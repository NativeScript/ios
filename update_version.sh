#!/bin/bash
set -e

# If a parameter is passed to this script then replace the version in package.json by appending $PACKAGE_VERSION
if [ -n "$1" ]; then
    sed -i.bak "s/\"version\"[[:space:]]*:[[:space:]]*\"\(.*\)\"[[:space:]]*,/\"version\": \"\1-$PACKAGE_VERSION\",/g" package.json && rm package.json.bak
fi

# Read the version from package.json and replace it inside the NativeScript-Prefix.pch precompiled header
FULL_VERSION=$(sed -nE "s/.*(\"version\"[[:space:]]*:[[:space:]]*\"(.+)\"[[:space:]]*,).*/\2/p" package.json)
sed -i.bak "s/#define[[:space:]]*NATIVESCRIPT_VERSION[[:space:]]*\"\(.*\)\"/#define NATIVESCRIPT_VERSION \"$FULL_VERSION\"/g" NativeScript/NativeScript-Prefix.pch && rm NativeScript/NativeScript-Prefix.pch.bak