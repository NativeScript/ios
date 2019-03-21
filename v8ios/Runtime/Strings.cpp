#include "Strings.h"

using namespace v8;
using namespace std;

namespace tns {

    Local<v8::String> Strings::ToV8String(Isolate* isolate, std::string value) {
    return v8::String::NewFromUtf8(isolate, value.c_str(), NewStringType::kNormal).ToLocalChecked();
}

std::string Strings::ToString(Isolate* isolate, const Local<Value>& value) {
    if (value.IsEmpty()) {
        return string();
    }

    v8::String::Utf8Value result(isolate, value);
    return string(*result);
}

}
