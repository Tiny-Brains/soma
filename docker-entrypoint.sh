#!/usr/bin/env sh
# Render the config, wait for Postgres, start orion-server, load the Soma package.
#
# The package cannot be baked into the image: Orion holds channels and workflows in
# its state database and only accepts them over the admin API, so they go in once
# the server is answering. That is why this runs the server in the background,
# loads, and then hands the foreground back to it.
set -eu

: "${SOMA_DB_URL:?SOMA_DB_URL is required}"
: "${ORION_STATE_DB_URL:?ORION_STATE_DB_URL is required}"
: "${SOMA_SESSION_SECRET:?SOMA_SESSION_SECRET is required}"
: "${GITHUB_CLIENT_SECRET:?GITHUB_CLIENT_SECRET is required}"

GITHUB_CLIENT_ID="${GITHUB_CLIENT_ID:?GITHUB_CLIENT_ID is required}"
OAUTH_REDIRECT_URI="${OAUTH_REDIRECT_URI:-http://localhost:5173/v1/auth/github/callback}"
APP_URL="${APP_URL:-http://localhost:5173/}"

CFG=/tmp/orion.toml

# '|' as the sed delimiter because every rendered value here is a URL.
sed \
  -e "s|__ORION_STATE_DB_URL__|${ORION_STATE_DB_URL}|" \
  -e "s|__GITHUB_CLIENT_ID__|${GITHUB_CLIENT_ID}|" \
  -e "s|__OAUTH_REDIRECT_URI__|${OAUTH_REDIRECT_URI}|" \
  -e "s|__APP_URL__|${APP_URL}|" \
  /app/server/orion.docker.toml > "$CFG"

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

i=0
until curl -fsS http://127.0.0.1:8080/health > /dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -ge 30 ]; then echo "orion-server did not become ready" >&2; exit 1; fi
  # If it died on its own there is nothing to wait for.
  kill -0 "$ORION_PID" 2>/dev/null || { echo "orion-server exited during startup" >&2; wait "$ORION_PID"; }
  sleep 1
done

# Both localhost and a compose service name resolve to private addresses, which
# Orion's SSRF guard refuses by default. See server/load-package.sh.
SOMA_ALLOW_PRIVATE_DB="${SOMA_ALLOW_PRIVATE_DB:-1}" /app/server/load-package.sh

echo "==> soma is up on :8080"
wait "$ORION_PID"
