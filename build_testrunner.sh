#!/bin/bash
set -e

NATIVESCRIPT_DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM:-}
NATIVESCRIPT_CODE_SIGN_IDENTITY=${NATIVESCRIPT_CODE_SIGN_IDENTITY:-}
NATIVESCRIPT_PROVISIONING_PROFILE_SPECIFIER=${NATIVESCRIPT_PROVISIONING_PROFILE_SPECIFIER:-}

echo "Cleanup"
xcodebuild -project v8ios.xcodeproj -target "TestRunner" -configuration Release clean

echo "Building for ARM64 device"
xcodebuild -project v8ios.xcodeproj -target "TestRunner" -configuration Release -arch arm64 -sdk iphoneos -quiet DEVELOPMENT_TEAM="$NATIVESCRIPT_DEVELOPMENT_TEAM" CODE_SIGN_IDENTITY="$NATIVESCRIPT_CODE_SIGN_IDENTITY" CODE_SIGN_STYLE="Manual" NATIVESCRIPT_PROVISIONING_PROFILE_SPECIFIER="$NATIVESCRIPT_PROVISIONING_PROFILE_SPECIFIER"

(
    set -e;
    cd "build/Release-iphoneos/";
    mkdir Payload;
    mv TestRunner.app Payload;
    zip -r "TestRunner.ipa" Payload;
    mv Payload/TestRunner.app .
)
