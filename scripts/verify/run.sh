#!/usr/bin/env bash
# Walk the schema: every statement the two packages run against it, the scenario, the two fence
# races, and the Kalam role exercised rather than asserted.
#
#   soma/scripts/verify/run.sh            # from anywhere; needs the db container up
#
# Creates a scratch database beside `soma`, applies the shipped migrations, PREPAREs every statement
# in statements.sql, walks scenario.sql, runs the two fence races with concurrent sessions, then
# applies the devops seed to a second scratch database and checks what it produced. Both databases
# are dropped at the end, and the `kalam` role with them where nothing else grants to it. Nothing in
# `soma` or `orion_state` is touched.
#
# check-sql.sh checks that what Soma ships PARSES; this checks what the SCHEMA promises -- the
# runner gate's match statements (Kalam's, served here), the clocks' ladder statements, and the
# `kalam` role a db-mode replica still holds.
set -euo pipefail
cd "$(dirname "$0")"
DB_CONTAINER="${DB_CONTAINER:-tinybrains-db-1}"
DB_USER="${DB_USER:-$(docker exec "$DB_CONTAINER" printenv POSTGRES_USER)}"
SCRATCH=soma_verify
SEEDCHK=soma_verify_seed
MIGRATIONS=../../migrations
# The seed lives in devops, which has moved it once. Override SEED, or check out devops beside
# soma, or the seed half of this script is skipped with a notice.
SEED="${SEED:-}"
if [ -z "$SEED" ]; then
  for candidate in ../../../devops/compose/bootstrap/seed.sql \
                   ../../../devops/compose/db-init/30-seed.sql \
                   ../../../devops/db-init/30-seed.sql; do
    [ -f "$candidate" ] && SEED="$candidate" && break
  done
  SEED="${SEED:-../../../devops/compose/bootstrap/seed.sql}"
fi
psql() { docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" "$@"; }
strip() { grep -v '^PREPARE$' | grep -v 'all statements prepared'; }

# The eight match statements in statements.sql are copies of what workflows/soma-runner-*.json ship,
# and a copy nobody compares is a copy that drifts: this file carried the pre-R7 two-CTE wave claim
# for months after a one-row claim shipped, so every race it "proved" was proving a statement that
# did not exist. Comparing them costs a second and makes that impossible rather than unlikely.
#
# The thirteen clock statements are compared the same way, against the generated workflows/tb-*.json.
# Until the clocks moved into this repository nothing compared them at all, and three of the copies
# (c_verdicts, c_decide, c_batch) had already outlived the statements they copied. The clock tasks
# live inside TASK GROUPS, which is why the lookup below descends.
echo "===== the statements under test are the statements that ship ====="
python3 - <<'PY'
import json, re, sys, pathlib
PAIRS = [("k_reap", "soma-runner-reap", "reap"), ("k_claim", "soma-runner-claim", "claim"),
         ("k_row", "soma-runner-claim", "row"), ("k_start", "soma-runner-start", "start"),
         ("k_release", "soma-runner-release", "release"), ("k_renew", "soma-runner-renew", "renew"),
         ("k_finish", "soma-runner-finish", "finish"),
         ("c_fence", "tb-count-run", "fence"), ("c_batch_doc", "tb-count-run", "batch"),
         ("c_priors", "tb-count-run", "priors"), ("c_fold", "tb-count-run", "fold"),
         ("c_pass", "tb-count-run", "pass"), ("c_reject", "tb-count-run", "reject"),
         ("c_withdraw_pred", "tb-count-run", "withdraw"),
         ("p_game", "tb-pair-run", "game"), ("p_epoch", "tb-pair-run", "epoch"),
         ("p_demand_doc", "tb-pair-run", "demand"), ("p_trials", "tb-pair-run", "trials"),
         ("p_insert", "tb-pair-run", "insert"), ("w_sweep", "tb-withdraw-run", "sweep")]
prepared = pathlib.Path("statements.sql").read_text()
def tasks(ts):
    for t in ts:
        yield t
        yield from tasks(t.get("tasks", []))
flat = lambda s: re.sub(r"\s+", " ", s).strip().rstrip(";")
bad = []
for name, wf, task in PAIRS:
    doc = json.load(open(f"../../workflows/{wf}.json"))
    shipped = next(t["function"]["input"]["query"] for t in tasks(doc["tasks"]) if t["id"] == task)
    m = re.search(rf"^PREPARE {name}(?: \([^)]*\))? AS\n(.*?);$", prepared, re.S | re.M)
    if not m:
        bad.append(f"{name}: no PREPARE in statements.sql")
    elif flat(m.group(1)) != flat(shipped):
        bad.append(f"{name}: statements.sql differs from workflows/{wf}.json / {task}")
for b in bad:
    print(f"  DRIFT {b}")
print("  " + ("the harness walks what ships: OK" if not bad else "FAILED"))
sys.exit(1 if bad else 0)
PY

psql -d postgres -q -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS $SCRATCH" -c "CREATE DATABASE $SCRATCH"
cat "$MIGRATIONS/0001_init.sql" "$MIGRATIONS/0002_sessions.sql" \
  | psql -d "$SCRATCH" -q -v ON_ERROR_STOP=1
echo "migrations 0001+0002: OK"

echo "===== the walk ====="
cat statements.sql scenario.sql | psql -d "$SCRATCH" 2>&1 | strip

echo "===== race 1: a newer claim holds the fence row; the stale fold must block, then write nothing ====="
( cat statements.sql race1_hold.sql | psql -d "$SCRATCH" -q > race1_hold.log 2>&1 ) &
sleep 2
cat statements.sql race1_probe.sql | psql -d "$SCRATCH" -q 2>&1 | strip
wait; strip < race1_hold.log

echo "===== race 2: the live fold holds FOR SHARE; the newer claim must block, then succeed ====="
( cat statements.sql race2_hold.sql | psql -d "$SCRATCH" -q > race2_hold.log 2>&1 ) &
sleep 2
cat statements.sql race2_probe.sql | psql -d "$SCRATCH" -q 2>&1 | strip
wait; strip < race2_hold.log

rm -f race1_hold.log race2_hold.log

# The deployed shape: the migrations plus the seed the volume gets on first initialisation, which
# is what a fresh environment actually runs. Checks the three baselines are contestable opponents,
# that every seeded rating has its seq-0 event, and that the Kalam role's grants are exactly the
# columns docs/schema.md §3.8 names -- the security track's assertion, run rather than asserted.
echo "===== the deployed schema: migrations + seed ====="
if [ ! -f "$SEED" ]; then
  echo "SKIP: seed checks -- $SEED not found (needs the devops repo; set SEED= to point at it)"
  psql -d postgres -q -v ON_ERROR_STOP=1 -c "DROP DATABASE $SCRATCH"
  exit 0
fi
psql -d postgres -q -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS $SEEDCHK" -c "CREATE DATABASE $SEEDCHK"
cat "$MIGRATIONS/0001_init.sql" "$MIGRATIONS/0002_sessions.sql" "$SEED" \
  | psql -d "$SEEDCHK" -q -v ON_ERROR_STOP=1
psql -d "$SEEDCHK" -q -v ON_ERROR_STOP=1 <<'SQL'
\pset footer off
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM model_versions m JOIN models e ON e.id = m.model_id
      JOIN users u ON u.id = e.owner_id
      WHERE u.role = 'baseline' AND m.status = 'active';
    ASSERT n = 3, format('expected 3 active baselines, found %s', n);

    -- The entry is named for the artifact directory, taken off the reserved `baseline.` prefix.
    -- A substring pattern that silently matched the whole handle would name three entries
    -- `baseline.nano-bc` and nothing else in the seed would fail.
    SELECT count(*) INTO n FROM models e JOIN users u ON u.id = e.owner_id
      WHERE u.role = 'baseline' AND (e.name LIKE 'baseline%' OR e.name = u.handle);
    ASSERT n = 0, format('%s baseline entries kept the handle prefix in their name', n);

    SELECT count(*) INTO n FROM ratings; ASSERT n = 6, format('expected 6 ratings, found %s', n);

    SELECT count(*) INTO n FROM ratings r
      WHERE NOT EXISTS (SELECT 1 FROM rating_events e
                         WHERE e.version_id = r.version_id AND e.ladder = r.ladder AND e.seq = 0);
    ASSERT n = 0, format('%s seeded ratings have no seq-0 event', n);

    SELECT count(*) INTO n FROM games WHERE active_engine_digest IS NOT NULL;
    ASSERT n = 1, 'the game must carry an engine digest, placeholder or not';

    -- docs/rating-and-seasons.md: exactly one live season, pinning the game's digest, with the baselines in it
    SELECT count(*) INTO n FROM seasons s JOIN games g ON g.id = s.game_id
      WHERE s.closed_at IS NULL AND s.engine_digest = g.active_engine_digest;
    ASSERT n = 1, 'the game must have exactly one live season, on its digest';
    SELECT count(*) INTO n FROM model_versions m JOIN seasons s ON s.id = m.season_id
      WHERE s.closed_at IS NULL AND m.status = 'active';
    ASSERT n = 3, format('the three baselines must be active in the live season, found %s', n);

    -- Kalam reads two tables and writes only its own columns of them.
    SELECT count(*) INTO n FROM information_schema.table_privileges
      WHERE grantee = 'kalam' AND privilege_type <> 'SELECT';
    ASSERT n = 0, format('kalam holds %s non-SELECT table-wide privileges; it must hold none', n);

    SELECT count(*) INTO n FROM information_schema.table_privileges
      WHERE grantee = 'kalam' AND privilege_type = 'SELECT'
        AND table_name NOT IN ('matches', 'match_seats');
    ASSERT n = 0, format('kalam can read %s tables it must not', n);

    SELECT count(*) INTO n FROM information_schema.column_privileges
      WHERE grantee = 'kalam' AND privilege_type = 'UPDATE'
        AND (table_name, column_name) NOT IN (
            ('matches','status'), ('matches','claim_token'), ('matches','lease_expires_at'),
            ('matches','lapses'), ('matches','refusals'), ('matches','reason'),
            ('matches','turns'), ('matches','played_ms'), ('matches','engine_digest_played'),
            ('matches','orion_version'), ('matches','replay_key'), ('matches','played_at'),
            ('matches','fault_reason'), ('matches','fault_seat'), ('matches','closed_at'),
            ('match_seats','rank'), ('match_seats','score'), ('match_seats','strikes'),
            ('match_seats','infer_us_total'), ('match_seats','infer_us_max'),
            ('match_seats','infer_turns'));
    ASSERT n = 0, format('kalam can write %s columns outside its grant', n);

    RAISE NOTICE 'seed and grants: OK';
END $$;
SQL

# What the Kalam role can and cannot do, run rather than read off information_schema. The grants
# above say the right words; this proves they bite. `SET ROLE` rather than a login, because the
# migration deliberately sets no password -- the credential is deployment configuration.
echo "===== the Kalam role, exercised ====="
psql -d "$SEEDCHK" -q -v ON_ERROR_STOP=1 <<'SQL'
\pset footer off
-- One claimable match, written as Soma (pair) would write it.
INSERT INTO matches (id, game_id, season_id, engine_digest, seed, preset, seat_count, ladders)
SELECT '11111111-1111-1111-1111-111111111111', g.id, s.id, s.engine_digest, 1, 'standard', 2,
       ARRAY['nano','open']::ladder[]
  FROM games g JOIN seasons s ON s.game_id = g.id AND s.closed_at IS NULL WHERE g.slug = 'ants';
INSERT INTO match_seats (match_id, seat, version_id, weights_hash, manifest_hash)
SELECT '11111111-1111-1111-1111-111111111111', row_number() OVER (ORDER BY m.id) - 1,
       m.id, m.weights_hash, m.manifest_hash
  FROM model_versions m LIMIT 2;

DO $$
DECLARE denied text;
BEGIN
    SET LOCAL ROLE kalam;

    -- What it MUST be able to do: claim, start, and finish its own rows.
    UPDATE matches SET status = 'claimed', claim_token = gen_random_uuid(),
                       lease_expires_at = now() + interval '60 s'
     WHERE id = '11111111-1111-1111-1111-111111111111';
    UPDATE match_seats SET rank = 1, score = 10, strikes = 0
     WHERE match_id = '11111111-1111-1111-1111-111111111111' AND seat = 0;
    RAISE NOTICE 'kalam can claim a match and report a seat: OK';

    -- What it MUST NOT be able to do. Each of these is a way the match player could reach into
    -- the ladder if the grant were wrong, and each must be refused by Postgres, not by convention.
    BEGIN  UPDATE ratings SET mu = 99;                    denied := NULL;
    EXCEPTION WHEN insufficient_privilege THEN denied := 'ratings'; END;
    ASSERT denied = 'ratings', 'kalam must not be able to write a rating';

    BEGIN  UPDATE model_versions SET status = 'active';   denied := NULL;
    EXCEPTION WHEN insufficient_privilege THEN denied := 'model_versions'; END;
    ASSERT denied = 'model_versions', 'kalam must not be able to promote a version';
    -- and it cannot reach the entry either, which is Soma's alone
    BEGIN  PERFORM count(*) FROM models;                  denied := NULL;
    EXCEPTION WHEN insufficient_privilege THEN denied := 'models'; END;
    ASSERT denied = 'models', 'kalam must not be able to read the entries';

    BEGIN  UPDATE clocks SET epoch = 99;                  denied := NULL;
    EXCEPTION WHEN insufficient_privilege THEN denied := 'clocks'; END;
    ASSERT denied = 'clocks', 'kalam must not be able to move a fence';

    BEGIN  INSERT INTO rating_events (version_id, ladder, seq, mu_after, sigma_after)
           SELECT id, 'open', 9, 1, 1 FROM model_versions LIMIT 1;  denied := NULL;
    EXCEPTION WHEN insufficient_privilege THEN denied := 'rating_events'; END;
    ASSERT denied = 'rating_events', 'kalam must not be able to write a rating event';

    BEGIN  SELECT count(*) INTO denied FROM users;        denied := NULL;
    EXCEPTION WHEN insufficient_privilege THEN denied := 'users'; END;
    ASSERT denied = 'users', 'kalam must not be able to read users';

    -- And the column grant, not just the table one: it may write its own columns of `matches` and
    -- no others. Marking a match rated is count's, and the status-shape constraint plus this grant
    -- are together why "Kalam writes no rating" is a fact rather than a promise.
    BEGIN  UPDATE matches SET rated_at = now();           denied := NULL;
    EXCEPTION WHEN insufficient_privilege THEN denied := 'matches.rated_at'; END;
    ASSERT denied = 'matches.rated_at', 'kalam must not be able to mark a match rated';

    BEGIN  UPDATE matches SET withdrawn_reason = 'nope';  denied := NULL;
    EXCEPTION WHEN insufficient_privilege THEN denied := 'matches.withdrawn_reason'; END;
    ASSERT denied = 'matches.withdrawn_reason', 'kalam must not be able to cancel a match';

    RAISE NOTICE 'kalam is refused ratings, models, model_versions, clocks, rating_events, users, and the columns that are not its own: OK';
END $$;
SQL

psql -d postgres -q -v ON_ERROR_STOP=1 -c "DROP DATABASE $SCRATCH" -c "DROP DATABASE $SEEDCHK"
# Roles are cluster-global, so this only succeeds when no *other* database grants to kalam. Once
# the stack's own soma database has been initialised with 0001, it does -- and the role must
# survive. Dropping it is a courtesy to a cluster this script was the first thing to touch, never
# a requirement, so a refusal here is reported and ignored.
if psql -d postgres -q -c "DROP ROLE IF EXISTS kalam" 2> /dev/null; then
  echo "scratch databases dropped; role kalam dropped"
else
  echo "scratch databases dropped; role kalam kept (another database grants to it)"
fi
