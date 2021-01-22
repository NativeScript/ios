#ifndef utils_h
#define utils_h

#include "include/v8-inspector.h"
#include "src/inspector/protocol/Protocol.h"
#include <vector>
#include <cmath>
#include <cstdio>

namespace v8_inspector {

std::string GetMIMEType(std::string filePath);
std::string ToStdString(const v8_inspector::StringView& value);
v8::Local<v8::Function> GetDebuggerFunction(v8::Local<v8::Context> context, std::string domain, std::string functionName, v8::Local<v8::Object>& domainDebugger);
std::string GetDomainMethod(v8::Isolate* isolate, const v8::Local<v8::Object>& arg, std::string domain);

template<typename T>
static std::unique_ptr<protocol::Array<T>> fromValue(protocol::Value* value, protocol::ErrorSupport* errors) {
    protocol::ListValue* array = protocol::ListValue::cast(value);
    if (!array) {
        errors->AddError("array expected");
        return nullptr;
    }

    std::unique_ptr<protocol::Array<T>> result(new protocol::Array<T>());
    errors->Push();
    
    // This (log10) will return the max number of digits(-1) in the length of the array that we have to worry about, +1 for the null
    int sizeArray = log10(array->size()) + 2;
    
    for (size_t i = 0; i < array->size(); ++i) {
	// Convert array index to a string value
	char* name = new char[sizeArray];
	sprintf(name, "%lu", i);
	
        errors->SetName(name);
        std::unique_ptr<T> item = protocol::ValueConversions<T>::fromValue(array->at(i), errors);
        result->push_back(std::move(item));
    }

    errors->Pop();
    if (!errors->Errors().empty()) {
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
