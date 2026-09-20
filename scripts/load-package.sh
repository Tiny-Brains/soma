#!/usr/bin/env sh
# Apply the Soma package into a running orion-server, from this checkout.
#
#   soma/scripts/load-package.sh                 # ORION_ADMIN selects the node
#   soma/scripts/load-package.sh --prune         # ...and retire what this version no longer ships
#
# A NODE DOES NOT NEED THIS TO BOOT. Its own `[packages] apply` compiles and applies the package in
# the image (docker/soma.toml.tmpl, entrypoint.sh), holding /readyz until it is serving. This script
# is the two things that path is not: applying a WORKING COPY into a node that is already up, and
# `--prune`, which the boot path deliberately does not do.
#
# `orion-server compile` resolves the set -- the `$from` constants, the `use` fragments and the
# `$sql` files -- into ONE artifact carrying the routes, the clocks, the connectors and both wasm
# plugins with their digests, and `package apply` stages it, activates it in dependency order,
# reloads the engine once and records a receipt. Since 1.9.0 it also reads the reloaded generation
# back and FAILS naming anything the reload quarantined, so a package that applied is a package
# that is serving.
#
# WHAT THIS SCRIPT NO LONGER DOES, because Orion 1.9.0 does it:
#
#   a staged copy of the set     connector URLs and booleans are `env://`/`var://` references in the
#                                committed definitions now (#338), so there is nothing to rewrite
#   a content-derived version    `--version content` (#339)
#   patching in signatures       `--signatures` attaches them in memory, leaving the hash alone (#340)
#   a delete-what-is-not-in-it   `--prune` removes what the applied version carried and this one
#     sweep over four kinds      does not, from the receipt's own inventory (#341)
#   reading /health back         `apply` fails on a quarantined member by itself (#342)
#
# Environment:
#   ORION_ADMIN             admin API base (default http://127.0.0.1:8080/api/v1/admin)
#   ORION_ADMIN_API_KEY     admin credential, when admin_auth is enabled
#   PLUGIN_SIG_DIR          detached Ed25519 signatures, named <component>.sig or <plugin id>.sig
#
# Everything else that varies by environment is read by the definitions and the instance config:
# the GitHub client id and secret as env:// from the sign-in channel; the bucket addresses, the
# Redis URL and `allow_private_urls` as references on the connectors; the app URL, callback and
# cookie policy as [vars].
set -eu

ADMIN="${ORION_ADMIN:-http://127.0.0.1:8080/api/v1/admin}"
SERVER="${ADMIN%/api/v1/admin}"
ARTIFACT="${TMPDIR:-/tmp}/soma-pkg.$$.json"
trap 'rm -f "$ARTIFACT"' EXIT

cd "$(dirname "$0")/.."

PRUNE=""
for arg in "$@"; do
  case "$arg" in
    --prune)        PRUNE="--prune" ;;
    --prune=delete) PRUNE="--prune=delete" ;;
    *) echo "usage: load-package.sh [--prune | --prune=delete]" >&2; exit 2 ;;
  esac
done

# The version NAMES THE CONTENT, for two reasons: an applied version is immutable, so a fixed one
# would be refused the first time anything changed; and an unchanged package re-applies as a no-op,
# which is what makes a redeploy cheap. `--name` comes from shared/package.json, which also carries
# the `requires.orion` range compile checks this binary against and writes into the artifact for
# apply to check the node against.
echo "==> compiling"
orion-server compile . --version content -o "$ARTIFACT" | tail -1

# `--prune` is not the default. The boot path applies without it, so a node that came up on a newer
# image keeps anything an older one left; retiring those is this deliberate step, and `plan --prune`
# below is worth reading before it runs on a live ladder.
echo "==> applying${PRUNE:+ (with $PRUNE)}"
ORION_ADMIN_TOKEN="${ORION_ADMIN_API_KEY:-}" \
  orion-server package apply -s "$SERVER" -f "$ARTIFACT" \
    ${PLUGIN_SIG_DIR:+--signatures "$PLUGIN_SIG_DIR"} \
    ${PRUNE:+$PRUNE}
