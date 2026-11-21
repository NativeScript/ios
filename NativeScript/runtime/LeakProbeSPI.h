#ifndef LeakProbeSPI_h
#define LeakProbeSPI_h

// The interface between the runtime and NativeScriptLeakProbe.framework, the
// leak diagnostics apps embed in debug builds only. The runtime looks up
// kLeakProbeConnectSymbol with dlsym and hands the framework a Host; the
// framework answers with its Probe. Both sides are built from this header and
// refuse any other version, so a stale framework copy is ignored rather than
// misread.
//
// The framework includes nothing else from the runtime: it uses V8's public
// API, which NativeScript.framework exports, and reaches runtime state only
// through Host.

#include <objc/objc.h>
#include <stdint.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include "v8.h"
#pragma clang diagnostic pop

namespace tns {
namespace leakprobe {

constexpr uint32_t kVersion = 3;

constexpr const char* kConnectSymbol = "NativeScriptLeakProbeConnect";

// One entry of an isolate's native object -> wrapper map, or an object whose
// only runtime retains are queued ones (`wrapper` empty). The runtime has not
// dereferenced `object`, which another thread may have freed unless `queued`.
struct Instance {
  void* object;
  // Empty once the wrapper is gone.
  v8::Local<v8::Value> wrapper;
  // Retains the runtime still holds on `object` for wrappers that died, until
  // the next drain (Host::drainReleases) on this isolate's thread.
  uint32_t queued;
  // `wrapper` wraps an Objective-C object; the fields below are meaningful
  // only then.
  bool objc;
  // The object and class the wrapper was made for.
  void* wrapped;
  Class wrappedClass;
  // "rooted" mode holds the wrapper strongly while native code owns the object.
  bool rootedStrong;
  // The map holds the wrapper through the strong handle the runtime keeps for
  // a JS-extended object native code also retains.
  bool reconciledStrong;
  // The map holds the wrapper through a weak handle whose disposal is refused
  // while native code retains the object ("resurrecting"): the object keeps
  // the wrapper alive.
  bool resurrects;
};

struct LifetimeStats {
  uint64_t resurrections;
  uint64_t collected;
  uint64_t releasedExplicitly;
  uint64_t releasedAccesses;
  uint64_t queuedReleases;
  uint64_t canaryStates;
  uint64_t canaryNativeDeaths;
};

// Posts tasks to one isolate's thread from any thread. A task posted after
// the isolate's event loop shut down is dropped.
struct Poster;

// Unless stated otherwise, a function taking an isolate runs on that isolate's
// thread, inside the caller's HandleScope.
struct Host {
  uint32_t version;
  uint32_t size;

  // False when the isolate is tearing down.
  bool (*forEachInstance)(v8::Isolate* isolate, void* context,
                          void (*visit)(void* context,
                                        const Instance& instance));
  // Each object comes retained, and `visit` takes over that reference. Its
  // last release can run JS: not inside a heap snapshot.
  void (*forEachCanaryState)(v8::Isolate* isolate, void* context,
                             void (*visit)(void* context, id object,
                                           v8::Local<v8::Object> state));
  // Every canary state handle the runtime holds, those forEachCanaryState
  // skips included: states of objects being deallocated, and of deallocated
  // objects until the next drain lets go of them.
  void (*forEachCanaryStateHandle)(v8::Isolate* isolate, void* context,
                                   void (*visit)(void* context,
                                                 v8::Local<v8::Object> state));
  // Whether the runtime made `block` (alive) for JS.
  bool (*isJSBlock)(const void* block);
  // The JS function a JS block made for this isolate calls; empty for other
  // blocks and once the block is disposing. The caller holds the Locker.
  v8::Local<v8::Value> (*jsBlockCallback)(v8::Isolate* isolate,
                                          const void* block);
  // The closest class of `cls` that JS did not create.
  Class (*nativeClass)(Class cls);

  // One opaque state per isolate for the probe. `destroy` runs when the
  // isolate's runtime state is torn down, under its Locker, while the isolate
  // is alive. Null / false once teardown has begun.
  void* (*isolateState)(v8::Isolate* isolate);
  bool (*setIsolateState)(v8::Isolate* isolate, void* state,
                          void (*destroy)(void* state));

  Poster* (*createPoster)(v8::Isolate* isolate);
  // Any thread. `task` runs on the isolate's thread with the isolate entered
  // and its context in scope; `context` must stay valid until then.
  bool (*post)(Poster* poster,
               void (*task)(v8::Isolate* isolate, void* context),
               void* context);
  // Any thread.
  void (*destroyPoster)(Poster* poster);

  // Releases the native objects wrapper lifetime modes queued for release,
  // and lets go of the canary states of deallocated objects. Can run JS.
  void (*drainReleases)(v8::Isolate* isolate);
  const char* (*lifetimeMode)();
  const char* (*lifetimeScope)();
  bool (*lifetimeStats)(v8::Isolate* isolate, LifetimeStats* out);
  // A key of the app's package.json, or nil.
  id (*appConfigValue)(const char* key);
  bool (*isDebug)();
  // Any thread.
  void (*log)(const char* message);
};

struct Probe {
  uint32_t version;
  uint32_t size;
  // Called once per isolate when it starts. False leaves the isolate without
  // the probe, as if the framework were absent.
  bool (*attach)(v8::Isolate* isolate, bool mainIsolate);
  // ns:runtime's findLeakCycles and getWrapperClassCounts.
  v8::FunctionCallback findLeakCycles;
  v8::FunctionCallback getWrapperClassCounts;
};

using ConnectFunction = const Probe* (*)(const Host* host);

}  // namespace leakprobe
}  // namespace tns

#endif /* LeakProbeSPI_h */
