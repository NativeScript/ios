#!/bin/bash
set -e

DEV_TEAM=${DEVELOPMENT_TEAM:-}
DIST="dist"
mkdir -p $DIST

echo "Cleanup"
xcodebuild -project v8ios.xcodeproj -target "NativeScript" -configuration Release clean

echo "Building for Mac Catalyst"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme "NativeScript" \
                   -configuration Release \
                   -destination "platform=macOS,variant=Mac Catalyst" \
                   -quiet \
                   SKIP_INSTALL=NO \
                   -archivePath $DIST/NativeScript.maccatalyst.xcarchive

echo "Building for x86_64 iphone simulator"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme "NativeScript" \
                   -configuration Release \
                   -arch x86_64 \
                   -sdk iphonesimulator \
                   -quiet \
                   DEVELOPMENT_TEAM=$DEV_TEAM \
                   SKIP_INSTALL=NO \
                   -archivePath $DIST/NativeScript.x86_64-iphonesimulator.xcarchive

echo "Building for ARM64 iphone simulator"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme "NativeScript" \
                   -configuration Release \
                   -arch arm64 \
                   -sdk iphonesimulator \
                   -quiet \
                   DEVELOPMENT_TEAM=$DEV_TEAM \
                   SKIP_INSTALL=NO \
                   -archivePath $DIST/NativeScript.arm64-iphonesimulator.xcarchive

echo "Building for ARM64 device"
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme "NativeScript" \
                   -configuration Release \
                   -arch arm64 \
                   -sdk iphoneos \
                   -quiet \
                   DEVELOPMENT_TEAM=$DEV_TEAM \
                   SKIP_INSTALL=NO \
                   -archivePath $DIST/NativeScript.iphoneos.xcarchive

#Create fat library for simulator
rm -rf "$DIST/NativeScript.iphonesimulator.xcarchive"

cp -R \
    "$DIST/NativeScript.x86_64-iphonesimulator.xcarchive" \
    "$DIST/NativeScript.iphonesimulator.xcarchive"

rm "$DIST/NativeScript.iphonesimulator.xcarchive/Products/Library/Frameworks/NativeScript.framework/NativeScript"

lipo -create \
    "$DIST/NativeScript.x86_64-iphonesimulator.xcarchive/Products/Library/Frameworks/NativeScript.framework/NativeScript" \
    "$DIST/NativeScript.arm64-iphonesimulator.xcarchive/Products/Library/Frameworks/NativeScript.framework/NativeScript" \
    -output \
    "$DIST/NativeScript.iphonesimulator.xcarchive/Products/Library/Frameworks/NativeScript.framework/NativeScript"

echo "Creating NativeScript.xcframework"
OUTPUT_DIR="$DIST/NativeScript.xcframework"
rm -rf $OUTPUT_DIR
xcodebuild -create-xcframework \
           -framework "$DIST/NativeScript.maccatalyst.xcarchive/Products/Library/Frameworks/NativeScript.framework" \
           -framework "$DIST/NativeScript.iphonesimulator.xcarchive/Products/Library/Frameworks/NativeScript.framework" \
           -framework "$DIST/NativeScript.iphoneos.xcarchive/Products/Library/Frameworks/NativeScript.framework" \
           -output "$OUTPUT_DIR"

DSYM_OUTPUT_DIR="$DIST/NativeScript.framework.dSYM"
cp -r "$DIST/NativeScript.iphoneos.xcarchive/dSYMs/NativeScript.framework.dSYM/" $DSYM_OUTPUT_DIR
lipo -create \
    "$DIST/NativeScript.iphonesimulator.xcarchive/dSYMs/NativeScript.framework.dSYM/Contents/Resources/DWARF/NativeScript" \
    "$DIST/NativeScript.iphoneos.xcarchive/dSYMs/NativeScript.framework.dSYM/Contents/Resources/DWARF/NativeScript" \
    -output "$DSYM_OUTPUT_DIR/Contents/Resources/DWARF/NativeScript"

pushd $DIST
zip -qr "NativeScript.framework.dSYM.zip" "NativeScript.framework.dSYM"
zip -qr "NativeScript.macos.framework.dSYM.zip" "NativeScript.maccatalyst.xcarchive/dSYMs/NativeScript.framework.dSYM"
rm -rf "NativeScript.framework.dSYM"
popd

rm -rf "$DIST/NativeScript.maccatalyst.xcarchive"
rm -rf "$DIST/NativeScript.x86_64-iphonesimulator.xcarchive"
rm -rf "$DIST/NativeScript.arm64-iphonesimulator.xcarchive"
rm -rf "$DIST/NativeScript.iphonesimulator.xcarchive"
rm -rf "$DIST/NativeScript.iphoneos.xcarchive"