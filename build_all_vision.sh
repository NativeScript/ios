#!/bin/bash
set -e

# Arguments (e.g. --spm-mode <embedded|remote>) are forwarded to
# build_npm_vision.sh; run it with --help for details.
for arg in "$@"; do
  if [ "$arg" = "-h" ] || [ "$arg" = "--help" ]; then
    echo "Usage: ./build_all_vision.sh [--spm-mode <embedded|remote>]"
    echo "Arguments are forwarded to build_npm_vision.sh (see ./build_npm_vision.sh --help)."
    exit 0
  fi
done

rm -rf ./dist
./update_version.sh
./build_metadata_generator.sh
./build_nativescript.sh --no-catalyst --no-iphone --no-sim
./build_tklivesync.sh --no-catalyst --no-iphone --no-sim
./prepare_dSYMs.sh
./build_spm_artifacts.sh visionos
./build_npm_vision.sh "$@"
