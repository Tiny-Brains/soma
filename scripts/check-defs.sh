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
#            An ignored input key is silent at run time and a whole feature stops working, which
#            is why it runs with --deny-warnings.
#   fmt      the house style, so a diff is the change and not a reformat -- over the generated
#            clock files too, which the generator formats as it writes them.
#
# Before all three, the clocks' channels and workflows must equal what scripts/gen-clocks.py
# generates: they are committed, and a hand edit is reverted by the next person who regenerates.
#
# What this does NOT check is whether the SQL inside those definitions resolves against the
# schema -- that is ./scripts/check-sql.sh, which needs the database -- or the plugins' arithmetic,
# which is `cargo test --manifest-path plugins/Cargo.toml`.
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

echo "==> the clock files match scripts/gen-clocks.py"
python3 scripts/gen-clocks.py --check

echo "==> lint"
orion-server lint . --deny-warnings

echo "==> clippy"
orion-server clippy . --deny-warnings 

echo "==> fmt"
orion-server fmt --check .

# ---------------------------------------------------------------- the one-character check
# `auth.source.scheme` IS A LITERAL PREFIX AND THE TRAILING SPACE BELONGS TO IT. Orion strips
# exactly that string, so "Bearer" leaves a leading space on the token and refuses EVERY runner
# with a bare 401 -- the same code as an absent, expired, revoked or wrong-audience token.
#
# NOTHING ABOVE CATCHES IT. "Bearer" is a valid string, so lint, clippy and fmt all pass; the
# smoke checks that assert 401 on the runner routes stay green because they are getting the 401
# they asked for; and a replica goes on minting tokens and claiming nothing, which on the admin
# Runners screen reads as "calling in" with nothing played. It has been lost twice now -- once by
# being typed without the space, once to a `git checkout` of a fix that was not committed yet --
# and the second time it stopped a live fleet for eleven minutes. Hence a check that costs nothing.
echo "==> the Bearer scheme keeps its trailing space"
python3 scripts/check-auth-scheme.py

echo "==> Soma's definitions are clean"
