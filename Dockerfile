# syntax=docker/dockerfile:1

# The Soma NODE: orion-server with the Soma package inside it -- the public /v1 HTTP API, the runner
# gate, the four clocks (admit, pair, count, withdraw) and the probe, their connectors, the two wasm
# plugins that are the only arithmetic on this platform which writes a ladder -- and the Postgres
# migrations everything shares, with the command that applies them.
#
#   docker run ... ghcr.io/tiny-brains/soma            serve: migrate, load the package, run Orion
#   docker run ... ghcr.io/tiny-brains/soma bootstrap  the database, once, before any node starts
#
# It is a SERVICE IMAGE, not a carrier of files for somebody else's Orion. Everything a node needs is
# in it -- the server binary, docker/soma.toml.tmpl, the package and the cartridge it registers -- and
# everything that differs between deployments arrives by environment: addresses, credentials, the
# trust key. docker/entrypoint.sh says what each command does.
#
# SIGNATURES ARE NOT IN HERE. A plugin signature belongs to whoever holds the trust key, not to this
# package, and this image is shared by every deployment. The package's load-package.sh reads them
# from PLUGIN_SIG_DIR, which a deployment mounts.
#
# EVERY STAGE THAT BUILDS RUNS ON THE BUILD PLATFORM. The plugins, the cartridge and the orion-server
# download are the same bytes for every target, so a multi-platform build compiles them once and the
# amd64 and arm64 images carry identical components -- a plugin digest is what a signature is over,
# and one signature must verify on both. Only the runtime stage is per platform.

ARG ORION_VERSION=1.8.1
ARG RUST_VERSION=1.98.1
ARG WASM_TOOLS_VERSION=1.258.0
ARG CURL_VERSION=8.22.0
ARG DEBIAN_VERSION=bookworm-slim
# The ants release whose cartridge this node registers. Unset or empty is the LATEST, whenever this
# image builds -- the same default kalam's runner takes, so a Soma and a runner built together agree
# on the engine. A deployment under a live season pins a tag.
ARG ANTS_RELEASE=

# ---- the two plugin components -----------------------------------------------
#
# `plugins/build.sh` is run per plugin rather than reimplemented here, because it runs `cargo test`
# first: these two plugins decide who plays whom and what every rating becomes, and a component
# built from source that does not pass its own tests is the one thing that must not reach a ladder.
FROM --platform=$BUILDPLATFORM rust:${RUST_VERSION}-trixie AS plugins
ARG WASM_TOOLS_VERSION
ARG BUILDARCH

# python3 for the plugin.json the build generates from plugin.toml (tomllib).
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${BUILDARCH}" in \
      amd64) arch=x86_64 ;; \
      arm64) arch=aarch64 ;; \
      *) echo "wasm-tools publishes no ${BUILDARCH} linux build" >&2; exit 1 ;; \
    esac; \
    name="wasm-tools-${WASM_TOOLS_VERSION}-${arch}-linux"; \
    curl -fsSL "https://github.com/bytecodealliance/wasm-tools/releases/download/v${WASM_TOOLS_VERSION}/${name}.tar.gz" \
      | tar -xz -C /tmp; \
    install -m 0755 "/tmp/${name}/wasm-tools" /usr/local/bin/wasm-tools; \
    rm -rf "/tmp/${name}"

RUN rustup target add wasm32-unknown-unknown

# The same remapping ants uses, and for the same reason: rustc bakes the absolute path of every
# source file a panic can name into the binary, so without this a component's digest is a
# fingerprint of the machine that built it rather than of the source. The release profile strips and
# aborts on panic, so no path survives into these two today; the remap keeps that true of a profile
# that someday keeps one. rustc's HOST still moves the bytes (ants' build.sh says why), which is why
# this stage is pinned to the build platform and the release workflow builds on arm64.
ENV RUSTFLAGS="--remap-path-prefix=/usr/local/cargo/registry/src=/cargo --remap-path-prefix=/usr/local/rustup/toolchains=/rustup --remap-path-prefix=/src=/soma"

WORKDIR /src/plugins
COPY plugins/ ./
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/src/plugins/target,sharing=locked \
    ./build.sh tb-pairing && ./build.sh tb-rating

# ---- the cartridge this node registers ----------------------------------------
#
# Soma plays no match, so it takes three things from the ants release and not the component: the
# manifest (presets, limits, the adapter budget), the reference observations admission validates an
# adapter against, and the engine digest `bootstrap` declares -- the digest every pending row is
# stamped with and every runner's claim filters on.
#
# The releases feed changes exactly when a release is published or edited, so ADDing it keys this
# stage's cache. The archive is fetched by curl, which moves on to the next address when one of
# GitHub's download hosts is unreachable, where ADD times out.
FROM --platform=$BUILDPLATFORM curlimages/curl:${CURL_VERSION} AS cartridge
USER root
ARG ANTS_RELEASE
ADD https://github.com/Tiny-Brains/ants/releases.atom /tmp/ants-releases.atom
RUN set -eu; \
    base="https://github.com/Tiny-Brains/ants/releases"; \
    if [ -n "${ANTS_RELEASE}" ]; then tag="${ANTS_RELEASE}"; \
    else tag=$(curl -fsSL --retry 5 --retry-all-errors -o /dev/null -w '%{url_effective}' "$base/latest"); tag="${tag##*/}"; fi; \
    curl -fsSL --connect-timeout 20 --retry 5 --retry-all-errors -o /tmp/ants.tar.gz "$base/download/$tag/ants-artifacts.tar.gz"; \
    mkdir -p /tmp/ants /cartridge/reference; \
    tar -xzf /tmp/ants.tar.gz -C /tmp/ants; \
    engine="sha256:$(sha256sum /tmp/ants/tb-ants.wasm | cut -d' ' -f1)"; \
    grep -q "\"engine_digest\": \"${engine}\"" /tmp/ants/viz/engine.json \
      || { echo "ants $tag: viz/ was not transpiled from the component beside it" >&2; exit 1; }; \
    cp /tmp/ants/cartridge.json /cartridge/; \
    cp /tmp/ants/reference/observations.json /cartridge/reference/; \
    printf '%s\n' "$engine" > /cartridge/engine-digest; \
    printf '%s\n' "$tag" > /cartridge/release; \
    echo "ants $tag: engine $engine"

# ---- orion-server, for the target platform -----------------------------------
#
# The upstream release, verified against its published checksum. Fetched on the build platform --
# it is a download, not a build -- for the architecture the image is for.
FROM --platform=$BUILDPLATFORM debian:${DEBIAN_VERSION} AS orion
ARG ORION_VERSION
ARG TARGETARCH
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /tmp/orion
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) triple=x86_64-unknown-linux-gnu ;; \
      arm64) triple=aarch64-unknown-linux-gnu ;; \
      *) echo "orion-server publishes no ${TARGETARCH} linux build" >&2; exit 1 ;; \
    esac; \
    base="https://github.com/GoPlasmatic/Orion/releases/download/v${ORION_VERSION}"; \
    curl -fsSL --retry 5 -o orion.tar.xz "${base}/orion-server-${triple}.tar.xz"; \
    curl -fsSL --retry 5 -o orion.sha256 "${base}/orion-server-${triple}.tar.xz.sha256"; \
    echo "$(cut -d' ' -f1 orion.sha256)  orion.tar.xz" | sha256sum -c -; \
    tar -xJf orion.tar.xz; \
    install -m 0755 "orion-server-${triple}/orion-server" /usr/local/bin/orion-server

# ---- the node ------------------------------------------------------------------
FROM debian:${DEBIAN_VERSION}
LABEL org.opencontainers.image.title="soma" \
      org.opencontainers.image.source="https://github.com/Tiny-Brains/soma" \
      org.opencontainers.image.description="the Soma node: the public /v1 API, the runner gate and the four clocks on orion-server, with the schema and the command that applies it"

# curl for the healthcheck, the self-load and the baselines' downloads and signed uploads; python3
# because load-package.sh stages the set with it and bootstrap's baselines step is written in it
# (stdlib only -- tomllib needs 3.11, which this Debian carries); postgresql-client and jq for
# `bootstrap`.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl python3 postgresql-client jq \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --create-home --shell /usr/sbin/nologin orion \
 && install -d -o orion -g orion /var/lib/orion /var/lib/orion/models

COPY --from=orion /usr/local/bin/orion-server /usr/local/bin/orion-server
COPY docker/entrypoint.sh  /usr/local/bin/soma
COPY docker/soma.toml.tmpl /etc/orion/soma.toml.tmpl

COPY channels/   /pkg/soma/channels/
COPY workflows/  /pkg/soma/workflows/
COPY connectors/ /pkg/soma/connectors/
COPY migrations/ /pkg/soma/migrations/
COPY shared/     /pkg/soma/shared/
COPY scripts/load-package.sh scripts/stage-set.py /pkg/soma/scripts/
# plugin.toml is what `orion-server compile` reads a set's plugins from; plugin.json is the
# generated twin a signing script reads.
COPY plugins/tb-pairing/plugin.toml /pkg/soma/plugins/tb-pairing/
COPY plugins/tb-rating/plugin.toml  /pkg/soma/plugins/tb-rating/
COPY --from=plugins /src/plugins/tb-pairing/plugin.json /src/plugins/tb-pairing/tb-pairing.wasm /pkg/soma/plugins/tb-pairing/
COPY --from=plugins /src/plugins/tb-rating/plugin.json  /src/plugins/tb-rating/tb-rating.wasm  /pkg/soma/plugins/tb-rating/
COPY --from=cartridge /cartridge/ /pkg/cartridge/

# `bootstrap`'s baselines step, and the roster it seeds when none is mounted at /config/baselines.toml.
COPY docker/baselines.py   /usr/local/lib/soma/baselines.py
COPY docker/baselines.toml /pkg/soma/baselines.toml
USER orion
EXPOSE 8080

# 200 once startup has finished and the state database answers. A package that failed to load does
# not fail this; the entrypoint's self-load stops the node instead.
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=5 \
  CMD curl -fsS http://127.0.0.1:8080/readyz > /dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/soma"]
CMD ["serve"]
