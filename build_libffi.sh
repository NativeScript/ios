#!/bin/bash
set -e

pushd libffi

./autogen.sh

ARM64_OUT="aarch64-apple-darwin13"
export CC="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang -arch arm64 -fembed-bitcode -miphoneos-version-min=10.0 -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
export CXX="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++ -arch arm64 -fembed-bitcode -miphoneos-version-min=10.0 -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
./configure --disable-shared --host="$ARM64_OUT"
make
ar r ./$ARM64_OUT/libffi.a ./$ARM64_OUT/src/*.o ./$ARM64_OUT/src/aarch64/*.o

#ARM_OUT="armv7-apple-darwin13"
#export CC="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang -arch armv7 -fembed-bitcode -miphoneos-version-min=10.0 -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
#export CXX="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++ -arch armv7 -fembed-bitcode -miphoneos-version-min=10.0 -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
#./configure --disable-shared --host="$ARM_OUT"
#make
#ar r ./$ARM_OUT/libffi.a ./$ARM_OUT/src/*.o ./$ARM_OUT/src/arm/*.o

X86_64_OUT="x86_64-apple-darwin13"
export CC="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang -arch x86_64 -fembed-bitcode-marker -mios-simulator-version-min=10.0 -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"
export CXX="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++ -arch x86_64 -fembed-bitcode-marker -mios-simulator-version-min=10.0 -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"
./configure --disable-shared --host="$X86_64_OUT"
make
ar r ./$X86_64_OUT/libffi.a ./$X86_64_OUT/src/*.o ./$X86_64_OUT/src/x86/*.o

#lipo ./$ARM64_OUT/libffi.a ./$ARM_OUT/libffi.a ./$X86_64_OUT/libffi.a -create -output ./libffi.a
lipo ./$ARM64_OUT/libffi.a ./$X86_64_OUT/libffi.a -create -output ./libffi.a

rm -rf ./aarch64-apple-darwin13
rm -rf ./x86_64-apple-darwin13

popd