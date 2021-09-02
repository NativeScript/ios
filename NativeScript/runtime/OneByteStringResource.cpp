#include "OneByteStringResource.h"

using namespace v8;

namespace tns {

OneByteStringResource::OneByteStringResource(const char* data, size_t length):
    data_(data), length_(length) {
}

OneByteStringResource::~OneByteStringResource() {
    delete this->data_;
}

const char* OneByteStringResource::data() const {
    return this->data_;
}

size_t OneByteStringResource::length() const {
    return this->length_;
}

}
