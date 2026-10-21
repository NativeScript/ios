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

## In an app

An app names the Swift modules JavaScript uses in
`App_Resources/iOS/build.xcconfig`:

```
NS_SWIFT_MODULES = WeatherKit MyPackage $(PRODUCT_MODULE_NAME)
```

SDK modules, SwiftPM packages (`ios.SPMPackages`) and the app's own Swift
module (from `App_Resources/iOS/src`) all work. At link time, `internal/nsld.sh`
runs `build-step-swift-interop.py` for each architecture, next to the
Objective-C metadata step:

1. `swift-symbolgraph-extract` reads every listed module from the build
   products and the SDK.
2. The generator writes them as one unit (`NS_SWIFT_UNIT`, by default
   `<product module>Swift`), verified by the Swift compiler unless
   `NS_SWIFT_VERIFY = NO`. With `NS_TYPESCRIPT_DECLARATIONS_PATH` set, the
   declarations go to its `swift` folder.
3. `swiftc` compiles the thunks to an object, which is linked into the app
   with `-u` for every register symbol.

The step's logs and outputs are in `$(CONFIGURATION_BUILD_DIR)/NSSwiftInterop-<arch>`.
Generation and compilation take a while (WeatherKit: about 19 s per
architecture in a Release build), so the object is reused while the
extracted symbol graphs, the generator and the settings stay the same; an
unchanged build pays only for the extraction.

## Generation units

Modules generated together form a unit: `--swift-unit <Name>` with one
`--swift-symbolgraph-dir` per module writes one `<Name>+NativeScript.swift`
and one `swift!<Module>.d.ts` per module. Within a unit, a module's
declarations can take and return another module's types, and its extensions
of those types become their members (`Money.doubled()` declared in SwiftDemo
on SwiftDemoKit's `Money`). Every module keeps its own `ns:swift/<Module>`
namespace; a type has one JS class wherever it appears.

A module that is an implementation detail of another (SwiftUICore of
SwiftUI) cannot be imported, so its declarations join the module that
re-exports it: `--swift-reexport SwiftUICore=SwiftUI` (implied for that
pair). Generate everything an app uses as one unit: modules of different
units cannot share types.

## Generic types

A generic type is bridged through the concrete instantiations the unit's
declarations spell: WeatherKit's `lowTemperature: Measurement<UnitTemperature>`
makes `Measurement<UnitTemperature>` callable. To use an instantiation no API
spells, declare a public typealias in the app's Swift code:

```swift
public typealias LengthMeasurement = Measurement<UnitLength>
```

Every instantiation of a generic type shares one JS class, declared in
TypeScript as the generic class (`Measurement<UnitType>`): `new
Measurement(...)` picks the instantiation from its arguments, an instance
calls the members of its own instantiation, and `instanceof Measurement`
holds for all of them. A member that does not exist for an instantiation
(a constrained extension's) is left out of that instantiation.

## Generic functions

A generic function, method or initializer is instantiated once for each
concrete stand-in of its type parameters, and every instantiation is an
overload of its JS name:

| Use or constraint of `T` | Stand-ins |
|---|---|
| an argument of a unit generic type (`Box<T>`, `WeatherQuery<T>`) | the arguments of the unit's instantiations of that type |
| none | `Double`, `String`, `Bool` |
| standard library protocols (`Comparable`, `Numeric`, `StringProtocol`, ...) | those of `Double` (or `Int` for integer protocols), `String` and `Bool` that conform |
| one protocol of the unit (`G: Greeting`) | `any Greeting`, which Swift opens at the call: Swift values and JS objects implementing it |
| a superclass (`V: UIView`) | the superclass, which also takes its subclasses' instances |

`largest<T: Comparable>(_ values: [T]) -> T?` takes `largest([3, 9])` and
`largest(["b", "a"])`, and TypeScript declares both overloads. WeatherKit's
`weather(for:including:)` gets one overload per `WeatherQuery`
instantiation: `service.weather(location, WeatherQuery.daily)` returns a
`Forecast<DayWeather>`. A call picks
the instantiation its arguments convert to; an array decides by its first
element, so `largest([])` throws a `TypeError` naming the overloads' keys.
At most one number type stands in, since a JS number converts to every one.

A generic function is left out when a type parameter appears as a metatype
(`T.Type`) or through an associated type (`C.Element`), when it is
constrained by another module's protocol, when its arguments could not tell
several instantiations apart (a type parameter only in the result or in a
closure), or when it would need more than six instantiations (sixteen from a
generic type's instantiations). A `some P` parameter is an implicit type
parameter, instantiated the same way: `describe(_ value: some
CustomStringConvertible)` takes a number, a string or a boolean. Generic
methods of generic types are not instantiated yet.

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
| `Set<T>` | `Set` copy (inputs also accept an array) |
| `(A, B)` | array copy, `[a, b]` |
| `(x: A, y: B)` | plain object copy, `{ x: a, y: b }` |
| `any Error` | `Error` named `SwiftError` (with `swiftType`); inputs accept any value, an `Error`'s message describing it |
| `CGPoint`, `CGSize`, `CGRect`, `CGVector`, `CGAffineTransform`, `UIEdgeInsets`, `NSDirectionalEdgeInsets`, `UIOffset`, `NSRange`, `CLLocationCoordinate2D`, `MKCoordinateSpan`, `MKCoordinateRegion` | plain object copy of the fields, `{ x, y }` (inputs also accept NativeScript's struct values, `CGPointMake(1, 2)`) |
| `Result<S, F>` | `{ case: "success", value }` or `{ case: "failure", value }` (no `value` for `Result<Void, F>`) |
| `(A, B) -> Void` (parameters only) | `function (a, b)` |
| Objective-C class (`UIView`, an `NSObject` subclass) | NativeScript's ordinary Objective-C wrapper, with the identity Objective-C calls give it |

Collections are copied in both directions; their elements follow the same
table (an optional element is `null` when it is `nil`), and dictionary keys must be
`String`.

An enum with associated values keys each value by its label; a case's only,
unlabeled value is `value` (`{ case: "length", value: 2 }`), and other
unlabeled values are keyed by position (`{ case: "sum", 0: a, 1: b }`).
TypeScript declares the enum as a union of its cases, so `switch (m.case)`
narrows. An enum is bridged only when every case's values are; recursive
(`indirect`) enums are.

Thunks import the framework an Objective-C class most likely comes from
(`UIView` -> UIKit), guessed from its prefix since symbol graphs do not
record it; compiler verification drops declarations whose types still do not
resolve. TypeScript names these classes by their global `@nativescript/types`
name, and Swift classes without `@objc(Name)` as `NSObject`, except the
unit's own Objective-C-visible classes (below).

Structs have value semantics: reading a struct-typed property, passing a struct
argument, or returning one copies it, so a JS object never aliases another
copy. Mutating members and property setters change the copy the JS object
holds.

## Calling conventions

- Methods and functions take positional arguments. Overloads with the same
  JavaScript name are resolved by argument count and by which overloads accept
  the arguments' JS types; overloads taking arrays of different element types
  are told apart by the arrays' first elements.
- When more than one overload accepts the arguments (`scale(by: Double)` and
  `scale(by: Int)` both accept a number), the call throws a `TypeError` naming
  the overloads' keys; call one directly by key: `polygon["scale(by: Int)"](2)`.
  Every overload is also reachable by its Swift name when that is unique
  (`demo["greet(name:times:)"]("a", 2)`).
- Subscripts are methods: `shelf.subscript("apples")` reads one and
  `shelf.setSubscript("apples", 3)` assigns it (settable subscripts only),
  overloaded like any method by their indices.
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

A closure parameter takes a JS function; its arguments and its result follow
the value table. The Swift closure keeps the function alive for as long
as Swift holds the closure, and drops it when Swift releases the closure.

- Called on the JS thread, the closure runs the function before returning.
  That includes every call made while the Swift call is in progress
  (`countdown(3, (n) => ...)`). When the function throws during the call, the
  call throws that exception, and later invocations in the same call are
  skipped.
- Called from any other thread (a completion handler run by a background
  queue), the invocation is queued to the isolate's thread and Swift does not
  wait for it. A throw there is reported as an uncaught error.
- A closure that returns a value (`transform([1, 2], (n) => "#" + n)`) always
  waits for the function, on any thread: from another thread, the call is
  queued to the isolate's thread and the Swift thread blocks until it ran.
  When the function throws or returns a value that does not convert, the
  exception (a `TypeError` for the conversion) is thrown from the Swift call
  in progress, or reported as an uncaught error otherwise. A `throws` closure
  then throws into Swift; any other closure returns `nil`, `false`, `0`, an
  empty string or collection, and stops the process when its result type has
  none of these.
- `async` closures, `@autoclosure` parameters, closures with `inout`
  parameters, closures returning closures or sequences, and closures returned
  from Swift are not bridged yet.

## Objective-C-visible Swift classes

A Swift class that subclasses `NSObject` (a `UIView` or `UIViewController`
subclass, say) is an Objective-C class to NativeScript: JS creates and holds
it through NativeScript's own class, and its `@objc` members work as before.
Its Swift-only members, the ones Objective-C cannot see, install on that same
class when the module loads:

```swift
public final class CounterView: UIView {
    public private(set) var count = 0
    public func configure(start: Int, step: Int?) -> Int { ... }
}
```

```js
require("ns:swift/MyApp");
const view = CounterView.new();      // NativeScript's class
view.configure(1, null);             // Swift-only, through a thunk
Note.init("hello");                  // a Swift-only initializer
```

- Instance members go on the class's prototype; static members and
  Swift-only initializers (as `init`) on its constructor. They never replace
  a member NativeScript already gives the class.
- The class needs NativeScript metadata, which an app gets from its
  `-Swift.h` header; members of a class without metadata are not installed.
- Members of `UIResponder` subclasses (views, controllers) are isolated to the
  main thread, as UIKit declares them.
- TypeScript merges the members into the global declaration of the class.

## Protocols

A parameter typed by a protocol (`any Greeting`) accepts a Swift value that
conforms to it, or a JS object implementing it:

```js
SwiftDemo.introduce({
    name: "js",
    punctuation: "?",
    greet(other) { return "hey " + other; },
    reset() {},
}, "ada");
```

The object must provide every requirement (the call throws `TypeError`
naming the missing ones), including those of a protocol it refines; TypeScript
declares the protocol as an interface. Swift calls it through a generated
adapter: on the JS thread the member runs before the call returns, and from
any other thread the call waits while it runs on the JS thread, so a Swift
thread must not hold up the JS thread while waiting on such a call. When the
member throws, a throwing requirement throws a Swift error (and a call in
progress from JS rethrows the JS exception); any other requirement returns
its type's zero value (`0`, `""`, `nil`, an empty collection), or traps when
the type has none.

A protocol value returned to JS is the JS object it came from, a Swift
object of its own registered class, or else a boxed value of the protocol.

A JS object has one adapter per protocol, so Swift sees one identity for it
(`===`, `removeAll { $0 === listener }`). Its lifetime follows NativeScript's
rule for the JS side of Objective-C objects:

- While Swift holds the adapter strongly (`var delegate`), it keeps the JS
  object alive.
- A `weak` reference (`weak var delegate`) keeps it only as long as JS does:
  keep the delegate referenced from JS, as for Objective-C delegates. Once
  the JS object is collected, the weak reference becomes `nil`.
- Once neither side holds it, both are collected.

Protocols with associated types, `Self` requirements, static or `async`
requirements, initializers, or more than one refined module protocol stay
type-only.

## SwiftUI views

A bridged struct that conforms to SwiftUI's `View` gains
`hostingController()`, which returns a `UIHostingController` showing a copy
of the view, as an ordinary NativeScript `UIViewController` (main thread
only):

```ts
const controller = new Badge("Inbox", 3).hostingController();
```

To place it in a NativeScript layout, return `controller.view` from a
custom view's `createNativeView()` and add the controller as a child of the
page's view controller (`addChildViewController`, then
`didMoveToParentViewController`). The view is copied in: to change what it
shows, create a new controller, or drive it from an `@Observable` model the
view reads.

## Asynchronous sequences

A function or property returning `AsyncStream<T>`, `AsyncThrowingStream<T, E>`
or `some AsyncSequence<T, E>` returns a JS async iterator:

```js
for await (const value of SwiftDemo.countUp(3)) {
    console.log(value);
}
```

Each `next()` advances the Swift iterator in a `Task` and settles on the JS
thread; calls run one at a time, in order. A sequence that throws rejects
the pending `next()` with the Swift error. Leaving a `for await` loop early
(`break`, `return`, a throw) releases the Swift iterator, which ends a stream
Swift still produces (`onTermination` sees `.cancelled`).

A class or struct conforming to `AsyncSequence` stays a JS class with its
other members and is also async-iterable (`for await (const x of countdown)`).
A Combine `AnyPublisher`, `PassthroughSubject` or `CurrentValueSubject` is an
async iterator over its `values` (iOS 15+, `null` before): like `values`, it
asks for one element at a time, so a subject drops what it sends while JS is
not waiting; buffer in Swift (`.buffer(...)`) when that matters. Sequences as
parameters are not supported yet.

## Observation

`@Observable` classes (iOS 17+) can be watched from JS:

```js
const swift = require("ns:swift");
const stop = swift.observe(() => thermostat.celsius, () => {
    console.log("now", thermostat.celsius);
});
```

`swift.track(read, onChange)` is Swift's `withObservationTracking`: it runs
`read`, recording the observable properties it reads, and calls `onChange`
once, when one of them is about to change. `swift.observe` re-arms after
every change and calls `onChange` once a change made on the JS thread is
stored; it returns a function that stops observing. Changes made on other
threads are reported on the JS thread too, but Observation reports a change
before it is made, so `onChange` can run before the other thread stores the
new value; share such state through an actor or a lock, as Swift requires.
Both need a loaded Swift module (its thunks carry the tracking code).

## Async, actors and the main actor

- `async` functions return a Promise. The call reads its arguments
  synchronously, runs in a Swift `Task`, and settles the Promise on the
  calling isolate's thread (main or Worker); a `throw` rejects it with the
  Swift error. If the isolate is gone by then, the outcome is dropped.
- An `async` call takes an `AbortSignal` after its arguments:
  `await fetchItems(query, controller.signal)`. Aborting rejects the Promise
  at once with the signal's reason and cancels the Swift task, which stops
  where it checks for cancellation (`Task.sleep`, `try Task.checkCancellation()`,
  URLSession); whatever it reports afterwards is dropped. A signal already
  aborted rejects without calling Swift.
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

## Performance

`TestRunner/app/tests/SwiftInteropBenchmarks.js` times the same operations
through the Objective-C/C metadata path and through Swift thunks, and writes
the results to the app's `Documents/swift-bench.txt`. On a Debug runtime in
the iOS simulator (indicative only; measure Release builds on devices for real
numbers):

| Operation | Objective-C/C | Swift thunk |
|---|---|---|
| function `(Int) -> Int` | 1733 ns | 1500 ns |
| class method | 1722 ns | 1500 ns |
| instance method | 1786 ns | 1722 ns |
| string round trip | 1717 ns | 1752 ns |
| construct an object | 3018 ns | 1608 ns |
| read a property | 1014 ns | 864 ns |

Comparisons with other runtimes (OneJS) are not part of the suite.

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

Generic methods of generic types, other standard library generics,
protocols with associated types, and operators. Each appears in the coverage
report with its reason.

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
