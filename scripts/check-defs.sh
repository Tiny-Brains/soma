#!/usr/bin/env bash
# Every check that reads the definitions and nothing else. No database, no stack, no Docker --
# so this is the one to run on every change and the one a CI job runs first.
#
#   ./scripts/check-defs.sh
#
# Three gates, and they do not overlap:
#
#   lint     the set resolves -- every reference, every function input schema, every declared
#            env var. `--deny-warnings` because a warning here is a definition that will not
#            behave as written.
#   clippy   what lint cannot prove but can be certain of: a run of steps repeating one
#            condition, an object copied across the set, an input key the function ignores.
#            IT FOUND A REAL BUG: `channel_call` silently ignores an unknown input key, so
#            jodi's admit walk called tb-probe with `body` instead of `data` and every
#            submission stalled on PROBE_UNREACHABLE. That is why it runs with --deny-warnings.
#   fmt      the house style, so a diff is the change and not a reformat.
#
# What this does NOT check is whether the SQL inside those definitions resolves against the
# schema -- that is ./scripts/check-sql.sh, which needs the database.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v orion-server > /dev/null || {
  echo "orion-server is not on PATH -- this repo is an Orion 1.8.1 package and the binary is its compiler" >&2
  exit 1
}

have=$(orion-server --version | head -1 | awk '{print $2}')
case "$have" in
  1.8.*) ;;
  *) echo "orion-server $have is not 1.8.x: it does not understand this package's blocks and will report misleading schema errors" >&2; exit 1 ;;
esac

echo "==> lint"
orion-server lint . --deny-warnings 

echo "==> clippy"
orion-server clippy . --deny-warnings 

echo "==> fmt"
orion-server fmt --check .

echo "==> Soma's definitions are clean"
