#!/bin/bash

pushd v8
git apply --cached ../v8.patch
git checkout -- .

popd
