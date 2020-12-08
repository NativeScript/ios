#!/bin/bash
set -e

rm -rf ./dist
./build_metadata_generator.sh
./build_nativescript.sh
./build_tklivesync.sh
./build_npm.sh