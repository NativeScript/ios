#!/bin/bash
set -e

function build {
    rm -rf build
    mkdir build
    pushd "build"
    cmake -DCMAKE_BUILD_TYPE=Release -DMETADATA_BINARY_ARCH=$1 -DCMAKE_OSX_ARCHITECTURES=$1 ../
    make clean
    make
    cp ../build-step-metadata-generator.py bin
    popd
    mkdir "dist/$1"
    cp -r "build/bin" "dist/$1"
}

pushd "metadata-generator"
rm -rf dist
mkdir dist
echo "Building metadata generator for x86_64 ..."
build "x86_64"

echo "Building metadata generator for arm64 ..."
build "arm64"
rm -rf build
popd