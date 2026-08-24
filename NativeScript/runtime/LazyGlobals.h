#ifndef LazyGlobals_h
#define LazyGlobals_h

#include <string>

#include "Common.h"

namespace tns {

// Globals whose implementation is a runtime builtin that must not run until
// someone actually reaches for the name. Each entry is registered on the
// global template as a lazy data property; the first read runs the builtin
// through the per-isolate exports cache (BuiltinLoader::GetExports), so sibling
// names (TextEncoder and TextDecoder) share the run — as does a module
// exporting the same interfaces — and V8 then replaces the property with a
// plain data property so later reads cost nothing.
//
// A builtin behind this tier runs at an arbitrary point in the isolate's life
// rather than during init, so it may only consume `internals` keys published
// by eager builtins (see NativeScript/runtime/js/README.md).
class LazyGlobals {
 public:
  // Registers every lazy global. Must run before Context::New, on the same
  // template the eager globals use.
  static void Init(v8::Isolate* isolate,
                   v8::Local<v8::ObjectTemplate> globalTemplate);

  // Whether `name` is one of this tier's globals. The global named-property
  // interceptor declines these so an ObjC metadata symbol sharing a name can
  // never resolve ahead of the runtime's own global.
  static bool IsLazyGlobal(const std::string& name);
};

}  // namespace tns

#endif /* LazyGlobals_h */
