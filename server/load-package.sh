#!/usr/bin/env sh
# Load (or reload) the Soma package into a running orion-server.
#
# Used by both the host (server/load-package.sh after `orion-server -c ...`) and the
# container (docker-entrypoint.sh runs it once the server answers /health).
#
# It is idempotent: it deletes the package's objects before re-creating them, so it
# can be re-run after an edit. That matters because an *active* workflow is immutable
# in Orion -- a second POST is a conflict, and PUT answers "404 No draft version
# found" until you POST .../versions first.
#
# Environment:
#   ORION_ADMIN             admin API base (default http://127.0.0.1:8080/api/v1/admin)
#   ORION_ADMIN_API_KEY     sent as a bearer token when admin_auth is enabled
#   SOMA_ALLOW_PRIVATE_DB   1 to set allow_private_urls on the database connector
#   SOMA_COOKIE_SECURE      0 to clear the Secure flag on the session and oauth-state
#                           cookies, which is required to sign in over plain http
set -eu

ADMIN="${ORION_ADMIN:-http://127.0.0.1:8080/api/v1/admin}"
ALLOW_PRIVATE="${SOMA_ALLOW_PRIVATE_DB:-0}"
COOKIE_SECURE="${SOMA_COOKIE_SECURE:-1}"

cd "$(dirname "$0")/.."

AUTH=""
[ -n "${ORION_ADMIN_API_KEY:-}" ] && AUTH="Authorization: Bearer ${ORION_ADMIN_API_KEY}"

curl_admin() {
  if [ -n "$AUTH" ]; then curl -sS -H "$AUTH" "$@"; else curl -sS "$@"; fi
}
req() { curl_admin --fail-with-body "$@"; }

# Read one top-level string field out of a definition file. jq where available,
# python3 otherwise -- the host has python3, the image has jq, neither has both.
if command -v jq > /dev/null 2>&1; then
  field() { jq -r ".$2" "$1"; }
  with_private_urls() { jq '.config.allow_private_urls = true' "$1"; }
  without_secure_cookies() { jq '(.. | objects | select(has("secure")) | .secure) |= false' "$1"; }
else
  field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
  with_private_urls() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["config"]["allow_private_urls"]=True; print(json.dumps(d))' "$1"; }
  without_secure_cookies() { python3 -c '
import json, sys
def walk(o):
    if isinstance(o, dict):
        if "secure" in o and isinstance(o["secure"], bool): o["secure"] = False
        for v in o.values(): walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
d = json.load(open(sys.argv[1])); walk(d); print(json.dumps(d))' "$1"; }
fi

echo "==> deleting existing package objects"
for f in channels/*.json;   do curl_admin -X DELETE "$ADMIN/channels/$(field "$f" channel_id)"    -o /dev/null || true; done
for f in workflows/*.json;  do curl_admin -X DELETE "$ADMIN/workflows/$(field "$f" workflow_id)"  -o /dev/null || true; done
for f in connectors/*.json; do curl_admin -X DELETE "$ADMIN/connectors/$(field "$f" id)"          -o /dev/null || true; done

echo "==> connectors"
for f in connectors/*.json; do
  id=$(field "$f" id)
  # Orion's SSRF guard refuses to dial a host resolving to a private address, which
  # both localhost:5432 and a compose service name like db:5432 are. The flag is a
  # deployment property, so it is applied here rather than in connectors/soma-db.json
  # -- the committed package does not ship with the guard disabled.
  if [ "$id" = "soma-db" ] && [ "$ALLOW_PRIVATE" = "1" ]; then
    with_private_urls "$f" | req -X POST "$ADMIN/connectors" -H 'Content-Type: application/json' --data @- > /dev/null
  else
    req -X POST "$ADMIN/connectors" -H 'Content-Type: application/json' --data @"$f" > /dev/null
  fi
  echo "    $id"
done

echo "==> workflows"
for f in workflows/*.json; do
  id=$(field "$f" workflow_id)
  # Orion requires cookie `secure` to be a literal boolean -- a {"var": ...} there is
  # not folded, and the cookie is dropped with only a warning. So the flag cannot be
  # an instance variable and has to be rewritten at load time. Browsers refuse to
  # store a Secure cookie from an http:// origin (Safari always; others depending on
  # host), which silently breaks sign-in: the state cookie never comes back, and no
  # session cookie is ever stored.
  if [ "$COOKIE_SECURE" = "0" ]; then
    without_secure_cookies "$f" | req -X POST "$ADMIN/workflows" -H 'Content-Type: application/json' --data @- > /dev/null
  else
    req -X POST "$ADMIN/workflows" -H 'Content-Type: application/json' --data @"$f" > /dev/null
  fi
  req -X PATCH "$ADMIN/workflows/$id/status" -H 'Content-Type: application/json' -d '{"status":"active"}' > /dev/null
  echo "    $id"
done

echo "==> channels"
for f in channels/*.json; do
  id=$(field "$f" channel_id)
  req -X POST "$ADMIN/channels" -H 'Content-Type: application/json' --data @"$f" > /dev/null
  req -X PATCH "$ADMIN/channels/$id/status" -H 'Content-Type: application/json' -d '{"status":"active"}' > /dev/null
  echo "    $id"
done

echo "==> health"
curl -sS "${ADMIN%/api/v1/admin}/health" | tr ',' '\n' | grep -E 'quarantined|failed_to_load' || true
