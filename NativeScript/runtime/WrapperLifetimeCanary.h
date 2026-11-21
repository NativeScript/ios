#ifndef WrapperLifetimeCanary_h
#define WrapperLifetimeCanary_h

#include <objc/runtime.h>

#include <cstdint>
#include <functional>
#include <memory>

#include "Common.h"

namespace tns {

struct CanaryRecord;

// The handlers a wrapper's template carries in canary mode: none for a wrapper
// that is not a canary, and per kind for one that is. A canary must be built
// from a template configured for its object's kind (WrapperLifetimeCanary::
// KindOf).
enum class CanaryKind : uint8_t {
  kNone,
  // A canary of an object outside JS-extended classes (scope "all").
  kPlain,
  // A canary of an instance of a JS-extended class.
  kExtended,
};

// The canary wrapper lifetime mode (WrapperLifetimeMode::kCanary).
//
// An ObjC object's wrapper is a canary: a phantom-weak JS object that dies
// with its JS references, releasing the runtime's retain on the object. Its JS
// properties live in a state object that outlives it, which is the source of
// truth. Writes to native properties and other inherited accessors are not
// state. Two handler sets keep the state:
//
// - Mirroring (kExtended canaries, and kPlain ones when the app config allows
//   shadowing native members): a masking named interceptor with only a
//   setter, deleter and definer mirrors every JS property written to the
//   canary into the state and then declines, so the property also lands on
//   the canary and reads never leave V8. A canary built later for the same
//   object gets the state's properties copied back (Hydrate). Masking, so it
//   also sees an instance write over a name its prototype chain has.
// - Forwarding (kPlain canaries under scope "all" otherwise): a non-masking
//   interceptor keeps the properties in the state only, and every access to
//   them goes through it; a canary built later needs no copy. V8 calls a
//   non-masking interceptor only for names absent from the object and its
//   prototype chain, so names the chain has never reach it: an instance write
//   over an inherited data property (a native method, toString, constructor,
//   a member JS added to a prototype), and Object.defineProperty of such a
//   name, land on the canary and die with it; deleting such a name deletes
//   nothing. Native members cannot be overridden per instance anyway: native
//   code sends messages, which never read JS own properties of a plain
//   object.
//
// The state object is rooted from its first write until the native object is
// deallocated. A JS-extended class's own -dealloc reports its instances; for
// other objects an associated token's -dealloc does, or a sweep of weak
// references after major collections finds it (NS_CANARY_DEATH_SIGNAL in the
// .mm chooses). It cannot be rooted only once the canary dies instead: a state
// reachable only through the canary is garbage in the same collection, before
// any phantom callback runs. The
// cost is that state referencing its own canary (a closure over `this`, a
// WeakMap value naming the object) keeps the canary, and through its retain the
// native object, alive. This is the portable contract, the one the Node-API
// runtimes and Android can implement.
//
// SWITCH POINT (iOS only, not implemented): to collect that self-referencing
// shape, a major-GC prologue could make a record's state handle weak while the
// object is not natively owned and no canary is alive, the way the rooted mode
// scans retain counts (WrapperLifetime.mm, PrologueCallback). Records already
// carry everything such a scan needs: the native object and the state handle.
class WrapperLifetimeCanary {
 public:
  static void Init(v8::Isolate* isolate);

  // Gives a JS-extended class a -dealloc that reports its instances' deaths,
  // so their state needs no associated token or weak reference. No-op unless
  // the mode is canary.
  static void InstallDeallocHook(Class extendedClass);

  // The IMP to install for `selector` on a JS-extended class: a JS-implemented
  // -dealloc replaces the hook above, so it reports the death itself once the
  // JS method returns; the receiver it runs with reads the object's JS state.
  // `imp` unchanged for any other selector, or unless the mode is canary.
  static IMP WrapDealloc(SEL selector, IMP imp);

  // Installs `kind`'s handlers on an ObjC instance template. No-op for kNone,
  // or unless the mode is canary. Only canaries need them: other wrappers would
  // pay for every write and gain nothing.
  static void ConfigureInstanceTemplate(
      v8::Local<v8::ObjectTemplate> instanceTemplate, CanaryKind kind);

  // The kind of canary `object`'s wrapper is, kNone when it is not one.
  static CanaryKind KindOf(id object);

  // The kind a native class constructor's instance template is configured
  // for: under scope "all" its instances are plain canaries. Under "extended"
  // they are canaries only when the constructor yields an instance of a
  // JS-extended class (an existing object adopted from a pointer, or one an
  // initializer returned instead), which ArgConverter::ConstructObject wraps
  // anew, as it does any result whose kind differs from the template's.
  static CanaryKind NativeInstancesKind();

  // Adds `unwrap` (a canary's native object -> its weak-collection key),
  // `wrap` (key -> live or new canary, or undefined once the object is gone)
  // and `cache` (the Uint32Array that tells the builtin when a wrapper it
  // cached from wrap is stale) to `binding`, for the weak-collections builtin.
  // Canary mode only.
  static bool RegisterWrapFunctions(v8::Local<v8::Context> context,
                                    v8::Local<v8::Object> binding);

  // Before `canary`'s native object is released through
  // __releaseNativeCounterpart: marks the canary's record released, so the
  // weak collections hand out no wrapper of the object until native code
  // returns it, and copies the object's weak-collection key onto the canary,
  // so what was keyed on the object is still found through the released
  // canary. With no key to copy, the canary is marked so that weak collections
  // report it as a released-object access. A forwarding canary also gets the
  // state's properties copied onto it: once released, its handlers no longer
  // reach the state.
  static void KeepWeakCollectionKey(v8::Isolate* isolate,
                                    v8::Local<v8::Object> canary);

  // Takes a collected or released canary's reference to its record. A record
  // that died under that canary kept its state for it (it is the forwarding
  // canary's only copy), which can go now. Isolate thread.
  static void DropRecord(v8::Isolate* isolate,
                         std::shared_ptr<CanaryRecord> record);

  // The record of an object that already has state in this isolate, for a new
  // canary to adopt; it is no longer released. Null otherwise.
  static std::shared_ptr<CanaryRecord> Find(v8::Isolate* isolate, id object);

  // Whether `kind`'s canaries carry the forwarding handlers.
  static bool Forwards(CanaryKind kind);

  // Copies the state of a new canary's object, or of a -dealloc receiver's,
  // onto that wrapper of kind `kind`. No-op without state, for a forwarding
  // kind, or unless the mode is canary.
  static void Hydrate(v8::Isolate* isolate, v8::Local<v8::Object> wrapper,
                      CanaryKind kind);

  // Teardown: lets go of every state object while the isolate is alive. Tokens
  // that outlive the isolate find the registry closed.
  static void CloseForTeardown(v8::Isolate* isolate);

  // Calls `visit` with each live object that has state in this isolate, and
  // its state object, outside the registry lock. Each object comes retained,
  // and `visit` takes over that reference: its last release can run the
  // object's -dealloc, JS included. Skips objects whose deallocation started
  // and those whose class refuses weak references. The caller provides the
  // HandleScope.
  static void ForEachState(
      v8::Isolate* isolate,
      const std::function<void(id object, v8::Local<v8::Object> state)>& visit);

  // Calls `visit` with every state handle the registry holds: ForEachState's,
  // those of objects being deallocated or deallocated but not yet let go of,
  // and those of dead forwarding records a canary still holds. Isolate thread;
  // the caller provides the HandleScope.
  static void ForEachStateHandle(
      v8::Isolate* isolate,
      const std::function<void(v8::Local<v8::Object> state)>& visit);

  // Lets go of the state of every object known to be deallocated now, rather
  // than on the drain its deallocation posted.
  static void ReleaseDeadStates(v8::Isolate* isolate);
};

}  // namespace tns

#endif /* WrapperLifetimeCanary_h */
