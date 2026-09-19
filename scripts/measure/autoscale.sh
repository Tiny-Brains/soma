#!/usr/bin/env bash
# Drive the autoscaler's query against staged ladders, and check the four things claimed of it.
#
#   scripts/measure/autoscale.sh          # needs the db container up
#
#   1. it reads DEMAND, and demand LEADS the queue -- a replica is asked for before the rows it
#      will claim exist;
#   2. it must NEVER read queue depth. `pair_depth_target` caps the queue at 64, so a
#      scaler reading depth would cap the fleet at 64/K and look correct doing it;
#   3. the latency guard is a NUDGE -- exactly one replica above the computed target, never a jump;
#   4. `engine_digest = s.engine_digest` keeps a rolling deploy from oscillating: the old engine's
#      rows are drained by replicas that are going away, and counting them would ask for new-engine
#      replicas to cover work they cannot claim.
#
# autoscaler.sql is the pair clock's demand view at the deploy's numbers -- the `d_demand` shape soma's verify
# statements carry, which is what pair computes for a season that sets no rules -- with the scaling
# arithmetic on top.
#
# Nothing touches the live database: the scratch copy is dropped at the end.
set -euo pipefail
cd "$(dirname "$0")"

DB_CONTAINER="${DB_CONTAINER:-tinybrains-db-1}"
DB_USER="${DB_USER:-$(docker exec "$DB_CONTAINER" printenv POSTGRES_USER)}"
LIVE="${DB_NAME:-$(docker exec "$DB_CONTAINER" printenv POSTGRES_DB)}"
SCRATCH=tb_scale_bench
psql() { docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" "$@"; }

echo "==> scratch database from the live one"
psql -d postgres -q -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS $SCRATCH" > /dev/null 2>&1
psql -d postgres -q -v ON_ERROR_STOP=1 -c "CREATE DATABASE $SCRATCH" > /dev/null
docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$LIVE" --no-owner --no-privileges \
  | psql -d "$SCRATCH" -q -v ON_ERROR_STOP=1 > /dev/null 2>&1

GAME_ID=$(psql -d "$SCRATCH" -At -c "SELECT id FROM games WHERE slug = 'ants'")

# Every non-baseline version into the live season, so the ladder has a field at all: on the live
# stack the versions sit in closed seasons and the open one holds only baselines. Not the baselines
# themselves: each closed season holds an earlier carried copy of each, and moving those would stack
# several active versions of one baseline into the live season and count its demand several times.
psql -d "$SCRATCH" -q -v ON_ERROR_STOP=1 <<'SQL' > /dev/null
ALTER TABLE model_versions DROP CONSTRAINT IF EXISTS model_versions_one_active_excl;
UPDATE model_versions md SET season_id = (SELECT id FROM seasons WHERE closed_at IS NULL)
  FROM models e, users u
 WHERE e.id = md.model_id AND u.id = e.owner_id
   AND md.status = 'active' AND u.role <> 'baseline';
SQL

stage() {  # $1 sql
  psql -d "$SCRATCH" -q -v ON_ERROR_STOP=1 -c "$1" > /dev/null
}
reset_queue() {
  stage "DELETE FROM match_seats WHERE match_id IN (SELECT id FROM matches WHERE status IN ('pending','claimed','running'));
         DELETE FROM matches WHERE status IN ('pending','claimed','running');"
}
# n pending rows, aged `age` seconds, on `digest`.
add_pending() {  # $1 n, $2 age_secs, $3 digest
  psql -d "$SCRATCH" -q -v ON_ERROR_STOP=1 -v n="$1" -v age="$2" -v d="$3" <<'SQL' > /dev/null
WITH src AS (SELECT * FROM matches WHERE status = 'rated' ORDER BY created_at DESC LIMIT 1),
ins AS (
  INSERT INTO matches (game_id, season_id, engine_digest, seed, preset, seat_count, ladders, created_at)
  SELECT src.game_id, src.season_id, :'d', g.i, src.preset, src.seat_count, src.ladders,
         now() - (:'age'::int * interval '1 second')
    FROM src, generate_series(1, :'n'::int) g(i)
  RETURNING id)
INSERT INTO match_seats (match_id, seat, version_id, weights_hash, manifest_hash)
SELECT ins.id, s.seat, s.version_id, s.weights_hash, s.manifest_hash
  FROM ins CROSS JOIN LATERAL (
       SELECT seat, version_id, weights_hash, manifest_hash FROM match_seats
        WHERE match_id = (SELECT id FROM src)) s;
SQL
}
# sigma above `settled_sigma` makes a version unsettled and therefore wanted.
unsettle() { stage "UPDATE ratings SET sigma = 8.333333333333334;"; }
settle()   { stage "UPDATE ratings SET sigma = 0.7;"; }

run() {  # $1 label, $2..: the eight parameters
  local label="$1"; shift
  printf '\n--- %s\n' "$label"
  python3 - "$GAME_ID" "$@" > /tmp/tb-scale.sql <<'PYEOF'
import sys, pathlib
gid, *p = sys.argv[1:]
q = pathlib.Path("autoscaler.sql").read_text().rstrip().rstrip(";")
print("PREPARE a AS"); print(q + ";")
print(f"EXECUTE a('{gid}', {', '.join(p)});")
PYEOF
  psql -d "$SCRATCH" -v ON_ERROR_STOP=1 < /tmp/tb-scale.sql | sed -n '2,5p'
  rm -f /tmp/tb-scale.sql
}

DIGEST=$(psql -d "$SCRATCH" -At -c "SELECT active_engine_digest FROM games WHERE slug='ants'")
OLD="sha256:$(printf 'retired-engine' | shasum -a 256 | cut -d' ' -f1)"
# $1 game · $2 burst · $3 steady cap · $4 settled sigma · $5 floor · $6 ceiling · $7 K · $8 guard
P="8 2 3.0 1 20 16 60"

echo "==> the scenarios"
reset_queue; settle
run "1. settled field, empty queue -- the floor, and nothing above it" $P

reset_queue; unsettle
run "2. the same field unsettled, queue still EMPTY -- demand LEADS the queue" $P

reset_queue; unsettle; add_pending 64 5 "$DIGEST"
run "3. queue at pair_depth_target (64). Depth is capped; want is not" $P

reset_queue; unsettle; add_pending 64 600 "$DIGEST"
run "4. same, but the oldest pending row is 600 s old -- the guard adds ONE" $P

reset_queue; settle; add_pending 40 5 "$OLD"
run "5. 40 rows on a RETIRED engine, mid-roll -- excluded, so no oscillation" $P

reset_queue; unsettle
run "6. as 2, with K=4 -- the fleet is want/K, so a smaller K wants more replicas" 8 2 3.0 1 20 4 60

psql -d postgres -q -v ON_ERROR_STOP=1 -c "DROP DATABASE $SCRATCH" > /dev/null
echo
echo "==> scratch dropped; $LIVE untouched"
