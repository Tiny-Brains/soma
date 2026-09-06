#!/usr/bin/env sh
# Check the environment, wait for Postgres, start orion-server, load the Soma package.
#
# The package cannot be baked into the image: Orion holds channels and workflows in
# its state database and only accepts them over the admin API, so they go in once
# the server is answering. That is why this runs the server in the background,
# loads, and then hands the foreground back to it.
#
# See ../devops/ for the compose file and the instance config this runs against.
set -eu

: "${SOMA_DB_URL:?SOMA_DB_URL is required}"
# Read by the config itself, as [storage] url = "env://ORION_STATE_DB_URL". Checked
# here only so a missing one is reported by name before orion-server is asked to
# migrate against it.
: "${ORION_STATE_DB_URL:?ORION_STATE_DB_URL is required}"
: "${SOMA_SESSION_SECRET:?SOMA_SESSION_SECRET is required}"
: "${GITHUB_CLIENT_SECRET:?GITHUB_CLIENT_SECRET is required}"

# Read by the sign-in channel as env://, like the secret. The callback URL and the
# app URL are not checked here: the config reads OAUTH_REDIRECT_URI and APP_URL
# itself, with localhost defaults.
: "${GITHUB_CLIENT_ID:?GITHUB_CLIENT_ID is required}"

# [vars] cookie_secure = ${SOMA_COOKIE_SECURE:-true} in the config must substitute
# to a bare TOML boolean, so normalise what the environment hands over: 0/false/no
# -> false, anything else -- including unset -- true. Browsers refuse to store a
# Secure cookie from an http:// origin, so a plain-http stack sets 0.
case "${SOMA_COOKIE_SECURE:-1}" in
  0|false|no) SOMA_COOKIE_SECURE=false ;;
  *)          SOMA_COOKIE_SECURE=true ;;
esac
export SOMA_COOKIE_SECURE

# Instance config, mounted from the deployment repo rather than baked into the
# image. orion-server substitutes its ${NAME:-default} references from this
# environment as it reads the file, so one image serves every environment and
# nothing is rendered to disk.
CFG="${ORION_CONFIG_TEMPLATE:-/etc/soma/orion.toml.tmpl}"

if [ ! -r "$CFG" ]; then
  echo "instance config not readable at $CFG -- mount it, or set ORION_CONFIG_TEMPLATE" >&2
  exit 1
fi

echo "==> waiting for postgres"
# `migrate` connects to the state database and applies Orion's own schema, so it
# doubles as the readiness probe. Compose's depends_on already gates on the db
# healthcheck; this covers a plain `docker run` and a database that restarts.
i=0
until orion-server -c "$CFG" migrate > /dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -ge 30 ]; then
    echo "postgres did not become reachable in time" >&2
    orion-server -c "$CFG" migrate    # run once more, unsilenced, to show why
    exit 1
  fi
  sleep 2
done

echo "==> starting orion-server"
orion-server -c "$CFG" &
ORION_PID=$!
trap 'kill -TERM "$ORION_PID" 2>/dev/null || true' TERM INT

# /readyz answers 200 once startup has finished and the state database is
# reachable, which is when the admin API will accept the package.
i=0
until curl -fsS http://127.0.0.1:8080/readyz > /dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -ge 30 ]; then echo "orion-server did not become ready" >&2; exit 1; fi
  # If it died on its own there is nothing to wait for.
  kill -0 "$ORION_PID" 2>/dev/null || { echo "orion-server exited during startup" >&2; wait "$ORION_PID"; }
  sleep 1
done

# Both localhost and a compose service name resolve to private addresses, which
# Orion's SSRF guard refuses by default. See scripts/load-package.sh.
SOMA_ALLOW_PRIVATE_DB="${SOMA_ALLOW_PRIVATE_DB:-1}" /app/scripts/load-package.sh

echo "==> soma is up on :8080"
wait "$ORION_PID"
