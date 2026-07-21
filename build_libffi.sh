#!/bin/bash
set -euo pipefail

# Builds static libffi slices from the ./libffi submodule for every platform
# the runtime ships, using the currently selected Xcode (xcode-select /
# DEVELOPER_DIR) instead of hardcoded /Applications/Xcode.app paths.
#
# Artifacts land in libffi/dist/<slice>/{lib/libffi.a,include}. With
# --install they are also copied into NativeScript/lib/<slice>/ and
# NativeScript/include/libffi/<arch>/ (the vendored locations the Xcode
# project links against).
#
# Note: all slices build from the same libffi source. On x86_64 the vector
# (SIMD) support caps at 16-byte vectors — wider vectors are rejected with
# FFI_BAD_TYPEDEF at prep time (documented libffi port limitation).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBFFI_DIR="$SCRIPT_DIR/libffi"
DIST_DIR="$LIBFFI_DIR/dist"

ALL_SLICES=(
  arm64-iphoneos
  arm64-iphonesimulator
  arm64-xros
  arm64-xrsimulator
  x86_64-iphonesimulator
  x86_64-maccatalyst
)

IOS_MIN=13.0
XROS_MIN=2.0
CATALYST_MIN=13.3

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [slice ...]

Builds libffi from the ./libffi submodule for the given slices
(default: all of ${ALL_SLICES[*]}).

Options:
  --install     also copy the built libraries and generated headers into
                NativeScript/lib/<slice>/ and NativeScript/include/libffi/<arch>/
  --jobs N      parallel make jobs (default: number of CPUs)
  -h, --help    show this help
EOF
}

INSTALL=0
JOBS="$(sysctl -n hw.ncpu)"
SLICES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)
      INSTALL=1
      ;;
    --jobs)
      shift
      if [ $# -eq 0 ] || ! [[ "$1" =~ ^[0-9]+$ ]]; then
        echo "--jobs requires a numeric argument" >&2
        usage
        exit 1
      fi
      JOBS="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      SLICES+=("$1")
      ;;
  esac
  shift
done

if [ ${#SLICES[@]} -eq 0 ]; then
  SLICES=("${ALL_SLICES[@]}")
fi

CLANG="$(xcrun -f clang)"
CLANGXX="$(xcrun -f clang++)"

# slice -> "sdk|host triple|target cflags"
slice_config() {
  case "$1" in
    arm64-iphoneos)
      echo "iphoneos|aarch64-apple-darwin|-arch arm64 -miphoneos-version-min=$IOS_MIN"
      ;;
    arm64-iphonesimulator)
      echo "iphonesimulator|aarch64-apple-darwin|-arch arm64 -mios-simulator-version-min=$IOS_MIN"
      ;;
    arm64-xros)
      echo "xros|aarch64-apple-darwin|-target arm64-apple-xros$XROS_MIN"
      ;;
    arm64-xrsimulator)
      echo "xrsimulator|aarch64-apple-darwin|-target arm64-apple-xros$XROS_MIN-simulator"
      ;;
    x86_64-iphonesimulator)
      echo "iphonesimulator|x86_64-apple-darwin|-arch x86_64 -mios-simulator-version-min=$IOS_MIN"
      ;;
    x86_64-maccatalyst)
      echo "macosx|x86_64-apple-darwin|-target x86_64-apple-ios$CATALYST_MIN-macabi"
      ;;
    *)
      echo ""
      ;;
  esac
}

for slice in "${SLICES[@]}"; do
  if [ -z "$(slice_config "$slice")" ]; then
    echo "Unknown slice: $slice (known: ${ALL_SLICES[*]})" >&2
    exit 1
  fi
done

pushd "$LIBFFI_DIR" >/dev/null
# Regenerate the build system so a submodule bump can never pair stale
# configure output with new sources. macOS installs GNU libtoolize as
# glibtoolize (via Homebrew).
LIBTOOLIZE="${LIBTOOLIZE:-glibtoolize}" ./autogen.sh
popd >/dev/null

rm -rf "$DIST_DIR"

for slice in "${SLICES[@]}"; do
  IFS='|' read -r sdk host target_cflags <<< "$(slice_config "$slice")"
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  build_dir="$LIBFFI_DIR/build-$slice"
  out_dir="$DIST_DIR/$slice"

  echo "==> $slice (sdk: $(basename "$sdk_path"))"

  rm -rf "$build_dir"
  mkdir -p "$build_dir" "$out_dir/lib" "$out_dir/include"

  pushd "$build_dir" >/dev/null
  CC="$CLANG $target_cflags -isysroot $sdk_path" \
  CXX="$CLANGXX $target_cflags -isysroot $sdk_path" \
    "$LIBFFI_DIR/configure" --disable-shared --disable-docs --host="$host" >/dev/null

  make -j"$JOBS" >/dev/null

  cp .libs/libffi.a "$out_dir/lib/libffi.a"
  cp include/ffi.h include/ffitarget.h "$out_dir/include/"
  popd >/dev/null

  rm -rf "$build_dir"
done

if [ "$INSTALL" -eq 1 ]; then
  for slice in "${SLICES[@]}"; do
    arch="${slice%%-*}"
    echo "==> installing $slice"
    mkdir -p "$SCRIPT_DIR/NativeScript/lib/$slice" "$SCRIPT_DIR/NativeScript/include/libffi/$arch"
    cp "$DIST_DIR/$slice/lib/libffi.a" "$SCRIPT_DIR/NativeScript/lib/$slice/libffi.a"
    # The generated headers are identical for every slice of the same arch.
    cp "$DIST_DIR/$slice/include/ffi.h" "$DIST_DIR/$slice/include/ffitarget.h" \
       "$SCRIPT_DIR/NativeScript/include/libffi/$arch/"
    # Upstream ffi.h includes its sibling with angle brackets, which only
    # resolves in Xcode via basename headermaps — ambiguous with two arch
    # copies of ffitarget.h in the project. Use a quoted include so each
    # ffi.h deterministically picks up the ffitarget.h next to it.
    sed -i '' 's|#include <ffitarget.h>|#include "ffitarget.h"|' \
      "$SCRIPT_DIR/NativeScript/include/libffi/$arch/ffi.h"
  done
fi

echo "Done. Artifacts in $DIST_DIR"
