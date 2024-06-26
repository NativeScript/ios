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
BUILD_VISION=$(to_bool ${BUILD_VISION:=true})
BUILD_TV=$(to_bool ${BUILD_TV:=true})
VERBOSE=$(to_bool ${VERBOSE:=false})

for arg in $@; do
  case $arg in
    --catalyst|--maccatalyst) BUILD_CATALYST=true ;;
    --no-catalyst|--no-maccatalyst) BUILD_CATALYST=false ;;
    --sim|--simulator) BUILD_SIMULATOR=true ;;
    --no-sim|--no-simulator) BUILD_SIMULATOR=false ;;
    --iphone|--device) BUILD_IPHONE=true ;;
    --no-iphone|--no-device) BUILD_IPHONE=false ;;
    --xr|--vision) BUILD_VISION=true ;;
    --no-xr|--no-vision) BUILD_VISION=false ;;
    --tv|--appletv) BUILD_TV=true ;;
    --no-tv|--no-appletv) BUILD_TV=false ;;
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

if $BUILD_SIMULATOR; then
checkpoint "Building NativeScript for iphone simulators (multi-arch)"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme "NativeScript" \
                   -configuration Release \
                   -destination "generic/platform=iOS Simulator" \
                   $QUIET \
                   EXCLUDED_ARCHS="i386" \
                   DEVELOPMENT_TEAM=$DEV_TEAM \
                   SKIP_INSTALL=NO \
                   BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
                   -archivePath $DIST/intermediates/NativeScript.iphonesimulator.xcarchive
fi

if $BUILD_IPHONE; then
checkpoint "Building NativeScript for ARM64 device"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme "NativeScript" \
                   -configuration Release \
                   -destination "generic/platform=iOS" \
                   $QUIET \
                   EXCLUDED_ARCHS="armv7" \
                   DEVELOPMENT_TEAM=$DEV_TEAM \
                   SKIP_INSTALL=NO \
                   BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
                   -archivePath $DIST/intermediates/NativeScript.iphoneos.xcarchive
fi

if $BUILD_CATALYST; then
checkpoint "Building NativeScript for Mac Catalyst"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme "NativeScript" \
                   -configuration Release \
                   -destination "generic/platform=macOS,variant=Mac Catalyst" \
                   $QUIET \
                   EXCLUDED_ARCHS="x86_64" \
                   SKIP_INSTALL=NO \
                   BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
                   -archivePath $DIST/intermediates/NativeScript.maccatalyst.xcarchive
fi

if $BUILD_VISION; then

checkpoint "Building NativeScript for visionOS Device"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme "NativeScript" \
                   -configuration Release \
                   -destination "generic/platform=visionOS" \
                   $QUIET \
                   EXCLUDED_ARCHS="i386 x86_64" \
                   VALID_ARCHS=arm64 \
                   DEVELOPMENT_TEAM=$DEV_TEAM \
                   SKIP_INSTALL=NO \
                   BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
                   -archivePath $DIST/intermediates/NativeScript.xros.xcarchive

checkpoint "Building NativeScript for visionOS Simulators"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme "NativeScript" \
                   -configuration Release \
                   -destination "generic/platform=visionOS Simulator" \
                   $QUIET \
                   EXCLUDED_ARCHS="i386 x86_64" \
                   VALID_ARCHS=arm64 \
                   DEVELOPMENT_TEAM=$DEV_TEAM \
                   SKIP_INSTALL=NO \
                   BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
                   -archivePath $DIST/intermediates/NativeScript.xrsimulator.xcarchive
fi

if $BUILD_TV; then

checkpoint "Building NativeScript for Apple TV Device"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme "NativeScript" \
                   -configuration Release \
                   -destination "generic/platform=tvOS" \
                   $QUIET \
                   EXCLUDED_ARCHS="i386 x86_64" \
                   VALID_ARCHS=arm64 \
                   DEVELOPMENT_TEAM=$DEV_TEAM \
                   SKIP_INSTALL=NO \
                   BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
                   -archivePath $DIST/intermediates/NativeScript.tvos.xcarchive

checkpoint "Building NativeScript for Apple TV Simulators"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme "NativeScript" \
                   -configuration Release \
                   -destination "generic/platform=tvOS Simulator" \
                   $QUIET \
                   EXCLUDED_ARCHS="i386 x86_64" \
                   VALID_ARCHS=arm64 \
                   DEVELOPMENT_TEAM=$DEV_TEAM \
                   SKIP_INSTALL=NO \
                   BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
                   -archivePath $DIST/intermediates/NativeScript.tvsimulator.xcarchive
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

if $BUILD_VISION; then
  XCFRAMEWORKS+=( -framework "$DIST/intermediates/NativeScript.xros.xcarchive/Products/Library/Frameworks/NativeScript.framework" \
                  -debug-symbols "$DIST/intermediates/NativeScript.xros.xcarchive/dSYMs/NativeScript.framework.dSYM" )
  XCFRAMEWORKS+=( -framework "$DIST/intermediates/NativeScript.xrsimulator.xcarchive/Products/Library/Frameworks/NativeScript.framework" \
                  -debug-symbols "$DIST/intermediates/NativeScript.xrsimulator.xcarchive/dSYMs/NativeScript.framework.dSYM" )
fi

if $BUILD_TV; then
  XCFRAMEWORKS+=( -framework "$DIST/intermediates/NativeScript.tvos.xcarchive/Products/Library/Frameworks/NativeScript.framework" \
                  -debug-symbols "$DIST/intermediates/NativeScript.tvos.xcarchive/dSYMs/NativeScript.framework.dSYM" )
  XCFRAMEWORKS+=( -framework "$DIST/intermediates/NativeScript.tvsimulator.xcarchive/Products/Library/Frameworks/NativeScript.framework" \
                  -debug-symbols "$DIST/intermediates/NativeScript.tvsimulator.xcarchive/dSYMs/NativeScript.framework.dSYM" )
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
