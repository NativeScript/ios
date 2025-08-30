This is a tiny Swift package used to generate a Symbol Graph for testing.

Generate symbol graph (optional):

```
cd metadata-generator/TestFixtures/SwiftDemo
# Swift 5.9+ required
swift build
swift symbolgraph-extract --module-name SwiftDemo --minimum-access-level public --output-dir .symbolgraph
```

Then run the metadata generator:

```
# Add your normal args plus:
#   --output-typescript <out_dir>
#   --swift-symbolgraph-dir <path_to_this>/TestFixtures/SwiftDemo/.symbolgraph
# The ObjC path can still run as usual.
```

Example:
```
cd ../../..
./build/objc-metadata-generator \
  -output-typescript /tmp/ts-out \
  --swift-symbolgraph-dir metadata-generator/TestFixtures/SwiftDemo/.symbolgraph \
  --skip-objc
```

Result: 
- `/tmp/ts-out/swift!SwiftDemo.d.ts` (skeleton content, e.g., declare class Demo, interface Greeter, struct Point, enum Flavor)

If you prefer running via the build-step script, set:

```
NS_SWIFT_SYMBOLGRAPH_DIR=/absolute/path/to/.symbolgraph
NS_SKIP_OBJC_METADATA=1
```

Done:

- CMake wired to compile new sources:
  - Added Swift/SymbolGraphParser.{h,cpp} and TypeScript/SwiftDefinitionWriter.{h,cpp} to CMakeLists.txt.
- CLI integration:
  -In main.cpp: added --swift-symbolgraph-dir and --skip-objc, scan symbolgraph dir, parse per module, emit swift!<Module>.d.ts. Obj‑C phase is skipped when --skip-objc is set.
- Swift parser (bootstrap):
  - Swift/SymbolGraphParser: scans a directory for .symbolgraph/.symbols.json, groups by module, and creates placeholder Meta entries (class/struct/enum/protocol) to prove the pipeline.
- Swift TS writer (bootstrap):
  - TypeScript/SwiftDefinitionWriter: writes minimal TS declarations from the Swift Meta set.
- Build step env passthrough:
  - build-step-metadata-generator.py: respects NS_SWIFT_SYMBOLGRAPH_DIR/TNS_SWIFT_SYMBOLGRAPH_DIR and NS_SKIP_OBJC_METADATA/TNS_SKIP_OBJC_METADATA.
- Test fixture:
  - TestFixtures/SwiftDemo SwiftPM package with Demo.swift and README showing how to emit symbol graphs.