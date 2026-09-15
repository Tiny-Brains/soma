# syntax=docker/dockerfile:1

# The Soma package as an ARTIFACT IMAGE: the public /v1 HTTP API, and the Postgres migrations
# everything on this platform shares.
#
# NOTHING HERE IS GENERATED. Unlike jodi and kalam, this package has no generator and no plugin:
# every channel, workflow, connector and migration is authored and committed. So this image exists
# for the other half of the same problem -- devops mounted `../soma` and `../soma/migrations/*.sql`
# by path, which made a checkout of this repository beside it part of how the stack comes up. The
# package travels as an image now, and a deployment needs no checkout of it at all.
#
# THE MIGRATIONS ARE CARRIED, NOT RENAMED. devops slots them into Postgres's init directory under
# names that fix their order relative to its own scripts (`20-`, `25-`, between its `10-` and `30-`).
# That ordering is devops' decision and does not belong in this image, so what ships here is
# `migrations/` under its own names, exactly as the repository holds it.

ARG BUSYBOX_VERSION=1.37-musl

FROM busybox:${BUSYBOX_VERSION}
LABEL org.opencontainers.image.title="soma package" \
      org.opencontainers.image.source="https://github.com/Tiny-Brains/soma" \
      org.opencontainers.image.description="the public /v1 API as Orion channels and workflows, its connectors, and the shared Postgres migrations"

COPY channels/             /artifacts/channels/
COPY workflows/            /artifacts/workflows/
COPY connectors/           /artifacts/connectors/
COPY migrations/           /artifacts/migrations/
COPY shared/               /artifacts/shared/
COPY scripts/load-package.sh scripts/stage-set.py /artifacts/scripts/

# `docker run --rm -v soma-pkg:/out tinybrains/soma:dev` populates a volume with the whole package.
CMD ["sh", "-c", "cp -a /artifacts/. /out/"]
