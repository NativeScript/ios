#!/bin/bash
set -e

rm -rf ./dist
./update_version.sh
./build_metadata_generator.sh
./build_nativescript.sh --no-catalyst --no-iphone --no-sim --no-xr
./build_tklivesync.sh --no-catalyst --no-iphone --no-sim --no-xr
./prepare_dSYMs.sh
./build_npm_tvos.sh