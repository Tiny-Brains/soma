#!/usr/bin/env bash
# Call every route the package ships and check the status code.
#
#   soma/scripts/smoke.sh            # needs the DevOps stack up and the package loaded
#
# check-sql.sh proves every statement parses and plans; this proves the workflows around them
# answer, which a package load alone does not. It is a status-code suite, not a behaviour one:
# what a route MEANS is scripts/verify/run.sh's walk and the layout studies it feeds.
#
# The session it uses is a real row in `sessions` and a real HS256 cookie, minted here and revoked
# at the end -- there is no way to sign in with GitHub from a script, and asserting anything about
# an authed route without one would be asserting the 401.
#
#   BASE            where the API answers          (default http://127.0.0.1:8080)
#   SMOKE_HANDLE    an existing admin's handle     (default codetiger)
#   DB_CONTAINER    the postgres container         (default tinybrains-db-1)
#   SOMA_ENV_FILE   whatever holds SOMA_SESSION_SECRET (default ../devops/.env)
set -uo pipefail
cd "$(dirname "$0")/.."

BASE="${BASE:-http://127.0.0.1:8080}"
HANDLE="${SMOKE_HANDLE:-codetiger}"
DB_CONTAINER="${DB_CONTAINER:-tinybrains-db-1}"
ENV_FILE="${SOMA_ENV_FILE:-../devops/.env}"
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
trap 'psql -c "UPDATE sessions SET revoked_at = now() WHERE sid='"'"'$SID'"'"';" >/dev/null' EXIT
C=(-H "Cookie: soma_session=$TOKEN")
GAME=$(curl -sS "$BASE/v1/games" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')
MODEL=$(psql -c "SELECT id FROM models WHERE status='active' LIMIT 1;")
MATCH=$(psql -c "SELECT id FROM matches WHERE status IN ('finished','rated') LIMIT 1;")

echo "==> public reads"
check 200 "GET  /v1/games"                       "$BASE/v1/games"
check 200 "GET  /v1/games/{game}"                "$BASE/v1/games/$GAME"
check 404 "GET  /v1/games/{unknown}"             "$BASE/v1/games/no-such-game"
check 200 "GET  /v1/status"                      "$BASE/v1/status"
check 200 "GET  /v1/games/$GAME/seasons"         "$BASE/v1/games/$GAME/seasons"
check 200 "GET  /v1/games/$GAME/leaderboard"     "$BASE/v1/games/$GAME/leaderboard?limit=3"
check 200 "GET  /v1/games/../leaderboard?ladder" "$BASE/v1/games/$GAME/leaderboard?ladder=nano&season=1"
check 200 "GET  /v1/matches?game="               "$BASE/v1/matches?game=$GAME&limit=3"
check 200 "GET  /v1/matches (filtered)"          "$BASE/v1/matches?game=$GAME&preset=maze&outcome=drawn&ladder=open&limit=2"
check 200 "GET  /v1/matches?model="              "$BASE/v1/matches?model=$MODEL&limit=3"
check 200 "GET  /v1/matches?owner="              "$BASE/v1/matches?owner=$HANDLE&limit=3"
check 200 "GET  /v1/matches/{id}"                "$BASE/v1/matches/$MATCH"
check 200 "GET  /v1/models/{id}"                 "$BASE/v1/models/$MODEL"
check 200 "GET  /v1/profiles/{username}"         "$BASE/v1/profiles/$HANDLE"
check 404 "GET  /v1/profiles/{unknown}"          "$BASE/v1/profiles/no-such-competitor"

printf '  '; curl -sS "$BASE/v1/games/$GAME" | python3 -c '
import json,sys
d=json.load(sys.stdin); a=d.get("about")
ok = bool(a and a.get("tagline") and a.get("story") and a.get("links") and d.get("presets"))
print(("ok   " if ok else "FAIL ") + "GET  /v1/games/{game} carries about+presets".ljust(46),
      ("%d paragraphs, %d links, %d presets" % (len(a["story"]), len(a["links"]), len(d["presets"]))) if ok else "missing")
sys.exit(0 if ok else 1)' && pass=$((pass+1)) || fail=$((fail+1))

echo "==> anonymous callers are refused the session routes"
check 401 "GET  /v1/me"                          "$BASE/v1/me"
check 401 "GET  /v1/me/matches"                  "$BASE/v1/me/matches"
check 401 "GET  /v1/sessions"                    "$BASE/v1/sessions"
check 401 "GET  /v1/games/$GAME/submission"      "$BASE/v1/games/$GAME/submission"
check 401 "POST /v1/submissions"                 -X POST -H 'content-type: application/json' -d '{}' "$BASE/v1/submissions"

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
          -d "{\"game\":\"$GAME\",\"repo\":\"a/b\",\"release_tag\":\"v1\"}" "$BASE/v1/submissions"
check 404 "DELETE /v1/sessions/{unknown}"        -X DELETE "${C[@]}" "$BASE/v1/sessions/00000000-0000-0000-0000-000000000000"

echo "==> admin routes reach their own checks"
ROLE=$(psql -c "SELECT role FROM users WHERE handle='$HANDLE';")
if [ "$ROLE" = "admin" ]; then
  check 404 "PATCH /v1/games/../seasons/99"      -X PATCH "${C[@]}" -H 'content-type: application/json' -d '{}' "$BASE/v1/games/$GAME/seasons/99"
  check 409 "POST /v1/games/../seasons"          -X POST "${C[@]}" -H 'content-type: application/json' \
            -d '{"submissions_open_at":"2030-01-01T00:00:00Z","submissions_close_at":"2030-03-01T00:00:00Z"}' "$BASE/v1/games/$GAME/seasons"
else
  check 403 "PATCH /v1/games/../seasons/99"      -X PATCH "${C[@]}" -H 'content-type: application/json' -d '{}' "$BASE/v1/games/$GAME/seasons/99"
fi

echo
echo "==> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
