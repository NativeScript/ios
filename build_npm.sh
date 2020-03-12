#!/bin/bash
set -e

OUTPUT_DIR="dist/npm"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/framework"
cp ./package.json "$OUTPUT_DIR"
cp -r "./project-template/" "$OUTPUT_DIR/framework"

cp -r "dist/NativeScript.xcframework" "$OUTPUT_DIR/framework/internal"
cp -r "dist/TKLiveSync.xcframework" "$OUTPUT_DIR/framework/internal"

mkdir -p "$OUTPUT_DIR/framework/internal/metadata-generator"
cp -r "metadata-generator/bin" "$OUTPUT_DIR/framework/internal/metadata-generator"

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