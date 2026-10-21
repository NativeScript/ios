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

## Quick start in an app

1. Write Swift in `App_Resources/iOS/src` (or add a SwiftPM package through
   `ios.SPMPackages` in `nativescript.config.ts`):

   ```swift
   public struct Forecast {
       public let city: String
       public let highs: [Double]
   }

   public final class WeatherClient {
       public init() {}
       public func forecast(for city: String) async throws -> Forecast {
           Forecast(city: city, highs: [21, 23.5, 19])
       }
   }
   ```

2. List the module in `App_Resources/iOS/build.xcconfig` (the app's own module
   is `$(PRODUCT_MODULE_NAME)`; add SDK modules and packages by name), and
   optionally where TypeScript declarations go:

   ```
   NS_SWIFT_MODULES = $(PRODUCT_MODULE_NAME)
   NS_TYPESCRIPT_DECLARATIONS_PATH = $(SRCROOT)/typescript-declarations
   ```

3. Call it from JavaScript or TypeScript (the app module's name is the app's
   product module, `nstsrs` for an app called nstsrs):

   ```ts
   import { WeatherClient } from "ns:swift/nstsrs";

   const forecast = await new WeatherClient().forecast("Lisbon");
   forecast.highs; // [21, 23.5, 19]
   ```

`ns build ios` generates, verifies, compiles and links the thunks; there is
nothing else to configure.

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

Collection protocols take JS arrays: a type parameter constrained to
`Sequence`, `Collection` or another protocol arrays conform to stands in as
`[X]` for `where C.Element == X`, or as arrays of the element's own stand-ins
(`C.Element` follows), and `some Sequence<Int>` as `[Int]`. A parameter typed
`any Sequence<E>` (or another such protocol) takes an array, and a result of
that type is copied out as one.

A generic function is left out when a type parameter appears as a metatype
(`T.Type`) or through an associated type other than a collection's `Element`, when it is
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
| `Any`, `[Any]`, `[String: Any]` | the JS value: `null` (`NSNull`), booleans, numbers (integral ones as `Int`), strings, arrays, plain objects; Swift values of the module's types and Objective-C objects as themselves. Back from Swift by the value's type (`Date` as milliseconds, `URL` and `UUID` as strings); TypeScript sees `unknown` |
| `UUID`, `Character` | string (an invalid UUID or a string of other than one character throws `TypeError`) |
| `Decimal` | number |
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
- Operators are methods named for what they do: `a.plus(b)`, `a.minus(b)`,
  `times`, `dividedBy`, `remainder`, `equals`, `lessThan`,
  `lessThanOrEqualTo`, `greaterThan`, `greaterThanOrEqualTo`, and prefix
  `negated()` / `not()`. One whose left operand is its own type is an instance
  method of that operand; any other is static (`Vector2.times(2, v)`).
  Compound assignment, bitwise and custom operators are not exposed.
- `Equatable` classes and structs (also through `Hashable` or `Comparable`)
  get `equals(other)`, and `Comparable` ones `compare(other)` (-1, 0 or 1),
  so `list.sort((a, b) => a.compare(b))` sorts by Swift's `<`.
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

`TestRunner/app/tests/SwiftInteropBenchmarks.js` calls one API implemented
twice: in Objective-C (`TestFixtures/Marshalling/TNSBenchmark`, reached
through NativeScript's metadata, the path apps have used for years) and in
Swift (`SwiftDemo`'s `Benchmark.swift`, reached through `ns:swift`). The two
implementations do the same work, and every case consumes its result in JS
as an app would, so NativeScript's lazily wrapped `NSArray`s pay for the
elements read and nothing is compared against a no-op. Each figure is the
median of three timed rounds after a warm-up, per call; the suite writes its
results to the app's `Documents/swift-bench.txt`.

Release build of TestRunner, iPhone 17 Pro simulator (iOS 26), Apple M3 Max,
Xcode 27.1 (lower is better):

| Workload | Objective-C | Swift (ns:swift) | Swift / Objective-C |
|---|---|---|---|
| call: no arguments | 0.16 µs | 0.09 µs | 0.58x |
| call: int -> int | 0.18 µs | 0.14 µs | 0.74x |
| call: 3 doubles -> double | 0.22 µs | 0.20 µs | 0.91x |
| call: bool -> bool | 0.17 µs | 0.13 µs | 0.75x |
| string: short round trip | 0.31 µs | 0.21 µs | 0.70x |
| string: 10 KB in | 1.68 µs | 0.97 µs | 0.58x |
| string: 10 KB round trip | 2.70 µs | 1.67 µs | 0.62x |
| object: construct | 0.70 µs | 0.29 µs | 0.42x |
| object: instance method | 0.10 µs | 0.12 µs | 1.14x |
| object: property read | 0.09 µs | 0.09 µs | 0.91x |
| object: property write | 0.11 µs | 0.11 µs | 0.98x |
| array: 1000 ints in | 70.55 µs | 22.68 µs | 0.32x |
| array: 1000 ints out, all read | 155.22 µs | 48.47 µs | 0.31x |
| dictionary: 10 keys in | 4.64 µs | 1.71 µs | 0.37x |
| dictionary: 10 keys out, all read | 5.82 µs | 2.31 µs | 0.40x |
| data: 1 MB in | 4248.88 µs | 416.88 µs | 0.10x |
| data: 1 MB out as bytes | 389.34 µs | 261.52 µs | 0.67x |
| struct: CGPoint in and out | 0.94 µs | 0.92 µs | 0.98x |
| callback: native calls JS 100 times | 10.78 µs | 21.25 µs | 1.97x |
| delegate: native calls JS object 100 times | 10.65 µs | 27.55 µs | 2.59x |
| error: thrown and caught | 16.34 µs | 13.66 µs | 0.84x |
| batch: build, filter, sort 1000 records, all read | 966.46 µs | 260.39 µs | 0.27x |
| async: call and await, sequential | 125.27 µs | 11.56 µs | 0.09x |

- Swift is faster for almost every call shape: scalar calls run in 0.6 to 0.9
  of the time, object construction in 0.4, and thrown errors in 0.85.
- Collections are where the difference is largest: arrays and dictionaries
  cross in about a third of the time, since a thunk converts them in one pass
  instead of through per-element Objective-C wrappers. The record batch,
  which builds, filters and sorts 1000 structs natively and reads every field
  in JS, runs in 0.27 of the time.
- Binary data crosses fast: a 1 MB `Data` argument takes a tenth of the time
  (one copy from the typed array, against NativeScript's per-call
  conversion), and a 1 MB result two thirds.
- Async calls settle 6 to 10x faster (the Objective-C figure varies from run
  to run with main-queue scheduling): a Swift `async` call resolves its
  Promise directly, while the Objective-C version goes through a completion
  block dispatched to the main queue.
- Native code calling JS is slower: a Swift closure or delegate calling a JS
  function costs about 0.2 µs per call against about 0.1 µs for an
  Objective-C block or a JS subclass, because each invocation reports its
  arguments as a stream the runtime assembles before calling into JS.
- A Debug build (unoptimized thunks) is slower on both paths; there Swift's
  scalar calls are about 1.2x Objective-C's while the collection, batch and
  async cases keep most of their lead.

## Recipes

- **A SwiftUI view in a NativeScript layout.** `hostingController()` on any
  bridged `View` struct returns a `UIHostingController`; add its `view` to a
  NativeScript container (for example a `ContentView`'s `nativeView`, or a
  custom `View` subclass whose `createNativeView()` returns it):

  ```ts
  const controller = new Badge("Inbox", 3).hostingController();
  const native = controller.view; // a UIView, sized by SwiftUI
  ```

- **A delegate implemented in JavaScript.** Declare a class-bound protocol in
  Swift and pass a plain JS object; keep it referenced from JS when Swift
  holds it `weak`:

  ```swift
  public protocol UploadDelegate: AnyObject { func progress(_ fraction: Double) }
  public final class Uploader { public weak var delegate: (any UploadDelegate)? ... }
  ```
  ```ts
  this.delegate = { progress: (f: number) => (this.percent = f * 100) };
  uploader.delegate = this.delegate;
  ```

- **A cancellable request.** An `async` Swift function takes an `AbortSignal`
  after its arguments; aborting cancels the Swift task:

  ```ts
  const controller = new AbortController();
  const items = client.search("swift", controller.signal);
  controller.abort(); // items rejects; Swift's Task.sleep / URLSession throw CancellationError
  ```

- **Streams.** Return `AsyncStream<T>`, a type conforming to `AsyncSequence`,
  or a Combine `AnyPublisher<T, E>`, and iterate it with `for await`;
  `break` ends the Swift stream.

- **JSON-like payloads.** `[String: Any]` takes and returns plain JS objects;
  give Swift a typed struct where the shape is known, and TypeScript types it
  precisely.

- **Swift-only API on a UIKit subclass.** A `UIView` or `UIViewController`
  subclass keeps its NativeScript class (`MyView.new()`), and its Swift-only
  methods are added to it once `ns:swift/<Module>` is loaded.

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
protocols with associated types as values or JS implementations (beyond the
collection protocols above), and Swift overlay members of SDK Objective-C
classes. Each appears in the coverage report with its reason.

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
