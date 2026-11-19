#!/bin/bash
set -euo pipefail
#
# Installs the prebuilt libffi libraries and headers for the pinned release.
#
# The artifacts are built by NativeScript/libffi-buildscripts from upstream's
# checksummed release tarball and published as GitHub release assets rather
# than committed here, so every binary traces back to a CI run and a source
# checksum.
#
# Like download_v8.sh, this is a standalone prerequisite rather than an Xcode
# build phase: run it once; it is a no-op while the pinned release is in place.
#
# Usage: download_libffi.sh [--release <tag>] [--from-dir <dist>] [--force]
#

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
UPSTREAM="NativeScript/libffi-buildscripts"
RELEASE_FILE="$REPO_ROOT/LIBFFI_RELEASE"
CACHE_DIR="${LIBFFI_PREBUILT_CACHE:-$REPO_ROOT/.libffi-prebuilt}"

NS_DIR="$REPO_ROOT/NativeScript"
LIB_DIR="$NS_DIR/lib"
INC_DIR="$NS_DIR/include/libffi"
STAMP="$LIB_DIR/.libffi-release-stamp"

RELEASE=""
FROM_DIR=""
FORCE=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [--release <tag>] [--from-dir <dist>] [--force]

  --release <tag>   Release to install (default: contents of LIBFFI_RELEASE)
  --from-dir <dist> Install from a local libffi-buildscripts build instead: the
                    directory holding its ios-<variant>/ folders (its dist/).
                    Later runs without --force leave that install alone.
  --force           Reinstall even if the pinned release is already in place

Downloads are cached in $CACHE_DIR (override with \$LIBFFI_PREBUILT_CACHE).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --release)    RELEASE="$2"; shift 2 ;;
        --release=*)  RELEASE="${1#*=}"; shift ;;
        --from-dir)   FROM_DIR="$2"; shift 2 ;;
        --from-dir=*) FROM_DIR="${1#*=}"; shift ;;
        --force)      FORCE=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [ -n "$RELEASE" ] && [ -n "$FROM_DIR" ]; then
    echo "--release and --from-dir are mutually exclusive" >&2
    exit 1
fi

if [ -z "$RELEASE" ] && [ -z "$FROM_DIR" ]; then
    [ -f "$RELEASE_FILE" ] || { echo "Missing $RELEASE_FILE" >&2; exit 1; }
    RELEASE="$(tr -d '[:space:]' < "$RELEASE_FILE")"
fi

# Release variant -> the runtime's library directories it is installed into.
VARIANTS=(
    "arm64-device:arm64-iphoneos"
    "arm64-simulator:arm64-iphonesimulator"
    "x64-simulator:x86_64-iphonesimulator"
    "arm64-catalyst:arm64-maccatalyst"
    "x64-catalyst:x86_64-maccatalyst"
    "arm64-xrdevice:arm64-xros"
    "arm64-xrsimulator:arm64-xrsimulator"
)
# The generated headers depend only on the architecture.
HEADER_SOURCES=(
    "arm64:arm64-device"
    "x86_64:x64-simulator"
)

# The stamp alone is not enough: it says what was installed, not that the
# files are still on disk.
files_present() {
    local entry
    for entry in "${VARIANTS[@]}"; do
        [ -f "$LIB_DIR/${entry#*:}/libffi.a" ] || return 1
    done
    for entry in "${HEADER_SOURCES[@]}"; do
        [ -f "$INC_DIR/${entry%%:*}/ffi.h" ] && [ -f "$INC_DIR/${entry%%:*}/ffitarget.h" ] || return 1
    done
}

if [ "$FORCE" = "0" ] && [ -z "$FROM_DIR" ] && [ -f "$STAMP" ] && files_present; then
    installed="$(cat "$STAMP")"
    if [ "$installed" = "$RELEASE" ]; then
        echo "libffi $RELEASE already installed. Use --force to reinstall."
        exit 0
    fi
    case "$installed" in
        local:*)
            echo "libffi from ${installed#local:} is installed; leaving it in place."
            echo "Use --force to install $RELEASE instead."
            exit 0
            ;;
    esac
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

if [ -n "$FROM_DIR" ]; then
    FROM_DIR="$(cd "$FROM_DIR" && pwd)"
    echo "Installing libffi from $FROM_DIR"
    for entry in "${VARIANTS[@]}"; do
        variant="${entry%%:*}"
        [ -d "$FROM_DIR/ios-$variant" ] || { echo "$FROM_DIR has no ios-$variant/" >&2; exit 1; }
        cp -R "$FROM_DIR/ios-$variant" "$STAGE/"
    done
    STAMP_VALUE="local:$FROM_DIR"
else
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

    echo "Installing libffi $RELEASE from $UPSTREAM"
    fetch SHA256SUMS

    ASSETS=()
    for entry in "${VARIANTS[@]}"; do
        variant="${entry%%:*}"
        asset="$(grep -oE "libffi-[^ ]*-ios-$variant\.tar\.gz" "$DL/SHA256SUMS" | head -1 || true)"
        [ -n "$asset" ] || { echo "Release $RELEASE has no ios-$variant archive." >&2; exit 1; }
        ASSETS+=("$asset")
        fetch "$asset"
    done

    # Verify before unpacking anything: a release is only trustworthy because
    # the archive matches the checksum published with it.
    if command -v sha256sum > /dev/null 2>&1; then
        SHA256_CHECK="sha256sum -c -"
    else
        SHA256_CHECK="shasum -a 256 -c -"
    fi
    echo "Verifying checksums"
    ( cd "$DL" && grep -E "$(printf '%s|' "${ASSETS[@]}" | sed 's/|$//')" SHA256SUMS | $SHA256_CHECK ) \
        || { echo "Checksum verification FAILED for $RELEASE" >&2; exit 1; }

    for a in "${ASSETS[@]}"; do tar -xzf "$DL/$a" -C "$STAGE"; done
    STAMP_VALUE="$RELEASE"
fi

echo "Installing libraries"
for entry in "${VARIANTS[@]}"; do
    variant="${entry%%:*}"
    dest="$LIB_DIR/${entry#*:}"
    src="$STAGE/ios-$variant/lib/libffi.a"
    [ -f "$src" ] || { echo "ios-$variant has no lib/libffi.a" >&2; exit 1; }
    mkdir -p "$dest"
    cp "$src" "$dest/libffi.a"
done

echo "Installing headers"
for entry in "${HEADER_SOURCES[@]}"; do
    arch="${entry%%:*}"
    src="$STAGE/ios-${entry#*:}/include"
    [ -f "$src/ffi.h" ] && [ -f "$src/ffitarget.h" ] || { echo "ios-${entry#*:} has no ffi headers" >&2; exit 1; }
    mkdir -p "$INC_DIR/$arch"
    cp "$src/ffi.h" "$src/ffitarget.h" "$INC_DIR/$arch/"
    # Upstream's ffi.h includes <ffitarget.h>, which Xcode resolves through a
    # basename headermap -- ambiguous with both architectures' copies in the
    # project. A quoted include always picks the ffitarget.h beside it.
    sed -i '' 's|#include <ffitarget.h>|#include "ffitarget.h"|' "$INC_DIR/$arch/ffi.h"
done

echo "$STAMP_VALUE" > "$STAMP"
echo "Installed libffi ${STAMP_VALUE}"
