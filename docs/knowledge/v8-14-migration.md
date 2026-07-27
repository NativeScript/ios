# V8 10.3 → 14.9 migration notes

Pinned version: **14.9.207.39** (`branch-heads/14.9`). The libraries are built by
[NativeScript/v8-buildscripts](https://github.com/NativeScript/v8-buildscripts)
and installed by `download_v8.sh`; the resurrecting-finalizer patch is described in
[v8-resurrecting-finalizers.md](v8-resurrecting-finalizers.md).

## Build configuration changes

- `enable_ios_bitcode` and `use_xcode_clang` no longer exist upstream — removed.
- `ios_deployment_target` must be a **string** (`"13.0"`, was a bare `13`).
- `v8_enable_temporal_support=false` is now required. Temporal is implemented in Rust, and
  enabling it emits Rust objects that reference a Rust sysroot (`__rust_alloc` and friends)
  which we do not link. V8 10.3 had no Temporal, so disabling keeps parity.
- arm64 **simulator** objects come out as `minos 14.0` regardless of the requested 13.0 —
  that is an Apple floor for arm64 simulator slices, not a project setting.

### New link-time dependencies

14.9 pulls in third-party code that 10.3 did not. `libv8_third_party.a` is archived from
everything under `out.gn/*/obj/third_party` **except** zlib and inspector_protocol (already
vendored as `libzip.a` / `libcrdtp*.a`), and linked via `-lv8_third_party`. It covers abseil,
simdutf and highway. Without it the link fails on `absl::hash_internal::*` and `simdutf::*`.

`ninja` now emits **thin** archives (references, not objects), so the vendored `.a` files must
be rebuilt from the `.o` files — a plain `cp` of `libinspector.a` silently produces a broken
library.

### Build from a clean `out.gn`

The packaging step globs `obj/<target>/*.o`, and ninja never deletes outputs that a config
change orphaned. Reusing an `out.gn` directory across V8 versions therefore archives stale
objects: a first attempt here silently vendored 42 objects dated **2022** (from the previous
10.3 build in the same directory) into `libv8_libbase.a`, `libv8_bigint.a` and `libcppgc_base.a`.
It surfaced as `ld: duplicate symbol 'v8::base::OS::SignalCodeMovingGC()'`, because the archive
held both the current `platform-darwin.o` and a stale `platform-macos.o`.

Delete the output directory before building a new version. The same hazard applies to the Rust
objects left behind by flipping `v8_enable_temporal_support` off, which is why the third_party
glob excludes `*/rust/*`.

## API changes applied to the runtime

| Change | Sites | Migration |
|---|---|---|
| `Context::GetIsolate()` removed | 113 | `v8::Isolate::GetCurrent()` |
| `External::New` / `External::Value()` take a type tag | 84 | `v8::kExternalPointerTypeTagDefault` |
| `Get/SetAlignedPointerInInternalField` take a tag | 13 | `v8::kEmbedderDataTypeTagDefault` |
| Interceptor callbacks return `v8::Intercepted` | 13 fns | see below |
| `PropertyCallbackInfo::This()` removed | 43 | `Holder()` |
| `ObjectTemplate/Object::SetAccessor` | 15 | `SetNativeDataProperty` |
| Accessor callbacks take `Local<Name>` | 44 | was `Local<String>` |
| `String::Value` deprecated | 2 | `String::ValueView` |
| `GetInternalField` returns `Local<Data>` | 6 | `.As<v8::Value>()` |
| `ScriptOrigin` no longer takes an `Isolate*` | 7 | drop the first argument |
| `GetCreationContext[Checked]()` need an isolate | 9 | pass `v8::Isolate::GetCurrent()` |
| `AccessControl` removed | 2 | drop the argument |
| `ArrayBuffer::Detach()` needs a key | 1 | `Detach(Local<Value>())` — null key is allowed |
| `V8Inspector::connect` needs a trust level | 3 | `kFullyTrusted` |
| dynamic-import callback reshaped | 1 | `ScriptOrModule referrer` → `host_defined_options` + `resource_name` |
| `V8ConsoleMessage::createForConsoleAPI` takes a span | 2 | `{args.data(), args.size()}` |

### Interceptors: the one non-mechanical change

Interceptor callbacks used to signal "I handled this" implicitly, by whether they set a return
value. They now return `v8::Intercepted` explicitly. The conversion rule applied throughout was:

- a path that called `GetReturnValue().Set*()` (or threw) → `return Intercepted::kYes`
- a path that returned without setting one, **including falling off the end** →
  `return Intercepted::kNo`

That reproduces the old semantics exactly, and the fall-off-the-end case is load-bearing rather
than an edge case: the swizzling definer depends on V8 still running the real `defineProperty`
to install the JS accessor, and the setter interceptors depend on V8 still performing the
ordinary store. Every getter here ends by setting a value (`kYes`); every setter and the definer
fall through (`kNo`).

Getting it backwards is silent in both directions: `kNo` where the old code intercepted lets V8
continue the lookup up the prototype chain, and `kYes` where it did not suppresses the default
operation entirely.

Note the setter typedefs are inconsistent upstream — for **named** properties the current form is
`NamedPropertySetterCallbackV2` (`PropertyCallbackInfo<Boolean>`), but for **indexed** properties
it is the non-V2 `IndexedPropertySetterCallback` that takes `<Boolean>`, while the V2 spelling is
the deprecated one taking `<void>`. Both current forms use `<Boolean>`.

### V8 flags: set them before `V8::Initialize()`, and drop `--jitless`

Two separate aborts, both inside `SetFlagsFromString` in `Runtime::CreateIsolate()`, before a
line of JS ran:

1. **Flags are frozen after initialization.** `V8::Initialize()` calls `FlagList::FreezeFlags()`
   (`freeze_flags_after_init` defaults on), and changing a flag afterwards is fatal. The runtime
   set its flags *after* `V8::Initialize()`; that call now happens first.
2. **`--jitless` is read-only in lite-mode builds.** 14.9 declares it as
   `DEFINE_BOOL_READONLY(jitless, true)` under `V8_JITLESS`, and setting a read-only flag is
   also fatal. It is now omitted — lite mode already implies it, so behaviour is unchanged.

Worth remembering that both failures look identical from the stack (`SetFlagsFromString` →
`V8_Fatal` → `Abort`); the distinguishing detail is only in V8's message.

### An empty `Local<Context>` is now a null dereference

V8 commit `026ce4d1` (*"[api] Disallow empty context in CallDepthScope"*, Dec 2023 — after 10.3,
before 14.9) removed the `if (!context.IsEmpty())` guard. `CallDepthScope` now runs
`*Utils::OpenDirectHandle(*context)` unconditionally, so passing an empty context segfaults at
address 0 instead of quietly skipping the context switch.

This turns "call a context-needing V8 API without an entered context" from silently working into
a crash. The exposure is anything reaching `isolate->GetCurrentContext()` — `tns::ToString`,
`ToNSString`, `ToUtf16String` and raw `String::Utf8Value` all do, via V8's own
`Utf8Value`/`ToString` internals. APIs taking an explicit `Local<Context>` are unaffected.

It is invisible on strings: `Value::ToString` returns early when the value already is one, so a
site only crashes once it converts a non-string. `JsV8InspectorClient::dispatchMessage` had
`Locker` + `Isolate::Scope` + `HandleScope` but no `Context::Scope`, and survived until a JS
domain handler returned `true` and the ack path converted the *numeric* request id.

Entering the context at the thread entry point is the fix; the scope has to cover every
conversion, not just the ones that call into JS.

### `Local` is now trivially destructible

Unused `Local<T>` locals now trip `-Wunused-variable`, which with `-Werror` is fatal. Five dead
declarations were removed; they were genuinely unused, not merely unread.

## The shipped headers now require C++20

`v8config.h` went from `#if __cplusplus < 201703L` (C++17 is enough) to `#if __cplusplus <= 201703L`
(C++17 is rejected). Any plugin whose sources include `v8.h` must therefore compile at c++20 or
later, and several pin exactly `CLANG_CXX_LANGUAGE_STANDARD = c++17` in their
`platforms/ios/build.xcconfig` — which sat precisely on the old floor.

The app can't override this from `App_Resources/iOS/build.xcconfig`: the CLI merges every plugin's
xcconfig *and* the app's into `plugins-{debug,release}.xcconfig`, one value per key, and the app's
value does not reliably win. That merged file is then the **last** `#include` in
`build-{debug,release}.xcconfig`, so it also beats the project-level setting in the pbxproj.

Plugins are expected to declare c++20 themselves. Worth knowing that a single stale transitive
plugin is enough to hold an entire app below the floor, and that the resulting error points at our
headers rather than at the plugin that pinned the standard. An app that needs to force the floor
regardless can assign `CLANG_CXX_LANGUAGE_STANDARD` *after* the `plugins-*.xcconfig` include in
`build-{debug,release}.xcconfig`, which is the only layer that beats the merge.

## Vendored inspector sources

`NativeScript/inspector/src` is a copy of V8's inspector/base/debug headers, previously pinned to
10.3. Because `libinspector.a` is now built from 14.9, keeping 10.3 headers would be an ABI
mismatch, so the tree was re-vendored: 107 files from `v8/src`, 9 generated protocol headers from
`out.gn/*/gen/src/inspector/protocol`, plus 7 newly-required headers.

14.9's `src/common/globals.h` reaches abseil via `base/numbers/double.h` → `diy-fp.h` →
`absl/numeric/int128.h`, so 11 abseil headers are vendored under `NativeScript/inspector/absl`
(that directory is already on the header search path, so no project change was needed).

Ten 10.3-era files no longer exist upstream and were left in place; nothing includes them now:
`base/{cpu,functional,optional,safe_conversions*,v8-fallthrough}.h`,
`common/allow-deprecated.h`, `debug/debug-type-profile.h`, `inspector/v8-webdriver-serializer.h`.

## Test status

`./run_tests.sh` on an iOS 18.5 simulator: **904 specs, 892 passing, 1 failing, 11 skipped.**
All worker and teardown specs pass.

The one failure, `TNS require :: should throw error if cant find node module`, is **not a
migration regression**. `IsLikelyOptionalModule()` treats any bare specifier without a path
separator as optional, so `require('nonExistingFileName.js')` yields a lazily-throwing
placeholder rather than throwing, and the test never touches the result. That logic is
version-independent and predates this work (it arrived with ESM support in `e72977ab`), so it is
left alone here rather than changed as a side effect of the V8 upgrade.

### Accessors that are inherited need a real accessor pair

Three separate failures had one root cause: **property callbacks can no longer see the
receiver**, and `SetNativeDataProperty` is not a drop-in replacement for `SetAccessor` on an
object that is inherited from.

- `ClassBuilder`'s `super` (on the implementation object, which instances inherit) and
  `Reference.value` (on a `PrototypeTemplate`) both need the receiver, and `Holder()` gives the
  prototype instead. Both are now function-backed accessors, whose `FunctionCallbackInfo::This()`
  still returns the receiver.
- Static properties on constructor functions behaved worse: `SetNativeDataProperty` installs
  something data-like, so `Derived.baseProperty = x` shadowed the base's property with an own
  data property and never reached the native setter. Now installed with `SetAccessorProperty`.

The rule of thumb: if an accessor lives on anything that is inherited from — a prototype
template, a base constructor, an implementation object — use `SetAccessorProperty` with
function-backed getter/setter. `SetNativeDataProperty` is only safe on instance templates,
where `Holder() == This()` and nothing inherits it.

## Outstanding

Nothing blocking. Two follow-ups:

- Only `arm64-iphonesimulator` has been rebuilt; the other six architectures in
  `NativeScript/lib` still hold 10.3 libraries.
- `DisposerPHV.{h,mm}` is now dead code -- `Isolate::VisitHandlesWithClassIds` no longer exists,
  so the visitor can never be driven. Its logic moved to `ObjectManager::DisposeAllRegistered()`.

### Behavioural parity traps in the accessor rewrite

Two places where the new APIs quietly change semantics unless the old values are carried over
deliberately. Neither is covered by a test, so both would have shipped silently:

- **Accessor attributes.** `Object::SetAccessor` defaulted to `PropertyAttribute::None`;
  `SetAccessorProperty` takes the attributes explicitly. Passing `DontEnum` for `super` (an easy
  assumption, since it looks internal) removes it from `Object.keys()` and `for...in` on the
  implementation object. The defaults are preserved instead.
- **`ArrayBuffer::Detach`.** The deprecated `Detach()` returned void and could not report
  failure. The replacement returns `Maybe<bool>` and is `V8_WARN_UNUSED_RESULT`, so it invites a
  `.Check()` — which **aborts the process** when the buffer has an `[[ArrayBufferDetachKey]]`
  that does not match. This is on the worker `postMessage` transfer path, so the result is
  discarded rather than checked.

### An intermittent worker/notification deadlock

Two runs during this work hung for ~10 minutes instead of finishing. Sampling the stuck process
showed a lock-order inversion that does not involve any of the above:

- the main thread, inside a posted notification (`___CFXRegistrationPost` →
  `ArgConverter::MethodCallback`), blocked acquiring a worker isolate's `v8::Locker`;
- worker threads, running JS that dispatched an ObjC method, blocked in
  `initializeNonMetaClass` on the ObjC runtime's class-initialization lock.

It has not reproduced in the three runs since, so it is timing-dependent. It is recorded here
because the symptom (suite hangs with no crash report, last log line a spec well before the
worker tests) is otherwise very hard to place.

### Teardown disposal

`Isolate::VisitHandlesWithClassIds` was removed upstream, so wrappers can no longer be found by
walking V8's handles. `Caches` now keeps a `weak_ptr` registry of every handle
`ObjectManager::Register()` hands out -- weak, so tracking never keeps a wrapper alive, and
compacted whenever it would grow so collected entries do not accumulate.
`ObjectManager::DisposeAllRegistered()` walks that registry at teardown, then disposes the
`Caches` collections that used to carry the `DataWrapper` class id (`CtorFuncs`,
`ProtocolCtorFuncs`, `CFunctions`, `PrimitiveInteropTypes` and the three interop ctor handles).
`~Caches()` cleared those maps but never disposed their wrappers, so they leaked too.

It has to enter the isolate itself: `~Runtime` holds a `Locker` but never enters, and creating
handles without that segfaults in `HandleScope::CreateHandle`. The same applies to
`Worker::SetWorkerId`, which runs after `Runtime::Init()` has unwound its own `Isolate::Scope`.
