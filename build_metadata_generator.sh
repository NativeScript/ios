#!/bin/bash
set -e
source "$(dirname "$0")/build_utils.sh"

./download_llvm.sh

# try to build in the amount of threads available
# change this to 1 if you want single threaded builds
NUMJOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)

function build {
    rm -rf build
    mkdir build
    cmake -B build -DCMAKE_BUILD_TYPE=Release -DMETADATA_BINARY_ARCH=$1 -DCMAKE_OSX_ARCHITECTURES=$1
    cmake --build build --target clean
    cmake --build build -j$NUMJOBS
    mkdir "dist/$1"
    cp -r "build/bin" "dist/$1"
}

pushd "metadata-generator"
rm -rf dist
mkdir dist
checkpoint "Building metadata generator for x86_64 ..."
build "x86_64"
# make sure the binary is linked against the system libc++ instead of an @rpath one (which happens when compiling on arm64)
# todo: perhaps there is a better way to do this with cmake?
#install_name_tool -change @rpath/libc++.1.dylib /usr/lib/libc++.1.dylib dist/x86_64/bin/objc-metadata-generator
otool -L  dist/x86_64/bin/objc-metadata-generator

checkpoint "Building metadata generator for arm64 ..."
build "arm64"
otool -L  dist/arm64/bin/objc-metadata-generator
rm -rf build
popd