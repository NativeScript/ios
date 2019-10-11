#include <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <execinfo.h>
#include <fstream>
#include <codecvt>
#include <locale>
#include <stdio.h>
#include <sstream>
#include <dlfcn.h>
#include <cxxabi.h>
#include "RuntimeConfig.h"
#include "Helpers.h"

using namespace v8;

static std::map<Isolate*, Persistent<v8::Function>*> isolateToPersistentSmartJSONStringify = std::map<Isolate*, Persistent<v8::Function>*>();

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

std::u16string tns::ToUtf16String(Isolate* isolate, const Local<Value>& value) {
    std::string valueStr = tns::ToString(isolate, value);
    std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> convert;
    std::u16string value16 = convert.from_bytes(valueStr);

    return value16;
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
    std::u16string value16 = convert.from_bytes(value);

    const uint16_t *begin = reinterpret_cast<uint16_t const*>(value16.data());
    const uint16_t *end = reinterpret_cast<uint16_t const*>(value16.data() + value16.size());
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

void tns::LogError(Isolate* isolate, TryCatch& tc) {
    if (!tc.HasCaught()) {
        return;
    }

    Log(@"Native stack trace:");
    LogBacktrace();

    Local<Value> stack;
    Local<Context> context = isolate->GetCurrentContext();
    bool success = tc.StackTrace(context).ToLocal(&stack);
    if (!success || stack.IsEmpty()) {
        return;
    }

    Local<v8::String> stackV8Str;
    success = stack->ToDetailString(context).ToLocal(&stackV8Str);
    if (!success || stackV8Str.IsEmpty()) {
        return;
    }

    std::string stackTraceStr = tns::ToString(isolate, stackV8Str);
    stackTraceStr = ReplaceAll(stackTraceStr, RuntimeConfig.BaseDir, "");

    Log(@"JavaScript error:");
    Log(@"%s", stackTraceStr.c_str());
}

Local<v8::String> tns::JsonStringifyObject(Isolate* isolate, Local<Value> value, bool handleCircularReferences) {
    if (value.IsEmpty()) {
        return v8::String::Empty(isolate);
    }

    Local<Context> context = isolate->GetCurrentContext();
    if (handleCircularReferences) {
        Local<v8::Function> smartJSONStringifyFunction = tns::GetSmartJSONStringifyFunction(isolate);

        if (!smartJSONStringifyFunction.IsEmpty()) {
            if (value->IsObject()) {
                Local<Value> resultValue;
                TryCatch tc(isolate);

                Local<Value> args[] = {
                    value->ToObject(context).ToLocalChecked()
                };
                bool success = smartJSONStringifyFunction->Call(context, v8::Undefined(isolate), 1, args).ToLocal(&resultValue);

                if (success && !tc.HasCaught()) {
                    return resultValue->ToString(context).ToLocalChecked();
                }
            }
        }
    }

    Local<v8::String> resultString;
    TryCatch tc(isolate);
    bool success = v8::JSON::Stringify(context, value->ToObject(context).ToLocalChecked()).ToLocal(&resultString);

    if (!success && tc.HasCaught()) {
        tns::LogError(isolate, tc);
        return Local<v8::String>();
    }

    return resultString;
}

Local<v8::Function> tns::GetSmartJSONStringifyFunction(Isolate* isolate) {
    auto it = isolateToPersistentSmartJSONStringify.find(isolate);
    if (it != isolateToPersistentSmartJSONStringify.end()) {
        auto smartStringifyPersistentFunction = it->second;

        return smartStringifyPersistentFunction->Get(isolate);
    }

    std::string smartStringifyFunctionScript =
        "(function () {\n"
        "    function smartStringify(object) {\n"
        "        const seen = [];\n"
        "        var replacer = function (key, value) {\n"
        "            if (value != null && typeof value == \"object\") {\n"
        "                if (seen.indexOf(value) >= 0) {\n"
        "                    if (key) {\n"
        "                        return \"[Circular]\";\n"
        "                    }\n"
        "                    return;\n"
        "                }\n"
        "                seen.push(value);\n"
        "            }\n"
        "            return value;\n"
        "        };\n"
        "        return JSON.stringify(object, replacer, 2);\n"
        "    }\n"
        "    return smartStringify;\n"
        "})();";

    Local<v8::String> source = tns::ToV8String(isolate, smartStringifyFunctionScript);
    Local<Context> context = isolate->GetCurrentContext();

    Local<Script> script;
    bool success = Script::Compile(context, source).ToLocal(&script);
    assert(success);

    if (script.IsEmpty()) {
        return Local<v8::Function>();
    }

    Local<Value> result;
    success = script->Run(context).ToLocal(&result);
    assert(success);

    if (result.IsEmpty() && !result->IsFunction()) {
        return Local<v8::Function>();
    }

    Local<v8::Function> smartStringifyFunction = result.As<v8::Function>();

    Persistent<v8::Function>* smartStringifyPersistentFunction = new Persistent<v8::Function>(isolate, smartStringifyFunction);

    isolateToPersistentSmartJSONStringify.insert(std::make_pair(isolate, smartStringifyPersistentFunction));

    return smartStringifyPersistentFunction->Get(isolate);
}

std::string tns::ReplaceAll(const std::string source, std::string find, std::string replacement) {
    std::string result = source;
    size_t pos = result.find(find);
    while (pos != std::string::npos) {
        result.replace(pos, find.size(), replacement);
        pos = result.find(find, pos + replacement.size());
    }

    return result;
}

void tns::LogBacktrace(int skip) {
    void *callstack[128];
    const int nMaxFrames = sizeof(callstack) / sizeof(callstack[0]);
    char buf[1024];
    int nFrames = backtrace(callstack, nMaxFrames);
    char **symbols = backtrace_symbols(callstack, nFrames);

    for (int i = skip; i < nFrames; i++) {
        Dl_info info;
        if (dladdr(callstack[i], &info) && info.dli_sname) {
            char *demangled = NULL;
            int status = -1;
            if (info.dli_sname[0] == '_') {
                demangled = abi::__cxa_demangle(info.dli_sname, NULL, 0, &status);
            }
            snprintf(buf,
                     sizeof(buf),
                     "%-3d %*p %s + %zd\n",
                     i,
                     int(2 + sizeof(void*) * 2),
                     callstack[i],
                     status == 0 ? demangled : info.dli_sname == 0 ? symbols[i] : info.dli_sname,
                     (char *)callstack[i] - (char *)info.dli_saddr);
            free(demangled);
        } else {
            snprintf(buf, sizeof(buf), "%-3d %*p %s\n", i, int(2 + sizeof(void*) * 2), callstack[i], symbols[i]);
        }
        Log(@"%s", buf);
    }
    free(symbols);
    if (nFrames == nMaxFrames) {
        Log(@"[truncated]");
    }
}

const std::string tns::GetStackTrace(Isolate* isolate) {
    Local<StackTrace> stack = StackTrace::CurrentStackTrace(isolate, 10, StackTrace::StackTraceOptions::kDetailed);
    int framesCount = stack->GetFrameCount();
    std::stringstream ss;
    for (int i = 0; i < framesCount; i++) {
        Local<StackFrame> frame = stack->GetFrame(isolate, i);
        ss << BuildStacktraceFrameMessage(isolate, frame) << std::endl;
    }
    return ss.str();
}

const std::string tns::GetCurrentScriptUrl(Isolate* isolate) {
    Local<StackTrace> stack = StackTrace::CurrentStackTrace(isolate, 1, StackTrace::StackTraceOptions::kDetailed);
    int framesCount = stack->GetFrameCount();
    if (framesCount > 0) {
        Local<StackFrame> frame = stack->GetFrame(isolate, 0);
        return tns::BuildStacktraceFrameLocationPart(isolate, frame);
    }

    return "";
}

const std::string tns::BuildStacktraceFrameLocationPart(Isolate* isolate, Local<StackFrame> frame) {
    std::stringstream ss;

    Local<v8::String> scriptName = frame->GetScriptNameOrSourceURL();
    std::string scriptNameStr = tns::ToString(isolate, scriptName);
    scriptNameStr = tns::ReplaceAll(scriptNameStr, RuntimeConfig.BaseDir, "");

    if (scriptNameStr.length() < 1) {
        ss << "VM";
    } else {
        ss << scriptNameStr << ":" << frame->GetLineNumber() << ":" << frame->GetColumn();
    }

    std::string stringResult = ss.str();

    return stringResult;
}

const std::string tns::BuildStacktraceFrameMessage(Isolate* isolate, Local<StackFrame> frame) {
    std::stringstream ss;

    Local<v8::String> functionName = frame->GetFunctionName();
    std::string functionNameStr = tns::ToString(isolate, functionName);
    if (functionNameStr.empty()) {
        functionNameStr = "<anonymous>";
    }

    if (frame->IsConstructor()) {
        ss << "at new " << functionNameStr << " (" << tns::BuildStacktraceFrameLocationPart(isolate, frame) << ")";
    } else if (frame->IsEval()) {
        ss << "eval at " << BuildStacktraceFrameLocationPart(isolate, frame) << std::endl;
    } else {
        ss << "at " << functionNameStr << " (" << tns::BuildStacktraceFrameLocationPart(isolate, frame) << ")";
    }

    std::string stringResult = ss.str();

    return stringResult;
}

bool tns::LiveSync(Isolate* isolate) {
    HandleScope scope(isolate);
    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> global = context->Global();
    Local<Value> value;
    bool success = global->Get(context, tns::ToV8String(isolate, "__onLiveSync")).ToLocal(&value);
    if (!success || value.IsEmpty() || !value->IsFunction()) {
        return false;
    }

    Local<v8::Function> liveSyncFunc = value.As<v8::Function>();
    Local<Value> args[0];
    Local<Value> result;

    TryCatch tc(isolate);
    success = liveSyncFunc->Call(context, v8::Undefined(isolate), 0, args).ToLocal(&result);
    if (!success || tc.HasCaught()) {
        if (tc.HasCaught()) {
            tns::LogError(isolate, tc);
        }
        return false;
    }

    return true;
}
