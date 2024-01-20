#!/bin/bash
set -e

rm -rf ./dist
./update_version.sh
./build_metadata_generator.sh
./build_nativescript.sh
./build_tklivesync.sh
./prepare_dSYMs.sh
./build_npm_vision.sh