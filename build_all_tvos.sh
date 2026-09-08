#!/bin/bash
set -e

# tvOS archives must be built for this runtime's pinned V8 version.
./scripts/install-tvos-v8.sh "${V8_TVOS_BUILD:?Set V8_TVOS_BUILD to the built v8-buildscripts checkout}"
# Keep the matching source-built headers and inspector sources.
export V8_SKIP_DOWNLOAD=1
git submodule update --init libffi
./build_libffi.sh --install arm64-appletvos arm64-appletvsimulator
./tools/update-xcode-env.sh
rm -rf ./dist
./update_version.sh
./build_metadata_generator.sh
./build_nativescript.sh --no-catalyst --no-iphone --no-sim --no-vision --tvos
./build_tklivesync.sh --no-catalyst --no-iphone --no-sim --no-vision --tvos
./prepare_dSYMs.sh
./build_npm_tvos.sh
