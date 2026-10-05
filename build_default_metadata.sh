#!/bin/bash
set -e
source "$(dirname "$0")/build_utils.sh"

function to_bool() {
  local arg="$1"
  case "$(echo "$arg" | tr '[:upper:]' '[:lower:]')" in
    n|no|f|false) echo false ;;
    y|yes|t|true) echo true ;;
    # case patterns are globs, not regexes: whatever gets past this arm is all digits
    ''|*[!0-9]*)
      if [ -n "$arg" ]; then
        echo "warning: invalid boolean argument ('$arg'). Expected true or false" >&2
      fi
      echo false
      ;;
    * )
      if [ "$arg" -eq 0 ]; then
        echo false
      else
        echo true
      fi
      ;;
  esac;
}

BUILD_CATALYST=$(to_bool ${BUILD_CATALYST:=true})
BUILD_IPHONE=$(to_bool ${BUILD_IPHONE:=true})
BUILD_SIMULATOR=$(to_bool ${BUILD_SIMULATOR:=true})

for arg in $@; do
  case $arg in
    --catalyst|--maccatalyst) BUILD_CATALYST=true ;;
    --no-catalyst|--no-maccatalyst) BUILD_CATALYST=false ;;
    --sim|--simulator) BUILD_SIMULATOR=true ;;
    --no-sim|--no-simulator) BUILD_SIMULATOR=false ;;
    --iphone|--device) BUILD_IPHONE=true ;;
    --no-iphone|--no-device) BUILD_IPHONE=false ;;
    *) ;;
  esac
done

DIST="$PWD/dist"
mkdir -p $DIST

mkdir -p $DIST/intermediates

checkpoint "Cleanup NativeScriptDefaultMetadata"
xcodebuild -project v8ios.xcodeproj \
           -target NativeScriptDefaultMetadata \
           -configuration Release clean \
           -quiet

if $BUILD_SIMULATOR; then
checkpoint "Building NativeScriptDefaultMetadata for iphone simulators (multi-arch)"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme NativeScriptDefaultMetadata \
                   -configuration Release \
                   -destination "generic/platform=iOS Simulator" \
                   -quiet \
                   SKIP_INSTALL=NO \
                   BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
                   -archivePath $DIST/intermediates/NativeScriptDefaultMetadata.iphonesimulator.xcarchive
fi

if $BUILD_IPHONE; then
checkpoint "Building NativeScriptDefaultMetadata for ARM64 device"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme NativeScriptDefaultMetadata \
                   -configuration Release \
                   -destination "generic/platform=iOS" \
                   -quiet \
                   SKIP_INSTALL=NO \
                   BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
                   -archivePath $DIST/intermediates/NativeScriptDefaultMetadata.iphoneos.xcarchive
fi

if $BUILD_CATALYST; then
checkpoint "Building NativeScriptDefaultMetadata for Mac Catalyst"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme NativeScriptDefaultMetadata \
                   -configuration Release \
                   -destination "generic/platform=macOS,variant=Mac Catalyst" \
                   -quiet \
                   EXCLUDED_ARCHS="x86_64" \
                   SKIP_INSTALL=NO \
                   BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
                   -archivePath $DIST/intermediates/NativeScriptDefaultMetadata.maccatalyst.xcarchive
fi

XCFRAMEWORKS=()
if $BUILD_CATALYST; then
  XCFRAMEWORKS+=( -framework "$DIST/intermediates/NativeScriptDefaultMetadata.maccatalyst.xcarchive/Products/Library/Frameworks/NativeScriptDefaultMetadata.framework" \
                  -debug-symbols "$DIST/intermediates/NativeScriptDefaultMetadata.maccatalyst.xcarchive/dSYMs/NativeScriptDefaultMetadata.framework.dSYM" )
fi

if $BUILD_SIMULATOR; then
  XCFRAMEWORKS+=( -framework "$DIST/intermediates/NativeScriptDefaultMetadata.iphonesimulator.xcarchive/Products/Library/Frameworks/NativeScriptDefaultMetadata.framework" \
                  -debug-symbols "$DIST/intermediates/NativeScriptDefaultMetadata.iphonesimulator.xcarchive/dSYMs/NativeScriptDefaultMetadata.framework.dSYM" )
fi

if $BUILD_IPHONE; then
  XCFRAMEWORKS+=( -framework "$DIST/intermediates/NativeScriptDefaultMetadata.iphoneos.xcarchive/Products/Library/Frameworks/NativeScriptDefaultMetadata.framework" \
                  -debug-symbols "$DIST/intermediates/NativeScriptDefaultMetadata.iphoneos.xcarchive/dSYMs/NativeScriptDefaultMetadata.framework.dSYM" )
fi

checkpoint "Creating NativeScriptDefaultMetadata.xcframework"
OUTPUT_DIR="$DIST/NativeScriptDefaultMetadata.xcframework"
rm -rf $OUTPUT_DIR
xcodebuild -create-xcframework ${XCFRAMEWORKS[@]} -output "$OUTPUT_DIR"

rm -rf "$DIST/intermediates"
