#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/build_utils.sh"

# Builds dist/NativeScriptDevTunnel.xcframework. The framework is plain C and
# links nothing from the runtime, so it builds on its own.

usage() {
  cat <<EOF
Usage: $0 [options]

Slices (all on by default):
  --catalyst / --no-catalyst    Mac Catalyst
  --sim / --no-sim              iOS Simulator
  --iphone / --no-iphone        iOS device
  --vision / --no-vision        visionOS device and simulator

  -v, --verbose                 Show xcodebuild output
  -h, --help                    Show this help
EOF
}

BUILD_CATALYST=true
BUILD_IPHONE=true
BUILD_SIMULATOR=true
BUILD_VISION=true
VERBOSE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --catalyst|--maccatalyst) BUILD_CATALYST=true ;;
    --no-catalyst|--no-maccatalyst) BUILD_CATALYST=false ;;
    --sim|--simulator) BUILD_SIMULATOR=true ;;
    --no-sim|--no-simulator) BUILD_SIMULATOR=false ;;
    --iphone|--device) BUILD_IPHONE=true ;;
    --no-iphone|--no-device) BUILD_IPHONE=false ;;
    --xr|--vision) BUILD_VISION=true ;;
    --no-xr|--no-vision) BUILD_VISION=false ;;
    -v|--verbose) VERBOSE=true ;;
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
  shift
done

QUIET=()
if ! $VERBOSE; then
  QUIET=(-quiet)
fi

DIST="$PWD/dist"
INTERMEDIATES="$DIST/intermediates"
mkdir -p "$INTERMEDIATES"

# archive <name> <destination> [build settings...]
archive() {
  local name="$1" destination="$2"
  shift 2
  checkpoint "Building NativeScriptDevTunnel for $name"
  xcodebuild archive -project v8ios.xcodeproj \
                     -scheme NativeScriptDevTunnel \
                     -configuration Release \
                     -destination "$destination" \
                     ${QUIET[@]+"${QUIET[@]}"} \
                     SKIP_INSTALL=NO \
                     BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
                     "$@" \
                     -archivePath "$INTERMEDIATES/NativeScriptDevTunnel.$name.xcarchive"
}

checkpoint "Cleanup NativeScriptDevTunnel"
xcodebuild -project v8ios.xcodeproj \
           -target NativeScriptDevTunnel \
           -configuration Release clean \
           ${QUIET[@]+"${QUIET[@]}"}

ARCHIVES=()
if $BUILD_SIMULATOR; then
  archive iphonesimulator "generic/platform=iOS Simulator" EXCLUDED_ARCHS="i386"
  ARCHIVES+=(iphonesimulator)
fi

if $BUILD_IPHONE; then
  archive iphoneos "generic/platform=iOS" EXCLUDED_ARCHS="armv7"
  ARCHIVES+=(iphoneos)
fi

if $BUILD_CATALYST; then
  archive maccatalyst "generic/platform=macOS,variant=Mac Catalyst" EXCLUDED_ARCHS="x86_64"
  ARCHIVES+=(maccatalyst)
fi

if $BUILD_VISION; then
  archive xros "generic/platform=visionOS" EXCLUDED_ARCHS="i386 x86_64" VALID_ARCHS=arm64
  archive xrsimulator "generic/platform=visionOS Simulator" EXCLUDED_ARCHS="i386 x86_64" VALID_ARCHS=arm64
  ARCHIVES+=(xros xrsimulator)
fi

if [ "${#ARCHIVES[@]}" -eq 0 ]; then
  echo "Nothing to build: every slice is turned off." >&2
  exit 1
fi

XCFRAMEWORKS=()
for name in "${ARCHIVES[@]}"; do
  ARCHIVE="$INTERMEDIATES/NativeScriptDevTunnel.$name.xcarchive"
  XCFRAMEWORKS+=(-framework "$ARCHIVE/Products/Library/Frameworks/NativeScriptDevTunnel.framework"
                 -debug-symbols "$ARCHIVE/dSYMs/NativeScriptDevTunnel.framework.dSYM")
done

checkpoint "Creating NativeScriptDevTunnel.xcframework"
OUTPUT_DIR="$DIST/NativeScriptDevTunnel.xcframework"
rm -rf "$OUTPUT_DIR"
xcodebuild -create-xcframework "${XCFRAMEWORKS[@]}" -output "$OUTPUT_DIR"

rm -rf "$INTERMEDIATES"
