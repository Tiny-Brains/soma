#!/usr/bin/env bash
# The offline regression suite: every *.case.json under tests/, run by `orion-server test` with the
# set's shared definitions. The set carries the two plugins this package ships (plugins/*/plugin.toml
# and their components), so tb.rating and tb.pairing run for real; naming them again with
# --plugin-dir declares each twice and is refused. No database, no stack: a case's connector calls are answered by its stubs, one value
# per connector, so a case shapes one row that satisfies every read on its branch. Since Orion
# 1.10.0 a case runs at a node's cost (no trace, no capture), so a clock's loop is affordable.
#
#   ./scripts/check-tests.sh
#
# RUNNER_TOKEN_SECRET is what the token route's jwt_sign reads (env://); a stand-in is enough
# offline, as check-defs.sh supplies stand-ins for the config's required variables.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v orion-server > /dev/null || { echo "orion-server is not on PATH" >&2; exit 1; }
export RUNNER_TOKEN_SECRET="${RUNNER_TOKEN_SECRET:-check-tests-not-a-secret-but-thirty-two-bytes-long}"
orion-server test tests --definitions .

# tests/with-ants/ names tb.ants functions, and the set carries no tb.ants (the node image takes it
# from the ants release), so those cases need the plugin's directory: TB_ANTS_PLUGIN_DIR, else the
# kalam checkout's copy beside this one, else the ants checkout's dist/. `test` does not recurse,
# so the main run above never sees them. Without a plugin they are skipped, and said so.
ants="${TB_ANTS_PLUGIN_DIR:-}"
for d in "$ants" ../kalam/plugins/tb-ants ../ants/dist; do
  if [ -n "$d" ] && [ -f "$d/plugin.toml" ]; then
    orion-server test tests/with-ants --definitions . --plugin-dir "$d"
    exit 0
  fi
done
echo "note: tests/with-ants skipped -- no tb.ants plugin directory (set TB_ANTS_PLUGIN_DIR)"
