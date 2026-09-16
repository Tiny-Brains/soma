#!/bin/sh
# Rebuild tb-pairing. The work is in ../build.sh; this names which plugin to do it to.
set -eu
exec "$(cd "$(dirname "$0")/.." && pwd)/build.sh" tb-pairing
