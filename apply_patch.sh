#!/bin/bash

pushd v8
git apply --cached ../v8.patch
git checkout -- .

#pushd build
#git apply --cached ../../build.patch
#git checkout -- .
#popd

popd
