#!/bin/bash
set -e
source "$(dirname "$0")/build_utils.sh"

LLVM_VERSION="17.0.6"

function download_llvm() {
    checkpoint "Downloading llvm (version $LLVM_VERSION)..."
    mkdir -p /tmp/llvm-dl/
    curl -L https://github.com/NativeScript/ios-llvm/releases/download/v$LLVM_VERSION/llvm-$LLVM_VERSION.tgz -o /tmp/llvm-dl/llvm-$LLVM_VERSION.tgz
    mkdir -p ./llvm/
    checkpoint 'extracting llvm...'
    tar -xzf /tmp/llvm-dl/llvm-$LLVM_VERSION.tgz -C ./llvm/
}

if [ ! -d "./llvm/$LLVM_VERSION" ]; then
    download_llvm
fi
