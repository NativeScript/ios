# Getting Started

To start diving into the v8 iOS runtime make sure you have Xcode and [Homebrew](https://brew.sh/) installed, and then run the following
```bash
# Install CMake
brew install cmake

# (Optional) Install clang-format to format the code
brew install clang-format

# To avoid errors, you might need to link cmake to: /usr/local/bin/cmake
# xcode doesn't read your profile during the build step, which causes it to ignore the PATH
sudo ln -s $(which cmake) /usr/local/bin/cmake

# Clone repo
git clone https://github.com/NativeScript/ios.git

# Initialize and clone the submodules
cd ios
git submodule update --init

# Ensure that you have the required llvm binaries for building the metadata generator
./download_llvm.sh

# Fetch the prebuilt V8 libraries and headers for the release pinned in V8_RELEASE
# (set V8_SKIP_DOWNLOAD=1 to keep a local V8 build instead)
./download_v8.sh

sudo gem install xcodeproj
sudo gem install cocoapods

# Record this shell's node in .xcode.env.local and open the runtime in Xcode
# (Xcode build phases don't see your shell's PATH — see "Node.js in Xcode builds")
npm run open-xcode
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

## Node.js in Xcode builds

Building the `NativeScript` target generates the runtime JS builtins with `tools/js2c.mjs`, which needs Node.js. Xcode runs build phases with a minimal `PATH` and never reads your shell profile, so a node managed by nvm/fnm/volta/asdf is invisible to it. The build phase instead sources two files from the repo root:

- `.xcode.env` — committed defaults (`NODE_BINARY=$(command -v node)`, enough for Homebrew installs and `xcodebuild` runs from a terminal)
- `.xcode.env.local` — gitignored per-machine overrides, sourced last so it wins

`npm run setup-xcode-env` writes the node from your current shell into `.xcode.env.local` (other variables in the file are preserved); `npm run open-xcode` does that and then opens `v8ios.xcodeproj`. If a build fails with `no usable node for tools/js2c.mjs`, run either command — or point `NODE_BINARY` at a node binary yourself, in `.xcode.env.local` or the build environment.

# Documentation

Runtime feature documentation lives in the [docs](docs/README.md) folder — see [Error handling](docs/error-handling.md) for the global error events, native exception round-tripping and `interop.escapeException`.

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

The runtime's builtins build phase needs node even when the project builds inside your app's workspace, so run `npm run setup-xcode-env` in the runtime repo at least once per machine (see [Node.js in Xcode builds](#nodejs-in-xcode-builds)).

<img width="941" alt="Screenshot 2020-09-09 at 18 46 18" src="https://user-images.githubusercontent.com/879060/92628228-c294c000-f2cc-11ea-8822-58df689d3cd3.png">

Remove the `NativeScript.xcframework` and `TKLiveSync.xcframework` from the General tab, as we will no longer be using the framework from node_modules and instead will use the source directly:

<img width="693" alt="Screenshot 2020-09-09 at 18 47 23" src="https://user-images.githubusercontent.com/879060/92628311-e6f09c80-f2cc-11ea-8977-201517badc3b.png">

Hitting Run in Xcode should start the app in the simulator, and we can now add breakpoints to the runtime and step through it with the debugger. To apply changes to the javascript, make sure you run `ns prepare ios` to re-bundle it into the `platforms/ios` folder.

## Only required when running on a physical device

Add the `Nativescript.framework` and `TKLiveSync.framework` from the v8ios workspace:

<img width="402" alt="Screen Shot 2021-04-12 at 11 49 10 AM" src="https://user-images.githubusercontent.com/2379994/114423589-51c8c580-9b85-11eb-9d30-eb1cbf73454a.png">

## Troubleshooting

If you encounter vague errors like this when building your app with the runtime included (This has been observed sometimes while Profiling apps in Xcode):

```
/path/to/ios/NativeScript/inspector/src/base/atomicops.h:311:11: No matching function for call to 'Relaxed_Load'
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

The V8 libraries and the headers that must match them are not committed here.
`./download_v8.sh` installs them from the release pinned in `V8_RELEASE`,
verifying the archives against the checksums published with them. It is a no-op
once they are in place, and `build_nativescript.sh` calls it for you.

```
./download_v8.sh                       # install the pinned release
./download_v8.sh --release <tag>       # install a different one
V8_SKIP_DOWNLOAD=1 ./build_all_ios.sh  # keep a local V8 build instead
```

To change the V8 version, or to build it yourself, see
[NativeScript/v8-buildscripts](https://github.com/NativeScript/v8-buildscripts).
It builds every Android ABI and Apple variant in CI and publishes them as
release assets — which it has to, because the full matrix cannot be produced on
any single machine: the 32-bit Android ABIs need an ia32-capable host and the
Apple variants need macOS.


# Building a Distribution Package

1. (Optional) Bump the version in package.json

2. Run: `npm run update-version` (*This will update the runtime headers with version info*)

3. Build & pack: `npm run build-ios`

This will create `dist/nativescript-ios-{version}.tgz`.

The runtime's NativeScript / TKLiveSync xcframeworks are consumed via SwiftPM, and the
package can be built in two modes (`--spm-mode`, see `./build_npm_ios.sh --help`):

- **`embedded` (default)** — a self-contained package: the freshly built xcframeworks are
  embedded (as zips, since npm strips symlinks) at `framework/internal/local-spm` together
  with a local SwiftPM manifest, and the app template consumes them by relative path.
  The tgz works on any machine. This is what local builds and PR artifacts produce.
- **`remote`** — the deploy shape published to npm by the release workflow
  (`npm run build-ios -- --spm-mode=remote`): no binaries are embedded; the app template
  pins https://github.com/NativeScript/ios-spm at exactly the package version. The release
  workflow uploads the xcframework zips as GitHub Release assets and tags ios-spm to match,
  so a remote-mode package only resolves for versions that shipped through
  `.github/workflows/npm_release.yml` — don't use this mode for local builds.

# Local Development & Linking

To use a locally built runtime in an app, build the default (embedded) package and point
the {N} CLI at it:

```bash
npm run build-ios
ns platform add ios --framework-path=/path/to/ns-v8ios-runtime/dist/nativescript-ios-{version}.tgz
```

Because the embedded package is self-contained, the tgz can be copied to other machines,
shared with teammates, or consumed by an app's CI. The same applies to the `npm-package`
artifact produced by this repo's pull-request workflow — download it and use it with
`--framework-path` directly.

To rebuild just the package after runtime changes (without the full `build-ios` pipeline),
re-run `./build_spm_artifacts.sh ios` followed by `./build_npm_ios.sh`.
