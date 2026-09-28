#!/usr/bin/env bash
# GIVE EVERY MATCH PLAYED BEFORE THE REDESIGN ITS LAST FRAME, so its card draws the end of the match
# rather than an empty board. After the cutover, with the new node serving; safe while the site is up,
# and idempotent (a match that has a frame is skipped, and the insert is ON CONFLICT DO NOTHING).
#
#   WEB_IMAGE=<new web image> scripts/cutover/backfill-frames.sh "$SOMA_DB_URL" http://soma:8080
#   WEB_IMAGE=... scripts/cutover/backfill-frames.sh "$SOMA_DB_URL" http://soma:8080 --check
#
# --check decodes the matches that DO have a frame instead and compares: every one must be equal to
# what the runner sent. That is the proof the backfill writes what a runner would have.
#
# The viewer is taken from WEB_IMAGE (the bytes the site serves; VIZ_DIR overrides with a directory
# holding engine.js), each replay through soma's own GET /v1/matches/{id} and its signed replay_url,
# newest match first. Environment: DOCKER_NETWORK (default host), LIMIT (default all),
# PSQL_IMAGE (postgres:16-alpine), NODE_IMAGE (node:22-alpine; `local` runs this machine's node,
# for a stack whose signed replay URLs name a host port).
set -euo pipefail
cd "$(dirname "$0")"
DB="${1:?usage: backfill-frames.sh <soma db url> <soma base url> [--check]}"
API="${2:?usage: backfill-frames.sh <soma db url> <soma base url> [--check]}"
MODE="${3:-write}"
DOCKER_NETWORK="${DOCKER_NETWORK:-host}"
PSQL_IMAGE="${PSQL_IMAGE:-postgres:16-alpine}"
NODE_IMAGE="${NODE_IMAGE:-node:22-alpine}"
LIMIT="${LIMIT:-ALL}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if [ -n "${VIZ_DIR:-}" ]; then
  cp -R "$VIZ_DIR/." "$work/viz/" 2>/dev/null || { mkdir -p "$work/viz"; cp -R "$VIZ_DIR/." "$work/viz/"; }
else
  : "${WEB_IMAGE:?WEB_IMAGE is required -- the web image whose viewer the site serves (or VIZ_DIR)}"
  cid=$(docker create "$WEB_IMAGE")
  src=$(docker run --rm --entrypoint sh "$WEB_IMAGE" -c 'dirname "$(find / -path /proc -prune -o -name engine.js -path "*cartridges/ants*" -print 2>/dev/null | head -1)"')
  mkdir -p "$work/viz" && docker cp "$cid:$src/." "$work/viz/" > /dev/null
  docker rm "$cid" > /dev/null
fi
cp backfill-frames.mjs "$work/"

psql_() { docker run --rm -i --network "$DOCKER_NETWORK" -v "$work:/w" "$PSQL_IMAGE" psql "$DB" -X -q -At -v ON_ERROR_STOP=1 "$@"; }

if [ "$MODE" = "--check" ]; then
  which="EXISTS (SELECT 1 FROM match_frames f WHERE f.match_id = m.id)"
else
  which="NOT EXISTS (SELECT 1 FROM match_frames f WHERE f.match_id = m.id)"
fi
psql_ -c "SELECT m.id FROM matches m WHERE m.status = 'rated' AND $which ORDER BY m.played_at DESC LIMIT $LIMIT" > "$work/ids"
echo "==> $(wc -l < "$work/ids" | tr -d ' ') match(es) to decode ($( [ "$MODE" = "--check" ] && echo 'checking stored frames' || echo 'writing missing frames'))"

if [ "$NODE_IMAGE" = "local" ]; then
  node "$work/backfill-frames.mjs" "$work/viz" "$API" < "$work/ids" > "$work/frames.ndjson"
else
  docker run --rm -i --network "$DOCKER_NETWORK" -v "$work:/w" -w /w "$NODE_IMAGE" \
    node backfill-frames.mjs /w/viz "$API" < "$work/ids" > "$work/frames.ndjson"
fi

psql_ -v mode="$MODE" <<'SQL'
CREATE TEMP TABLE got (j jsonb);
\copy got (j) FROM '/w/frames.ndjson' WITH (FORMAT csv, QUOTE E'\x01', DELIMITER E'\x02')
SELECT '    skipped: ' || count(*) || coalesce(' (' || string_agg(DISTINCT j ->> 'skip', '; ') || ')', '')
  FROM got WHERE j ? 'skip';
SELECT :'mode' = '--check' AS checking \gset
\if :checking
SELECT '    equal to the runner''s: ' || count(*) FILTER (WHERE f.frame = g.j -> 'frame' AND f.turn = (g.j ->> 'turn')::int)
       || ', different: ' || count(*) FILTER (WHERE f.frame <> g.j -> 'frame' OR f.turn <> (g.j ->> 'turn')::int)
  FROM got g JOIN match_frames f ON f.match_id = (g.j ->> 'match_id')::uuid
 WHERE NOT g.j ? 'skip';
\else
WITH ins AS (
  INSERT INTO match_frames (match_id, turn, frame)
  SELECT m.id, (g.j ->> 'turn')::int, g.j -> 'frame'
    FROM got g JOIN matches m ON m.id = (g.j ->> 'match_id')::uuid AND m.turns = (g.j ->> 'turn')::int
   WHERE NOT g.j ? 'skip'
  ON CONFLICT (match_id) DO NOTHING
  RETURNING 1)
SELECT '    written: ' || count(*) FROM ins;
\endif
SQL
