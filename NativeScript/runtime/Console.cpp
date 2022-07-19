#include "Console.h"
#include "Caches.h"
#include <chrono>
#include <iomanip>
#include "Helpers.h"
#include "RuntimeConfig.h"
#include "v8-log-agent-impl.h"

using namespace v8;

namespace tns {

void Console::Init(Local<Context> context) {
    Isolate* isolate = context->GetIsolate();
    Context::Scope context_scope(context);
    Local<Object> console = Object::New(isolate);
    bool success = console->SetPrototype(context, Object::New(isolate)).FromMaybe(false);
    tns::Assert(success, isolate);

    Console::AttachLogFunction(context, console, "log");
    Console::AttachLogFunction(context, console, "info");
    Console::AttachLogFunction(context, console, "error");
    Console::AttachLogFunction(context, console, "warn");
    Console::AttachLogFunction(context, console, "trace");
    Console::AttachLogFunction(context, console, "assert", AssertCallback);
    Console::AttachLogFunction(context, console, "dir", DirCallback);
    Console::AttachLogFunction(context, console, "time", TimeCallback);
    Console::AttachLogFunction(context, console, "timeEnd", TimeEndCallback);

    Local<Object> global = context->Global();
    PropertyAttribute readOnlyFlags = static_cast<PropertyAttribute>(PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
    if (!global->DefineOwnProperty(context, tns::ToV8String(isolate, "console"), console, readOnlyFlags).FromMaybe(false)) {
        tns::Assert(false, isolate);
    }
}

void Console::LogCallback(const FunctionCallbackInfo<Value>& args) {
    // TODO: implement 'forceLog' override option like android has, to force logs in prod if desired
    if (!RuntimeConfig.LogToSystemConsole) {
        return;
    }

    Isolate* isolate = args.GetIsolate();
    std::string stringResult = BuildStringFromArgs(args);

    Local<v8::String> data = args.Data().As<v8::String>();
    std::string verbosityLevel = tns::ToString(isolate, data);
    std::string verbosityLevelUpper = verbosityLevel;
    std::transform(verbosityLevelUpper.begin(), verbosityLevelUpper.end(), verbosityLevelUpper.begin(), ::toupper);

    std::stringstream ss;
    ss << stringResult;

    if (verbosityLevel == "trace") {
        std::string stacktrace = tns::GetStackTrace(isolate);
        ss << std::endl << stacktrace << std::endl;
    }

    std::string msgToLog = ss.str();

    std::string level = VerbosityToInspectorVerbosity(verbosityLevel);
    v8_inspector::V8LogAgentImpl::EntryAdded(msgToLog, level, "", 0);
    std::string msgWithVerbosity = "CONSOLE " + verbosityLevelUpper + ": " + msgToLog;
    Log("%s", msgToLog.c_str());
}

void Console::AssertCallback(const FunctionCallbackInfo<Value>& args) {
    if (!RuntimeConfig.LogToSystemConsole) {
        return;
    }

    Isolate* isolate = args.GetIsolate();

    int argsLength = args.Length();
    bool expressionPasses = argsLength > 0 && args[0]->BooleanValue(isolate);
    if (!expressionPasses) {
        std::stringstream ss;

        ss << "Assertion failed: ";

        if (argsLength > 1) {
            ss << BuildStringFromArgs(args, 1);
        } else {
            ss << "console.assert";
        }

        std::string log = ss.str();
        v8_inspector::V8LogAgentImpl::EntryAdded(log, "error", "", 0);
        Log("%s", log.c_str());
    }
}

void Console::DirCallback(const FunctionCallbackInfo<Value>& args) {
    if (!RuntimeConfig.LogToSystemConsole) {
        return;
    }

    int argsLen = args.Length();
    Isolate* isolate = args.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();

    std::stringstream ss;
    std::string scriptUrl = tns::GetCurrentScriptUrl(isolate);
    ss << scriptUrl << ":";

    if (argsLen > 0) {
        if (!args[0]->IsObject()) {
            std::string logString = BuildStringFromArgs(args);
            ss << " " << logString;
        } else {
            ss << std::endl << "==== object dump start ====" << std::endl;
            Local<Object> argObject = args[0].As<Object>();

            Local<v8::Array> propNames;
            bool success = argObject->GetPropertyNames(context).ToLocal(&propNames);
            tns::Assert(success, isolate);
            uint32_t propertiesLength = propNames->Length();
            for (uint32_t i = 0; i < propertiesLength; i++) {
                Local<Value> propertyName = propNames->Get(context, i).ToLocalChecked();
                Local<Value> propertyValue;
                bool success = argObject->Get(context, propertyName).ToLocal(&propertyValue);
                if (!success || propertyValue.IsEmpty() || propertyValue->IsUndefined()) {
                    continue;
                }

                bool propIsFunction = propertyValue->IsFunction();

                ss << tns::ToString(isolate, propertyName->ToString(context).ToLocalChecked()) << ": ";

                if (propIsFunction) {
                    ss << "()";
                } else if (propertyValue->IsArray()) {
                    Local<v8::String> stringResult = BuildStringFromArg(context, propertyValue);
                    std::string jsonStringifiedArray = tns::ToString(isolate, stringResult);
                    ss << jsonStringifiedArray;
                } else if (propertyValue->IsObject()) {
                    Local<Object> obj = propertyValue->ToObject(context).ToLocalChecked();
                    Local<v8::String> objString = TransformJSObject(obj);
                    std::string jsonStringifiedObject = tns::ToString(isolate, objString);
                    // if object prints out as the error string for circular references, replace with #CR instead for brevity
                    if (jsonStringifiedObject.find("circular structure") != std::string::npos) {
                        jsonStringifiedObject = "#CR";
                    }
                    ss << jsonStringifiedObject;
                } else {
                    ss << "\"" << tns::ToString(isolate, propertyValue->ToDetailString(context).ToLocalChecked()) << "\"";
                }

                ss << std::endl;
            }

            ss << "==== object dump end ====" << std::endl;
        }
    } else {
        ss << "";
    }

    std::string msgToLog = ss.str();

    Local<v8::String> data = args.Data().As<v8::String>();
    std::string verbosityLevel = tns::ToString(isolate, data);
    std::string level = VerbosityToInspectorVerbosity(verbosityLevel);
    v8_inspector::V8LogAgentImpl::EntryAdded(msgToLog, level, "", 0);
    Log("%s", msgToLog.c_str());
}

void Console::TimeCallback(const FunctionCallbackInfo<Value>& args) {
    if (!RuntimeConfig.LogToSystemConsole) {
        return;
    }

    Isolate* isolate = args.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();
    std::string label = "default";

    Local<v8::String> labelString;
    if (args.Length() > 0 && args[0]->ToString(context).ToLocal(&labelString)) {
        label = tns::ToString(isolate, labelString);
    }

    std::shared_ptr<Caches> cache = Caches::Get(isolate);

    auto nano = std::chrono::time_point_cast<std::chrono::microseconds>(std::chrono::system_clock::now());
    double timeStamp = nano.time_since_epoch().count();

    cache->Timers.emplace(label, timeStamp);
}

void Console::TimeEndCallback(const FunctionCallbackInfo<Value>& args) {
    if (!RuntimeConfig.LogToSystemConsole) {
        return;
    }

    Isolate* isolate = args.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();
    std::string label = "default";

    Local<v8::String> labelString;
    if (args.Length() > 0 && args[0]->ToString(context).ToLocal(&labelString)) {
        label = tns::ToString(isolate, labelString);
    }

    std::shared_ptr<Caches> cache = Caches::Get(isolate);
    auto itTimersMap = cache->Timers.find(label);
    if (itTimersMap == cache->Timers.end()) {
        std::string warning = std::string("No such label '" + label + "' for console.timeEnd()");
        Log("%s", warning.c_str());
        return;
    }

    auto nano = std::chrono::time_point_cast<std::chrono::microseconds>(std::chrono::system_clock::now());
    double endTimeStamp = nano.time_since_epoch().count();
    double startTimeStamp = itTimersMap->second;

    cache->Timers.erase(label);

    double diffMicroseconds = endTimeStamp - startTimeStamp;
    double diffMilliseconds = diffMicroseconds / 1000.0;

    std::stringstream ss;
    ss << "CONSOLE INFO " << label << ": " << std::fixed << std::setprecision(3) << diffMilliseconds << "ms" ;

    Local<v8::String> data = args.Data().As<v8::String>();
    std::string verbosityLevel = tns::ToString(isolate, data);
    std::string level = VerbosityToInspectorVerbosity(verbosityLevel);
    std::string msgToLog = ss.str();
    v8_inspector::V8LogAgentImpl::EntryAdded(msgToLog, level, "", 0);
    Log("%s", msgToLog.c_str());
}

void Console::AttachLogFunction(Local<Context> context, Local<Object> console, const std::string name, v8::FunctionCallback callback) {
    Isolate* isolate = context->GetIsolate();

    Local<v8::Function> func;
    if (!Function::New(context, callback, tns::ToV8String(isolate, name), 0, ConstructorBehavior::kThrow).ToLocal(&func)) {
        tns::Assert(false, isolate);
    }

    Local<v8::String> logFuncName = tns::ToV8String(isolate, name);
    func->SetName(logFuncName);
    if (!console->CreateDataProperty(context, logFuncName, func).FromMaybe(false)) {
        tns::Assert(false, isolate);
    }
}

std::string Console::BuildStringFromArgs(const FunctionCallbackInfo<Value>& args, int startingIndex) {
    Isolate* isolate = args.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();
    int argLen = args.Length();
    std::stringstream ss;

    if (argLen > 0) {
        for (int i = startingIndex; i < argLen; i++) {
            Local<v8::String> argString;

            argString = BuildStringFromArg(context, args[i]);

            // separate args with a space
            if (i != startingIndex) {
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

const Local<v8::String> Console::BuildStringFromArg(Local<Context> context, const Local<Value>& val) {
    Isolate* isolate = context->GetIsolate();
    Local<v8::String> argString;
    if (val->IsFunction()) {
        bool success = val->ToDetailString(context).ToLocal(&argString);
        tns::Assert(success, isolate);
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

            Local<v8::String> objectString = BuildStringFromArg(context, propertyValue);

            argString = v8::String::Concat(isolate, argString, objectString);

            if (i != arrayLength - 1) {
                argString = v8::String::Concat(isolate, argString, tns::ToV8String(isolate, ", "));
            }
        }

        argString = v8::String::Concat(isolate, argString, tns::ToV8String(isolate, "]"));
    } else if (val->IsObject()) {
        Local<Object> obj = val.As<Object>();

        argString = TransformJSObject(obj);
    } else {
        bool success = val->ToDetailString(isolate->GetCurrentContext()).ToLocal(&argString);
        tns::Assert(success, isolate);
    }

    return argString;
}

const Local<v8::String> Console::TransformJSObject(Local<Object> object) {
    Local<Context> context;
    bool success = object->GetCreationContext().ToLocal(&context);
    tns::Assert(success);
    Isolate* isolate = context->GetIsolate();
    Local<Value> value;
    {
        TryCatch tc(isolate);
        bool success = object->ToString(context).ToLocal(&value);
        if (!success) {
            return tns::ToV8String(isolate, "");
        }
    }
    Local<v8::String> objToString = value.As<v8::String>();

    Local<v8::String> resultString;
    bool hasCustomToStringImplementation = tns::ToString(isolate, objToString).find("[object Object]") == std::string::npos;

    if (hasCustomToStringImplementation) {
        resultString = objToString;
    } else {
        resultString = tns::JsonStringifyObject(context, object);
    }

    return resultString;
}

const std::string Console::VerbosityToInspectorVerbosity(const std::string level) {
    if (level == "error") {
        return "error";
    } else if (level == "warn") {
        return "warning";
    }

    return "info";
}

}
