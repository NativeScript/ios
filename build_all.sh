#!/bin/bash
set -e

rm -rf ./dist
./update_version.sh
./build_v8_source.sh
./build_v8_source_catalyst.sh
./build_metadata_generator.sh
./build_nativescript.sh
./build_tklivesync.sh
./build_npm.sh
