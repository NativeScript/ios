#!/bin/bash
set -e

DEV_TEAM=${DEVELOPMENT_TEAM:-}

echo "Cleanup"
xcodebuild -project v8ios.xcodeproj -target "TestApp" -configuration Release clean

echo "Building for ARM64 device"
xcodebuild -project v8ios.xcodeproj -target "TestApp" -configuration Release -arch arm64 -sdk iphoneos -quiet DEVELOPMENT_TEAM=$DEV_TEAM CODE_SIGN_IDENTITY="iPhone Developer"

(
    set -e;
    cd "build/Release-iphoneos/";
    mkdir Payload;
    mv TestApp.app Payload;
    zip -r "TestApp.ipa" Payload;
    mv Payload/TestApp.app .
)
