7.1.1
===

- Reverted: Updated V8 to 8.9 (https://github.com/NativeScript/ns-v8ios-runtime/pull/84)

This release should restore debugging in chrome-devtools.

7.1.0
===

### Features
- Updated V8 to 8.9 (https://github.com/NativeScript/ns-v8ios-runtime/pull/84)

### Bug Fixes
- XCode 12.3 support (https://github.com/NativeScript/ns-v8ios-runtime/pull/92)
- DictionaryAdapter missing handle scopes and locks (https://github.com/NativeScript/ns-v8ios-runtime/pull/90)
- PromiseProxy returns function regardless of underlying property type (https://github.com/NativeScript/ns-v8ios-runtime/pull/90)

7.0.6
===

### Bug Fixes
- Do not prematurely release blocks (https://github.com/NativeScript/ns-v8ios-runtime/pull/83)


7.0.5
===

### Bug Fixes
- Reverted pull 74, this fixes crash on swipe exit.
- Fixes Crashing in Workers (https://github.com/NativeScript/ns-v8ios-runtime/pull/78)


7.0.4
===

### Features
- Faster JS loading (https://github.com/NativeScript/ns-v8ios-runtime/pull/73)
- Support unmanaged types (https://github.com/NativeScript/ns-v8ios-runtime/pull/72)

### Bug Fixes
- Fix random crash on exit (https://github.com/NativeScript/ns-v8ios-runtime/pull/74)


7.0.3
===

### Bug Fixes

- Native Object Prototype corruption(https://github.com/NativeScript/ns-v8ios-runtime/pull/70)
- Ensure Isolate is alive before accessing (https://github.com/NativeScript/ns-v8ios-runtime/pull/69)
- Fix issues with Debug line number dangling pointer (https://github.com/NativeScript/ns-v8ios-runtime/pull/66)


7.0.2(-rc)
===

### Issue

- Fix Build so it no longer is compiled with XCode Beta (https://github.com/NativeScript/ns-v8ios-runtime/pull/66)


7.0.1
===

### Features

- TypedArray to NSArray auto-conversion  (https://github.com/NativeScript/ns-v8ios-runtime/pull/59)
 

### Bug Fixes
- Support for XCode 12 (https://github.com/NativeScript/ns-v8ios-runtime/pull/66)


7.0.0-beta.3-v8 (2020-03-09)
====

### Features

- Multithreaded javascript (https://github.com/NativeScript/ns-v8ios-runtime/pull/28)
- Disable ARC (https://github.com/NativeScript/ns-v8ios-runtime/pull/30)
- Instance members swizzling (https://github.com/NativeScript/ns-v8ios-runtime/issues/31)

### Bug Fixes

- Do not prematurely dispose blocks (https://github.com/NativeScript/ns-v8ios-runtime/issues/26)
- Skip undefined properties in console.dir (https://github.com/NativeScript/ns-v8ios-runtime/issues/27)
- Runtime check for selectors support (https://github.com/NativeScript/ns-v8ios-runtime/issues/33)
- Types declarations conforming to protocols (https://github.com/NativeScript/ns-v8ios-runtime/issues/36)

6.5.0-beta.2-v8 (2020-01-28)
====

### Features

- Various performance improvements in FFI method calls (https://github.com/NativeScript/ns-v8ios-runtime/issues/24)

### Bug Fixes

- Function names must be shown in js stacktraces in debug mode (https://github.com/NativeScript/ns-v8ios-runtime/issues/12)
- Support for array buffer input parameters (https://github.com/NativeScript/ns-v8ios-runtime/issues/20)
- Do not create js wrappers for `__NSMallocBlock__` instances (https://github.com/NativeScript/ns-v8ios-runtime/issues/21)
- Dynamically load modules for unresolved classes from metadata (https://github.com/NativeScript/ns-v8ios-runtime/issues/22)
- Optional method returning a structure should use objc_msgSend_stret (https://github.com/NativeScript/ns-v8ios-runtime/issues/23)

6.4.0-beta.1-v8 (2020-01-14)
====

### Features

- SIMD support
- `NSError**` output parameters support
- Global js error handler

### Bug Fixes

6.2.0-alpha.2-v8 (2019-09-18)
=====

### Features

- [Script code caching](https://v8.dev/blog/improved-code-caching)
- iOS Deployment Target = 9.0
- Log statements are sent to `stderr` using the `NSLog` function
- Wrap native method calls into try/catch statements and throw javascript exception for every caught NSException

### Bug Fixes

 - The `global.performance` object is no longer declared as readonly [#2](https://github.com/NativeScript/ns-v8ios-runtime/issues/2)

6.2.0-alpha.1-v8 (2019-09-18)
=====

Initial public release
