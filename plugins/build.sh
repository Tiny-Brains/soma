#!/bin/sh
# Rebuild one plugin's component and manifest, and place both beside its source.
#
#   plugins/build.sh tb-rating
#
# Each plugin also has its own build.sh calling this one, because building the wrong plugin is
# indistinguishable from building the right one until the component is loaded.
#
# Needs the wasm32-unknown-unknown target (`rustup target add wasm32-unknown-unknown`) and
# `wasm-tools` (`cargo install wasm-tools`). The outputs are gitignored: the image builds its own
# under a pinned toolchain, and this is how a change is tried locally.
#
# The host tests are the gate and run first: these two plugins are the only arithmetic that writes
# a ladder and the only thing that decides who plays whom.
set -eu

plugin="${1:?usage: plugins/build.sh <plugin-dir-name>}"
here=$(cd "$(dirname "$0")" && pwd)
dir="$here/$plugin"
[ -d "$dir" ] || { echo "no such plugin: $plugin" >&2; exit 1; }

cd "$here"
cargo test -p "$plugin"
cargo build -p "$plugin" --release --target wasm32-unknown-unknown

wasm-tools component new \
  "target/wasm32-unknown-unknown/release/$(echo "$plugin" | tr - _).wasm" \
  -o "$dir/$plugin.wasm"
wasm-tools validate "$dir/$plugin.wasm" --features component-model

# plugin.toml is the authored manifest -- what `orion-server compile` and web's signing script
# read -- and plugin.json is its generated JSON twin. Build output like the component: never
# hand-edited, never committed.
python3 - "$dir/plugin.toml" "$dir/plugin.json" <<'PYEOF'
import json, sys, tomllib
src, dst = sys.argv[1], sys.argv[2]
with open(src, "rb") as f:
    manifest = tomllib.load(f)
with open(dst, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PYEOF

ls -l "$dir/$plugin.wasm" "$dir/plugin.json"
