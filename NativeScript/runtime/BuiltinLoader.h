#ifndef BuiltinLoader_h
#define BuiltinLoader_h

#include "Common.h"
#include "RuntimeBuiltins.h"

namespace tns {

class BuiltinLoader {
 public:
  // Compiles and runs the builtin script identified by id in the given context
  // and returns its completion value. Scripts carry an "internal/<name>.js"
  // origin so runtime frames are identifiable in stack traces. Compilation goes
  // through a process-wide bytecode cache: the first run in the process
  // compiles eagerly and populates the cache, later isolates (workers) consume
  // it instead of re-parsing the source.
  static v8::MaybeLocal<v8::Value> RunBuiltin(v8::Local<v8::Context> context,
                                              BuiltinId id);
};

}  // namespace tns

#endif /* BuiltinLoader_h */
