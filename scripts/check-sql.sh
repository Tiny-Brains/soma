#!/usr/bin/env bash
# PREPARE every statement the package actually ships, against a schema built from the migrations.
#
#   soma/scripts/check-sql.sh            # needs the db container up
#
# Every read endpoint's SQL is written inline in its workflow, so a schema change can break one
# silently -- the workflow still loads, and the channel only fails when someone calls it. This
# pulls each `query` out of workflows/*.json and asks Postgres to parse and plan it against a
# schema built from the migrations, so the break surfaces in CI instead.
#
# It earned itself the day the match table became two tables: two read workflows were still
# selecting `matches.model_ids`, and nothing else would have noticed until a request arrived.
#
# It is a syntax and planning check, not a behaviour one: PREPARE resolves every relation, column
# and function and builds a plan, so a typo, a dropped column or a renamed table cannot survive it.
# What each statement DOES is design/v2/01-verify/run.sh's walk.
set -euo pipefail
cd "$(dirname "$0")/.."

DB_CONTAINER="${DB_CONTAINER:-tinybrains-db-1}"
DB_USER="${DB_USER:-$(docker exec "$DB_CONTAINER" printenv POSTGRES_USER)}"
SCRATCH=soma_sqlcheck
psql() { docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" "$@"; }

psql -d postgres -q -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS $SCRATCH" -c "CREATE DATABASE $SCRATCH" 2>/dev/null
cat migrations/0001_init.sql migrations/0002_sessions.sql \
    | psql -d "$SCRATCH" -q -v ON_ERROR_STOP=1

# Parameter types are left to Postgres. Every statement writes its placeholders as ($1)::type, so
# inference has everything it needs -- and a statement that ever stopped doing that would be
# ambiguous to the server too, which is worth failing on.
python3 - workflows/*.json > /tmp/soma-sqlcheck.sql <<'PY'
import json, sys

n = 0
for path in sys.argv[1:]:
    doc = json.load(open(path))
    for task in doc.get("tasks", []):
        fn = task.get("function", {})
        query = fn.get("input", {}).get("query")
        if not query:
            continue
        n += 1
        name = f"chk_{doc['workflow_id'].replace('-', '_')}_{task['id']}"
        print(rf"\echo '  {doc['workflow_id']} / {task['id']}'")
        print(f"PREPARE {name} AS {query};")
print(rf"\echo '{n} statements prepared'", file=sys.stderr)
print(rf"\echo '-- {n} statements'")
PY

echo "==> preparing every query in workflows/*.json"
psql -d "$SCRATCH" -q -v ON_ERROR_STOP=1 < /tmp/soma-sqlcheck.sql

rm -f /tmp/soma-sqlcheck.sql
psql -d postgres -q -v ON_ERROR_STOP=1 -c "DROP DATABASE $SCRATCH"
echo "==> all shipped SQL parses and plans against the current schema"
