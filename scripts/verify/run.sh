#!/usr/bin/env bash
# Walk the schema: every statement the two packages run against it, the scenario, the two fence
# races, and the Kalam role exercised rather than asserted.
#
#   soma/scripts/verify/run.sh            # from anywhere; needs the db container up
#
# Creates a scratch database beside `soma`, applies the shipped migrations, PREPAREs every statement
# in statements.sql, walks scenario.sql, runs the two fence races with concurrent sessions, then
# applies the migrations alone to a second scratch database, checks they seed nothing an admin makes,
# and exercises the `kalam` role there. Both databases are dropped at the end, and the `kalam` role with them where nothing else grants to it. Nothing in
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
DEPLOYED=soma_verify_deployed
MIGRATIONS=../../migrations
psql() { docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" "$@"; }
strip() { grep -v '^PREPARE$' | grep -v 'all statements prepared'; }

# The match statements in statements.sql are copies of what workflows/soma-runner-*.json ship, and a
# copy nobody compares is a copy that drifts: a race "proved" against a stale copy proves a statement
# that does not exist. Comparing them costs a second and makes that impossible rather than unlikely.
#
# The clock, notification, season-map, season-baseline and admission statements are compared the
# same way, against the workflows that ship them (n_version against all three tasks that ship
# it). The clock tasks live inside TASK GROUPS, which is why the lookup below descends.
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
         ("p_insert", "tb-pair-run", "insert"), ("w_sweep", "tb-withdraw-run", "sweep"),
         ("n_version", "tb-count-run", "notify_promoted"),
         ("n_version", "tb-count-run", "notify_rejected"),
         ("n_version", "tb-admit-run", "notify"),
         ("n_expired", "tb-admit-run", "notify_expired"),
         ("n_results", "tb-count-run", "notify_result"),
         ("n_ranks", "tb-count-run", "notify_rank"),
         ("n_season", "tb-withdraw-run", "notify_closed"),
         ("m_insert", "soma-season-maps-add", "insert"),
         ("m_flip", "soma-season-maps-update", "flip"),
         ("a_verify", "tb-admit-run", "verify"),
         ("a_expire", "tb-admit-run", "expire"), ("a_claim", "tb-admit-run", "claim"),
         ("a_batch_doc", "tb-admit-run", "batch"), ("a_queue", "tb-admit-run", "queue"),
         ("a_requeue", "tb-admit-run", "requeue"), ("a_release", "tb-admit-run", "release"),
         ("g_admit_claim", "soma-runner-admissions-claim", "claim"),
         ("g_admit_row", "soma-runner-admissions-claim", "row"),
         ("g_admit_report", "soma-runner-admissions-report", "report"),
         ("g_admit_why", "soma-runner-admissions-report", "why"),
         ("b_insert", "soma-season-baselines-add", "insert"),
         ("b_flip", "soma-season-baselines-update", "flip")]
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

# The deployed shape: the migrations alone, which is all a fresh platform database holds before its
# first bootstrap. Checks they seed nothing an admin makes -- seasons, their boards and baselines,
# runner keys and accounts are made on the admin pages -- and that the Kalam role's grants are
# exactly its execution columns, run rather than asserted.
echo "===== the deployed schema: migrations alone ====="
psql -d postgres -q -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS $DEPLOYED" -c "CREATE DATABASE $DEPLOYED"
cat "$MIGRATIONS/0001_init.sql" "$MIGRATIONS/0002_sessions.sql" \
  | psql -d "$DEPLOYED" -q -v ON_ERROR_STOP=1
psql -d "$DEPLOYED" -q -v ON_ERROR_STOP=1 <<'SQL'
\pset footer off
DO $$
DECLARE n int;
BEGIN
    -- NOTHING AN ADMIN MAKES IS SEEDED. The clock rows are the only data the migrations write; the
    -- game is bootstrap's, and everything else is made through the routes an admin page calls.
    SELECT count(*) INTO n FROM games;          ASSERT n = 0, format('the migrations wrote %s games', n);
    SELECT count(*) INTO n FROM seasons;        ASSERT n = 0, format('the migrations wrote %s seasons', n);
    SELECT count(*) INTO n FROM season_maps;    ASSERT n = 0, format('the migrations wrote %s season maps', n);
    SELECT count(*) INTO n FROM users;          ASSERT n = 0, format('the migrations made %s accounts', n);
    SELECT count(*) INTO n FROM models;         ASSERT n = 0, format('the migrations wrote %s models', n);
    SELECT count(*) INTO n FROM model_versions; ASSERT n = 0, format('the migrations wrote %s versions', n);
    SELECT count(*) INTO n FROM ratings;        ASSERT n = 0, format('the migrations wrote %s ratings', n);
    SELECT count(*) INTO n FROM runner_keys;    ASSERT n = 0, format('the migrations wrote %s runner keys', n);

    -- Kalam reads two tables and writes only its own columns of them.
    SELECT count(*) INTO n FROM information_schema.table_privileges
      WHERE grantee = 'kalam' AND privilege_type <> 'SELECT';
    ASSERT n = 0, format('kalam holds %s non-SELECT table-wide privileges; it must hold none', n);

    SELECT count(*) INTO n FROM information_schema.table_privileges
      WHERE grantee = 'kalam' AND privilege_type = 'SELECT'
        AND table_name NOT IN ('matches', 'match_seats');
    ASSERT n = 0, format('kalam can read %s tables it must not', n);

    -- What an account was told and how it wants to be told are Soma's, like its sessions: neither
    -- role that plays matches may read or write either table, and 0002 grants nothing so they cannot.
    SELECT count(*) INTO n
      FROM (VALUES ('kalam'), ('runner_gate')) AS r (role),
           (VALUES ('notifications'), ('notification_settings')) AS t (tbl),
           (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) AS p (priv)
     WHERE has_table_privilege(r.role, t.tbl, p.priv);
    ASSERT n = 0, format('kalam or runner_gate holds %s privileges on the notification tables', n);

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

    RAISE NOTICE 'nothing seeded, grants: OK';
END $$;
SQL

# What the Kalam role can and cannot do, run rather than read off information_schema. The grants
# above say the right words; this proves they bite. `SET ROLE` rather than a login, because the
# migration deliberately sets no password -- the credential is deployment configuration.
echo "===== the Kalam role, exercised ====="
psql -d "$DEPLOYED" -q -v ON_ERROR_STOP=1 <<'SQL'
\pset footer off
-- The game as bootstrap registers it and a live season as an admin creates it; two baselines in play
-- and one board, as an upload, an admission and two enables leave them; then one claimable match,
-- written as Soma (pair) would write it.
INSERT INTO games (slug, name, active_engine_digest) VALUES ('ants', 'Ants', 'sha256:fixture');
INSERT INTO seasons (game_id, number, name, slug, engine_digest, submissions_open_at, submissions_close_at)
SELECT g.id, 1, 'Fixture', 'fixture', g.active_engine_digest, now(), now() + interval '1 day'
  FROM games g WHERE g.slug = 'ants';
INSERT INTO users (handle, role) VALUES ('baseline.fixture-a', 'baseline'), ('baseline.fixture-b', 'baseline');
INSERT INTO models (owner_id, game_id, name)
SELECT u.id, g.id, substr(u.handle, 10) FROM users u, games g WHERE u.role = 'baseline' AND g.slug = 'ants';
INSERT INTO model_versions (model_id, game_id, season_id, version, status, weight_class,
                            weights_hash, manifest_hash, orion_version)
SELECT e.id, e.game_id, s.id, 1, 'active', 'nano', 'sha256:w-' || e.name, 'sha256:m-' || e.name, '1.8.1'
  FROM models e JOIN seasons s ON s.game_id = e.game_id AND s.closed_at IS NULL;
INSERT INTO season_maps (season_id, map_id, players, rows, cols, digest, board, enabled, added_by)
SELECT s.id, 'fixture', 2, 24, 24, 'sha256:fixture', '{"id": "fixture"}', true,
       (SELECT id FROM users WHERE handle = 'baseline.fixture-a')
  FROM seasons s WHERE s.closed_at IS NULL;
INSERT INTO matches (id, game_id, season_id, engine_digest, seed, season_map_id, seat_count, ladders)
SELECT '11111111-1111-1111-1111-111111111111', g.id, s.id, s.engine_digest, 1, sm.id, 2,
       ARRAY['nano','open']::ladder[]
  FROM games g JOIN seasons s ON s.game_id = g.id AND s.closed_at IS NULL
  JOIN season_maps sm ON sm.season_id = s.id WHERE g.slug = 'ants';
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

    BEGIN  SELECT count(*) INTO denied FROM notifications; denied := NULL;
    EXCEPTION WHEN insufficient_privilege THEN denied := 'notifications'; END;
    ASSERT denied = 'notifications', 'kalam must not be able to read notifications';

    -- And the column grant, not just the table one: it may write its own columns of `matches` and
    -- no others. Marking a match rated is count's, and the status-shape constraint plus this grant
    -- are together why "Kalam writes no rating" is a fact rather than a promise.
    BEGIN  UPDATE matches SET rated_at = now();           denied := NULL;
    EXCEPTION WHEN insufficient_privilege THEN denied := 'matches.rated_at'; END;
    ASSERT denied = 'matches.rated_at', 'kalam must not be able to mark a match rated';

    BEGIN  UPDATE matches SET withdrawn_reason = 'nope';  denied := NULL;
    EXCEPTION WHEN insufficient_privilege THEN denied := 'matches.withdrawn_reason'; END;
    ASSERT denied = 'matches.withdrawn_reason', 'kalam must not be able to cancel a match';

    RAISE NOTICE 'kalam is refused ratings, models, model_versions, clocks, rating_events, users, notifications, and the columns that are not its own: OK';
END $$;
SQL

psql -d postgres -q -v ON_ERROR_STOP=1 -c "DROP DATABASE $SCRATCH" -c "DROP DATABASE $DEPLOYED"
# Roles are cluster-global, so this only succeeds when no *other* database grants to kalam. Once
# the stack's own soma database has been initialised with 0001, it does -- and the role must
# survive. Dropping it is a courtesy to a cluster this script was the first thing to touch, never
# a requirement, so a refusal here is reported and ignored.
if psql -d postgres -q -c "DROP ROLE IF EXISTS kalam" 2> /dev/null; then
  echo "scratch databases dropped; role kalam dropped"
else
  echo "scratch databases dropped; role kalam kept (another database grants to it)"
fi
