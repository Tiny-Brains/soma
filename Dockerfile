# syntax=docker/dockerfile:1

# Soma has no application code -- it is a set of JSON definitions that an
# orion-server loads over its admin API. So this image is the upstream binary plus
# the package, and an entrypoint that puts the two together at boot.

# ---- fetch and verify the orion-server binary --------------------------------
FROM debian:bookworm-slim AS orion

# Soma pins 1.5.1: 1.5.0 is the first release where an http_call header can be
# computed (which is what makes GitHub sign-in expressible) and where a channel may
# declare response.cookies. See ../README.md "Version requirement".
ARG ORION_VERSION=1.5.1
ARG TARGETARCH

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/orion
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) triple=x86_64-unknown-linux-gnu ;; \
      arm64) triple=aarch64-unknown-linux-gnu ;; \
      *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    base="https://github.com/GoPlasmatic/Orion/releases/download/v${ORION_VERSION}"; \
    curl -fsSL -o orion.tar.xz "${base}/orion-server-${triple}.tar.xz"; \
    curl -fsSL -o orion.sha256 "${base}/orion-server-${triple}.tar.xz.sha256"; \
    echo "$(cut -d' ' -f1 orion.sha256)  orion.tar.xz" | sha256sum -c -; \
    tar -xJf orion.tar.xz; \
    install -m 0755 "orion-server-${triple}/orion-server" /usr/local/bin/orion-server; \
    orion-server --version

# ---- runtime -----------------------------------------------------------------
FROM debian:bookworm-slim

# curl drives the admin API from the entrypoint and answers the healthcheck;
# jq reads the ids out of the definition files in server/load-package.sh.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl jq \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --create-home --shell /usr/sbin/nologin soma

COPY --from=orion /usr/local/bin/orion-server /usr/local/bin/orion-server

WORKDIR /app
COPY connectors/ ./connectors/
COPY channels/   ./channels/
COPY workflows/  ./workflows/
COPY server/orion.docker.toml ./server/orion.docker.toml
COPY server/load-package.sh   ./server/load-package.sh
COPY docker-entrypoint.sh     /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/docker-entrypoint.sh /app/server/load-package.sh \
 && chown -R soma:soma /app

USER soma
EXPOSE 8080

# /health answers 200 once the listener is up. It reports "degraded" rather than
# failing when a background task is down, so this proves reachability, not that
# every channel loaded -- the entrypoint prints quarantined channels for that.
HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=5 \
  CMD curl -fsS http://127.0.0.1:8080/health > /dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
