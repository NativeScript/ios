#ifndef Strings_h
#define Strings_h

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include "v8.h"
#pragma clang diagnostic pop

#include <string>

namespace tns {

class Strings {
public:
    static v8::Local<v8::String> ToV8String(v8::Isolate* isolate, std::string value);
    static std::string ToString(v8::Isolate* isolate, const v8::Local<v8::Value>& value);
};

}

#endif /* Strings_h */
