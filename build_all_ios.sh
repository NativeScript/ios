#!/bin/bash
set -e

# Arguments (e.g. --spm-mode <embedded|remote>) are forwarded to
# build_npm_ios.sh; run it with --help for details.
for arg in "$@"; do
  if [ "$arg" = "-h" ] || [ "$arg" = "--help" ]; then
    echo "Usage: ./build_all_ios.sh [--spm-mode <embedded|remote>]"
    echo "Arguments are forwarded to build_npm_ios.sh (see ./build_npm_ios.sh --help)."
    exit 0
  fi
done

rm -rf ./dist
./update_version.sh
./build_metadata_generator.sh
./build_nativescript.sh --no-vision
./build_tklivesync.sh --no-vision
./prepare_dSYMs.sh
./build_spm_artifacts.sh ios
./build_npm_ios.sh "$@"
