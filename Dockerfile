# syntax=docker/dockerfile:1

# The Soma NODE: orion-server with the Soma package inside it -- the public /v1 HTTP API, the runner
# gate, the five clocks (admit, pair, count, withdraw, reap), their connectors, the two wasm
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

ARG ORION_VERSION=1.9.1
ARG RUST_VERSION=1.98.1
ARG WASM_TOOLS_VERSION=1.258.0
ARG CURL_VERSION=8.22.0
ARG DEBIAN_VERSION=bookworm-slim
# The ants release whose cartridge this node registers. Unset or empty is the LATEST, whenever this
# image builds -- the same default kalam's runner takes, so a Soma and a runner built together agree
# on the engine. A deployment under a live season pins a tag. `--build-context ants=../ants/dist`
# registers an ants checkout's own build instead, as kalam's and web's images take one.
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
# Soma plays no match, but it takes four things from the ants release: the manifest (the basic
# boards, `limits.boards` -- what a season's upload may be -- and the adapter budget), the reference
# observations admission validates an adapter against, the engine digest `bootstrap` declares --
# the digest every pending row is stamped with and every runner's claim filters on -- and THE
# COMPONENT ITSELF: an uploaded season map is judged by the engine's own `worldgen` on this
# node, so a board that cannot be played is refused at upload rather than failing every match.
#
# The release unpacked and checked, as kalam's and web's images take it: the viewer inside it must
# have been transpiled from the component beside it, or the archive is not one build. `ants` is the
# tree alone, laid out as ants' dist/, so `--build-context ants=../ants/dist` replaces this stage
# with a local build -- an engine not released yet -- and nothing below can tell.
#
# The releases feed changes exactly when a release is published or edited, so ADDing it keys this
# stage's cache. The archive is fetched by curl, which moves on to the next address when one of
# GitHub's download hosts is unreachable, where ADD times out.
FROM --platform=$BUILDPLATFORM curlimages/curl:${CURL_VERSION} AS ants-release
USER root
ARG ANTS_RELEASE
ADD https://github.com/Tiny-Brains/ants/releases.atom /tmp/ants-releases.atom
RUN set -eu; \
    url="https://github.com/Tiny-Brains/ants/releases/${ANTS_RELEASE:+download/}${ANTS_RELEASE:-latest/download}/ants-artifacts.tar.gz"; \
    curl -fsSL --connect-timeout 20 --retry 5 --retry-all-errors -o /tmp/ants.tar.gz "$url"; \
    mkdir /artifacts; \
    tar -xzf /tmp/ants.tar.gz -C /artifacts

FROM scratch AS ants
COPY --from=ants-release /artifacts/ /

FROM --platform=$BUILDPLATFORM curlimages/curl:${CURL_VERSION} AS cartridge
USER root
COPY --from=ants / /tmp/ants/
# A release is tagged `engine-<12 hex>` after its component, so that is the name a local build gets
# too: the same engine, whoever built it.
RUN set -eu; \
    engine="sha256:$(sha256sum /tmp/ants/tb-ants.wasm | cut -d' ' -f1)"; \
    grep -q "\"engine_digest\": \"${engine}\"" /tmp/ants/viz/engine.json \
      || { echo "ants: viz/ was not transpiled from the component beside it" >&2; exit 1; }; \
    mkdir -p /cartridge/reference; \
    cp /tmp/ants/cartridge.json /cartridge/; \
    cp /tmp/ants/reference/observations.json /cartridge/reference/; \
    printf '%s\n' "$engine" > /cartridge/engine-digest; \
    printf 'engine-%s\n' "$(printf '%s' "${engine#sha256:}" | cut -c1-12)" > /cartridge/release; \
    echo "ants: engine $engine"

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
      org.opencontainers.image.description="the Soma node: the public /v1 API, the runner gate and the five clocks on orion-server -- no model runs here -- with the schema and the command that applies it"

# curl for the healthcheck; postgresql-client and jq for `bootstrap`. No python3: the set is
# compiled by orion-server and applied by the node itself, so nothing here stages or patches JSON.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl postgresql-client jq \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --create-home --shell /usr/sbin/nologin orion \
 && install -d -o orion -g orion /var/lib/orion

COPY --from=orion /usr/local/bin/orion-server /usr/local/bin/orion-server
COPY docker/entrypoint.sh  /usr/local/bin/soma
COPY docker/soma.toml.tmpl /etc/orion/soma.toml.tmpl

COPY channels/   /pkg/soma/channels/
COPY workflows/  /pkg/soma/workflows/
# The statements the workflows name as `{"$sql": "../sql/<file>"}`. `compile` resolves them off
# disk, so a set without this directory does not compile and the node stops at its boot apply.
COPY sql/        /pkg/soma/sql/
COPY connectors/ /pkg/soma/connectors/
COPY migrations/ /pkg/soma/migrations/
COPY shared/     /pkg/soma/shared/
COPY scripts/load-package.sh /pkg/soma/scripts/
# plugin.toml is what `orion-server compile` reads a set's plugins from, and what web's
# sign-plugins.sh reads; plugin.json is its generated JSON twin.
COPY plugins/tb-pairing/plugin.toml /pkg/soma/plugins/tb-pairing/
COPY plugins/tb-rating/plugin.toml  /pkg/soma/plugins/tb-rating/
COPY --from=plugins /src/plugins/tb-pairing/plugin.json /src/plugins/tb-pairing/tb-pairing.wasm /pkg/soma/plugins/tb-pairing/
COPY --from=plugins /src/plugins/tb-rating/plugin.json  /src/plugins/tb-rating/tb-rating.wasm  /pkg/soma/plugins/tb-rating/
COPY --from=cartridge /cartridge/ /pkg/cartridge/
# The engine, which the map upload calls, as a plugin of this package -- the same component and
# the same two manifests Kalam's runner loads, so one signature verifies on both.
COPY --from=ants /tb-ants.wasm /plugin.json /plugin.toml /pkg/soma/plugins/tb-ants/

USER orion
EXPOSE 8080

# TWO MALLOC ARENAS, NOT glibc's 8 PER CORE. orion-server allocates through glibc, which gives each
# busy thread its own 64 MB arena and returns almost nothing from one: on a 10-core host a fresh
# node sat at ~910 MB after its package load, nearly all of it arenas full of freed memory, and
# idles at ~70 MB with this. Measured on the local stack; a deployment may override it.
ENV MALLOC_ARENA_MAX=2

# 200 once startup has finished, the state database answers AND this node's package is serving:
# `[packages] apply` holds /readyz at 503 (`components.packages: "applying"`) until it is, and stops
# the node if it cannot be. So this is now a real readiness check and not just "the process is up".
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=5 \
  CMD curl -fsS http://127.0.0.1:8080/readyz > /dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/soma"]
CMD ["serve"]
