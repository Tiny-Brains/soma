# syntax=docker/dockerfile:1

# Soma has no application code -- it is a set of JSON definitions that an
# orion-server loads over its admin API. So this image is the upstream binary plus
# the package, and an entrypoint that puts the two together at boot.

# ---- fetch and verify the orion-server binary --------------------------------
FROM debian:bookworm-slim AS orion

# Soma pins 1.7.0: the first release that takes a var:// in oauth2_login.redirect_uri
# and has principal_rate_limit. See ../README.md "Version requirement".
ARG ORION_VERSION=1.7.0
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
# jq reads the ids out of the definition files in scripts/load-package.sh.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl jq \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --create-home --shell /usr/sbin/nologin soma

COPY --from=orion /usr/local/bin/orion-server /usr/local/bin/orion-server

WORKDIR /app
COPY connectors/ ./connectors/
COPY channels/   ./channels/
COPY workflows/  ./workflows/
COPY scripts/load-package.sh  ./scripts/load-package.sh
COPY docker-entrypoint.sh     /usr/local/bin/docker-entrypoint.sh

# The orion config template is NOT baked in -- it is instance configuration and
# lives in the deployment repo, mounted at ORION_CONFIG_TEMPLATE (see the compose
# file). The image is therefore the same in every environment.
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /app/scripts/load-package.sh \
 && chown -R soma:soma /app

USER soma
EXPOSE 8080

# /readyz is Orion's readiness probe: 200 only once startup has finished, the
# state database answers and no required background task has died. Before 1.6 it
# could not be used here -- async trace persistence mis-registered its worker as
# failed and pinned readiness to 503 -- so the image probed /health for a bare 200.
# A channel that failed to load does not fail this; the entrypoint prints those.
HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=5 \
  CMD curl -fsS http://127.0.0.1:8080/readyz > /dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
