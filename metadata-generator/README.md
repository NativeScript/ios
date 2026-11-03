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

## Swift (Symbol Graph) support

The generator can import Swift modules from symbol graphs (`*.symbols.json`, as
written by `swiftc -emit-symbol-graph` or `swift symbolgraph-extract`). Graphs
are loaded structurally into a Swift-specific IR (`src/Swift/SwiftIR.h`): every
public declaration with its precise USR, kind, access level, parameters and
labels, effects (`async`/`throws`), settability, generics, availability,
extension info, and resolved relationships (members, conformances, superclass,
overrides, protocol requirements). Malformed or unexpected input is reported as
diagnostics with stable codes (`invalid-json`, `unsupported-format-version`,
`duplicate-symbol`, `parameter-label-mismatch`, ...); errors make the generator
exit non-zero.

`--swift-thunk-output <dir>` writes `<Module>+NativeScript.swift`: a Swift
thunk for every declaration the runtime can call, plus the
`ns_swift_register_<Module>` function the runtime looks up. `-output-typescript`
writes `swift!<Module>.d.ts`, declaring exactly that surface as the
`ns:swift/<Module>` module. Both come from the same registration model
(`src/Swift/SwiftSurface.h`). See `docs/swift-interop.md` for the app-side
workflow and the JavaScript semantics.

### Capability classification and coverage

Every declaration is classified into one tier, with machine-readable reasons
for anything not generated (`src/Swift/CapabilityClassifier.h` lists the
codes):

| Tier | Meaning |
|---|---|
| `objc-direct` | Objective-C-visible (`c:` USR); served by the existing metadata runtime |
| `swift-generated` | callable through a generated Swift thunk |
| `swift-specialized` | needs an explicit generic specialization first |
| `type-only` | representable in TypeScript, not callable (protocols, type aliases) |
| `unsupported` | not bridgeable yet; `reasons` say why |
| `not-applicable` | not an API surface (deinitializers, macros) |

The generated surface currently bridges `Bool`, integer and floating-point
types, `String`, optionals of those, module classes and actors (handles),
module structs (boxed copies) and payload-less enums (case-name strings).

`--swift-coverage-output <dir>` writes `<Module>.coverage.json`: counts per
tier and kind, a histogram of reasons, and every symbol's classification.
`effectiveCallable` counts what is callable through either the Objective-C
runtime or a thunk.

### Compiler verification

Symbol graphs do not carry every fact a call needs (e.g. `~Copyable` is often
invisible), so the generated surface can be checked by the Swift compiler.
`--swift-probe-output <dir>` writes `<Module>.probe.swift`, which calls every
generated declaration the way a thunk will, and a line map back to symbols.
`--swift-verify` type-checks those probes, demotes every declaration the
compiler rejects (`compiler-rejected:<message>`), and repeats until the probes
type-check:

```
./objc-metadata-generator --skip-objc \
	--swift-symbolgraph-dir <graphs> \
	--swift-deployment-target 15.0 \
	--swift-verify \
	--swift-sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
	--swift-target arm64-apple-ios15.0-simulator \
	--swift-search-path <dir containing the module's .swiftmodule> \
	--swift-coverage-output <out_dir>
```

`--swift-deployment-target` sets the version availability decisions are made
against; it defaults to the minimum version recorded in the graphs, which
`swift-symbolgraph-extract` sets to the SDK version.

```
./objc-metadata-generator \
	-output-typescript <out_dir> \
	--swift-symbolgraph-dir <path_to>/symbolgraphs \
	--swift-ir-output <ir_dir> \
	--skip-objc
```

- `--swift-symbolgraph-dir` – directory searched recursively for symbol graphs
- `--swift-ir-output` – optional; writes `<Module>.swift-ir.json`, a deterministic dump of the IR
- `--skip-objc` – skip the Objective-C phase

Environment variables (if using build-step script):
- `NS_SWIFT_SYMBOLGRAPH_DIR` (or `TNS_SWIFT_SYMBOLGRAPH_DIR`) – path to symbol graph directory
- `NS_SKIP_OBJC_METADATA` (or `TNS_SKIP_OBJC_METADATA`) – set to `1` to skip Objective-C phase

### Tests

`swift-symbolgraph-tests` is built alongside the generator and runs against the
checked-in graphs in `TestFixtures/SwiftDemo/symbolgraphs`, so it needs no Swift
toolchain:

```
cmake --build build --target swift-symbolgraph-tests
./build/bin/swift-symbolgraph-tests            # or: (cd build && ctest)
./build/bin/swift-symbolgraph-tests Snapshot   # run tests whose name contains "Snapshot"
```

The snapshot tests (`IRSnapshot`, `TypeScriptSnapshot`, `CoverageSnapshot`,
`ProbeSnapshot`) compare against `tests/swift/snapshots/`;
`ThunkSourceMatchesFixtureInterop` keeps
`TestFixtures/SwiftDemo/Interop/SwiftDemo+NativeScript.swift`, which TestRunner
compiles, identical to the generator's output. `TypeScriptUsageCompiles` runs
`tsc` (from `PATH` or `NS_TSC`) over `tests/swift/typescript/usage.ts`. `ProbesTypeCheck`
and the `Verifier*` tests build the fixture module and run the Swift compiler;
they are skipped when `xcrun` is unavailable. After an intended output change, regenerate them with
`NS_UPDATE_SNAPSHOTS=1 ./build/bin/swift-symbolgraph-tests` and review
the diff.
