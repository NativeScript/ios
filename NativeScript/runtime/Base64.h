#ifndef Base64_h
#define Base64_h

#include "Common.h"

namespace tns {

// Native ops behind the base64 builtin (internal/base64.js): the WHATWG
// forgiving-base64 codec backing the atob / btoa globals. Both ops answer
// null instead of throwing, so the builtin owns the error shape.
class Base64 {
 public:
  static v8::Local<v8::Object> CreateBinding(v8::Local<v8::Context> context);
};

}  // namespace tns

#endif /* Base64_h */
