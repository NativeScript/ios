#!/bin/bash
set -e

# If a parameter is passed to this script then replace the version in package.json by appending $PACKAGE_VERSION
if [ -n "$1" ]; then
    jq ".version = \"$PACKAGE_VERSION\"" package.json > package.json.tmp && rm package.json && mv package.json.tmp package.json
fi

# Read the version from package.json and replace it inside the NativeScript-Prefix.pch precompiled header
FULL_VERSION=$(jq -r .version package.json)
sed -i.bak "s/#define[[:space:]]*NATIVESCRIPT_VERSION[[:space:]]*\"\(.*\)\"/#define NATIVESCRIPT_VERSION \"$FULL_VERSION\"/g" NativeScript/NativeScript-Prefix.pch && rm NativeScript/NativeScript-Prefix.pch.bak