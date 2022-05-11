#!/bin/bash
set -e
source "$(dirname "$0")/build_utils.sh"

DEV_TEAM=${DEVELOPMENT_TEAM:-}
DIST=$(PWD)/dist
mkdir -p $DIST

mkdir -p $DIST/intermediates

checkpoint "Cleanup NativeScript"
xcodebuild -project v8ios.xcodeproj \
           -target "NativeScript" \
           -configuration Release clean \
           -quiet

checkpoint "Building NativeScript for Mac Catalyst"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme "NativeScript" \
                   -configuration Release \
                   -destination "platform=macOS,variant=Mac Catalyst" \
                   -quiet \
                   SKIP_INSTALL=NO \
                   -archivePath $DIST/intermediates/NativeScript.maccatalyst.xcarchive

# checkpoint "Building for x86_64 iphone simulator"
# xcodebuild archive -project v8ios.xcodeproj \
#                    -scheme "NativeScript" \
#                    -configuration Release \
#                    -arch x86_64 \
#                    -sdk iphonesimulator \
#                    -quiet \
#                    DEVELOPMENT_TEAM=$DEV_TEAM \
#                    SKIP_INSTALL=NO \
#                    -archivePath $DIST/NativeScript.x86_64-iphonesimulator.xcarchive

# checkpoint "Building for ARM64 iphone simulator"
# xcodebuild archive -project v8ios.xcodeproj \
#                    -scheme "NativeScript" \
#                    -configuration Release \
#                    -arch arm64 \
#                    -sdk iphonesimulator \
#                    -quiet \
#                    DEVELOPMENT_TEAM=$DEV_TEAM \
#                    SKIP_INSTALL=NO \
#                    -archivePath $DIST/NativeScript.arm64-iphonesimulator.xcarchive

checkpoint "Building NativeScript for iphone simulators (multi-arch)"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme "NativeScript" \
                   -configuration Release \
                   -destination "generic/platform=iOS Simulator" \
                   -sdk iphonesimulator \
                   -quiet \
                   EXCLUDED_ARCHS="i386" \
                   DEVELOPMENT_TEAM=$DEV_TEAM \
                   SKIP_INSTALL=NO \
                   -archivePath $DIST/intermediates/NativeScript.iphonesimulator.xcarchive

checkpoint "Building NativeScript for ARM64 device"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme "NativeScript" \
                   -configuration Release \
                   -destination "generic/platform=iOS" \
                   -sdk iphoneos \
                   -quiet \
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

checkpoint "Creating NativeScript.xcframework"
OUTPUT_DIR="$DIST/NativeScript.xcframework"
rm -rf $OUTPUT_DIR
xcodebuild -create-xcframework \
           -framework "$DIST/intermediates/NativeScript.maccatalyst.xcarchive/Products/Library/Frameworks/NativeScript.framework" \
           -debug-symbols "$DIST/intermediates/NativeScript.maccatalyst.xcarchive/dSYMs/NativeScript.framework.dSYM" \
           -framework "$DIST/intermediates/NativeScript.iphonesimulator.xcarchive/Products/Library/Frameworks/NativeScript.framework" \
           -debug-symbols "$DIST/intermediates/NativeScript.iphonesimulator.xcarchive/dSYMs/NativeScript.framework.dSYM" \
           -framework "$DIST/intermediates/NativeScript.iphoneos.xcarchive/Products/Library/Frameworks/NativeScript.framework" \
           -debug-symbols "$DIST/intermediates/NativeScript.iphoneos.xcarchive/dSYMs/NativeScript.framework.dSYM" \
           -output "$OUTPUT_DIR"

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