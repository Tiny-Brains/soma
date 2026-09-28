#!/usr/bin/env bash
# THE REDESIGN'S DATABASE CUTOVER: a v0.7.x database onto this branch's schema, in place, in one
# transaction, with nothing a signed-in competitor would notice -- same accounts and sessions, same
# ladder, same seasons, same runner keys, and the season they land on unchanged.
#
#   scripts/cutover/cutover.sh "$SOMA_DB_URL"            # dry run: every step, then ROLLBACK
#   scripts/cutover/cutover.sh "$SOMA_DB_URL" --commit   # the real one
#
# `bootstrap` refuses a database built from other migration bytes, and this release rewrote them, so
# the database cannot simply be re-bootstrapped. Instead cutover.sql builds the new schema as `v2`
# BESIDE the old `public`, copies every row across (transfer.sql), swaps the two names, derives what
# the new schema adds (backfill.sql), checks what must have been kept (verify.sql), and commits --
# or, on any failure, leaves the database exactly as it was. The old schema stays, renamed `legacy`,
# and rollback.sql puts it back.
#
# The migrations are taken from SOMA_IMAGE when it is set -- the very bytes that image's `bootstrap`
# will hash, so it finds the schema current -- and otherwise from this checkout.
#
# Environment:
#   SOMA_IMAGE       the new soma image (recommended: the release being deployed)
#   FROM_DIGEST      the schema digest the database must be on (default: v0.7.x's)
#   DOCKER_NETWORK   where psql runs from (default: host; `container:<db>` for a local container)
#   PSQL_IMAGE       default postgres:16-alpine, the major version the platform runs
#
# The three steps of this directory, in order, with every node stopped for the first two:
#   cutover.sh          the database (this script)
#   retire.sh           Orion's state: the definitions this release renamed, or the node cannot boot
#   backfill-frames.sh  once the new node serves: the last frame of every match played before it
# The whole production runbook -- what stops first, the env change, the caches -- is the "Cutover"
# section of the platform tracker. The owner of the database runs it (the role in SOMA_DB_URL); it
# needs no superuser.
set -euo pipefail
cd "$(dirname "$0")"

URL="${1:?usage: cutover.sh <database url> [--commit]}"
COMMIT=false
[ "${2:-}" = "--commit" ] && COMMIT=true
FROM_DIGEST="${FROM_DIGEST:-a7d597d5f58756a906d6d49b5ec3fd6941459944fb86bf231a0f48c6d64af9a8}"
DOCKER_NETWORK="${DOCKER_NETWORK:-host}"
PSQL_IMAGE="${PSQL_IMAGE:-postgres:16-alpine}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/migrations" "$work/raw"

if [ -n "${SOMA_IMAGE:-}" ]; then
  echo "==> migrations from $SOMA_IMAGE"
  cid=$(docker create "$SOMA_IMAGE")
  docker cp "$cid:/pkg/soma/migrations/." "$work/raw/" > /dev/null
  docker rm "$cid" > /dev/null
else
  echo "==> migrations from this checkout ($(git -C .. rev-parse --short HEAD 2>/dev/null || echo '?'))"
  cp ../../migrations/*.sql "$work/raw/"
fi

# The digest exactly as entrypoint.sh's schema_digest() computes it: the content, concatenated in
# filename order.
files=$(ls -1 "$work"/raw/*.sql)
if command -v sha256sum > /dev/null; then sum() { sha256sum | cut -d' ' -f1; }; else sum() { shasum -a 256 | cut -d' ' -f1; }; fi
# shellcheck disable=SC2086
TO_DIGEST=$(cat $files | sum)
echo "    $(echo "$files" | xargs -n1 basename | tr '\n' ' ')-> sha256:${TO_DIGEST:0:12}..."

# Each migration is its own transaction; here they run inside the cutover's. Strip exactly the one
# top-level `BEGIN;` and `COMMIT;` each file carries, and refuse a file shaped otherwise rather than
# guess -- a stray COMMIT would end the cutover's transaction halfway.
: > "$work/apply.sql"
for f in $files; do
  b=$(basename "$f")
  nb=$(grep -cx 'BEGIN;' "$f" || true)
  nc=$(grep -cx 'COMMIT;' "$f" || true)
  if [ "$nb" != 1 ] || [ "$nc" != 1 ]; then
    echo "REFUSED: $b has $nb top-level BEGIN; and $nc COMMIT; lines, expected one of each" >&2
    exit 1
  fi
  grep -vx -e 'BEGIN;' -e 'COMMIT;' "$f" > "$work/migrations/$b"
  echo "\\echo '    $b'" >> "$work/apply.sql"
  echo "\\i /cut/migrations/$b" >> "$work/apply.sql"
done
cp cutover.sql transfer.sql backfill.sql verify.sql "$work/"

echo "==> $( $COMMIT && echo 'CUTOVER (commit)' || echo 'dry run (rolls back)' ): from sha256:${FROM_DIGEST:0:12}... to sha256:${TO_DIGEST:0:12}..."
docker run --rm -i --network "$DOCKER_NETWORK" -v "$work:/cut:ro" "$PSQL_IMAGE" \
  psql "$URL" -X -q -v ON_ERROR_STOP=1 \
       -v from_digest="$FROM_DIGEST" -v to_digest="$TO_DIGEST" -v commit="$COMMIT" \
       -f /cut/cutover.sql
