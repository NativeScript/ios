#!/bin/bash
set -e
source "$(dirname "$0")/build_utils.sh"

checkpoint "Preparing npm package for iOS..."
OUTPUT_DIR="dist/npm"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/framework"
cp ./package.json "$OUTPUT_DIR"

cp -r "./project-template-ios/" "$OUTPUT_DIR/framework"

cp -r "dist/NativeScript.xcframework" "$OUTPUT_DIR/framework/internal"
cp -r "dist/TKLiveSync.xcframework" "$OUTPUT_DIR/framework/internal"

mkdir -p "$OUTPUT_DIR/framework/internal/metadata-generator-x86_64"
cp -r "metadata-generator/dist/x86_64/." "$OUTPUT_DIR/framework/internal/metadata-generator-x86_64"

mkdir -p "$OUTPUT_DIR/framework/internal/metadata-generator-arm64"
cp -r "metadata-generator/dist/arm64/." "$OUTPUT_DIR/framework/internal/metadata-generator-arm64"

# Add xcframeworks to .zip (NPM modules do not support symlinks, unzipping is done by {N} CLI)
(
    set -e
    cd $OUTPUT_DIR/framework/internal
    zip -qr --symlinks XCFrameworks.zip *.xcframework
    rm -rf *.xcframework
)

pushd "$OUTPUT_DIR"
npm pack
mv *.tgz ../
popd

checkpoint "npm package created."