#!/bin/bash
set -e

pushd libffi

./autogen.sh

OUTPUT_DIR=./dist
OUTPUT_ARM64=$OUTPUT_DIR/arm64-iphoneos
OUTPUT_ARM64_SIMULATOR=$OUTPUT_DIR/arm64-iphonesimulator
OUTPUT_X86_64_SIMULATOR=$OUTPUT_DIR/x86_64-iphonesimulator
OUTPUT_X86_64_MACCATALYST=$OUTPUT_DIR/x86_64-maccatalyst

rm -rf $OUTPUT_DIR
mkdir -p $OUTPUT_ARM64
mkdir -p $OUTPUT_X86_64_SIMULATOR
mkdir -p $OUTPUT_X86_64_MACCATALYST

ARM64_OUT="aarch64-apple-darwin13"
export CC="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang -arch arm64 -fembed-bitcode -miphoneos-version-min=9.0 -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
export CXX="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++ -arch arm64 -fembed-bitcode -miphoneos-version-min=9.0 -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
./configure --disable-shared --host="$ARM64_OUT"
make
mkdir -p $OUTPUT_ARM64/lib
ar r $OUTPUT_ARM64/lib/libffi.a ./$ARM64_OUT/src/*.o ./$ARM64_OUT/src/aarch64/*.o
cp -r $ARM64_OUT/include $OUTPUT_ARM64
rm -rf $ARM64_OUT

ARM64_SIMULATOR_OUT="aarch64-apple-darwin13"
export CC="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang -arch arm64 -fembed-bitcode -mios-simulator-version-min=9.0 -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"
export CXX="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++ -arch arm64 -fembed-bitcode -mios-simulator-version-min=9.0 -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"
./configure --disable-shared --host="$ARM64_SIMULATOR_OUT"
make
mkdir -p $OUTPUT_ARM64_SIMULATOR/lib
ar r $OUTPUT_ARM64_SIMULATOR/lib/libffi.a ./$ARM64_SIMULATOR_OUT/src/*.o ./$ARM64_SIMULATOR_OUT/src/aarch64/*.o
cp -r $ARM64_SIMULATOR_OUT/include $OUTPUT_ARM64_SIMULATOR
rm -rf $ARM64_SIMULATOR_OUT

#ARM_OUT="armv7-apple-darwin13"
#export CC="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang -arch armv7 -fembed-bitcode -miphoneos-version-min=9.0 -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
#export CXX="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++ -arch armv7 -fembed-bitcode -miphoneos-version-min=9.0 -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
#./configure --disable-shared --host="$ARM_OUT"
#make
#ar r ./$ARM_OUT/libffi.a ./$ARM_OUT/src/*.o ./$ARM_OUT/src/arm/*.o

X86_64_OUT="x86_64-apple-darwin13"
export CC="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang -arch x86_64 -fembed-bitcode-marker -mios-simulator-version-min=9.0 -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"
export CXX="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++ -arch x86_64 -fembed-bitcode-marker -mios-simulator-version-min=9.0 -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"
./configure --disable-shared --host="$X86_64_OUT"
make
mkdir -p $OUTPUT_X86_64_SIMULATOR/lib
ar r $OUTPUT_X86_64_SIMULATOR/lib/libffi.a ./$X86_64_OUT/src/*.o ./$X86_64_OUT/src/x86/*.o
cp -r $X86_64_OUT/include $OUTPUT_X86_64_SIMULATOR
rm -rf $X86_64_OUT

X86_64_CATALYST_OUT="x86_64-apple-darwin13"
export CC="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang -target x86_64-apple-ios13.3-macabi -miphoneos-version-min=13.3 -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
export CXX="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++ -target x86_64-apple-ios13.3-macabi -miphoneos-version-min=13.3 -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
./configure --disable-shared --host="$X86_64_CATALYST_OUT"
make
mkdir -p $OUTPUT_X86_64_MACCATALYST/lib
ar r $OUTPUT_X86_64_MACCATALYST/lib/libffi.a ./$X86_64_CATALYST_OUT/src/*.o ./$X86_64_CATALYST_OUT/src/x86/*.o
cp -r $X86_64_CATALYST_OUT/include $OUTPUT_X86_64_MACCATALYST
rm -rf $X86_64_CATALYST_OUT

popd