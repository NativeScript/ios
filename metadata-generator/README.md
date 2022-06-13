# Objective-C Metadata Generator

This project generates the metadata for the target iOS application. The build parameters are gathered by the `build-step-metadata-generator.py` and turned into command line parameters for the `objc-metadata-generator`.

## Building

```bash
cmake -B build
cmake --build build --target=clean
cmake --build build
# this can be sped up by using -jN where N is the number of cores.
# ex: cmake --build build -j10
```

### Additional cmake flags

* `-DMETADATA_BINARY_ARCH=arm64`: Generate the metadata for the arm64 architecture. Possible values: `arm64`, `x86_64`.
* `-DCMAKE_OSX_ARCHITECTURES=arm64`: Generate the metadata for the arm64 architecture. Possible values: `arm64`, `x86_64`.
* `-DCMAKE_BUILD_TYPE=Release`: Build the project in release mode.

Example:

```bash
METADATA_ARCH="arm64" # or "x86_64"
cmake -B build -DCMAKE_BUILD_TYPE=Release -DMETADATA_BINARY_ARCH=$METADATA_ARCH -DCMAKE_OSX_ARCHITECTURES=$METADATA_ARCH
cmake --build build
```

## Debugging the metadata generator

To debug the metadata generator you first need to generate the xcode project for it:

```bash
cmake -B cmake-build -G Xcode
```

This will create the xcode project in the `cmake-build` directory, which you can open with `open cmake-build/MetadataGenerator.xcodeproj`.

To build and run the metadata generator you must first change the Scheme to `objc-metadata-generator`, then you must edit this scheme and add the command line parameters for the `Arguments Passed on Launch` section. These parameters can be found on the `build-step-metadata-generator.py` script or in the build logs for an app, in the metadata generator step. If getting this data from another app, ensure that the paths set on the command line are accurate (not relative to the app's directory).

Example command line arguments:
```bash
# replace NSV8RUNTIMEPATH with the path to the ns-v8ios-runtime path, ex: /Users/you/ns-v8ios-runtime
# replace YOU with your username
-verbose -output-typescript /tmp/tsdeclarations/ -output-bin NSV8RUNTIMEPATH/build/Debug-iphonesimulator/metadata-arm64.bin -output-umbrella NSV8RUNTIMEPATH/build/Debug-iphonesimulator/umbrella-arm64.h -docset-path /Users/YOU/Library/Developer/Shared/Documentation/DocSets/com.apple.adc.documentation.iOS.docset Xclang -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator15.2.sdk -mios-simulator-version-min=9.0 -std=gnu99 -target arm64-apple-ios15.2-simulator -INSV8RUNTIMEPATH/build/Debug-iphonesimulator/include -INSV8RUNTIMEPATH/NativeScript -INSV8RUNTIMEPATH/TestFixtures -FNSV8RUNTIMEPATH/build/Debug-iphonesimulator -DCOCOAPODS=1 -DDEBUG=1 -I. -fmodules 
```

For a better way of generating these arguments, just run the TestRunner scheme on the v8ios-runtime project and get the arguments from the log.
