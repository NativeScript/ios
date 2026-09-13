#!/bin/bash
# Install source-built tvOS artifacts from NativeScript/v8-buildscripts.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:?Usage: scripts/install-tvos-v8.sh /path/to/v8-buildscripts}"
BUILD="$(cd "$BUILD" && pwd)"
VERSION="$(sed -E 's/^v8-(.*)-[0-9]+$/\1/' "$ROOT/V8_RELEASE")"
for variant in arm64-tvdevice arm64-tvsimulator; do
  test "$(cat "$BUILD/dist/ios-$variant/V8_VERSION")" = "$VERSION" || {
    echo "V8 version mismatch for $variant; expected $VERSION" >&2; exit 1;
  }
  test -f "$BUILD/dist/ios-$variant/lib/libv8_base_without_compiler.a"
done
for pair in arm64-tvdevice:arm64-appletvos arm64-tvsimulator:arm64-appletvsimulator; do
  src="$BUILD/dist/ios-${pair%%:*}"
  dest="$ROOT/NativeScript/lib/${pair#*:}"
  mkdir -p "$dest"
  find "$dest" -maxdepth 1 -name '*.a' ! -name libffi.a -delete
  cp "$src/lib/"*.a "$dest/"
done
# Headers and inspector sources must come from the same V8 build as the archives.
cp -R "$BUILD/dist/ios-arm64-tvdevice/include/." "$ROOT/NativeScript/include/"
python3 "$ROOT/tools/v8/vendor_inspector_sources.py" \
  --v8-dir "$BUILD/.v8/v8" \
  --gen-dir "$BUILD/.v8/v8/out.gn/arm64-tvdevice-release/gen" \
  --dest "$ROOT/NativeScript/inspector"
echo "$VERSION" > "$ROOT/NativeScript/lib/.tvos-v8-version"
