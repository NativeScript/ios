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

checkpoint "Building metadata generator for arm64 ..."
build "arm64"
rm -rf build
popd