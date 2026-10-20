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
| enum with associated values | a plain object copy naming its case: `{ case: "area", width: 3, height: 4 }` |
| `Date` | `Date` |
| `URL` | `URL` (inputs also accept a string) |
| `Data` | `Uint8Array` copy (inputs accept any `ArrayBuffer` or view) |
| `[T]` | array copy |
| `[String: T]` | plain object copy |
| `(A, B) -> Void` (parameters only) | `function (a, b)` |

Collections are copied in both directions; their elements follow the same
table (optional elements are not supported yet), and dictionary keys must be
`String`.

An enum with associated values keys each value by its label; a case's only,
unlabeled value is `value` (`{ case: "length", value: 2 }`), and other
unlabeled values are keyed by position (`{ case: "sum", 0: a, 1: b }`).
TypeScript declares the enum as a union of its cases, so `switch (m.case)`
narrows. An enum is bridged only when every case's values are; recursive
(`indirect`) enums are.

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
- Enum initializers are `Enum.init(...)`, returning a case or `null`. Enum
  instance members are functions taking the case first:
  `Flavor.description("vanilla")`, `Measurement.isNone({ case: "none" })`.
- An `inout` parameter takes a reference object: `bump(ref)` with
  `ref = { value: 41 }` leaves `ref.value === 42`. The value is read before
  the call and replaced after it succeeds; a throw leaves it unchanged. A
  struct comes back as a new copy, so the object passed in is not mutated.
  `async` functions with `inout` parameters are not exposed.
- Properties are accessors; read-only Swift properties have no setter.
- Nested types hang off their parent: `Polygon.Style.dashed`,
  `new Polygon.Metrics({ perimeter: 3 })`. When the parent itself is not
  bridged, a frozen namespace object stands in for it.

## Closures

A closure parameter that returns `Void` takes a JS function; its arguments
follow the value table. The Swift closure keeps the function alive for as long
as Swift holds the closure, and drops it when Swift releases the closure.

- Called on the JS thread, the closure runs the function before returning.
  That includes every call made while the Swift call is in progress
  (`countdown(3, (n) => ...)`). When the function throws during the call, the
  call throws that exception, and later invocations in the same call are
  skipped.
- Called from any other thread (a completion handler run by a background
  queue), the invocation is queued to the isolate's thread and Swift does not
  wait for it. A throw there is reported as an uncaught error.
- Closures that return a value, throw, or are `async`, `@autoclosure`
  parameters, closures with `inout` parameters, and closures returned from
  Swift are not bridged yet.

## Async, actors and the main actor

- `async` functions return a Promise. The call reads its arguments
  synchronously, runs in a Swift `Task`, and settles the Promise on the
  calling isolate's thread (main or Worker); a `throw` rejects it with the
  Swift error. If the isolate is gone by then, the outcome is dropped.
- Members of an `actor` are awaited from outside it, exactly as in Swift:
  `await counter.increment()`, `await counter.value`. Actor properties are
  never assignable from JavaScript. `nonisolated` members stay synchronous.
- `@MainActor` members run synchronously on the main thread. Called from a
  Worker, they throw instead of trapping; their `async` members hop to the main
  actor on their own and work from any isolate.
- `async` initializers are not exposed: `new` cannot await.

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
`--swift-verify` type-checks a probe for every generated declaration, and the
generated thunks themselves, with the Swift compiler, demotes whatever it
rejects as `compiler-rejected:<message>`, and repeats until everything that
remains compiles. Symbol graphs cannot
express every fact a call depends on (`~Copyable` is often invisible), so
verification is what makes the generated surface trustworthy at SDK scale.

## Not yet supported

Closures that return values, async cancellation, generics
(including `Result`), protocols as values, tuples, sets, optional collection
elements, subscripts and operators. Each appears in the coverage report with
its reason.

## Swift language mode

The thunks compile in Swift 5 and Swift 6 language modes. In Swift 6 mode,
code outside a module may not touch that module's nonisolated mutable globals
(`public var counter = 0`); run `--swift-verify` with the same mode
(`--swift-compiler "xcrun swiftc -swift-version 6"`) and those declarations
are demoted as `compiler-rejected`.

## ABI

`NativeScript/runtime/SwiftInterop.h` is the binary contract between the
runtime and generated thunks (value slots, the API table, kinds and signature
codes, and the async completion and callback entries). Thunks are stamped with
`NS_SWIFT_ABI_VERSION`; the runtime refuses a module generated for another
version.
