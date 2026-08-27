# [9.1.0](https://github.com/NativeScript/ios/compare/v9.0.3...v9.1.0) (2026-08-27)


### Bug Fixes

* add buffer-length check in unzip.cpp ([#429](https://github.com/NativeScript/ios/issues/429)) ([131611a](https://github.com/NativeScript/ios/commit/131611a6a878669bdc3869145f3a5a08b7565912))
* add SharedArrayBuffer support and fix byteOffset handling across all buffer paths ([#370](https://github.com/NativeScript/ios/issues/370)) ([5555935](https://github.com/NativeScript/ios/commit/55559351f0387f3d3359cead8fc22a7cdc070fbf))
* clear pending exception before rejecting a builtin dynamic import ([3232fb5](https://github.com/NativeScript/ios/commit/3232fb58986f0e526e48fbb12c12cff2b71c55c5))
* close the inspector client socket on disconnect ([#390](https://github.com/NativeScript/ios/issues/390)) ([e271a77](https://github.com/NativeScript/ios/commit/e271a7741eaa0dc5bc9b86c259ac50b3a8edeaed))
* delete self-owned URL wrappers at isolate teardown ([#438](https://github.com/NativeScript/ios/issues/438)) ([73e22b5](https://github.com/NativeScript/ios/commit/73e22b5e9b523e01cbb2af63a59707b1f58b3ef9))
* enable interruption of V8 execution on Debugger.pause command ([#378](https://github.com/NativeScript/ios/issues/378)) ([714be8c](https://github.com/NativeScript/ios/commit/714be8cfac40b35232ea9392f716774709cac077))
* enhance nullable type handling in method parameter validation ([#367](https://github.com/NativeScript/ios/issues/367)) ([e0d30a8](https://github.com/NativeScript/ios/commit/e0d30a8a1514a9ed1606673f18b66ea299bd4fb5))
* error handling with ES module compilation, instantiation, and evaluation ([#375](https://github.com/NativeScript/ios/issues/375)) ([4dadac8](https://github.com/NativeScript/ios/commit/4dadac87bf0f0f9d9e0c5788bdc6ca453c1866f1))
* loader additional hardening ([#443](https://github.com/NativeScript/ios/issues/443)) ([#444](https://github.com/NativeScript/ios/issues/444)) ([f1b0e4d](https://github.com/NativeScript/ios/commit/f1b0e4d630ded30c2f988ff42f5e1053fb057867))
* make V8 string to NSString conversions UTF-16 faithful ([#392](https://github.com/NativeScript/ios/issues/392)) ([6778dfd](https://github.com/NativeScript/ios/commit/6778dfdd5b436be0dad51f1f64df1e1408d8e76c))
* native methods expecting a NSError arg will now throw a JS exception if the error arg is not passed ([#311](https://github.com/NativeScript/ios/issues/311)) ([217873b](https://github.com/NativeScript/ios/commit/217873b444af506aed70abde8dd699fe76b94038))
* only marshal promise resolution when created on the runtime loop ([#396](https://github.com/NativeScript/ios/issues/396)) ([721633a](https://github.com/NativeScript/ios/commit/721633a50ad32c69b20b5016e5ae49f4c6cb03c8)), closes [#330](https://github.com/NativeScript/ios/issues/330)
* own native blocks with Block_copy/Block_release ([#394](https://github.com/NativeScript/ios/issues/394)) ([e40de8a](https://github.com/NativeScript/ios/commit/e40de8ae0488af514f190f84eaa4bbd6bab0e007))
* re-throw exceptions in both debug and release modes for better error handling ([#368](https://github.com/NativeScript/ios/issues/368)) ([1eaf03d](https://github.com/NativeScript/ios/commit/1eaf03dd6f34db28e11ae608afef901b54176ead))
* release our own blocks and release instead of dealloc data ([a65b729](https://github.com/NativeScript/ios/commit/a65b729f712d6dfee8a23532f909b9b49203472d))
* report the rejection reason when ES module evaluation fails ([#410](https://github.com/NativeScript/ios/issues/410)) ([164e752](https://github.com/NativeScript/ios/commit/164e7524cb9fdf91bf8862c7d2d96b596575cfb9))
* resolve race condition in nsld.sh with parallel linker invocations ([#356](https://github.com/NativeScript/ios/issues/356)) ([a61d35c](https://github.com/NativeScript/ios/commit/a61d35ce1eb6c807d3ac9a3bfe6e4223dfbdbe7f))
* serialize extended-class allocate/register to prevent duplicate class names ([#421](https://github.com/NativeScript/ios/issues/421)) ([f5f9200](https://github.com/NativeScript/ios/commit/f5f9200de6d5005c7517f67ab943b2e27a6c51db))
* stop over-releasing objects wrapped from a raw pointer ([#432](https://github.com/NativeScript/ios/issues/432)) ([bddaacb](https://github.com/NativeScript/ios/commit/bddaacb984ac2dac426f58577a538fee4ce25bc0))
* throw JS exception instead of silent warning for disposed native object calls in debug mode ([#354](https://github.com/NativeScript/ios/issues/354)) ([becb19b](https://github.com/NativeScript/ios/commit/becb19bf52eafa8c3627b5b9809688461a8859a9))
* typed array offset ([6cb26c0](https://github.com/NativeScript/ios/commit/6cb26c06617853091c6ea89d56b8a145d35c44e9))
* URLSearchParams construction and iteration spec compliance ([#388](https://github.com/NativeScript/ios/issues/388)) ([ad920c6](https://github.com/NativeScript/ios/commit/ad920c6b4a7e4bc4d2dd23394235846b4b1edb48))
* use -fmodule-map-file for Swift metadata discovery in nsld.sh ([#374](https://github.com/NativeScript/ios/issues/374)) ([ecd3598](https://github.com/NativeScript/ios/commit/ecd3598527bc7a9740d93869685aff6422af1825))
* use-after-free in interop.bufferFromData under memory pressure ([#372](https://github.com/NativeScript/ios/issues/372)) ([90ac16c](https://github.com/NativeScript/ios/commit/90ac16ca5a1426fa9e0cf2656427c4c4340f1e66))
* workers should gracefully shutdown on close() ([#369](https://github.com/NativeScript/ios/issues/369)) ([4644fce](https://github.com/NativeScript/ios/commit/4644fced293eb084ac12972fe3dae6953d3bd850))
* Xcode 26.4 build for runtime, inspector, and metadata-generator ([#376](https://github.com/NativeScript/ios/issues/376)) ([5e34fec](https://github.com/NativeScript/ios/commit/5e34fec429a2bf10bb358cc6492e0b5a948f29d2))
* **console:** find custom toString on deep prototype chains ([3d178e7](https://github.com/NativeScript/ios/commit/3d178e772ff174430cf4875d38130175f1dc6c0b))
* **hooks:** stop the pre-commit hook from swallowing failures ([f860466](https://github.com/NativeScript/ios/commit/f860466af318cbde01282d0e1e72fc9908dc1cc7))
* **inspect:** bound Map/Set iteration and harden proxy handling ([9bebe69](https://github.com/NativeScript/ios/commit/9bebe6979dedc30019c9c75fdfc0778453a63ce7))
* **inspector:** answer the Tracing domain off the JS thread, stop swapping the trace buffer ([b68a963](https://github.com/NativeScript/ios/commit/b68a963975448b9ff592250cc234f7086cba56d0))
* **inspector:** make the Tracing domain protocol-correct and faster ([87ab586](https://github.com/NativeScript/ios/commit/87ab58624b4b67dda7bdc02856ce334c4823bfbb))
* **metadata-generator:** emit UIKit metadata for Mac Catalyst ([#433](https://github.com/NativeScript/ios/issues/433)) ([7291cf3](https://github.com/NativeScript/ios/commit/7291cf3b705f3c7425b282ba09857a8de34d179e))
* **metadata-generator:** handle spaces in xcode path by appending the paths directly post split ([#344](https://github.com/NativeScript/ios/issues/344)) ([327f9ba](https://github.com/NativeScript/ios/commit/327f9bad76eb42359321f6355365572aa0200b32))
* **metadata-generator:** strip nullability wrappers before structural type checks ([#389](https://github.com/NativeScript/ios/issues/389)) ([05224d3](https://github.com/NativeScript/ios/commit/05224d35a81af2cc3d5091ab951835d4fe5774c5))
* **napi:** enter the env's context around async-work completion ([3645898](https://github.com/NativeScript/ios/commit/3645898b9a5e8b8cd7b34fa45c49a83555ddaaaf)), closes [#441](https://github.com/NativeScript/ios/issues/441)
* **performance:** treat a null measure() options argument as absent ([4af8d21](https://github.com/NativeScript/ios/commit/4af8d21f42fc04a3c900b7e1dcb6113378baca59))
* **release:** default to embedded SwiftPM packaging and restore portable local/PR packages ([#406](https://github.com/NativeScript/ios/issues/406)) ([2098243](https://github.com/NativeScript/ios/commit/209824303beef844e8c36b2c3fbdd4e417f20b7e))
* **release:** shape the ios-spm manifest per channel and verify the real manifest ([#405](https://github.com/NativeScript/ios/issues/405)) ([746d4da](https://github.com/NativeScript/ios/commit/746d4da0c111fbad3e5a18392e9ef7811740cf41))
* **runtime:** configureLoader volatilePatterns replaces wholesale, empty included ([828d913](https://github.com/NativeScript/ios/commit/828d91367b7612a2c5c3a80a82fc127949633d26))
* **runtime:** correct allocator use and ownership metadata in wrapper teardown ([addf287](https://github.com/NativeScript/ios/commit/addf287e322c5bafbec71b18d90232f68fe04140))
* **runtime:** finalizer-safe handle ownership and deferred JSBlock teardown ([#457](https://github.com/NativeScript/ios/issues/457)) ([70ad372](https://github.com/NativeScript/ios/commit/70ad3729de03409e66a7c2296a64f0700ed02ea3))
* **runtime:** interop memory-safety fixes from the worker memory-corruption hunt ([#458](https://github.com/NativeScript/ios/issues/458)) ([5d4569c](https://github.com/NativeScript/ios/commit/5d4569c197810cdd4c1e02e7c16d42a01a77d5c0)), closes [#459](https://github.com/NativeScript/ios/issues/459)
* **runtime:** loader callbacks throw TypeErrors on invalid input ([ee51d74](https://github.com/NativeScript/ios/commit/ee51d7414eccb6caa1182f9706c819cb4cebca16))
* **runtime:** lock process-global caches shared across isolates ([3a6332a](https://github.com/NativeScript/ios/commit/3a6332a7ae4aac936d0d75b831c5c739699e6322))
* **runtime:** plug native memory leaks found by Instruments ([8080bc0](https://github.com/NativeScript/ios/commit/8080bc0688e1a9533f7473301b9425627f3e0477))
* **test-runner:** make junit report delivery resilient on starved CI VMs ([#419](https://github.com/NativeScript/ios/issues/419)) ([e5e84e0](https://github.com/NativeScript/ios/commit/e5e84e0b7f8b5e0f7386d02ac39b023dc1d10754))
* **url:** resync cached searchParams when search/href changes ([#422](https://github.com/NativeScript/ios/issues/422)) ([10547cc](https://github.com/NativeScript/ios/commit/10547cc4475ec3ce67e982795c60555320c2bac2))
* **urlpattern:** match capture groups in test()/exec() ([#402](https://github.com/NativeScript/ios/issues/402)) ([9f21329](https://github.com/NativeScript/ios/commit/9f21329a8f4d83830c6ccc0ad6054975d8036c33))
* **v8:** pin the prebuilt release that exports the public V8 API ([9fb910c](https://github.com/NativeScript/ios/commit/9fb910c44d509d25d83e5d3bb829d31f3012ddfc))
* **v8:** pin the release without the cppgc caged heap ([2f47ad9](https://github.com/NativeScript/ios/commit/2f47ad988e990b71e8cde26d9c49a7fcb94f4726))
* **worker:** worker path resolution parity with android and error handling for missing scripts ([20ce8d4](https://github.com/NativeScript/ios/commit/20ce8d45167ec917c4b3c5ffc2c552b829652107))


### Features

* Ada v4 ([#413](https://github.com/NativeScript/ios/issues/413)) ([9b6df7d](https://github.com/NativeScript/ios/commit/9b6df7d68bf72b3cef780fa0f477cedfaa9071d9))
* add more null types for types the runtime accept or returns as null ([#363](https://github.com/NativeScript/ios/issues/363)) ([fb0a5f4](https://github.com/NativeScript/ios/commit/fb0a5f4fcd408369a318ae3d17b60b196e6cbc34))
* add Node-style primordials to runtime builtins ([#415](https://github.com/NativeScript/ios/issues/415)) ([d5c187c](https://github.com/NativeScript/ios/commit/d5c187c462cde4e7a26be5378593b083cf1ba153))
* add support for nullable types and ArrayBuffers for pointers ([#357](https://github.com/NativeScript/ios/issues/357)) ([961dc76](https://github.com/NativeScript/ios/commit/961dc769386992dd53d722b31073fa500a5c7323))
* allow custom priority for workers ([#377](https://github.com/NativeScript/ios/issues/377)) ([8d238ed](https://github.com/NativeScript/ios/commit/8d238eddbf20e69e27ba0044522fcd53a6d357d8))
* budgeted console formatter (inspect builtin) ([#416](https://github.com/NativeScript/ios/issues/416)) ([5e40702](https://github.com/NativeScript/ios/commit/5e40702bc788589f5f2868dcb69149da0428e594))
* enable TestRunner suite and metadata availability checks on visionOS ([#407](https://github.com/NativeScript/ios/issues/407)) ([d907487](https://github.com/NativeScript/ios/commit/d9074873eb5eeb389168e0aa1e7074430ecfa6ae))
* ESM resolver hardening, HTTP module loader, ns:module dev surface ([#383](https://github.com/NativeScript/ios/issues/383)) ([c5e9886](https://github.com/NativeScript/ios/commit/c5e9886e96516884d337a1920d581011fdcfdcac))
* guard released-native-object access behind a policy (ns:runtime) ([4193a8e](https://github.com/NativeScript/ios/commit/4193a8e9e84cfbbec53df07857954e1616e67a8b))
* improve profiler performance ([#332](https://github.com/NativeScript/ios/issues/332)) ([c371b6c](https://github.com/NativeScript/ios/commit/c371b6cbc084e90a9db84b1ccdde0f2db5bf1154))
* Node-API (napi) surface for plugin developers ([#437](https://github.com/NativeScript/ios/issues/437)) ([3900e1c](https://github.com/NativeScript/ios/commit/3900e1ca9f6749e55a93375759e2aa242964eb9a))
* ns:util builtin module (inspect, format) ([#418](https://github.com/NativeScript/ios/issues/418)) ([22226ba](https://github.com/NativeScript/ios/commit/22226ba1d8636ebd8a09c6416820d57c9813d74d))
* per-runtime EventLoop - v8 platform tasks + two-lane scheduler (CFRunLoop timer/source) ([#439](https://github.com/NativeScript/ios/issues/439)) ([4a90925](https://github.com/NativeScript/ios/commit/4a909252a3df273a803b6a68de68587ab088b900))
* scope worker-created extended class names to their isolate ([#428](https://github.com/NativeScript/ios/issues/428)) ([77b1ea3](https://github.com/NativeScript/ios/commit/77b1ea3ca2c3cfb1f5e88d759f5ded1479bb7da8))
* ship TypeScript declarations for the ns:* builtin modules ([5e470f4](https://github.com/NativeScript/ios/commit/5e470f4565be19016dade382a8f7b8a0be552219))
* structuredClone global (HTML structured clone, ArrayBuffer transfer) ([#431](https://github.com/NativeScript/ios/issues/431)) ([5ad8bb1](https://github.com/NativeScript/ios/commit/5ad8bb149b0192a0c0a1b7838ed3384f0e34d9d5))
* swift package release workflow ([#395](https://github.com/NativeScript/ios/issues/395)) ([732c439](https://github.com/NativeScript/ios/commit/732c4396ea12c01569312a0b0caaed0a5badfdc8))
* update libffi to upstream with FFI_TYPE_VECTOR support ([#408](https://github.com/NativeScript/ios/issues/408)) ([485cdbb](https://github.com/NativeScript/ios/commit/485cdbbbcbc0b6563fc1ebd630eadea5882e45dd))
* upgrade V8 to 14.9.207.39 ([#412](https://github.com/NativeScript/ios/issues/412)) ([0e89474](https://github.com/NativeScript/ios/commit/0e89474b1a203ff084b4c88df8a2aa777e5c50a0))
* web-compliant error handling (unhandled rejections, error events, interop.escapeException) ([#409](https://github.com/NativeScript/ios/issues/409)) ([55ffdef](https://github.com/NativeScript/ios/commit/55ffdef9adbc8548473987709b74d6e27d40dc11))
* WHATWG performance API (hr-time, user timing, performance timeline) ([#430](https://github.com/NativeScript/ios/issues/430)) ([e338870](https://github.com/NativeScript/ios/commit/e338870d8c9d24d66fde5c22349b0a9dcb4af85c))
* **inspector:** attach Chrome DevTools to Web Worker isolates ([#386](https://github.com/NativeScript/ios/issues/386)) ([cd28c41](https://github.com/NativeScript/ios/commit/cd28c415e6352376daad593ef3e136cb51444fc2))
* **inspector:** serve source maps to DevTools via Network.loadNetworkResource ([#385](https://github.com/NativeScript/ios/issues/385)) ([91ce499](https://github.com/NativeScript/ios/commit/91ce499f8888eed309c26398803609f7e9ac2a8c))
* **performance:** structured-clone mark/measure detail per spec ([6dd5523](https://github.com/NativeScript/ios/commit/6dd55238d5b20ab75d2b9b08ce07a50c6bf10356))
* **runtime:** add AbortController and AbortSignal ([#447](https://github.com/NativeScript/ios/issues/447)) ([292a9e3](https://github.com/NativeScript/ios/commit/292a9e38162d5ce8ad852ddb1d644b1316e7155d))
* **runtime:** DOMException and CustomEvent as lazy globals ([#452](https://github.com/NativeScript/ios/issues/452)) ([d7bf2c7](https://github.com/NativeScript/ios/commit/d7bf2c7308f1605cac339ddfe48e8840add90e87))
* **runtime:** expose timers under the standard global names ([9399899](https://github.com/NativeScript/ios/commit/9399899958a3cfdf5fd31a63cbdce47824489594))
* **runtime:** lazy-global tier with native TextEncoder/TextDecoder and atob/btoa ([#448](https://github.com/NativeScript/ios/issues/448)) ([ac195f0](https://github.com/NativeScript/ios/commit/ac195f0c3edc339ed7e960f31560d1d15c858e9d))
* **runtime:** requestAnimationFrame and Android-parity frame callbacks ([#446](https://github.com/NativeScript/ios/issues/446)) ([e9ce46e](https://github.com/NativeScript/ios/commit/e9ce46e29e56d40bb683de0033e1891447286dcd))
* **runtime:** typed per-isolate state slots on Caches ([abe7ffe](https://github.com/NativeScript/ios/commit/abe7ffe57e67e350009d7ba38c0f81d0177fe14b))


### Performance Improvements

* convert strings across the V8/Obj-C bridge without the UTF-8 round trip ([#442](https://github.com/NativeScript/ios/issues/442)) ([bfc6c5e](https://github.com/NativeScript/ios/commit/bfc6c5ef2487c48994392b1f1e364afc2717f456))
* **metadata:** small size reductions in metadata.bin ([#434](https://github.com/NativeScript/ios/issues/434)) ([ba922a7](https://github.com/NativeScript/ios/commit/ba922a7c70c73b4b1e92df96ae92f1bff27de68a))


### Reverts

* swift package release workflow and follow-ups ([#404](https://github.com/NativeScript/ios/issues/404)) ([2c2b63f](https://github.com/NativeScript/ios/commit/2c2b63f75b7dfbda4b942e22a4817bf0cd9dc166))


### BREAKING CHANGES

* V8 is upgraded from 10.3.22 to 14.9.207.39 ([#412](https://github.com/NativeScript/ios/issues/412)). The prebuilt V8 libraries and vendored headers are no longer committed to the repo — `download_v8.sh` (run automatically by `build_nativescript.sh`) installs them from the release pinned in `V8_RELEASE`. `require()` of an unresolvable module now throws at require time instead of returning a placeholder that fails on property access. The embedder API migration notes live in `docs/knowledge/v8-14-migration.md`.



## [9.0.3](https://github.com/NativeScript/ios/compare/v9.0.2...v9.0.3) (2026-01-04)


### Features

* remote module security ([#331](https://github.com/NativeScript/ios/issues/331)) ([721ceaf](https://github.com/NativeScript/ios/commit/721ceafe2606ff25786529acb9a4c727cfa84d78))



## [9.0.2](https://github.com/NativeScript/ios/compare/v9.0.1...v9.0.2) (2025-12-14)


### Bug Fixes

* http realm cache key with query params ([#328](https://github.com/NativeScript/ios/issues/328)) ([f0c9df3](https://github.com/NativeScript/ios/commit/f0c9df35ecf01aaad340d325b0fba3f8ec083eae))
* http realm normalization ([faa6762](https://github.com/NativeScript/ios/commit/faa67626695f133f5d37dca09aaab957214c7bd2))
* URLSearchParams.forEach() crash and spec compliance ([#327](https://github.com/NativeScript/ios/issues/327)) ([28242ec](https://github.com/NativeScript/ios/commit/28242ecc3bc52875f7ffe13ae1665224026191a3))



## [9.0.1](https://github.com/NativeScript/ios/compare/v9.0.0...v9.0.1) (2025-11-25)


### Bug Fixes

* node built-in modules handling ([#319](https://github.com/NativeScript/ios/issues/319)) ([f748751](https://github.com/NativeScript/ios/commit/f748751c74968ea015c8abff30fe86bfacd84930))
* **runtime:** app path substr considerations ([#314](https://github.com/NativeScript/ios/issues/314)) ([fd2703d](https://github.com/NativeScript/ios/commit/fd2703d59e6ba2472d8baefe014f0afc4c8952df))



# [9.0.0](https://github.com/NativeScript/ios/compare/v8.9.5...v9.0.0) (2025-11-17)


### Bug Fixes

* optional error parameter for NSError out parameters ([#310](https://github.com/NativeScript/ios/issues/310)) ([99824ec](https://github.com/NativeScript/ios/commit/99824eca41c1ae7fb939a6790ae83f6e2bc41574))
* **visionos:** build flags ([29e5d79](https://github.com/NativeScript/ios/commit/29e5d79924ae65c32f93f8cb19aece4ef6f370fd))
* **visionos:** linker robustness ([14355d5](https://github.com/NativeScript/ios/commit/14355d5647e4b61c60be3fb87282d441575f1de0))


### Features

* Ada 3.3.0 ([#313](https://github.com/NativeScript/ios/issues/313)) ([e24388c](https://github.com/NativeScript/ios/commit/e24388c9261bcbf9c2580abf76cffdc87b6d2bf6))
* ES modules (ESM) support with conditional esm or commonjs consumption + better error handling ([#276](https://github.com/NativeScript/ios/issues/276)) ([e72977a](https://github.com/NativeScript/ios/commit/e72977ab9a1059a8e9686c169f3090c6fdcee398))
* http loaded es module realms + HMR DX enrichments ([#312](https://github.com/NativeScript/ios/issues/312)) ([59191d3](https://github.com/NativeScript/ios/commit/59191d3b921c29346bbfeb4f0947f13e5b08288e))
* support for struct reference index access ([#304](https://github.com/NativeScript/ios/issues/304)) ([d289232](https://github.com/NativeScript/ios/commit/d2892320e773cc12729f3b6edc5da683534aef9b))



## [8.9.5](https://github.com/NativeScript/ios/compare/v8.9.4...v8.9.5) (2025-10-24)


### Bug Fixes

* make debugger log public ([#302](https://github.com/NativeScript/ios/issues/302)) ([e89067c](https://github.com/NativeScript/ios/commit/e89067cf0f57adcc2479642e4e043b6d6e0d8a0b))
* prevent crash during debug on fast view churn (like with HMR) ([#294](https://github.com/NativeScript/ios/issues/294)) ([42a5328](https://github.com/NativeScript/ios/commit/42a5328f9e95b2298efe067485ac6775718d0510))
* properly convert objective-c logs into os_log ([#301](https://github.com/NativeScript/ios/issues/301)) ([5733af1](https://github.com/NativeScript/ios/commit/5733af1abd896ef8902fbd5b0f57888e71d67d1b))
* symbol loader log true errors only to not confuse terminal output ([#293](https://github.com/NativeScript/ios/issues/293)) ([7101127](https://github.com/NativeScript/ios/commit/710112731a9149020c49c2b2b34a82ebd39a2d49))
* x86 simulators and add better failsafe around generated class names ([#303](https://github.com/NativeScript/ios/issues/303)) ([bb02623](https://github.com/NativeScript/ios/commit/bb02623415359d11cd9e17f3d6351c3b04c4f01d))


### Features

* queueMicrotask support ([#291](https://github.com/NativeScript/ios/issues/291)) ([b12d552](https://github.com/NativeScript/ios/commit/b12d5528885086335487bae4c62cab13ccdb841a))



## [8.9.4](https://github.com/NativeScript/ios/compare/v8.9.2...v8.9.3) (2025-09-09)


### Features

- include dSYMs

## [8.9.3](https://github.com/NativeScript/ios/compare/v8.9.2...v8.9.3) (2025-09-09)


### Bug Fixes

* **catalyst:** variable-length arrays ([#275](https://github.com/NativeScript/ios/issues/275)) ([6d3dfc2](https://github.com/NativeScript/ios/commit/6d3dfc2558e60da60a9f6cbb45cdfd272eefabe7))


### Features

* Xcode 26 
* Ada 3.2.7 ([#279](https://github.com/NativeScript/ios/issues/279)) ([fb56643](https://github.com/NativeScript/ios/commit/fb56643b2ec0e41a10f3acf5633e59bcbd2b0514))
* improve robustness of linking with clang path checks ([#280](https://github.com/NativeScript/ios/issues/280)) ([debc76d](https://github.com/NativeScript/ios/commit/debc76dfd143d26956180c35c8a96534dd7ad152))
* opt for os_log with graceful backwards compat fallback ([#278](https://github.com/NativeScript/ios/issues/278)) ([3c5d894](https://github.com/NativeScript/ios/commit/3c5d894e670bcb9ef7c48446b6c565a196f0cfd2))
* search sub framework paths in metadata generator ([#277](https://github.com/NativeScript/ios/issues/277)) ([7bd239f](https://github.com/NativeScript/ios/commit/7bd239fa43e3884bffe06a7fef6f39aa4a156e39))



## [8.9.2](https://github.com/NativeScript/ios/compare/v8.9.1...v8.9.2) (2025-03-11)


### Bug Fixes

* Intel simulators ([#272](https://github.com/NativeScript/ios/issues/272)) ([0adeabf](https://github.com/NativeScript/ios/commit/0adeabf24aab579bdc10900495a46e9b8287b5d9))


### Reverts

* "feat: visionOS unit tests" ([f26d72c](https://github.com/NativeScript/ios/commit/f26d72c769c936b3ead647933f5da1af6c5c4434))



## [8.9.1](https://github.com/NativeScript/ios/compare/v8.9.0...v8.9.1) (2025-02-28)


### Features

* Ada 3.1.3 ([#270](https://github.com/NativeScript/ios/issues/270)) ([7081e5a](https://github.com/NativeScript/ios/commit/7081e5a50ee34f1d9edc1a6c3ae8a0cdbace30ec))



# [8.9.0](https://github.com/NativeScript/ios/compare/v8.8.2...v8.9.0) (2025-02-24)


### Bug Fixes

* handle gc protection in runtime run loop ([#264](https://github.com/NativeScript/ios/issues/264)) ([5e8214d](https://github.com/NativeScript/ios/commit/5e8214dc7fffa91abd6c870b294259583ec50ce7))
* possible race condition extending native class ([8b932a3](https://github.com/NativeScript/ios/commit/8b932a31fe735c69b9d72b76eb106037653764ce))
* **URL:** allow undefined 2nd args and fix pathname return value ([#263](https://github.com/NativeScript/ios/issues/263)) ([4219038](https://github.com/NativeScript/ios/commit/42190388ddfbd42ad3b87244f5f317860f43c327))


### Features

* ada 3.1.1 including URLPattern support ([#268](https://github.com/NativeScript/ios/issues/268)) ([08d4406](https://github.com/NativeScript/ios/commit/08d4406d36545117a5a7be2db900394f106c4ec2))
* latest jsi updates ([#267](https://github.com/NativeScript/ios/issues/267)) ([d4f3b68](https://github.com/NativeScript/ios/commit/d4f3b680ba77823d9e03b82548ead26706993b99))
* use monotonic time for performance object ([8b320a4](https://github.com/NativeScript/ios/commit/8b320a4b15a216d27d43acfda44cd068d84f6e65))
* visionOS unit tests ([#257](https://github.com/NativeScript/ios/issues/257)) ([ac52442](https://github.com/NativeScript/ios/commit/ac524426242049db2844576cc4f6d4f8776e71d5))



## [8.8.3-alpha.0](https://github.com/NativeScript/ios/compare/v8.8.2...v8.8.3-alpha.0) (2024-12-05)


### Bug Fixes

* handle gc protection in runtime run loop ([78b5e37](https://github.com/NativeScript/ios/commit/78b5e3799f1305b3eafe7d3deb60a7e56b86b230))
* possible race condition extending native class ([8b932a3](https://github.com/NativeScript/ios/commit/8b932a31fe735c69b9d72b76eb106037653764ce))



## [8.8.2](https://github.com/NativeScript/ios/compare/v8.8.1...v8.8.2) (2024-09-06)


### Bug Fixes

* ensure same mtime for js and code cache to prevent loading old code caches ([#261](https://github.com/NativeScript/ios/issues/261)) ([055b042](https://github.com/NativeScript/ios/commit/055b0427cf49e7c4cb37991c9419b899868b6bbd))
* revert visionOS changes to iOS project template ([55c5c51](https://github.com/NativeScript/ios/commit/55c5c5198f04ff2b5cbe1be6f5add92acb3ed23f))



## [8.8.1](https://github.com/NativeScript/ios/compare/v8.8.0...v8.8.1) (2024-07-10)


### Features

* Ada 2.9 ([#256](https://github.com/NativeScript/ios/issues/256)) ([d16b144](https://github.com/NativeScript/ios/commit/d16b14436bddac42a12a4bddff92d2bc37dc8669))



# [8.8.0](https://github.com/NativeScript/ios/compare/v8.7.2...v8.8.0) (2024-07-09)


### Bug Fixes

* ensure copy rule copy *.hpp headers ([3b13e9d](https://github.com/NativeScript/ios/commit/3b13e9dce88015c1e8eab29b9b0c7ec104b4f4d2))


### Features

* add `[@deprecation](https://github.com/deprecation)` and `[@since](https://github.com/since)` docs ([#246](https://github.com/NativeScript/ios/issues/246)) ([daceac1](https://github.com/NativeScript/ios/commit/daceac129d3b73c46a6de4f557d6c06a0621890f))
* add protocol information to native types ([#247](https://github.com/NativeScript/ios/issues/247)) ([6286203](https://github.com/NativeScript/ios/commit/6286203ca5293f4a9bec536ee6af7415d8d4d8f5))
* allow embedding into existing apple host projects ([#231](https://github.com/NativeScript/ios/issues/231)) ([7ab180a](https://github.com/NativeScript/ios/commit/7ab180a7c8788216126abbb985d72332b064217a))
* expose __dateTimeConfigurationChangeNotification ([#220](https://github.com/NativeScript/ios/issues/220)) ([5088f5f](https://github.com/NativeScript/ios/commit/5088f5fff231023a722a4626e73661ff6b9ad9fd))
* JSI support for BigInt, Initial TypedArrays & ArrayBuffer creation ([#204](https://github.com/NativeScript/ios/issues/204)) ([4cd869d](https://github.com/NativeScript/ios/commit/4cd869dd678cf875b31efa4b7a75ee0f571ce096))
* use messaging object to pass message to workers ([#233](https://github.com/NativeScript/ios/issues/233)) ([7ded0c3](https://github.com/NativeScript/ios/commit/7ded0c38bb891b340bd8e1c5137e607447e26e60))
* xcode 16 support ([#254](https://github.com/NativeScript/ios/issues/254)) ([6ec9a8f](https://github.com/NativeScript/ios/commit/6ec9a8fe7888780d7394a1e21c1041619212be1f))



## [8.7.2](https://github.com/NativeScript/ios/compare/v8.7.1...v8.7.2) (2024-05-16)


### Bug Fixes

* **ios:** watchOS embedded apps ([#250](https://github.com/NativeScript/ios/issues/250)) ([1df9ea2](https://github.com/NativeScript/ios/commit/1df9ea20b6bfde5163b0486e444e5471fb8343b2))



## [8.7.1](https://github.com/NativeScript/ios/compare/v8.7.0...v8.7.1) (2024-04-26)


### Bug Fixes

* url href ([#252](https://github.com/NativeScript/ios/issues/252)) ([4a6e9ad](https://github.com/NativeScript/ios/commit/4a6e9adde6950e09ac0c2fd2713e25aa919ad448))
* Xcode 15.3+ not setting TARGET_OS_IOS correctly ([#248](https://github.com/NativeScript/ios/issues/248)) ([74e1444](https://github.com/NativeScript/ios/commit/74e144432bf17cc043d0e64affc9cb1703e80832))



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
