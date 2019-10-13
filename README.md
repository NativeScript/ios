# Overview

POC showing the [{N} iOS runtime](https://github.com/NativeScript/ios-runtime) running with the V8 engine.

Supported architectures:

 - x86_64
 - arm64

iOS deployment target:
 - 9.0

 Required LLVM version:
 - [LLVM 8.0](http://releases.llvm.org/download.html#8.0.0) - used to build the [metadata generator](https://github.com/NativeScript/ios-metadata-generator) submodule. Be sure to have the folder containing `llvm-config` in `PATH` or make a symlink to in `/usr/local/bin/`.

The `--jitless` mode in which V8 is running is explained in the following [document](https://docs.google.com/document/d/1YYU17VqFMBeSJ8whCqXknOGXtXDVDLulchsTkmi0YdI/edit#heading=h.mz26kq2dsu6k)

# Building V8

In order to build the V8 engine for iOS and produce the static libraries used in this project follow those steps:

1. Get [depot_tools](https://www.chromium.org/developers/how-tos/install-depot-tools)

```
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
export PATH=`pwd`/depot_tools:"$PATH"
```

2. `fetch v8` (this will create a `v8` repo folder automatically checking out the `master` branch)

3. Apply patches: `apply_patch.sh`

4. Run `build_v8.sh`

The compiled fat static libraries will be placed inside the `v8/dist` folder.

# Building a Distribution Package

Use the `build_all.sh` script included in this repository to produce the `dist/npm/tns-ios-{version}.tgz` NPM package.