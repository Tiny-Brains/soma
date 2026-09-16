#!/usr/bin/env bash
# PREPARE every statement the package ships, against a schema built from the migrations.
#
#   soma/scripts/check-sql.sh            # needs the db container up
#
# Every endpoint's SQL is written inline in its workflow, so a schema change can break one silently:
# the workflow still loads and the channel only fails when someone calls it. PREPARE resolves every
# relation, column and function and builds a plan, so a typo, a dropped column or a renamed table
# cannot survive it. It earned itself the day the match table became two tables, with two workflows
# still selecting `matches.model_ids`.
#
# It walks INTO TASK GROUPS. The clocks' generator folds each run of tasks sharing a condition into
# a group, and a walker that reads only the top-level list sees 9 of the clocks' 23 statements --
# which is what jodi/scripts/check-sql.sh did from 15 September 2026 until the merge.
#
# What each statement DOES is scripts/verify/run.sh's walk; that a workflow answers at all is
# scripts/smoke.sh.
#
#   DB_CONTAINER  the postgres container   (default tinybrains-db-1)
#   DB_USER       its superuser            (default: read from the container)
set -euo pipefail
cd "$(dirname "$0")/.."

# The clock workflows are generated and committed. A hand edit to one of them is caught here rather
# than reverted by the next person who regenerates -- and it would be checked below as if it shipped.
echo "==> the clock files match scripts/gen-clocks.py"
python3 scripts/gen-clocks.py --check

DB_CONTAINER="${DB_CONTAINER:-tinybrains-db-1}"
DB_USER="${DB_USER:-$(docker exec "$DB_CONTAINER" printenv POSTGRES_USER)}"
SCRATCH=soma_sqlcheck
SQL=$(mktemp)
trap 'rm -f "$SQL"' EXIT
psql() { docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" "$@"; }

psql -d postgres -q -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS $SCRATCH" -c "CREATE DATABASE $SCRATCH" 2>/dev/null
cat migrations/0001_init.sql migrations/0002_sessions.sql \
    | psql -d "$SCRATCH" -q -v ON_ERROR_STOP=1

# Parameter types are left to Postgres: every statement writes its placeholders as ($1)::type, so
# inference has what it needs -- and a statement that stopped doing that would be ambiguous to the
# server too, which is worth failing on.
python3 - workflows/*.json > "$SQL" <<'PY'
import json, sys

def statements(tasks):
    """Every query in the list, descending into task groups."""
    for task in tasks:
        yield from statements(task.get("tasks", []))
        query = task.get("function", {}).get("input", {}).get("query")
        if query:
            yield task["id"], query

# Orion caps a workflow description at 2048 characters and refuses the create past it. Lint says
# so too, but it is cheaper to fail here, beside the statements, than halfway through an apply.
long_descriptions = []
n = 0
for path in sys.argv[1:]:
    doc = json.load(open(path))
    if len(doc.get("description", "")) > 2048:
        long_descriptions.append((path, len(doc["description"])))
    for task_id, query in statements(doc.get("tasks", [])):
        n += 1
        name = f"chk_{doc['workflow_id'].replace('-', '_')}_{task_id.replace('.', '_')}"
        print(rf"\echo '  {doc['workflow_id']} / {task_id}'")
        print(f"PREPARE {name} AS {query};")
print(rf"\echo '-- {n} statements'")
for path, length in long_descriptions:
    print(f"  {path}: description is {length} characters, Orion's limit is 2048", file=sys.stderr)
if long_descriptions:
    sys.exit(f"==> {len(long_descriptions)} workflow description(s) too long")
PY

echo "==> preparing every query in workflows/*.json"
psql -d "$SCRATCH" -q -v ON_ERROR_STOP=1 < "$SQL"

psql -d postgres -q -v ON_ERROR_STOP=1 -c "DROP DATABASE $SCRATCH"
echo "==> all shipped SQL parses and plans against the current schema"
