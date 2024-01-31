#!/bin/bash
set -e

rm -rf ./dist
./update_version.sh
./build_metadata_generator.sh
BUILD_CATALYST=false BUILD_IPHONE=false BUILD_SIMULATOR=false ./build_nativescript.sh
BUILD_CATALYST=false BUILD_IPHONE=false BUILD_SIMULATOR=false ./build_tklivesync.sh
./prepare_dSYMs.sh
./build_npm_vision.sh