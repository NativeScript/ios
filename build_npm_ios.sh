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

# The NativeScript / TKLiveSync xcframeworks are NO LONGER bundled in npm. They
# are published as GitHub Release artifacts and consumed via SwiftPM
# (github.com/NativeScript/ios-spm). Stamp the runtime version into the packaged
# template's SwiftPM reference so it resolves the matching release.
NPM_VERSION=$(node -e "console.log(require('./package.json').version)")
node ./scripts/stamp-template-version.mjs \
  "$OUTPUT_DIR/framework/__PROJECT_NAME__.xcodeproj/project.pbxproj" \
  "$NPM_VERSION"

# Build-time metadata generator is still shipped in npm (Phase 1). See the
# distribution plan for moving this to an on-demand artifact (Phase 2).
mkdir -p "$OUTPUT_DIR/framework/internal/metadata-generator-x86_64"
cp -r "metadata-generator/dist/x86_64/." "$OUTPUT_DIR/framework/internal/metadata-generator-x86_64"

mkdir -p "$OUTPUT_DIR/framework/internal/metadata-generator-arm64"
cp -r "metadata-generator/dist/arm64/." "$OUTPUT_DIR/framework/internal/metadata-generator-arm64"

pushd "$OUTPUT_DIR"
npm pack
mv *.tgz ../
popd

checkpoint "npm package created."
