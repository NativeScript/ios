#ifndef Events_h
#define Events_h

#include "Common.h"

namespace tns {

class Events {
 public:
  // Installs the generic WHATWG event primitives: the Event and EventTarget
  // constructors on globalThis, the EventTarget methods (addEventListener /
  // removeEventListener / dispatchEvent) bound onto globalThis, and the
  // internal EventTarget instance backing the global. Evaluated once per
  // isolate during Runtime::Init, right after PromiseProxy::Init and before
  // ErrorEvents::Init, for both main and worker isolates. Stashes the backing
  // target in Caches->GlobalEventTarget so native layers can dispatch without
  // going through overwritable globals.
  static void Init(v8::Local<v8::Context> context);
};

}  // namespace tns

#endif /* Events_h */
