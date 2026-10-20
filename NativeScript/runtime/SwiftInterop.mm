#include "SwiftInterop.h"

#include <dlfcn.h>

#include <atomic>
#include <cmath>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <vector>

#include "Caches.h"
#include "DataWrapper.h"
#include "EventLoop.h"
#include "Helpers.h"
#include "IsolateTracked.h"
#include "IsolateWrapper.h"
#include "NativeScriptPlatform.h"
#include "robin_hood.h"

using namespace v8;

namespace tns {
namespace SwiftInterop {

namespace {

// Largest integer magnitude a JS number represents exactly.
constexpr double kMaxSafeInteger = 9007199254740991.0;

// --- Signatures --------------------------------------------------------------

struct ValueCode {
  enum class Kind {
    Void,
    Bool,
    Signed,
    Unsigned,
    Float,
    String,
    Object,
    Enum,
    Date,
    URL,
    Data,
    Array,
    Map,
  };
  Kind kind = Kind::Void;
  int bits = 64;
  int typeIndex = -1;
  bool optional = false;
  // Array and Map: the element (value) code.
  std::vector<ValueCode> element;
};

bool ParseCode(std::string text, ValueCode& code) {
  if (!text.empty() && text.back() == '?') {
    code.optional = true;
    text.pop_back();
  }
  if (text.empty()) {
    return false;
  }
  if ((text.front() == '[' && text.back() == ']') || (text.front() == '{' && text.back() == '}')) {
    code.kind = text.front() == '[' ? ValueCode::Kind::Array : ValueCode::Kind::Map;
    code.element.emplace_back();
    ValueCode& element = code.element.back();
    return ParseCode(text.substr(1, text.size() - 2), element) &&
           element.kind != ValueCode::Kind::Void && !element.optional;
  }
  auto number = [](const std::string& digits, int& out) {
    if (digits.empty() || digits.size() > 6) {
      return false;
    }
    for (char c : digits) {
      if (c < '0' || c > '9') {
        return false;
      }
    }
    out = std::stoi(digits);
    return true;
  };
  switch (text[0]) {
    case 'v':
      code.kind = ValueCode::Kind::Void;
      return text.size() == 1;
    case 'b':
      code.kind = ValueCode::Kind::Bool;
      return text.size() == 1;
    case 's':
      code.kind = ValueCode::Kind::String;
      return text.size() == 1;
    case 'D':
      code.kind = ValueCode::Kind::Date;
      return text.size() == 1;
    case 'U':
      code.kind = ValueCode::Kind::URL;
      return text.size() == 1;
    case 'B':
      code.kind = ValueCode::Kind::Data;
      return text.size() == 1;
    case 'i':
    case 'u':
      code.kind = text[0] == 'i' ? ValueCode::Kind::Signed : ValueCode::Kind::Unsigned;
      return number(text.substr(1), code.bits) &&
             (code.bits == 8 || code.bits == 16 || code.bits == 32 || code.bits == 64);
    case 'f':
      code.kind = ValueCode::Kind::Float;
      return number(text.substr(1), code.bits) && (code.bits == 32 || code.bits == 64);
    case 'o':
      code.kind = ValueCode::Kind::Object;
      return number(text.substr(1), code.typeIndex);
    case 'e':
      code.kind = ValueCode::Kind::Enum;
      return number(text.substr(1), code.typeIndex);
    default:
      return false;
  }
}

// The code map keys are reported with.
const ValueCode& KeyCode() {
  static const ValueCode code = [] {
    ValueCode key;
    key.kind = ValueCode::Kind::String;
    return key;
  }();
  return code;
}

struct Signature {
  std::vector<ValueCode> parameters;
  ValueCode result;
};

bool ParseSignature(const std::string& text, Signature& signature) {
  size_t arrow = text.find('>');
  if (arrow == std::string::npos) {
    return false;
  }
  std::string parameters = text.substr(0, arrow);
  size_t start = 0;
  while (start < parameters.size()) {
    size_t comma = parameters.find(',', start);
    std::string part =
        parameters.substr(start, comma == std::string::npos ? std::string::npos : comma - start);
    ValueCode code;
    if (!ParseCode(part, code) || code.kind == ValueCode::Kind::Void) {
      return false;
    }
    signature.parameters.push_back(code);
    if (comma == std::string::npos) {
      break;
    }
    start = comma + 1;
  }
  return ParseCode(text.substr(arrow + 1), signature.result);
}

// "greet(name:times:)" -> {"name", "times"}; "describe(_:)" -> {""}.
std::vector<std::string> LabelsOf(const std::string& swiftName) {
  std::vector<std::string> labels;
  size_t open = swiftName.find('(');
  if (open == std::string::npos || swiftName.back() != ')') {
    return labels;
  }
  std::string inner = swiftName.substr(open + 1, swiftName.size() - open - 2);
  size_t start = 0;
  while (start < inner.size()) {
    size_t colon = inner.find(':', start);
    if (colon == std::string::npos) {
      break;
    }
    std::string label = inner.substr(start, colon - start);
    labels.push_back(label == "_" ? "" : label);
    start = colon + 1;
  }
  return labels;
}

// --- Process-wide module registry ---------------------------------------------
//
// Registration data (names, signatures, thunk pointers) is immutable once a
// module is registered, so every isolate shares it.

struct ModuleInfo;

struct MemberInfo {
  int owner = -1;
  uint32_t kind = 0;
  uint32_t flags = 0;
  std::string jsName;
  std::string swiftName;
  std::string signatureText;
  Signature signature;
  std::vector<std::string> labels;
  NSSwiftThunk thunk = nullptr;
  NSSwiftThunk setter = nullptr;
};

// Overloads sharing one JS name on one owner.
struct MemberGroup {
  const ModuleInfo* module = nullptr;
  int owner = -1;
  uint32_t kind = 0;
  std::string jsName;
  std::vector<const MemberInfo*> overloads;
};

struct TypeInfo {
  uint32_t index = 0;
  uint32_t kind = 0;
  std::string jsName;
  std::string swiftName;
  int superIndex = -1;
  const ModuleInfo* module = nullptr;
  // Initializers (`new Type(...)`), or null when the type has none.
  const MemberGroup* initializers = nullptr;
};

struct ModuleInfo {
  std::string name;
  std::string fingerprint;
  uint32_t abiVersion = 0;
  NSSwiftRelease release = nullptr;
  std::vector<TypeInfo> types;
  std::vector<MemberInfo> members;
  std::vector<std::unique_ptr<MemberGroup>> groups;
  std::string error;

  bool IsA(uint32_t typeIndex, int expected) const {
    for (int current = static_cast<int>(typeIndex); current >= 0;
         current = types[current].superIndex) {
      if (current == expected) {
        return true;
      }
    }
    return false;
  }
};

struct Registrar : NSSwiftRegistrar {
  ModuleInfo* module;
};

std::string TypeDisplayName(const ModuleInfo& module, const ValueCode& code) {
  std::string name;
  switch (code.kind) {
    case ValueCode::Kind::Void:
      name = "Void";
      break;
    case ValueCode::Kind::Bool:
      name = "Bool";
      break;
    case ValueCode::Kind::Signed:
      name = code.bits == 64 ? "Int" : "Int" + std::to_string(code.bits);
      break;
    case ValueCode::Kind::Unsigned:
      name = code.bits == 64 ? "UInt" : "UInt" + std::to_string(code.bits);
      break;
    case ValueCode::Kind::Float:
      name = code.bits == 32 ? "Float" : "Double";
      break;
    case ValueCode::Kind::String:
      name = "String";
      break;
    case ValueCode::Kind::Date:
      name = "Date";
      break;
    case ValueCode::Kind::URL:
      name = "URL";
      break;
    case ValueCode::Kind::Data:
      name = "Data";
      break;
    case ValueCode::Kind::Array:
      name = "[" + TypeDisplayName(module, code.element.at(0)) + "]";
      break;
    case ValueCode::Kind::Map:
      name = "[String: " + TypeDisplayName(module, code.element.at(0)) + "]";
      break;
    case ValueCode::Kind::Object:
    case ValueCode::Kind::Enum:
      name = code.typeIndex >= 0 && code.typeIndex < static_cast<int>(module.types.size())
                 ? module.types[code.typeIndex].jsName
                 : "?";
      break;
  }
  return code.optional ? name + "?" : name;
}

// "scale(by: Double)": distinguishes overloads that share a Swift name.
std::string TypedKey(const ModuleInfo& module, const MemberInfo& member) {
  std::string base = member.swiftName.substr(0, member.swiftName.find('('));
  std::string key = base + "(";
  for (size_t i = 0; i < member.signature.parameters.size(); i++) {
    if (i > 0) {
      key += ", ";
    }
    std::string label = i < member.labels.size() ? member.labels[i] : "";
    key += (label.empty() ? "_" : label) + ": " +
           TypeDisplayName(module, member.signature.parameters[i]);
  }
  return key + ")";
}

void ApiRegisterModule(NSSwiftRegistrar* registrar, uint32_t abiVersion, const char* name,
                       const char* fingerprint, NSSwiftRelease release) {
  ModuleInfo* module = static_cast<Registrar*>(registrar)->module;
  module->abiVersion = abiVersion;
  if (name != nullptr && module->name != name) {
    module->error = "registers as '" + std::string(name) + "'";
  }
  module->fingerprint = fingerprint ? fingerprint : "";
  module->release = release;
}

void ApiRegisterType(NSSwiftRegistrar* registrar, uint32_t index, uint32_t kind, const char* jsName,
                     const char* swiftName, int32_t superIndex) {
  ModuleInfo* module = static_cast<Registrar*>(registrar)->module;
  if (index != module->types.size()) {
    module->error = "type indices are not dense";
    return;
  }
  TypeInfo type;
  type.index = index;
  type.kind = kind;
  type.jsName = jsName ? jsName : "";
  type.swiftName = swiftName ? swiftName : "";
  type.superIndex = superIndex;
  module->types.push_back(std::move(type));
}

void ApiRegisterMember(NSSwiftRegistrar* registrar, int32_t owner, uint32_t kind, uint32_t flags,
                       const char* jsName, const char* swiftName, const char* signature,
                       NSSwiftThunk thunk, NSSwiftThunk setter) {
  ModuleInfo* module = static_cast<Registrar*>(registrar)->module;
  MemberInfo member;
  member.owner = owner;
  member.kind = kind;
  member.flags = flags;
  member.jsName = jsName ? jsName : "";
  member.swiftName = swiftName ? swiftName : "";
  member.signatureText = signature ? signature : "";
  member.labels = LabelsOf(member.swiftName);
  member.thunk = thunk;
  member.setter = setter;
  if (!ParseSignature(member.signatureText, member.signature)) {
    module->error = "invalid signature '" + member.signatureText + "' for " + member.swiftName;
    return;
  }
  module->members.push_back(std::move(member));
}

struct CallContext;
void ApiReturnVoid(NSSwiftCall* call);
void ApiReturnBool(NSSwiftCall* call, uint8_t value);
void ApiReturnInt64(NSSwiftCall* call, int64_t value);
void ApiReturnUInt64(NSSwiftCall* call, uint64_t value);
void ApiReturnDouble(NSSwiftCall* call, double value);
void ApiReturnString(NSSwiftCall* call, const uint8_t* utf8, intptr_t length);
void ApiReturnNull(NSSwiftCall* call);
void ApiReturnObject(NSSwiftCall* call, void* object, uint32_t typeIndex);
void ApiThrowError(NSSwiftCall* call, const uint8_t* message, intptr_t messageLength,
                   const uint8_t* type, intptr_t typeLength);
void ApiThrowTypeError(NSSwiftCall* call, const uint8_t* message, intptr_t length);
void* ApiBeginAsync(NSSwiftCall* call);
void ApiCompleteVoid(void* token);
void ApiCompleteBool(void* token, uint8_t value);
void ApiCompleteInt64(void* token, int64_t value);
void ApiCompleteUInt64(void* token, uint64_t value);
void ApiCompleteDouble(void* token, double value);
void ApiCompleteString(void* token, const uint8_t* utf8, intptr_t length);
void ApiCompleteNull(void* token);
void ApiCompleteObject(void* token, void* object, uint32_t typeIndex);
void ApiCompleteError(void* token, const uint8_t* message, intptr_t messageLength,
                      const uint8_t* type, intptr_t typeLength);
void ApiReturnArrayBegin(NSSwiftCall* call, intptr_t count);
void ApiReturnArrayEnd(NSSwiftCall* call);
void ApiReturnMapBegin(NSSwiftCall* call, intptr_t count);
void ApiReturnMapEnd(NSSwiftCall* call);
void ApiCompleteArrayBegin(void* token, intptr_t count);
void ApiCompleteMapBegin(void* token, intptr_t count);
void ApiCompleteContainerEnd(void* token);

const NSSwiftAPI kAPI = {
    ApiReturnVoid,           ApiReturnBool,       ApiReturnInt64,          ApiReturnUInt64,
    ApiReturnDouble,         ApiReturnString,     ApiReturnNull,           ApiReturnObject,
    ApiThrowError,           ApiThrowTypeError,   ApiRegisterModule,       ApiRegisterType,
    ApiRegisterMember,       ApiBeginAsync,       ApiCompleteVoid,         ApiCompleteBool,
    ApiCompleteInt64,        ApiCompleteUInt64,   ApiCompleteDouble,       ApiCompleteString,
    ApiCompleteNull,         ApiCompleteObject,   ApiCompleteError,        ApiReturnArrayBegin,
    ApiReturnArrayEnd,       ApiReturnMapBegin,   ApiReturnMapEnd,         ApiCompleteArrayBegin,
    ApiCompleteContainerEnd, ApiCompleteMapBegin, ApiCompleteContainerEnd,
};

bool IsValidModuleName(const std::string& name) {
  if (name.empty()) {
    return false;
  }
  for (char c : name) {
    bool valid =
        (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_';
    if (!valid) {
      return false;
    }
  }
  return true;
}

void BuildGroups(ModuleInfo& module) {
  robin_hood::unordered_map<std::string, MemberGroup*> byKey;
  for (const MemberInfo& member : module.members) {
    std::string key =
        std::to_string(member.owner) + ":" + std::to_string(member.kind) + ":" + member.jsName;
    auto it = byKey.find(key);
    MemberGroup* group;
    if (it == byKey.end()) {
      module.groups.push_back(std::make_unique<MemberGroup>());
      group = module.groups.back().get();
      group->module = &module;
      group->owner = member.owner;
      group->kind = member.kind;
      group->jsName = member.jsName;
      byKey.emplace(key, group);
    } else {
      group = it->second;
    }
    group->overloads.push_back(&member);
    if (member.kind == NSSwiftMemberInitializer && member.owner >= 0) {
      module.types[member.owner].initializers = group;
    }
  }

  // A subclass's method shadows the superclass property of the same name in
  // JS, so it must also carry the inherited overloads it does not override
  // (an override keeps the Swift name and signature).
  for (const auto& group : module.groups) {
    if (group->kind != NSSwiftMemberInstanceMethod || group->owner < 0) {
      continue;
    }
    for (int ancestor = module.types[group->owner].superIndex; ancestor >= 0;
         ancestor = module.types[ancestor].superIndex) {
      auto inherited = byKey.find(std::to_string(ancestor) + ":" + std::to_string(group->kind) +
                                  ":" + group->jsName);
      if (inherited == byKey.end()) {
        continue;
      }
      for (const MemberInfo* candidate : inherited->second->overloads) {
        bool overridden = false;
        for (const MemberInfo* own : group->overloads) {
          overridden |= own->swiftName == candidate->swiftName &&
                        own->signatureText == candidate->signatureText;
        }
        if (!overridden) {
          group->overloads.push_back(candidate);
        }
      }
    }
  }
}

std::string Validate(const ModuleInfo& module) {
  if (!module.error.empty()) {
    return module.error;
  }
  if (module.abiVersion != NS_SWIFT_ABI_VERSION) {
    return "was generated for Swift interop ABI " + std::to_string(module.abiVersion) +
           ", the runtime implements ABI " + std::to_string(NS_SWIFT_ABI_VERSION) +
           "; regenerate its thunks";
  }
  if (module.release == nullptr) {
    return "registered no release function";
  }
  auto validType = [&](int index) {
    return index >= 0 && index < static_cast<int>(module.types.size());
  };
  for (const TypeInfo& type : module.types) {
    if (type.superIndex != -1 && !validType(type.superIndex)) {
      return "type " + type.swiftName + " has an invalid superclass index";
    }
  }
  for (const MemberInfo& member : module.members) {
    if (member.owner != -1 && !validType(member.owner)) {
      return member.swiftName + " has an invalid owner";
    }
    std::vector<const ValueCode*> codes;
    for (const auto& parameter : member.signature.parameters) {
      codes.push_back(&parameter);
    }
    codes.push_back(&member.signature.result);
    while (!codes.empty()) {
      const ValueCode* code = codes.back();
      codes.pop_back();
      if ((code->kind == ValueCode::Kind::Object || code->kind == ValueCode::Kind::Enum) &&
          !validType(code->typeIndex)) {
        return member.swiftName + " references an unknown type";
      }
      for (const auto& element : code->element) {
        codes.push_back(&element);
      }
    }
    if (member.kind != NSSwiftMemberEnumCase && member.thunk == nullptr) {
      return member.swiftName + " has no thunk";
    }
  }
  return "";
}

std::mutex gModulesMutex;
robin_hood::unordered_map<std::string, std::shared_ptr<const ModuleInfo>> gModules;

std::shared_ptr<const ModuleInfo> LoadModuleInfo(const std::string& name, std::string& error) {
  std::lock_guard<std::mutex> lock(gModulesMutex);
  auto existing = gModules.find(name);
  if (existing != gModules.end()) {
    if (!existing->second->error.empty()) {
      error = existing->second->error;
      return nullptr;
    }
    return existing->second;
  }

  auto module = std::make_shared<ModuleInfo>();
  module->name = name;
  std::string symbol = "ns_swift_register_" + name;
  auto registerFunction =
      reinterpret_cast<NSSwiftRegisterFunction>(dlsym(RTLD_DEFAULT, symbol.c_str()));
  if (registerFunction == nullptr) {
    module->error =
        "Swift module '" + name + "' is not linked into this app (" + symbol + " not found)";
  } else {
    Registrar registrar;
    registrar.api = &kAPI;
    registrar.module = module.get();
    registerFunction(&registrar);
    std::string problem = Validate(*module);
    if (!problem.empty()) {
      module->error = "Swift module '" + name + "' " + problem;
    } else {
      BuildGroups(*module);
    }
  }
  gModules.emplace(name, module);
  if (!module->error.empty()) {
    error = module->error;
    return nullptr;
  }
  return module;
}

// --- Per-isolate state ---------------------------------------------------------

class SwiftObjectWrapper;

struct LoadedModule {
  std::shared_ptr<const ModuleInfo> info;
  Global<Object> exports;
  // Constructor templates by type index; empty for enums.
  std::vector<Global<FunctionTemplate>> templates;
};

// An async call's Promise, settled on the isolate's thread.
struct PendingAsync {
  Global<Promise::Resolver> resolver;
  const MemberInfo* member;
};

struct IsolateState {
  robin_hood::unordered_map<std::string, std::unique_ptr<LoadedModule>> modules;
  // Resolvers stay here, on the isolate's thread: a v8::Global must not be
  // destroyed by the thread that completes the call.
  robin_hood::unordered_map<uint64_t, std::unique_ptr<PendingAsync>> pending;
  uint64_t nextAsyncId = 1;
  robin_hood::unordered_map<const ModuleInfo*, LoadedModule*> byInfo;
  // Swift object -> its JS wrapper, so a Swift object has one JS identity.
  robin_hood::unordered_map<void*, SwiftObjectWrapper*> identity;
};

// Owns one retain of a Swift object for as long as its JS wrapper lives.
class SwiftObjectWrapper : public BaseDataWrapper, public IsolateTracked {
 public:
  SwiftObjectWrapper(Isolate* isolate, const ModuleInfo* module, void* object, uint32_t typeIndex)
      : isolate_(isolate), module_(module), object_(object), typeIndex_(typeIndex) {}

  ~SwiftObjectWrapper() override {
    if (auto* state = Caches::StateFor<IsolateState>(isolate_)) {
      auto it = state->identity.find(object_);
      if (it != state->identity.end() && it->second == this) {
        state->identity.erase(it);
      }
    }
    module_->release(object_);
  }

  const WrapperType Type() override { return WrapperType::SwiftObject; }

  Local<Object> JSObject() const { return TrackedObject(isolate_); }
  const ModuleInfo* Module() const { return module_; }
  void* Object() const { return object_; }
  uint32_t TypeIndex() const { return typeIndex_; }

 private:
  Isolate* isolate_;
  const ModuleInfo* module_;
  void* object_;
  uint32_t typeIndex_;
};

SwiftObjectWrapper* SwiftWrapperOf(Isolate* isolate, Local<Value> value) {
  if (value.IsEmpty() || !value->IsObject()) {
    return nullptr;
  }
  BaseDataWrapper* wrapper = tns::GetValue(isolate, value);
  if (wrapper == nullptr || wrapper->Type() != WrapperType::SwiftObject) {
    return nullptr;
  }
  return static_cast<SwiftObjectWrapper*>(wrapper);
}

// --- Calls -----------------------------------------------------------------------

// An array or map a thunk is reporting element by element.
struct ResultFrame {
  bool isMap = false;
  Local<Object> target;
  uint32_t next = 0;
  // Maps alternate key and value reports.
  bool expectKey = true;
  Local<Value> key;
  const ValueCode* element = nullptr;
};

struct CallContext : NSSwiftCall {
  Isolate* isolate = nullptr;
  Local<Context> context;
  const ModuleInfo* module = nullptr;
  LoadedModule* loaded = nullptr;
  IsolateState* state = nullptr;
  const MemberInfo* member = nullptr;
  // The object `new` created, adopted by the initializer's result.
  Local<Object> constructTarget;
  // Code of the call's result; open frames take precedence.
  const ValueCode* resultCode = nullptr;
  std::vector<ResultFrame> frames;
  Local<Value> result;
  bool completed = false;
  bool threw = false;
};

CallContext* ContextOf(NSSwiftCall* call) { return static_cast<CallContext*>(call); }

// The code of the value the thunk reports next.
const ValueCode* CurrentCode(CallContext* context) {
  if (context->frames.empty()) {
    return context->resultCode;
  }
  const ResultFrame& frame = context->frames.back();
  return frame.isMap && frame.expectKey ? &KeyCode() : frame.element;
}

void Fail(CallContext* context) {
  context->completed = true;
  context->threw = true;
}

void Complete(CallContext* context, Local<Value> value) {
  if (context->frames.empty()) {
    context->completed = true;
    context->result = value;
    return;
  }
  ResultFrame& frame = context->frames.back();
  bool stored = true;
  if (!frame.isMap) {
    stored = frame.target->Set(context->context, frame.next++, value).FromMaybe(false);
  } else if (frame.expectKey) {
    frame.key = value;
    frame.expectKey = false;
  } else {
    stored = frame.target->Set(context->context, frame.key, value).FromMaybe(false);
    frame.expectKey = true;
  }
  if (!stored) {
    Fail(context);
  }
}

std::string RangeMessage(const std::string& value, const std::string& swiftName) {
  return value + " returned by " + swiftName +
         " is outside the range JavaScript numbers represent exactly";
}

void ThrowRange(CallContext* context, const std::string& what) {
  Fail(context);
  context->isolate->ThrowException(Exception::RangeError(
      tns::ToV8String(context->isolate, RangeMessage(what, context->member->swiftName))));
}

// A Uint8Array holding a copy of `bytes`.
MaybeLocal<Value> MakeBytes(Isolate* isolate, const uint8_t* bytes, size_t length) {
  Local<v8::ArrayBuffer> buffer = v8::ArrayBuffer::New(isolate, length);
  if (length > 0) {
    memcpy(buffer->Data(), bytes, length);
  }
  return v8::Uint8Array::New(buffer, 0, length);
}

// `new URL(href)` with the realm's URL.
MaybeLocal<Value> MakeURL(Isolate* isolate, Local<Context> context, Local<v8::String> href) {
  Local<Value> constructor;
  if (!context->Global()->Get(context, tns::ToV8String(isolate, "URL")).ToLocal(&constructor) ||
      !constructor->IsFunction()) {
    return href;
  }
  Local<Value> argv[] = {href};
  Local<Object> url;
  if (!constructor.As<v8::Function>()->NewInstance(context, 1, argv).ToLocal(&url)) {
    return MaybeLocal<Value>();
  }
  return url;
}

void ApiReturnVoid(NSSwiftCall* call) {
  CallContext* context = ContextOf(call);
  Complete(context, v8::Undefined(context->isolate));
}

void ApiReturnBool(NSSwiftCall* call, uint8_t value) {
  CallContext* context = ContextOf(call);
  Complete(context, v8::Boolean::New(context->isolate, value != 0));
}

void ApiReturnInt64(NSSwiftCall* call, int64_t value) {
  CallContext* context = ContextOf(call);
  if (std::fabs(static_cast<double>(value)) > kMaxSafeInteger) {
    return ThrowRange(context, std::to_string(value));
  }
  Complete(context, v8::Number::New(context->isolate, static_cast<double>(value)));
}

void ApiReturnUInt64(NSSwiftCall* call, uint64_t value) {
  CallContext* context = ContextOf(call);
  if (static_cast<double>(value) > kMaxSafeInteger) {
    return ThrowRange(context, std::to_string(value));
  }
  Complete(context, v8::Number::New(context->isolate, static_cast<double>(value)));
}

void ApiReturnDouble(NSSwiftCall* call, double value) {
  CallContext* context = ContextOf(call);
  const ValueCode* code = CurrentCode(context);
  if (code && code->kind == ValueCode::Kind::Date) {
    Local<Value> date;
    if (!v8::Date::New(context->context, value).ToLocal(&date)) {
      return Fail(context);
    }
    return Complete(context, date);
  }
  Complete(context, v8::Number::New(context->isolate, value));
}

void ApiReturnString(NSSwiftCall* call, const uint8_t* utf8, intptr_t length) {
  CallContext* context = ContextOf(call);
  const ValueCode* code = CurrentCode(context);
  if (code && code->kind == ValueCode::Kind::Data) {
    Local<Value> bytes;
    if (!MakeBytes(context->isolate, utf8, static_cast<size_t>(length)).ToLocal(&bytes)) {
      return Fail(context);
    }
    return Complete(context, bytes);
  }
  Local<v8::String> string;
  if (!v8::String::NewFromUtf8(context->isolate,
                               reinterpret_cast<const char*>(utf8 ? utf8 : (const uint8_t*)""),
                               v8::NewStringType::kNormal, static_cast<int>(length))
           .ToLocal(&string)) {
    return Fail(context);
  }
  if (code && code->kind == ValueCode::Kind::URL) {
    Local<Value> url;
    if (!MakeURL(context->isolate, context->context, string).ToLocal(&url)) {
      return Fail(context);
    }
    return Complete(context, url);
  }
  Complete(context, string);
}

void ApiReturnNull(NSSwiftCall* call) {
  CallContext* context = ContextOf(call);
  Complete(context, v8::Null(context->isolate));
}

void BeginContainer(CallContext* context, bool isMap, intptr_t count) {
  const ValueCode* code = CurrentCode(context);
  ValueCode::Kind expected = isMap ? ValueCode::Kind::Map : ValueCode::Kind::Array;
  if (code == nullptr || code->kind != expected || code->element.empty()) {
    Fail(context);
    context->isolate->ThrowException(Exception::Error(tns::ToV8String(
        context->isolate, context->member->swiftName + " reported an unexpected collection")));
    return;
  }
  ResultFrame frame;
  frame.isMap = isMap;
  frame.target = isMap ? Local<Object>(Object::New(context->isolate))
                       : Local<Object>(v8::Array::New(context->isolate, static_cast<int>(count)));
  frame.element = &code->element[0];
  context->frames.push_back(frame);
}

void EndContainer(CallContext* context) {
  if (context->frames.empty()) {
    return Fail(context);
  }
  Local<Object> target = context->frames.back().target;
  context->frames.pop_back();
  Complete(context, target);
}

void ApiReturnArrayBegin(NSSwiftCall* call, intptr_t count) {
  BeginContainer(ContextOf(call), false, count);
}

void ApiReturnArrayEnd(NSSwiftCall* call) { EndContainer(ContextOf(call)); }

void ApiReturnMapBegin(NSSwiftCall* call, intptr_t count) {
  BeginContainer(ContextOf(call), true, count);
}

void ApiReturnMapEnd(NSSwiftCall* call) { EndContainer(ContextOf(call)); }

// The JS wrapper for `object`, taking over the +1 retain the thunk passed.
// Adopts `*constructTarget` (the object `new` created) when it is set.
Local<Object> WrapSwiftObject(Isolate* isolate, Local<Context> context, const ModuleInfo* module,
                              LoadedModule* loaded, IsolateState* state, void* object,
                              uint32_t typeIndex, Local<Object>* constructTarget) {
  auto existing = state->identity.find(object);
  if (existing != state->identity.end()) {
    Local<Object> wrapper = existing->second->JSObject();
    if (!wrapper.IsEmpty()) {
      // The thunk handed over a retain the existing wrapper already holds.
      module->release(object);
      return wrapper;
    }
  }

  Local<Object> instance;
  if (constructTarget && !constructTarget->IsEmpty()) {
    instance = *constructTarget;
    constructTarget->Clear();
  } else {
    if (loaded == nullptr || typeIndex >= loaded->templates.size() ||
        loaded->templates[typeIndex].IsEmpty()) {
      module->release(object);
      return Local<Object>();
    }
    Local<FunctionTemplate> tmpl = loaded->templates[typeIndex].Get(isolate);
    if (!tmpl->InstanceTemplate()->NewInstance(context).ToLocal(&instance)) {
      module->release(object);
      return Local<Object>();
    }
  }

  auto* wrapper = new SwiftObjectWrapper(isolate, module, object, typeIndex);
  tns::SetValue(isolate, instance, wrapper);
  wrapper->BindFinalizer(isolate, instance);
  state->identity[object] = wrapper;
  return instance;
}

Local<Object> WrapObject(CallContext* context, void* object, uint32_t typeIndex) {
  return WrapSwiftObject(context->isolate, context->context, context->module, context->loaded,
                         context->state, object, typeIndex, &context->constructTarget);
}

// A Swift error as a JS Error: name "SwiftError" and the error's type in
// `swiftType` (a plain Error when there is no type).
Local<Value> SwiftErrorValue(Isolate* isolate, Local<Context> context, const std::string& message,
                             const std::string& typeName) {
  Local<Value> error = Exception::Error(tns::ToV8String(isolate, message));
  if (!typeName.empty() && error->IsObject()) {
    Local<Object> object = error.As<Object>();
    object->Set(context, tns::ToV8String(isolate, "name"), tns::ToV8String(isolate, "SwiftError"))
        .Check();
    object->Set(context, tns::ToV8String(isolate, "swiftType"), tns::ToV8String(isolate, typeName))
        .Check();
  }
  return error;
}

void ApiReturnObject(NSSwiftCall* call, void* object, uint32_t typeIndex) {
  CallContext* context = ContextOf(call);
  if (object == nullptr || typeIndex >= context->module->types.size()) {
    context->completed = true;
    context->threw = true;
    context->isolate->ThrowException(
        Exception::Error(tns::ToV8String(context->isolate, "Swift returned an invalid object")));
    return;
  }
  Local<Object> wrapper = WrapObject(context, object, typeIndex);
  if (wrapper.IsEmpty()) {
    context->completed = true;
    context->threw = true;
    return;
  }
  Complete(context, wrapper);
}

void ApiThrowError(NSSwiftCall* call, const uint8_t* message, intptr_t messageLength,
                   const uint8_t* type, intptr_t typeLength) {
  CallContext* context = ContextOf(call);
  context->completed = true;
  context->threw = true;
  std::string text(reinterpret_cast<const char*>(message), message ? messageLength : 0);
  std::string typeName(reinterpret_cast<const char*>(type), type ? typeLength : 0);
  context->isolate->ThrowException(
      SwiftErrorValue(context->isolate, context->context, text, typeName));
}

void ApiThrowTypeError(NSSwiftCall* call, const uint8_t* message, intptr_t length) {
  CallContext* context = ContextOf(call);
  context->completed = true;
  context->threw = true;
  std::string text(reinterpret_cast<const char*>(message), message ? length : 0);
  context->isolate->ThrowException(Exception::TypeError(
      tns::ToV8String(context->isolate, context->member->swiftName + ": " + text)));
}

// --- Async calls -------------------------------------------------------------------
//
// beginAsync runs on the isolate's thread inside the call; complete* runs on
// whatever thread the Swift task finishes on. Neither the token nor the
// outcome holds V8 handles, so either may be destroyed on any thread.

// What a Swift task produced, in a form that can cross threads. Arrays and
// maps hold their elements (a map's alternate key and value) as children.
struct AsyncOutcome {
  enum class Kind { Void, Bool, Int64, UInt64, Double, String, Null, Object, Error, Array, Map };
  Kind kind = Kind::Void;
  bool boolean = false;
  int64_t int64 = 0;
  uint64_t uint64 = 0;
  double float64 = 0;
  std::string text;
  std::string errorType;
  void* object = nullptr;
  uint32_t typeIndex = 0;
  const ModuleInfo* module = nullptr;
  std::vector<std::shared_ptr<AsyncOutcome>> children;

  // An undelivered object (the isolate went away) still owns its retain.
  ~AsyncOutcome() {
    if (object != nullptr) {
      module->release(object);
    }
  }
};

struct AsyncToken {
  Isolate* isolate;
  IsolateWrapper wrapper;
  uint64_t id;
  const ModuleInfo* module;
  std::shared_ptr<AsyncOutcome> root;
  // Arrays and maps still being reported.
  std::vector<AsyncOutcome*> open;
};

// Converts `node` (of `code`) to JS; on failure sets `rejection` and returns
// false.
bool OutcomeToJS(Isolate* isolate, Local<Context> context, IsolateState* state,
                 const MemberInfo& member, AsyncOutcome& node, const ValueCode& code,
                 Local<Value>& out, Local<Value>& rejection) {
  auto range = [&](const std::string& value) {
    rejection =
        Exception::RangeError(tns::ToV8String(isolate, RangeMessage(value, member.swiftName)));
    return false;
  };
  auto failed = [&](const char* what) {
    rejection = Exception::Error(tns::ToV8String(isolate, member.swiftName + ": " + what));
    return false;
  };
  switch (node.kind) {
    case AsyncOutcome::Kind::Void:
      out = v8::Undefined(isolate);
      return true;
    case AsyncOutcome::Kind::Bool:
      out = v8::Boolean::New(isolate, node.boolean);
      return true;
    case AsyncOutcome::Kind::Int64:
      if (std::fabs(static_cast<double>(node.int64)) > kMaxSafeInteger) {
        return range(std::to_string(node.int64));
      }
      out = v8::Number::New(isolate, static_cast<double>(node.int64));
      return true;
    case AsyncOutcome::Kind::UInt64:
      if (static_cast<double>(node.uint64) > kMaxSafeInteger) {
        return range(std::to_string(node.uint64));
      }
      out = v8::Number::New(isolate, static_cast<double>(node.uint64));
      return true;
    case AsyncOutcome::Kind::Double:
      if (code.kind == ValueCode::Kind::Date) {
        return v8::Date::New(context, node.float64).ToLocal(&out) || failed("invalid date");
      }
      out = v8::Number::New(isolate, node.float64);
      return true;
    case AsyncOutcome::Kind::String: {
      if (code.kind == ValueCode::Kind::Data) {
        return MakeBytes(isolate, reinterpret_cast<const uint8_t*>(node.text.data()),
                         node.text.size())
                   .ToLocal(&out) ||
               failed("could not copy data");
      }
      Local<v8::String> string = tns::ToV8String(isolate, node.text);
      if (code.kind == ValueCode::Kind::URL) {
        return MakeURL(isolate, context, string).ToLocal(&out) || failed("invalid URL");
      }
      out = string;
      return true;
    }
    case AsyncOutcome::Kind::Null:
      out = v8::Null(isolate);
      return true;
    case AsyncOutcome::Kind::Object: {
      auto loaded = state->byInfo.find(node.module);
      void* object = node.object;
      // WrapSwiftObject takes over the retain.
      node.object = nullptr;
      Local<Object> wrapper = WrapSwiftObject(
          isolate, context, node.module, loaded == state->byInfo.end() ? nullptr : loaded->second,
          state, object, node.typeIndex, nullptr);
      if (wrapper.IsEmpty()) {
        return failed("returned an object JavaScript cannot wrap");
      }
      out = wrapper;
      return true;
    }
    case AsyncOutcome::Kind::Array: {
      if (code.element.empty()) {
        return failed("returned an unexpected array");
      }
      Local<v8::Array> array = v8::Array::New(isolate, static_cast<int>(node.children.size()));
      for (uint32_t i = 0; i < node.children.size(); i++) {
        Local<Value> element;
        if (!OutcomeToJS(isolate, context, state, member, *node.children[i], code.element[0],
                         element, rejection) ||
            !array->Set(context, i, element).FromMaybe(false)) {
          return false;
        }
      }
      out = array;
      return true;
    }
    case AsyncOutcome::Kind::Map: {
      if (code.element.empty()) {
        return failed("returned an unexpected map");
      }
      Local<Object> object = Object::New(isolate);
      for (size_t i = 0; i + 1 < node.children.size(); i += 2) {
        Local<Value> key;
        Local<Value> value;
        if (!OutcomeToJS(isolate, context, state, member, *node.children[i], KeyCode(), key,
                         rejection) ||
            !OutcomeToJS(isolate, context, state, member, *node.children[i + 1], code.element[0],
                         value, rejection) ||
            !object->Set(context, key, value).FromMaybe(false)) {
          return false;
        }
      }
      out = object;
      return true;
    }
    case AsyncOutcome::Kind::Error:
      rejection = SwiftErrorValue(isolate, context, node.text, node.errorType);
      return false;
  }
  return failed("returned an unknown value");
}

void SettleOnIsolate(Isolate* isolate, uint64_t id, AsyncOutcome& outcome) {
  auto* state = Caches::StateFor<IsolateState>(isolate);
  if (state == nullptr) {
    return;
  }
  auto it = state->pending.find(id);
  if (it == state->pending.end()) {
    return;
  }
  std::unique_ptr<PendingAsync> pending = std::move(it->second);
  state->pending.erase(it);

  Local<Context> context = isolate->GetCurrentContext();
  Local<Promise::Resolver> resolver = pending->resolver.Get(isolate);
  Local<Value> value;
  Local<Value> rejection;
  if (OutcomeToJS(isolate, context, state, *pending->member, outcome,
                  pending->member->signature.result, value, rejection)) {
    resolver->Resolve(context, value).Check();
  } else {
    resolver->Reject(context, rejection).Check();
  }
}

// Consumes `token`. Safe on any thread.
void Deliver(AsyncToken* rawToken) {
  std::unique_ptr<AsyncToken> token(rawToken);
  std::shared_ptr<AsyncOutcome> outcome = token->root;
  NativeScriptPlatform* platform = NativeScriptPlatform::Instance();
  std::shared_ptr<EventLoop> loop =
      platform ? platform->LookupEventLoop(token->isolate) : std::shared_ptr<EventLoop>();
  if (!loop || !outcome) {
    return;
  }
  Isolate* isolate = token->isolate;
  IsolateWrapper wrapper = token->wrapper;
  uint64_t id = token->id;
  // The event loop enters the isolate and drains microtasks around this; a
  // dropped post releases the outcome (and its objects) here.
  loop->PostInternal([isolate, wrapper, id, outcome]() {
    if (!wrapper.IsValid()) {
      return;
    }
    SettleOnIsolate(isolate, id, *outcome);
  });
}

// Records one reported value; delivers once the top-level value is complete.
void Emit(void* rawToken, std::shared_ptr<AsyncOutcome> node) {
  auto* token = static_cast<AsyncToken*>(rawToken);
  node->module = token->module;
  bool opens = node->kind == AsyncOutcome::Kind::Array || node->kind == AsyncOutcome::Kind::Map;
  AsyncOutcome* raw = node.get();
  if (token->open.empty()) {
    token->root = std::move(node);
  } else {
    token->open.back()->children.push_back(std::move(node));
  }
  if (opens) {
    token->open.push_back(raw);
  } else if (token->open.empty()) {
    Deliver(token);
  }
}

std::shared_ptr<AsyncOutcome> Outcome(AsyncOutcome::Kind kind) {
  auto outcome = std::make_shared<AsyncOutcome>();
  outcome->kind = kind;
  return outcome;
}

void* ApiBeginAsync(NSSwiftCall* call) {
  CallContext* context = ContextOf(call);
  Isolate* isolate = context->isolate;
  uint64_t id = context->state->nextAsyncId++;
  Local<Promise::Resolver> resolver;
  if (Promise::Resolver::New(context->context).ToLocal(&resolver)) {
    auto pending = std::make_unique<PendingAsync>();
    pending->resolver.Reset(isolate, resolver);
    pending->member = context->member;
    context->state->pending.emplace(id, std::move(pending));
    Complete(context, resolver->GetPromise());
  } else {
    // The token is still completed later; it then finds no pending entry.
    Fail(context);
  }
  return new AsyncToken{isolate, IsolateWrapper(isolate), id, context->module, nullptr, {}};
}

void ApiCompleteVoid(void* token) { Emit(token, Outcome(AsyncOutcome::Kind::Void)); }

void ApiCompleteBool(void* token, uint8_t value) {
  auto outcome = Outcome(AsyncOutcome::Kind::Bool);
  outcome->boolean = value != 0;
  Emit(token, outcome);
}

void ApiCompleteInt64(void* token, int64_t value) {
  auto outcome = Outcome(AsyncOutcome::Kind::Int64);
  outcome->int64 = value;
  Emit(token, outcome);
}

void ApiCompleteUInt64(void* token, uint64_t value) {
  auto outcome = Outcome(AsyncOutcome::Kind::UInt64);
  outcome->uint64 = value;
  Emit(token, outcome);
}

void ApiCompleteDouble(void* token, double value) {
  auto outcome = Outcome(AsyncOutcome::Kind::Double);
  outcome->float64 = value;
  Emit(token, outcome);
}

void ApiCompleteString(void* token, const uint8_t* utf8, intptr_t length) {
  auto outcome = Outcome(AsyncOutcome::Kind::String);
  outcome->text.assign(reinterpret_cast<const char*>(utf8), utf8 ? length : 0);
  Emit(token, outcome);
}

void ApiCompleteNull(void* token) { Emit(token, Outcome(AsyncOutcome::Kind::Null)); }

void ApiCompleteObject(void* token, void* object, uint32_t typeIndex) {
  auto outcome = Outcome(AsyncOutcome::Kind::Object);
  outcome->object = object;
  outcome->typeIndex = typeIndex;
  Emit(token, outcome);
}

void ApiCompleteError(void* token, const uint8_t* message, intptr_t messageLength,
                      const uint8_t* type, intptr_t typeLength) {
  auto outcome = Outcome(AsyncOutcome::Kind::Error);
  outcome->text.assign(reinterpret_cast<const char*>(message), message ? messageLength : 0);
  outcome->errorType.assign(reinterpret_cast<const char*>(type), type ? typeLength : 0);
  Emit(token, outcome);
}

void ApiCompleteArrayBegin(void* token, intptr_t /*count*/) {
  Emit(token, Outcome(AsyncOutcome::Kind::Array));
}

void ApiCompleteMapBegin(void* token, intptr_t /*count*/) {
  Emit(token, Outcome(AsyncOutcome::Kind::Map));
}

void ApiCompleteContainerEnd(void* rawToken) {
  auto* token = static_cast<AsyncToken*>(rawToken);
  if (!token->open.empty()) {
    token->open.pop_back();
  }
  if (token->open.empty()) {
    Deliver(token);
  }
}

// --- Argument conversion -----------------------------------------------------------

bool IsPlainObject(Isolate* isolate, Local<Value> value) {
  return value->IsObject() && !value->IsArray() && !value->IsFunction() &&
         SwiftWrapperOf(isolate, value) == nullptr;
}

// Whether `value` can be passed as `code` (overload resolution; no throws, no
// user code). Collections are checked by kind only; Convert checks elements.
bool Accepts(Isolate* isolate, const ModuleInfo& module, const ValueCode& code,
             Local<Value> value) {
  if (value->IsNullOrUndefined()) {
    return code.optional;
  }
  switch (code.kind) {
    case ValueCode::Kind::Bool:
      return value->IsBoolean();
    case ValueCode::Kind::Signed:
    case ValueCode::Kind::Unsigned:
      if (value->IsBigInt()) {
        return true;
      }
      if (value->IsNumber()) {
        double number = value.As<v8::Number>()->Value();
        return std::isfinite(number) && std::trunc(number) == number;
      }
      return false;
    case ValueCode::Kind::Float:
      return value->IsNumber();
    case ValueCode::Kind::String:
    case ValueCode::Kind::Enum:
      return value->IsString();
    case ValueCode::Kind::URL:
      return value->IsString() ||
             (value->IsObject() && !value->IsArray() && SwiftWrapperOf(isolate, value) == nullptr);
    case ValueCode::Kind::Date:
      return value->IsDate();
    case ValueCode::Kind::Data:
      return value->IsArrayBuffer() || value->IsArrayBufferView();
    case ValueCode::Kind::Array:
      return value->IsArray();
    case ValueCode::Kind::Map:
      return IsPlainObject(isolate, value) && !value->IsDate() && !value->IsArrayBuffer() &&
             !value->IsArrayBufferView();
    case ValueCode::Kind::Object: {
      SwiftObjectWrapper* wrapper = SwiftWrapperOf(isolate, value);
      return wrapper && wrapper->Module() == &module &&
             module.IsA(wrapper->TypeIndex(), code.typeIndex);
    }
    case ValueCode::Kind::Void:
      return false;
  }
  return false;
}

bool ThrowArgument(Isolate* isolate, const MemberInfo& member, size_t index,
                   const std::string& problem, bool range = false) {
  std::string message =
      member.swiftName + ": argument " + std::to_string(index + 1) + " " + problem;
  Local<v8::String> text = tns::ToV8String(isolate, message);
  isolate->ThrowException(range ? Exception::RangeError(text) : Exception::TypeError(text));
  return false;
}

// Storage the slots of one call point into. Deques keep every buffer at a
// fixed address while more are added.
struct SlotArena {
  std::deque<std::string> strings;
  std::deque<std::vector<NSSwiftValue>> slots;
};

void PointAtBytes(NSSwiftValue& slot, const void* bytes, size_t length) {
  slot.tag = NSSwiftTagString;
  slot.payload.utf8 = static_cast<const uint8_t*>(bytes);
  slot.length = length;
}

bool WriteString(Isolate* isolate, Local<v8::String> string, NSSwiftValue& slot, SlotArena& arena) {
  size_t length = string->Utf8LengthV2(isolate);
  arena.strings.emplace_back(length, '\0');
  std::string& buffer = arena.strings.back();
  if (length > 0) {
    string->WriteUtf8V2(isolate, buffer.data(), length,
                        v8::String::WriteFlags::kReplaceInvalidUtf8);
  }
  PointAtBytes(slot, buffer.data(), length);
  return true;
}

// Writes `value` into `slot`; `index` names the argument in errors.
bool Convert(Isolate* isolate, Local<Context> context, const ModuleInfo& module,
             const MemberInfo& member, size_t index, const ValueCode& code, Local<Value> value,
             NSSwiftValue& slot, SlotArena& arena) {
  slot = NSSwiftValue{};
  if (value->IsNullOrUndefined()) {
    if (!code.optional) {
      return ThrowArgument(isolate, member, index,
                           "must be " + TypeDisplayName(module, code) + ", not " +
                               (value->IsNull() ? "null" : "undefined"));
    }
    slot.tag = NSSwiftTagNull;
    return true;
  }

  switch (code.kind) {
    case ValueCode::Kind::Bool:
      if (!value->IsBoolean()) {
        return ThrowArgument(isolate, member, index, "must be a boolean");
      }
      slot.tag = NSSwiftTagBool;
      slot.payload.boolean = value->BooleanValue(isolate) ? 1 : 0;
      return true;

    case ValueCode::Kind::Signed: {
      int64_t result = 0;
      if (value->IsBigInt()) {
        bool lossless = false;
        result = value.As<v8::BigInt>()->Int64Value(&lossless);
        if (!lossless) {
          return ThrowArgument(isolate, member, index, "is out of range", true);
        }
      } else if (value->IsNumber()) {
        double number = value.As<v8::Number>()->Value();
        if (!std::isfinite(number) || std::trunc(number) != number) {
          return ThrowArgument(isolate, member, index, "must be an integer");
        }
        if (std::fabs(number) > kMaxSafeInteger) {
          return ThrowArgument(isolate, member, index, "is not a safe integer; pass a BigInt",
                               true);
        }
        result = static_cast<int64_t>(number);
      } else {
        return ThrowArgument(isolate, member, index, "must be a number or BigInt");
      }
      if (code.bits < 64) {
        int64_t limit = int64_t(1) << (code.bits - 1);
        if (result < -limit || result >= limit) {
          return ThrowArgument(isolate, member, index,
                               "does not fit " + TypeDisplayName(module, code), true);
        }
      }
      slot.tag = NSSwiftTagInt64;
      slot.payload.int64 = result;
      return true;
    }

    case ValueCode::Kind::Unsigned: {
      uint64_t result = 0;
      if (value->IsBigInt()) {
        bool lossless = false;
        result = value.As<v8::BigInt>()->Uint64Value(&lossless);
        if (!lossless) {
          return ThrowArgument(isolate, member, index, "is out of range", true);
        }
      } else if (value->IsNumber()) {
        double number = value.As<v8::Number>()->Value();
        if (!std::isfinite(number) || std::trunc(number) != number) {
          return ThrowArgument(isolate, member, index, "must be an integer");
        }
        if (number < 0 || number > kMaxSafeInteger) {
          return ThrowArgument(
              isolate, member, index,
              number < 0 ? "must not be negative" : "is not a safe integer; pass a BigInt", true);
        }
        result = static_cast<uint64_t>(number);
      } else {
        return ThrowArgument(isolate, member, index, "must be a number or BigInt");
      }
      if (code.bits < 64 && result >= (uint64_t(1) << code.bits)) {
        return ThrowArgument(isolate, member, index,
                             "does not fit " + TypeDisplayName(module, code), true);
      }
      slot.tag = NSSwiftTagUInt64;
      slot.payload.uint64 = result;
      return true;
    }

    case ValueCode::Kind::Float:
      if (!value->IsNumber()) {
        return ThrowArgument(isolate, member, index, "must be a number");
      }
      slot.tag = NSSwiftTagDouble;
      slot.payload.float64 = value.As<v8::Number>()->Value();
      return true;

    case ValueCode::Kind::Date:
      if (!value->IsDate()) {
        return ThrowArgument(isolate, member, index, "must be a Date");
      }
      slot.tag = NSSwiftTagDouble;
      slot.payload.float64 = value.As<v8::Date>()->ValueOf();
      return true;

    case ValueCode::Kind::String:
    case ValueCode::Kind::Enum:
      if (!value->IsString()) {
        return ThrowArgument(isolate, member, index,
                             code.kind == ValueCode::Kind::Enum
                                 ? "must be a " + TypeDisplayName(module, code) + " case name"
                                 : "must be a string");
      }
      return WriteString(isolate, value.As<v8::String>(), slot, arena);

    case ValueCode::Kind::URL: {
      Local<Value> href = value;
      if (!value->IsString()) {
        // A URL object (or anything else with a string href).
        if (!value->IsObject() ||
            !value.As<Object>()->Get(context, tns::ToV8String(isolate, "href")).ToLocal(&href) ||
            !href->IsString()) {
          return ThrowArgument(isolate, member, index, "must be a URL or a string");
        }
      }
      return WriteString(isolate, href.As<v8::String>(), slot, arena);
    }

    case ValueCode::Kind::Data:
      if (value->IsArrayBufferView()) {
        Local<v8::ArrayBufferView> view = value.As<v8::ArrayBufferView>();
        auto* base = static_cast<const uint8_t*>(view->Buffer()->Data());
        PointAtBytes(slot, base ? base + view->ByteOffset() : nullptr, view->ByteLength());
        return true;
      }
      if (value->IsArrayBuffer()) {
        Local<v8::ArrayBuffer> buffer = value.As<v8::ArrayBuffer>();
        PointAtBytes(slot, buffer->Data(), buffer->ByteLength());
        return true;
      }
      return ThrowArgument(isolate, member, index, "must be an ArrayBuffer or a typed array");

    case ValueCode::Kind::Array: {
      if (!value->IsArray()) {
        return ThrowArgument(isolate, member, index, "must be an array");
      }
      Local<v8::Array> array = value.As<v8::Array>();
      uint32_t length = array->Length();
      arena.slots.emplace_back(length);
      std::vector<NSSwiftValue>& elements = arena.slots.back();
      for (uint32_t i = 0; i < length; i++) {
        Local<Value> element;
        if (!array->Get(context, i).ToLocal(&element) ||
            !Convert(isolate, context, module, member, index, code.element[0], element, elements[i],
                     arena)) {
          return false;
        }
      }
      slot.tag = NSSwiftTagArray;
      slot.payload.object = elements.data();
      slot.length = length;
      return true;
    }

    case ValueCode::Kind::Map: {
      if (!Accepts(isolate, module, code, value)) {
        return ThrowArgument(isolate, member, index, "must be a plain object");
      }
      Local<Object> object = value.As<Object>();
      Local<v8::Array> keys;
      if (!object->GetOwnPropertyNames(context).ToLocal(&keys)) {
        return false;
      }
      uint32_t count = keys->Length();
      arena.slots.emplace_back(2 * count);
      std::vector<NSSwiftValue>& entries = arena.slots.back();
      for (uint32_t i = 0; i < count; i++) {
        Local<Value> key;
        Local<Value> entry;
        if (!keys->Get(context, i).ToLocal(&key)) {
          return false;
        }
        Local<v8::String> name;
        if (!key->ToString(context).ToLocal(&name) || !object->Get(context, key).ToLocal(&entry)) {
          return false;
        }
        WriteString(isolate, name, entries[2 * i], arena);
        if (!Convert(isolate, context, module, member, index, code.element[0], entry,
                     entries[2 * i + 1], arena)) {
          return false;
        }
      }
      slot.tag = NSSwiftTagMap;
      slot.payload.object = entries.data();
      slot.length = count;
      return true;
    }

    case ValueCode::Kind::Object: {
      SwiftObjectWrapper* wrapper = SwiftWrapperOf(isolate, value);
      if (!wrapper || wrapper->Module() != &module ||
          !module.IsA(wrapper->TypeIndex(), code.typeIndex)) {
        return ThrowArgument(isolate, member, index, "must be a " + TypeDisplayName(module, code));
      }
      slot.tag = NSSwiftTagObject;
      slot.payload.object = wrapper->Object();
      return true;
    }

    case ValueCode::Kind::Void:
      break;
  }
  return ThrowArgument(isolate, member, index, "has an unsupported type");
}

// --- Dispatch ----------------------------------------------------------------------

bool IsInstanceKind(uint32_t kind) {
  return kind == NSSwiftMemberInstanceMethod || kind == NSSwiftMemberInstanceProperty;
}

struct Selection {
  const MemberInfo* member = nullptr;
  std::vector<Local<Value>> arguments;
};

// Picks the overload of `group` that `arguments` can call. Initializers also
// accept a single `{ label: value }` object naming every argument label.
bool Select(Isolate* isolate, Local<Context> context, const MemberGroup& group,
            const std::vector<Local<Value>>& arguments, Selection& selection) {
  const ModuleInfo& module = *group.module;
  std::vector<const MemberInfo*> matches;
  for (const MemberInfo* member : group.overloads) {
    const auto& parameters = member->signature.parameters;
    if (parameters.size() != arguments.size()) {
      continue;
    }
    bool accepts = true;
    for (size_t i = 0; accepts && i < parameters.size(); i++) {
      accepts = Accepts(isolate, module, parameters[i], arguments[i]);
    }
    if (accepts) {
      matches.push_back(member);
    }
  }

  if (matches.empty() && group.kind == NSSwiftMemberInitializer && arguments.size() == 1 &&
      IsPlainObject(isolate, arguments[0])) {
    Local<Object> object = arguments[0].As<Object>();
    Local<v8::Array> names;
    if (object->GetOwnPropertyNames(context).ToLocal(&names)) {
      std::set<std::string> keys;
      for (uint32_t i = 0; i < names->Length(); i++) {
        Local<Value> name;
        if (names->Get(context, i).ToLocal(&name)) {
          keys.insert(tns::ToString(isolate, name));
        }
      }
      for (const MemberInfo* member : group.overloads) {
        std::set<std::string> labels(member->labels.begin(), member->labels.end());
        if (member->labels.empty() || labels.count("") || labels != keys) {
          continue;
        }
        std::vector<Local<Value>> ordered;
        bool accepts = true;
        for (size_t i = 0; accepts && i < member->labels.size(); i++) {
          Local<Value> value;
          accepts =
              object->Get(context, tns::ToV8String(isolate, member->labels[i])).ToLocal(&value) &&
              Accepts(isolate, module, member->signature.parameters[i], value);
          ordered.push_back(value);
        }
        if (accepts) {
          selection.member = member;
          selection.arguments = std::move(ordered);
          return true;
        }
      }
    }
  }

  if (matches.size() == 1) {
    selection.member = matches[0];
    selection.arguments = arguments;
    return true;
  }

  std::string candidates;
  for (const MemberInfo* member : matches.empty() ? group.overloads : matches) {
    candidates +=
        (candidates.empty() ? "" : ", ") + std::string("'") + TypedKey(module, *member) + "'";
  }
  std::string message =
      matches.empty()
          ? "No overload of " + group.jsName + " accepts these arguments; candidates: " + candidates
          : "Ambiguous call to " + group.jsName + "; call one of " + candidates + " by key";
  isolate->ThrowException(Exception::TypeError(tns::ToV8String(isolate, message)));
  return false;
}

LoadedModule* LoadedFor(Isolate* isolate, const ModuleInfo* module) {
  auto* state = Caches::StateFor<IsolateState>(isolate);
  if (state == nullptr) {
    return nullptr;
  }
  auto it = state->byInfo.find(module);
  return it == state->byInfo.end() ? nullptr : it->second;
}

// Calls `member`'s getter/call thunk (or its setter when `setter`) with
// `receiver` (empty for non-instance members) and `arguments`.
MaybeLocal<Value> Invoke(Isolate* isolate, const MemberGroup& group, const MemberInfo& member,
                         Local<Value> receiver, const std::vector<Local<Value>>& arguments,
                         bool setter, Local<Object> constructTarget) {
  Local<Context> context = isolate->GetCurrentContext();
  const ModuleInfo& module = *group.module;
  auto* state = Caches::StateFor<IsolateState>(isolate);
  LoadedModule* loaded = LoadedFor(isolate, &module);
  if (state == nullptr || loaded == nullptr) {
    return MaybeLocal<Value>();
  }

  std::vector<NSSwiftValue> slots;
  SlotArena arena;
  slots.reserve(arguments.size() + 1);

  if (!receiver.IsEmpty()) {
    NSSwiftValue slot{};
    const TypeInfo& owner = module.types[member.owner];
    if (owner.kind == NSSwiftTypeEnum) {
      ValueCode code;
      code.kind = ValueCode::Kind::Enum;
      code.typeIndex = member.owner;
      if (!Convert(isolate, context, module, member, 0, code, receiver, slot, arena)) {
        return MaybeLocal<Value>();
      }
    } else {
      SwiftObjectWrapper* wrapper = SwiftWrapperOf(isolate, receiver);
      if (!wrapper || wrapper->Module() != &module ||
          !module.IsA(wrapper->TypeIndex(), member.owner)) {
        isolate->ThrowException(Exception::TypeError(tns::ToV8String(
            isolate, "Illegal invocation: " + member.swiftName + " needs a " + owner.jsName)));
        return MaybeLocal<Value>();
      }
      slot.tag = NSSwiftTagObject;
      slot.payload.object = wrapper->Object();
    }
    slots.push_back(slot);
  }

  if (setter) {
    NSSwiftValue slot{};
    if (!Convert(isolate, context, module, member, 0, member.signature.result, arguments[0], slot,
                 arena)) {
      return MaybeLocal<Value>();
    }
    slots.push_back(slot);
  } else {
    for (size_t i = 0; i < arguments.size(); i++) {
      NSSwiftValue slot{};
      if (!Convert(isolate, context, module, member, i, member.signature.parameters[i],
                   arguments[i], slot, arena)) {
        return MaybeLocal<Value>();
      }
      slots.push_back(slot);
    }
  }

  CallContext call;
  call.api = &kAPI;
  call.isolate = isolate;
  call.context = context;
  call.module = &module;
  call.loaded = loaded;
  call.state = state;
  call.member = &member;
  call.constructTarget = constructTarget;
  call.resultCode = &member.signature.result;

  NSSwiftThunk thunk = setter ? member.setter : member.thunk;
  thunk(&call, slots.empty() ? nullptr : slots.data(), static_cast<intptr_t>(slots.size()));

  if (call.threw) {
    return MaybeLocal<Value>();
  }
  if (!call.completed) {
    isolate->ThrowException(Exception::Error(
        tns::ToV8String(isolate, "Swift thunk for " + member.swiftName + " reported no result")));
    return MaybeLocal<Value>();
  }
  return call.result;
}

const MemberGroup* GroupOf(const FunctionCallbackInfo<Value>& info) {
  return static_cast<const MemberGroup*>(
      info.Data().As<External>()->Value(v8::kExternalPointerTypeTagDefault));
}

std::vector<Local<Value>> ArgumentsOf(const FunctionCallbackInfo<Value>& info, int first) {
  std::vector<Local<Value>> arguments;
  for (int i = first; i < info.Length(); i++) {
    arguments.push_back(info[i]);
  }
  return arguments;
}

bool ReceiverIsEnumArgument(const MemberGroup& group) {
  return IsInstanceKind(group.kind) && group.owner >= 0 &&
         group.module->types[group.owner].kind == NSSwiftTypeEnum;
}

// Methods, functions, and enum instance members (whose receiver, a case
// name, is the first argument).
void MethodCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  const MemberGroup& group = *GroupOf(info);
  Local<Value> receiver;
  int first = 0;
  if (ReceiverIsEnumArgument(group)) {
    if (info.Length() < 1) {
      isolate->ThrowException(Exception::TypeError(tns::ToV8String(
          isolate, group.jsName + " needs a " + group.module->types[group.owner].jsName +
                       " case name as its first argument")));
      return;
    }
    receiver = info[0];
    first = 1;
  } else if (IsInstanceKind(group.kind)) {
    receiver = info.This();
  }

  std::vector<Local<Value>> arguments = ArgumentsOf(info, first);
  Selection selection;
  if (group.kind == NSSwiftMemberInstanceProperty) {
    // Enum instance properties are exposed as functions of the case name.
    selection.member = group.overloads[0];
  } else if (!Select(isolate, isolate->GetCurrentContext(), group, arguments, selection)) {
    return;
  }
  Local<Value> result;
  if (Invoke(isolate, group, *selection.member, receiver, selection.arguments, false,
             Local<Object>())
          .ToLocal(&result)) {
    info.GetReturnValue().Set(result);
  }
}

// One overload by its signature key (`obj['scale(by: Int)'](2)`).
void ExactCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  const MemberGroup& group = *GroupOf(info);
  // Exact groups hold the single overload they were created for.
  const MemberInfo& member = *group.overloads[0];
  Local<Value> receiver;
  int first = 0;
  if (ReceiverIsEnumArgument(group)) {
    receiver = info.Length() > 0 ? info[0] : Local<Value>(v8::Undefined(isolate));
    first = 1;
  } else if (IsInstanceKind(group.kind)) {
    receiver = info.This();
  }
  std::vector<Local<Value>> arguments = ArgumentsOf(info, first);
  if (arguments.size() != member.signature.parameters.size()) {
    isolate->ThrowException(Exception::TypeError(tns::ToV8String(
        isolate, member.swiftName + " expects " +
                     std::to_string(member.signature.parameters.size()) + " argument(s)")));
    return;
  }
  Local<Value> result;
  if (Invoke(isolate, group, member, receiver, arguments, false, Local<Object>())
          .ToLocal(&result)) {
    info.GetReturnValue().Set(result);
  }
}

void GetterCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  const MemberGroup& group = *GroupOf(info);
  Local<Value> receiver = IsInstanceKind(group.kind) ? Local<Value>(info.This()) : Local<Value>();
  Local<Value> result;
  if (Invoke(isolate, group, *group.overloads[0], receiver, {}, false, Local<Object>())
          .ToLocal(&result)) {
    info.GetReturnValue().Set(result);
  }
}

void SetterCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  const MemberGroup& group = *GroupOf(info);
  Local<Value> receiver = IsInstanceKind(group.kind) ? Local<Value>(info.This()) : Local<Value>();
  std::vector<Local<Value>> arguments = {info.Length() > 0 ? info[0]
                                                           : Local<Value>(v8::Undefined(isolate))};
  Invoke(isolate, group, *group.overloads[0], receiver, arguments, true, Local<Object>());
}

void ConstructorCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  const TypeInfo& type = *static_cast<const TypeInfo*>(
      info.Data().As<External>()->Value(v8::kExternalPointerTypeTagDefault));
  if (!info.IsConstructCall()) {
    isolate->ThrowException(Exception::TypeError(tns::ToV8String(
        isolate, "Class constructor " + type.jsName + " cannot be invoked without 'new'")));
    return;
  }
  if (type.initializers == nullptr) {
    isolate->ThrowException(Exception::TypeError(
        tns::ToV8String(isolate, type.swiftName + " has no initializer callable from JavaScript")));
    return;
  }
  const MemberGroup& group = *type.initializers;
  Selection selection;
  if (!Select(isolate, isolate->GetCurrentContext(), group, ArgumentsOf(info, 0), selection)) {
    return;
  }
  Local<Value> result;
  if (Invoke(isolate, group, *selection.member, Local<Value>(), selection.arguments, false,
             info.This())
          .ToLocal(&result)) {
    // A failable initializer that fails produces null, which `new` cannot
    // return; report it instead of yielding an unbacked object.
    if (result->IsNull()) {
      isolate->ThrowException(Exception::Error(
          tns::ToV8String(isolate, selection.member->swiftName + " failed (returned nil)")));
      return;
    }
    info.GetReturnValue().Set(result);
  }
}

// --- Building a module's JS surface for one isolate --------------------------------

Local<External> DataFor(Isolate* isolate, const void* pointer) {
  return External::New(isolate, const_cast<void*>(pointer), v8::kExternalPointerTypeTagDefault);
}

std::vector<std::unique_ptr<MemberGroup>>& ExactGroups() {
  // Single-overload groups backing signature keys; process-lifetime like the
  // modules they point into.
  static std::vector<std::unique_ptr<MemberGroup>> groups;
  return groups;
}

std::mutex gExactGroupsMutex;

robin_hood::unordered_map<const MemberInfo*, const MemberGroup*>& ExactGroupIndex() {
  static robin_hood::unordered_map<const MemberInfo*, const MemberGroup*> index;
  return index;
}

const MemberGroup* ExactGroupFor(const MemberGroup& group, const MemberInfo& member) {
  std::lock_guard<std::mutex> lock(gExactGroupsMutex);
  auto& index = ExactGroupIndex();
  auto it = index.find(&member);
  if (it != index.end()) {
    return it->second;
  }
  auto exact = std::make_unique<MemberGroup>();
  exact->module = group.module;
  exact->owner = group.owner;
  exact->kind = group.kind;
  exact->jsName = group.jsName;
  exact->overloads = {&member};
  const MemberGroup* result = exact.get();
  ExactGroups().push_back(std::move(exact));
  index.emplace(&member, result);
  return result;
}

// Keys reaching individual overloads: the Swift name when it is unique in the
// group, the typed key otherwise.
std::vector<std::pair<std::string, const MemberInfo*>> OverloadKeys(const MemberGroup& group) {
  std::vector<std::pair<std::string, const MemberInfo*>> keys;
  if (group.overloads.size() < 2) {
    return keys;
  }
  robin_hood::unordered_map<std::string, int> counts;
  for (const MemberInfo* member : group.overloads) {
    counts[member->swiftName]++;
  }
  for (const MemberInfo* member : group.overloads) {
    keys.emplace_back(
        counts[member->swiftName] == 1 ? member->swiftName : TypedKey(*group.module, *member),
        member);
  }
  return keys;
}

class Builder {
 public:
  Builder(Isolate* isolate, Local<Context> context, LoadedModule& loaded)
      : _isolate(isolate), _context(context), _loaded(loaded), _module(*loaded.info) {}

  MaybeLocal<Object> Build() {
    Local<Object> exports = Object::New(_isolate);

    _loaded.templates.resize(_module.types.size());
    std::vector<Local<FunctionTemplate>> templates(_module.types.size());
    for (const TypeInfo& type : _module.types) {
      if (type.kind == NSSwiftTypeEnum) {
        continue;
      }
      Local<FunctionTemplate> tmpl =
          FunctionTemplate::New(_isolate, ConstructorCallback, DataFor(_isolate, &type));
      tmpl->SetClassName(tns::ToV8String(_isolate, type.jsName));
      tmpl->InstanceTemplate()->SetInternalFieldCount(1);
      templates[type.index] = tmpl;
    }
    for (const TypeInfo& type : _module.types) {
      if (type.superIndex >= 0 && !templates[type.index].IsEmpty() &&
          !templates[type.superIndex].IsEmpty()) {
        templates[type.index]->Inherit(templates[type.superIndex]);
      }
    }

    std::vector<Local<Object>> enums(_module.types.size());
    for (const TypeInfo& type : _module.types) {
      if (type.kind == NSSwiftTypeEnum) {
        enums[type.index] = Object::New(_isolate);
      }
    }

    // Members onto templates first: a template cannot change once its
    // function exists.
    std::vector<const MemberGroup*> moduleGroups;
    std::vector<const MemberGroup*> enumGroups;
    for (const auto& group : _module.groups) {
      if (group->owner < 0) {
        moduleGroups.push_back(group.get());
        continue;
      }
      const TypeInfo& owner = _module.types[group->owner];
      if (owner.kind == NSSwiftTypeEnum) {
        enumGroups.push_back(group.get());
        continue;
      }
      InstallOnTemplate(templates[group->owner], *group);
    }

    for (const TypeInfo& type : _module.types) {
      Local<Value> value;
      if (type.kind == NSSwiftTypeEnum) {
        value = enums[type.index];
      } else {
        Local<v8::Function> function;
        if (!templates[type.index]->GetFunction(_context).ToLocal(&function)) {
          return MaybeLocal<Object>();
        }
        _loaded.templates[type.index].Reset(_isolate, templates[type.index]);
        value = function;
      }
      if (!exports->Set(_context, tns::ToV8String(_isolate, type.jsName), value).FromMaybe(false)) {
        return MaybeLocal<Object>();
      }
    }

    for (const MemberGroup* group : enumGroups) {
      if (!InstallOnObject(enums[group->owner], *group)) {
        return MaybeLocal<Object>();
      }
    }
    for (const MemberGroup* group : moduleGroups) {
      if (!InstallOnObject(exports, *group)) {
        return MaybeLocal<Object>();
      }
    }
    for (Local<Object> enumObject : enums) {
      if (!enumObject.IsEmpty()) {
        enumObject->SetIntegrityLevel(_context, IntegrityLevel::kFrozen).Check();
      }
    }
    exports->SetIntegrityLevel(_context, IntegrityLevel::kFrozen).Check();
    return exports;
  }

 private:
  Local<FunctionTemplate> MethodTemplate(const MemberGroup& group,
                                         FunctionCallback callback = MethodCallback) {
    Local<FunctionTemplate> tmpl =
        FunctionTemplate::New(_isolate, callback, DataFor(_isolate, &group));
    tmpl->RemovePrototype();
    return tmpl;
  }

  bool HasSetter(const MemberGroup& group) const {
    return (group.overloads[0]->flags & NSSwiftMemberSettable) &&
           group.overloads[0]->setter != nullptr;
  }

  void InstallOnTemplate(Local<FunctionTemplate> tmpl, const MemberGroup& group) {
    Local<v8::String> name = tns::ToV8String(_isolate, group.jsName);
    switch (group.kind) {
      case NSSwiftMemberInitializer:
        // Reached through `new`; see ConstructorCallback.
        break;
      case NSSwiftMemberInstanceMethod:
        tmpl->PrototypeTemplate()->Set(name, MethodTemplate(group));
        for (const auto& key : OverloadKeys(group)) {
          tmpl->PrototypeTemplate()->Set(
              tns::ToV8String(_isolate, key.first),
              MethodTemplate(*ExactGroupFor(group, *key.second), ExactCallback));
        }
        break;
      case NSSwiftMemberStaticMethod:
        tmpl->Set(name, MethodTemplate(group));
        for (const auto& key : OverloadKeys(group)) {
          tmpl->Set(tns::ToV8String(_isolate, key.first),
                    MethodTemplate(*ExactGroupFor(group, *key.second), ExactCallback));
        }
        break;
      case NSSwiftMemberInstanceProperty:
        tmpl->PrototypeTemplate()->SetAccessorProperty(
            name, MethodTemplate(group, GetterCallback),
            HasSetter(group) ? MethodTemplate(group, SetterCallback) : Local<FunctionTemplate>());
        break;
      case NSSwiftMemberStaticProperty:
        tmpl->SetAccessorProperty(
            name, MethodTemplate(group, GetterCallback),
            HasSetter(group) ? MethodTemplate(group, SetterCallback) : Local<FunctionTemplate>());
        break;
      default:
        break;
    }
  }

  bool SetFunction(Local<Object> target, const std::string& key, Local<FunctionTemplate> tmpl) {
    Local<v8::Function> function;
    return tmpl->GetFunction(_context).ToLocal(&function) &&
           target->Set(_context, tns::ToV8String(_isolate, key), function).FromMaybe(false);
  }

  // Enum and module-level members, on a plain object.
  bool InstallOnObject(Local<Object> target, const MemberGroup& group) {
    Local<v8::String> name = tns::ToV8String(_isolate, group.jsName);
    switch (group.kind) {
      case NSSwiftMemberEnumCase:
        // A case's JS value is its name.
        return target
            ->DefineOwnProperty(_context, name, name,
                                static_cast<PropertyAttribute>(ReadOnly | DontDelete))
            .FromMaybe(false);
      case NSSwiftMemberInitializer:
        // Enum initializers (`init?(rawValue:)`) yield a case name, which
        // `new` cannot produce.
        return SetFunction(target, "init", MethodTemplate(group));
      case NSSwiftMemberStaticProperty:
      case NSSwiftMemberVariable: {
        Local<v8::Function> getter;
        Local<v8::Function> setter;
        if (!MethodTemplate(group, GetterCallback)->GetFunction(_context).ToLocal(&getter)) {
          return false;
        }
        if (HasSetter(group) &&
            !MethodTemplate(group, SetterCallback)->GetFunction(_context).ToLocal(&setter)) {
          return false;
        }
        target->SetAccessorProperty(name, getter, setter);
        return true;
      }
      case NSSwiftMemberInstanceProperty:
      case NSSwiftMemberInstanceMethod:
      case NSSwiftMemberStaticMethod:
      case NSSwiftMemberFunction: {
        if (!SetFunction(target, group.jsName, MethodTemplate(group))) {
          return false;
        }
        for (const auto& key : OverloadKeys(group)) {
          if (!SetFunction(target, key.first,
                           MethodTemplate(*ExactGroupFor(group, *key.second), ExactCallback))) {
            return false;
          }
        }
        return true;
      }
      default:
        return true;
    }
  }

  Isolate* _isolate;
  Local<Context> _context;
  LoadedModule& _loaded;
  const ModuleInfo& _module;
};

void LoadModuleCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  if (info.Length() < 1 || !info[0]->IsString()) {
    isolate->ThrowException(
        Exception::TypeError(tns::ToV8String(isolate, "The Swift module name must be a string")));
    return;
  }
  Local<Object> exports;
  if (LoadModule(isolate->GetCurrentContext(), tns::ToString(isolate, info[0])).ToLocal(&exports)) {
    info.GetReturnValue().Set(exports);
  }
}

void ModuleInfoCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Context> context = isolate->GetCurrentContext();
  if (info.Length() < 1 || !info[0]->IsString()) {
    return;
  }
  std::string error;
  std::shared_ptr<const ModuleInfo> module = LoadModuleInfo(tns::ToString(isolate, info[0]), error);
  if (!module) {
    isolate->ThrowException(Exception::Error(tns::ToV8String(isolate, error)));
    return;
  }
  Local<Object> result = Object::New(isolate);
  result->Set(context, tns::ToV8String(isolate, "name"), tns::ToV8String(isolate, module->name))
      .Check();
  result
      ->Set(context, tns::ToV8String(isolate, "fingerprint"),
            tns::ToV8String(isolate, module->fingerprint))
      .Check();
  result
      ->Set(context, tns::ToV8String(isolate, "abiVersion"),
            v8::Number::New(isolate, module->abiVersion))
      .Check();
  result
      ->Set(context, tns::ToV8String(isolate, "members"),
            v8::Number::New(isolate, static_cast<double>(module->members.size())))
      .Check();
  info.GetReturnValue().Set(result);
}

}  // namespace

MaybeLocal<Object> LoadModule(Local<Context> context, const std::string& name) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  if (!IsValidModuleName(name)) {
    isolate->ThrowException(Exception::TypeError(
        tns::ToV8String(isolate, "'" + name + "' is not a valid Swift module name")));
    return MaybeLocal<Object>();
  }

  auto* state = Caches::StateFor<IsolateState>(isolate);
  if (state == nullptr) {
    return MaybeLocal<Object>();
  }
  auto cached = state->modules.find(name);
  if (cached != state->modules.end()) {
    return cached->second->exports.Get(isolate);
  }

  std::string error;
  std::shared_ptr<const ModuleInfo> module = LoadModuleInfo(name, error);
  if (!module) {
    isolate->ThrowException(Exception::Error(tns::ToV8String(isolate, error)));
    return MaybeLocal<Object>();
  }

  auto loaded = std::make_unique<LoadedModule>();
  loaded->info = module;
  LoadedModule* raw = loaded.get();
  state->byInfo[module.get()] = raw;
  Local<Object> exports;
  if (!Builder(isolate, context, *raw).Build().ToLocal(&exports)) {
    state->byInfo.erase(module.get());
    return MaybeLocal<Object>();
  }
  loaded->exports.Reset(isolate, exports);
  state->modules.emplace(name, std::move(loaded));
  return exports;
}

MaybeLocal<Object> CreateBinding(Local<Context> context) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<Object> binding = Object::New(isolate);
  Local<v8::Function> loadModule;
  Local<v8::Function> moduleInfo;
  if (!v8::Function::New(context, LoadModuleCallback).ToLocal(&loadModule) ||
      !v8::Function::New(context, ModuleInfoCallback).ToLocal(&moduleInfo) ||
      !binding->Set(context, tns::ToV8String(isolate, "loadModule"), loadModule).FromMaybe(false) ||
      !binding->Set(context, tns::ToV8String(isolate, "moduleInfo"), moduleInfo).FromMaybe(false) ||
      !binding
           ->Set(context, tns::ToV8String(isolate, "abiVersion"),
                 v8::Number::New(isolate, NS_SWIFT_ABI_VERSION))
           .FromMaybe(false)) {
    return MaybeLocal<Object>();
  }
  return binding;
}

}  // namespace SwiftInterop
}  // namespace tns
