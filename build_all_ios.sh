#!/bin/bash
set -e

rm -rf ./dist
./update_version.sh
./build_metadata_generator.sh
BUILD_VISION=false ./build_nativescript.sh
BUILD_VISION=false ./build_tklivesync.sh
./prepare_dSYMs.sh
./build_npm_ios.sh