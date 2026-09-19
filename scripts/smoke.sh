#!/usr/bin/env bash
# Call every route the package ships and check the status code.
#
#   soma/scripts/smoke.sh            # needs web's local stack up and the package loaded
#
# check-sql.sh proves every statement parses and plans; this proves the workflows around them
# answer, which a package load alone does not. It is a status-code suite, not a behaviour one:
# what a route MEANS is scripts/verify/run.sh's walk.
#
# The session it uses is a real row in `sessions` and a real HS256 cookie, minted here and revoked
# at the end -- there is no way to sign in with GitHub from a script, and asserting anything about
# an authed route without one would be asserting the 401.
#
#   BASE            where the API answers          (default http://127.0.0.1:8080)
#   SMOKE_HANDLE    an existing competitor         (default codetiger)
#   DB_CONTAINER    the postgres container         (default tinybrains-db-1)
#   SOMA_ENV_FILE   whatever holds SOMA_SESSION_SECRET (default ../web/.env, the local stack's)
set -uo pipefail
cd "$(dirname "$0")/.."

BASE="${BASE:-http://127.0.0.1:8080}"
HANDLE="${SMOKE_HANDLE:-codetiger}"
DB_CONTAINER="${DB_CONTAINER:-tinybrains-db-1}"
ENV_FILE="${SOMA_ENV_FILE:-../web/.env}"
DB_USER="${DB_USER:-$(docker exec "$DB_CONTAINER" printenv POSTGRES_USER)}"
psql() { docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_USER" -qtAX "$@"; }

pass=0; fail=0
check() { # check <expected> <name> <curl args...>
  local want="$1" name="$2"; shift 2
  local got; got=$(curl -sS -o /dev/null -w '%{http_code}' "$@")
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf '  ok   %-46s %s\n' "$name" "$got"
  else fail=$((fail+1)); printf '  FAIL %-46s got %s, wanted %s\n' "$name" "$got" "$want"; fi
}

SECRET=$(grep '^SOMA_SESSION_SECRET=' "$ENV_FILE" | cut -d= -f2-)
UID_=$(psql -c "SELECT id FROM users WHERE handle='$HANDLE';")
[ -n "$UID_" ] || { echo "no such user: $HANDLE"; exit 1; }
SID=$(psql -c "INSERT INTO sessions (sid,user_id,expires_at,user_agent) VALUES (gen_random_uuid(),'$UID_',now()+interval '10 minutes','soma smoke.sh') RETURNING sid;")
TOKEN=$(python3 - "$SECRET" "$UID_" "$SID" "$HANDLE" <<'PY'
import base64, hashlib, hmac, json, sys, time
secret, sub, sid, handle = sys.argv[1:5]
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b'=').decode()
h = b64(json.dumps({"alg":"HS256","typ":"JWT"},separators=(',',':')).encode()); now = int(time.time())
p = b64(json.dumps({"sub":sub,"handle":handle,"sid":sid,"iss":"soma","iat":now,"exp":now+600},separators=(',',':')).encode())
print(f"{h}.{p}.{b64(hmac.new(secret.encode(), f'{h}.{p}'.encode(), hashlib.sha256).digest())}")
PY
)
C=(-H "Cookie: soma_session=$TOKEN")

# PATCH /v1/me with no fields clears the display name, so it is put back on the way out along with
# the session: a status-code suite must not leave a mark on the account it borrowed.
NAME=$(psql -c "SELECT coalesce(display_name,'') FROM users WHERE handle='$HANDLE';")
restore() {
  curl -sS -o /dev/null -X PATCH "${C[@]}" -H 'content-type: application/json' \
       -d "$(python3 -c 'import json,sys; print(json.dumps({"display_name": sys.argv[1] or None}))' "$NAME")" \
       "$BASE/v1/me"
  psql -c "UPDATE sessions SET revoked_at = now() WHERE sid='$SID';" > /dev/null
}
trap restore EXIT

GAME=$(curl -sS "$BASE/v1/games" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')
# `models` HAS NO status COLUMN: a model is a row, and the life cycle belongs to its versions.
# This asked for `models.status` and got an ERROR, so MODEL was empty and the two checks that use
# it failed as a 400 and a 401 -- neither of which is what they were testing.
MODEL=$(psql -c "SELECT m.id FROM models m JOIN model_versions v ON v.model_id = m.id WHERE v.status = 'active' AND m.retired_at IS NULL LIMIT 1;")
# The model read is addressed BY ID again: `/v1/games/{game}/models/{owner}/{repo}` went with the
# repository, and an entry is a name that never has to survive a URL.
MODEL_ID=$(psql -c "SELECT m.id FROM models m JOIN model_versions v ON v.model_id = m.id WHERE v.status = 'active' AND m.retired_at IS NULL LIMIT 1;")
MATCH=$(psql -c "SELECT id FROM matches WHERE status IN ('finished','rated') LIMIT 1;")
# The season every season-scoped check names, by its slug (N28): the newest one.
SEASON=$(psql -c "SELECT s.slug FROM seasons s JOIN games g ON g.id = s.game_id WHERE g.slug = '$GAME' ORDER BY s.number DESC LIMIT 1;")
# Nothing seeds one: without it every season-scoped check would name `/seasons//...` and fail as a 404.
[ -n "$SEASON" ] || { echo "no season for $GAME -- create one on the admin page, then re-run"; exit 1; }

echo "==> public reads"
check 200 "GET  /v1/games"                       "$BASE/v1/games"
check 200 "GET  /v1/games/{game}"                "$BASE/v1/games/$GAME"
check 404 "GET  /v1/games/{unknown}"             "$BASE/v1/games/no-such-game"
check 200 "GET  /v1/status"                      "$BASE/v1/status"
check 200 "GET  /v1/games/$GAME/seasons"         "$BASE/v1/games/$GAME/seasons"
check 200 "GET  /v1/games/$GAME/leaderboard"     "$BASE/v1/games/$GAME/leaderboard?limit=3"
check 200 "GET  /v1/games/../leaderboard?ladder" "$BASE/v1/games/$GAME/leaderboard?ladder=nano&season=$SEASON"
check 200 "GET  /v1/games/../seasons/{slug}/maps" "$BASE/v1/games/$GAME/seasons/$SEASON/maps?boards=true"
check 404 "GET  ../seasons/{unknown}/maps"       "$BASE/v1/games/$GAME/seasons/no-such-season/maps"
check 404 "GET  ../seasons/{slug}/maps/{unknown}" "$BASE/v1/games/$GAME/seasons/$SEASON/maps/no-such-map"
check 200 "GET  /v1/matches?game="               "$BASE/v1/matches?game=$GAME&limit=3"
check 200 "GET  /v1/matches (filtered)"          "$BASE/v1/matches?game=$GAME&map=basic-tiny-2p&outcome=drawn&ladder=open&limit=2"
check 200 "GET  /v1/matches?players_min=&max="    "$BASE/v1/matches?game=$GAME&players_min=2&players_max=2&limit=2"
check 400 "GET  /v1/matches?players_min=abc"     "$BASE/v1/matches?game=$GAME&players_min=abc"
check 200 "GET  /v1/matches?model="              "$BASE/v1/matches?model=$MODEL&limit=3"
check 200 "GET  /v1/matches?owner="              "$BASE/v1/matches?owner=$HANDLE&limit=3"
check 200 "GET  /v1/matches/{id}"                "$BASE/v1/matches/$MATCH"
check 200 "GET  /v1/models/{id}"                 "$BASE/v1/models/$MODEL_ID"
check 200 "GET  /v1/profiles/{username}"         "$BASE/v1/profiles/$HANDLE"
check 404 "GET  /v1/profiles/{unknown}"          "$BASE/v1/profiles/no-such-competitor"

printf '  '; curl -sS "$BASE/v1/games/$GAME" | python3 -c '
import json,sys
d=json.load(sys.stdin); a=d.get("about")
b=(d.get("limits") or {}).get("boards") or {}
ok = bool(a and a.get("tagline") and a.get("story") and a.get("links") and b.get("players") and b.get("cells_max"))
print(("ok   " if ok else "FAIL ") + "GET  /v1/games/{game} carries about+limits.boards".ljust(46),
      ("%d paragraphs, %d links, uploads %s seats" % (len(a["story"]), len(a["links"]), b["players"])) if ok else "missing")
sys.exit(0 if ok else 1)' && pass=$((pass+1)) || fail=$((fail+1))

echo "==> anonymous callers are refused the session routes"
check 401 "GET  /v1/me"                          "$BASE/v1/me"
check 401 "POST ../seasons/{slug}/maps (anon)"   -X POST -H 'content-type: application/json' -d '{}' "$BASE/v1/games/$GAME/seasons/$SEASON/maps"
check 401 "GET  ../seasons/{slug}/baselines (anon)" "$BASE/v1/games/$GAME/seasons/$SEASON/baselines"
check 401 "POST ../seasons/{slug}/baselines (anon)" -X POST -H 'content-type: application/json' -d '{}' "$BASE/v1/games/$GAME/seasons/$SEASON/baselines"
check 401 "GET  /v1/me/matches"                  "$BASE/v1/me/matches"
check 401 "GET  /v1/sessions"                    "$BASE/v1/sessions"
check 401 "GET  /v1/me/notifications"            "$BASE/v1/me/notifications"
check 401 "POST /v1/me/notifications/read"       -X POST -H 'content-type: application/json' -d '{"all":true}' "$BASE/v1/me/notifications/read"
check 401 "GET  /v1/me/notification-settings"    "$BASE/v1/me/notification-settings"
check 401 "PATCH /v1/me/notification-settings"   -X PATCH -H 'content-type: application/json' -d '{"category":"matches"}' "$BASE/v1/me/notification-settings"
check 401 "GET  /v1/games/$GAME/submission"      "$BASE/v1/games/$GAME/submission"
check 401 "POST /v1/submissions"                 -X POST -H 'content-type: application/json' -d '{}' "$BASE/v1/submissions"
check 401 "GET  /v1/runner-keys"                  "$BASE/v1/runner-keys"
check 401 "GET  /v1/runners"                     "$BASE/v1/runners"
check 401 "GET  /v1/admin/users"                 "$BASE/v1/admin/users"
check 401 "PATCH /v1/admin/users/{id}"           -X PATCH -H 'content-type: application/json' -d '{"role":"admin"}' "$BASE/v1/admin/users/00000000-0000-0000-0000-000000000000"

echo "==> the runner routes refuse an anonymous caller and a session cookie alike"
# The runner family verifies a BEARER token with aud 'runner', signed with a different secret, so a
# browser session is not a runner -- which is the whole reason the audience is there. Both answer
# 401 rather than 403: the caller's move in each case is to present a runner token.
check 401 "POST /v1/runner/claim (anonymous)"    -X POST -H 'content-type: application/json' -d '{}' "$BASE/v1/runner/claim"
check 401 "POST /v1/runner/claim (session)"      -X POST "${C[@]}" -H 'content-type: application/json' -d '{}' "$BASE/v1/runner/claim"
check 401 "GET  /v1/runner/roster (session)"     "${C[@]}" "$BASE/v1/runner/roster"
check 400 "POST /v1/runner/token (no key)"       -X POST -H 'content-type: application/json' -d '{}' "$BASE/v1/runner/token"
check 401 "POST /v1/runner/token (bad key)"      -X POST -H 'content-type: application/json' \
          -d '{"key":"tbr_nope_nope","label":"smoke"}' "$BASE/v1/runner/token"

echo "==> the admit walk's probe is closed to HTTP"
# The admit clock reaches tb-probe in-process, which Orion never holds to the channel's auth; an
# HTTP caller always is, and nothing mints a token for the probe's audience.
check 401 "POST /internal/probe/adapter (anon)"  -X POST -H 'content-type: application/json' -d '{}' "$BASE/internal/probe/adapter"
check 401 "POST /internal/probe/adapter (session)" -X POST "${C[@]}" -H 'content-type: application/json' -d '{}' "$BASE/internal/probe/adapter"

echo "==> session routes"
check 200 "GET  /v1/me"                          "${C[@]}" "$BASE/v1/me"
check 200 "GET  /v1/me/matches"                  "${C[@]}" "$BASE/v1/me/matches?limit=3"
check 200 "GET  /v1/sessions"                    "${C[@]}" "$BASE/v1/sessions"
check 200 "GET  /v1/models"                      "${C[@]}" "$BASE/v1/models?game=$GAME"
check 200 "GET  /v1/games/$GAME/submission"      "${C[@]}" "$BASE/v1/games/$GAME/submission"
check 404 "GET  /v1/games/{unknown}/submission"  "${C[@]}" "$BASE/v1/games/no-such-game/submission"
check 200 "PATCH /v1/me"                         -X PATCH "${C[@]}" -H 'content-type: application/json' -d '{}' "$BASE/v1/me"
check 400 "PATCH /v1/me (name too long)"         -X PATCH "${C[@]}" -H 'content-type: application/json' \
          -d "{\"display_name\":\"$(python3 -c 'print("x"*61)')\"}" "$BASE/v1/me"
check 400 "POST /v1/submissions (no hashes)"     -X POST "${C[@]}" -H 'content-type: application/json' \
          -d "{\"game\":\"$GAME\",\"model\":\"00000000-0000-0000-0000-000000000000\"}" "$BASE/v1/submissions"
check 404 "DELETE /v1/sessions/{unknown}"        -X DELETE "${C[@]}" "$BASE/v1/sessions/00000000-0000-0000-0000-000000000000"

echo "==> notifications"
# NOTHING HERE MAY LEAVE A MARK on the borrowed account: the read marks an id nobody holds, and the
# settings PATCH that answers 200 names a category and nothing to change, which writes no row. The
# refusals are all refused before or instead of a write.
check 200 "GET  /v1/me/notifications"            "${C[@]}" "$BASE/v1/me/notifications?limit=3"
check 200 "GET  /v1/me/notifications (filtered)" "${C[@]}" "$BASE/v1/me/notifications?category=matches&unread=true&since=2026-01-01T00:00:00Z"
check 400 "GET  /v1/me/notifications?category=?" "${C[@]}" "$BASE/v1/me/notifications?category=no-such-category"
check 200 "POST /v1/me/notifications/read"       -X POST "${C[@]}" -H 'content-type: application/json' \
          -d '{"ids":["00000000-0000-0000-0000-000000000000"]}' "$BASE/v1/me/notifications/read"
check 400 "POST /v1/me/notifications/read (none)" -X POST "${C[@]}" -H 'content-type: application/json' -d '{}' "$BASE/v1/me/notifications/read"
check 200 "GET  /v1/me/notification-settings"    "${C[@]}" "$BASE/v1/me/notification-settings"
check 200 "PATCH /v1/me/notification-settings"   -X PATCH "${C[@]}" -H 'content-type: application/json' \
          -d '{"category":"matches"}' "$BASE/v1/me/notification-settings"
check 409 "PATCH ../notification-settings (locked)" -X PATCH "${C[@]}" -H 'content-type: application/json' \
          -d '{"category":"account","app":false}' "$BASE/v1/me/notification-settings"
check 400 "PATCH ../notification-settings (unknown)" -X PATCH "${C[@]}" -H 'content-type: application/json' \
          -d '{"category":"no-such-category","app":true}' "$BASE/v1/me/notification-settings"
check 400 "PATCH ../notification-settings (level)" -X PATCH "${C[@]}" -H 'content-type: application/json' \
          -d '{"category":"ratings","level":"all"}' "$BASE/v1/me/notification-settings"
check 400 "PATCH ../notification-settings (type)" -X PATCH "${C[@]}" -H 'content-type: application/json' \
          -d '{"category":"matches","app":"yes"}' "$BASE/v1/me/notification-settings"

echo "==> admin routes reach their own checks"
ROLE=$(psql -c "SELECT role FROM users WHERE handle='$HANDLE';")
if [ "$ROLE" = "admin" ]; then
  check 404 "PATCH /v1/games/../seasons/{unknown}" -X PATCH "${C[@]}" -H 'content-type: application/json' -d '{}' "$BASE/v1/games/$GAME/seasons/no-such-season"
  check 400 "PATCH ../seasons/{slug} (rename)"   -X PATCH "${C[@]}" -H 'content-type: application/json' -d '{"name":"Other"}' "$BASE/v1/games/$GAME/seasons/$SEASON"
  check 400 "POST /v1/games/../seasons (no name)" -X POST "${C[@]}" -H 'content-type: application/json' \
            -d '{"submissions_open_at":"2030-01-01T00:00:00Z","submissions_close_at":"2030-03-01T00:00:00Z"}' "$BASE/v1/games/$GAME/seasons"
  check 409 "POST /v1/games/../seasons"          -X POST "${C[@]}" -H 'content-type: application/json' \
            -d '{"name":"Smoke 2030","submissions_open_at":"2030-01-01T00:00:00Z","submissions_close_at":"2030-03-01T00:00:00Z"}' "$BASE/v1/games/$GAME/seasons"
  check 400 "POST ../seasons/{slug}/maps (header)" -X POST "${C[@]}" -H 'content-type: application/json' -d '{"id":"x"}' "$BASE/v1/games/$GAME/seasons/$SEASON/maps"
  check 400 "PATCH ../maps/{id} (no state)"      -X PATCH "${C[@]}" -H 'content-type: application/json' -d '{}' "$BASE/v1/games/$GAME/seasons/$SEASON/maps/no-such-map"
  check 404 "PATCH ../maps/{unknown}"            -X PATCH "${C[@]}" -H 'content-type: application/json' -d '{"enabled":false}' "$BASE/v1/games/$GAME/seasons/$SEASON/maps/no-such-map"
  check 200 "GET  ../seasons/{slug}/baselines"   "${C[@]}" "$BASE/v1/games/$GAME/seasons/$SEASON/baselines"
  check 404 "GET  ../seasons/{unknown}/baselines" "${C[@]}" "$BASE/v1/games/$GAME/seasons/no-such-season/baselines"
  check 400 "POST ../baselines (unusable name)"  -X POST "${C[@]}" -H 'content-type: application/json' \
            -d '{"name":"!!","weights_hash":"sha256:x","manifest_hash":"sha256:y"}' "$BASE/v1/games/$GAME/seasons/$SEASON/baselines"
  check 400 "POST ../baselines (no hashes)"      -X POST "${C[@]}" -H 'content-type: application/json' \
            -d '{"name":"smoke"}' "$BASE/v1/games/$GAME/seasons/$SEASON/baselines"
  check 400 "PATCH ../baselines/{slug} (no state)" -X PATCH "${C[@]}" -H 'content-type: application/json' -d '{}' "$BASE/v1/games/$GAME/seasons/$SEASON/baselines/no-such-baseline"
  check 404 "PATCH ../baselines/{unknown}"       -X PATCH "${C[@]}" -H 'content-type: application/json' -d '{"enabled":false}' "$BASE/v1/games/$GAME/seasons/$SEASON/baselines/no-such-baseline"
  check 200 "GET  /v1/runner-keys"               "${C[@]}" "$BASE/v1/runner-keys"
  check 200 "GET  /v1/runners"                   "${C[@]}" "$BASE/v1/runners"
  check 200 "PATCH ../notification-settings (admin)" -X PATCH "${C[@]}" -H 'content-type: application/json' \
            -d '{"category":"admin"}' "$BASE/v1/me/notification-settings"
  check 400 "POST /v1/runner-keys (no label)"    -X POST "${C[@]}" -H 'content-type: application/json' -d '{}' "$BASE/v1/runner-keys"
  check 404 "DELETE /v1/runner-keys/{unknown}"   -X DELETE "${C[@]}" "$BASE/v1/runner-keys/00000000-0000-0000-0000-000000000000"
  check 404 "DELETE /v1/runners/{unknown}"       -X DELETE "${C[@]}" "$BASE/v1/runners/00000000-0000-0000-0000-000000000000"
  # Role changes: every one of these is refused before it writes, so the run leaves no role changed.
  check 200 "GET  /v1/admin/users"               "${C[@]}" "$BASE/v1/admin/users"
  check 200 "GET  /v1/admin/users?q="            "${C[@]}" "$BASE/v1/admin/users?q=smoke"
  check 400 "PATCH /v1/admin/users/{id} (role?)" -X PATCH "${C[@]}" -H 'content-type: application/json' -d '{"role":"owner"}' "$BASE/v1/admin/users/$UID_"
  check 409 "PATCH /v1/admin/users/{yourself}"   -X PATCH "${C[@]}" -H 'content-type: application/json' -d '{"role":"competitor"}' "$BASE/v1/admin/users/$UID_"
  check 404 "PATCH /v1/admin/users/{unknown}"    -X PATCH "${C[@]}" -H 'content-type: application/json' -d '{"role":"admin"}' "$BASE/v1/admin/users/00000000-0000-0000-0000-000000000000"

  # THE ROUND TRIP, and it is the only check here that proves the DEPLOYMENT rather than the
  # package: mint a key, exchange it, claim with the token. Every check above answers 401 or 404
  # from the channel's auth or its router, which a node with no RUNNER_TOKEN_SECRET and none of the
  # gate's [vars] passes just as happily -- the routes load, and then every real call is a 500. So
  # this is what says the wiring is done.
  KEY=$(curl -sS -X POST "${C[@]}" -H 'content-type: application/json' \
             -d '{"label":"smoke"}' "$BASE/v1/runner-keys" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("key",""))' 2>/dev/null || true)
  if [ -n "$KEY" ]; then
    check 201 "POST /v1/runner-keys"             -X POST "${C[@]}" -H 'content-type: application/json' \
              -d '{"label":"smoke-2"}' "$BASE/v1/runner-keys"
    TOK=$(curl -sS -X POST -H 'content-type: application/json' \
               -d "{\"key\":\"$KEY\",\"label\":\"smoke\",\"arch\":\"amd64\"}" \
               "$BASE/v1/runner/token" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' 2>/dev/null || true)
    if [ -n "$TOK" ]; then
      pass=$((pass+1)); printf '  ok   %-46s %s\n' "POST /v1/runner/token (real key)" "minted"
      got=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H "authorization: Bearer $TOK" \
                 -H 'content-type: application/json' \
                 -d "{\"engine_digest\":\"none\",\"seat_count\":2}" "$BASE/v1/runner/claim")
      # Always 200 now: {"idle": true} when nothing is queued, the row and its contract when
      # something is. A 500 here is the [vars] that are not set.
      if [ "$got" = "200" ]; then
        pass=$((pass+1)); printf '  ok   %-46s %s\n' "POST /v1/runner/claim (real token)" "$got"
      else
        fail=$((fail+1)); printf '  FAIL %-46s got %s, wanted 200\n' "POST /v1/runner/claim (real token)" "$got"
      fi
      # A runner's token is signed with the probe's key but carries the runner's audience.
      check 401 "POST /internal/probe/adapter (runner)" -X POST -H "authorization: Bearer $TOK" \
                -H 'content-type: application/json' -d '{}' "$BASE/internal/probe/adapter"
    else
      fail=$((fail+1)); printf '  FAIL %-46s %s\n' "POST /v1/runner/token (real key)" "no token -- RUNNER_TOKEN_SECRET set?"
    fi
    # Tidy up: the keys this made are real, and a smoke run should not leave the fleet openable.
    psql -c "UPDATE runner_keys SET revoked_at = now() WHERE label LIKE 'smoke%' AND revoked_at IS NULL;" > /dev/null
  else
    fail=$((fail+1)); printf '  FAIL %-46s %s\n' "POST /v1/runner-keys" "no key in the response"
  fi
else
  check 403 "PATCH /v1/games/../seasons/{slug}"  -X PATCH "${C[@]}" -H 'content-type: application/json' -d '{}' "$BASE/v1/games/$GAME/seasons/$SEASON"
  check 403 "POST ../seasons/{slug}/maps"        -X POST "${C[@]}" -H 'content-type: application/json' -d '{}' "$BASE/v1/games/$GAME/seasons/$SEASON/maps"
  check 403 "GET  ../seasons/{slug}/baselines"   "${C[@]}" "$BASE/v1/games/$GAME/seasons/$SEASON/baselines"
  check 403 "POST ../seasons/{slug}/baselines"   -X POST "${C[@]}" -H 'content-type: application/json' -d '{}' "$BASE/v1/games/$GAME/seasons/$SEASON/baselines"
  check 403 "GET  /v1/runner-keys"               "${C[@]}" "$BASE/v1/runner-keys"
  check 403 "GET  /v1/runners"                   "${C[@]}" "$BASE/v1/runners"
  check 403 "GET  /v1/admin/users"               "${C[@]}" "$BASE/v1/admin/users"
  check 403 "PATCH /v1/admin/users/{id}"         -X PATCH "${C[@]}" -H 'content-type: application/json' -d '{"role":"admin"}' "$BASE/v1/admin/users/$UID_"
  check 403 "PATCH ../notification-settings (admin)" -X PATCH "${C[@]}" -H 'content-type: application/json' \
            -d '{"category":"admin"}' "$BASE/v1/me/notification-settings"
fi

echo
echo "==> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
