#!/usr/bin/env bash
# Every check that reads the definitions and nothing else. No database, no stack, no Docker --
# so this is the one to run on every change and the one a CI job runs first.
#
#   ./scripts/check-defs.sh
#
# Two gates, and between them they are everything:
#
#   clippy   RUNS LINT'S GATE FIRST -- the set resolves, every reference, every function input
#            schema, every declared env var -- and stops on it ("N lint error(s) -- fix those
#            first; clippy's rules did not run"). So `lint` is not run separately: it would be the
#            same work twice. Then clippy's own rules: what lint cannot prove but can be certain
#            of -- a run of steps repeating one condition, an object copied across the set, an
#            input key the function ignores. An ignored input key is silent at run time and a
#            whole feature stops working, which is why it is --deny-warnings.
#   fmt      the house style, so a diff is the change and not a reformat.
#
# clippy runs TWICE, and the second run is not a repeat: three rules say nothing without the
# serving config, and "said nothing" reads exactly like "found nothing".
#
# What this does NOT check is whether the SQL inside those definitions resolves against the
# schema -- that is ./scripts/check-sql.sh, which needs the database -- or the plugins' arithmetic,
# which is `cargo test --manifest-path plugins/Cargo.toml`.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v orion-server > /dev/null || {
  echo "orion-server is not on PATH -- this repo is an Orion package and the binary is its compiler" >&2
  exit 1
}

# WHICH orion-server is not asked here. shared/package.json declares `requires.orion`, and lint,
# clippy, fmt and compile each check the running binary against it before anything else -- one
# declaration instead of a version test per script, and it travels with the package to `apply`.

echo "==> clippy (lint's gate, then the rules that need no config)"
orion-server clippy . --deny-warnings

echo "==> fmt"
orion-server fmt --check .

# ---------------------------------------------------------------- the names and the sql/ directory
# Orion checks that every reference RESOLVES; it has no opinion about what anything is CALLED, and
# `?tag=` is the only way to navigate a list. So the naming rules are checked here or nowhere.
echo "==> names, tags and the sql/ directory"
./scripts/check-names.sh

# ---------------------------------------------------------------- the serving config's rules
# Three clippy rules need the config the node will actually serve with, because what they prove is
# a definition against a setting: a `[vars]` name nothing declares, a `secret` nothing supplies,
# and a `model_infer` deadline `[models]` would silently clamp. Without -c they are SKIPPED, which
# reads as a pass -- so they are run again here against the template the image ships.
#
# STAND-IN VALUES FOR WHAT THE TEMPLATE REQUIRES: the two `${NAME:?message}` placeholders and the
# two `env://` references the config itself resolves. `${NAME:?message}` stops a boot when the
# variable is unset or empty, which is what it is for -- and this is a static check, not a boot, so
# it supplies something shaped right and obviously fake. Everything else in the template has a
# default. Note that a variable named only in a COMMENT is NOT required: Orion skips the file's
# comments when it substitutes, so the prose here can spell a form out without demanding it.
echo "==> clippy against the shipped instance config"
ORION_ADMIN_KEY=check-defs-not-a-key \
TB_TRUST_PUBLIC_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAI= \
ORION_STATE_DB_URL=postgres://check-defs/orion_state \
REDIS_URL=redis://check-defs:6379/0 \
  orion-server clippy . -c docker/soma.toml.tmpl --deny-warnings

echo "==> Soma's definitions are clean"
