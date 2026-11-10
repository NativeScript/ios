#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/build_utils.sh"

# Installs the prebuilt clang/LLVM static libraries the metadata generator links,
# built by NativeScript/ios-llvm, into ./llvm/<version>/{include,lib_<arch>}.
LLVM_VERSION="17.0.8"
ARCHS=()
FORCE=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [--arch <arm64|x86_64>]... [--force]

  --arch <arch>  Architecture to install (repeatable; default: arm64 and x86_64)
  --force        Reinstall even if the architecture is already in place
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --arch)
            [ $# -ge 2 ] || { echo "--arch requires a value" >&2; usage >&2; exit 2; }
            case "$2" in
                arm64|x86_64) ARCHS+=("$2") ;;
                *) echo "unsupported arch: $2" >&2; exit 2 ;;
            esac
            shift ;;
        --force) FORCE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# Every archive carries the same include/ apart from the host triple in
# llvm/Config/llvm-config.h, which the generator does not use; arm64 goes last
# so it is the one left in place.
[ "${#ARCHS[@]}" -gt 0 ] || ARCHS=(x86_64 arm64)

DEST="./llvm"
mkdir -p "$DEST"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

for arch in "${ARCHS[@]}"; do
    if [ "$FORCE" = 0 ] && [ -d "$DEST/$LLVM_VERSION/lib_$arch" ] && [ -d "$DEST/$LLVM_VERSION/include" ]; then
        continue
    fi
    archive="llvm-$LLVM_VERSION-$arch.tgz"
    checkpoint "Downloading llvm $LLVM_VERSION ($arch)..."
    curl -fL --retry 3 "https://github.com/NativeScript/ios-llvm/releases/download/v$LLVM_VERSION/$archive" -o "$TMP_DIR/$archive"
    rm -rf "${DEST:?}/$LLVM_VERSION/lib_$arch"
    tar -xzf "$TMP_DIR/$archive" -C "$DEST"
done
