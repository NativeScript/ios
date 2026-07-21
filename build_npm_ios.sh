#!/bin/bash
set -e
source "$(dirname "$0")/build_utils.sh"

usage() {
  echo "Usage: ./build_npm_ios.sh [--spm-mode <embedded|remote>]"
  echo ""
  echo "  --spm-mode embedded  (default) self-contained package: the xcframework zips"
  echo "                       from dist/artifacts are embedded at"
  echo "                       framework/internal/local-spm and the app template"
  echo "                       references them by relative path. Portable — for local"
  echo "                       testing (ns platform add ios --framework-path=...) and"
  echo "                       PR artifacts."
  echo "  --spm-mode remote    deploy shape used by the release workflow: no binaries"
  echo "                       embedded; the app template pins"
  echo "                       github.com/NativeScript/ios-spm at exactly this package"
  echo "                       version. Only resolves for versions shipped by the"
  echo "                       release pipeline."
  echo "  -h, --help           show this help"
}

SPM_MODE="embedded"
while [ $# -gt 0 ]; do
  case "$1" in
    --spm-mode)
      if [ $# -lt 2 ]; then
        echo "--spm-mode requires a value" >&2
        usage >&2
        exit 1
      fi
      SPM_MODE="$2"
      shift 2
      ;;
    --spm-mode=*)
      SPM_MODE="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$SPM_MODE" in
  embedded|remote) ;;
  *)
    echo "Invalid --spm-mode '$SPM_MODE' (expected embedded or remote)" >&2
    usage >&2
    exit 1
    ;;
esac

checkpoint "Preparing npm package for iOS ($SPM_MODE SwiftPM mode)..."
OUTPUT_DIR="dist/npm"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/framework"
cp ./package.json "$OUTPUT_DIR"

cp -r "./project-template-ios/" "$OUTPUT_DIR/framework"

# The runtime xcframeworks are consumed via SwiftPM in both modes; what differs
# is where the SwiftPM package lives (see usage above). The zips come from
# build_spm_artifacts.sh — zipped because npm strips symlinks (the Catalyst
# slices contain them) and SwiftPM extracts local zip binary targets itself.
if [ "$SPM_MODE" = "embedded" ]; then
  ARTIFACTS_DIR="dist/artifacts"
  LOCAL_SPM_DIR="$OUTPUT_DIR/framework/internal/local-spm"
  for zip in NativeScript.xcframework.zip TKLiveSync.xcframework.zip; do
    if [ ! -f "$ARTIFACTS_DIR/$zip" ]; then
      echo "Missing $ARTIFACTS_DIR/$zip — run ./build_spm_artifacts.sh ios first." >&2
      exit 1
    fi
  done
  mkdir -p "$LOCAL_SPM_DIR"
  cp "./spm-templates/local-spm-ios/Package.swift" "$LOCAL_SPM_DIR/"
  cp "$ARTIFACTS_DIR/NativeScript.xcframework.zip" \
     "$ARTIFACTS_DIR/TKLiveSync.xcframework.zip" \
     "$LOCAL_SPM_DIR/"
  node ./scripts/stamp-template-local-spm.mjs \
    "$OUTPUT_DIR/framework/__PROJECT_NAME__.xcodeproj/project.pbxproj" \
    "internal/local-spm" \
    --package-dir "$LOCAL_SPM_DIR"
else
  NPM_VERSION=$(node -e "console.log(require('./package.json').version)")
  node ./scripts/stamp-template-version.mjs \
    "$OUTPUT_DIR/framework/__PROJECT_NAME__.xcodeproj/project.pbxproj" \
    "$NPM_VERSION"
fi

# Build-time metadata generator is still shipped in npm (Phase 1).
mkdir -p "$OUTPUT_DIR/framework/internal/metadata-generator-x86_64"
cp -r "metadata-generator/dist/x86_64/." "$OUTPUT_DIR/framework/internal/metadata-generator-x86_64"

mkdir -p "$OUTPUT_DIR/framework/internal/metadata-generator-arm64"
cp -r "metadata-generator/dist/arm64/." "$OUTPUT_DIR/framework/internal/metadata-generator-arm64"

pushd "$OUTPUT_DIR"
npm pack
mv *.tgz ../
popd

checkpoint "npm package created."
