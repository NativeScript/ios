#!/bin/bash
set -e

rm -rf ./dist
./update_version.sh
./build_metadata_generator.sh
./build_nativescript.sh --no-vision
./build_tklivesync.sh --no-vision
./prepare_dSYMs.sh
./build_npm_ios.sh