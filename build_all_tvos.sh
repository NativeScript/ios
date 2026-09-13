#!/bin/bash
set -e

# Arguments (e.g. --spm-mode <embedded|remote>) are forwarded to
# build_npm_tvos.sh; run it with --help for details.
for arg in "$@"; do
  if [ "$arg" = "-h" ] || [ "$arg" = "--help" ]; then
    echo "Usage: ./build_all_tvos.sh [--spm-mode <embedded|remote>]"
    echo "Arguments are forwarded to build_npm_tvos.sh (see ./build_npm_tvos.sh --help)."
    echo ""
    echo "V8: the pinned release's tvOS slices are installed with download_v8.sh --tvos."
    echo "Set V8_TVOS_BUILD to a built NativeScript/v8-buildscripts checkout to use a"
    echo "source build instead (see scripts/install-tvos-v8.sh)."
    exit 0
  fi
done

if [ -n "${V8_TVOS_BUILD:-}" ]; then
  ./scripts/install-tvos-v8.sh "$V8_TVOS_BUILD"
  # The source build supplied the archives, headers and inspector sources;
  # the pinned release must not overwrite them from here on.
  export V8_SKIP_DOWNLOAD=1
else
  ./download_v8.sh --tvos
fi

rm -rf ./dist
./update_version.sh
./build_metadata_generator.sh
./build_nativescript.sh --no-catalyst --no-iphone --no-sim --no-vision --tvos
./build_tklivesync.sh --no-catalyst --no-iphone --no-sim --no-vision --tvos
./prepare_dSYMs.sh
./build_spm_artifacts.sh tvos
./build_npm_tvos.sh "$@"
