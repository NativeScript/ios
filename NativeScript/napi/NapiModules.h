#ifndef NapiModules_h
#define NapiModules_h

#include <string>

#include "runtime/Common.h"

namespace tns {

// The process-global table of Node-API addons registered through
// napi_module_register, and their per-env instantiation. Shaped after
// NsBuiltinModules so require() can consult both the same way.
class NapiModules {
 public:
  static bool IsRegistered(const std::string& name);

  // Returns the addon's exports for the context's env, initializing it on
  // first use and reusing that object afterwards. Empty on failure, with the
  // exception left pending on the isolate.
  static v8::MaybeLocal<v8::Object> GetExports(v8::Local<v8::Context> context,
                                               const std::string& name);
};

}  // namespace tns

#endif /* NapiModules_h */
