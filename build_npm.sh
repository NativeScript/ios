#!/bin/bash

OUTPUT_DIR="dist/npm"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/framework"
cp ./package.json "$OUTPUT_DIR"
cp -r "./project-template/" "$OUTPUT_DIR/framework"

cp -r "dist/NativeScript.framework" "$OUTPUT_DIR/framework/internal"

mkdir -p "$OUTPUT_DIR/framework/internal/metadata-generator"
cp -r "metadata-generator/bin" "$OUTPUT_DIR/framework/internal/metadata-generator"

cp -r "dist/TKLiveSync" "$OUTPUT_DIR/framework/internal"

pushd "$OUTPUT_DIR"
npm pack
popd