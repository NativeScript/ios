#!/bin/bash
set -e

echo "Cleanup"
xcodebuild -project v8ios.xcodeproj -target "TestApp" -configuration Release clean

echo "Building for ARM64 device"
xcodebuild -project v8ios.xcodeproj -target "TestApp" -configuration Release -arch arm64 -sdk iphoneos -quiet

(
    set -e;
    cd "build/Release-iphoneos/";
    mkdir Payload;
    mv TestApp.app Payload;
    zip -r "TestApp.ipa" Payload;
    mv Payload/TestApp.app .
)
