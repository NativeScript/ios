#!/bin/bash
set -e

# If a parameter is passed to this script then replace the version in package.json by appending $PACKAGE_VERSION
if [ -n "$1" ]; then
    jq ".version = \"$PACKAGE_VERSION\"" package.json > package.json.tmp && rm package.json && mv package.json.tmp package.json
fi

# NATIVESCRIPT_VERSION comes from package.json at build time
# (tools/generate-version-header.sh, run by the NativeScript target).