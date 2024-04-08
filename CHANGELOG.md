# [8.7.0](https://github.com/NativeScript/ios/compare/v8.6.3...v8.7.0) (2024-04-08)


### Bug Fixes

* only generate metadata for the targeted arch ([#236](https://github.com/NativeScript/ios/issues/236)) ([17a5c5f](https://github.com/NativeScript/ios/commit/17a5c5ff118c2803c0385891224fb30168268ac8))
* Xcode 15.3+ not setting TARGET_OS_IPHONE correctly ([#242](https://github.com/NativeScript/ios/issues/242)) ([0d52056](https://github.com/NativeScript/ios/commit/0d52056fdb102f40887abd47c9bc2af5f3cca94e))


### Features

* upgrade llvm to 15.0.7 ([#238](https://github.com/NativeScript/ios/issues/238)) ([6e9b51e](https://github.com/NativeScript/ios/commit/6e9b51e48c6b8ddf65c6669a035b97e5d935f202))
* **visionos:** support for xros platform ([#235](https://github.com/NativeScript/ios/issues/235)) ([bb364f9](https://github.com/NativeScript/ios/commit/bb364f9558c336c43a9c43d3ded46ef1ad8e8bf3))
* **WinterCG:** URL & URLSearchParams ([#234](https://github.com/NativeScript/ios/issues/234)) ([dc3c76f](https://github.com/NativeScript/ios/commit/dc3c76f1ff74bcd5b800df55210855871bb70563))



## [8.6.3](https://github.com/NativeScript/ios/compare/v8.6.2...v8.6.3) (2023-11-08)


### Bug Fixes

* prevent crashes during isolate disposal ([3d70c11](https://github.com/NativeScript/ios/commit/3d70c110e1429a1d62c9b9e23020cf7044635511))



## [8.6.2](https://github.com/NativeScript/ios/compare/v8.6.1...v8.6.2) (2023-11-01)


### Bug Fixes

* only reset timer persistent if Isolate is valid ([4379583](https://github.com/NativeScript/ios/commit/4379583fc0b2fa3eacde50eb471086f55c1eec18))



## [8.6.0](https://github.com/NativeScript/ios/compare/v8.5.2...v8.6.1) (2023-10-09)


### Bug Fixes

* bridge release adapters ([#224](https://github.com/NativeScript/ios/issues/224)) ([70b1802](https://github.com/NativeScript/ios/commit/70b180202dc0752d01ae5b9249cbaabae65f53cc))
* delay isolate disposal when isolate is in use ([5a6c2ee](https://github.com/NativeScript/ios/commit/5a6c2ee5efa0c557c94ae56da0d3b3a31911d1b8))
* don't suppress timer exceptions ([0c4b819](https://github.com/NativeScript/ios/commit/0c4b819941b0327e572772018298cf9cf181436e))
* fix setInterval not repeating correctly ([022893f](https://github.com/NativeScript/ios/commit/022893f1dcd9a7649db73e9735ff12e9246b3585))
* prevent JS function to native block leak ([#223](https://github.com/NativeScript/ios/issues/223)) ([a6d7332](https://github.com/NativeScript/ios/commit/a6d73323718a1de12c5a9f4865a6abfe06fd6e03))


### Features

* add interop.stringFromCString ([#228](https://github.com/NativeScript/ios/issues/228)) ([185c12d](https://github.com/NativeScript/ios/commit/185c12dc85e86747f266867fb208c71caf5fc6b3))
* add native timers ([#221](https://github.com/NativeScript/ios/issues/221)) ([119470f](https://github.com/NativeScript/ios/commit/119470f249c5aa85c4c2d0b1c9b5b691003c1ec7))
* add timer strong retainer annotation ([efef961](https://github.com/NativeScript/ios/commit/efef961a67519aed881637ac0291894f3325b111))
* log the fullMessage with more details about the error ([#229](https://github.com/NativeScript/ios/issues/229)) ([d67588c](https://github.com/NativeScript/ios/commit/d67588cb3866212ccd86b105edf1207fddde2db9))
* use node logic for globals and modules ([#215](https://github.com/NativeScript/ios/issues/215)) ([a66cc42](https://github.com/NativeScript/ios/commit/a66cc42c768ee7712d1c1f441b8c4e8e88a19eca))



## [8.5.2](https://github.com/NativeScript/ios/compare/v8.5.1...v8.5.2) (2023-05-24)


### Bug Fixes

* Cache shared_ptr leak ([8236cf3](https://github.com/NativeScript/ios/commit/8236cf3f191f8b5bd7098beeff92aef31c0fc6e7))
* FunctionWrapper isolate-level leak ([0c4c017](https://github.com/NativeScript/ios/commit/0c4c017689a71433d567dde48c1464954f3af98b))
* move TARGETED_DEVICE_FAMILY to xcconfig to allow override ([#211](https://github.com/NativeScript/ios/issues/211)) ([2e5f5f1](https://github.com/NativeScript/ios/commit/2e5f5f1e8c8b9551011e2566b8f134dd6cfb5378))
* remove quotes for TARGETED_DEVICE_FAMILY ([157dda7](https://github.com/NativeScript/ios/commit/157dda704b6fbe7cd5077b4bb1ad9676a7c8d47e))
* soif on runtime destruction ([7e24de8](https://github.com/NativeScript/ios/commit/7e24de8f1ace1d72318c0f0253759cd745307e5f))


### Features

* re-enabled inspector protocol handling ([#202](https://github.com/NativeScript/ios/issues/202)) ([c100f72](https://github.com/NativeScript/ios/commit/c100f725e48df5e61316281b82eed835d265b996))



## [8.5.1](https://github.com/NativeScript/ns-v8ios-runtime/compare/v8.5.0...v8.5.1) (2023-03-30)


### Bug Fixes

* incorrect wrapper in indexed array access ([#206](https://github.com/NativeScript/ns-v8ios-runtime/issues/206)) ([b689434](https://github.com/NativeScript/ns-v8ios-runtime/commit/b6894346b273b289bfda713a8f0c7055911c945a))



# [8.5.0](https://github.com/NativeScript/ns-v8ios-runtime/compare/v8.4.1...v8.5.0) (2023-03-28)


### Bug Fixes

* block isolate validation condition ([17a7299](https://github.com/NativeScript/ns-v8ios-runtime/commit/17a729953c913f4b4e7a254c962fe2e8ff11f63b))
* Build and link to v8_heap_base and v8_heap_base_headers ([3ebd066](https://github.com/NativeScript/ns-v8ios-runtime/commit/3ebd066974db59b3d2400232908a8e70531aa649))
* Correctly initialize context in inspector client init() ([92b38ea](https://github.com/NativeScript/ns-v8ios-runtime/commit/92b38eaa7fba3f23f8b128123b7eaec192eb2734))
* create empty metadata-bin files to satisfy XCode dep checks ([0e349fc](https://github.com/NativeScript/ns-v8ios-runtime/commit/0e349fcec9df3ad7ff8b61d27b3f424f5d49f957))
* Don't disconnect inspector when frontend connects ([d2d3b65](https://github.com/NativeScript/ns-v8ios-runtime/commit/d2d3b659fd5fc032b10f8bfdca12063510297271))
* don't null runloop on Promise proxy ([826a395](https://github.com/NativeScript/ns-v8ios-runtime/commit/826a395822b816882d4ac5e82e0995a27769a673))
* don't try to free blocks that not owned by the BlockWrapper ([d4e9b08](https://github.com/NativeScript/ns-v8ios-runtime/commit/d4e9b08e7f58d83dbbb8ab1674b46490b0b491ed))
* drain the microtask queue after devtools message ([de77365](https://github.com/NativeScript/ns-v8ios-runtime/commit/de773650903e80d25420d98649364cbadc64c09d))
* Implement console.log inspector with Runtime protocol ([eaa8dd7](https://github.com/NativeScript/ns-v8ios-runtime/commit/eaa8dd7b6449348a7f966f244eeec93853115164))
* Mac Catalyst build ([#189](https://github.com/NativeScript/ns-v8ios-runtime/issues/189)) ([8980c0f](https://github.com/NativeScript/ns-v8ios-runtime/commit/8980c0f189d9b8dd175dd27cdbb31cba13bf7b9f))
* Re-enable inspector code ([14faf01](https://github.com/NativeScript/ns-v8ios-runtime/commit/14faf01f75053d9a9903baa55b190cdbd3c248b0))
* resolve PromiseProxy context memory leak ([#193](https://github.com/NativeScript/ns-v8ios-runtime/issues/193)) ([21de81d](https://github.com/NativeScript/ns-v8ios-runtime/commit/21de81de5466e3bc1c39f8cbf9135c6a560b2045))
* set metadata-generator deployment target to 11.0 ([#198](https://github.com/NativeScript/ns-v8ios-runtime/issues/198)) ([75cf79f](https://github.com/NativeScript/ns-v8ios-runtime/commit/75cf79f89020f98b55ea08b4dd8ab6e3581ba456))
* use BigInt for pointers ([#199](https://github.com/NativeScript/ns-v8ios-runtime/issues/199)) ([6db3184](https://github.com/NativeScript/ns-v8ios-runtime/commit/6db318438ab5c3de918be9e6b204bddbc399e78d))


### Features

* jsi ([6a3c0e7](https://github.com/NativeScript/ns-v8ios-runtime/commit/6a3c0e7dade509aa677c7d67aeb1206e62e6f7cd))
* print v8 version on start ([be64e3f](https://github.com/NativeScript/ns-v8ios-runtime/commit/be64e3fd4da8da9c9855c080f080848e713074e9))
* Re-add NativeScript inspector sources ([241bba4](https://github.com/NativeScript/ns-v8ios-runtime/commit/241bba48e03b5accc29da1fd2fdd6fe52de8758a))
* Re-add V8 inspector sources ([cfc7adf](https://github.com/NativeScript/ns-v8ios-runtime/commit/cfc7adff27f49dc37a8f99ff4ddba57fb0a8ca4d))
* support fully independent isolates ([#194](https://github.com/NativeScript/ns-v8ios-runtime/issues/194)) ([fa44007](https://github.com/NativeScript/ns-v8ios-runtime/commit/fa44007f9aab12b277836f4388861066837ef14c))
* v8_static 10.3.22 ([32e90c4](https://github.com/NativeScript/ns-v8ios-runtime/commit/32e90c4768d52ca83261b3c2613d38b205852739))



## [8.4.1](https://github.com/NativeScript/ns-v8ios-runtime/compare/v8.4.0...v8.4.1) (2023-01-16)


### Bug Fixes

* memory leak on new string handling ([#190](https://github.com/NativeScript/ns-v8ios-runtime/issues/190)) ([6868a7a](https://github.com/NativeScript/ns-v8ios-runtime/commit/6868a7a4c4db7d9447cd1cc457a112b88e6b2458))
* throw NSException on main thread ([#188](https://github.com/NativeScript/ns-v8ios-runtime/issues/188)) ([d3ba48b](https://github.com/NativeScript/ns-v8ios-runtime/commit/d3ba48bec5f7b47fca4ff999fb6502640e195d27))



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
