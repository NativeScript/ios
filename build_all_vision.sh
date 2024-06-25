#!/bin/bash
set -e

rm -rf ./dist
./update_version.sh
./build_metadata_generator.sh
./build_nativescript.sh --no-catalyst --no-iphone --no-sim
./build_tklivesync.sh --no-catalyst --no-iphone --no-sim
./prepare_dSYMs.sh
./build_npm_vision.sh