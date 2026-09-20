#!/usr/bin/env sh
# The Soma node: one image that serves the platform and prepares the database it serves from.
#
#   soma serve        (the default) migrate Orion's state, load this image's package, run orion-server
#   soma bootstrap    one-shot, BEFORE any node starts: orion_state, the schema, the game, the
#                     runner_gate role, the engine digest and the cartridge. Nothing an admin makes:
#                     seasons, their boards and baselines, and runner keys are made on the admin
#                     pages, and no image carries a model
#
# THE PACKAGE IS IN THE IMAGE, AND THE NODE APPLIES IT ITSELF. There is no loader service and no
# loader fork: `serve` compiles the set into an artifact and `[packages] apply` in soma.toml.tmpl
# does the rest, holding /readyz at 503 until the package is serving and stopping the node if it
# cannot be. `apply` is idempotent by content, so a restart with the same image is a no-op and
# every node of a cluster may list it.
#
# BOOTSTRAP IS A SEPARATE COMMAND BECAUSE OF ONE ORDERING FACT: a cluster-mode orion-server cannot
# start until `orion_state` EXISTS -- migrate does not create a database, it migrates into one. So
# the database work runs first, as a one-shot of this same image, and the nodes wait on it.
set -eu

PKG="${SOMA_PKG_DIR:-/pkg/soma}"
CARTRIDGE="${SOMA_CARTRIDGE_DIR:-/pkg/cartridge}"

# ---------------------------------------------------------------------------- serve
serve() {
  # orion-server substitutes ${NAME:-default} from this environment as it reads the file, so nothing
  # is rendered to disk.
  CFG="${ORION_CONFIG_TEMPLATE:-/etc/orion/soma.toml.tmpl}"
  [ -r "$CFG" ] || { echo "instance config not readable at $CFG" >&2; exit 1; }
  : "${ORION_STATE_DB_URL:?ORION_STATE_DB_URL is required -- the Orion state database (orion_state)}"
  : "${ORION_ADMIN_KEY:?ORION_ADMIN_KEY is required -- the package is loaded over the admin API}"

  # [vars] allow_private_urls must substitute to a bare TOML BOOLEAN, and `${X:-false}` falls back
  # only when X is UNSET -- an empty value substitutes as empty and the line stops being TOML. Every
  # connector but soma-cache reads it, so this is normalised here rather than trusted to a caller:
  # a deployment writing `1`, `yes` or nothing at all gets a boolean either way.
  case "${SOMA_ALLOW_PRIVATE_URLS:-}" in
    1|true|yes|on) SOMA_ALLOW_PRIVATE_URLS=true ;;
    *)             SOMA_ALLOW_PRIVATE_URLS=false ;;
  esac
  export SOMA_ALLOW_PRIVATE_URLS

  # [vars] cookie_secure must substitute to a bare TOML boolean. Browsers refuse to store a Secure
  # cookie from an http:// origin, so a plain-http stack sets 0.
  case "${SOMA_COOKIE_SECURE:-1}" in
    0|false|no) SOMA_COOKIE_SECURE=false ;;
    *)          SOMA_COOKIE_SECURE=true ;;
  esac
  export SOMA_COOKIE_SECURE

  # [vars] admin_github_ids: GitHub numeric user ids, comma-separated. Spaces are dropped; anything
  # else is refused, because a login here would match nobody and say nothing -- and a login is the
  # wrong key anyway, since GitHub frees a renamed one for anyone to register.
  SOMA_ADMIN_GITHUB_IDS=$(printf '%s' "${SOMA_ADMIN_GITHUB_IDS:-}" | tr -d ' \t\r\n')
  case "$SOMA_ADMIN_GITHUB_IDS" in
    "") echo "==> SOMA_ADMIN_GITHUB_IDS is empty: sign-in makes nobody an admin" ;;
    *[!0-9,]*|,*|*,|*,,*)
      echo "SOMA_ADMIN_GITHUB_IDS must be GitHub numeric user ids, comma-separated, not logins" >&2
      echo "    web's scripts/setup/admin-user.sh <github-login> looks one up" >&2
      exit 1 ;;
    *) echo "==> $(printf '%s' "$SOMA_ADMIN_GITHUB_IDS" | tr ',' '\n' | grep -c .) GitHub account(s) are admins by deployment" ;;
  esac
  export SOMA_ADMIN_GITHUB_IDS

  # The engine this node loads, which [vars] engine_digest names so a map upload can refuse a season
  # pinned to another one: validating a board on a different engine proves nothing about the one
  # that will play it.
  SOMA_ENGINE_DIGEST=$(cat "$CARTRIDGE/engine-digest" 2>/dev/null || true)
  export SOMA_ENGINE_DIGEST

  # Doubles as the readiness probe for Postgres. soma.toml.tmpl sets auto_migrate = false, because a
  # cluster may not migrate at boot from every node at once; this is the step that satisfies it.
  #
  # `--wait` retries only what means "not accepting connections yet" -- a refused or reset
  # connection, an unresolvable host, a server starting up -- and stops at once on a wrong password
  # or an unknown database, which is what `has soma bootstrap run?` used to be guessed from. It
  # says what it is waiting for on each retry, so a stuck boot names its own reason.
  echo "==> migrating state"
  orion-server -c "$CFG" migrate --wait 60s

  # THE PACKAGE THIS IMAGE CARRIES, compiled into the artifact `[packages] apply` names. Applying
  # it is the server's own job now (soma.toml.tmpl): it holds /readyz at 503 until the package is
  # serving and stops the node if it cannot be. So there is no fork here, nothing polling /readyz,
  # and no /health assertion -- the failure those existed to catch is an invariant of the boot.
  #
  # `--version content` names the version after the artifact's content hash, so an unchanged image
  # compiles to the version already applied and the apply is a no-op. `--name` is not passed:
  # shared/package.json carries it, with the `requires.orion` range this binary is checked against.
  ARTIFACT="${SOMA_ARTIFACT:-/var/lib/orion/soma.package.json}"
  export SOMA_ARTIFACT="$ARTIFACT"
  echo "==> compiling the soma package"
  orion-server compile "$PKG" --version content -o "$ARTIFACT" > /dev/null

  echo "==> starting orion-server with $CFG"
  exec orion-server -c "$CFG"
}

# ---------------------------------------------------------------------------- bootstrap
# The database as a precondition, not as a fixture. Each step is convergent, so this runs on every
# bring-up:
#
#   orion_state   Orion's own state is not Soma's data: same server, separate database, so Soma's
#                 schema can be rebuilt without losing the loaded package.
#   the schema    migrations/, applied when the database is EMPTY. Not applied over an existing one:
#                 0001_init.sql is pre-release and rewritten in place, so re-applying it is an error
#                 and not an upgrade. The digest of what was applied is kept as a per-database
#                 setting, and a rewrite that has not reached this database is REFUSED by name
#                 rather than surfacing as a missing relation on a clock tick hours later.
#   the roles     runner_gate (and kalam, for a db-mode replica) created by the migration with LOGIN
#                 and no password, so the committed schema ships no secret
#   the engine    the digest of the cartridge component this image was built with, declared as a
#                 patch (the live season takes it) or, with ENGINE_RELEASE=1, a release (refused
#                 while a season is live). A runner whose digest differs claims nothing, for ever.
#   the cartridge games.manifest and games.reference_observations, what admission validates against
#
# No step here writes a model, a map or a bucket object: a season's baselines and boards are uploaded
# into it by an admin, and baselines are admitted like any submission.
DB="${SOMA_DB_URL:-}"
ADMIN_DB="${SOMA_ADMIN_DB_URL:-}"
MIGRATIONS="$PKG/migrations"
GAME="${GAME:-ants}"

psql_db() { psql "$DB" -q -v ON_ERROR_STOP=1 "$@"; }

migration_files() { ls -1 "$MIGRATIONS"/*.sql 2>/dev/null || true; }

# Over the CONTENT, concatenated in filename order. Not over the names: a rename that changes
# nothing should not read as a schema change.
schema_digest() {
  files=$(migration_files)
  [ -n "$files" ] || { echo "no migrations at $MIGRATIONS" >&2; exit 1; }
  # shellcheck disable=SC2086
  cat $files | sha256sum | cut -d' ' -f1
}

record_schema_digest() {
  psql -X "$DB" -q -v ON_ERROR_STOP=1 -v d="$1" <<'SQL'
SELECT format('ALTER DATABASE %I SET tinybrains.schema_digest = %L', current_database(), :'d')\gexec
SQL
}

bootstrap() {
  [ -n "$DB" ] || { echo "SOMA_DB_URL is required -- the platform database, as its owner" >&2; exit 1; }
  [ -n "$ADMIN_DB" ] || { echo "SOMA_ADMIN_DB_URL is required -- the maintenance database (.../postgres), for CREATE DATABASE" >&2; exit 1; }

  echo "==> waiting for postgres"
  i=0
  until psql -X "$ADMIN_DB" -At -c 'SELECT 1' > /dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || { echo "postgres did not become reachable in time" >&2; psql -X "$ADMIN_DB" -c 'SELECT 1'; exit 1; }
    sleep 2
  done

  echo "==> orion_state"
  # CREATE DATABASE cannot run inside a transaction block, so it is built as text and run by \gexec
  # -- which is also what makes it a no-op when the database is already there.
  psql -X "$ADMIN_DB" -q -v ON_ERROR_STOP=1 <<'SQL'
SELECT format('CREATE DATABASE orion_state OWNER %I', current_user)
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'orion_state')\gexec
SQL

  want=$(schema_digest)
  have=$(psql -X "$DB" -At -c "SELECT coalesce(current_setting('tinybrains.schema_digest', true), '')")
  present=$(psql -X "$DB" -At -c "SELECT CASE WHEN to_regclass('public.games') IS NULL THEN 'no' ELSE 'yes' END")
  if [ "$present" = "no" ]; then
    echo "==> applying the schema"
    for f in $(migration_files); do
      psql_db -f "$f"
      echo "    $(basename "$f")"
    done
    record_schema_digest "$want"
  elif [ -z "$have" ]; then
    # A database from before digests were recorded: the schema cannot be checked after the fact, so
    # it is ADOPTED -- once, loudly -- rather than refused.
    echo "==> the schema is present but carries no digest; adopting ${want%${want#????????}}... as applied"
    record_schema_digest "$want"
  elif [ "$have" != "$want" ]; then
    echo "REFUSED: the schema in this database is not the one this image's migrations describe." >&2
    echo "    applied  sha256:$have" >&2
    echo "    in image sha256:$want" >&2
    echo "The schema is pre-release -- 0001_init.sql is rewritten in place, not extended -- so this is a" >&2
    echo "rewrite that has not reached this database. Rebuild it, or throw the volume away." >&2
    exit 1
  else
    echo "==> the schema is current (sha256:${want%${want#????????}}...)"
  fi

  echo "==> role passwords"
  # Through stdin rather than -c: psql expands :'var' in a script, not in a -c string.
  psql_db -v pw="${RUNNER_GATE_DB_PASSWORD:?RUNNER_GATE_DB_PASSWORD is required -- the role the runner gate runs as}" <<'SQL'
ALTER ROLE runner_gate WITH LOGIN PASSWORD :'pw';
SQL
  if [ -n "${KALAM_DB_PASSWORD:-}" ]; then
    psql_db -v pw="$KALAM_DB_PASSWORD" <<'SQL'
ALTER ROLE kalam WITH LOGIN PASSWORD :'pw';
SQL
  fi

  digest=$(cat "$CARTRIDGE/engine-digest")
  manifest="$CARTRIDGE/cartridge.json"
  observations="$CARTRIDGE/reference/observations.json"
  echo "==> the cartridge: ants $(cat "$CARTRIDGE/release"), engine $digest"

  # The game row, when this database has none. The digest is declared below either way.
  psql_db -v g="$GAME" -v d="$digest" <<'SQL'
INSERT INTO games (slug, name, active_engine_digest)
VALUES (:'g', initcap(:'g'), :'d')
ON CONFLICT (slug) DO NOTHING;
SQL

  if [ "${ENGINE_RELEASE:-0}" = "1" ]; then
    echo "==> releasing the engine (a rules change: only between seasons)"
    n=$(psql -X "$DB" -At -v d="$digest" -v g="$GAME" <<'SQL'
WITH g AS (
    UPDATE games g SET active_engine_digest = :'d'
     WHERE g.slug = :'g'
       AND NOT EXISTS (SELECT 1 FROM seasons s WHERE s.game_id = g.id AND s.closed_at IS NULL)
 RETURNING id)
SELECT count(*) FROM g;
SQL
)
    if [ "${n:-0}" -eq 0 ]; then
      echo "REFUSED: a season is live. Close it (POST /v1/games/{game}/seasons/{slug}/close), or build this image from the release the season plays." >&2
      exit 1
    fi
  else
    echo "==> declaring the engine (a patch: the live season takes it too)"
    # Only `pending` rows are re-stamped: a claimed, running or finished row records the engine it
    # was ACTUALLY played on, and that record is what makes a skew visible. The roster epoch bumps so
    # a pair run mid-plan halts and re-reads.
    psql_db -v d="$digest" -v g="$GAME" <<'SQL'
UPDATE games SET active_engine_digest = :'d' WHERE slug = :'g' AND active_engine_digest IS DISTINCT FROM :'d';
WITH s AS (
    UPDATE seasons s SET engine_digest = :'d'
      FROM games g
     WHERE g.id = s.game_id AND g.slug = :'g'
       AND s.closed_at IS NULL AND s.engine_digest <> :'d'
 RETURNING s.id)
UPDATE clocks c SET epoch = c.epoch + 1, updated_at = now() FROM s WHERE c.key = 'roster';
UPDATE matches m SET engine_digest = :'d'
  FROM seasons s JOIN games g ON g.id = s.game_id
 WHERE s.id = m.season_id AND g.slug = :'g' AND s.closed_at IS NULL
   AND m.status = 'pending' AND m.engine_digest IS DISTINCT FROM :'d';
SQL
  fi

  echo "==> registering the cartridge"
  jq -e '.budgets.adapter_ops_max' "$manifest" > /dev/null \
    || { echo "$manifest declares no budgets.adapter_ops_max" >&2; exit 1; }
  # The file is an OBJECT and the column is an ARRAY, so the array is taken out. THE DOCUMENTS GO IN
  # THROUGH psql's OWN BACKTICKS, NOT `-v m="$(...)"`: an argument is capped at 128 KiB by the kernel
  # and the reference set is 355 KB, so a backtick's pipe is the only way in that has no ceiling.
  obs_file=$(mktemp)
  jq -ce '.observations | select(type == "array")' "$observations" > "$obs_file" \
    || { echo "$observations has no 'observations' array" >&2; exit 1; }
  psql_db -v mfile="$manifest" -v ofile="$obs_file" -v g="$GAME" <<'SQL'
\set m `jq -c . :'mfile'`
\set o `cat :'ofile'`
UPDATE games SET manifest = :'m'::jsonb, reference_observations = :'o'::jsonb WHERE slug = :'g';
SQL
  rm -f "$obs_file"
  psql -X "$DB" -At -c "SELECT '    ' || slug || ': engine ' || left(active_engine_digest, 19) || '..., adapter_ops_max=' || (manifest -> 'budgets' ->> 'adapter_ops_max') || ', ' || jsonb_array_length(reference_observations) || ' observation(s)' FROM games"
  echo "==> done"
}

case "${1:-serve}" in
  serve)     serve ;;
  bootstrap) bootstrap ;;
  *) exec "$@" ;;
esac
