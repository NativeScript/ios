#ifndef Helpers_h
#define Helpers_h

#include <string>
#include "Common.h"
#include "DataWrapper.h"

namespace tns {

v8::Local<v8::String> ToV8String(v8::Isolate* isolate, std::string value);
std::string ToString(v8::Isolate* isolate, const v8::Local<v8::Value>& value);
double ToNumber(const v8::Local<v8::Value>& value);
bool ToBool(const v8::Local<v8::Value>& value);

std::string ReadText(const std::string& file);

void SetPrivateValue(v8::Isolate* isolate, const v8::Local<v8::Object>& obj, const v8::Local<v8::String>& propName, const v8::Local<v8::Value>& value);
v8::Local<v8::Value> GetPrivateValue(v8::Isolate* isolate, const v8::Local<v8::Object>& obj, const v8::Local<v8::String>& propName);

void SetValue(v8::Isolate* isolate, const v8::Local<v8::Object>& obj, BaseDataWrapper* value);
BaseDataWrapper* GetValue(v8::Isolate* isolate, const v8::Local<v8::Value>& val);

void ThrowError(v8::Isolate* isolate, std::string message);

bool IsString(v8::Local<v8::Value> value);
bool IsNumber(v8::Local<v8::Value> value);
bool IsBool(v8::Local<v8::Value> value);

}

#endif /* Helpers_h */
