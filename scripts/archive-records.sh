#!/usr/bin/env bash
# KEEP EVERY CLOSED SEASON'S RECORD OUTSIDE THE DATABASE. A closed season is read from its record
# (season_records and its tables), which nothing ever changes; this copies each one, through the
# public route that serves it, to a directory -- and, with --r2, to the bucket -- so the season
# outlives the database it was written in.
#
#   scripts/archive-records.sh <dir> [--base https://tinybrains.dev] [--game ants] [--r2 <bucket>]
#
# Each record lands at <dir>/<game>/<slug>/record-r<revision>.json, exactly as served, and
# <dir>/SHA256SUMS lists the sha256 of each file's CANONICAL form (keys sorted, no whitespace), so
# a later copy of the same record -- fetched again, or from the bucket -- can be compared whatever
# serializer wrote it. A file already archived is fetched again and compared, never overwritten:
# a record whose canonical digest changed is reported and the run fails, since a record that moved
# is the one thing that must never happen. --r2 uploads each new file with `wrangler r2 object put`
# to records/<game>/<slug>/record-r<revision>.json (wrangler must be signed in to the account).
# Production's `records/` is under an indefinite R2 lock, so an object already there is never
# replaced: keep <dir> (it is how this script knows what it uploaded), or a re-upload is refused.
# Reads only public routes; a private season is not archived here.
set -euo pipefail
DIR="${1:?usage: archive-records.sh <dir> [--base URL] [--game SLUG] [--r2 BUCKET]}"
shift
BASE=https://tinybrains.dev GAME=ants R2=
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --game) GAME="$2"; shift 2 ;;
    --r2)   R2="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -z "$R2" ] || command -v wrangler > /dev/null || { echo "--r2 needs wrangler on PATH" >&2; exit 1; }
mkdir -p "$DIR"

canon() { python3 -c 'import json,sys,hashlib; d=json.load(open(sys.argv[1])); print(hashlib.sha256(json.dumps(d["record"],sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()).hexdigest())' "$1"; }

slugs=$(curl -fsS "$BASE/v1/games/$GAME/seasons" | python3 -c 'import json,sys; print("\n".join(s["slug"] for s in json.load(sys.stdin) if s.get("closed_at")))')
[ -n "$slugs" ] || { echo "no closed season of $GAME at $BASE"; exit 0; }

failed=0
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
for slug in $slugs; do
  curl -fsS "$BASE/v1/games/$GAME/seasons/$slug/record" -o "$tmp"
  rev=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["record"]["revision"])' "$tmp")
  rel="$GAME/$slug/record-r$rev.json"
  sum=$(canon "$tmp")
  if [ -f "$DIR/$rel" ]; then
    if [ "$(canon "$DIR/$rel")" = "$sum" ]; then
      echo "  same     $rel"
    else
      echo "  MOVED    $rel -- the record served now differs from the one archived" >&2
      failed=1
    fi
    continue
  fi
  mkdir -p "$DIR/$GAME/$slug"
  cp "$tmp" "$DIR/$rel"
  echo "$sum  $rel" >> "$DIR/SHA256SUMS"
  echo "  archived $rel  sha256:${sum:0:12}"
  if [ -n "$R2" ]; then
    wrangler r2 object put "$R2/records/$rel" --file "$DIR/$rel" --content-type application/json --remote > /dev/null
    echo "           r2://$R2/records/$rel"
  fi
done
exit $failed
