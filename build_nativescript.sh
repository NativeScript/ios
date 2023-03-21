#!/bin/bash
set -e
source "$(dirname "$0")/build_utils.sh"

function to_bool() {
  local arg="$1"
  case "$(echo "$arg" | tr '[:upper:]' '[:lower:]')" in
    [0-9]+)
      if [ $arg -eq 0 ]; then
        echo false
      else
        echo true
      fi
      ;;
    n|no|f|false) echo false ;;
    y|yes|t|true) echo true ;;
    * )
      if [ -n "$arg" ]; then
        echo "warning: invalid boolean argument ('$arg'). Expected true or false" >&2
      fi
      echo false
      ;;
  esac;
}

BUILD_CATALYST=$(to_bool ${BUILD_CATALYST:=true})
BUILD_IPHONE=$(to_bool ${BUILD_IPHONE:=true})
BUILD_SIMULATOR=$(to_bool ${BUILD_SIMULATOR:=true})
VERBOSE=$(to_bool ${VERBOSE:=false})

for arg in $@; do
  case $arg in
    --catalyst|--maccatalyst) BUILD_CATALYST=true ;;
    --no-catalyst|--no-maccatalyst) BUILD_CATALYST=false ;;
    --sim|--simulator) BUILD_SIMULATOR=true ;;
    --no-sim|--no-simulator) BUILD_SIMULATOR=false ;;
    --iphone|--device) BUILD_IPHONE=true ;;
    --no-iphone|--no-device) BUILD_IPHONE=false ;;
    --verbose|-v) VERBOSE=true ;;
    *) ;;
  esac
done

QUIET=
if ! $VERBOSE; then
  QUIET=-quiet
fi

DEV_TEAM=${DEVELOPMENT_TEAM:-}
DIST=$(PWD)/dist
mkdir -p $DIST

mkdir -p $DIST/intermediates

checkpoint "Cleanup NativeScript"
xcodebuild -project v8ios.xcodeproj \
           -target "NativeScript" \
           -configuration Release clean \
           $QUIET


if $BUILD_CATALYST; then
checkpoint "Building NativeScript for Mac Catalyst"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme "NativeScript" \
                   -configuration Release \
                   -destination "platform=macOS,variant=Mac Catalyst" \
                   $QUIET \
                   EXCLUDED_ARCHS="x86_64" \
                   SKIP_INSTALL=NO \
                   -archivePath $DIST/intermediates/NativeScript.maccatalyst.xcarchive
fi

if $BUILD_SIMULATOR; then
# checkpoint "Building for x86_64 iphone simulator"
# xcodebuild archive -project v8ios.xcodeproj \
#                    -scheme "NativeScript" \
#                    -configuration Release \
#                    -arch x86_64 \
#                    -sdk iphonesimulator \
#                    $QUIET \
#                    DEVELOPMENT_TEAM=$DEV_TEAM \
#                    SKIP_INSTALL=NO \
#                    -archivePath $DIST/NativeScript.x86_64-iphonesimulator.xcarchive

# checkpoint "Building for ARM64 iphone simulator"
# xcodebuild archive -project v8ios.xcodeproj \
#                    -scheme "NativeScript" \
#                    -configuration Release \
#                    -arch arm64 \
#                    -sdk iphonesimulator \
#                    $QUIET \
#                    DEVELOPMENT_TEAM=$DEV_TEAM \
#                    SKIP_INSTALL=NO \
#                    -archivePath $DIST/NativeScript.arm64-iphonesimulator.xcarchive

checkpoint "Building NativeScript for iphone simulators (multi-arch)"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme "NativeScript" \
                   -configuration Release \
                   -destination "generic/platform=iOS Simulator" \
                   -sdk iphonesimulator \
                   $QUIET \
                   EXCLUDED_ARCHS="i386" \
                   DEVELOPMENT_TEAM=$DEV_TEAM \
                   SKIP_INSTALL=NO \
                   -archivePath $DIST/intermediates/NativeScript.iphonesimulator.xcarchive
fi

if $BUILD_IPHONE; then
checkpoint "Building NativeScript for ARM64 device"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme "NativeScript" \
                   -configuration Release \
                   -destination "generic/platform=iOS" \
                   -sdk iphoneos \
                   $QUIET \
                   EXCLUDED_ARCHS="armv7" \
                   DEVELOPMENT_TEAM=$DEV_TEAM \
                   SKIP_INSTALL=NO \
                   -archivePath $DIST/intermediates/NativeScript.iphoneos.xcarchive

#Create fat library for simulator
# rm -rf "$DIST/NativeScript.iphonesimulator.xcarchive"

# cp -R \
#     "$DIST/NativeScript.x86_64-iphonesimulator.xcarchive" \
#     "$DIST/NativeScript.iphonesimulator.xcarchive"

# rm "$DIST/NativeScript.iphonesimulator.xcarchive/Products/Library/Frameworks/NativeScript.framework/NativeScript"

# lipo -create \
#     "$DIST/NativeScript.x86_64-iphonesimulator.xcarchive/Products/Library/Frameworks/NativeScript.framework/NativeScript" \
#     "$DIST/NativeScript.arm64-iphonesimulator.xcarchive/Products/Library/Frameworks/NativeScript.framework/NativeScript" \
#     -output \
#     "$DIST/NativeScript.iphonesimulator.xcarchive/Products/Library/Frameworks/NativeScript.framework/NativeScript"
fi

XCFRAMEWORKS=()
if $BUILD_CATALYST; then
  XCFRAMEWORKS+=( -framework "$DIST/intermediates/NativeScript.maccatalyst.xcarchive/Products/Library/Frameworks/NativeScript.framework" \
                  -debug-symbols "$DIST/intermediates/NativeScript.maccatalyst.xcarchive/dSYMs/NativeScript.framework.dSYM" )
fi

if $BUILD_SIMULATOR; then
  XCFRAMEWORKS+=( -framework "$DIST/intermediates/NativeScript.iphonesimulator.xcarchive/Products/Library/Frameworks/NativeScript.framework" \
                  -debug-symbols "$DIST/intermediates/NativeScript.iphonesimulator.xcarchive/dSYMs/NativeScript.framework.dSYM" )
fi

if $BUILD_IPHONE; then
  XCFRAMEWORKS+=( -framework "$DIST/intermediates/NativeScript.iphoneos.xcarchive/Products/Library/Frameworks/NativeScript.framework" \
                  -debug-symbols "$DIST/intermediates/NativeScript.iphoneos.xcarchive/dSYMs/NativeScript.framework.dSYM" )
fi

checkpoint "Creating NativeScript.xcframework"
OUTPUT_DIR="$DIST/NativeScript.xcframework"
rm -rf $OUTPUT_DIR
xcodebuild -create-xcframework ${XCFRAMEWORKS[@]} -output "$OUTPUT_DIR"

rm -rf "$DIST/intermediates"

# DSYM_OUTPUT_DIR="$DIST/NativeScript.framework.dSYM"
# cp -r "$DIST/NativeScript.iphoneos.xcarchive/dSYMs/NativeScript.framework.dSYM/" $DSYM_OUTPUT_DIR
# lipo -create \
#     "$DIST/NativeScript.iphonesimulator.xcarchive/dSYMs/NativeScript.framework.dSYM/Contents/Resources/DWARF/NativeScript" \
#     "$DIST/NativeScript.iphoneos.xcarchive/dSYMs/NativeScript.framework.dSYM/Contents/Resources/DWARF/NativeScript" \
#     -output "$DSYM_OUTPUT_DIR/Contents/Resources/DWARF/NativeScript"

# pushd $DIST
# zip -qr "NativeScript.framework.dSYM.zip" "NativeScript.framework.dSYM"
# zip -qr "NativeScript.macos.framework.dSYM.zip" "NativeScript.maccatalyst.xcarchive/dSYMs/NativeScript.framework.dSYM"
# rm -rf "NativeScript.framework.dSYM"
# popd

# rm -rf "$DIST/NativeScript.maccatalyst.xcarchive"
# rm -rf "$DIST/NativeScript.x86_64-iphonesimulator.xcarchive"
# rm -rf "$DIST/NativeScript.arm64-iphonesimulator.xcarchive"
# rm -rf "$DIST/NativeScript.iphonesimulator.xcarchive"
# rm -rf "$DIST/NativeScript.iphoneos.xcarchive"
