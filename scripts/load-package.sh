#!/usr/bin/env sh
# Load (or reload) the Soma package into a running orion-server.
#
#   soma/scripts/load-package.sh          # ORION_ADMIN selects the instance
#
# Idempotent: it deletes every object tagged pkg:soma before re-creating the package. That matters
# because an ACTIVE workflow is immutable in Orion -- a second POST is a conflict, and PUT answers
# "404 No draft version found" until you POST .../versions first. The sweep is BY TAG rather than
# by the files present, so a channel the package no longer ships does not linger active and hold
# its route.
#
# Environment:
#   ORION_ADMIN             admin API base (default http://127.0.0.1:8080/api/v1/admin)
#   ORION_ADMIN_API_KEY     sent as a bearer token when admin_auth is enabled
#   SOMA_ALLOW_PRIVATE_DB   1 to set allow_private_urls on the database connector
#
# Everything else that varies by environment is read by the definitions themselves: the GitHub
# client id and secret as env:// from the sign-in channel, and the app URL, callback and cookie
# policy as [vars] in the instance config.
set -eu

ADMIN="${ORION_ADMIN:-http://127.0.0.1:8080/api/v1/admin}"
ALLOW_PRIVATE="${SOMA_ALLOW_PRIVATE_DB:-0}"

cd "$(dirname "$0")/.."

AUTH=""
[ -n "${ORION_ADMIN_API_KEY:-}" ] && AUTH="Authorization: Bearer ${ORION_ADMIN_API_KEY}"

curl_admin() {
  if [ -n "$AUTH" ]; then curl -sS -H "$AUTH" "$@"; else curl -sS "$@"; fi
}
req() { curl_admin --fail-with-body "$@"; }

# jq where available, python3 otherwise -- the host has python3, the image has jq, neither has both.
if command -v jq > /dev/null 2>&1; then
  field() { jq -r ".$2" "$1"; }
  ids() { jq -r ".data[].$1"; }
  with_private_urls() { jq '.config.allow_private_urls = true' "$1"; }
  with_url() { jq --arg u "$SUB_URL" '.config.url = $u' "$1"; }
else
  field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
  ids() { python3 -c 'import json,sys; [print(o[sys.argv[1]]) for o in json.load(sys.stdin)["data"]]' "$1"; }
  with_private_urls() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["config"]["allow_private_urls"]=True; print(json.dumps(d))' "$1"; }
  with_url() { python3 -c 'import json,os,sys; d=json.load(open(sys.argv[1])); d["config"]["url"]=os.environ["SUB_URL"]; print(json.dumps(d))' "$1"; }
fi

# Plugins are swept although the package ships none: its two moved to jodi with the clocks that
# call them, and a stale one left active on an instance would still answer.
echo "==> deleting existing pkg:soma objects"
for kind in channels workflows connectors plugins; do
  case "$kind" in
    channels)   key=channel_id ;;
    workflows)  key=workflow_id ;;
    connectors) key=id ;;
    plugins)    key=plugin_id ;;
  esac
  for id in $(req "$ADMIN/$kind?tag=pkg:soma&limit=500" | ids "$key"); do
    curl_admin -X DELETE "$ADMIN/$kind/$id" -o /dev/null || true
    echo "    $kind/$id"
  done
done

echo "==> connectors"
for f in connectors/*.json; do
  id=$(field "$f" id)
  # Orion's SSRF guard refuses to dial a host resolving to a private address, which both
  # localhost:5432 and a compose service name like db:5432 are. The flag is a deployment property,
  # so it is applied here rather than committed in connectors/soma-db.json.
  #
  # github-api's base is substituted for the same reason kalam substitutes the loader's: Orion
  # refuses an env:// reference in an http connector's url, so a deployment that wants to point the
  # ownership check at a stand-in -- which is the only way to exercise soma-models-create end to
  # end without a live GitHub account per case -- has to have it written in here.
  if [ "$id" = "soma-db" ] && [ "$ALLOW_PRIVATE" = "1" ]; then
    with_private_urls "$f" | req -X POST "$ADMIN/connectors" -H 'Content-Type: application/json' --data @- > /dev/null
  elif [ "$id" = "github-api" ] && [ -n "${GITHUB_API_BASE:-}" ]; then
    SUB_URL="$GITHUB_API_BASE" with_url "$f" | req -X POST "$ADMIN/connectors" -H 'Content-Type: application/json' --data @- > /dev/null
  else
    req -X POST "$ADMIN/connectors" -H 'Content-Type: application/json' --data @"$f" > /dev/null
  fi
  echo "    $id"
done

# Workflows before channels: a channel holds its workflow and its route.
echo "==> workflows"
for f in workflows/*.json; do
  id=$(field "$f" workflow_id)
  req -X POST "$ADMIN/workflows" -H 'Content-Type: application/json' --data @"$f" > /dev/null
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

# Through curl_admin: /health's detail -- the plugin list, the quarantined channels -- is gated on
# a valid admin key, so unauthenticated this check would quietly report nothing wrong on a node
# where something is.
echo "==> health"
curl_admin "${ADMIN%/api/v1/admin}/health" | tr ',' '\n' | grep -E 'quarantined|failed_to_load' || true
