# [8.4.0](https://github.com/NativeScript/ns-v8ios-runtime/compare/v8.3.3...v8.4.0) (2022-11-30)


### Bug Fixes

* **string:** initWithBytes instead of UTF8 string ([b72dcf6](https://github.com/NativeScript/ns-v8ios-runtime/commit/b72dcf626333a1dcdf21d092b5422b78953a7817))
* support null characters on NSString marshalling ([705346f](https://github.com/NativeScript/ns-v8ios-runtime/commit/705346fb0a8c770cc2f59bf73d10342a8e2cacbb))


### Features

* drop perIsolateCaches_ in favor of v8 data slots ([44daeb3](https://github.com/NativeScript/ns-v8ios-runtime/commit/44daeb3c21ea0d7f678197a2c2444f972585e6cf))
* inline frequently used methods, add caches, thread safety, and use static allocation when possible ([44e60d0](https://github.com/NativeScript/ns-v8ios-runtime/commit/44e60d00b86d5fe61f716b099a58d0fea36e2018))
* use spinlocks for selector maps ([c5a8863](https://github.com/NativeScript/ns-v8ios-runtime/commit/c5a886332b13ab6dae798880b82b256a0339351c))


### Performance Improvements

* use fast primitive setters ([#181](https://github.com/NativeScript/ns-v8ios-runtime/issues/181)) ([47c63b0](https://github.com/NativeScript/ns-v8ios-runtime/commit/47c63b03360dde6e8040b1890f7e49055466d695))



## [8.3.3](https://github.com/NativeScript/ns-v8ios-runtime/compare/v8.3.2...v8.3.3) (2022-08-13)


### Bug Fixes

* **ios16-beta5:** errors and crash ([#179](https://github.com/NativeScript/ns-v8ios-runtime/issues/179)) ([e36106c](https://github.com/NativeScript/ns-v8ios-runtime/commit/e36106c2ce4ad9bf232b89682699aaea19718f35))
* **metadata-generator:** skip empty bitfields ([#178](https://github.com/NativeScript/ns-v8ios-runtime/issues/178)) ([3720b2b](https://github.com/NativeScript/ns-v8ios-runtime/commit/3720b2b3c219fa17151f85ffe0ba227cdce0d692))



## [8.3.2](https://github.com/NativeScript/ns-v8ios-runtime/compare/v8.3.1...v8.3.2) (2022-07-23)


### Bug Fixes

* console prefix missing ([#175](https://github.com/NativeScript/ns-v8ios-runtime/issues/175)) ([3f4abd1](https://github.com/NativeScript/ns-v8ios-runtime/commit/3f4abd1e8187d783b10377f9380f46c43135f824))



## [8.3.1](https://github.com/NativeScript/ns-v8ios-runtime/compare/v8.3.0...v8.3.1) (2022-07-22)


### Bug Fixes

* memory leak on ArgConverter::ConstructObject ([1129d15](https://github.com/NativeScript/ns-v8ios-runtime/commit/1129d15fb47d1ae78bf42826ec118c9e76cdd4f7))
* memory leak on ArrayAdapter, DictionaryAdapter and NSDataAdapter ([#170](https://github.com/NativeScript/ns-v8ios-runtime/issues/170)) ([1e1abe2](https://github.com/NativeScript/ns-v8ios-runtime/commit/1e1abe24e78c35f59e85a4cf06c57d832be0c9dc))
* misspelling on MetaType ([f6e0500](https://github.com/NativeScript/ns-v8ios-runtime/commit/f6e05002f4ca9f6e9007b77278f55a3940a8640c))
* xcode14 build phase files ([#169](https://github.com/NativeScript/ns-v8ios-runtime/issues/169)) ([3b1eafc](https://github.com/NativeScript/ns-v8ios-runtime/commit/3b1eafc4da502404ab8c50854016ff059ae8eff8))


### Features

* add debug runtime detail log handling ([cfe59d4](https://github.com/NativeScript/ns-v8ios-runtime/commit/cfe59d4024bdadde6aa39aaad814883853f89403))
* add support for reasons on assertion failure ([#172](https://github.com/NativeScript/ns-v8ios-runtime/issues/172)) ([e185014](https://github.com/NativeScript/ns-v8ios-runtime/commit/e185014b6a6bec47b49d75486c73dc8ed748c998))
* improve crash report details ([#142](https://github.com/NativeScript/ns-v8ios-runtime/issues/142)) ([f0a49c0](https://github.com/NativeScript/ns-v8ios-runtime/commit/f0a49c043d5d298cf13e79f108cac4f18e95cd27))


### Performance Improvements

* cache swizzled selector construction ([#173](https://github.com/NativeScript/ns-v8ios-runtime/issues/173)) ([de6506b](https://github.com/NativeScript/ns-v8ios-runtime/commit/de6506b8fa9b7fc6e1c5cabd7874ebd6a9f0574c))



## [8.2.3](https://github.com/NativeScript/ns-v8ios-runtime/compare/v8.2.2...v8.2.3) (2022-03-30)


### Bug Fixes

* use serial queues and revert string copy changes ([#156](https://github.com/NativeScript/ns-v8ios-runtime/issues/156)) ([e8681ff](https://github.com/NativeScript/ns-v8ios-runtime/commit/e8681ff46ca240e819b1eaffc2c6c5b2d7cac866))



## [8.2.2](https://github.com/NativeScript/ns-v8ios-runtime/compare/v8.2.1...v8.2.2) (2022-03-22)


### Bug Fixes

* **inspector:** ensure socket message is copied and stored ([#155](https://github.com/NativeScript/ns-v8ios-runtime/issues/155)) ([3098976](https://github.com/NativeScript/ns-v8ios-runtime/commit/3098976b328f45cc2ebd4b918fcd4d069ea575a9))
* only delay promise resolution when needed ([#154](https://github.com/NativeScript/ns-v8ios-runtime/issues/154)) ([f46c425](https://github.com/NativeScript/ns-v8ios-runtime/commit/f46c4256b6e5b3b4340d6570d0876c25990e9d79))



# [8.2.0](https://github.com/NativeScript/ns-v8ios-runtime/compare/v8.1.0...v8.2.0) (2022-03-07)


### Bug Fixes

* don't leak code cache data ([#146](https://github.com/NativeScript/ns-v8ios-runtime/issues/146)) ([c580098](https://github.com/NativeScript/ns-v8ios-runtime/commit/c5800985c26a39f209bffa0b30a41f748fa76594))
* lock isolate before handle_scope ([#149](https://github.com/NativeScript/ns-v8ios-runtime/issues/149)) ([3c23fd8](https://github.com/NativeScript/ns-v8ios-runtime/commit/3c23fd872b9ea0e4bd3e61864a2df98a3e77a9bc))
* only warn once about WeakRef.clear() deprecation. ([#140](https://github.com/NativeScript/ns-v8ios-runtime/issues/140)) ([fc0f18c](https://github.com/NativeScript/ns-v8ios-runtime/commit/fc0f18c80902315c0cce5766ae77b42df0ce2ecd))
* prevent crashes during onuncaughterror ([#141](https://github.com/NativeScript/ns-v8ios-runtime/issues/141)) ([65be29b](https://github.com/NativeScript/ns-v8ios-runtime/commit/65be29b187fc1f8d59ed943df1d65ab98e4d0413))
* retain instance on init ([2d6f455](https://github.com/NativeScript/ns-v8ios-runtime/commit/2d6f4559847058170a33cbfd909c8e6f5093654e))
* runtime init and reset handling ([1893356](https://github.com/NativeScript/ns-v8ios-runtime/commit/189335674e1c78898d8ee73bb4e2d195b02396c4))
* take into account null terminated C strings ([#132](https://github.com/NativeScript/ns-v8ios-runtime/issues/132)) ([63ac554](https://github.com/NativeScript/ns-v8ios-runtime/commit/63ac55459bab9336c2c577434d196369c9a33960))
* TypeEncoding might be initialized with random data ([#144](https://github.com/NativeScript/ns-v8ios-runtime/issues/144)) ([02d681e](https://github.com/NativeScript/ns-v8ios-runtime/commit/02d681e6c440caea00aa297bf846b65011fff31c))


### Features

* add support for custom ApplicationPath ([391ef8f](https://github.com/NativeScript/ns-v8ios-runtime/commit/391ef8f3cab9d0608e19b7fb12c197042a576103))
* expose `PerformMicrotaskCheckpoint` ([#133](https://github.com/NativeScript/ns-v8ios-runtime/issues/133)) ([f868384](https://github.com/NativeScript/ns-v8ios-runtime/commit/f868384d757087e887d6cd5ac579155b9ad435a5))
* run app from NativeScript initializer instead of static method ([#137](https://github.com/NativeScript/ns-v8ios-runtime/issues/137)) ([a676ecf](https://github.com/NativeScript/ns-v8ios-runtime/commit/a676ecf3dcc65131c8a426fb5b99058da32f67cf))
* support Xcode 13.3 and iOS 15.4 ([#150](https://github.com/NativeScript/ns-v8ios-runtime/issues/150)) ([1e0c0ce](https://github.com/NativeScript/ns-v8ios-runtime/commit/1e0c0cec0e9627cd72652208347e760809f7d1e1))



# [8.1.0](https://github.com/NativeScript/ns-v8ios-runtime/compare/v7.2.0...v8.1.0) (2021-09-08)


### Bug Fixes

* check if a static method is already set ([#122](https://github.com/NativeScript/ns-v8ios-runtime/issues/122)) ([1f40861](https://github.com/NativeScript/ns-v8ios-runtime/commit/1f408616e3df3012f6ae42adff8c77907be23354))
* isolate dispose on app exit handling ([57ec2ec](https://github.com/NativeScript/ns-v8ios-runtime/commit/57ec2ec012f5c9b5322be1e330cc3e747926bc0d))
* memory leak when marshalling C string parameters ([#127](https://github.com/NativeScript/ns-v8ios-runtime/issues/127)) ([f946828](https://github.com/NativeScript/ns-v8ios-runtime/commit/f946828f4555defdbf12c5eb7cad47b741150fbf))
* general memory leak fixes [62dff97](https://github.com/NativeScript/ns-v8ios-runtime/commit/62dff97cba05785b69db6c5b4001998f313bd449)


### Features

* Update V8 to 9.2.230.18 ([#121](https://github.com/NativeScript/ns-v8ios-runtime/issues/121)) ([b4239fa](https://github.com/NativeScript/ns-v8ios-runtime/commit/b4239facbfcaec13f7efbb8c44ce633ab319ffdc))



7.2.0
===

### Features
- Updated V8 to 8.9 (https://github.com/NativeScript/ns-v8ios-runtime/pull/84)

### Bug Fixes
- breakpoint debugging

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
