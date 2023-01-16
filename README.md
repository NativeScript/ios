# Getting Started

To start diving into the v8 iOS runtime make sure you have Xcode and [Homebrew](https://brew.sh/) installed, and then run the following
```bash
# Install CMake
brew install cmake

# To avoid errors, you might need to link cmake to: /usr/local/bin/cmake
# xcode doesn't read your profile during the build step, which causes it to ignore the PATH
sudo ln -s /usr/local/bin/cmake $(which cmake)

# Clone repo
git clone https://github.com/NativeScript/ns-v8ios-runtime.git

# Initialize and clone the submodules
cd ns-v8ios-runtime
git submodule update --init

# Ensure that you have the required llvm binaries for building the metadata generator
./download_llvm.sh

# Open the runtime in Xcode
open v8ios.xcodeproj
```

Select the `TestRunner` target and an emulator and hit Run (the play button).

<img width="453" alt="Screenshot 2020-09-09 at 18 25 43" src="https://user-images.githubusercontent.com/879060/92626234-ee627680-f2c9-11ea-941b-6b43600f54e4.png">

This should take a while, but once built the emulator should start and show a black screen (this is normal). In this phase the app will run all the built-in tests, and report the results to the console:
```
Runtime initialization took 55ms
2020-09-09 18:30:37.797265+0200 TestRunner[14285:1238340] CONSOLE LOG: Application Start!
2020-09-09 18:30:38.288740+0200 TestRunner[14285:1238340] No implementation found for exposed method "nonExistingSelector"
2020-09-09 18:30:49.720055+0200 TestRunner[14285:1238340] CONSOLE LOG: SUCCESS: 684 specs, 0 failures, 0 skipped, 0 disabled in 11.81s.
```

If all tests pass, everything is good! At this point you can make changes to the runtime, add breakpoints and step through with the debugger. In the next section we'll see how to attach the runtime to an existing NativeScript application allowing us to debug runtime issues in actual apps.

# Attaching the runtime to a NativeScript app

In the existing app, we need to prepare the Xcode project using `ns prepare ios`. This will create a folder named `platforms/ios` and in there a `<appname>.xcworkspace` (or .xcodeproject but note the following...).

**IMPORTANT**: You can only attach the runtime to a `.xcworkspace` project (not a `.xcodeproj` project). If your app's platforms/ios folder does not contain a .xcworkspace file yet, you can do the following:

Add a new file `App_Resources/iOS/Podfile` with the following contents: 

```
pod 'IQKeyboardManager'
```

Now `ns clean` and prepare again with `ns prepare ios`.
This will make sure when the iOS project is generated that you end up with a .xcworkspace file so attaching the v8 runtime source works properly.

You can now open the `platforms/ios/{project-name}.xcworkspace` file in Xcode and then drag the `v8ios.xcodeproj` from the root of this repo under the `<appname>` in the Xcode sidebar.

<img width="941" alt="Screenshot 2020-09-09 at 18 46 18" src="https://user-images.githubusercontent.com/879060/92628228-c294c000-f2cc-11ea-8822-58df689d3cd3.png">

Remove the `NativeScript.xcframework` and `TNSLiveSync.xcframework` from the General tab, as we will no longer be using the framework from node_modules and instead will use the source directly:

<img width="693" alt="Screenshot 2020-09-09 at 18 47 23" src="https://user-images.githubusercontent.com/879060/92628311-e6f09c80-f2cc-11ea-8977-201517badc3b.png">

Hitting Run in Xcode should start the app in the simulator, and we can now add breakpoints to the runtime and step through it with the debugger. To apply changes to the javascript, make sure you run `ns prepare ios` to re-bundle it into the `platforms/ios` folder.

## Only required when running on a physical device

Add the `Nativescript.framework` from the v8ios workspace:

<img width="402" alt="Screen Shot 2021-04-12 at 11 49 10 AM" src="https://user-images.githubusercontent.com/2379994/114423589-51c8c580-9b85-11eb-9d30-eb1cbf73454a.png">

## Troubleshooting

If you encounter vague errors like this when building your app with the runtime included (This has been observed sometimes while Profiling apps in Xcode):

```
/path/to/ns-v8ios-runtime/NativeScript/inspector/src/base/atomicops.h:311:11: No matching function for call to 'Relaxed_Load'
```

This is most likely related to `Build Active Architecture Only` setting in Xcode for various targets (your app and the included v8ios runtime). You should check to make sure your app `Build Settings` and the v8ios targets `NativeScript` and `TKLiveSync` Build Settings are set to YES for both Debug and Release. See this reference:
https://github.com/QuickBlox/quickblox-ios-sdk/issues/993#issuecomment-379656716


# Overview

POC showing the [{N} iOS runtime](https://github.com/NativeScript/ios-runtime) running with the V8 engine.

Supported architectures:

 - x86_64
 - arm64

iOS deployment target:
 - 9.0

The `--jitless` mode in which V8 is running is explained in the following [document](https://docs.google.com/document/d/1YYU17VqFMBeSJ8whCqXknOGXtXDVDLulchsTkmi0YdI/edit#heading=h.mz26kq2dsu6k)

# Updating/Building V8 engine source

In order to build the V8 engine for iOS and produce the static libraries used in the NativeScript iOS runtime follow these steps:

**Prerequisites:**

```
git clone https://github.com/NativeScript/ns-v8ios-runtime.git
cd ns-v8ios-runtime
```

You will need Google [depot_tools](https://www.chromium.org/developers/how-tos/install-depot-tools)

* If you have not cloned the repo yet, clone the following and export a path setting so they can be referenced properly:

```
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git

// copy/paste this command in current terminal window:
export PATH=`pwd`/depot_tools:"$PATH"
```

1. Fetch the latest v8 source (or specific version):

> If you have an existing v8 source fetched, delete the folder, and fetch it fresh each time updates are needed.

```
// IMPORTANT: Make sure you are inside the clone of this repo...
cd ns-v8ios-runtime

// Fetch v8 source:
fetch v8
```

This will create a `v8` repo folder automatically checking out the `master` branch.

Always check https://omahaproxy.appspot.com/ for the specific version you intend to build.

2. Ensure you checkout the version you intend to build:

```
cd v8

// for example:
git checkout 9.2.230.18

gclient sync
```

This will checkout a specific tag and fetch additional dependencies for building the intended version.

3. Apply patches from v8 updates to the iOS runtime:

```
npm run apply-patches
```

NOTE: Oftentimes the patches may not apply immediately and can run into issues like this:

```
error: patch failed: BUILD.gn:538
error: BUILD.gn: patch does not apply
error: patch failed: src/inspector/inspector_protocol_config.json:21
error: src/inspector/inspector_protocol_config.json: patch does not apply
~/Documents/ns-v8ios-runtime/v8/build ~/Documents/ns-v8ios-runtime/v8 ~/Documents/ns-v8ios-runtime
error: patch failed: config/ios/ios_sdk.gni:32
error: config/ios/ios_sdk.gni: patch does not apply
```

You can look at each patch failure, for example `BUILD.gn: patch does not apply`, you can apply the patch manually instead. This can be done by opening the `./v8.patch` file and applying each patch manually to the corresponding file.

4. Build v8 source:

```
npm run build-v8-source
```

*Troubleshooting build errors*

* Example failure 1:

```
@Mac ns-v8ios-runtime % npm run build-v8-source

> @nativescript/ios@8.1.0 build-v8-source
> ./build_v8_source.sh

~/Documents/ns-v8ios-runtime/v8 ~/Documents/ns-v8ios-runtime
Building for out.gn/x64-release (simulator)
Done. Made 212 targets from 92 files in 4004ms
ninja: Entering directory `out.gn/x64-release'
ninja: error: unknown target 'v8_libsampler'
```

In this case, the v8_libsampler module no longer needs to be built specifically as a target, therefore the MODULES inside the `build_v8_source.sh` can be modified to remove the target of `v8_libsampler` and the build can be invoked again.

* Example failure 2:

```
ERROR at //build/config/ios/ios_sdk.gni:181:33: Script returned non-zero exit code.
    ios_code_signing_identity = exec_script("find_signing_identity.py",

Automatic code signing identity selection was enabled but could not
find exactly one codesigning identity matching "Apple Development".

Check that the keychain is accessible and that there is exactly one
valid codesigning identity matching the pattern. Here is the parsed
output of `xcrun security find-identity -v -p codesigning`:

  1) 1ABE0***********************************: "Apple Development: Your Name (U4********)"
  2) CB529***********************************: "Apple Distribution: Your Org (29********)"
  3) BACD5***********************************: "Apple Development: Your Name (VV********)"
  4) 0D42D***********************************: "Apple Development: Your Team (D3********)"
  5) 055BA***********************************: "Apple Development: Your Name (GF********)"
  6) A5306***********************************: "Apple Development: Your Name (9V***********)"
    6 valid identities found
```

If this occurs you can manually modify `v8/build/config/ios/ios_sdk.gni`. A property named `ios_code_signing_identity`. You can set that explicitly to one of your code signing identities. You can use the command it suggests to list out your identities in full: `xcrun security find-identity -v -p codesigning` - Copy the id and paste it as the value of `ios_code_signing_identity`.

You will want to make `ios_code_signing_identity_description` an empty string so the final change should look something like this:

```
# Explicitly select the identity to use for codesigning. If defined, must
# be set to a non-empty string that will be passed to codesigning. Can be
# left unspecified if ios_code_signing_identity_description is used instead.
ios_code_signing_identity = "...your-id..."

# Pattern used to select the identity to use for codesigning. If defined,
# must be a substring of the description of exactly one of the identities by
# `security find-identity -v -p codesigning`.
ios_code_signing_identity_description = ""
```

5. If building of the v8 source succeeds, Verify the build output.

The compiled fat static libraries will be placed inside the `v8/dist` folder.

# Building a Distribution Package

1. Bump the version in package.json

2. Run: `npm run update-version` (*This will update the runtime headers with version info*)

3. Build & pack: `npm run build`

This will create: `dist/npm/nativescript-ios-{version}.tgz` NPM package ready for publishing.
