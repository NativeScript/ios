#!/bin/bash
# Regenerates the checked-in symbol graphs under symbolgraphs/.
# The parser tests snapshot these files, so regenerate only when the fixture
# sources change or when deliberately adopting a new toolchain's output.
set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$FIXTURE_DIR/symbolgraphs"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"

xcrun swiftc \
  -emit-module \
  -emit-module-path "$WORK_DIR/SwiftDemo.swiftmodule" \
  -emit-symbol-graph \
  -emit-symbol-graph-dir "$WORK_DIR" \
  -symbol-graph-minimum-access-level public \
  -module-name SwiftDemo \
  -target arm64-apple-ios15.0-simulator \
  -sdk "$SDK_PATH" \
  "$FIXTURE_DIR"/Sources/SwiftDemo/*.swift

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
cp "$WORK_DIR"/*.symbols.json "$OUT_DIR/"

# Absolute source paths differ per machine; keep the fixture reproducible.
sed -i '' "s#file://$FIXTURE_DIR/#file://#g" "$OUT_DIR"/*.symbols.json

ls -1 "$OUT_DIR"
