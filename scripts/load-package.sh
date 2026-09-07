#!/usr/bin/env sh
# Load (or reload) the Soma package into a running orion-server.
#
# Used by both the host (after `orion-server -c ...`) and the container
# (docker-entrypoint.sh runs it once the server answers /readyz).
#
# It is idempotent: it deletes every object tagged pkg:soma before re-creating the
# package, so it can be re-run after an edit. That matters because an *active*
# workflow is immutable in Orion -- a second POST is a conflict, and PUT answers
# "404 No draft version found" until you POST .../versions first. The sweep is by
# tag rather than by the files present, so a channel the package no longer ships
# does not linger active and hold its route: the 1.6 sign-in channel took over
# /v1/auth/github from the two it replaced exactly that way.
#
# Environment:
#   ORION_ADMIN             admin API base (default http://127.0.0.1:8080/api/v1/admin)
#   ORION_ADMIN_API_KEY     sent as a bearer token when admin_auth is enabled
#   SOMA_ALLOW_PRIVATE_DB   1 to set allow_private_urls on the database connector
#
# Everything else that varies by environment is read by the definitions themselves:
# the GitHub client id and secret as env:// from the sign-in channel; the app URL,
# the OAuth callback URL and whether cookies are Secure as [vars] entries in the
# instance config. The one rewrite above exists because allow_private_urls is a
# deployment property the package should not ship with.
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

# Read one top-level string field out of a definition file. jq where available,
# python3 otherwise -- the host has python3, the image has jq, neither has both.
if command -v jq > /dev/null 2>&1; then
  field() { jq -r ".$2" "$1"; }
  ids() { jq -r ".data[].$1"; }
  with_private_urls() { jq '.config.allow_private_urls = true' "$1"; }
  plugin_body() { jq -n --slurpfile m "$1" --rawfile c "$2" \
      '{plugin_id: $m[0].name, manifest: $m[0], component: ($c | rtrimstr("\n")), tags: ["pkg:soma"]}'; }
else
  field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
  ids() { python3 -c 'import json,sys; [print(o[sys.argv[1]]) for o in json.load(sys.stdin)["data"]]' "$1"; }
  with_private_urls() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["config"]["allow_private_urls"]=True; print(json.dumps(d))' "$1"; }
  plugin_body() { python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(json.dumps({"plugin_id": m["name"], "manifest": m, "component": open(sys.argv[2]).read().strip(), "tags": ["pkg:soma"]}))' "$1" "$2"; }
fi

# Channels first, because a channel holds its workflow and its route; connectors
# last. Every object the package creates carries the tag, so this is the whole
# package, including anything a previous version shipped and this one does not.
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

# Plugins before workflows: a workflow naming a function no plugin provides is quarantined at
# load. Soma ships none today -- its two plugins moved to the jodi package with the clocks that
# call them -- so this loop is a no-op unless a plugins/ directory appears. It is kept because the
# ordering rule is the thing worth not rediscovering.
#
# Every upload lands as a draft and is activated by the PATCH, exactly as a workflow is. Orion
# validates the manifest, compiles the component in the sandbox and probes every declared function
# before the draft row is written, so a create that returns 201 has already proved it loads.
echo "==> plugins"
for f in plugins/*/plugin.json; do
  [ -e "$f" ] || continue
  dir=$(dirname "$f")
  id=$(field "$f" name)
  component=$(field "$f" component)
  # The component reaches the helper as a *file*, never as an argument: base64 of a 100 KiB
  # component is ~133 KiB of text, and passing that as an argv entry is "Argument list too long"
  # on any shell. `-w 0` would do it in one step but is GNU-only, and this script runs on the
  # host too.
  b64file=$(mktemp)
  base64 < "$dir/$component" | tr -d '\n' > "$b64file"
  plugin_body "$f" "$b64file" \
    | req -X POST "$ADMIN/plugins" -H 'Content-Type: application/json' --data @- > /dev/null
  rm -f "$b64file"
  req -X PATCH "$ADMIN/plugins/$id/status" -H 'Content-Type: application/json' \
      -d '{"status":"active"}' > /dev/null
  echo "    $id"
done

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

echo "==> health"
curl -sS "${ADMIN%/api/v1/admin}/health" | tr ',' '\n' | grep -E 'quarantined|failed_to_load' || true
