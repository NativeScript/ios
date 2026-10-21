#include "OneByteStringResource.h"

#include <cstdlib>
#include <new>

using namespace v8;

namespace tns {

OneByteStringResource* OneByteStringResource::NewUtf8Copy(Isolate* isolate,
                                                          Local<String> str) {
  size_t byteLength = str->Utf8LengthV2(isolate);
  void* block = std::malloc(sizeof(OneByteStringResource) + byteLength + 1);
  OneByteStringResource* resource =
      new (block) OneByteStringResource(byteLength + 1);
  // Same flags as String::Utf8Value.
  str->WriteUtf8V2(isolate, reinterpret_cast<char*>(resource + 1),
                   byteLength + 1,
                   String::WriteFlags::kNullTerminate |
                       String::WriteFlags::kReplaceInvalidUtf8);
  return resource;
}

OneByteStringResource::OneByteStringResource(size_t length) : length_(length) {}

void OneByteStringResource::Dispose() {
  this->~OneByteStringResource();
  std::free(this);
}

const char* OneByteStringResource::data() const {
  return reinterpret_cast<const char*>(this + 1);
}

size_t OneByteStringResource::length() const {
    return this->length_;
}

}
