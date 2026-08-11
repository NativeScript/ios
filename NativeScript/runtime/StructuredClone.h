#ifndef StructuredClone_h
#define StructuredClone_h

#include "Common.h"

namespace tns {

class StructuredClone {
 public:
  // Installs the structuredClone global (internal/structured-clone.js). The
  // builtin owns the argument coercion and hands the native side a value plus
  // an already-materialized array of ArrayBuffers to transfer.
  static void Init(v8::Local<v8::Context> context);
};

}  // namespace tns

#endif /* StructuredClone_h */
