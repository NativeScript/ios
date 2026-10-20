# Swift interop

The runtime can call pure Swift APIs — Swift classes, actors, structs and
enums that are not visible to Objective-C — through small Swift thunks the
metadata generator emits at build time. Objective-C-visible APIs keep using the
existing metadata path; this covers what that path cannot reach.

```js
const { Demo, Point, Flavor } = require("ns:swift/SwiftDemo");
// or: import { Demo, Point, Flavor } from "ns:swift/SwiftDemo";
// or: require("ns:swift").module("SwiftDemo")

const demo = new Demo();
demo.greet("NativeScript");          // "Hello, NativeScript"
const point = new Point({ x: 2, y: 3 });
point.x;                             // 2
Flavor.vanilla;                      // "vanilla"
```

## How it fits together

1. **Symbol graphs.** Compile the Swift module with `-emit-symbol-graph` (or run
   `swift symbolgraph-extract`) to get `<Module>.symbols.json` and its
   `<Module>@<Other>.symbols.json` extension graphs.
2. **Generation.** `objc-metadata-generator --swift-symbolgraph-dir <graphs>`
   loads them into the Swift IR, classifies every declaration
   (`--swift-coverage-output` reports the result) and can have the Swift
   compiler confirm the classification (`--swift-verify`). From the verified
   classification it writes:
   - `--swift-thunk-output`: `<Module>+NativeScript.swift`, one thunk per
     callable declaration plus a registration function;
   - `-output-typescript`: `swift!<Module>.d.ts`, declaring exactly what the
     thunks expose (`declare module "ns:swift/<Module>"`).
3. **Build.** Compile the thunk file in a module that imports `<Module>` and
   link it into the app. It exports one C symbol, `ns_swift_register_<Module>`;
   because nothing references it statically, link with
   `-Wl,-u,_ns_swift_register_<Module>` and keep it in any exported-symbols
   list.
4. **Runtime.** The first `ns:swift/<Module>` access looks the register
   symbol up with `dlsym`, records the module's types and members, and builds
   its JavaScript classes for the current isolate.

`TestRunner` does all of this for the `SwiftDemo` fixture
(`metadata-generator/TestFixtures/SwiftDemo`): the `SwiftDemo` target compiles
the fixture sources together with the generated `Interop/` file, whose
contents the generator tests keep identical to the generator's output. The
fixture's `Package.swift` builds the same files as two SwiftPM modules.

## Value model

| Swift | JavaScript |
|---|---|
| `Bool` | `boolean` |
| `Int`, `Int8`…`Int64`, `UInt`…`UInt64` | `number` (or `BigInt` as input); values outside ±(2⁵³−1) throw `RangeError` rather than lose precision |
| `Float`, `Double`, `CGFloat` | `number` |
| `String` | `string` |
| `T?` | `T` or `null` (inputs also accept `undefined`) |
| class, actor | an instance of the generated JS class; one JS object per Swift object |
| struct | an instance of the generated JS class holding its own copy |
| enum without associated values | the case name as a string; the enum's namespace object (`Flavor.vanilla`) lists them |

Structs have value semantics: reading a struct-typed property, passing a struct
argument, or returning one copies it, so a JS object never aliases another
copy. Mutating members and property setters change the copy the JS object
holds.

## Calling conventions

- Methods and functions take positional arguments. Overloads with the same
  JavaScript name are resolved by argument count and by which overloads accept
  the arguments' JS types.
- When more than one overload accepts the arguments (`scale(by: Double)` and
  `scale(by: Int)` both accept a number), the call throws a `TypeError` naming
  the overloads' keys; call one directly by key: `polygon["scale(by: Int)"](2)`.
  Every overload is also reachable by its Swift name when that is unique
  (`demo["greet(name:times:)"]("a", 2)`).
- Initializers run through `new` and also accept one object naming every
  argument label: `new Point({ x: 2, y: 3 })`. A failable initializer that
  returns `nil` throws.
- Subclass instances accept inherited overloads; JS classes follow the Swift
  class hierarchy (`instanceof` works).
- Enum initializers are `Enum.init(...)`, returning a case name or `null`.
  Enum instance members are functions taking the case name first:
  `Flavor.description("vanilla")`.
- Properties are accessors; read-only Swift properties have no setter.

## Errors

- A Swift `throw` becomes a JS `Error` with `name === "SwiftError"`,
  `message` set to `String(describing: error)` and `swiftType` set to the
  error's type name.
- Arguments of the wrong type throw `TypeError`; out-of-range integers throw
  `RangeError`.
- Calling a declaration that is newer than the running OS throws an `Error`
  naming the required version.

## Identity and lifetime

A Swift object returned to JavaScript is retained once by its JS wrapper and
released when the wrapper is garbage collected; returning the same object again
yields the same wrapper. Wrappers belong to the isolate that created them, so
each worker gets its own JS objects.

## Coverage and verification

Every declaration gets one tier — `objc-direct`, `swift-generated`,
`swift-specialized`, `type-only`, `unsupported` or `not-applicable` — with
machine-readable reasons (`metadata-generator/src/Swift/CapabilityClassifier.h`).
`--swift-verify` type-checks a probe for every generated declaration with the
Swift compiler, demotes whatever it rejects as `compiler-rejected:<message>`,
and repeats until everything that remains compiles. Symbol graphs cannot
express every fact a call depends on (`~Copyable` is often invisible), so
verification is what makes the generated surface trustworthy at SDK scale.

## Not yet supported

`async` functions, actor-isolated and `@MainActor` members, closures and
callbacks, `inout` parameters, generics, protocols as values, collections,
tuples, enums with associated values, nested types, subscripts, operators, and
Foundation value types (`URL`, `Data`, `Date`). Each appears in the coverage
report with its reason.

## ABI

`NativeScript/runtime/SwiftInterop.h` is the binary contract between the
runtime and generated thunks (value slots, the API table, kinds and signature
codes). Thunks are stamped with `NS_SWIFT_ABI_VERSION`; the runtime refuses a
module generated for another version.
