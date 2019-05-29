#include <fstream>
#include "Helpers.h"

using namespace v8;

Local<String> tns::ToV8String(Isolate* isolate, std::string value) {
    return String::NewFromUtf8(isolate, value.c_str(), NewStringType::kNormal).ToLocalChecked();
}

std::string tns::ToString(Isolate* isolate, const Local<Value>& value) {
    if (value.IsEmpty()) {
        return std::string();
    }

    String::Utf8Value result(isolate, value);

    const char* val = *result;
    if (val == nullptr) {
        return std::string();
    }

    return std::string(*result);
}

std::string tns::ReadText(const std::string& file) {
    std::ifstream ifs(file);
    if (ifs.fail()) {
        assert(false);
    }
    std::string content((std::istreambuf_iterator<char>(ifs)), (std::istreambuf_iterator<char>()));
    return content;
}

void tns::SetPrivateValue(Isolate* isolate, const Local<Object>& obj, const Local<String>& propName, const Local<Value>& value) {
    Local<Private> privateKey = Private::ForApi(isolate, propName);
    bool success;
    if (!obj->SetPrivate(isolate->GetCurrentContext(), privateKey, value).To(&success) || !success) {
        assert(false);
    }
}

Local<Value> tns::GetPrivateValue(Isolate* isolate, const Local<Object>& obj, const Local<String>& propName) {
    Local<Private> privateKey = Private::ForApi(isolate, propName);

    Maybe<bool> hasPrivate = obj->HasPrivate(isolate->GetCurrentContext(), privateKey);

    assert(!hasPrivate.IsNothing());

    if (!hasPrivate.FromMaybe(false)) {
        return Local<Value>();
    }

    Local<Value> result;
    if (!obj->GetPrivate(isolate->GetCurrentContext(), privateKey).ToLocal(&result)) {
        assert(false);
    }

    return result;
}
