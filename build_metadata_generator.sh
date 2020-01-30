#!/bin/bash
set -e

pushd "metadata-generator"
cmake -DCMAKE_BUILD_TYPE=Release .
make clean
make
cp build-step-metadata-generator.py bin
popd