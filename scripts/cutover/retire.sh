#!/usr/bin/env bash
# RETIRE, IN ORION'S STATE, WHAT THE NEW PACKAGE NO LONGER SHIPS -- before the new node boots.
#
#   SOMA_IMAGE=<new image> scripts/cutover/retire.sh "$ORION_STATE_DB_URL"            # dry run
#   SOMA_IMAGE=<new image> scripts/cutover/retire.sh "$ORION_STATE_DB_URL" --commit
#
# WHY IT CANNOT WAIT FOR `load-package.sh --prune`. This release renames seven channels
# (`soma-admin-baselines-*` -> `soma-user-baselines-*`, ...) on the SAME routes. A node's boot apply
# never prunes, and Orion refuses to activate a channel on a (method, path) another active channel
# already claims -- so the new node's boot apply stops at the first renamed channel and the node
# exits, again and again. And once a boot apply HAS succeeded, the receipt's current version is the
# new one, so a later `--prune` finds nothing to remove. The retirement has to happen in between:
# with every node stopped, after the old one and before the new one.
#
# What it does is what `package apply --prune` (archive mode) does, done in the state database:
# every ACTIVE channel and workflow tagged `soma` whose id the new artifact does not carry is set
# `archived` (which frees its route), and every such connector is disabled. Nothing another package
# carries is touched (kalam's definitions live in each runner's own state), drafts are left alone,
# and nothing is deleted -- the old rows stay, archived, for the record. Run it after
# `CREATE DATABASE orion_state_pre_cutover TEMPLATE orion_state`, which is the rollback.
#
# Environment: SOMA_IMAGE (required: the image whose package is about to apply), DOCKER_NETWORK
# (default host), PSQL_IMAGE (default postgres:16-alpine).
set -euo pipefail
URL="${1:?usage: retire.sh <orion_state url> [--commit]}"
COMMIT=false
[ "${2:-}" = "--commit" ] && COMMIT=true
: "${SOMA_IMAGE:?SOMA_IMAGE is required -- the image whose package the new node will apply}"
DOCKER_NETWORK="${DOCKER_NETWORK:-host}"
PSQL_IMAGE="${PSQL_IMAGE:-postgres:16-alpine}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "==> the package $SOMA_IMAGE carries"
docker run --rm --entrypoint sh "$SOMA_IMAGE" \
  -c 'orion-server compile /pkg/soma --version content -o /tmp/a.json > /dev/null 2>&1 && cat /tmp/a.json' > "$work/artifact.json"
python3 - "$work/artifact.json" "$work/keep.sql" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
ids = lambda kind, key: sorted(x[key] for x in a.get(kind, []))
ch, wf, co = ids("channels", "channel_id"), ids("workflows", "workflow_id"), ids("connectors", "id")
rows = lambda xs: ",".join("('" + x.replace("'", "''") + "')" for x in xs)
with open(sys.argv[2], "w") as f:
    for name, xs in (("keep_channels", ch), ("keep_workflows", wf), ("keep_connectors", co)):
        f.write(f"CREATE TEMP TABLE {name} (id text PRIMARY KEY);\nINSERT INTO {name} VALUES {rows(xs)};\n")
print(f"    {a['package']['name']} {a['package']['version'][:24]}: {len(ch)} channels, {len(wf)} workflows, {len(co)} connectors")
PY

cat > "$work/retire.sql" <<'SQL'
\set ON_ERROR_STOP on
\i /r/keep.sql
BEGIN;
SELECT to_regclass('public.channels') IS NOT NULL AS is_orion_state \gset
\if :is_orion_state
\else
  \echo 'REFUSED: this is not an Orion state database (no channels table)'
  \quit 3
\endif
\echo '==> retiring (soma-tagged, active, not in the new package):'
WITH r AS (
  UPDATE channels SET status = 'archived', updated_at = now()
   WHERE status = 'active' AND tags_json::jsonb ? 'soma' AND channel_id NOT IN (SELECT id FROM keep_channels)
  RETURNING channel_id)
SELECT '    channel   ' || channel_id FROM r ORDER BY 1;
WITH r AS (
  UPDATE workflows SET status = 'archived', updated_at = now()
   WHERE status = 'active' AND tags_json::jsonb ? 'soma' AND workflow_id NOT IN (SELECT id FROM keep_workflows)
  RETURNING workflow_id)
SELECT '    workflow  ' || workflow_id FROM r ORDER BY 1;
WITH r AS (
  UPDATE connectors SET enabled = false, updated_at = now()
   WHERE enabled AND tags_json::jsonb ? 'soma' AND id NOT IN (SELECT id FROM keep_connectors)
  RETURNING id)
SELECT '    connector ' || id FROM r ORDER BY 1;
\if :commit
  COMMIT;
  \echo '==> COMMITTED'
\else
  ROLLBACK;
  \echo '==> DRY RUN: rolled back, nothing changed'
\endif
SQL

docker run --rm -i --network "$DOCKER_NETWORK" -v "$work:/r:ro" "$PSQL_IMAGE" \
  psql "$URL" -X -q -At -v ON_ERROR_STOP=1 -v commit="$COMMIT" -f /r/retire.sql
