#!/bin/bash

pushd "metadata-generator"
cmake .
make clean
make
cp build-step-metadata-generator.py bin
popd