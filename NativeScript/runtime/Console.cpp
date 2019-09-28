#include "Console.h"
#include "Caches.h"
#include <chrono>
#include <iomanip>
#include "Helpers.h"
#include "RuntimeConfig.h"
#include "v8-log-agent-impl.h"

using namespace v8;

namespace tns {

void Console::Init(Isolate* isolate) {
    Local<Context> context = isolate->GetCurrentContext();
    Context::Scope context_scope(context);
    Local<Object> console = Object::New(isolate);
    bool success = console->SetPrototype(context, Object::New(isolate)).FromMaybe(false);
    assert(success);

    Console::AttachLogFunction(isolate, console, "log");
    Console::AttachLogFunction(isolate, console, "info");
    Console::AttachLogFunction(isolate, console, "error");
    Console::AttachLogFunction(isolate, console, "warn");
    Console::AttachLogFunction(isolate, console, "trace");
    Console::AttachLogFunction(isolate, console, "time", TimeCallback);
    Console::AttachLogFunction(isolate, console, "timeEnd", TimeEndCallback);

    Local<Object> global = context->Global();
    PropertyAttribute readOnlyFlags = static_cast<PropertyAttribute>(PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
    if (!global->DefineOwnProperty(context, tns::ToV8String(isolate, "console"), console, readOnlyFlags).FromMaybe(false)) {
        assert(false);
    }
}

void Console::LogCallback(const FunctionCallbackInfo<Value>& args) {
    if (!RuntimeConfig.IsDebug) {
        // Filter console.log statements in release builds
        return;
    }

    Isolate* isolate = args.GetIsolate();
    std::string stringResult = BuildStringFromArgs(isolate, args);

    Local<v8::String> data = args.Data().As<v8::String>();
    std::string verbosityLevel = tns::ToString(isolate, data);
    std::string verbosityLevelUpper = verbosityLevel;
    std::transform(verbosityLevelUpper.begin(), verbosityLevelUpper.end(), verbosityLevelUpper.begin(), ::toupper);

    std::stringstream ss;
    ss << "CONSOLE " << verbosityLevelUpper << ": " << stringResult;

    if (verbosityLevel == "trace") {
        std::string stacktrace = tns::GetStackTrace(isolate);
        ss << std::endl << stacktrace << std::endl;
    }

    std::string msgToLog = ss.str();

    v8_inspector::V8LogAgentImpl::EntryAdded(msgToLog, "info", "", 0);
    tns::Log("%s", msgToLog.c_str());
}

void Console::TimeCallback(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();
    std::string label = "default";

    Local<v8::String> labelString;
    if (args.Length() > 0 && args[0]->ToString(context).ToLocal(&labelString)) {
        label = tns::ToString(isolate, labelString);
    }

    Caches* cache = Caches::Get(isolate);

    auto nano = std::chrono::time_point_cast<std::chrono::milliseconds>(std::chrono::system_clock::now());
    double timeStamp = nano.time_since_epoch().count();

    cache->Timers.insert(std::make_pair(label, timeStamp));
}

void Console::TimeEndCallback(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();
    std::string label = "default";

    Local<v8::String> labelString;
    if (args.Length() > 0 && args[0]->ToString(context).ToLocal(&labelString)) {
        label = tns::ToString(isolate, labelString);
    }

    Caches* cache = Caches::Get(isolate);
    auto itTimersMap = cache->Timers.find(label);
    if (itTimersMap == cache->Timers.end()) {
        std::string warning = std::string("No such label '" + label + "' for console.timeEnd()");
        tns::Log("%s", warning.c_str());
        return;
    }

    auto nano = std::chrono::time_point_cast<std::chrono::milliseconds>(std::chrono::system_clock::now());
    double endTimeStamp = nano.time_since_epoch().count();
    double startTimeStamp = itTimersMap->second;

    cache->Timers.erase(label);

    auto diff = endTimeStamp - startTimeStamp;

    std::stringstream ss;
    ss << label << ": " << std::fixed << std::setprecision(2) << diff << "ms" ;
    std::string log = ss.str();
    tns::Log("%s", log.c_str());
}

void Console::AttachLogFunction(Isolate* isolate, Local<Object> console, const std::string name, v8::FunctionCallback callback) {
    Local<Context> context = isolate->GetCurrentContext();

    Local<v8::Function> func;
    if (!Function::New(context, callback, tns::ToV8String(isolate, name), 0, ConstructorBehavior::kThrow).ToLocal(&func)) {
        assert(false);
    }

    Local<v8::String> logFuncName = tns::ToV8String(isolate, name);
    func->SetName(logFuncName);
    if (!console->CreateDataProperty(context, logFuncName, func).FromMaybe(false)) {
        assert(false);
    }
}

std::string Console::BuildStringFromArgs(Isolate* isolate, const FunctionCallbackInfo<Value>& args) {
    int argLen = args.Length();
    std::stringstream ss;

    if (argLen > 0) {
        for (int i = 0; i < argLen; i++) {
            Local<v8::String> argString;

            argString = BuildStringFromArg(isolate, args[i]);

            // separate args with a space
            if (i != 0) {
                ss << " ";
            }

            ss << tns::ToString(isolate, argString);
        }
    } else {
        ss << std::endl;
    }

    std::string stringResult = ss.str();
    return stringResult;
}

const Local<v8::String> Console::BuildStringFromArg(Isolate* isolate, const Local<Value>& val) {
    Local<Context> context = isolate->GetCurrentContext();
    Local<v8::String> argString;
    if (val->IsFunction()) {
        bool success = val->ToDetailString(context).ToLocal(&argString);
        assert(success);
    } else if (val->IsArray()) {
        Local<Value> cachedSelf = val;
        Local<Object> array = val->ToObject(context).ToLocalChecked();
        Local<v8::Array> arrayEntryKeys = array->GetPropertyNames(context).ToLocalChecked();

        uint32_t arrayLength = arrayEntryKeys->Length();

        argString = tns::ToV8String(isolate, "[");

        for (int i = 0; i < arrayLength; i++) {
            Local<Value> propertyName = arrayEntryKeys->Get(context, i).ToLocalChecked();

            Local<Value> propertyValue = array->Get(context, propertyName).ToLocalChecked();

            // avoid bottomless recursion with cyclic reference to the same array
            if (propertyValue->StrictEquals(cachedSelf)) {
                argString = v8::String::Concat(isolate, argString, tns::ToV8String(isolate, "[Circular]"));
                continue;
            }

            Local<v8::String> objectString = BuildStringFromArg(isolate, propertyValue);

            argString = v8::String::Concat(isolate, argString, objectString);

            if (i != arrayLength - 1) {
                argString = v8::String::Concat(isolate, argString, tns::ToV8String(isolate, ", "));
            }
        }

        argString = v8::String::Concat(isolate, argString, tns::ToV8String(isolate, "]"));
    } else if (val->IsObject()) {
        Local<Object> obj = val.As<Object>();

        argString = TransformJSObject(isolate, obj);
    } else {
        bool success = val->ToDetailString(isolate->GetCurrentContext()).ToLocal(&argString);
        assert(success);
    }

    return argString;
}

const Local<v8::String> Console::TransformJSObject(Isolate* isolate, Local<Object> object) {
    Local<Context> context = isolate->GetCurrentContext();
    Local<v8::String> objToString = object->ToString(context).ToLocalChecked();
    Local<v8::String> resultString;

    bool hasCustomToStringImplementation = tns::ToString(isolate, objToString).find("[object Object]") == std::string::npos;

    if (hasCustomToStringImplementation) {
        resultString = objToString;
    } else {
        resultString = tns::JsonStringifyObject(isolate, object);
    }

    return resultString;
}

}
