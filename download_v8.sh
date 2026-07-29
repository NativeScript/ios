#!/bin/bash
set -euo pipefail
#
# Installs the prebuilt V8 libraries and headers for the pinned release.
#
# The artifacts are built by NativeScript/v8-buildscripts and published as
# GitHub release assets rather than committed here: the full matrix cannot be
# produced on any single machine (the 32-bit Android ABIs need an ia32 host,
# the Apple variants need macOS), so hand-assembled binaries are neither
# reproducible nor verifiable.
#
# Deliberately a standalone script rather than an Xcode build phase, matching
# download_llvm.sh: it is a prerequisite you run once, trivial to skip when you
# already have the artifacts, and easy to override with a local V8 build.
#
# Set V8_SKIP_DOWNLOAD=1 to make it a no-op -- use that when you have built V8
# yourself and do not want a pinned release overwriting it.
#
# Usage: download_v8.sh [--release <tag>] [--force]
#

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
UPSTREAM="NativeScript/v8-buildscripts"
RELEASE_FILE="$REPO_ROOT/V8_RELEASE"
CACHE_DIR="${V8_PREBUILT_CACHE:-$REPO_ROOT/.v8-prebuilt}"

NS_DIR="$REPO_ROOT/NativeScript"
LIB_DIR="$NS_DIR/lib"
STAMP="$LIB_DIR/.v8-release-stamp"

RELEASE=""
FORCE=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [--release <tag>] [--force]

  --release <tag>  Release to install (default: contents of V8_RELEASE)
  --force          Reinstall even if the pinned release is already in place

Downloads are cached in $CACHE_DIR (override with \$V8_PREBUILT_CACHE).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --release)   RELEASE="$2"; shift 2 ;;
        --release=*) RELEASE="${1#*=}"; shift ;;
        --force)     FORCE=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [ "${V8_SKIP_DOWNLOAD:-0}" != "0" ]; then
    echo "V8_SKIP_DOWNLOAD is set; leaving NativeScript/{lib,include,inspector} alone."
    exit 0
fi

if [ -z "$RELEASE" ]; then
    [ -f "$RELEASE_FILE" ] || { echo "Missing $RELEASE_FILE" >&2; exit 1; }
    RELEASE="$(tr -d '[:space:]' < "$RELEASE_FILE")"
fi

# The stamp alone is not enough: it says which release was installed, not that
# the three trees are still on disk. Re-install rather than leave a half-removed
# checkout looking up to date.
installed() {
    [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$RELEASE" ] \
        && [ -f "$NS_DIR/include/v8.h" ] && [ -d "$NS_DIR/inspector" ]
}

if [ "$FORCE" = "0" ] && installed; then
    echo "V8 $RELEASE already installed. Use --force to reinstall."
    exit 0
fi

# V8 has no visionOS target -- target_environment is only simulator, device or
# catalyst. It does not need one: the platform tag on a member of a static
# archive is advisory, and only the final linked image carries an
# LC_BUILD_VERSION, so a visionOS binary links the iOS archives directly. The
# xros directories are therefore copies of their iOS counterparts, which is
# exactly what shipped before this change.
VARIANTS=(
    "arm64-device:arm64-iphoneos arm64-xros"
    "arm64-simulator:arm64-iphonesimulator arm64-xrsimulator"
    "x64-simulator:x86_64-iphonesimulator"
    "arm64-catalyst:arm64-maccatalyst"
    "x64-catalyst:x86_64-maccatalyst"
)

BASE_URL="https://github.com/$UPSTREAM/releases/download/$RELEASE"
DL="$CACHE_DIR/$RELEASE"
mkdir -p "$DL"

fetch() {
    local name="$1"
    [ -f "$DL/$name" ] && return 0
    echo "  downloading $name"
    curl -fSL --retry 3 -o "$DL/$name.part" "$BASE_URL/$name"
    mv "$DL/$name.part" "$DL/$name"
}

echo "Installing V8 $RELEASE from $UPSTREAM"
fetch SHA256SUMS

ASSETS=()
for entry in "${VARIANTS[@]}"; do
    variant="${entry%%:*}"
    ASSETS+=("$(grep -oE "v8-[^ ]*-ios-$variant\.tar\.gz" "$DL/SHA256SUMS" | head -1)")
done
ASSETS+=("$(grep -oE 'v8-[^ ]*-src-headers\.tar\.gz' "$DL/SHA256SUMS" | head -1)")

for a in "${ASSETS[@]}"; do
    [ -n "$a" ] || { echo "Release $RELEASE is missing an expected asset." >&2; exit 1; }
    fetch "$a"
done

# Verify before unpacking anything. A release is only trustworthy because the
# archive matches the checksum published with it.
#
# Linux has sha256sum, macOS has shasum; neither has both reliably.
if command -v sha256sum > /dev/null 2>&1; then
    SHA256_CHECK="sha256sum -c -"
else
    SHA256_CHECK="shasum -a 256 -c -"
fi
echo "Verifying checksums"
( cd "$DL" && grep -E "$(printf '%s|' "${ASSETS[@]}" | sed 's/|$//')" SHA256SUMS | $SHA256_CHECK ) \
    || { echo "Checksum verification FAILED for $RELEASE" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
for a in "${ASSETS[@]}"; do tar -xzf "$DL/$a" -C "$STAGE"; done

echo "Installing libraries"
for entry in "${VARIANTS[@]}"; do
    variant="${entry%%:*}"
    src="$STAGE/ios-$variant/lib"
    [ -d "$src" ] || { echo "Archive for $variant has no lib/" >&2; exit 1; }
    for dest in ${entry#*:}; do
        mkdir -p "$LIB_DIR/$dest"
        # libffi.a is built by build_libffi.sh and lives in the same directory,
        # so only the V8 archives are replaced.
        find "$LIB_DIR/$dest" -maxdepth 1 -name '*.a' ! -name 'libffi.a' -delete
        cp "$src"/*.a "$LIB_DIR/$dest/"
    done
done

echo "Installing public headers"
# libffi's headers live in the same directory, so V8's are replaced selectively
# rather than by wiping include/.
SRC_INC="$STAGE/ios-arm64-device/include"
[ -d "$SRC_INC" ] || { echo "Archive has no include/" >&2; exit 1; }
for entry in cppgc libplatform inspector; do
    rm -rf "${NS_DIR:?}/include/$entry"
done
find "$NS_DIR/include" -maxdepth 1 -type f ! -name 'libffi.h' -delete
cp -R "$SRC_INC/." "$NS_DIR/include/"

echo "Vendoring the inspector's V8 internals"
# The closure is computed here rather than shipped, because what the glue
# includes is this repo's business, not the build repo's.
python3 "$REPO_ROOT/tools/v8/vendor_inspector_sources.py" \
    --v8-dir "$STAGE/src-headers" \
    --gen-dir "$STAGE/src-headers" \
    --dest "$NS_DIR/inspector"

echo "$RELEASE" > "$STAMP"
echo "Installed V8 $RELEASE"
