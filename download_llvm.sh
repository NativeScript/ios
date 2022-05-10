#!/bin/bash
set -e

function download_llvm() {
    echo 'Downloading llvm...'
    mkdir -p /tmp/llvm-dl/
    curl -L https://github.com/NativeScript/ios-llvm/releases/download/v13.0.1/llvm-13.0.1.tgz -o /tmp/llvm-dl/llvm-13.0.1.tgz
    mkdir -p ./llvm/
    echo 'extracting llvm...'
    tar -xzf /tmp/llvm-dl/llvm-13.0.1.tgz -C ./llvm/
}

if [ ! -d "./llvm/13.0.1" ]; then
    download_llvm
fi
