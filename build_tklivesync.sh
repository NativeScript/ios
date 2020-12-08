#!/bin/bash
set -e

DIST=dist
mkdir -p $DIST

#cleanup
xcodebuild -project v8ios.xcodeproj -target TKLiveSync -configuration Release clean

#generates library for Mac Catalyst target
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme TKLiveSync \
                   -configuration Release \
                   -destination "platform=macOS,variant=Mac Catalyst" \
                   -quiet \
                   SKIP_INSTALL=NO \
                   -archivePath $DIST/TKLiveSync.maccatalyst.xcarchive

#generates library for x86_64 simulator target
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme TKLiveSync \
                   -configuration Release \
                   -sdk iphonesimulator \
                   -quiet \
                   SKIP_INSTALL=NO \
                   -archivePath $DIST/TKLiveSync.x86_64-iphonesimulator.xcarchive

#generates library for arm64 simulator target
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme TKLiveSync \
                   -configuration Release \
                   -sdk iphonesimulator \
                   -arch arm64 \
                   -quiet \
                   SKIP_INSTALL=NO \
                   -archivePath $DIST/TKLiveSync.arm64-iphonesimulator.xcarchive

#generates library for device target
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme TKLiveSync \
                   -configuration Release \
                   -sdk iphoneos \
                   -quiet \
                   SKIP_INSTALL=NO \
                   -archivePath $DIST/TKLiveSync.iphoneos.xcarchive

#Creates directory for fat-library
OUTPUT_DIR="$DIST/TKLiveSync.xcframework"
rm -rf "${OUTPUT_PATH}"

#Create fat library for simulator
rm -rf "$DIST/TKLiveSync.iphonesimulator.xcarchive"

cp -r \
    "$DIST/TKLiveSync.x86_64-iphonesimulator.xcarchive/." \
    "$DIST/TKLiveSync.iphonesimulator.xcarchive"

rm "$DIST/TKLiveSync.iphonesimulator.xcarchive/Products/Library/Frameworks/TKLiveSync.framework/TKLiveSync"

lipo -create \
    "$DIST/TKLiveSync.x86_64-iphonesimulator.xcarchive/Products/Library/Frameworks/TKLiveSync.framework/TKLiveSync" \
    "$DIST/TKLiveSync.arm64-iphonesimulator.xcarchive/Products/Library/Frameworks/TKLiveSync.framework/TKLiveSync" \
    -output \
    "$DIST/TKLiveSync.iphonesimulator.xcarchive/Products/Library/Frameworks/TKLiveSync.framework/TKLiveSync"

#Creates xcframework
xcodebuild -create-xcframework \
           -framework "$DIST/TKLiveSync.maccatalyst.xcarchive/Products/Library/Frameworks/TKLiveSync.framework" \
           -framework "$DIST/TKLiveSync.iphonesimulator.xcarchive/Products/Library/Frameworks/TKLiveSync.framework" \
           -framework "$DIST/TKLiveSync.iphoneos.xcarchive/Products/Library/Frameworks/TKLiveSync.framework" \
           -output "$OUTPUT_DIR"

rm -rf "$DIST/TKLiveSync.maccatalyst.xcarchive"
rm -rf "$DIST/TKLiveSync.x86_64-iphonesimulator.xcarchive"
rm -rf "$DIST/TKLiveSync.arm64-iphonesimulator.xcarchive"
rm -rf "$DIST/TKLiveSync.iphonesimulator.xcarchive"
rm -rf "$DIST/TKLiveSync.iphoneos.xcarchive"