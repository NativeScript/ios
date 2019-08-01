#!/bin/bash

OUTPUT_DIR="build/npm"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/framework"
cp ./package.json "$OUTPUT_DIR"
cp -r "./project-template/" "$OUTPUT_DIR/framework"

cp -r "build/NativeScript.framework" "$OUTPUT_DIR/framework/internal"

mkdir -p "$OUTPUT_DIR/framework/internal/metadata-generator"
cp -r "metadata-generator/bin" "$OUTPUT_DIR/framework/internal/metadata-generator"

pushd "$OUTPUT_DIR"
npm pack
popd