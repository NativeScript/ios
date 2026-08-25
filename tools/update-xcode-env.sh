#!/bin/sh
# Records a node binary in .xcode.env.local at the repo root so Xcode build
# phases can use it. Xcode runs build phases with a minimal PATH and never
# reads your shell profile, so the node this shell sees has to be written
# down somewhere Xcode looks (see .xcode.env). Only the NODE_BINARY line is
# replaced; other variables in .xcode.env.local are preserved.
set -eu

usage() {
  echo "usage: tools/update-xcode-env.sh [node-binary]" >&2
  echo "       node-binary defaults to the node on this shell's PATH" >&2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

repo_root=$(cd "$(dirname "$0")/.." && pwd)
env_local="$repo_root/.xcode.env.local"

node_bin="${1:-$(command -v node || true)}"
if [ -z "$node_bin" ]; then
  echo "error: node is not on PATH; pass a binary explicitly: tools/update-xcode-env.sh /path/to/node" >&2
  exit 1
fi
if [ ! -x "$node_bin" ]; then
  echo "error: '$node_bin' is not executable" >&2
  exit 1
fi

tmp="$env_local.tmp"
if [ -f "$env_local" ]; then
  grep -v '^export NODE_BINARY=' "$env_local" > "$tmp" || true
else
  : > "$tmp"
fi
printf 'export NODE_BINARY="%s"\n' "$node_bin" >> "$tmp"
mv "$tmp" "$env_local"
echo "NODE_BINARY=\"$node_bin\" written to $env_local"
