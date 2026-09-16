#!/usr/bin/env sh
# Load (or reload) the Soma package into a running orion-server.
#
#   soma/scripts/load-package.sh          # ORION_ADMIN selects the instance
#
# `orion-server compile` resolves the set -- the `$from` constants and the `use` fragments in
# shared/soma.json, which the admin API does not accept -- into ONE promotion artifact, and
# `orion-server package apply` stages it, activates it in dependency order, reloads the engine
# once and records a receipt. That replaces the delete-by-tag-then-POST-each-file loop this script
# used to be: apply is idempotent, so an unchanged package is a no-op, and it never takes a route
# down between a DELETE and its POST the way the sweep did.
#
# The version NAMES THE CONTENT (a hash of the staged set), for two reasons: an applied version is
# immutable, so a fixed one would be refused the first time anything changed; and an unchanged
# package re-applies as a no-op, which is what makes `docker compose up` cheap.
#
# Environment:
#   ORION_ADMIN             admin API base (default http://127.0.0.1:8080/api/v1/admin)
#   ORION_ADMIN_API_KEY     admin credential, when admin_auth is enabled
#   SOMA_ALLOW_PRIVATE_DB   1 to set allow_private_urls on the database and models connectors
#   SOMA_CACHE_REDIS_URL    the response cache's Redis; empty keeps the committed literal
#   GITHUB_API_BASE         stand-in for api.github.com, to exercise the ownership check offline
#
# Everything else that varies by environment is read by the definitions themselves: the GitHub
# client id and secret as env:// from the sign-in channel, and the app URL, callback and cookie
# policy as [vars] in the instance config.
set -eu

ADMIN="${ORION_ADMIN:-http://127.0.0.1:8080/api/v1/admin}"
SERVER="${ADMIN%/api/v1/admin}"
STAGE="${TMPDIR:-/tmp}/soma-pkg.$$"
ARTIFACT="$STAGE.json"
trap 'rm -rf "$STAGE" "$ARTIFACT"' EXIT

cd "$(dirname "$0")/.."

AUTH=""
[ -n "${ORION_ADMIN_API_KEY:-}" ] && AUTH="Authorization: Bearer ${ORION_ADMIN_API_KEY}"
curl_admin() {
  if [ -n "$AUTH" ]; then curl -sS -H "$AUTH" "$@"; else curl -sS "$@"; fi
}

# THE DEPLOYMENT'S CONNECTOR SETTINGS, applied to a staged copy of the set rather than committed.
#
# `allow_private_urls` is a BOOLEAN and a connector `url` is SCHEME-CHECKED, and both are validated
# by every offline gate -- lint, clippy, compile, package lint -- BEFORE `var://` references are
# resolved. So neither can be a var:// reference: the definition would run on a node and fail every
# check this repo has. They are applied here, to the staged copy, so the committed package stays
# lintable and carries no deployment's addresses.
#
# Orion's SSRF guard refuses a host resolving to a private address, which both localhost:5432 and a
# compose service name like db:5432 are. soma-cache always needs the opt-out -- its Redis is
# private wherever it runs -- while soma-db and soma-models are per deployment. soma-models signs
# a competitor's upload against the PUBLIC endpoint, so on a laptop 127.0.0.1 is where the browser
# is; a deployment pointing MODELS_PUBLIC_ENDPOINT at an internal name needs the flag too.
PRIVATE=$([ "${SOMA_ALLOW_PRIVATE_DB:-0}" = "1" ] && echo true || echo false)

echo "==> staging the set"
VERSION=$(python3 scripts/stage-set.py . "$STAGE" \
  "soma-cache=allow_private_urls=true" \
  "soma-cache=url=${SOMA_CACHE_REDIS_URL:-}" \
  "soma-db=allow_private_urls=$PRIVATE" \
  "soma-runner-db=allow_private_urls=$PRIVATE" \
  "soma-runner-blobs=allow_private_urls=$PRIVATE" \
  "soma-models=allow_private_urls=$PRIVATE" \
  "github-api=url=${GITHUB_API_BASE:-}")

echo "==> compiling soma@$VERSION"
# Quiet unless it fails: compile's env-reference inventory names the staging directory, which is a
# temporary path, so it is noise here. A failure prints the lot.
if ! out=$(orion-server compile "$STAGE" --name soma --version "$VERSION" -o "$ARTIFACT" 2>&1); then
  printf '%s\n' "$out" >&2
  exit 1
fi

# A route the package no longer ships would otherwise stay active and hold its path: `apply` adds
# and updates, it does not remove. The sweep is the old loader's one irreplaceable half, kept --
# but it now deletes only what the artifact does not carry, instead of everything tagged pkg:soma.
echo "==> retiring objects this package no longer ships"
python3 -c '
import json, sys
a = json.load(open(sys.argv[1]))
for kind, key in (("channels", "channel_id"), ("workflows", "workflow_id"), ("connectors", "id")):
    for e in a.get(kind, []):
        print(kind + "/" + e[key])
' "$ARTIFACT" > "$STAGE.keep"

for kind in channels workflows connectors; do
  case "$kind" in
    channels)   key=channel_id ;;
    workflows)  key=workflow_id ;;
    connectors) key=id ;;
  esac
  # An artifact with NONE of a kind was built without that kind's source, so it cannot say which
  # of them should exist and must not retire any. Sweeping on an empty list would delete every
  # one of them -- which for a package whose components come from another repository's image is
  # the whole engine.
  grep -q "^$kind/" "$STAGE.keep" || continue
  for id in $(curl_admin "$ADMIN/$kind?tag=pkg:soma&limit=500" \
      | python3 -c "import json,sys; [print(o['$key']) for o in json.load(sys.stdin)['data']]"); do
    grep -qx "$kind/$id" "$STAGE.keep" && continue
    curl_admin -X DELETE "$ADMIN/$kind/$id" -o /dev/null || true
    echo "    retired $kind/$id"
  done
done

echo "==> applying"
ORION_ADMIN_TOKEN="${ORION_ADMIN_API_KEY:-}" \
  orion-server package apply -s "$SERVER" -f "$ARTIFACT" | tail -1

# Through curl_admin: /health's detail -- the plugin list, the quarantined channels -- is gated on
# a valid admin key, so unauthenticated this check would quietly report nothing wrong on a node
# where something is.
echo "==> health"
curl_admin "$SERVER/health" | tr ',' '\n' | grep -E 'quarantined|failed_to_load' || true
