#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <fstream>
#include <codecvt>
#include <locale>
#include <stdio.h>
#include "Helpers.h"

using namespace v8;

extern "C" void NSLogv(CFStringRef format, va_list args);

Local<String> tns::ToV8String(Isolate* isolate, std::string value) {
    return v8::String::NewFromUtf8(isolate, value.c_str(), NewStringType::kNormal, (int)value.length()).ToLocalChecked();
}

std::string tns::ToString(Isolate* isolate, const Local<Value>& value) {
    if (value.IsEmpty()) {
        return std::string();
    }

    if (value->IsStringObject()) {
        Local<v8::String> obj = value.As<StringObject>()->ValueOf();
        return tns::ToString(isolate, obj);
    }

    v8::String::Utf8Value result(isolate, value);

    const char* val = *result;
    if (val == nullptr) {
        return std::string();
    }

    return std::string(*result);
}

double tns::ToNumber(Isolate* isolate, const Local<Value>& value) {
    double result = NAN;

    if (value.IsEmpty()) {
        return result;
    }

    if (value->IsNumberObject()) {
        result = value.As<NumberObject>()->ValueOf();
    } else if (value->IsNumber()) {
        result = value.As<Number>()->Value();
    } else {
        Local<Number> number;
        Local<Context> context = isolate->GetCurrentContext();
        bool success = value->ToNumber(context).ToLocal(&number);
        if (success) {
            result = number->Value();
        }
    }

    return result;
}

bool tns::ToBool(const Local<Value>& value) {
    bool result = false;

    if (value.IsEmpty()) {
        return result;
    }

    if (value->IsBooleanObject()) {
        result = value.As<BooleanObject>()->ValueOf();
    } else if (value->IsBoolean()) {
        result = value.As<v8::Boolean>()->Value();
    }

    return result;
}

std::vector<uint16_t> tns::ToVector(const std::string& value) {
    std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> convert;
    std::u16string valueu16 = convert.from_bytes(value);

    const uint16_t *begin = reinterpret_cast<uint16_t const*>(valueu16.data());
    const uint16_t *end = reinterpret_cast<uint16_t const*>(valueu16.data() + valueu16.size());
    std::vector<uint16_t> vector(begin, end);
    return vector;
}

std::string tns::ReadText(const std::string& file) {
    std::ifstream ifs(file);
    if (ifs.fail()) {
        assert(false);
    }
    std::string content((std::istreambuf_iterator<char>(ifs)), (std::istreambuf_iterator<char>()));
    return content;
}

uint8_t* tns::ReadBinary(const std::string path, long& length) {
    length = 0;
    std::ifstream ifs(path);
    if (ifs.fail()) {
        return nullptr;
    }

    FILE* file = fopen(path.c_str(), "rb");
    if (!file) {
        return nullptr;
    }

    fseek(file, 0, SEEK_END);
    length = ftell(file);
    rewind(file);

    uint8_t* data = new uint8_t[length];
    fread(data, sizeof(uint8_t), length, file);
    fclose(file);

    return data;
}

bool tns::WriteBinary(const std::string& path, const void* data, long length) {
    FILE* file = fopen(path.c_str(), "wb");
    if (!file) {
        return false;
    }

    size_t writtenBytes = fwrite(data, sizeof(uint8_t), length, file);
    fclose(file);

    return writtenBytes == length;
}

void tns::SetPrivateValue(const Local<Object>& obj, const Local<v8::String>& propName, const Local<Value>& value) {
    Local<Context> context = obj->CreationContext();
    Isolate* isolate = context->GetIsolate();
    Local<Private> privateKey = Private::ForApi(isolate, propName);
    bool success;
    if (!obj->SetPrivate(context, privateKey, value).To(&success) || !success) {
        assert(false);
    }
}

Local<Value> tns::GetPrivateValue(const Local<Object>& obj, const Local<v8::String>& propName) {
    Local<Context> context = obj->CreationContext();
    Isolate* isolate = context->GetIsolate();
    Local<Private> privateKey = Private::ForApi(isolate, propName);

    Maybe<bool> hasPrivate = obj->HasPrivate(context, privateKey);

    assert(!hasPrivate.IsNothing());

    if (!hasPrivate.FromMaybe(false)) {
        return Local<Value>();
    }

    Local<Value> result;
    if (!obj->GetPrivate(context, privateKey).ToLocal(&result)) {
        assert(false);
    }

    return result;
}

void tns::SetValue(Isolate* isolate, const Local<Object>& obj, BaseDataWrapper* value) {
    if (obj.IsEmpty() || obj->IsNullOrUndefined()) {
        return;
    }

    Local<External> ext = External::New(isolate, value);

    if (obj->InternalFieldCount() > 0) {
        obj->SetInternalField(0, ext);
    } else {
        tns::SetPrivateValue(obj, tns::ToV8String(isolate, "metadata"), ext);
    }
}

tns::BaseDataWrapper* tns::GetValue(Isolate* isolate, const Local<Value>& val) {
    if (val.IsEmpty() || val->IsNullOrUndefined() || !val->IsObject()) {
        return nullptr;
    }

    Local<Object> obj = val.As<Object>();
    if (obj->InternalFieldCount() > 0) {
        Local<Value> field = obj->GetInternalField(0);
        if (field.IsEmpty() || field->IsNullOrUndefined() || !field->IsExternal()) {
            return nullptr;
        }

        return static_cast<BaseDataWrapper*>(field.As<External>()->Value());
    }

    Local<Value> metadataProp = tns::GetPrivateValue(obj, tns::ToV8String(isolate, "metadata"));
    if (metadataProp.IsEmpty() || metadataProp->IsNullOrUndefined() || !metadataProp->IsExternal()) {
        return nullptr;
    }

    return static_cast<BaseDataWrapper*>(metadataProp.As<External>()->Value());
}

std::vector<Local<Value>> tns::ArgsToVector(const FunctionCallbackInfo<Value>& info) {
    std::vector<Local<Value>> args;
    for (int i = 0; i < info.Length(); i++) {
        args.push_back(info[i]);
    }
    return args;
}

void tns::ThrowError(Isolate* isolate, std::string message) {
    // The Isolate::Scope here is necessary because the Exception::Error method internally relies on the
    // Isolate::GetCurrent method which might return null if we do not use the proper scope
    Isolate::Scope scope(isolate);

    Local<v8::String> errorMessage = tns::ToV8String(isolate, message);
    Local<Value> error = Exception::Error(errorMessage);
    isolate->ThrowException(error);
}


bool tns::IsString(Local<Value> value) {
    return !value.IsEmpty() && (value->IsString() || value->IsStringObject());
}

bool tns::IsNumber(Local<Value> value) {
    return !value.IsEmpty() && (value->IsNumber() || value->IsNumberObject());
}

bool tns::IsBool(Local<Value> value) {
    return !value.IsEmpty() && (value->IsBoolean() || value->IsBooleanObject());
}

void tns::ExecuteOnMainThread(std::function<void ()> func, bool async) {
    if (async) {
        dispatch_async(dispatch_get_main_queue(), ^(void) {
            func();
        });
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^(void) {
            func();
        });
    }
}

void tns::Log(Isolate* isolate, TryCatch& tc) {
    if (!tc.HasCaught()) {
        return;
    }

    Local<Value> exception = tc.Exception();
    std::string exceptionString = tns::ToString(isolate, exception);
    tns::Log("%s", exceptionString.c_str());

    Local<Context> context = isolate->GetCurrentContext();
    Local<Value> stack;
    bool success = tc.StackTrace(context).ToLocal(&stack);
    if (!success || stack.IsEmpty()) {
        return;
    }

    Local<v8::String> stackV8Str;
    success = stack->ToDetailString(context).ToLocal(&stackV8Str);
    if (!success || stackV8Str.IsEmpty()) {
        return;
    }

    std::string stackStr = tns::ToString(isolate, stackV8Str);
    tns::Log("%s", stackStr.c_str());
}

void tns::Log(const char* format, ...) {
    va_list vargs;
    va_start(vargs, format);
    CFStringRef formatStr = CFStringCreateWithCString(kCFAllocatorDefault, format, kCFStringEncodingUTF8);
    NSLogv(formatStr, vargs);
    va_end(vargs);
    CFRelease(formatStr);
}
