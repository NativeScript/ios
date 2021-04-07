#!/bin/bash
set -e

DIST=$(PWD)/dist
mkdir -p $DIST

mkdir -p $DIST/intermediates

#cleanup
xcodebuild -project v8ios.xcodeproj -target TKLiveSync -configuration Release clean

#generates library for Mac Catalyst target
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme TKLiveSync \
                   -configuration Release \
                   -destination "platform=macOS,variant=Mac Catalyst" \
                   -quiet \
                   SKIP_INSTALL=NO \
                   -archivePath $DIST/intermediates/TKLiveSync.maccatalyst.xcarchive

# #generates library for x86_64 simulator target
# xcodebuild archive -project v8ios.xcodeproj \
#                    -scheme TKLiveSync \
#                    -configuration Release \
#                    -sdk iphonesimulator \
#                    -quiet \
#                    SKIP_INSTALL=NO \
#                    -archivePath $DIST/TKLiveSync.x86_64-iphonesimulator.xcarchive

# #generates library for arm64 simulator target
# xcodebuild archive -project v8ios.xcodeproj \
#                    -scheme TKLiveSync \
#                    -configuration Release \
#                    -sdk iphonesimulator \
#                    -arch arm64 \
#                    -quiet \
#                    SKIP_INSTALL=NO \
#                    -archivePath $DIST/TKLiveSync.arm64-iphonesimulator.xcarchive

# generates library for simulator targets (usually includes arm64, x86_64)
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme TKLiveSync \
                   -configuration Release \
                   -sdk iphonesimulator \
                   -arch x86_64 \
                   -arch arm64 \
                   -quiet \
                   SKIP_INSTALL=NO \
                   -archivePath $DIST/intermediates/TKLiveSync.iphonesimulator.xcarchive

#generates library for device target
xcodebuild archive -project v8ios.xcodeproj \
                   -scheme TKLiveSync \
                   -configuration Release \
                   -sdk iphoneos \
                   -quiet \
                   SKIP_INSTALL=NO \
                   -archivePath $DIST/intermediates/TKLiveSync.iphoneos.xcarchive

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
xcodebuild -create-xcframework \
           -framework "$DIST/intermediates/TKLiveSync.maccatalyst.xcarchive/Products/Library/Frameworks/TKLiveSync.framework" \
           -debug-symbols "$DIST/intermediates/TKLiveSync.maccatalyst.xcarchive/dSYMs/TKLiveSync.framework.dSYM" \
           -framework "$DIST/intermediates/TKLiveSync.iphonesimulator.xcarchive/Products/Library/Frameworks/TKLiveSync.framework" \
           -debug-symbols "$DIST/intermediates/TKLiveSync.iphonesimulator.xcarchive/dSYMs/TKLiveSync.framework.dSYM" \
           -framework "$DIST/intermediates/TKLiveSync.iphoneos.xcarchive/Products/Library/Frameworks/TKLiveSync.framework" \
           -debug-symbols "$DIST/intermediates/TKLiveSync.iphoneos.xcarchive/dSYMs/TKLiveSync.framework.dSYM" \
           -output "$OUTPUT_DIR"

rm -rf "$DIST/intermediates"

# rm -rf "$DIST/TKLiveSync.maccatalyst.xcarchive"
# rm -rf "$DIST/TKLiveSync.x86_64-iphonesimulator.xcarchive"
# rm -rf "$DIST/TKLiveSync.arm64-iphonesimulator.xcarchive"
# rm -rf "$DIST/TKLiveSync.iphonesimulator.xcarchive"
# rm -rf "$DIST/TKLiveSync.iphoneos.xcarchive"