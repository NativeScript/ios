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

DIST=$(PWD)/dist
mkdir -p $DIST

mkdir -p $DIST/intermediates

#cleanup
checkpoint "Cleanup TKLiveSync"
xcodebuild -project v8ios.xcodeproj \
           -target TKLiveSync \
           -configuration Release clean \
           -quiet

if $BUILD_SIMULATOR; then
# generates library for simulator targets (usually includes arm64, x86_64)
checkpoint "Building TKLiveSync for iphone simulators (multi-arch)"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme TKLiveSync \
                   -configuration Release \
                   -destination "generic/platform=iOS Simulator" \
                   -quiet \
                   SKIP_INSTALL=NO \
                   BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
                   -archivePath $DIST/intermediates/TKLiveSync.iphonesimulator.xcarchive
fi

if $BUILD_IPHONE; then
#generates library for device target
checkpoint "Building TKLiveSync for ARM64 device"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme TKLiveSync \
                   -configuration Release \
                   -destination "generic/platform=iOS" \
                   -quiet \
                   SKIP_INSTALL=NO \
                   BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
                   -archivePath $DIST/intermediates/TKLiveSync.iphoneos.xcarchive
fi

if $BUILD_CATALYST; then
#generates library for Mac Catalyst target
checkpoint "Building TKLiveSync for Mac Catalyst"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme TKLiveSync \
                   -configuration Release \
                   -destination "generic/platform=macOS,variant=Mac Catalyst" \
                   -quiet \
                   SKIP_INSTALL=NO \
                   BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
                   -archivePath $DIST/intermediates/TKLiveSync.maccatalyst.xcarchive
fi

if $BUILD_VISION; then
#generates library for visionOS targets
checkpoint "Building TKLiveSync for visionOS Simulators"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme "TKLiveSync" \
                   -configuration Release \
                   -destination "generic/platform=visionOS Simulator" \
                   -quiet \
                   SKIP_INSTALL=NO \
                   BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
                   -archivePath $DIST/intermediates/TKLiveSync.xrsimulator.xcarchive

checkpoint "Building TKLiveSync for visionOS Device"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme "TKLiveSync" \
                   -configuration Release \
                   -destination "generic/platform=visionOS" \
                   -quiet \
                   SKIP_INSTALL=NO \
                   BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
                   -archivePath $DIST/intermediates/TKLiveSync.xros.xcarchive
fi

if $BUILD_TV; then

checkpoint "Building TKLiveSync for Apple TV Device"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme "TKLiveSync" \
                   -configuration Release \
                   -destination "generic/platform=tvOS" \
                   -quiet \
                   SKIP_INSTALL=NO \
                   BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
                   -archivePath $DIST/intermediates/TKLiveSync.tvos.xcarchive

checkpoint "Building TKLiveSync for Apple TV Simulators"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme "TKLiveSync" \
                   -configuration Release \
                   -destination "generic/platform=tvOS Simulator" \
                   -quiet \
                   SKIP_INSTALL=NO \
                   BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
                   -archivePath $DIST/intermediates/TKLiveSync.tvsimulator.xcarchive
fi

#Creates directory for fat-library
OUTPUT_DIR="$DIST/TKLiveSync.xcframework"
rm -rf "${OUTPUT_PATH}"

#Create fat library for simulator
# rm -rf "$DIST/TKLiveSync.iphonesimulator.xcarchive"

# cp -r \
    # "$DIST/TKLiveSync.x86_64-iphonesimulator.xcarchive/." \
    # "$DIST/TKLiveSync.iphonesimulator.xcarchive"

# rm "$DIST/TKLiveSync.iphonesimulator.xcarchive/Products/Library/Frameworks/TKLiveSync.framework/TKLiveSync"

# lipo -create \
#     "$DIST/TKLiveSync.x86_64-iphonesimulator.xcarchive/Products/Library/Frameworks/TKLiveSync.framework/TKLiveSync" \
#     "$DIST/TKLiveSync.arm64-iphonesimulator.xcarchive/Products/Library/Frameworks/TKLiveSync.framework/TKLiveSync" \
#     -output \
#     "$DIST/TKLiveSync.iphonesimulator.xcarchive/Products/Library/Frameworks/TKLiveSync.framework/TKLiveSync"

#Creates xcframework
XCFRAMEWORKS=()
if $BUILD_CATALYST; then
  XCFRAMEWORKS+=( -framework "$DIST/intermediates/TKLiveSync.maccatalyst.xcarchive/Products/Library/Frameworks/TKLiveSync.framework" \
                  -debug-symbols "$DIST/intermediates/TKLiveSync.maccatalyst.xcarchive/dSYMs/TKLiveSync.framework.dSYM" )
fi

if $BUILD_SIMULATOR; then
  XCFRAMEWORKS+=( -framework "$DIST/intermediates/TKLiveSync.iphonesimulator.xcarchive/Products/Library/Frameworks/TKLiveSync.framework" \
                  -debug-symbols "$DIST/intermediates/TKLiveSync.iphonesimulator.xcarchive/dSYMs/TKLiveSync.framework.dSYM" )
fi

if $BUILD_IPHONE; then
  XCFRAMEWORKS+=( -framework "$DIST/intermediates/TKLiveSync.iphoneos.xcarchive/Products/Library/Frameworks/TKLiveSync.framework" \
                  -debug-symbols "$DIST/intermediates/TKLiveSync.iphoneos.xcarchive/dSYMs/TKLiveSync.framework.dSYM" )
fi

if $BUILD_VISION; then
  XCFRAMEWORKS+=( -framework "$DIST/intermediates/TKLiveSync.xros.xcarchive/Products/Library/Frameworks/TKLiveSync.framework" \
                  -debug-symbols "$DIST/intermediates/TKLiveSync.xros.xcarchive/dSYMs/TKLiveSync.framework.dSYM" )
  XCFRAMEWORKS+=( -framework "$DIST/intermediates/TKLiveSync.xrsimulator.xcarchive/Products/Library/Frameworks/TKLiveSync.framework" \
                  -debug-symbols "$DIST/intermediates/TKLiveSync.xrsimulator.xcarchive/dSYMs/TKLiveSync.framework.dSYM" )
fi

if $BUILD_TV; then
  XCFRAMEWORKS+=( -framework "$DIST/intermediates/TKLiveSync.tvos.xcarchive/Products/Library/Frameworks/TKLiveSync.framework" \
                  -debug-symbols "$DIST/intermediates/TKLiveSync.tvos.xcarchive/dSYMs/TKLiveSync.framework.dSYM" )
  XCFRAMEWORKS+=( -framework "$DIST/intermediates/TKLiveSync.tvsimulator.xcarchive/Products/Library/Frameworks/TKLiveSync.framework" \
                  -debug-symbols "$DIST/intermediates/TKLiveSync.tvsimulator.xcarchive/dSYMs/TKLiveSync.framework.dSYM" )
fi

checkpoint "Creating TKLiveSync.xcframework"
OUTPUT_DIR="$DIST/TKLiveSync.xcframework"
rm -rf $OUTPUT_DIR
echo xcodebuild -create-xcframework ${XCFRAMEWORKS[@]} -output "$OUTPUT_DIR"
xcodebuild -create-xcframework ${XCFRAMEWORKS[@]} -output "$OUTPUT_DIR"

rm -rf "$DIST/intermediates"

# rm -rf "$DIST/TKLiveSync.maccatalyst.xcarchive"
# rm -rf "$DIST/TKLiveSync.x86_64-iphonesimulator.xcarchive"
# rm -rf "$DIST/TKLiveSync.arm64-iphonesimulator.xcarchive"
# rm -rf "$DIST/TKLiveSync.iphonesimulator.xcarchive"
# rm -rf "$DIST/TKLiveSync.iphoneos.xcarchive"