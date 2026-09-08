#!/bin/bash
set -e
source "$(dirname "$0")/build_utils.sh"

checkpoint "Preparing npm package for tvOS..."
OUTPUT_DIR="dist/npm"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/framework"
cp ./package.json "$OUTPUT_DIR"

# Keep the template and runtime linkage in step with upstream iOS.
cp -r "./project-template-ios/." "$OUTPUT_DIR/framework/"
swift scripts/prepare-tvos-template.swift "$OUTPUT_DIR/framework"
LOCAL_SPM_DIR="$OUTPUT_DIR/framework/internal/local-spm"
mkdir -p "$LOCAL_SPM_DIR"
cp spm-templates/local-spm-tvos/Package.swift "$LOCAL_SPM_DIR/"
for framework in NativeScript TKLiveSync; do
  (cd dist && zip -qr --symlinks "npm/framework/internal/local-spm/$framework.xcframework.zip" "$framework.xcframework")
done

mkdir -p "$OUTPUT_DIR/framework/internal/metadata-generator-x86_64"
cp -r "metadata-generator/dist/x86_64/." "$OUTPUT_DIR/framework/internal/metadata-generator-x86_64"

mkdir -p "$OUTPUT_DIR/framework/internal/metadata-generator-arm64"
cp -r "metadata-generator/dist/arm64/." "$OUTPUT_DIR/framework/internal/metadata-generator-arm64"

pushd "$OUTPUT_DIR"
# Publish as @nativescript/tvos (same version as the iOS runtime it is built from) and drop the husky
# "prepare" hook, which must not run for the published tarball.
node -e 'const fs=require("fs");const p=JSON.parse(fs.readFileSync("package.json"));p.name="@nativescript/tvos";p.description="NativeScript Runtime for tvOS";delete p.scripts.prepare;fs.writeFileSync("package.json",JSON.stringify(p,null,2));'
npm pack
mv *.tgz ../
popd

checkpoint "npm package created."