#ifndef utils_h
#define utils_h

#include "include/v8-inspector.h"
#include "src/inspector/protocol/Protocol.h"
#include <vector>

namespace v8_inspector {

std::string GetMIMEType(std::string filePath);
std::string ToStdString(const v8_inspector::StringView& value);
v8::Local<v8::Function> GetDebuggerFunction(v8::Isolate* isolate, std::string domain, std::string functionName, v8::Local<v8::Object>& domainDebugger);

template<typename T>
static std::unique_ptr<protocol::Array<T>> fromValue(protocol::Value* value, protocol::ErrorSupport* errors) {
    protocol::ListValue* array = protocol::ListValue::cast(value);
    if (!array) {
        errors->addError("array expected");
        return nullptr;
    }

    std::unique_ptr<protocol::Array<T>> result(new protocol::Array<T>());
    errors->push();
    for (size_t i = 0; i < array->size(); ++i) {
        errors->setName(protocol::StringUtil::fromInteger(i));
        std::unique_ptr<T> item = protocol::ValueConversions<T>::fromValue(array->at(i), errors);
        result->push_back(std::move(item));
    }

    errors->pop();
    if (errors->hasErrors()) {
        return nullptr;
    }

    return result;
}

class NetworkRequestData {
public:
    NetworkRequestData(std::u16string data, bool hasTextContent): data_(data), hasTextContent_(hasTextContent) {
    }

    const char16_t* GetData() {
        return this->data_.data();
    }

    const bool HasTextContent() {
        return this->hasTextContent_;
    }
private:
    std::u16string data_;
    bool hasTextContent_;
};

}

#endif /* utils_h */
