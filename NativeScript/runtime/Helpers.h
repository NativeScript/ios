#ifndef Helpers_h
#define Helpers_h

#include <atomic>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <string>
#include <vector>

#include "ArcMacro.h"
#include "Common.h"
#include "DataWrapper.h"

#ifdef __OBJC__
#include <Foundation/Foundation.h>
#else
#include <CoreFoundation/CoreFoundation.h>
extern "C" void NSLog(CFStringRef format, ...);
#endif

#if defined(__has_include)
#if __has_include(<os/log.h>)
#include <os/log.h>
#define TNS_HAVE_OS_LOG 1
#else
#define TNS_HAVE_OS_LOG 0
#endif
#else
#define TNS_HAVE_OS_LOG 0
#endif

namespace tns {

inline v8::Local<v8::String> ToV8String(v8::Isolate* isolate, const std::string& value) {
  return v8::String::NewFromUtf8(isolate, value.c_str(), v8::NewStringType::kNormal,
                                 (int)value.length())
      .ToLocalChecked();
}

inline v8::Local<v8::String> ToV8String(v8::Isolate* isolate, const char* value, int length) {
  return v8::String::NewFromUtf8(isolate, value, v8::NewStringType::kNormal, length)
      .ToLocalChecked();
}

// Without this overload a bare `const char*` — every string literal, every
// c_str(), every jsName() — picks the std::string one and pays for a temporary
// just to reach V8.
inline v8::Local<v8::String> ToV8String(v8::Isolate* isolate, const char* value) {
  return v8::String::NewFromUtf8(isolate, value).ToLocalChecked();
}
#ifdef __OBJC__
// Both sides store text as either 8-bit or UTF-16, never UTF-8, so the buffer is
// handed to V8 in whichever width CFString already holds. Going through
// -UTF8String instead would encode the string twice (once for the bytes, once
// for -lengthOfBytesUsingEncoding:), allocate, and return nil for strings
// containing a lone surrogate — silently turning them into "".
inline v8::Local<v8::String> ToV8String(v8::Isolate* isolate, const NSString* value) {
  if (value == nil) {
    return v8::String::Empty(isolate);
  }

  CFStringRef str = (__bridge CFStringRef)value;
  CFIndex length = CFStringGetLength(str);
  if (length == 0) {
    return v8::String::Empty(isolate);
  }

  // An ASCII pointer is handed back only when every code unit is < 0x80, so the
  // code unit count doubles as the byte count.
  if (const char* ascii = CFStringGetCStringPtr(str, kCFStringEncodingASCII)) {
    return v8::String::NewFromOneByte(isolate, reinterpret_cast<const uint8_t*>(ascii),
                                      v8::NewStringType::kNormal, (int)length)
        .ToLocalChecked();
  }

  if (const UniChar* utf16 = CFStringGetCharactersPtr(str)) {
    return v8::String::NewFromTwoByte(isolate, reinterpret_cast<const uint16_t*>(utf16),
                                      v8::NewStringType::kNormal, (int)length)
        .ToLocalChecked();
  }

  // Tagged pointers and some bridged strings expose neither buffer, so the
  // contents have to be copied out. The narrow attempt writes at most `length`
  // bytes, which always fits the UTF-16-sized buffer.
  constexpr CFIndex kStackUnits = 256;
  uint16_t stackBuffer[kStackUnits];
  std::vector<uint16_t> heapBuffer;
  uint16_t* buffer = stackBuffer;
  if (length > kStackUnits) {
    heapBuffer.resize((size_t)length);
    buffer = heapBuffer.data();
  }

  CFRange range = CFRangeMake(0, length);
  CFIndex usedLength = 0;
  if (CFStringGetBytes(str, range, kCFStringEncodingASCII, 0, false,
                       reinterpret_cast<UInt8*>(buffer), length, &usedLength) == length) {
    return v8::String::NewFromOneByte(isolate, reinterpret_cast<const uint8_t*>(buffer),
                                      v8::NewStringType::kNormal, (int)length)
        .ToLocalChecked();
  }

  CFStringGetCharacters(str, range, reinterpret_cast<UniChar*>(buffer));
  return v8::String::NewFromTwoByte(isolate, buffer, v8::NewStringType::kNormal, (int)length)
      .ToLocalChecked();
}
#endif
// Unwraps a value to the v8::String the text conversions below read from.
// A throwing toString() is swallowed rather than left pending, which is the
// contract v8::String::Utf8Value offered and callers were written against.
inline bool ToStringLocal(v8::Isolate* isolate, const v8::Local<v8::Value>& value,
                          v8::Local<v8::String>& out) {
  if (value.IsEmpty()) {
    return false;
  }

  if (value->IsString()) {
    out = value.As<v8::String>();
    return true;
  }

  if (value->IsStringObject()) {
    out = value.As<v8::StringObject>()->ValueOf();
    return true;
  }

  v8::TryCatch tc(isolate);
  return value->ToString(isolate->GetCurrentContext()).ToLocal(&out);
}

inline std::string ToString(v8::Isolate* isolate, const v8::Local<v8::Value>& value) {
  v8::Local<v8::String> str;
  if (!ToStringLocal(isolate, value, str)) {
    return std::string();
  }

  {
    v8::String::ValueView view(isolate, str);
    if (view.is_one_byte()) {
      const uint8_t* data = view.data8();
      uint32_t length = view.length();
      uint32_t i = 0;
      while (i < length && data[i] < 0x80) {
        i++;
      }
      // Pure ASCII already is its own UTF-8 encoding, so it can be copied
      // straight out. A one-byte string with a high byte is Latin-1 and still
      // needs widening, which the encode below handles.
      if (i == length) {
        return std::string(reinterpret_cast<const char*>(data), length);
      }
    }
  }

  size_t length = str->Utf8LengthV2(isolate);
  std::string result(length, '\0');
  if (length > 0) {
    str->WriteUtf8V2(isolate, result.data(), length, v8::String::WriteFlags::kReplaceInvalidUtf8);
  }

  return result;
}

#ifdef __OBJC__
// Encodes via V8 rather than -UTF8String, which returns nil for a string holding
// a lone surrogate — leaving callers to construct a std::string from nullptr.
// The unpaired half becomes U+FFFD, since it has no UTF-8 spelling.
inline std::string ToString(v8::Isolate* isolate, const NSString* value) {
  return tns::ToString(isolate, tns::ToV8String(isolate, value));
}

inline NSString* ToNSString(const std::string& v) {
  return [[[NSString alloc] initWithBytes:v.c_str() length:v.length()
                                 encoding:NSUTF8StringEncoding] S_AUTORELEASE];
}
// Reads the V8 string's native UTF-16 buffer directly so lone surrogates and
// embedded NUL survive the bridge; a UTF-8 round-trip loses both.
inline NSString* ToNSString(v8::Isolate* isolate, const v8::Local<v8::Value>& value) {
  if (value.IsEmpty()) {
    return @"";
  }

  if (value->IsStringObject()) {
    v8::Local<v8::String> obj = value.As<v8::StringObject>()->ValueOf();
    return ToNSString(isolate, obj);
  }

  v8::Local<v8::String> str;
  if (!value->ToString(isolate->GetCurrentContext()).ToLocal(&str)) {
    return @"";
  }

  v8::String::ValueView result(isolate, str);
  if (result.is_one_byte()) {
    // A one-byte V8 string is Latin-1, not UTF-8.
    return [[[NSString alloc] initWithBytes:result.data8()
                                     length:result.length()
                                   encoding:NSISOLatin1StringEncoding] S_AUTORELEASE];
  }

  return [NSString stringWithCharacters:(const unichar*)result.data16() length:result.length()];
}
#endif
std::u16string ToUtf16String(v8::Isolate* isolate, const v8::Local<v8::Value>& value);
inline double ToNumber(v8::Isolate* isolate, const v8::Local<v8::Value>& value) {
  double result = NAN;

  if (value.IsEmpty()) {
    return result;
  }

  if (value->IsNumberObject()) {
    result = value.As<v8::NumberObject>()->ValueOf();
  } else if (value->IsNumber()) {
    result = value.As<v8::Number>()->Value();
  } else {
    v8::Local<v8::Number> number;
    v8::Local<v8::Context> context = isolate->GetCurrentContext();
    bool success = value->ToNumber(context).ToLocal(&number);
    if (success) {
      result = number->Value();
    }
  }

  return result;
}
inline bool ToBool(const v8::Local<v8::Value>& value) {
  bool result = false;

  if (value.IsEmpty()) {
    return result;
  }

  if (value->IsBooleanObject()) {
    result = value.As<v8::BooleanObject>()->ValueOf();
  } else if (value->IsBoolean()) {
    result = value.As<v8::Boolean>()->Value();
  }

  return result;
}
bool Exists(const char* fullPath);
v8::Local<v8::String> ReadModule(v8::Isolate* isolate, const std::string& filePath);
const char* ReadText(const std::string& filePath, long& length, bool& isNew);
std::string ReadText(const std::string& file);
uint8_t* ReadBinary(const std::string path, long& length, bool& isNew);
bool WriteBinary(const std::string& path, const void* data, long length);

void SetPrivateValue(const v8::Local<v8::Object>& obj, const v8::Local<v8::String>& propName,
                     const v8::Local<v8::Value>& value);
v8::Local<v8::Value> GetPrivateValue(const v8::Local<v8::Object>& obj,
                                     const v8::Local<v8::String>& propName);

void SetValue(v8::Isolate* isolate, const v8::Local<v8::Object>& obj, BaseDataWrapper* value);
BaseDataWrapper* GetValue(v8::Isolate* isolate, const v8::Local<v8::Value>& val);

// What happens when JS touches a wrapper whose native counterpart has already
// been released (its internal field was neutered by DisposeValue) — a state a
// resurrected object can expose by outliving a referenced object's native
// half; see docs/knowledge/v8-resurrecting-finalizers.md. Process-wide,
// configured via the `releasedObjectPolicy` key of ns:runtime's setConfig.
enum class ReleasedObjectPolicy {
  // No-op the operation and fire the `releasednativeaccess` global event
  // (console.warn additionally in debug). The default.
  kReport = 0,
  // Throw a catchable JS ReferenceError at the touch site.
  kThrow = 1,
};
ReleasedObjectPolicy GetReleasedObjectPolicy();
void SetReleasedObjectPolicy(ReleasedObjectPolicy policy);

// Like GetValue, but applies ReleasedObjectPolicy when the object carries no
// wrapper: throws (kThrow) or schedules a `releasednativeaccess` event
// (kReport, deduplicated per object), returning nullptr either way.
// `operation` names the API surface for the event payload / error message.
// Callers must no-op on nullptr; paths that would otherwise read the internal
// field unchecked must go through this.
BaseDataWrapper* GetValueOrReport(v8::Isolate* isolate, const v8::Local<v8::Value>& val,
                                  const char* operation);
void DeleteValue(v8::Isolate* isolate, const v8::Local<v8::Value>& val);
bool DeleteWrapperIfUnused(v8::Isolate* isolate, const v8::Local<v8::Value>& obj,
                           BaseDataWrapper* value);
std::vector<v8::Local<v8::Value>> ArgsToVector(const v8::FunctionCallbackInfo<v8::Value>& info);

inline bool IsString(const v8::Local<v8::Value>& value) {
  return !value.IsEmpty() && (value->IsString() || value->IsStringObject());
}

inline bool IsNumber(const v8::Local<v8::Value>& value) {
  return !value.IsEmpty() && (value->IsNumber() || value->IsNumberObject());
}

inline bool IsBigInt(const v8::Local<v8::Value>& value) {
  return !value.IsEmpty() && (value->IsBigInt() || value->IsBigIntObject());
}

inline bool IsBool(const v8::Local<v8::Value>& value) {
  return !value.IsEmpty() && (value->IsBoolean() || value->IsBooleanObject());
}

bool IsArrayOrArrayLike(v8::Isolate* isolate, const v8::Local<v8::Value>& value);
void* TryGetBufferFromArrayBuffer(const v8::Local<v8::Value>& value, bool& isArrayBuffer);

void ExecuteOnRunLoop(CFRunLoopRef queue, void (^func)(void), bool async = true);
void ExecuteOnDispatchQueue(dispatch_queue_t queue, std::function<void()> func, bool async = true);
void ExecuteOnMainThread(std::function<void()> func, bool async = true);

void LogError(v8::Isolate* isolate, v8::TryCatch& tc);
void LogBacktrace(int skip = 1);

// Robust logging: prefer os_log when available (supports privacy markers).
// To ensure messages are not redacted by the unified logging system we
// format the final message into a C string and pass it as a single
// "%{public}s" argument to os_log. When os_log is not available we
// fall back to NSLog (Objective-C) or CF/NSLog bridge in pure C++ builds.

#ifdef __OBJC__
// Overload for Objective-C string literals (NSString*)
static inline void TNS_FormatAndLog(NSString* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);

  // Use NSString's formatting to handle both C and Objective-C format
  // specifiers
  NSString* formattedString = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);

  if (!formattedString) {
    return;
  }

  // Convert to C string for logging
  const char* cStr = [formattedString UTF8String];
  if (!cStr) {
    return;
  }

#if TNS_HAVE_OS_LOG
  os_log(OS_LOG_DEFAULT, "%{public}s", cStr);
#else
  NSLog(@"%s", cStr);
#endif
}
#endif

// Main implementation for C string literals
static inline void TNS_FormatAndLog(const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);

  // Fast path: try a reasonably sized stack buffer first to avoid heap
  // allocation and a second formatting pass in the common case.
  const int STACK_BUF_SIZE = 1024;
  char stack_buf[STACK_BUF_SIZE];

  va_list ap_copy;
  va_copy(ap_copy, ap);
  int needed = vsnprintf(stack_buf, STACK_BUF_SIZE, fmt, ap_copy);
  va_end(ap_copy);

  if (needed < 0) {
    va_end(ap);
    return;
  }

  if (needed < STACK_BUF_SIZE) {
    // Message fit into stack buffer — single formatting pass.
#if TNS_HAVE_OS_LOG
    os_log(OS_LOG_DEFAULT, "%{public}s", stack_buf);
#else
    // Fall back to NSLog. Use Objective-C API when compiling as ObjC++.
#ifdef __OBJC__
    NSLog(@"%s", stack_buf);
#else
    NSLog(CFSTR("%s"), stack_buf);
#endif
#endif
  } else {
    // Needs heap allocation; format again into the correctly sized buffer.
    std::vector<char> buffer((size_t)needed + 1);
    vsnprintf(buffer.data(), buffer.size(), fmt, ap);

#if TNS_HAVE_OS_LOG
    os_log(OS_LOG_DEFAULT, "%{public}s", buffer.data());
#else
    // Fall back to NSLog. Use Objective-C API when compiling as ObjC++.
#ifdef __OBJC__
    NSLog(@"%s", buffer.data());
#else
    NSLog(CFSTR("%s"), buffer.data());
#endif
#endif
  }

  va_end(ap);
}

// Keep the existing Log(...) macro name for call-site compatibility.
#define Log(...) tns::TNS_FormatAndLog(__VA_ARGS__)

// ── Category-scoped debug tracing ─────────────────────────────
//
// A process-wide bitmask of enabled categories, tested inline at every call
// site, so a disabled category costs one relaxed load and a well-predicted
// branch. Present in every build: these are traces, and a release build that
// cannot be traced is a release build that cannot be diagnosed. Error and
// lifecycle logs are unconditional and do not belong here.
//
// Turned on by the NS_DEBUG environment variable (read once at process init)
// or by ns:runtime's `debug` config key.

enum class LogCategory : uint8_t {
  Esm,       // module resolution, compilation, linking, evaluation
  Fetch,     // the HTTP module transport
  Registry,  // registry invalidation and dynamic-import cache bookkeeping
  kCount
};

// One bit per LogCategory. Written from process init and from main-isolate
// setConfig; read from every thread. Relaxed suffices — a trace line racing a
// toggle changes nothing but that line.
inline std::atomic<uint32_t> g_enabledLogCategories{0};

inline bool LogCategoryEnabled(LogCategory category) {
  return (g_enabledLogCategories.load(std::memory_order_relaxed) &
          (1u << static_cast<uint8_t>(category))) != 0;
}

// Writes one trace line under `category`, prefixed with the category name.
// Out of line so nothing but the enabled test lands at the call site.
void EmitDebugLog(LogCategory category, const char* format, ...)
    __attribute__((format(printf, 2, 3)));

const char* LogCategoryName(LogCategory category);
// Every category name, comma separated — for the "valid categories are …"
// diagnostic.
std::string AllLogCategoryNames();
// A comma-separated category list to a mask. Unknown names are skipped and
// reported through `hadUnknown` rather than failing the whole list.
uint32_t ParseLogCategories(const std::string& list, bool* hadUnknown);
// The canonical comma-separated list of the categories currently enabled.
std::string EnabledLogCategoryNames();
void SetEnabledLogCategories(uint32_t mask);
// Applies NS_DEBUG. Call once, before anything worth tracing runs.
void InitializeLogCategoriesFromEnvironment();

// A MACRO rather than a function or template on purpose: the arguments must
// not be evaluated unless the category is on, and call sites routinely build
// strings that cost far more than the line they would print.
#define TNS_DEBUG(category, ...)                                            \
  do {                                                                      \
    if (tns::LogCategoryEnabled(tns::LogCategory::category)) [[unlikely]] { \
      tns::EmitDebugLog(tns::LogCategory::category, __VA_ARGS__);           \
    }                                                                       \
  } while (0)

// Short identification for objects backed by a native wrapper (ObjC class
// name etc.); empty when the value is a plain JS object. Never runs JS.
std::string GetNativeWrapperHint(v8::Isolate* isolate, const v8::Local<v8::Value>& value);

std::string ReplaceAll(const std::string source, std::string find, std::string replacement);

const std::string BuildStacktraceFrameLocationPart(v8::Isolate* isolate,
                                                   v8::Local<v8::StackFrame> frame);
const std::string BuildStacktraceFrameMessage(v8::Isolate* isolate,
                                              v8::Local<v8::StackFrame> frame);
const std::string GetStackTrace(v8::Isolate* isolate);
const std::string GetCurrentScriptUrl(v8::Isolate* isolate);

// Returns stack trace string remapped to original sources using global __ns_remapStack if present.
std::string RemapStackTraceIfAvailable(v8::Isolate* isolate, const std::string& stackTrace);

// Smart stack extraction that prefers:
// 1) exception.stack if provided
// 2) TryCatch.StackTrace / Message()->GetStackTrace when TryCatch provided
// 3) Current stack via GetStackTrace
std::string GetSmartStackTrace(v8::Isolate* isolate, v8::TryCatch* tryCatch = nullptr,
                               v8::Local<v8::Value> exception = v8::Local<v8::Value>());

bool LiveSync(v8::Isolate* isolate);

void Assert(bool condition, v8::Isolate* isolate = nullptr,
            std::string const& reason = std::string());

void StopExecutionAndLogStackTrace(v8::Isolate* isolate);

// Helpers from Node
inline v8::Local<v8::String> OneByteString(v8::Isolate* isolate, const char* data, int length) {
  return v8::String::NewFromOneByte(isolate, reinterpret_cast<const uint8_t*>(data),
                                    v8::NewStringType::kNormal, length)
      .ToLocalChecked();
}
inline v8::Local<v8::String> OneByteString(v8::Isolate* isolate, const signed char* data,
                                           int length) {
  return v8::String::NewFromOneByte(isolate, reinterpret_cast<const uint8_t*>(data),
                                    v8::NewStringType::kNormal, length)
      .ToLocalChecked();
}
inline v8::Local<v8::String> OneByteString(v8::Isolate* isolate, const unsigned char* data,
                                           int length) {
  return v8::String::NewFromOneByte(isolate, data, v8::NewStringType::kNormal, length)
      .ToLocalChecked();
}

// Convenience wrapper around v8::String::NewFromOneByte().
inline v8::Local<v8::String> OneByteString(v8::Isolate* isolate, const char* data, int length = -1);
// For the people that compile with -funsigned-char.
inline v8::Local<v8::String> OneByteString(v8::Isolate* isolate, const signed char* data,
                                           int length = -1);
inline v8::Local<v8::String> OneByteString(v8::Isolate* isolate, const unsigned char* data,
                                           int length = -1);

v8::Local<v8::FunctionTemplate> NewFunctionTemplate(
    v8::Isolate* isolate, v8::FunctionCallback callback,
    v8::Local<v8::Value> data = v8::Local<v8::Value>(),
    v8::Local<v8::Signature> signature = v8::Local<v8::Signature>(),
    v8::ConstructorBehavior behavior = v8::ConstructorBehavior::kAllow,
    v8::SideEffectType side_effect = v8::SideEffectType::kHasSideEffect,
    const v8::CFunction* c_function = nullptr);
// Convenience methods for NewFunctionTemplate().
void SetMethod(v8::Local<v8::Context> context, v8::Local<v8::Object> that, const char* name,
               v8::FunctionCallback callback, v8::Local<v8::Value> data = v8::Local<v8::Value>());
// Similar to SetProtoMethod but without receiver signature checks.
void SetMethod(v8::Isolate* isolate, v8::Local<v8::Template> that, const char* name,
               v8::FunctionCallback callback, v8::Local<v8::Value> data = v8::Local<v8::Value>());
// Whether the runtime registers v8::CFunction fast-call overloads next to the
// slow callbacks. A registered overload is inert wherever the optimizing tiers
// are absent — iOS ships V8 in lite mode, which implies jitless, so every call
// there goes through the slow callback — and only fires on JIT-enabled embeds.
#ifndef NATIVESCRIPT_ENABLE_FAST_API
#define NATIVESCRIPT_ENABLE_FAST_API 1
#endif
void SetFastMethod(v8::Isolate* isolate, v8::Local<v8::Template> that, const char* name,
                   v8::FunctionCallback slow_callback, const v8::CFunction* c_function,
                   v8::Local<v8::Value> data = v8::Local<v8::Value>());
void SetFastMethod(v8::Local<v8::Context> context, v8::Local<v8::Object> that, const char* name,
                   v8::FunctionCallback slow_callback, const v8::CFunction* c_function,
                   v8::Local<v8::Value> data = v8::Local<v8::Value>());
void SetFastMethodNoSideEffect(v8::Isolate* isolate, v8::Local<v8::Template> that, const char* name,
                               v8::FunctionCallback slow_callback, const v8::CFunction* c_function,
                               v8::Local<v8::Value> data = v8::Local<v8::Value>());
void SetFastMethodNoSideEffect(v8::Local<v8::Context> context, v8::Local<v8::Object> that,
                               const char* name, v8::FunctionCallback slow_callback,
                               const v8::CFunction* c_function,
                               v8::Local<v8::Value> data = v8::Local<v8::Value>());
void SetProtoMethod(v8::Isolate* isolate, v8::Local<v8::FunctionTemplate> that, const char* name,
                    v8::FunctionCallback callback,
                    v8::Local<v8::Value> data = v8::Local<v8::Value>());
void SetInstanceMethod(v8::Isolate* isolate, v8::Local<v8::FunctionTemplate> that, const char* name,
                       v8::FunctionCallback callback,
                       v8::Local<v8::Value> data = v8::Local<v8::Value>());
// Safe variants denote the function has no side effects.
void SetMethodNoSideEffect(v8::Local<v8::Context> context, v8::Local<v8::Object> that,
                           const char* name, v8::FunctionCallback callback,
                           v8::Local<v8::Value> data = v8::Local<v8::Value>());
void SetProtoMethodNoSideEffect(v8::Isolate* isolate, v8::Local<v8::FunctionTemplate> that,
                                const char* name, v8::FunctionCallback callback,
                                v8::Local<v8::Value> data = v8::Local<v8::Value>());
void SetMethodNoSideEffect(v8::Isolate* isolate, v8::Local<v8::Template> that, const char* name,
                           v8::FunctionCallback callback,
                           v8::Local<v8::Value> data = v8::Local<v8::Value>());
enum class SetConstructorFunctionFlag {
  NONE,
  SET_CLASS_NAME,
};
void SetConstructorFunction(
    v8::Local<v8::Context> context, v8::Local<v8::Object> that, const char* name,
    v8::Local<v8::FunctionTemplate> tmpl,
    SetConstructorFunctionFlag flag = SetConstructorFunctionFlag::SET_CLASS_NAME);
void SetConstructorFunction(
    v8::Local<v8::Context> context, v8::Local<v8::Object> that, v8::Local<v8::String> name,
    v8::Local<v8::FunctionTemplate> tmpl,
    SetConstructorFunctionFlag flag = SetConstructorFunctionFlag::SET_CLASS_NAME);
void SetConstructorFunction(
    v8::Isolate* isolate, v8::Local<v8::Template> that, const char* name,
    v8::Local<v8::FunctionTemplate> tmpl,
    SetConstructorFunctionFlag flag = SetConstructorFunctionFlag::SET_CLASS_NAME);
void SetConstructorFunction(
    v8::Isolate* isolate, v8::Local<v8::Template> that, v8::Local<v8::String> name,
    v8::Local<v8::FunctionTemplate> tmpl,
    SetConstructorFunctionFlag flag = SetConstructorFunctionFlag::SET_CLASS_NAME);

template <int N>
inline v8::Local<v8::String> FIXED_ONE_BYTE_STRING(v8::Isolate* isolate, const char (&data)[N]) {
  return OneByteString(isolate, data, N - 1);
}

template <std::size_t N>
inline v8::Local<v8::String> FIXED_ONE_BYTE_STRING(v8::Isolate* isolate,
                                                   const std::array<char, N>& arr) {
  return OneByteString(isolate, arr.data(), N - 1);
}

class PersistentToLocal {
 public:
  // If persistent.IsWeak() == false, then do not call persistent.Reset()
  // while the returned Local<T> is still in scope, it will destroy the
  // reference to the object.
  template <class TypeName>
  static inline v8::Local<TypeName> Default(v8::Isolate* isolate,
                                            const v8::PersistentBase<TypeName>& persistent) {
    if (persistent.IsWeak()) {
      return PersistentToLocal::Weak(isolate, persistent);
    } else {
      return PersistentToLocal::Strong(persistent);
    }
  }

  // Unchecked conversion from a non-weak Persistent<T> to Local<T>,
  // use with care!
  //
  // Do not call persistent.Reset() while the returned Local<T> is still in
  // scope, it will destroy the reference to the object.
  template <class TypeName>
  static inline v8::Local<TypeName> Strong(const v8::PersistentBase<TypeName>& persistent) {
    //    DCHECK(!persistent.IsWeak());
    return *reinterpret_cast<v8::Local<TypeName>*>(
        const_cast<v8::PersistentBase<TypeName>*>(&persistent));
  }

  template <class TypeName>
  static inline v8::Local<TypeName> Weak(v8::Isolate* isolate,
                                         const v8::PersistentBase<TypeName>& persistent) {
    return v8::Local<TypeName>::New(isolate, persistent);
  }
};

}  // namespace tns

#endif /* Helpers_h */
