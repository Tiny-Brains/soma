#!/usr/bin/env bash
# DROP WHAT A CUTOVER KEPT FOR ITS ROLLBACK, once the release has served long enough that nobody will
# roll it back: the replaced schemas in the soma database (`legacy`, a chained window's `legacy_072`,
# and any `*_rolled_back` a rollback left) and the copies of Orion's state (`orion_state_pre_cutover`,
# a retried window's `orion_state_v2`).
#
#   scripts/cutover/drop-legacy.sh "$SOMA_DB_URL" "$SOMA_ADMIN_DB_URL"                       # dry run
#   BACKUP_ID=<id> scripts/cutover/drop-legacy.sh "$SOMA_DB_URL" "$SOMA_ADMIN_DB_URL" --commit
#
# THIS ENDS THE ROLLBACK: rollback.sql renames `legacy` back to `public`, and retire.sh's rollback is
# `orion_state_pre_cutover`. So it refuses unless
#   - `public` is on the schema this release serves (ON_DIGEST) -- after a rollback, the copy worth
#     keeping is exactly one this would drop;
#   - every closed season reads the same from `public` as from `legacy`, the copy the cutover took:
#     ratings, rating events, podium, seats, versions, matches played, close and engine
#     (fingerprint.sql); with FINGERPRINT given, that fingerprint must also start with it, and with
#     no `legacy` left it is the only reference and is required;
#   - no match of a closed season is unfinished, every closed season that played has a podium, and
#     none gained a rating event since yesterday;
#   - nothing outside the schemas to drop depends on anything in them.
# Each schema goes in its own transaction, guarded by a count of every object in the schemas that
# stay, and the dry run performs every drop and rolls it back -- so a dependent, a missing privilege
# or a lock it cannot take fails the dry run, not the real one. The databases go last, and only on
# --commit: DROP DATABASE cannot be rolled back, so the dry run lists them.
#
# --commit wants BACKUP_ID, a Cloud SQL on-demand backup taken for this run
# (`gcloud sql backups create --instance <instance>`). With SQL_INSTANCE set and gcloud on the PATH
# it checks that backup is SUCCESSFUL, ON_DEMAND and under MAX_BACKUP_HOURS old; otherwise it says it
# cannot, and takes your word.
#
# Environment:
#   ON_DIGEST         the schema `public` must be on (default: v0.9.2's, f3926661)
#   FINGERPRINT       the closed seasons' fingerprint recorded earlier, whole or a prefix (optional)
#   BACKUP_ID         required with --commit
#   SQL_INSTANCE      the Cloud SQL instance BACKUP_ID belongs to, to verify it (optional)
#   MAX_BACKUP_HOURS  default 24
#   OLD_CHECKOUT      the directory the replaced release ran from on this host (optional): what still
#                     names it is shown, and removing it is left to you
#   DOCKER_NETWORK    where psql runs from (default: host; `container:<db>` for a local container)
#   PSQL_IMAGE        default postgres:16-alpine
#
# The owner of both databases runs it (the role in SOMA_DB_URL, and the same role on the cluster's
# `postgres` database in SOMA_ADMIN_DB_URL); it needs no superuser.
set -euo pipefail
cd "$(dirname "$0")"

URL="${1:?usage: drop-legacy.sh <soma database url> <admin (postgres database) url> [--commit]}"
ADMIN_URL="${2:?usage: drop-legacy.sh <soma database url> <admin (postgres database) url> [--commit]}"
COMMIT=false
[ "${3:-}" = "--commit" ] && COMMIT=true
ON_DIGEST="${ON_DIGEST:-f3926661775c668409975e59e0c1aef9731d8e9c70f88c9562b108bffbb3c28b}"
FINGERPRINT="${FINGERPRINT:-}"
MAX_BACKUP_HOURS="${MAX_BACKUP_HOURS:-24}"
DOCKER_NETWORK="${DOCKER_NETWORK:-host}"
PSQL_IMAGE="${PSQL_IMAGE:-postgres:16-alpine}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp drop-legacy.sql fingerprint.sql drop-databases.sql "$work/"
# The role's statement_timeout is the node's (its connector gives up at 15 s); a maintenance run
# reading every closed season and dropping whole schemas must not inherit it.
psql_() { docker run --rm -i --network "$DOCKER_NETWORK" -e PGOPTIONS='-c statement_timeout=0' \
            -v "$work:/d:ro" "$PSQL_IMAGE" psql "$@"; }

# The backup, before anything is touched.
if $COMMIT; then
  # An explicit exit: macOS's bash 3.2 reports a failed ${VAR:?} as 0 once an EXIT trap is set.
  if [ -z "${BACKUP_ID:-}" ]; then
    echo "REFUSED: --commit needs BACKUP_ID: take one first (gcloud sql backups create --instance <instance>)" >&2
    exit 1
  fi
  if [ -n "${SQL_INSTANCE:-}" ] && command -v gcloud > /dev/null; then
    read -r status kind ended <<< "$(gcloud sql backups describe "$BACKUP_ID" --instance "$SQL_INSTANCE" \
      --format='value(status,type,endTime)')" || true
    hours=$(python3 -c 'import sys, datetime as d
e = d.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
print(int((d.datetime.now(d.timezone.utc) - e).total_seconds() // 3600))' "${ended:-}" 2>/dev/null || echo unknown)
    if [ "${status:-}" != SUCCESSFUL ] || [ "${kind:-}" != ON_DEMAND ] || [ "$hours" = unknown ] \
       || [ "$hours" -ge "$MAX_BACKUP_HOURS" ]; then
      echo "REFUSED: backup $BACKUP_ID of $SQL_INSTANCE is ${status:-missing} ${kind:-} ${hours}h old -- want SUCCESSFUL, ON_DEMAND, under ${MAX_BACKUP_HOURS}h" >&2
      exit 1
    fi
    echo "==> backup $BACKUP_ID of $SQL_INSTANCE: successful, on demand, ${hours}h old"
  else
    echo "==> backup $BACKUP_ID: NOT verified here (set SQL_INSTANCE, with gcloud on the PATH) -- you vouch for it"
  fi
fi

echo "==> $( $COMMIT && echo 'DROP (commit)' || echo 'dry run (every drop rolled back)' ): the soma database"
psql_ "$URL" -X -q -v ON_ERROR_STOP=1 \
       -v on_digest="$ON_DIGEST" -v commit="$COMMIT" -v fingerprint="$FINGERPRINT" \
       -f /d/drop-legacy.sql

# Cloud SQL's own agent opens a session on every database every few minutes, and DROP DATABASE
# refuses one with a session open (FORCE would need to end a superuser's). So: a few tries.
echo "==> $( $COMMIT && echo 'DROP (commit)' || echo 'dry run (listed only)' ): the cluster's databases"
for try in 1 2 3 4 5; do
  if out=$(psql_ "$ADMIN_URL" -X -q -v ON_ERROR_STOP=1 -v commit="$COMMIT" -f /d/drop-databases.sql 2>&1); then
    echo "$out"
    break
  fi
  echo "$out"
  if [ "$try" = 5 ] || ! grep -q 'is being accessed by other users' <<< "$out"; then exit 1; fi
  echo "    (a session is open on it; trying again in 10 s)"
  sleep 10
done

# The checkout the replaced release ran from is a host's, not a database's: shown, never removed.
if [ -n "${OLD_CHECKOUT:-}" ]; then
  echo "==> NOT DONE HERE: $OLD_CHECKOUT, the checkout the replaced release ran from. What names it:"
  if [ -d "$OLD_CHECKOUT" ]; then
    named=0
    for c in $(docker ps -aq); do
      docker inspect "$c" --format '{{.Name}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.project.config_files"}}|{{range .Mounts}}{{.Source}} {{end}}' \
        | awk -F'|' -v d="$OLD_CHECKOUT" 'index($4, d) { print "    MOUNT  " $1 " mounts from it"; next }
                                           index($2 $3, d) { print "    label  " $1 " (compose labels only; nothing read at run time)" }'
    done | tee "$work/named"
    { find "$(dirname "$OLD_CHECKOUT")" -maxdepth 5 -type l 2>/dev/null || true; } | while read -r l; do
      t=$(readlink "$l")
      case "$t" in "$OLD_CHECKOUT"*) echo "    LINK   $l -> $t" ;; esac
    done | tee -a "$work/named"
    grep -q -e MOUNT -e LINK "$work/named" && named=1
    if [ "$named" = 0 ]; then
      echo "    nothing mounts or links into it. Keep its .env and keys with the backups, then: sudo rm -rf $OLD_CHECKOUT"
    else
      echo "    something still reads from it (above): leave it until that is moved"
    fi
  else
    echo "    (not a directory on this host)"
  fi
fi
