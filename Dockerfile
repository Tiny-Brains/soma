# syntax=docker/dockerfile:1

# The Soma package as an ARTIFACT IMAGE: the public /v1 HTTP API, the runner gate, the four clocks
# (admit, pair, count, withdraw) and the probe, their connectors, the two wasm plugins that are the
# only arithmetic on this platform which writes a ladder, and the Postgres migrations everything
# shares.
#
# ONE THING HERE IS BUILT, AND IT IS THE PLUGINS. Every channel, workflow, connector and migration is
# committed -- the clocks' channels and workflows included, which scripts/gen-clocks.py generates and
# scripts/check-defs.sh holds to the generator -- so they are copied straight through. The two
# components are not committed: they are built below under a pinned toolchain, because a plugin
# digest is what the signature is over and what every node verifies.
#
# THE MIGRATIONS ARE CARRIED, NOT RENAMED. What ships is `migrations/` under its own names, exactly as
# the repository holds it; the order devops applies them in is devops' decision.
#
# SIGNATURES ARE NOT IN HERE. A plugin signature is deployment state -- it belongs to whoever holds
# the trust key, not to this package -- and this image is immutable and shared. `load-package.sh`
# reads them from `PLUGIN_SIG_DIR` instead; devops mints them and mounts that directory.

ARG RUST_VERSION=1.98.1
ARG WASM_TOOLS_VERSION=1.258.0
ARG BUSYBOX_VERSION=1.37-musl

# ---- the two plugin components -----------------------------------------------
#
# `plugins/build.sh` is run per plugin rather than reimplemented here, because it runs `cargo test`
# first: these two plugins decide who plays whom and what every rating becomes, and a component
# built from source that does not pass its own tests is the one thing that must not reach a ladder.
FROM rust:${RUST_VERSION}-trixie AS plugins
ARG WASM_TOOLS_VERSION
ARG TARGETARCH

# python3 for the plugin.json the build generates from plugin.toml (tomllib).
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) arch=x86_64 ;; \
      arm64) arch=aarch64 ;; \
      *) echo "wasm-tools publishes no ${TARGETARCH} linux build" >&2; exit 1 ;; \
    esac; \
    name="wasm-tools-${WASM_TOOLS_VERSION}-${arch}-linux"; \
    curl -fsSL "https://github.com/bytecodealliance/wasm-tools/releases/download/v${WASM_TOOLS_VERSION}/${name}.tar.gz" \
      | tar -xz -C /tmp; \
    install -m 0755 "/tmp/${name}/wasm-tools" /usr/local/bin/wasm-tools; \
    rm -rf "/tmp/${name}"

RUN rustup target add wasm32-unknown-unknown

# The same remapping ants uses, and for the same reason: rustc bakes the absolute path of every
# source file a panic can name into the binary, so without this a component's digest is a
# fingerprint of the machine that built it rather than of the source. A plugin digest is what the
# signature is over and what every node verifies, so it has to be reproducible.
#
# `/src=/soma` since the plugins moved here from the jodi repository on 16 September 2026, where it
# was `/src=/jodi`. That rename did NOT move either digest -- the release profile strips and aborts
# on panic, so no source path survives into these two components -- and the image still builds
# `tb-pairing` sha256:dac150b5... and `tb-rating` sha256:a962eade..., the bytes jodi's image built.
# Keep the remap anyway: it is what makes that true of a profile that someday keeps a path.
ENV RUSTFLAGS="--remap-path-prefix=/usr/local/cargo/registry/src=/cargo --remap-path-prefix=/usr/local/rustup/toolchains=/rustup --remap-path-prefix=/src=/soma"

WORKDIR /src/plugins
COPY plugins/ ./
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/src/plugins/target,sharing=locked \
    ./build.sh tb-pairing && ./build.sh tb-rating

# ---- the carrier -------------------------------------------------------------
FROM busybox:${BUSYBOX_VERSION}
LABEL org.opencontainers.image.title="soma package" \
      org.opencontainers.image.source="https://github.com/Tiny-Brains/soma" \
      org.opencontainers.image.description="the public /v1 API, the runner gate, the admit/pair/count/withdraw clocks and their connectors, the tb.rating and tb.pairing components, and the shared Postgres migrations"

COPY channels/             /artifacts/channels/
COPY workflows/            /artifacts/workflows/
COPY connectors/           /artifacts/connectors/
COPY migrations/           /artifacts/migrations/
COPY shared/               /artifacts/shared/
COPY scripts/load-package.sh scripts/stage-set.py /artifacts/scripts/
# plugin.toml is what `orion-server compile` reads a set's plugins from; plugin.json is the
# generated twin the signing script reads.
COPY plugins/tb-pairing/plugin.toml /artifacts/plugins/tb-pairing/
COPY plugins/tb-rating/plugin.toml  /artifacts/plugins/tb-rating/
COPY --from=plugins /src/plugins/tb-pairing/plugin.json /src/plugins/tb-pairing/tb-pairing.wasm /artifacts/plugins/tb-pairing/
COPY --from=plugins /src/plugins/tb-rating/plugin.json  /src/plugins/tb-rating/tb-rating.wasm  /artifacts/plugins/tb-rating/

# `docker run --rm -v soma-pkg:/out tinybrains/soma:dev` populates a volume with the whole package.
CMD ["sh", "-c", "cp -a /artifacts/. /out/"]
