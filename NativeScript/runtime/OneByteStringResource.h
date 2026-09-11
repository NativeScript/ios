#ifndef OneByteStringResource_h
#define OneByteStringResource_h

#include "Common.h"

namespace tns {

class OneByteStringResource : public v8::String::ExternalOneByteStringResource {
public:
    OneByteStringResource(const char* data, size_t length);
    ~OneByteStringResource() override;
    const char* data() const override;
    size_t length() const override;

    // Whether this runtime created the resource. Only such resources are known
    // to hold NUL-terminated UTF-8; V8's contract makes a foreign resource
    // Latin-1 with no terminator guarantee.
    static bool Owns(const v8::String::ExternalOneByteStringResource* resource);

   private:
    const char* data_;
    size_t length_;
};

}

#endif /* OneByteStringResource_h */
