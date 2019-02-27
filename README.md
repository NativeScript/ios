# Overview

POC showing the V8 engine running in an iOS application. Currently only the x86_64 and arm64 architectures are supported.

The `--jitless` mode in which V8 is running is explained in the following [document](https://docs.google.com/document/d/1YYU17VqFMBeSJ8whCqXknOGXtXDVDLulchsTkmi0YdI/edit#heading=h.mz26kq2dsu6k)

The sample iOS application runs the [Octane 2.0 Benchmark](https://github.com/chromium/octane) and outputs the results.

# Building V8

In order to build the V8 engine for iOS and produce static libraries follow those steps:

* Get [depot_tools](https://www.chromium.org/developers/how-tos/install-depot-tools)

```
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
export PATH=`pwd`/depot_tools:"$PATH"
```

* `fetch v8` (this will create a `v8` repo folder automatically checking out the `master` branch)

* Apply patches: `apply_patch.sh`

* Run `build.sh`

The compiled fat static libraries will be placed inside the `v8/dist` folder.

# Octane Benchmark Results

Using the Octane benchmark we have compared the performance of V8 against JSC used in the [ios-runtime](https://github.com/NativeScript/ios-runtime).

The tests have been executed on an iPhone 7 (iOS version 11.2.1)

| V8 | JSC |
| --- | --- |
| 1843 | 1507 |
