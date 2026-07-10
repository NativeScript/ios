#!/bin/bash
# Package the built xcframeworks as SwiftPM binary-target artifacts:
#   * a .zip per xcframework (framework at the zip root, symlinks preserved)
#   * a SHA-256 checksum for each (the value SwiftPM's binaryTarget(checksum:) expects)
#
# Output goes to dist/artifacts/:
#   <name>.zip                and a combined checksums.env (KEY=sha256 lines)
#
# Usage: ./build_spm_artifacts.sh [ios|visionos]   (default: ios)
#
# These artifacts are uploaded to the GitHub Release and referenced by
# github.com/NativeScript/ios-spm (see scripts/stamp-spm-release.mjs).
set -e
source "$(dirname "$0")/build_utils.sh"

TARGET="${1:-ios}"
DIST="$(pwd)/dist"
OUT="$DIST/artifacts"

case "$TARGET" in
  ios)
    NS_ZIP="NativeScript.xcframework.zip"
    TK_ZIP="TKLiveSync.xcframework.zip"
    NS_KEY="NS_CHECKSUM_NATIVESCRIPT_IOS"
    TK_KEY="NS_CHECKSUM_TKLIVESYNC_IOS"
    ;;
  visionos|vision|xr)
    TARGET="visionos"
    NS_ZIP="NativeScript.visionos.xcframework.zip"
    TK_ZIP="TKLiveSync.visionos.xcframework.zip"
    NS_KEY="NS_CHECKSUM_NATIVESCRIPT_VISIONOS"
    TK_KEY="NS_CHECKSUM_TKLIVESYNC_VISIONOS"
    ;;
  *)
    echo "Unknown target '$TARGET' (expected ios or visionos)" >&2
    exit 1
    ;;
esac

checkpoint "Packaging SwiftPM artifacts for $TARGET..."
rm -rf "$OUT"
mkdir -p "$OUT"

# SwiftPM's binaryTarget(checksum:) is the SHA-256 of the zip. `swift package
# compute-checksum` is the canonical producer; shasum -a 256 yields the same
# value and is the portable fallback.
compute_checksum() {
  local zip="$1"
  if command -v swift >/dev/null 2>&1 && swift package compute-checksum "$zip" >/dev/null 2>&1; then
    swift package compute-checksum "$zip"
  else
    shasum -a 256 "$zip" | awk '{print $1}'
  fi
}

# zip_xcframework <SourceXcframeworkDir> <OutputZipName>
zip_xcframework() {
  local src="$1" zipname="$2"
  if [ ! -d "$DIST/$src" ]; then
    echo "Missing $DIST/$src — run the runtime build first." >&2
    exit 1
  fi
  ( cd "$DIST" && zip -qr --symlinks "$OUT/$zipname" "$src" )
}

zip_xcframework "NativeScript.xcframework" "$NS_ZIP"
zip_xcframework "TKLiveSync.xcframework" "$TK_ZIP"

NS_SUM="$(compute_checksum "$OUT/$NS_ZIP")"
TK_SUM="$(compute_checksum "$OUT/$TK_ZIP")"

# Per-target filename so the iOS and visionOS env files don't collide when the
# release/stamp jobs merge both platforms' artifacts into one directory.
CHECKSUMS="$OUT/checksums-$TARGET.env"
{
  echo "${NS_KEY}=${NS_SUM}"
  echo "${TK_KEY}=${TK_SUM}"
} > "$CHECKSUMS"

checkpoint "SwiftPM artifacts ready in $OUT:"
( cd "$OUT" && ls -lh *.zip )
echo "Checksums ($CHECKSUMS):"
cat "$CHECKSUMS"
