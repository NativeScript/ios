# Build and test the tvOS review stack

This builds an isolated `org.nativescript.tvosreview` app from the pinned contribution branches. It does not require the author's app, framework bundles, npm cache, signing team, or local Rust paths. V8 and metadata generation are built from source. npm and Cargo dependencies still require network access; the app's resolved npm lockfile is retained in the workspace.

## Prerequisites

Use an Apple Silicon Mac with Xcode and its iOS and tvOS SDKs installed and selected with `xcode-select`. The validation host uses Xcode 26.6, Node 22.23.2, Python 3, CocoaPods 1.17, cbindgen, and Rust nightly 2026-09-07. Install `rustup`, `cbindgen`, CMake, jq, and CocoaPods before starting. The script installs the pinned Rust toolchain and `rust-src`. Python must trust the HTTPS certificate chain; installing `certifi` lets the script use its CA bundle.

The host package/test steps pin npm 10.9.8 inside `host-tooling`, because upstream CLI fixtures still rely on npm 10 behavior. The app setup installs npm 12.0.2 inside the workspace because npm 10 crashes while resolving this peer-dependency graph. Node must meet its requirement, 22.22.2 or newer in the Node 22 series. Local review tarballs use a stable version with `+review.<revision>` build metadata so npm peer ranges accept upstream prerelease sources.

Make `pod` and its matching Ruby visible on PATH. If CocoaPods uses a separate GEM_HOME, export that environment too. Do not copy a machine-specific Cellar path from another Mac.

Allow several hours and at least 100 GB free space for the first build. V8 compiles separately for device and simulator. The device deployment target is tvOS 13.0; Xcode raises the arm64 simulator minimum to tvOS 14.0. No Apple signing account is needed for the simulator workflow.

## Run

From the runtime PR checkout, choose an empty directory outside the checkout:

```sh
python3 tools/tvos-review/review.py doctor --workspace /path/to/tvos-review
python3 tools/tvos-review/review.py all --workspace /path/to/tvos-review \
  --simulator YOUR_APPLE_TV_SIMULATOR_UDID --jobs 6
```

Find a simulator with `xcrun simctl list devices available`. The `test` step runs Core and CLI host suites, the test runner suite, and `ns test tvos` on the selected simulator. The fixture injects a Foundation text-WebSocket transport through the test runner's `createSocket` option. The default `@valor/nativescript-websockets` binary currently lacks tvOS slices, so an unmodified `ns test init` scaffold still needs a compatible transport.

The six app tests exercise platform detection, writable cache storage, Canvas 2D pixels and Unicode metrics, ImageData ownership across garbage collection, WebGL typed buffers and readback, WebGPU compute readback, and query cleanup.

The `checkout`, `runtime`, `packages`, `canvas`, `helpers`, `app`, and `test` steps can also be selected individually. Resume after a failure by running the failed step after correcting its cause. Preserve the failed app directory for comparison; `app` deliberately refuses to overwrite an existing app. Use another empty workspace for a complete clean rerun.

`revisions.json` pins companion repositories. The runtime is pinned to the checkout containing this script, so that commit must be published before `checkout`. `canvas-extras.json` lists independent Canvas fixes to apply on top of its tvOS branch. The script writes the resolved revisions and every command's output under the workspace. It adds a workspace-only Cargo override pointing to the pinned rust-skia fork until that dependency is available upstream.

## Device and distribution checks

Physical devices need your own signing team and provisioning. Use the generated app and the workspace CLI:

```sh
cd /path/to/tvos-review/app
node ../cli/bin/tns run tvos --device YOUR_APPLE_TV_UDID --team-id YOUR_TEAM --no-local-cli
node ../cli/bin/tns build tvos --release --for-appstore --team-id YOUR_TEAM --no-local-cli
```

With an explicit paired Apple TV identifier (CoreDevice UUID, hardware UDID, or unique device name), `ns run tvos` uses Apple's `devicectl` transport. Find identifiers with `xcrun devicectl list devices`. Simulator identifiers continue through the simulator transport. The network-paired device path builds an IPA, installs it and launches the app. Use `--no-watch` for a single deployment; the default watcher performs a full rebuild/install on source or resource changes. HMR, debugger attachment and console streaming are not implemented for this transport. `ns device` still uses the existing discovery backend.

An asleep Apple TV cannot be launched by this workflow; the command reports the launch failure. A simulator pass does not establish physical controller, audio, haptics, frame pacing, or App Store acceptance. The generated fixture is a test app, not a submission-ready product.

## Template regression

```sh
TVOS_REVIEW_CLI=/path/to/tvos-review/cli python3 tests/tvos/template.py
```

This verifies that `project-template-tvos` is the current upstream iOS template plus the tvOS build settings, agrees with the bundled local runtime package, survives both packaging stamps (the released ios-spm pin and the embedded local package), and parses with the actual CLI project parser. Run it again when upstream changes the iOS template.
