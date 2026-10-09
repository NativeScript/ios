#include "OneByteStringResource.h"

#include <cstdlib>
#include <mutex>
#include <unordered_set>

using namespace v8;

namespace {

std::mutex registryMutex;

std::unordered_set<const void*>& Registry() {
  static auto* registry = new std::unordered_set<const void*>();
  return *registry;
}

}  // namespace

namespace tns {

OneByteStringResource::OneByteStringResource(const char* data, size_t length):
    data_(data), length_(length) {
  std::lock_guard<std::mutex> lock(registryMutex);
  Registry().insert(this);
}

OneByteStringResource::~OneByteStringResource() {
  {
    std::lock_guard<std::mutex> lock(registryMutex);
    Registry().erase(this);
  }
  // data_ comes from strdup (see Interop::WriteValue's CStringEncoding path).
  std::free(const_cast<char*>(this->data_));
}

const char* OneByteStringResource::data() const {
    return this->data_;
}

size_t OneByteStringResource::length() const {
    return this->length_;
}

bool OneByteStringResource::Owns(
    const v8::String::ExternalOneByteStringResource* resource) {
  std::lock_guard<std::mutex> lock(registryMutex);
  return Registry().count(resource) != 0;
}
}
