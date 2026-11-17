#ifndef WrapperLifetimeCanary_h
#define WrapperLifetimeCanary_h

#include <objc/runtime.h>

#include <memory>

#include "Common.h"

namespace tns {

struct CanaryRecord;

// The canary wrapper lifetime mode (WrapperLifetimeMode::kCanary).
//
// An ObjC object's wrapper is a canary: a phantom-weak JS object that dies
// with its JS references, releasing the runtime's retain on the object. A
// masking named interceptor with only a setter, deleter and definer mirrors
// every JS property written to a canary into a state object and then declines,
// so the property also lands on the canary and reads never leave V8. Writes to
// native properties and other inherited accessors are not state. A canary
// built later for the same object gets the state's properties copied back
// (Hydrate). The state object is the source of truth.
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

  // Installs the forwarding handlers on an ObjC instance template. No-op unless
  // the mode is canary. Only canaries need them: other wrappers would pay for
  // every write and gain nothing.
  static void ConfigureInstanceTemplate(
      v8::Local<v8::ObjectTemplate> instanceTemplate);

  // Whether `object`'s wrapper is a canary, so must be built from a template
  // ConfigureInstanceTemplate configured.
  static bool Intercepts(id object);

  // Whether a native class constructor's instance template gets the handlers:
  // under scope "all" its instances are canaries. Under "extended" they are
  // canaries only when the constructor yields an instance of a JS-extended
  // class (an existing object adopted from a pointer, or one an initializer
  // returned instead), which ArgConverter::ConstructObject wraps anew.
  static bool NativeInstancesIntercept();

  // Adds `unwrap` (a canary's native object -> its weak-collection key) and
  // `wrap` (key -> live or new canary, or undefined once the object is gone)
  // to `binding`, for the weak-collections builtin. Canary mode only.
  static bool RegisterWrapFunctions(v8::Local<v8::Context> context,
                                    v8::Local<v8::Object> binding);

  // The record of an object that already has state in this isolate, for a new
  // canary to share. Null otherwise.
  static std::shared_ptr<CanaryRecord> Find(v8::Isolate* isolate, id object);

  // Copies the state of a new canary's object, or of a -dealloc receiver's,
  // onto that wrapper. No-op without state, or unless the mode is canary.
  static void Hydrate(v8::Isolate* isolate, v8::Local<v8::Object> wrapper);

  // Teardown: lets go of every state object while the isolate is alive. Tokens
  // that outlive the isolate find the registry closed.
  static void CloseForTeardown(v8::Isolate* isolate);
};

}  // namespace tns

#endif /* WrapperLifetimeCanary_h */
