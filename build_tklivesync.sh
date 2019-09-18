#!/bin/bash
set -e

#fat library path
FAT_LIBRARY_PATH=dist/TKLiveSync

#cleanup
xcodebuild -project v8ios.xcodeproj -target TKLiveSync -configuration Release clean

#generates library for simulator target
xcodebuild -project v8ios.xcodeproj -target TKLiveSync -configuration Release -sdk iphonesimulator -arch x86_64 -quiet

#generates library for device target
xcodebuild -project v8ios.xcodeproj -target TKLiveSync -configuration Release -sdk iphoneos -arch arm64 -quiet

#Creates directory for fat-library
rm -rf "${FAT_LIBRARY_PATH}"
mkdir -p "${FAT_LIBRARY_PATH}"

#Creates fat library
lipo -create -output "${FAT_LIBRARY_PATH}/libTKLiveSync.a" "build/Release-iphoneos/libTKLiveSync.a" "build/Release-iphonesimulator/libTKLiveSync.a"

#copies header files
cp -R "build/Release-iphoneos/include" "${FAT_LIBRARY_PATH}/"
