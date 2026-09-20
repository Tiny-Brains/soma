#!/usr/bin/env bash
# PREPARE every statement the package ships, against a schema built from the migrations, AS THE
# ROLE ITS CONNECTOR CONNECTS AS.
#
#   soma/scripts/check-sql.sh
#
# `orion-server sql check` walks the set -- task groups included -- resolves each connector exactly
# as the server does, builds a scratch schema from migrations/ in ONE TRANSACTION THAT IS ALWAYS
# ROLLED BACK, and prepares every statement in its own savepoint. Nothing is executed: the sessions
# are READ ONLY. On PostgreSQL 16+ it also plans each statement with EXPLAIN (GENERIC_PLAN), which
# is what proves the role's table and column GRANTS.
#
# THAT LAST PART IS NEW AND IT MATTERS MORE THAN THE REST. This script used to PREPARE everything as
# the owner, and PREPARE never checks a privilege -- so a gate statement naming a column
# `runner_gate` has no grant on passed here and failed on the next runner poll. `--role` is what
# closes it: `soma-runner-db` is checked as `runner_gate`, which is the boundary with Kalam.
#
# IT NEEDS NO STACK, only a PostgreSQL 16+ server to build the scratch schema on, and it starts a
# throwaway one when SQLCHECK_DATABASE does not name one. So this runs on a laptop with nothing up.
#
# What each statement DOES is scripts/verify/run.sh's walk; that a workflow answers at all is
# scripts/smoke.sh.
#
# `soma-db` is reported as "grants not proven", and that is correct rather than missing: it connects
# as the schema's OWNER, which holds every grant by construction, so there is nothing a role check
# could prove about it. The boundary worth proving is `runner_gate`'s, and that one is.
#
#   SQLCHECK_DATABASE   a PostgreSQL 16+ superuser URL. Unset starts and removes a container.
set -euo pipefail
cd "$(dirname "$0")/.."

DATABASE="${SQLCHECK_DATABASE:-}"
CONTAINER=""
if [ -z "$DATABASE" ]; then
  command -v docker > /dev/null || {
    echo "set SQLCHECK_DATABASE to a PostgreSQL 16+ URL, or install docker to start one" >&2
    exit 1
  }
  CONTAINER="soma-sqlcheck-$$"
  PORT=$(( 15432 + (RANDOM % 1000) ))
  echo "==> starting a throwaway postgres on :$PORT"
  docker run -d --rm --name "$CONTAINER" -p "$PORT:5432" \
    -e POSTGRES_PASSWORD=sqlcheck -e POSTGRES_DB=sqlcheck postgres:16-alpine > /dev/null
  # shellcheck disable=SC2064
  trap "docker rm -f '$CONTAINER' > /dev/null 2>&1 || true; rm -rf \"\${SCHEMA:-}\"" EXIT
  DATABASE="postgres://postgres:sqlcheck@127.0.0.1:$PORT/sqlcheck"
  for _ in $(seq 60); do
    docker exec "$CONTAINER" pg_isready -U postgres -d sqlcheck > /dev/null 2>&1 && break
    sleep 1
  done
fi

# THE SCRATCH SCHEMA IS BUILT FROM A COPY WITH THE MIGRATIONS' OWN `BEGIN;`/`COMMIT;` REMOVED.
# Each migration wraps itself so `bootstrap` applies it atomically through psql; `sql check` builds
# the schema inside ONE transaction it always rolls back, and a `COMMIT` in the middle of that would
# end it. The shipped files are not touched -- `bootstrap` hashes them byte for byte, comments
# included, and refuses a database built from other bytes.
SCHEMA=$(mktemp -d)
[ -n "$CONTAINER" ] || trap 'rm -rf "$SCHEMA"' EXIT
for f in migrations/*.sql; do
  grep -vxE '\s*(BEGIN|COMMIT);\s*' "$f" > "$SCHEMA/$(basename "$f")"
done

# --role: which role each connector's statements are prepared and planned as. `soma-db` is the
# owner (the scratch database's own user); `soma-runner-db` is `runner_gate`, the narrow role the
# gate's match statements run as, which the migration creates. THAT is the grant boundary with
# Kalam, and this is the only check that proves it.
echo "==> preparing every statement in the set"
orion-server sql check . \
  --schema "$SCHEMA" \
  --database "$DATABASE" \
  --role soma-runner-db=runner_gate

# ---------------------------------------------------------------- the autoscaler's CTEs are pair's
# scripts/autoscaler.sql is not shipped in the package: it is the query a scaler runs to decide how
# many runners the ladder wants. Its answer is only meaningful if it counts demand the way PAIR
# counts it, so its CTE block is pair's, verbatim, with a different final SELECT.
#
# A generator used to paste one into the other. The clocks are authored now, so the rule is checked:
# a change to pair's demand statement is a change to both files. Pair's block closes its WITH with
# `)`; the autoscaler's continues into `, q AS (`, which is the only difference allowed.
echo "==> the autoscaler counts demand exactly as pair does"
python3 - <<'CHECK'
import difflib, pathlib, sys
demand = pathlib.Path("sql/tb-pair-run-demand.sql").read_text()
auto = pathlib.Path("scripts/autoscaler.sql").read_text()
if "\nSELECT json_build_object(" not in demand:
    sys.exit("sql/tb-pair-run-demand.sql: the final `SELECT json_build_object(` split point moved")
for marker in ("WITH live AS (", "\n), q AS ("):
    if marker not in auto:
        sys.exit(f"scripts/autoscaler.sql: the `{marker.strip()}` split point moved")
want = demand.split("\nSELECT json_build_object(")[0].rstrip().rstrip(")").rstrip()
have = auto[auto.index("WITH live AS ("):auto.index("\n), q AS (")].rstrip()
if want != have:
    print("the autoscaler's CTEs are not pair's -- a change to one is a change to both:", file=sys.stderr)
    for line in list(difflib.unified_diff(want.split("\n"), have.split("\n"),
                                          "pair demand", "autoscaler", lineterm="", n=2))[:40]:
        print("  " + line, file=sys.stderr)
    sys.exit(1)
CHECK

# Held to the same schema as everything the package ships. `sql check` sees only the set, so this
# one is prepared by hand against the same scratch schema.
echo "==> preparing scripts/autoscaler.sql"
psql "$DATABASE" -q -v ON_ERROR_STOP=1 > /dev/null <<SQL
BEGIN;
$(cat "$SCHEMA"/0001_init.sql "$SCHEMA"/0002_sessions.sql)
PREPARE chk_autoscaler AS
$(cat scripts/autoscaler.sql);
ROLLBACK;
SQL

echo "==> all shipped SQL parses, plans and is within its role's grants"
