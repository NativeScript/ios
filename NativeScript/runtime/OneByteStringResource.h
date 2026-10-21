#ifndef OneByteStringResource_h
#define OneByteStringResource_h

#include "Common.h"

namespace tns {

// A NUL-terminated UTF-8 copy of a JS string, stored in the same allocation as
// the resource. V8 releases it through Dispose(), never through delete.
class OneByteStringResource final
    : public v8::String::ExternalOneByteStringResource {
 public:
  static OneByteStringResource* NewUtf8Copy(v8::Isolate* isolate,
                                            v8::Local<v8::String> str);

  const char* data() const override;
  // The UTF-8 byte count plus the NUL, so it is never zero: V8 disposes a
  // zero-length resource as soon as it is handed one.
  size_t length() const override;

 protected:
  void Dispose() override;

 private:
  explicit OneByteStringResource(size_t length);
  ~OneByteStringResource() override = default;

  size_t length_;
};
}

#endif /* OneByteStringResource_h */
