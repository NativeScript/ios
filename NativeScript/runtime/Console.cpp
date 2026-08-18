#include "Console.h"

#include <chrono>
#include <iomanip>
#include <regex>
#include <string>
#include <vector>

#include "BuiltinLoader.h"
#include "Caches.h"
#include "DataWrapper.h"
#include "Helpers.h"
#include "NativeScriptException.h"
#include "NsBuiltinModules.h"
#include "RuntimeConfig.h"
// #include "v8-log-agent-impl.h"
#include <sstream>

using namespace v8;

namespace tns {

namespace {
// console.time labels -> start timestamps (µs), per isolate.
struct ConsoleTimersState {
  robin_hood::unordered_map<std::string, double> startedAt;
};
}  // namespace

void Console::Init(Local<Context> context) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  Context::Scope context_scope(context);
  Local<Object> console = Object::New(isolate);
  bool success =
      console->SetPrototype(context, Object::New(isolate)).FromMaybe(false);
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

  Console::InitInspect(context);

  Local<Object> global = context->Global();
  PropertyAttribute readOnlyFlags = static_cast<PropertyAttribute>(
      PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
  if (!global
           ->DefineOwnProperty(context, tns::ToV8String(isolate, "console"),
                               console, readOnlyFlags)
           .FromMaybe(false)) {
    tns::Assert(false, isolate);
  }
}

void Console::AttachInspectorClient(
    v8_inspector::JsV8InspectorClient* aInspector) {
  inspector = aInspector;
}

void Console::DetachInspectorClient() { inspector = nullptr; }

bool isErrorMessage(const std::string& line) {
  return line.find("Error") != std::string::npos;
}

bool isStackFrame(const std::string& line) {
  // Recognize both styles:
  //   "    at foo (/path/to/file.ts:123:45)"  -> with parentheses
  //   "    at /path/to/file.ts:123:45"        -> bare location
  static const std::regex withParens(R"(\s+at\s+.*\(.+?:\d+:\d+\))");
  static const std::regex bare(R"(\s+at\s+[^\s\(\)]+:\d+:\d+)");
  return std::regex_search(line, withParens) || std::regex_search(line, bare);
}

void Console::LogCallback(const FunctionCallbackInfo<Value>& args) {
  // TODO: implement 'forceLog' override option like android has, to force logs
  // in prod if desired
  if (!RuntimeConfig.LogToSystemConsole) {
    return;
  }

  Isolate* isolate = args.GetIsolate();
  std::string stringResult = BuildStringFromArgs(args);
  // Log("stringResult %s", stringResult.c_str());

  Local<v8::String> data = args.Data().As<v8::String>();
  std::string verbosityLevel = tns::ToString(isolate, data);

  // Compute remapped payload ONCE and use it for both the modal and terminal
  // so they always match exactly.
  bool hasStackTrace = isStackFrame(stringResult);
  std::string processedStringResult = stringResult;
  if (hasStackTrace) {
    processedStringResult =
        tns::RemapStackTraceIfAvailable(isolate, processedStringResult);
  }

  std::string verbosityLevelUpper = verbosityLevel;
  std::transform(verbosityLevelUpper.begin(), verbosityLevelUpper.end(),
                 verbosityLevelUpper.begin(), ::toupper);

  std::stringstream ss;
  ss << processedStringResult;

  if (verbosityLevel == "trace") {
    std::string stacktrace = tns::GetStackTrace(isolate);
    ss << std::endl << stacktrace << std::endl;
  }

  std::string msgToLog = ss.str();

  ConsoleAPIType method = VerbosityToInspectorMethod(verbosityLevel);
  SendToDevToolsFrontEnd(method, args);
  std::string msgWithVerbosity =
      "CONSOLE " + verbosityLevelUpper + ": " + msgToLog;
  Log("%s", msgWithVerbosity.c_str());

  if (RuntimeConfig.IsDebug && Runtime::showErrorDisplay() &&
      verbosityLevel == "error" && hasStackTrace) {
    try {
      // Log("Console.cpp: Forwarding console payload to error display: %s",
      // msgToLog.c_str());
      NativeScriptException::SubmitConsoleErrorPayload(isolate, msgToLog);
    } catch (const std::exception& e) {
      Log("Console.cpp: Exception updating modal: %s", e.what());
    } catch (...) {
      Log("Console.cpp: Unknown exception updating modal");
    }
  }
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

    SendToDevToolsFrontEnd(ConsoleAPIType::kAssert, args);
    Log("%s", log.c_str());
  }
}

void Console::DirCallback(const FunctionCallbackInfo<Value>& args) {
  if (!RuntimeConfig.LogToSystemConsole) {
    return;
  }

  Isolate* isolate = args.GetIsolate();
  Local<Context> context = isolate->GetCurrentContext();

  std::stringstream ss;
  std::string scriptUrl = tns::GetCurrentScriptUrl(isolate);
  ss << scriptUrl << ":";

  if (args.Length() > 0 && args[0]->IsObject()) {
    ss << std::endl << "==== object dump start ====" << std::endl;
    ss << tns::ToString(isolate, Console::InspectValue(context, args[0], 4))
       << std::endl;
    ss << "==== object dump end ====" << std::endl;
  } else if (args.Length() > 0) {
    ss << " " << BuildStringFromArgs(args);
  } else {
    ss << "";
  }

  std::string msgToLog = ss.str();
  SendToDevToolsFrontEnd(ConsoleAPIType::kDir, args);
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

  auto* timers = Caches::StateFor<ConsoleTimersState>(isolate);
  if (timers == nullptr) {
    return;
  }

  auto nano = std::chrono::time_point_cast<std::chrono::microseconds>(
      std::chrono::system_clock::now());
  double timeStamp = nano.time_since_epoch().count();

  timers->startedAt.emplace(label, timeStamp);
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

  auto* timers = Caches::StateFor<ConsoleTimersState>(isolate);
  if (timers == nullptr) {
    return;
  }
  auto itTimersMap = timers->startedAt.find(label);
  if (itTimersMap == timers->startedAt.end()) {
    std::string warning =
        std::string("No such label '" + label + "' for console.timeEnd()");
    Log("%s", warning.c_str());
    return;
  }

  auto nano = std::chrono::time_point_cast<std::chrono::microseconds>(
      std::chrono::system_clock::now());
  double endTimeStamp = nano.time_since_epoch().count();
  double startTimeStamp = itTimersMap->second;

  timers->startedAt.erase(itTimersMap);

  double diffMicroseconds = endTimeStamp - startTimeStamp;
  double diffMilliseconds = diffMicroseconds / 1000.0;

  std::stringstream ss;
  ss << "CONSOLE INFO " << label << ": " << std::fixed << std::setprecision(3)
     << diffMilliseconds << "ms";

  std::string msgToLog = ss.str();
  SendToDevToolsFrontEnd(isolate, ConsoleAPIType::kTimeEnd, msgToLog);
  Log("%s", msgToLog.c_str());
}

void Console::AttachLogFunction(Local<Context> context, Local<Object> console,
                                const std::string name,
                                v8::FunctionCallback callback) {
  Isolate* isolate = v8::Isolate::GetCurrent();

  Local<v8::Function> func;
  if (!Function::New(context, callback, tns::ToV8String(isolate, name), 0,
                     ConstructorBehavior::kThrow)
           .ToLocal(&func)) {
    tns::Assert(false, isolate);
  }

  Local<v8::String> logFuncName = tns::ToV8String(isolate, name);
  func->SetName(logFuncName);
  if (!console->CreateDataProperty(context, logFuncName, func)
           .FromMaybe(false)) {
    tns::Assert(false, isolate);
  }
}

std::string Console::BuildStringFromArgs(
    const FunctionCallbackInfo<Value>& args, int startingIndex) {
  Isolate* isolate = args.GetIsolate();
  Local<Context> context = isolate->GetCurrentContext();
  int argLen = args.Length();

  // console.* follows Node: the arguments go through util.format, so the first
  // one may carry %-substitutions and the rest are appended space-separated.
  Local<v8::Function> format = argLen > startingIndex
                                   ? NsBuiltinModules::GetFormatFunc(context)
                                   : Local<v8::Function>();
  if (!format.IsEmpty()) {
    std::vector<Local<Value>> formatArgs;
    formatArgs.reserve(argLen - startingIndex);
    for (int i = startingIndex; i < argLen; i++) {
      formatArgs.push_back(args[i]);
    }
    TryCatch tc(isolate);
    Local<Value> result;
    if (format
            ->Call(context, v8::Undefined(isolate),
                   static_cast<int>(formatArgs.size()), formatArgs.data())
            .ToLocal(&result) &&
        result->IsString()) {
      return tns::ToString(isolate, result.As<v8::String>());
    }
  }

  // ns:util unavailable or the formatter threw: per-argument rendering.
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

const Local<v8::String> Console::BuildStringFromArg(Local<Context> context,
                                                    const Local<Value>& val) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  // Top-level strings print raw (console.log("hi") -> hi); everything else
  // that can carry structure goes through the inspect builtin.
  if (val->IsString()) {
    return val.As<v8::String>();
  }
  if (val->IsObject() || val->IsFunction()) {
    return Console::InspectValue(context, val);
  }

  Local<v8::String> argString;
  bool success = val->ToDetailString(context).ToLocal(&argString);
  tns::Assert(success, isolate);
  return argString;
}

static void GetNativeWrapperHintCallback(
    const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  if (info.Length() < 1) {
    return;
  }
  std::string hint = tns::GetNativeWrapperHint(isolate, info[0]);
  if (!hint.empty()) {
    info.GetReturnValue().Set(tns::ToV8String(isolate, hint));
  }
}

void Console::InitInspect(Local<Context> context) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  if (Caches::Get(isolate)->InspectFunc != nullptr) {
    // inspect.js installs a non-configurable global.__inspect, so a second run
    // in the same realm would throw.
    return;
  }

  Local<v8::Function> hintFunc;
  if (!v8::Function::New(context, GetNativeWrapperHintCallback)
           .ToLocal(&hintFunc)) {
    Log("Warning: Console failed to create the native-hint binding");
    return;
  }
  Local<Object> binding = Object::New(isolate);
  if (!binding
           ->Set(context, tns::ToV8String(isolate, "getNativeWrapperHint"),
                 hintFunc)
           .FromMaybe(false)) {
    Log("Warning: Console failed to populate the inspect binding");
    return;
  }

  TryCatch tc(isolate);
  Local<Value> result;
  if (!BuiltinLoader::RunBuiltin(context, BuiltinId::kInspect, binding)
           .ToLocal(&result) ||
      !result->IsFunction()) {
    if (tc.HasCaught()) {
      tns::LogError(isolate, tc);
    }
    Log("Warning: Console failed to initialize the inspect builtin");
    return;
  }

  Caches::Get(isolate)->InspectFunc =
      std::make_unique<Persistent<v8::Function>>(isolate,
                                                 result.As<v8::Function>());
}

Local<v8::String> Console::InspectValue(Local<Context> context,
                                        const Local<Value>& val, int depth) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  auto cache = Caches::Get(isolate);

  if (cache->InspectFunc != nullptr) {
    Local<v8::Function> inspect = cache->InspectFunc->Get(isolate);
    Local<Value> arg = val;
    Local<Value> args[2];
    int argc = 1;
    args[0] = arg;
    if (depth >= 0) {
      Local<Object> options = Object::New(isolate);
      if (options
              ->Set(context, tns::ToV8String(isolate, "depth"),
                    v8::Number::New(isolate, depth))
              .FromMaybe(false)) {
        args[1] = options;
        argc = 2;
      }
    }
    TryCatch tc(isolate);
    Local<Value> result;
    if (inspect->Call(context, v8::Undefined(isolate), argc, args)
            .ToLocal(&result) &&
        result->IsString()) {
      return result.As<v8::String>();
    }
  }

  // Init failed or the formatter threw: degrade to V8's own short description.
  Local<v8::String> fallback;
  if (val->ToDetailString(context).ToLocal(&fallback)) {
    return fallback;
  }
  return v8::String::Empty(isolate);
}

v8_inspector::ConsoleAPIType Console::VerbosityToInspectorMethod(
    const std::string level) {
  if (level == "error") {
    return ConsoleAPIType::kError;
  } else if (level == "warn") {
    return ConsoleAPIType::kWarning;
  } else if (level == "info") {
    return ConsoleAPIType::kInfo;
  } else if (level == "trace") {
    return ConsoleAPIType::kTrace;
  }

  assert(level == "log");
  return ConsoleAPIType::kLog;
}

void Console::SendToDevToolsFrontEnd(
    ConsoleAPIType method, const v8::FunctionCallbackInfo<v8::Value>& args) {
  if (!inspector) {
    return;
  }

  std::vector<v8::Local<v8::Value>> arg_vector;
  unsigned nargs = args.Length();
  arg_vector.reserve(nargs);
  for (unsigned ix = 0; ix < nargs; ix++) arg_vector.push_back(args[ix]);

  inspector->consoleLog(args.GetIsolate(), method, arg_vector);
}

void Console::SendToDevToolsFrontEnd(v8::Isolate* isolate,
                                     ConsoleAPIType method,
                                     const std::string& msg) {
  if (!inspector) {
    return;
  }

  v8::Local<v8::String> v8str =
      v8::String::NewFromUtf8(isolate, msg.c_str(), v8::NewStringType::kNormal,
                              -1)
          .ToLocalChecked();
  std::vector<v8::Local<v8::Value>> args{v8str};
  inspector->consoleLog(isolate, method, args);
}

v8_inspector::JsV8InspectorClient* Console::inspector = nullptr;

}  // namespace tns
