#include "Helpers.h"
#include <Foundation/Foundation.h>
#include <cxxabi.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <sys/stat.h>
#include <atomic>
#include <fstream>
#include <mutex>
#include <sstream>
#include "Caches.h"
#include "ErrorEvents.h"
#include "NativeScriptException.h"
#include "Runtime.h"
#include "RuntimeConfig.h"

using namespace v8;

namespace {
const int BUFFER_SIZE = 1024 * 1024;
char* Buffer = new char[BUFFER_SIZE];
uint8_t* BinBuffer = new uint8_t[BUFFER_SIZE];
}  // namespace

std::u16string tns::ToUtf16String(Isolate* isolate, const Local<Value>& value) {
  // Read the V8 string's native UTF-16 buffer directly instead of round-tripping
  // through UTF-8, which corrupts lone surrogates (replaced with U+FFFD) and is
  // slower. This also drops the deprecated std::codecvt_utf8_utf16.
  if (value.IsEmpty()) {
    return std::u16string();
  }

  if (value->IsStringObject()) {
    Local<v8::String> obj = value.As<StringObject>()->ValueOf();
    return tns::ToUtf16String(isolate, obj);
  }

  Local<v8::String> str;
  if (!value->ToString(isolate->GetCurrentContext()).ToLocal(&str)) {
    return std::u16string();
  }

  v8::String::ValueView result(isolate, str);
  if (result.is_one_byte()) {
    // A one-byte V8 string is Latin-1, so widening each byte is the conversion.
    const uint8_t* data = result.data8();
    return std::u16string(data, data + result.length());
  }

  return std::u16string((const char16_t*)result.data16(), result.length());
}

bool tns::Exists(const char* fullPath) {
  struct stat statbuf;
  mode_t mode = S_IFDIR | S_IFREG;
  if (stat(fullPath, &statbuf) == 0) {
    return (statbuf.st_mode & S_IFMT) & mode;
  }

  return false;
}

Local<v8::String> tns::ReadModule(Isolate* isolate, const std::string& filePath) {
  struct stat finfo;

  int file = open(filePath.c_str(), O_RDONLY);
  if (file < 0) {
    throw NativeScriptException(isolate, "Cannot read module " + filePath);
  }

  fstat(file, &finfo);
  long length = finfo.st_size;

  char* newBuffer = new char[length + 128];
  strcpy(newBuffer,
         "(function(module, exports, require, __filename, __dirname) { ");  // 61 Characters
  read(file, &newBuffer[61], length);
  close(file);
  length += 61;

  // Add the closing "\n})"
  newBuffer[length] = 10;
  ++length;
  newBuffer[length] = '}';
  ++length;
  newBuffer[length] = ')';
  ++length;
  newBuffer[length] = 0;

  Local<v8::String> str =
      v8::String::NewFromUtf8(isolate, newBuffer, NewStringType::kNormal, (int)length)
          .ToLocalChecked();
  delete[] newBuffer;

  return str;
}

const char* tns::ReadText(const std::string& filePath, long& length, bool& isNew) {
  FILE* file = fopen(filePath.c_str(), "rb");
  if (file == nullptr) {
    tns::Assert(false);
  }

  fseek(file, 0, SEEK_END);

  length = ftell(file);
  isNew = length > BUFFER_SIZE;

  rewind(file);

  if (isNew) {
    char* newBuffer = new char[length];
    fread(newBuffer, 1, length, file);
    fclose(file);

    return newBuffer;
  }

  fread(Buffer, 1, length, file);
  fclose(file);

  return Buffer;
}

std::string tns::ReadText(const std::string& file) {
  long length;
  bool isNew;
  const char* content = tns::ReadText(file, length, isNew);

  std::string result(content, length);

  if (isNew) {
    delete[] content;
  }

  return result;
}

uint8_t* tns::ReadBinary(const std::string path, long& length, bool& isNew) {
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

  isNew = length > BUFFER_SIZE;

  if (isNew) {
    uint8_t* data = new uint8_t[length];
    fread(data, sizeof(uint8_t), length, file);
    fclose(file);
    return data;
  }

  fread(BinBuffer, 1, length, file);
  fclose(file);

  return BinBuffer;
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

void tns::SetPrivateValue(const Local<Object>& obj, const Local<v8::String>& propName,
                          const Local<Value>& value) {
  Local<Context> context;
  bool success = obj->GetCreationContext(v8::Isolate::GetCurrent()).ToLocal(&context);
  tns::Assert(success);
  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<Private> privateKey = Private::ForApi(isolate, propName);

  if (!obj->SetPrivate(context, privateKey, value).To(&success) || !success) {
    tns::Assert(false, isolate);
  }
}

Local<Value> tns::GetPrivateValue(const Local<Object>& obj, const Local<v8::String>& propName) {
  Local<Context> context;
  bool success = obj->GetCreationContext(v8::Isolate::GetCurrent()).ToLocal(&context);
  tns::Assert(success);
  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<Private> privateKey = Private::ForApi(isolate, propName);

  Maybe<bool> hasPrivate = obj->HasPrivate(context, privateKey);

  tns::Assert(!hasPrivate.IsNothing(), isolate);

  if (!hasPrivate.FromMaybe(false)) {
    return Local<Value>();
  }

  v8::Locker locker(isolate);
  Local<Value> result;
  if (!obj->GetPrivate(context, privateKey).ToLocal(&result)) {
    tns::Assert(false, isolate);
  }

  return result;
}

bool tns::DeleteWrapperIfUnused(Isolate* isolate, const Local<Value>& obj, BaseDataWrapper* value) {
  if (GetValue(isolate, obj) != value) {
    delete value;
    return true;
  }
  return false;
}

void tns::SetValue(Isolate* isolate, const Local<Object>& obj, BaseDataWrapper* value) {
  if (obj.IsEmpty() || obj->IsNullOrUndefined()) {
    return;
  }

  Local<External> ext = External::New(isolate, value, v8::kExternalPointerTypeTagDefault);

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
    Local<Value> field = obj->GetInternalField(0).As<v8::Value>();
    if (field.IsEmpty() || field->IsNullOrUndefined() || !field->IsExternal()) {
      return nullptr;
    }

    return static_cast<BaseDataWrapper*>(
        field.As<External>()->Value(v8::kExternalPointerTypeTagDefault));
  }

  Local<Value> metadataProp = tns::GetPrivateValue(obj, tns::ToV8String(isolate, "metadata"));
  if (metadataProp.IsEmpty() || metadataProp->IsNullOrUndefined() || !metadataProp->IsExternal()) {
    return nullptr;
  }

  return static_cast<BaseDataWrapper*>(
      metadataProp.As<External>()->Value(v8::kExternalPointerTypeTagDefault));
}

namespace {

std::atomic<int> releasedObjectPolicy_{static_cast<int>(tns::ReleasedObjectPolicy::kReport)};

struct ReleasedAccessReport {
  v8::Isolate* isolate;
  v8::Global<v8::Value> error;
  std::string operation;
};

// Runs on the isolate's microtask queue: dispatching from the touch site
// itself would run arbitrary app JS in the middle of an interop marshal.
void DispatchReleasedAccessMicrotask(void* data) {
  std::unique_ptr<ReleasedAccessReport> report(static_cast<ReleasedAccessReport*>(data));
  v8::Isolate* isolate = report->isolate;
  v8::HandleScope scope(isolate);
  tns::ErrorEvents::DispatchReleasedNativeAccess(isolate, report->error.Get(isolate),
                                                 report->operation);
}

}  // namespace

tns::ReleasedObjectPolicy tns::GetReleasedObjectPolicy() {
  return static_cast<ReleasedObjectPolicy>(releasedObjectPolicy_.load(std::memory_order_relaxed));
}

void tns::SetReleasedObjectPolicy(ReleasedObjectPolicy policy) {
  releasedObjectPolicy_.store(static_cast<int>(policy), std::memory_order_relaxed);
}

namespace {

std::atomic<bool> scriptLoadingLog_{false};
std::atomic<bool> httpFetchUrlLog_{false};
std::once_flag logFlagsInitFlag_;

bool BoolFromAppConfig(const char* key) {
  id value = tns::Runtime::GetAppConfigValue(key);
  if (value && [value respondsToSelector:@selector(boolValue)]) {
    return [value boolValue];
  }
  return false;
}

void EnsureLogFlagsInitialized() {
  std::call_once(logFlagsInitFlag_, []() {
    @autoreleasepool {
      scriptLoadingLog_.store(BoolFromAppConfig("logScriptLoading"), std::memory_order_relaxed);
      httpFetchUrlLog_.store(BoolFromAppConfig("httpFetchUrlLog"), std::memory_order_relaxed);
    }
    if (scriptLoadingLog_.load(std::memory_order_relaxed)) {
      Log(@"[http-loader] fetch-url-log=%s",
          httpFetchUrlLog_.load(std::memory_order_relaxed) ? "enabled" : "disabled");
    }
  });
}

}  // namespace

bool tns::IsScriptLoadingLogEnabled() {
  EnsureLogFlagsInitialized();
  return scriptLoadingLog_.load(std::memory_order_relaxed);
}

void tns::SetScriptLoadingLogEnabled(bool enabled) {
  EnsureLogFlagsInitialized();
  scriptLoadingLog_.store(enabled, std::memory_order_relaxed);
}

bool tns::IsHttpFetchUrlLogEnabled() {
  EnsureLogFlagsInitialized();
  return httpFetchUrlLog_.load(std::memory_order_relaxed);
}

void tns::SetHttpFetchUrlLogEnabled(bool enabled) {
  EnsureLogFlagsInitialized();
  httpFetchUrlLog_.store(enabled, std::memory_order_relaxed);
}

void tns::LogDroppedDeadIsolateCallback(void* target, void* selector) {
  if (!IsScriptLoadingLogEnabled()) {
    return;
  }

  if (target != nullptr && selector != nullptr) {
    id self_ = (__bridge id)target;
    SEL cmd = (SEL)selector;
    NSLog(@"NativeScript: dropping call to -[%s %s] because the JS isolate that implemented it "
          @"was disposed (e.g. after reloadApplication); reassign the delegate/callback from the "
          @"new bundle to restore dispatch",
          object_getClassName(self_), sel_getName(cmd));
  } else {
    NSLog(@"NativeScript: dropping a native callback (block or function pointer) because the JS "
          @"isolate that implemented it was disposed (e.g. after reloadApplication)");
  }
}

tns::BaseDataWrapper* tns::GetValueOrReport(Isolate* isolate, const Local<Value>& val,
                                            const char* operation) {
  BaseDataWrapper* wrapper = tns::GetValue(isolate, val);
  if (wrapper != nullptr) {
    return wrapper;
  }

  std::string message =
      std::string("The native object has been released or is not a valid native object (") +
      operation + ")";

  if (GetReleasedObjectPolicy() == ReleasedObjectPolicy::kThrow) {
    isolate->ThrowException(v8::Exception::ReferenceError(tns::ToV8String(isolate, message)));
    return nullptr;
  }

  Local<Context> context = isolate->GetCurrentContext();
  if (val->IsObject()) {
    // One report per husk object: a released buffer touched in a tight loop
    // must not flood the event queue.
    Local<Private> reported =
        Private::ForApi(isolate, tns::ToV8String(isolate, "ns:releasedAccessReported"));
    Local<Object> obj = val.As<Object>();
    if (obj->HasPrivate(context, reported).FromMaybe(false)) {
      return nullptr;
    }
    obj->SetPrivate(context, reported, v8::True(isolate)).FromMaybe(false);
  }

  // The error is created here so its stack names the touch site.
  Local<Value> error = v8::Exception::ReferenceError(tns::ToV8String(isolate, message));
  auto* report =
      new ReleasedAccessReport{isolate, v8::Global<v8::Value>(isolate, error), operation};
  isolate->EnqueueMicrotask(DispatchReleasedAccessMicrotask, report);
  return nullptr;
}

void tns::DeleteValue(Isolate* isolate, const Local<Value>& val) {
  if (val.IsEmpty() || val->IsNullOrUndefined() || !val->IsObject()) {
    return;
  }

  Local<Object> obj = val.As<Object>();
  if (obj->InternalFieldCount() > 0) {
    obj->SetInternalField(0, v8::Undefined(isolate));
    return;
  }

  Local<v8::String> metadataKey = tns::ToV8String(isolate, "metadata");
  Local<Value> metadataProp = tns::GetPrivateValue(obj, metadataKey);
  if (metadataProp.IsEmpty() || metadataProp->IsNullOrUndefined() || !metadataProp->IsExternal()) {
    return;
  }

  Local<Context> context;
  bool success = obj->GetCreationContext(v8::Isolate::GetCurrent()).ToLocal(&context);
  tns::Assert(success, isolate);
  Local<Private> privateKey = Private::ForApi(isolate, metadataKey);

  success = obj->DeletePrivate(context, privateKey).FromMaybe(false);
  tns::Assert(success, isolate);
}

std::vector<Local<Value>> tns::ArgsToVector(const FunctionCallbackInfo<Value>& info) {
  std::vector<Local<Value>> args;
  args.reserve(info.Length());
  for (int i = 0; i < info.Length(); i++) {
    args.push_back(info[i]);
  }
  return args;
}

bool tns::IsArrayOrArrayLike(Isolate* isolate, const Local<Value>& value) {
  if (value->IsArray()) {
    return true;
  }

  if (!value->IsObject()) {
    return false;
  }

  Local<Object> obj = value.As<Object>();
  Local<Context> context;
  bool success = obj->GetCreationContext(v8::Isolate::GetCurrent()).ToLocal(&context);
  tns::Assert(success, isolate);
  return obj->Has(context, ToV8String(isolate, "length")).FromMaybe(false);
}

void* tns::TryGetBufferFromArrayBuffer(const v8::Local<v8::Value>& value, bool& isArrayBuffer) {
  isArrayBuffer = false;

  if (value.IsEmpty() ||
      (!value->IsArrayBuffer() && !value->IsArrayBufferView() && !value->IsSharedArrayBuffer())) {
    return nullptr;
  }

  std::shared_ptr<BackingStore> backingStore;
  size_t byteOffset = 0;
  if (value->IsArrayBufferView()) {
    isArrayBuffer = true;
    auto view = value.As<ArrayBufferView>();
    byteOffset = view->ByteOffset();
    auto buffer = view->Buffer();
    if (!buffer.IsEmpty()) {
      backingStore = buffer->GetBackingStore();
    }
  } else if (value->IsArrayBuffer()) {
    isArrayBuffer = true;
    backingStore = value.As<ArrayBuffer>()->GetBackingStore();
  } else if (value->IsSharedArrayBuffer()) {
    isArrayBuffer = true;
    backingStore = value.As<SharedArrayBuffer>()->GetBackingStore();
  }

  if (!backingStore) {
    return nullptr;
  }

  uint8_t* data = static_cast<uint8_t*>(backingStore->Data());
  if (data == nullptr) {
    return nullptr;
  }

  return data + byteOffset;
}

struct LockAndCV {
  std::mutex m;
  std::condition_variable cv;
};

void tns::ExecuteOnRunLoop(CFRunLoopRef queue, void (^func)(void), bool async) {
  if (!async) {
    bool __block finished = false;
    auto v = new LockAndCV;
    std::unique_lock<std::mutex> lock(v->m);
    CFRunLoopPerformBlock(queue, kCFRunLoopCommonModes, ^(void) {
      func();
      {
        std::unique_lock lk(v->m);
        finished = true;
      }
      v->cv.notify_all();
    });
    CFRunLoopWakeUp(queue);
    while (!finished) {
      v->cv.wait(lock);
    }
    delete v;
  } else {
    CFRunLoopPerformBlock(queue, kCFRunLoopCommonModes, func);
    CFRunLoopWakeUp(queue);
  }
}

void tns::ExecuteOnDispatchQueue(dispatch_queue_t queue, std::function<void()> func, bool async) {
  if (async) {
    dispatch_async(queue, ^(void) {
      func();
    });
  } else {
    dispatch_sync(queue, ^(void) {
      func();
    });
  }
}

void tns::ExecuteOnMainThread(std::function<void()> func, bool async) {
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

std::string tns::GetNativeWrapperHint(Isolate* isolate, const Local<Value>& value) {
  BaseDataWrapper* wrapper = tns::GetValue(isolate, value);
  if (wrapper == nullptr) {
    return std::string();
  }

  switch (wrapper->Type()) {
    case WrapperType::ObjCObject: {
      id data = static_cast<ObjCDataWrapper*>(wrapper)->Data();
      return data != nil ? std::string(object_getClassName(data)) : "ObjCObject";
    }
    case WrapperType::ObjCClass: {
      Class klass = static_cast<ObjCClassWrapper*>(wrapper)->Klass();
      return klass != nil ? "class " + std::string(class_getName(klass)) : "ObjCClass";
    }
    case WrapperType::ObjCProtocol: {
      Protocol* proto = static_cast<ObjCProtocolWrapper*>(wrapper)->Proto();
      return proto != nil ? "protocol " + std::string(protocol_getName(proto)) : "ObjCProtocol";
    }
    case WrapperType::Pointer:
      return "Pointer";
    case WrapperType::Block:
      return "Block";
    case WrapperType::Function:
      return "NativeFunction";
    default:
      // Remaining wrapper kinds (structs, references, enums, ...) format fine
      // through the ordinary object path.
      return std::string();
  }
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
  void* callstack[128];
  const int nMaxFrames = sizeof(callstack) / sizeof(callstack[0]);
  char buf[1024];
  int nFrames = backtrace(callstack, nMaxFrames);
  char** symbols = backtrace_symbols(callstack, nFrames);

  for (int i = skip; i < nFrames; i++) {
    Dl_info info;
    if (dladdr(callstack[i], &info) && info.dli_sname) {
      char* demangled = NULL;
      int status = -1;
      if (info.dli_sname[0] == '_') {
        demangled = abi::__cxa_demangle(info.dli_sname, NULL, 0, &status);
      }
      snprintf(buf, sizeof(buf), "%-3d %*p %s + %zd\n", i, int(2 + sizeof(void*) * 2), callstack[i],
               status == 0           ? demangled
               : info.dli_sname == 0 ? symbols[i]
                                     : info.dli_sname,
               (char*)callstack[i] - (char*)info.dli_saddr);
      free(demangled);
    } else {
      snprintf(buf, sizeof(buf), "%-3d %*p %s\n", i, int(2 + sizeof(void*) * 2), callstack[i],
               symbols[i]);
    }
    Log(@"%s", buf);
  }
  free(symbols);
  if (nFrames == nMaxFrames) {
    Log(@"[truncated]");
  }
}

const std::string tns::GetStackTrace(Isolate* isolate) {
  Local<StackTrace> stack =
      StackTrace::CurrentStackTrace(isolate, 10, StackTrace::StackTraceOptions::kDetailed);
  int framesCount = stack->GetFrameCount();
  std::stringstream ss;
  for (int i = 0; i < framesCount; i++) {
    Local<StackFrame> frame = stack->GetFrame(isolate, i);
    ss << BuildStacktraceFrameMessage(isolate, frame) << std::endl;
  }
  return ss.str();
}

const std::string tns::GetCurrentScriptUrl(Isolate* isolate) {
  Local<StackTrace> stack =
      StackTrace::CurrentStackTrace(isolate, 1, StackTrace::StackTraceOptions::kDetailed);
  int framesCount = stack->GetFrameCount();
  if (framesCount > 0) {
    Local<StackFrame> frame = stack->GetFrame(isolate, 0);
    return tns::BuildStacktraceFrameLocationPart(isolate, frame);
  }

  return "";
}

std::string tns::RemapStackTraceIfAvailable(Isolate* isolate, const std::string& stackTrace) {
  if (stackTrace.empty()) {
    return stackTrace;
  }
  if (isolate == nullptr) {
    return stackTrace;
  }

  v8::Locker locker(isolate);
  Isolate::Scope isolateScope(isolate);
  HandleScope handleScope(isolate);
  Local<Context> context = Caches::Get(isolate)->GetContext();
  if (context.IsEmpty()) {
    return stackTrace;
  }
  Context::Scope contextScope(context);
  Local<Object> global = context->Global();
  Local<Value> remapFnVal;
  bool hasRemap =
      global->Get(context, tns::ToV8String(isolate, "__ns_remapStack")).ToLocal(&remapFnVal);
  if (hasRemap && remapFnVal->IsFunction()) {
    Local<v8::Function> remapFn = remapFnVal.As<v8::Function>();
    Local<Value> args[] = {tns::ToV8String(isolate, stackTrace)};
    Local<Value> remapped;
    if (remapFn->Call(context, global, 1, args).ToLocal(&remapped) && remapped->IsString()) {
      return tns::ToString(isolate, remapped.As<v8::String>());
    }
  }
  return stackTrace;
}

std::string tns::GetSmartStackTrace(Isolate* isolate, v8::TryCatch* tryCatch,
                                    v8::Local<v8::Value> exception) {
  std::string stack;
  Local<Context> context = isolate->GetCurrentContext();

  // 1) Prefer exception.stack when provided
  if (!exception.IsEmpty()) {
    if (exception->IsObject()) {
      Local<Object> excObj = exception.As<Object>();
      Local<Value> stackVal;
      if (excObj->Get(context, tns::ToV8String(isolate, "stack")).ToLocal(&stackVal) &&
          stackVal->IsString()) {
        stack = tns::ToString(isolate, stackVal.As<v8::String>());
      }
    }

    // Fallback to v8::Exception::GetStackTrace on the exception value
    if (stack.empty()) {
      Local<StackTrace> v8Stack = v8::Exception::GetStackTrace(exception);
      if (!v8Stack.IsEmpty()) {
        int framesCount = v8Stack->GetFrameCount();
        std::stringstream ss;
        for (int i = 0; i < framesCount; i++) {
          Local<StackFrame> frame = v8Stack->GetFrame(isolate, i);
          ss << BuildStacktraceFrameMessage(isolate, frame) << std::endl;
        }
        stack = ss.str();
      }
    }
  }

  // 2) TryCatch-provided stack if available
  if (stack.empty() && tryCatch != nullptr) {
    Local<Value> stackVal;
    if (tryCatch->StackTrace(context).ToLocal(&stackVal) && stackVal->IsString()) {
      stack = tns::ToString(isolate, stackVal.As<v8::String>());
    } else {
      Local<Message> message = tryCatch->Message();
      if (!message.IsEmpty()) {
        Local<StackTrace> v8Stack = message->GetStackTrace();
        if (!v8Stack.IsEmpty()) {
          int framesCount = v8Stack->GetFrameCount();
          std::stringstream ss;
          for (int i = 0; i < framesCount; i++) {
            Local<StackFrame> frame = v8Stack->GetFrame(isolate, i);
            ss << BuildStacktraceFrameMessage(isolate, frame) << std::endl;
          }
          stack = ss.str();
        }
      }
    }
  }

  // 3) Finally, current stack if still empty
  if (stack.empty()) {
    stack = tns::GetStackTrace(isolate);
  }

  return stack;
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
    ss << "at new " << functionNameStr << " ("
       << tns::BuildStacktraceFrameLocationPart(isolate, frame) << ")";
  } else if (frame->IsEval()) {
    ss << "eval at " << BuildStacktraceFrameLocationPart(isolate, frame) << std::endl;
  } else {
    ss << "at " << functionNameStr << " (" << tns::BuildStacktraceFrameLocationPart(isolate, frame)
       << ")";
  }

  std::string stringResult = ss.str();

  return stringResult;
}

bool tns::LiveSync(Isolate* isolate) {
  v8::Locker locker(isolate);
  Isolate::Scope isolate_scope(isolate);
  HandleScope handle_scope(isolate);
  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  Local<Context> context = cache->GetContext();
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

void tns::Assert(bool condition, Isolate* isolate, std::string const& reason) {
  if (!RuntimeConfig.IsDebug) {
    assert(condition);
    return;
  }

  if (condition) {
    return;
  }

  if (isolate == nullptr) {
    Runtime* runtime = Runtime::GetCurrentRuntime();
    if (runtime != nullptr) {
      isolate = runtime->GetIsolate();
    }
  }

  if (isolate == nullptr) {
    Log(@"====== Assertion failed ======");
    if (!reason.empty()) {
      Log(@"Reason: %s", reason.c_str());
    }
    Log(@"Native stack trace:");
    LogBacktrace();
    assert(false);
    return;
  }

  Log(@"====== Assertion failed ======");
  Log(@"Native stack trace:");
  LogBacktrace();

  Log(@"JavaScript stack trace:");
  std::string stack = tns::GetStackTrace(isolate);
  Log(@"%s", stack.c_str());
  assert(false);
}

void tns::StopExecutionAndLogStackTrace(v8::Isolate* isolate) { Assert(false, isolate); }

namespace tns {
Local<v8::FunctionTemplate> NewFunctionTemplate(v8::Isolate* isolate, v8::FunctionCallback callback,
                                                Local<v8::Value> data,
                                                Local<v8::Signature> signature,
                                                v8::ConstructorBehavior behavior,
                                                v8::SideEffectType side_effect_type,
                                                const v8::CFunction* c_function) {
  return v8::FunctionTemplate::New(isolate, callback, data, signature, 0, behavior,
                                   side_effect_type, c_function);
}
void SetMethod(Local<v8::Context> context, Local<v8::Object> that, const char* name,
               v8::FunctionCallback callback, Local<v8::Value> data) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<v8::Function> function =
      NewFunctionTemplate(isolate, callback, data, Local<v8::Signature>(),
                          v8::ConstructorBehavior::kThrow, v8::SideEffectType::kHasSideEffect)
          ->GetFunction(context)
          .ToLocalChecked();
  // kInternalized strings are created in the old space.
  const v8::NewStringType type = v8::NewStringType::kInternalized;
  Local<v8::String> name_string = v8::String::NewFromUtf8(isolate, name, type).ToLocalChecked();
  that->Set(context, name_string, function).Check();
  function->SetName(name_string);  // NODE_SET_METHOD() compatibility.
}
void SetMethod(v8::Isolate* isolate, v8::Local<v8::Template> that, const char* name,
               v8::FunctionCallback callback, Local<v8::Value> data) {
  Local<v8::FunctionTemplate> t =
      NewFunctionTemplate(isolate, callback, data, Local<v8::Signature>(),
                          v8::ConstructorBehavior::kThrow, v8::SideEffectType::kHasSideEffect);
  // kInternalized strings are created in the old space.
  const v8::NewStringType type = v8::NewStringType::kInternalized;
  Local<v8::String> name_string = v8::String::NewFromUtf8(isolate, name, type).ToLocalChecked();
  that->Set(name_string, t);
}
void SetFastMethod(Isolate* isolate, Local<Template> that, const char* name,
                   v8::FunctionCallback slow_callback, const v8::CFunction* c_function,
                   Local<v8::Value> data) {
  Local<v8::FunctionTemplate> t = NewFunctionTemplate(
      isolate, slow_callback, data, Local<v8::Signature>(), v8::ConstructorBehavior::kThrow,
      v8::SideEffectType::kHasSideEffect, c_function);
  // kInternalized strings are created in the old space.
  const v8::NewStringType type = v8::NewStringType::kInternalized;
  Local<v8::String> name_string = v8::String::NewFromUtf8(isolate, name, type).ToLocalChecked();
  that->Set(name_string, t);
}
void SetFastMethod(Local<v8::Context> context, Local<v8::Object> that, const char* name,
                   v8::FunctionCallback slow_callback, const v8::CFunction* c_function,
                   Local<v8::Value> data) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<v8::Function> function =
      NewFunctionTemplate(isolate, slow_callback, data, Local<v8::Signature>(),
                          v8::ConstructorBehavior::kThrow, v8::SideEffectType::kHasSideEffect,
                          c_function)
          ->GetFunction(context)
          .ToLocalChecked();
  const v8::NewStringType type = v8::NewStringType::kInternalized;
  Local<v8::String> name_string = v8::String::NewFromUtf8(isolate, name, type).ToLocalChecked();
  that->Set(context, name_string, function).Check();
}
void SetFastMethodNoSideEffect(Local<v8::Context> context, Local<v8::Object> that, const char* name,
                               v8::FunctionCallback slow_callback, const v8::CFunction* c_function,
                               Local<v8::Value> data) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<v8::Function> function =
      NewFunctionTemplate(isolate, slow_callback, data, Local<v8::Signature>(),
                          v8::ConstructorBehavior::kThrow, v8::SideEffectType::kHasNoSideEffect,
                          c_function)
          ->GetFunction(context)
          .ToLocalChecked();
  const v8::NewStringType type = v8::NewStringType::kInternalized;
  Local<v8::String> name_string = v8::String::NewFromUtf8(isolate, name, type).ToLocalChecked();
  that->Set(context, name_string, function).Check();
}
void SetFastMethodNoSideEffect(Isolate* isolate, Local<Template> that, const char* name,
                               v8::FunctionCallback slow_callback, const v8::CFunction* c_function,
                               Local<v8::Value> data) {
  Local<v8::FunctionTemplate> t = NewFunctionTemplate(
      isolate, slow_callback, data, Local<v8::Signature>(), v8::ConstructorBehavior::kThrow,
      v8::SideEffectType::kHasNoSideEffect, c_function);
  // kInternalized strings are created in the old space.
  const v8::NewStringType type = v8::NewStringType::kInternalized;
  Local<v8::String> name_string = v8::String::NewFromUtf8(isolate, name, type).ToLocalChecked();
  that->Set(name_string, t);
}
void SetMethodNoSideEffect(Local<v8::Context> context, Local<v8::Object> that, const char* name,
                           v8::FunctionCallback callback, Local<v8::Value> data) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<v8::Function> function =
      NewFunctionTemplate(isolate, callback, data, Local<v8::Signature>(),
                          v8::ConstructorBehavior::kThrow, v8::SideEffectType::kHasNoSideEffect)
          ->GetFunction(context)
          .ToLocalChecked();
  // kInternalized strings are created in the old space.
  const v8::NewStringType type = v8::NewStringType::kInternalized;
  Local<v8::String> name_string = v8::String::NewFromUtf8(isolate, name, type).ToLocalChecked();
  that->Set(context, name_string, function).Check();
  function->SetName(name_string);  // NODE_SET_METHOD() compatibility.
}
void SetMethodNoSideEffect(Isolate* isolate, Local<v8::Template> that, const char* name,
                           v8::FunctionCallback callback, Local<v8::Value> data) {
  Local<v8::FunctionTemplate> t =
      NewFunctionTemplate(isolate, callback, data, Local<v8::Signature>(),
                          v8::ConstructorBehavior::kThrow, v8::SideEffectType::kHasNoSideEffect);
  // kInternalized strings are created in the old space.
  const v8::NewStringType type = v8::NewStringType::kInternalized;
  Local<v8::String> name_string = v8::String::NewFromUtf8(isolate, name, type).ToLocalChecked();
  that->Set(name_string, t);
}
void SetProtoMethod(v8::Isolate* isolate, Local<v8::FunctionTemplate> that, const char* name,
                    v8::FunctionCallback callback, Local<v8::Value> data) {
  Local<v8::Signature> signature = v8::Signature::New(isolate, that);
  Local<v8::FunctionTemplate> t =
      NewFunctionTemplate(isolate, callback, data, signature, v8::ConstructorBehavior::kThrow,
                          v8::SideEffectType::kHasSideEffect);
  // kInternalized strings are created in the old space.
  const v8::NewStringType type = v8::NewStringType::kInternalized;
  Local<v8::String> name_string = v8::String::NewFromUtf8(isolate, name, type).ToLocalChecked();
  that->PrototypeTemplate()->Set(name_string, t);
  t->SetClassName(name_string);  // NODE_SET_PROTOTYPE_METHOD() compatibility.
}
void SetProtoMethodNoSideEffect(v8::Isolate* isolate, Local<v8::FunctionTemplate> that,
                                const char* name, v8::FunctionCallback callback,
                                Local<v8::Value> data) {
  Local<v8::Signature> signature = v8::Signature::New(isolate, that);
  Local<v8::FunctionTemplate> t =
      NewFunctionTemplate(isolate, callback, data, signature, v8::ConstructorBehavior::kThrow,
                          v8::SideEffectType::kHasNoSideEffect);
  // kInternalized strings are created in the old space.
  const v8::NewStringType type = v8::NewStringType::kInternalized;
  Local<v8::String> name_string = v8::String::NewFromUtf8(isolate, name, type).ToLocalChecked();
  that->PrototypeTemplate()->Set(name_string, t);
  t->SetClassName(name_string);  // NODE_SET_PROTOTYPE_METHOD() compatibility.
}
void SetInstanceMethod(v8::Isolate* isolate, Local<v8::FunctionTemplate> that, const char* name,
                       v8::FunctionCallback callback, Local<v8::Value> data) {
  Local<v8::Signature> signature = v8::Signature::New(isolate, that);
  Local<v8::FunctionTemplate> t =
      NewFunctionTemplate(isolate, callback, data, signature, v8::ConstructorBehavior::kThrow,
                          v8::SideEffectType::kHasSideEffect);
  // kInternalized strings are created in the old space.
  const v8::NewStringType type = v8::NewStringType::kInternalized;
  Local<v8::String> name_string = v8::String::NewFromUtf8(isolate, name, type).ToLocalChecked();
  that->InstanceTemplate()->Set(name_string, t);
  t->SetClassName(name_string);
}
void SetConstructorFunction(Local<v8::Context> context, Local<v8::Object> that, const char* name,
                            Local<v8::FunctionTemplate> tmpl, SetConstructorFunctionFlag flag) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  SetConstructorFunction(context, that, tns::OneByteString(isolate, name), tmpl, flag);
}
void SetConstructorFunction(Local<Context> context, Local<Object> that, Local<v8::String> name,
                            Local<FunctionTemplate> tmpl, SetConstructorFunctionFlag flag) {
  if (flag == SetConstructorFunctionFlag::SET_CLASS_NAME) tmpl->SetClassName(name);
  that->Set(context, name, tmpl->GetFunction(context).ToLocalChecked()).Check();
}
void SetConstructorFunction(Isolate* isolate, Local<Template> that, const char* name,
                            Local<FunctionTemplate> tmpl, SetConstructorFunctionFlag flag) {
  SetConstructorFunction(isolate, that, OneByteString(isolate, name), tmpl, flag);
}
void SetConstructorFunction(Isolate* isolate, Local<Template> that, Local<v8::String> name,
                            Local<FunctionTemplate> tmpl, SetConstructorFunctionFlag flag) {
  if (flag == SetConstructorFunctionFlag::SET_CLASS_NAME) tmpl->SetClassName(name);
  that->Set(name, tmpl);
}
};  // namespace tns
