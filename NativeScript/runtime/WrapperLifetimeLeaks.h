#ifndef WrapperLifetimeLeaks_h
#define WrapperLifetimeLeaks_h

#include "Common.h"

namespace tns {

// Finds what the wrapper lifetime modes leak: JS <-> native cycles.
//
// Heap snapshots carry both heaps: an embedder graph adds a node per native
// object the runtime wraps or keeps JS state for, and the runtime's own
// cross-heap edges (wrapper -> object retain, rooted-strong object -> wrapper,
// canary object -> state, JS block -> callback). Any snapshot gets these,
// DevTools' included.
//
// findLeakCycles() adds the native objects reachable from those through owning
// references (strong object ivars, collection and block storage) and runs a
// trial deletion: a native object is a root only while its retain count is not
// explained by the graph (the runtime's own retain plus incoming owning edges);
// the global handles that stand for native -> JS edges are not roots. What the
// marking does not reach and that lies on a cycle is reported.
//
// Blind spots: retains made by code without an owning ivar or storage pointer
// (manual retain/release bookkeeping, C++ members, associated objects) read as
// external owners, so their cycles are missed rather than misreported. Pointers
// that do not own (MRC assign ivars, weak storage outside the known weak
// containers) over-explain a retain count; such objects are "uncertain" and
// stay roots unless the probe runs strict.
class WrapperLifetimeLeaks {
 public:
  // Registers the embedder graph; on the main isolate of debug builds, or with
  // "wrapperLifetime": { "leakProbe": true } in the app config, also the
  // memory-warning class counts and the Darwin notification triggers.
  static void Init(v8::Isolate* isolate);

  // Adds getWrapperClassCounts and findLeakCycles to the ns:runtime binding.
  static bool RegisterFunctions(v8::Local<v8::Context> context,
                                v8::Local<v8::Object> binding);
};

}  // namespace tns

#endif /* WrapperLifetimeLeaks_h */
