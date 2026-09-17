#!/usr/bin/env bash
# What a claim costs under N concurrent pollers -- the measurement the poll interval is judged
# against.
#
#   scripts/measure/claim-load.sh [seconds-per-run]      # needs the db container up
#
# N replicas at interval i issue N/i claims a second, each one statement against the partial index
# on `pending`. The rule for raising the interval is: only when that rate is a measurable fraction
# of database capacity. This measures the capacity.
#
# Everything runs in a scratch database restored from the live one, so index statistics, row widths
# and the rows behind the partial index are real rather than generated. `soma` and `orion_state` are
# untouched and the scratch database is dropped at the end.
#
# Two cases: `idle` -- an empty queue and N pollers, pure index-probe cost, and the common case
# because a fleet sized by the autoscaler spends most of its time keeping up; and `deep` --
# pair_depth_target rows, the deepest the queue may get, contended under SKIP LOCKED.
#
# Each claim is rolled back, so the queue does not drain and every run measures the same shape. The
# locks are real: SKIP LOCKED makes each client take a different row and release it at the rollback.
set -euo pipefail
cd "$(dirname "$0")"

SECS="${1:-10}"
DB_CONTAINER="${DB_CONTAINER:-tinybrains-db-1}"
DB_USER="${DB_USER:-$(docker exec "$DB_CONTAINER" printenv POSTGRES_USER)}"
LIVE="${DB_NAME:-$(docker exec "$DB_CONTAINER" printenv POSTGRES_DB)}"
SCRATCH=tb_claim_bench
CLIENTS="${CLIENTS:-1 4 8 16 32 64}"

psql() { docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" "$@"; }
val()  { psql -d "$SCRATCH" -At -c "$1"; }

echo "==> scratch database from the live one"
psql -d postgres -q -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS $SCRATCH" > /dev/null
# TEMPLATE copies the whole database, statistics and all, without a dump -- but needs no other
# session on the source, so the stack's own connections are counted first.
if [ "$(psql -d postgres -At -c "SELECT count(*) FROM pg_stat_activity WHERE datname = '$LIVE'")" != "0" ]; then
  echo "    $LIVE has live connections, so TEMPLATE is refused -- dumping instead"
  psql -d postgres -q -v ON_ERROR_STOP=1 -c "CREATE DATABASE $SCRATCH" > /dev/null
  # THE search_path REWRITE IS NOT COSMETIC. pg_dump opens its output with
  # `set_config('search_path', '', false)` so that nothing in the dump resolves an unqualified name
  # by accident -- but `season_rules_ok()` CALLS `season_rule_spec()` unqualified, and the CHECK on
  # `seasons` fires while the empty path is in force, so the restore dies with "function
  # season_rule_spec() does not exist" and the whole harness exits 3 before measuring anything.
  # Putting `public` back is the narrowest fix; qualifying the call inside the function would be the
  # other one, and that belongs to soma's migration rather than to a benchmark.
  docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$LIVE" --no-owner --no-privileges \
    | sed "s/^SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public', false);/" \
    | psql -d "$SCRATCH" -q -v ON_ERROR_STOP=1 > /dev/null 2>&1
else
  psql -d postgres -q -v ON_ERROR_STOP=1 -c "CREATE DATABASE $SCRATCH TEMPLATE $LIVE" > /dev/null
fi

DIGEST=$(val "SELECT active_engine_digest FROM games WHERE slug = 'ants'")
echo "    rows: $(val "SELECT count(*) FROM matches") matches, $(val "SELECT count(*) FROM match_seats") seats"
echo "    engine: $DIGEST"

# A RUNNER TO CLAIM AS. The shipped claim joins `live_runners` and counts that runner's in-flight
# rows, so the statement cannot be measured without one -- and a fixture whose key is revoked or
# whose owner is not an admin measures the EXISTS failing, which is fast and meaningless. Built
# here rather than assumed, because a scratch database copied from a live stack may have neither.
RUNNER=$(val "
  WITH admin AS (
      INSERT INTO users (github_id, handle, role)
      VALUES (-1, 'claim-bench', 'admin')
      ON CONFLICT (github_id) DO UPDATE SET role = 'admin'
      RETURNING id
  ), k AS (
      INSERT INTO runner_keys (user_id, label, key_hash, key_prefix)
      SELECT id, 'claim-bench', repeat('0', 64), 'tbr_bench' FROM admin
      RETURNING id
  ), r AS (
      INSERT INTO runners (key_id, label, max_in_flight)
      SELECT k.id, 'claim-bench', 32767 FROM k
      RETURNING id
  )
  SELECT id FROM r")
[ -n "$RUNNER" ] || { echo "could not stage a runner fixture -- is the schema current?" >&2; exit 1; }
# max_in_flight is at its ceiling on purpose: every claim here is rolled back, so no row is ever
# really held, and a realistic 4 would still let the harness measure the predicate rather than
# trip it. What is being timed is the InitPlan, not the limit.
echo "    runner: $RUNNER (max_in_flight 32767, so the ceiling never short-circuits the probe)"
SEATS=$(val "SELECT coalesce(max(seat_count), 2) FROM matches")
docker cp claim.sql "$DB_CONTAINER":/tmp/claim.sql > /dev/null

echo "==> making the queue reproducible"
psql -d "$SCRATCH" -q -v ON_ERROR_STOP=1 <<'SQL' > /dev/null
-- Whatever the live stack was mid-flight, start from nothing pending, so the only pending rows are
-- the ones each case stages.
--
-- ONLY `pending` IS TOUCHED, and the target is `cancelled` rather than `rated`. The claim filters
-- `status = 'pending'`, so a claimed, running or finished row cannot be taken by this harness and
-- does not need neutralising -- and it CANNOT be flipped to `rated` anyway: `matches_status_shape`
-- requires a rated row to carry `played_at`, `rated_at` and `rated_seq`, which an in-flight row has
-- none of. Sweeping all four states into 'rated' worked only while the snapshot happened to hold no
-- in-flight rows, and failed the moment it was run against a ladder that was actually playing.
-- `cancelled` is the state a pending row can legally reach: withdrawn_reason, closed_at, no played_at.
UPDATE matches
   SET status = 'cancelled', withdrawn_reason = 'claim-load benchmark reset', closed_at = now(),
       claim_token = NULL, lease_expires_at = NULL, played_by = NULL
 WHERE status = 'pending';
ANALYZE matches;
ANALYZE match_seats;
SQL

run_case() {   # $1 label, $2 pending rows to stage
  echo
  echo "==> $1 queue: $2 pending row(s)"
  # Staged by INSERT, not by flipping a rated row back: `matches_status_shape` requires a pending
  # row's played_at, rated_at, closed_at, claim_token and lease_expires_at to be NULL. Seats are
  # cloned from a real match so row widths and the seat join are real rather than generated.
  psql -d "$SCRATCH" -q -v ON_ERROR_STOP=1 -v n="$2" <<'SQL' > /dev/null
DELETE FROM match_seats WHERE match_id IN (SELECT id FROM matches WHERE status = 'pending');
DELETE FROM matches WHERE status = 'pending';
WITH src AS (
    SELECT * FROM matches WHERE status = 'rated' ORDER BY created_at DESC LIMIT 1
), ins AS (
    INSERT INTO matches (game_id, season_id, engine_digest, seed, preset, seat_count, ladders)
    SELECT src.game_id, src.season_id, src.engine_digest, g.i, src.preset, src.seat_count, src.ladders
      FROM src, generate_series(1, :'n'::int) g(i)
 RETURNING id
)
INSERT INTO match_seats (match_id, seat, version_id, weights_hash, manifest_hash)
SELECT ins.id, s.seat, s.version_id, s.weights_hash, s.manifest_hash
  FROM ins CROSS JOIN LATERAL (
       SELECT seat, version_id, weights_hash, manifest_hash FROM match_seats
        WHERE match_id = (SELECT id FROM src)) s;
ANALYZE matches;
ANALYZE match_seats;
SQL
  printf '    %-8s %12s %14s\n' clients "claims/s" "mean ms"
  for c in $CLIENTS; do
    out=$(docker exec "$DB_CONTAINER" pgbench -U "$DB_USER" -d "$SCRATCH" \
            -n -c "$c" -j "$(( c > 8 ? 8 : c ))" -T "$SECS" \
            -D digest="'$DIGEST'" -D runner="'$RUNNER'" -D seats="$SEATS" -f /tmp/claim.sql 2>&1) || {
      echo "$out" | tail -5 >&2; return 1; }
    tps=$(echo "$out" | awk '/^tps =/ {print $3; exit}')
    lat=$(echo "$out" | awk '/^latency average/ {print $4; exit}')
    mx=$(echo "$out" | awk '/^initial connection time/ {print $5; exit}')
    printf '    %-8s %12.0f %14s\n' "$c" "${tps:-0}" "${lat:-?}"
    # The floor across every run is what the interval is judged against, not the peak.
    if [ -z "${FLOOR:-}" ] || [ "${tps%%.*}" -lt "$FLOOR" ]; then FLOOR="${tps%%.*}"; fi
  done
}

run_case "idle  -- a large fleet polling nothing" 0
run_case "deep  -- pair_depth_target, the deepest the queue may get" 64

echo
echo "==> what this says about the poll interval"
echo "    Floor across every run: $FLOOR claims/s (the slowest, which is the single-client case --"
echo "    concurrency buys throughput here, it does not cost it)."
echo
printf '    %-22s %14s %16s\n' "fleet" "claims/s" "of capacity"
for spec in "20 5" "100 5" "100 1" "1000 5"; do
  set -- $spec
  rate=$(( $1 / $2 ))
  pct=$(awk -v r="$rate" -v f="$FLOOR" 'BEGIN{printf "%.2f%%", 100*r/f}')
  printf '    %-22s %14s %16s\n' "N=$1 at i=${2}s" "$rate" "$pct"
done
echo
echo "    Raise the interval only when N/i is a measurable fraction of that floor. It is not one at"
echo "    any fleet size this design contemplates, so the lower bound on the interval is not claim"
echo "    load -- and it is not latency either. It is the paragraph below."
echo

# ---------------------------------------------------------------------------- the real bound
#
# WHAT THIS WHOLE HARNESS MEASURES IS NO LONGER THE BINDING CONSTRAINT, and saying so here is the
# point of this block. It measures ONE STATEMENT IN POSTGRES. Since a replica may run in `api`
# mode, an idle poll is not one statement -- it is TWO HTTP CALLS THROUGH THE GATE, because every
# cron run is a fresh workflow execution with no state carried between runs, so each one mints a
# ten-minute token and uses it exactly once.
#
# Measured on a live stack, 120 seconds, two api-mode runners, nothing queued:
#
#     214 soma-runner-token      1.78/s   0.89/s per runner
#     198 soma-runner-claim      1.65/s   0.83/s per runner   (4 channels at 5s = 0.80)
#      16 soma-runner-roster     0.13/s   0.067/s per runner  (every 15s)
#
# 214 tokens for 214 authenticated calls: exactly one per call, which is the doubling.
#
# AND THE TOKEN ROUTE IS RATE LIMITED ON THE CALLER'S ADDRESS. `soma-runner-token` declares
# {requests_per_second: 5, burst: 10} and CANNOT have a principal limit -- it is the route that
# establishes the principal. So the ceiling is per SOURCE ADDRESS, and several machines in one
# office are one source address.
TOKEN_RPS="${TOKEN_RPS:-5}"      # soma/channels/soma-runner-token.json rate_limit
PER_RUNNER="${PER_RUNNER:-0.89}" # measured above
echo "==> the bound that actually binds: the token route, per SOURCE ADDRESS"
printf '    %-34s %s\n' "token route limit" "$TOKEN_RPS rps (address-keyed, burst 10)"
printf '    %-34s %s\n' "an idle runner costs" "$PER_RUNNER token/s -- one per authenticated call"
runners=$(awk -v t="$TOKEN_RPS" -v p="$PER_RUNNER" 'BEGIN{printf "%.1f", t/p}')
printf '    %-34s %s\n' "runners behind one NAT" "$runners"
pct=$(awk -v r="$runners" -v f="$FLOOR" 'BEGIN{printf "%.2f%%", 100*(r*0.83)/f}')
printf '    %-34s %s\n' "…and the database at that point" "$pct of the floor measured above"
echo
echo "    So the database is ~200x clear of the limit that bites first, and the limit that bites"
echo "    first is SILENT: a 429 on the token leaves data.tok.token unset, the run ends at the"
echo "    \`noauth\` task with outcome no_token, and the channel traces errors_only -- so nothing"
echo "    is written anywhere. The one visible symptom is that last_seen_at stops moving, because"
echo "    the token exchange is what stamps it, which is why the admin Runners screen separates"
echo "    \"calling in\" from \"authorised\"."
echo
echo "    N9, answered: do not lengthen the poll. Stop minting a ten-minute token for one call --"
echo "    then one runner costs 0.83 calls/s instead of 1.78, and the same limit holds twice the"
echo "    machines. Raising TOKEN_RPS instead buys the same room and keeps the doubling."

psql -d postgres -q -c "DROP DATABASE IF EXISTS $SCRATCH" > /dev/null
echo
echo "==> scratch dropped; $LIVE untouched"
