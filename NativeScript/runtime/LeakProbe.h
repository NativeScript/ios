#ifndef LeakProbe_h
#define LeakProbe_h

#include "Common.h"

namespace tns {

// The runtime's side of NativeScriptLeakProbe.framework (LeakProbeSPI.h), the
// JS <-> native cycle finder apps embed in debug builds only. Without the
// framework an isolate has no embedder graph in its heap snapshots and no
// leak-probe triggers, and ns:runtime's findLeakCycles and
// getWrapperClassCounts throw.
class LeakProbe {
 public:
  // Offers the isolate to the framework, when the process has it.
  static void Init(v8::Isolate* isolate);

  // Adds getWrapperClassCounts and findLeakCycles to the ns:runtime binding.
  static bool RegisterFunctions(v8::Local<v8::Context> context,
                                v8::Local<v8::Object> binding);
};

}  // namespace tns

#endif /* LeakProbe_h */
