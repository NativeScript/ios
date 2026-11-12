#ifndef WrapperLifetimeCanary_h
#define WrapperLifetimeCanary_h

#include <memory>
#include "Common.h"

namespace tns {

struct CanaryRecord;

// The canary wrapper lifetime mode (WrapperLifetimeMode::kCanary).
//
// An ObjC object's wrapper is a canary: a phantom-weak JS object that dies
// with its JS references, releasing the runtime's retain on the object. JS
// properties set on a canary are forwarded by kNonMasking named interceptors
// to a state object, so prototype members (native methods and properties,
// JS-extended class methods) never reach these handlers. A canary built later
// for the same object forwards to the same state.
//
// The state object is rooted from its first write until the native object is
// deallocated (an associated token's -dealloc reports it). It cannot be rooted
// only once the canary dies instead: a state reachable only through the canary
// is garbage in the same collection, before any phantom callback runs. The
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

  // Installs the forwarding handlers on an ObjC instance template. No-op unless
  // the mode is canary.
  static void ConfigureInstanceTemplate(v8::Local<v8::ObjectTemplate> instanceTemplate);

  // The record of an object that already has state in this isolate, for a new
  // canary to share. Null otherwise.
  static std::shared_ptr<CanaryRecord> Find(v8::Isolate* isolate, id object);

  // Teardown: lets go of every state object while the isolate is alive. Tokens
  // that outlive the isolate find the registry closed.
  static void CloseForTeardown(v8::Isolate* isolate);
};

}  // namespace tns

#endif /* WrapperLifetimeCanary_h */
