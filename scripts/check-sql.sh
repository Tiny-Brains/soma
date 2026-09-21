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
# closes it: `soma-db-gate` is checked as `runner_gate`, which is the boundary with Kalam.
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
# owner (the scratch database's own user); `soma-db-gate` is `runner_gate`, the narrow role the
# gate's match statements run as, which the migration creates. THAT is the grant boundary with
# Kalam, and this is the only check that proves it.
echo "==> preparing every statement in the set"
orion-server sql check . \
  --schema "$SCHEMA" \
  --database "$DATABASE" \
  --role soma-db-gate=runner_gate

# ---------------------------------------------------------------- the grants a role must NOT have
# `runner_gate` is the one role a runner's statements run as, so a migration that widens it into a
# competitive decision should fail something cheap. soma/scripts/verify/run.sh exercises the same
# properties against a live database, but it needs one, and it exits 0 through a scenario error;
# this does neither.
echo "==> no role reaches a competitive decision"
psql "$DATABASE" -q -v ON_ERROR_STOP=1 > /dev/null <<SQL
BEGIN;
$(cat "$SCHEMA"/*.sql)
DO \$\$
BEGIN
    IF EXISTS (SELECT 1 FROM unnest(ARRAY['status', 'reject_reason', 'admit_token']) c
                WHERE has_column_privilege('runner_gate', 'model_versions', c, 'UPDATE')) THEN
        RAISE EXCEPTION 'runner_gate can write a competitive decision on model_versions';
    END IF;
    IF has_column_privilege('runner_gate', 'matches', 'rated_at', 'UPDATE') THEN
        RAISE EXCEPTION 'runner_gate can write matches.rated_at -- counting is Soma''s';
    END IF;
    IF has_table_privilege('runner_gate', 'ratings', 'SELECT') THEN
        RAISE EXCEPTION 'runner_gate can read ratings';
    END IF;
END
\$\$;
ROLLBACK;
SQL

echo "==> all shipped SQL parses, plans and is within its role's grants"
