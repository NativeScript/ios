# SwiftDemo fixture

A Swift package whose declarations cover the shapes the Swift symbol graph
loader must model: classes, structs, enums with raw and associated values,
protocols, actors, `@MainActor` types, nested types, overloads, operators,
subscripts, failable initializers, `async`/`throws`, `inout` and escaping
closure parameters, generics, availability, and extensions of both module and
standard library types.

`symbolgraphs/` holds the graphs generated from `Sources/`. The loader tests
read these checked-in files, so they run without a Swift toolchain. After
changing `Sources/`, regenerate the graphs and then the test snapshots:

```
./generate-symbolgraphs.sh
NS_UPDATE_SNAPSHOTS=1 ../../build/bin/swift-symbolgraph-tests Snapshot
```

Review the resulting snapshot diff before committing it; it is the record of
what the loader extracts.
