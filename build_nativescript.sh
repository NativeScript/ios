#!/bin/bash
set -e

echo "Cleanup"
xcodebuild -project v8ios.xcodeproj -target "NativeScript" -configuration Release clean

echo "Building for iphone simulator"
xcodebuild -project v8ios.xcodeproj -target "NativeScript" -configuration Release -arch x86_64 -sdk iphonesimulator -quiet

echo "Building for ARM64 device"
xcodebuild -project v8ios.xcodeproj -target "NativeScript" -configuration Release -arch arm64 -sdk iphoneos -quiet

echo "Creating fat library"
OUTPUT_DIR="dist/NativeScript.framework"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
cp -r "build/Release-iphoneos/NativeScript.framework/" "$OUTPUT_DIR"
lipo -create build/Release-iphonesimulator/NativeScript.framework/NativeScript build/Release-iphoneos/NativeScript.framework/NativeScript -output "$OUTPUT_DIR/NativeScript"
