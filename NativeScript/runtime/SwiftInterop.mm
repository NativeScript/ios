#include "SwiftInterop.h"

#include <dlfcn.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <vector>

#include "ArgConverter.h"
#include "Caches.h"
#include "DataWrapper.h"
#include "EventLoop.h"
#include "Helpers.h"
#include "IsolateTracked.h"
#include "IsolateWrapper.h"
#include "NativeScriptException.h"
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
    Set,
    Tuple,
    Function,
    Tagged,
    ObjC,
    Protocol,
    AsyncSequence,
  };
  Kind kind = Kind::Void;
  int bits = 64;
  int typeIndex = -1;
  bool optional = false;
  // A parameter passed as a reference object (`&` prefix).
  bool inout = false;
  // ObjC: the class's runtime name, and the class when it is loaded.
  std::string className;
  Class objcClass = nil;
  // Array and Map: the element (value) code. Function: its parameter codes.
  std::vector<ValueCode> element;
  // Function: its result code; empty for Void.
  std::vector<ValueCode> returns;
  // Tuple: its element codes are `element`; its labels, or empty when none
  // is labeled (a JS array rather than an object).
  std::vector<std::string> labels;
};

// The '>' before the result in "params>result": the last one outside
// brackets, since closure parameters carry their own.
size_t ResultArrow(const std::string& text) {
  int depth = 0;
  size_t arrow = std::string::npos;
  for (size_t i = 0; i < text.size(); i++) {
    char c = text[i];
    depth += (c == '[' || c == '{' || c == '(') - (c == ']' || c == '}' || c == ')');
    if (c == '>' && depth == 0) {
      arrow = i;
    }
  }
  return arrow;
}

// Splits "a,[b],(c,d)" at its top-level commas.
bool SplitCodes(const std::string& text, std::vector<std::string>& parts) {
  int depth = 0;
  size_t start = 0;
  for (size_t i = 0; i < text.size(); i++) {
    char c = text[i];
    if (c == '[' || c == '{' || c == '(') {
      depth++;
    } else if (c == ']' || c == '}' || c == ')') {
      if (--depth < 0) {
        return false;
      }
    } else if (c == ',' && depth == 0) {
      parts.push_back(text.substr(start, i - start));
      start = i + 1;
    }
  }
  if (depth != 0) {
    return false;
  }
  if (!text.empty()) {
    parts.push_back(text.substr(start));
  }
  return true;
}

bool ParseCode(std::string text, ValueCode& code) {
  if (!text.empty() && text.back() == '?') {
    code.optional = true;
    text.pop_back();
  }
  if (text.empty()) {
    return false;
  }
  if (text.front() == '~') {
    code.kind = ValueCode::Kind::AsyncSequence;
    code.element.emplace_back();
    ValueCode& element = code.element.back();
    return ParseCode(text.substr(1), element) && element.kind != ValueCode::Kind::Void &&
           element.kind != ValueCode::Kind::Function && !element.optional;
  }
  if (text.size() > 3 && text.compare(0, 2, "S[") == 0 && text.back() == ']') {
    code.kind = ValueCode::Kind::Set;
    code.element.emplace_back();
    ValueCode& element = code.element.back();
    return ParseCode(text.substr(2, text.size() - 3), element) &&
           element.kind != ValueCode::Kind::Void && element.kind != ValueCode::Kind::Function &&
           !element.optional;
  }
  if (text.size() > 3 && text.compare(0, 2, "*(") == 0 && text.back() == ')') {
    code.kind = ValueCode::Kind::Tuple;
    std::vector<std::string> parts;
    if (!SplitCodes(text.substr(2, text.size() - 3), parts) || parts.size() < 2) {
      return false;
    }
    for (std::string part : parts) {
      // "label:code"; codes themselves start with no identifier and colon.
      size_t colon = part.find(':');
      bool labeled = colon != std::string::npos && colon > 0 &&
                     std::all_of(part.begin(), part.begin() + colon,
                                 [](char c) { return std::isalnum(c) || c == '_'; });
      // Every element is labeled, or none is.
      if (!code.element.empty() && labeled == code.labels.empty()) {
        return false;
      }
      if (labeled) {
        code.labels.push_back(part.substr(0, colon));
        part = part.substr(colon + 1);
      }
      code.element.emplace_back();
      if (!ParseCode(part, code.element.back()) ||
          code.element.back().kind == ValueCode::Kind::Void ||
          code.element.back().kind == ValueCode::Kind::Function) {
        return false;
      }
    }
    return true;
  }
  if ((text.front() == '[' && text.back() == ']') || (text.front() == '{' && text.back() == '}')) {
    code.kind = text.front() == '[' ? ValueCode::Kind::Array : ValueCode::Kind::Map;
    code.element.emplace_back();
    ValueCode& element = code.element.back();
    return ParseCode(text.substr(1, text.size() - 2), element) &&
           element.kind != ValueCode::Kind::Void && element.kind != ValueCode::Kind::Function;
  }
  if (text.front() == '(' && text.back() == ')') {
    code.kind = ValueCode::Kind::Function;
    std::string inner = text.substr(1, text.size() - 2);
    size_t arrow = ResultArrow(inner);
    if (arrow != std::string::npos) {
      code.returns.emplace_back();
      if (!ParseCode(inner.substr(arrow + 1), code.returns.back()) ||
          code.returns.back().kind == ValueCode::Kind::Function ||
          code.returns.back().kind == ValueCode::Kind::Void) {
        return false;
      }
      inner = inner.substr(0, arrow);
    }
    std::vector<std::string> parts;
    if (!SplitCodes(inner, parts)) {
      return false;
    }
    for (const std::string& part : parts) {
      code.element.emplace_back();
      ValueCode& parameter = code.element.back();
      if (!ParseCode(part, parameter) || parameter.kind == ValueCode::Kind::Void ||
          parameter.kind == ValueCode::Kind::Function) {
        return false;
      }
    }
    return true;
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
    case 't':
      code.kind = ValueCode::Kind::Tagged;
      return number(text.substr(1), code.typeIndex);
    case 'p':
      code.kind = ValueCode::Kind::Protocol;
      return number(text.substr(1), code.typeIndex);
    case '@':
      code.kind = ValueCode::Kind::ObjC;
      code.className = text.substr(1);
      code.objcClass = NSClassFromString([NSString stringWithUTF8String:code.className.c_str()]);
      return !code.className.empty();
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
  size_t arrow = ResultArrow(text);
  if (arrow == std::string::npos) {
    return false;
  }
  std::vector<std::string> parts;
  if (!SplitCodes(text.substr(0, arrow), parts)) {
    return false;
  }
  for (const std::string& part : parts) {
    ValueCode code;
    bool inout = !part.empty() && part[0] == '&';
    if (!ParseCode(inout ? part.substr(1) : part, code) || code.kind == ValueCode::Kind::Void ||
        (inout && code.kind == ValueCode::Kind::Function)) {
      return false;
    }
    code.inout = inout;
    signature.parameters.push_back(code);
  }
  return ParseCode(text.substr(arrow + 1), signature.result) &&
         signature.result.kind != ValueCode::Kind::Function;
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
  std::string swiftModule;
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
  // Module-level groups: the Swift module whose namespace holds them.
  std::string swiftModule;
  // Overloads of several types (a generic family's instantiations): a call
  // picks those of its receiver's type.
  bool mixedOwners = false;
  uint32_t kind = 0;
  std::string jsName;
  std::vector<const MemberInfo*> overloads;
};

// One case of a tagged enum: its JS keys and value codes, by position.
struct CaseInfo {
  std::string name;
  std::vector<std::string> keys;
  std::vector<ValueCode> codes;
};

struct TypeInfo {
  uint32_t index = 0;
  uint32_t kind = 0;
  std::string swiftModule;
  std::string jsName;
  std::string swiftName;
  int superIndex = -1;
  const ModuleInfo* module = nullptr;
  // Initializers (`new Type(...)`), or null when the type has none.
  const MemberGroup* initializers = nullptr;
  // NSSwiftTypeTaggedEnum: the cases, by case index.
  std::vector<CaseInfo> cases;
  // Instantiations of one generic type share a module and JS name; they
  // form a family with one JS class, named by its first type's index.
  int family = -1;
  // NSSwiftTypeProtocol: the requirement table adapters call by index.
  std::vector<const MemberInfo*> requirements;
};

bool IsEnumKind(uint32_t kind) { return kind == NSSwiftTypeEnum || kind == NSSwiftTypeTaggedEnum; }

// A registered unit: one or more Swift modules sharing one type table.
struct ModuleInfo {
  // The unit's name.
  std::string name;
  // Its Swift modules, each an `ns:swift/<name>` namespace.
  std::vector<std::string> modules;
  NSSwiftTracker tracker = nullptr;
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
    case ValueCode::Kind::Set:
      name = "Set<" + TypeDisplayName(module, code.element.at(0)) + ">";
      break;
    case ValueCode::Kind::Tuple:
      name = "(";
      for (size_t i = 0; i < code.element.size(); i++) {
        name += (i > 0 ? ", " : "") + (code.labels.empty() ? "" : code.labels[i] + ": ") +
                TypeDisplayName(module, code.element[i]);
      }
      name += ")";
      break;
    case ValueCode::Kind::Object:
    case ValueCode::Kind::Enum:
    case ValueCode::Kind::Tagged:
    case ValueCode::Kind::Protocol:
      name = code.typeIndex >= 0 && code.typeIndex < static_cast<int>(module.types.size())
                 ? module.types[code.typeIndex].jsName
                 : "?";
      break;
    case ValueCode::Kind::Function:
      name = "(";
      for (size_t i = 0; i < code.element.size(); i++) {
        name += (i > 0 ? ", " : "") + TypeDisplayName(module, code.element[i]);
      }
      name += ") -> " + (code.returns.empty() ? std::string("Void")
                                              : TypeDisplayName(module, code.returns[0]));
      if (code.optional) {
        name = "(" + name + ")";
      }
      break;
    case ValueCode::Kind::ObjC:
      name = code.className;
      break;
    case ValueCode::Kind::AsyncSequence:
      name = "AsyncSequence<" + TypeDisplayName(module, code.element.at(0)) + ">";
      break;
  }
  return (code.inout ? "inout " : "") + (code.optional ? name + "?" : name);
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
  module->name = name ? name : "";
  module->fingerprint = fingerprint ? fingerprint : "";
  module->release = release;
}

void ApiRegisterTracker(NSSwiftRegistrar* registrar, NSSwiftTracker tracker) {
  static_cast<Registrar*>(registrar)->module->tracker = tracker;
}

void ApiRegisterUnitModule(NSSwiftRegistrar* registrar, const char* name) {
  ModuleInfo* module = static_cast<Registrar*>(registrar)->module;
  if (name != nullptr &&
      std::find(module->modules.begin(), module->modules.end(), name) == module->modules.end()) {
    module->modules.push_back(name);
  }
}

void ApiRegisterType(NSSwiftRegistrar* registrar, uint32_t index, uint32_t kind,
                     const char* swiftModule, const char* jsName, const char* swiftName,
                     int32_t superIndex) {
  ModuleInfo* module = static_cast<Registrar*>(registrar)->module;
  if (index != module->types.size()) {
    module->error = "type indices are not dense";
    return;
  }
  TypeInfo type;
  type.index = index;
  type.kind = kind;
  type.swiftModule = swiftModule ? swiftModule : "";
  type.jsName = jsName ? jsName : "";
  type.swiftName = swiftName ? swiftName : "";
  type.superIndex = superIndex;
  module->types.push_back(std::move(type));
}

void ApiRegisterMember(NSSwiftRegistrar* registrar, int32_t owner, uint32_t kind, uint32_t flags,
                       const char* swiftModule, const char* jsName, const char* swiftName,
                       const char* signature, NSSwiftThunk thunk, NSSwiftThunk setter) {
  ModuleInfo* module = static_cast<Registrar*>(registrar)->module;
  MemberInfo member;
  member.owner = owner;
  member.swiftModule = swiftModule ? swiftModule : "";
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
  if (kind == NSSwiftMemberEnumCase && owner >= 0 &&
      owner < static_cast<int32_t>(module->types.size()) &&
      module->types[owner].kind == NSSwiftTypeTaggedEnum) {
    const auto& codes = member.signature.parameters;
    if (member.labels.size() != codes.size()) {
      module->error = "case " + member.swiftName + " does not match its signature";
      return;
    }
    CaseInfo info;
    info.name = member.jsName;
    info.codes = codes;
    for (size_t i = 0; i < codes.size(); i++) {
      std::string key = !member.labels[i].empty() ? member.labels[i]
                        : codes.size() == 1       ? "value"
                                                  : std::to_string(i);
      if (key == "case") {
        module->error = "case " + member.swiftName + " has a value keyed 'case'";
        return;
      }
      info.keys.push_back(key);
    }
    module->types[owner].cases.push_back(std::move(info));
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
void* ApiCallbackBegin(void* callback);
void ApiCallbackRetain(void* callback);
void ApiCallbackRelease(void* callback);
void ApiReturnCaseBegin(NSSwiftCall* call, intptr_t caseIndex);
void ApiCompleteCaseBegin(void* token, intptr_t caseIndex);
void ApiWriteBackBegin(NSSwiftCall* call, intptr_t index);
void ApiWriteBackEnd(NSSwiftCall* call);
void ApiReturnObjC(NSSwiftCall* call, void* object);
void ApiCompleteObjC(void* token, void* object);
void ApiRegisterUnitModule(NSSwiftRegistrar* registrar, const char* name);
void* ApiObjectCallBegin(void* object, intptr_t index);
const NSSwiftValue* ApiObjectCallEnd(void* token);
void ApiObjectResultRelease(const NSSwiftValue* result);
void ApiReturnJSObject(NSSwiftCall* call, void* object);
void ApiCompleteJSObject(void* token, void* object);
void ApiRegisterTracker(NSSwiftRegistrar* registrar, NSSwiftTracker tracker);
const NSSwiftValue* ApiCallbackCallEnd(void* token);
void ApiReturnAsyncSequence(NSSwiftCall* call, void* iterator, NSSwiftThunk next);
void ApiCompleteAsyncSequence(void* token, void* iterator, NSSwiftThunk next);
struct IsolateState;
// A JS async iterator over a Swift iterator (+1, taken over).
MaybeLocal<Value> MakeAsyncIterator(Isolate* isolate, Local<Context> context,
                                    const ModuleInfo* module, void* iterator, NSSwiftThunk next,
                                    const ValueCode& code, const std::string& name);
struct SwiftCallback;
Local<Value> JSObjectOf(SwiftCallback* handle, Isolate* isolate);
void ReleaseCallback(SwiftCallback* callback);

const NSSwiftAPI kAPI = {
    ApiReturnVoid,           ApiReturnBool,           ApiReturnInt64,
    ApiReturnUInt64,         ApiReturnDouble,         ApiReturnString,
    ApiReturnNull,           ApiReturnObject,         ApiThrowError,
    ApiThrowTypeError,       ApiRegisterModule,       ApiRegisterType,
    ApiRegisterMember,       ApiBeginAsync,           ApiCompleteVoid,
    ApiCompleteBool,         ApiCompleteInt64,        ApiCompleteUInt64,
    ApiCompleteDouble,       ApiCompleteString,       ApiCompleteNull,
    ApiCompleteObject,       ApiCompleteError,        ApiReturnArrayBegin,
    ApiReturnArrayEnd,       ApiReturnMapBegin,       ApiReturnMapEnd,
    ApiCompleteArrayBegin,   ApiCompleteContainerEnd, ApiCompleteMapBegin,
    ApiCompleteContainerEnd, ApiCallbackBegin,        ApiCallbackRetain,
    ApiCallbackRelease,      ApiReturnCaseBegin,      ApiCompleteCaseBegin,
    ApiReturnArrayEnd,       ApiCompleteContainerEnd, ApiWriteBackBegin,
    ApiWriteBackEnd,         ApiReturnObjC,           ApiCompleteObjC,
    ApiRegisterUnitModule,   ApiObjectCallBegin,      ApiObjectCallEnd,
    ApiObjectResultRelease,  ApiReturnJSObject,       ApiCompleteJSObject,
    ApiRegisterTracker,      ApiReturnAsyncSequence,  ApiCompleteAsyncSequence,
    ApiCallbackCallEnd,
};

// "Polygon.Style" -> "Style".
std::string LastComponent(const std::string& path) {
  size_t dot = path.rfind('.');
  return dot == std::string::npos ? path : path.substr(dot + 1);
}

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

void BuildRequirements(ModuleInfo& module) {
  std::vector<bool> built(module.types.size(), false);
  std::function<void(TypeInfo&)> build = [&](TypeInfo& type) {
    if (built[type.index]) {
      return;
    }
    built[type.index] = true;
    if (type.superIndex >= 0 && module.types[type.superIndex].kind == NSSwiftTypeProtocol) {
      build(module.types[type.superIndex]);
      type.requirements = module.types[type.superIndex].requirements;
    }
    for (const MemberInfo& member : module.members) {
      if (member.owner == static_cast<int>(type.index) &&
          (member.flags & NSSwiftMemberRequirement)) {
        type.requirements.push_back(&member);
      }
    }
  };
  for (TypeInfo& type : module.types) {
    if (type.kind == NSSwiftTypeProtocol) {
      build(type);
    }
  }
}

void BuildFamilies(ModuleInfo& module) {
  std::map<std::string, int> first;
  for (TypeInfo& type : module.types) {
    auto inserted = first.emplace(type.swiftModule + ":" + type.jsName, type.index);
    type.family = inserted.first->second;
  }
}

void BuildGroups(ModuleInfo& module) {
  robin_hood::unordered_map<std::string, MemberGroup*> byKey;
  for (const MemberInfo& member : module.members) {
    int owner = member.owner < 0 ? -1 : module.types[member.owner].family;
    std::string key = std::to_string(owner) + ":" + std::to_string(member.kind) + ":" +
                      member.jsName + (member.owner < 0 ? ":" + member.swiftModule : "");
    auto it = byKey.find(key);
    MemberGroup* group;
    if (it == byKey.end()) {
      module.groups.push_back(std::make_unique<MemberGroup>());
      group = module.groups.back().get();
      group->module = &module;
      group->owner = owner;
      group->swiftModule = member.owner < 0 ? member.swiftModule : "";
      group->kind = member.kind;
      group->jsName = member.jsName;
      byKey.emplace(key, group);
    } else {
      group = it->second;
    }
    group->mixedOwners |= !group->overloads.empty() && group->overloads[0]->owner != member.owner;
    group->overloads.push_back(&member);
    if (member.kind == NSSwiftMemberInitializer && member.owner >= 0) {
      module.types[member.owner].initializers = group;
      module.types[owner].initializers = group;
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
  auto inUnit = [&](const std::string& name) {
    return std::find(module.modules.begin(), module.modules.end(), name) != module.modules.end();
  };
  for (const TypeInfo& type : module.types) {
    if (!inUnit(type.swiftModule)) {
      return "type " + type.swiftName + " names an unregistered module";
    }
  }
  for (const MemberInfo& member : module.members) {
    if (member.owner < 0 && !inUnit(member.swiftModule)) {
      return member.swiftName + " names an unregistered module";
    }
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
      if (code->kind == ValueCode::Kind::Tagged &&
          (!validType(code->typeIndex) ||
           module.types[code->typeIndex].kind != NSSwiftTypeTaggedEnum)) {
        return member.swiftName + " references an unknown enum";
      }
      if (code->kind == ValueCode::Kind::Protocol &&
          (!validType(code->typeIndex) ||
           module.types[code->typeIndex].kind != NSSwiftTypeProtocol)) {
        return member.swiftName + " references an unknown protocol";
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
    if (problem.empty() &&
        std::find(module->modules.begin(), module->modules.end(), name) == module->modules.end()) {
      problem = "registers a unit without it";
    }
    for (const auto& other : module->modules) {
      auto registered = gModules.find(other);
      if (problem.empty() && other != name && registered != gModules.end()) {
        problem = "shares module '" + other + "' with another unit";
      }
    }
    if (!problem.empty()) {
      module->error = "Swift module '" + name + "' " + problem;
    } else {
      BuildFamilies(*module);
      BuildRequirements(*module);
      BuildGroups(*module);
      for (const auto& other : module->modules) {
        gModules.emplace(other, module);
      }
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

// A unit as one isolate sees it.
struct LoadedModule {
  std::shared_ptr<const ModuleInfo> info;
  // Each Swift module's namespace.
  robin_hood::unordered_map<std::string, Global<Object>> exports;
  // Constructor templates by type index; empty for enums.
  std::vector<Global<FunctionTemplate>> templates;
};

// An async call's Promise, settled on the isolate's thread.
// Its own copy of what the result is: the call's member may be gone by the
// time it settles (an iterator step's).
struct PendingAsync {
  Global<Promise::Resolver> resolver;
  ValueCode code;
  std::string name;
};

struct IsolateState {
  // Resolvers stay here, on the isolate's thread: a v8::Global must not be
  // destroyed by the thread that completes the call.
  robin_hood::unordered_map<uint64_t, std::unique_ptr<PendingAsync>> pending;
  uint64_t nextAsyncId = 1;
  robin_hood::unordered_map<const ModuleInfo*, std::unique_ptr<LoadedModule>> byInfo;
  // Swift object -> its JS wrapper, so a Swift object has one JS identity.
  robin_hood::unordered_map<void*, SwiftObjectWrapper*> identity;
  // Thunk calls in progress on the isolate's thread, innermost last.
  std::vector<CallContext*> calls;
  // Builds async iterators from step functions (MakeAsyncIterator).
  Global<v8::Function> iteratorFactory;
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

// An array, map or tagged enum case a thunk is reporting value by value.
struct ResultFrame {
  bool isMap = false;
  Local<Object> target;
  uint32_t next = 0;
  // Maps alternate key and value reports.
  bool expectKey = true;
  Local<Value> key;
  const ValueCode* element = nullptr;
  // Set for a case: its values' keys and codes.
  const CaseInfo* tagged = nullptr;
  // Set for a tuple: its element codes and labels (an object when labeled).
  const ValueCode* tuple = nullptr;
  // `target` is a JS Set, filled by Add.
  bool isSet = false;
  // An inout argument's reference object, whose `value` receives the one
  // value reported (of code `element`).
  bool writeBack = false;
};

struct SlotArena;

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
  // The first exception a JS callback threw while the thunk ran; it is
  // thrown from the call once the thunk returns.
  Global<Value> callbackException;
  // The arguments' storage, including inout arguments' reference objects.
  const SlotArena* arena = nullptr;
};

CallContext* ContextOf(NSSwiftCall* call) { return static_cast<CallContext*>(call); }

// The code of the value the thunk reports next.
const ValueCode* CurrentCode(CallContext* context) {
  if (context->frames.empty()) {
    return context->resultCode;
  }
  const ResultFrame& frame = context->frames.back();
  if (frame.writeBack) {
    return frame.element;
  }
  if (frame.tagged != nullptr) {
    return frame.next < frame.tagged->codes.size() ? &frame.tagged->codes[frame.next] : nullptr;
  }
  if (frame.tuple != nullptr) {
    return frame.next < frame.tuple->element.size() ? &frame.tuple->element[frame.next] : nullptr;
  }
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
  if (frame.writeBack) {
    stored = frame.target->Set(context->context, tns::ToV8String(context->isolate, "value"), value)
                 .FromMaybe(false);
  } else if (frame.tagged != nullptr) {
    stored = frame.next < frame.tagged->keys.size() &&
             frame.target
                 ->Set(context->context,
                       tns::ToV8String(context->isolate, frame.tagged->keys[frame.next++]), value)
                 .FromMaybe(false);
  } else if (frame.tuple != nullptr && !frame.tuple->labels.empty()) {
    stored = frame.next < frame.tuple->labels.size() &&
             frame.target
                 ->Set(context->context,
                       tns::ToV8String(context->isolate, frame.tuple->labels[frame.next++]), value)
                 .FromMaybe(false);
  } else if (frame.isSet) {
    stored = !frame.target.As<v8::Set>()->Add(context->context, value).IsEmpty();
  } else if (!frame.isMap) {
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

// NativeScript's wrapper of `object`, taking over a +1 reference to it.
MaybeLocal<Value> WrapObjC(Isolate* isolate, Local<Context> context, id object) {
  if (object == nil) {
    return v8::Null(isolate);
  }
  Local<Value> result;
  auto cached = ArgConverter::FindCachedInstance(isolate, Caches::Get(isolate), object);
  if (cached != nullptr) {
    result = cached->Get(isolate);
  } else {
    ObjCDataWrapper* wrapper = new ObjCDataWrapper(object);
    result = ArgConverter::ConvertArgument(context, wrapper);
    tns::DeleteWrapperIfUnused(isolate, result, wrapper);
  }
  [object release];
  return result.IsEmpty() ? MaybeLocal<Value>() : MaybeLocal<Value>(result);
}

// The Objective-C object a NativeScript wrapper holds, or nil.
id ObjCObjectOf(Isolate* isolate, Local<Value> value) {
  if (!value->IsObject()) {
    return nil;
  }
  BaseDataWrapper* wrapper = tns::GetValue(isolate, value);
  return wrapper != nullptr && wrapper->Type() == WrapperType::ObjCObject
             ? static_cast<ObjCDataWrapper*>(wrapper)->Data()
             : nil;
}

bool IsObjCInstance(id object, const ValueCode& code) {
  return object != nil && (code.objcClass == nil || [object isKindOfClass:code.objcClass]);
}

void ApiReturnAsyncSequence(NSSwiftCall* call, void* iterator, NSSwiftThunk next) {
  CallContext* context = ContextOf(call);
  const ValueCode* code = CurrentCode(context);
  Local<Value> value;
  if (code == nullptr || code->kind != ValueCode::Kind::AsyncSequence ||
      !MakeAsyncIterator(context->isolate, context->context, context->module, iterator, next, *code,
                         context->member->swiftName)
           .ToLocal(&value)) {
    if (code == nullptr || code->kind != ValueCode::Kind::AsyncSequence) {
      context->module->release(iterator);
    }
    return Fail(context);
  }
  Complete(context, value);
}

void ApiReturnJSObject(NSSwiftCall* call, void* object) {
  CallContext* context = ContextOf(call);
  Complete(context, JSObjectOf(static_cast<SwiftCallback*>(object), context->isolate));
}

void ApiReturnObjC(NSSwiftCall* call, void* object) {
  CallContext* context = ContextOf(call);
  Local<Value> value;
  if (!WrapObjC(context->isolate, context->context, static_cast<id>(object)).ToLocal(&value)) {
    return Fail(context);
  }
  Complete(context, value);
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
  // An iterator step reports its element as an array, and so do sets and
  // tuples.
  bool arrayLike =
      !isMap && code != nullptr &&
      (code->kind == ValueCode::Kind::AsyncSequence || code->kind == ValueCode::Kind::Set ||
       (code->kind == ValueCode::Kind::Tuple &&
        static_cast<size_t>(count) == code->element.size()));
  if (code == nullptr || (code->kind != expected && !arrayLike) || code->element.empty()) {
    Fail(context);
    context->isolate->ThrowException(Exception::Error(tns::ToV8String(
        context->isolate, context->member->swiftName + " reported an unexpected collection")));
    return;
  }
  ResultFrame frame;
  frame.isMap = isMap;
  frame.isSet = code->kind == ValueCode::Kind::Set;
  if (code->kind == ValueCode::Kind::Tuple) {
    frame.tuple = code;
  }
  frame.target = isMap || (frame.tuple != nullptr && !code->labels.empty())
                     ? Local<Object>(Object::New(context->isolate))
                 : frame.isSet
                     ? Local<Object>(v8::Set::New(context->isolate))
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

// `{ case: name }`, filled in by the case's values.
MaybeLocal<Object> NewCaseObject(Isolate* isolate, Local<Context> context, const CaseInfo& info) {
  Local<Object> object = Object::New(isolate);
  if (!object->Set(context, tns::ToV8String(isolate, "case"), tns::ToV8String(isolate, info.name))
           .FromMaybe(false)) {
    return MaybeLocal<Object>();
  }
  return object;
}

// The case `caseIndex` of the tagged enum `code` names, or null.
const CaseInfo* CaseOf(const ModuleInfo& module, const ValueCode* code, intptr_t caseIndex) {
  if (code == nullptr || code->kind != ValueCode::Kind::Tagged || code->typeIndex < 0 ||
      code->typeIndex >= static_cast<int>(module.types.size())) {
    return nullptr;
  }
  const auto& cases = module.types[code->typeIndex].cases;
  return caseIndex >= 0 && caseIndex < static_cast<intptr_t>(cases.size()) ? &cases[caseIndex]
                                                                           : nullptr;
}

Local<Object> ReferenceAt(const SlotArena* arena, intptr_t index);

void ApiWriteBackBegin(NSSwiftCall* call, intptr_t index) {
  CallContext* context = ContextOf(call);
  const auto& parameters = context->member->signature.parameters;
  Local<Object> reference;
  if (index >= 0 && index < static_cast<intptr_t>(parameters.size()) && parameters[index].inout) {
    reference = ReferenceAt(context->arena, index);
  }
  if (reference.IsEmpty()) {
    Fail(context);
    context->isolate->ThrowException(Exception::Error(tns::ToV8String(
        context->isolate, context->member->swiftName + " reported an unexpected inout value")));
    return;
  }
  ResultFrame frame;
  frame.target = reference;
  frame.element = &parameters[index];
  frame.writeBack = true;
  context->frames.push_back(frame);
}

void ApiWriteBackEnd(NSSwiftCall* call) {
  CallContext* context = ContextOf(call);
  if (context->frames.empty() || !context->frames.back().writeBack) {
    return Fail(context);
  }
  context->frames.pop_back();
}

void ApiReturnCaseBegin(NSSwiftCall* call, intptr_t caseIndex) {
  CallContext* context = ContextOf(call);
  const CaseInfo* info = CaseOf(*context->module, CurrentCode(context), caseIndex);
  ResultFrame frame;
  if (info == nullptr ||
      !NewCaseObject(context->isolate, context->context, *info).ToLocal(&frame.target)) {
    Fail(context);
    context->isolate->ThrowException(Exception::Error(tns::ToV8String(
        context->isolate, context->member->swiftName + " reported an unexpected enum case")));
    return;
  }
  frame.tagged = info;
  context->frames.push_back(frame);
}

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
// maps hold their elements (a map's alternate key and value) as children, a
// tagged enum case its values (with its case index in `int64`).
struct SwiftCallback;
void ReleaseCallback(SwiftCallback* callback);

struct AsyncOutcome {
  enum class Kind {
    Void,
    Bool,
    Int64,
    UInt64,
    Double,
    String,
    Null,
    Object,
    Error,
    Array,
    Map,
    Case,
    ObjC,
    // `object` is a JS object handle the outcome holds a reference to.
    JSObject,
    // `object` is a Swift iterator, stepped by `next`.
    Sequence,
  };
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
  NSSwiftThunk next = nullptr;
  std::vector<std::shared_ptr<AsyncOutcome>> children;

  // An undelivered object (the isolate went away) still owns its retain.
  ~AsyncOutcome() {
    if (object != nullptr && kind == Kind::JSObject) {
      ReleaseCallback(static_cast<SwiftCallback*>(object));
    } else if (object != nullptr) {
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
  // Set for a callback invocation; the token holds a reference.
  struct SwiftCallback* callback = nullptr;
  // An object call (objectCallBegin): the encoded requirement.
  intptr_t requirement = -1;
};

// Converts `node` (of `code`) to JS; on failure sets `rejection` and returns
// false.
bool OutcomeToJS(Isolate* isolate, Local<Context> context, IsolateState* state,
                 const std::string& name, AsyncOutcome& node, const ValueCode& code,
                 Local<Value>& out, Local<Value>& rejection) {
  auto range = [&](const std::string& value) {
    rejection = Exception::RangeError(tns::ToV8String(isolate, RangeMessage(value, name)));
    return false;
  };
  auto failed = [&](const char* what) {
    rejection = Exception::Error(tns::ToV8String(isolate, name + ": " + what));
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
      Local<Object> wrapper =
          WrapSwiftObject(isolate, context, node.module,
                          loaded == state->byInfo.end() ? nullptr : loaded->second.get(), state,
                          object, node.typeIndex, nullptr);
      if (wrapper.IsEmpty()) {
        return failed("returned an object JavaScript cannot wrap");
      }
      out = wrapper;
      return true;
    }
    case AsyncOutcome::Kind::JSObject:
      out = JSObjectOf(static_cast<SwiftCallback*>(node.object), isolate);
      return true;
    case AsyncOutcome::Kind::Sequence: {
      if (code.kind != ValueCode::Kind::AsyncSequence) {
        return failed("returned an unexpected sequence");
      }
      void* iterator = node.object;
      node.object = nullptr;
      return MakeAsyncIterator(isolate, context, node.module, iterator, node.next, code, name)
                 .ToLocal(&out) ||
             failed("returned a sequence JavaScript cannot iterate");
    }
    case AsyncOutcome::Kind::ObjC: {
      id object = static_cast<id>(node.object);
      node.object = nullptr;
      return WrapObjC(isolate, context, object).ToLocal(&out) ||
             failed("returned an object JavaScript cannot wrap");
    }
    case AsyncOutcome::Kind::Array: {
      if (code.element.empty()) {
        return failed("returned an unexpected array");
      }
      if (code.kind == ValueCode::Kind::Tuple) {
        if (node.children.size() != code.element.size()) {
          return failed("returned an unexpected tuple");
        }
        bool labeled = !code.labels.empty();
        Local<Object> tuple =
            labeled ? Object::New(isolate)
                    : v8::Array::New(isolate, static_cast<int>(code.element.size())).As<Object>();
        for (uint32_t i = 0; i < code.element.size(); i++) {
          Local<Value> element;
          Local<Value> key = labeled ? tns::ToV8String(isolate, code.labels[i]).As<Value>()
                                     : v8::Integer::New(isolate, i).As<Value>();
          if (!OutcomeToJS(isolate, context, state, name, *node.children[i], code.element[i],
                           element, rejection) ||
              !tuple->Set(context, key, element).FromMaybe(false)) {
            return false;
          }
        }
        out = tuple;
        return true;
      }
      if (code.kind == ValueCode::Kind::Set) {
        Local<v8::Set> set = v8::Set::New(isolate);
        for (const auto& child : node.children) {
          Local<Value> element;
          if (!OutcomeToJS(isolate, context, state, name, *child, code.element[0], element,
                           rejection) ||
              set->Add(context, element).IsEmpty()) {
            return false;
          }
        }
        out = set;
        return true;
      }
      Local<v8::Array> array = v8::Array::New(isolate, static_cast<int>(node.children.size()));
      for (uint32_t i = 0; i < node.children.size(); i++) {
        Local<Value> element;
        if (!OutcomeToJS(isolate, context, state, name, *node.children[i], code.element[0], element,
                         rejection) ||
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
        if (!OutcomeToJS(isolate, context, state, name, *node.children[i], KeyCode(), key,
                         rejection) ||
            !OutcomeToJS(isolate, context, state, name, *node.children[i + 1], code.element[0],
                         value, rejection) ||
            !object->Set(context, key, value).FromMaybe(false)) {
          return false;
        }
      }
      out = object;
      return true;
    }
    case AsyncOutcome::Kind::Case: {
      const CaseInfo* info = CaseOf(*node.module, &code, node.int64);
      Local<Object> object;
      if (info == nullptr || node.children.size() != info->codes.size() ||
          !NewCaseObject(isolate, context, *info).ToLocal(&object)) {
        return failed("returned an unexpected enum case");
      }
      for (size_t i = 0; i < node.children.size(); i++) {
        Local<Value> value;
        if (!OutcomeToJS(isolate, context, state, name, *node.children[i], info->codes[i], value,
                         rejection) ||
            !object->Set(context, tns::ToV8String(isolate, info->keys[i]), value)
                 .FromMaybe(false)) {
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
  if (OutcomeToJS(isolate, context, state, pending->name, outcome, pending->code, value,
                  rejection)) {
    resolver->Resolve(context, value).Check();
  } else {
    resolver->Reject(context, rejection).Check();
  }
}

// --- Callbacks ---------------------------------------------------------------------

// A JS function passed for a closure parameter, or a JS object passed for a
// protocol value (`code` says which). The call's arena holds one reference,
// each Swift closure or adapter holding it another, and each invocation in
// flight one more. `target` is only touched on the isolate's thread.
struct SwiftCallback {
  SwiftCallback(Isolate* isolate, const ModuleInfo* module, const ValueCode& code,
                const std::string& name, Local<Object> target)
      : isolate(isolate),
        wrapper(isolate),
        module(module),
        code(code),
        name(name),
        target(isolate, target) {}

  Isolate* isolate;
  IsolateWrapper wrapper;
  const ModuleInfo* module;
  ValueCode code;
  std::string name;
  Global<Object> target;
  std::atomic<int> references{1};
};

Local<Value> JSObjectOf(SwiftCallback* handle, Isolate* isolate) {
  return handle->target.Get(isolate);
}

// Runs `body` on the isolate's thread with the isolate locked and valid:
// now when called there, otherwise queued. Returns false when it will not run.
bool OnIsolateThread(Isolate* isolate, IsolateWrapper wrapper, std::function<void()> body) {
  if (Isolate::TryGetCurrent() == isolate) {
    v8::Locker locker(isolate);
    if (!wrapper.IsValid()) {
      return false;
    }
    body();
    return true;
  }
  NativeScriptPlatform* platform = NativeScriptPlatform::Instance();
  std::shared_ptr<EventLoop> loop =
      platform ? platform->LookupEventLoop(isolate) : std::shared_ptr<EventLoop>();
  return loop && loop->PostInternal([wrapper, body = std::move(body)]() {
    if (wrapper.IsValid()) {
      body();
    }
  });
}

void ReleaseCallback(SwiftCallback* callback) {
  if (callback->references.fetch_sub(1, std::memory_order_acq_rel) != 1) {
    return;
  }
  // When it cannot run (the isolate is gone) the callback is leaked: its
  // handle can no longer be reset.
  OnIsolateThread(callback->isolate, callback->wrapper, [callback]() { delete callback; });
}

void RunCallback(SwiftCallback* callback, AsyncOutcome& arguments) {
  Isolate* isolate = callback->isolate;
  Isolate::Scope isolateScope(isolate);
  HandleScope handleScope(isolate);
  auto* state = Caches::StateFor<IsolateState>(isolate);
  if (state == nullptr) {
    return;
  }
  Local<Context> context = Caches::Get(isolate)->GetContext();
  Context::Scope contextScope(context);

  // On the isolate's thread the innermost call in progress is the one whose
  // thunk invoked the closure; after its callback threw, the rest are
  // skipped.
  CallContext* call = state->calls.empty() ? nullptr : state->calls.back();
  if (call != nullptr && !call->callbackException.IsEmpty()) {
    return;
  }

  TryCatch tryCatch(isolate);
  Local<Value> exception;
  const std::vector<ValueCode>& parameters = callback->code.element;
  std::vector<Local<Value>> argv;
  if (arguments.children.size() != parameters.size()) {
    exception = Exception::Error(
        tns::ToV8String(isolate, callback->name + ": a closure reported " +
                                     std::to_string(arguments.children.size()) +
                                     " arguments, expected " + std::to_string(parameters.size())));
  }
  for (size_t i = 0; exception.IsEmpty() && i < parameters.size(); i++) {
    Local<Value> value;
    if (!OutcomeToJS(isolate, context, state, callback->name, *arguments.children[i], parameters[i],
                     value, exception)) {
      break;
    }
    argv.push_back(value);
  }
  if (exception.IsEmpty()) {
    Local<Value> ignored;
    if (callback->target.Get(isolate)
            .As<v8::Function>()
            ->Call(context, v8::Undefined(isolate), static_cast<int>(argv.size()), argv.data())
            .ToLocal(&ignored) ||
        !tryCatch.HasCaught() || !tryCatch.CanContinue()) {
      return;
    }
    exception = tryCatch.Exception();
  }
  if (call != nullptr) {
    call->callbackException.Reset(isolate, exception);
  } else {
    NativeScriptException::ReportToJsHandlersAndLog(isolate, exception, tryCatch.Message());
  }
}

void DeliverCallback(std::unique_ptr<AsyncToken> token) {
  SwiftCallback* callback = token->callback;
  std::shared_ptr<AsyncOutcome> arguments = token->root;
  bool scheduled = OnIsolateThread(callback->isolate, callback->wrapper, [callback, arguments]() {
    RunCallback(callback, *arguments);
    ReleaseCallback(callback);
  });
  if (!scheduled) {
    ReleaseCallback(callback);
  }
}

// Consumes `token`. Safe on any thread.
void Deliver(AsyncToken* rawToken) {
  std::unique_ptr<AsyncToken> token(rawToken);
  if (token->callback != nullptr) {
    return DeliverCallback(std::move(token));
  }
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
  bool opens = node->kind == AsyncOutcome::Kind::Array || node->kind == AsyncOutcome::Kind::Map ||
               node->kind == AsyncOutcome::Kind::Case;
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
    pending->code = *context->resultCode;
    pending->name = context->member->swiftName;
    context->state->pending.emplace(id, std::move(pending));
    Complete(context, resolver->GetPromise());
  } else {
    // The token is still completed later; it then finds no pending entry.
    Fail(context);
  }
  return new AsyncToken{isolate, IsolateWrapper(isolate), id, context->module, nullptr, {}};
}

void* ApiCallbackBegin(void* rawCallback) {
  auto* callback = static_cast<SwiftCallback*>(rawCallback);
  callback->references.fetch_add(1, std::memory_order_relaxed);
  auto* token = new AsyncToken{callback->isolate,
                               callback->wrapper,
                               0,
                               callback->module,
                               Outcome(AsyncOutcome::Kind::Array),
                               {}};
  token->root->module = callback->module;
  token->open.push_back(token->root.get());
  token->callback = callback;
  return token;
}

void ApiCallbackRetain(void* callback) {
  static_cast<SwiftCallback*>(callback)->references.fetch_add(1, std::memory_order_relaxed);
}

void ApiCallbackRelease(void* callback) { ReleaseCallback(static_cast<SwiftCallback*>(callback)); }

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

void ApiCompleteAsyncSequence(void* token, void* iterator, NSSwiftThunk next) {
  auto outcome = Outcome(AsyncOutcome::Kind::Sequence);
  outcome->object = iterator;
  outcome->next = next;
  Emit(token, outcome);
}

void ApiCompleteJSObject(void* token, void* object) {
  auto outcome = Outcome(AsyncOutcome::Kind::JSObject);
  ApiCallbackRetain(object);
  outcome->object = object;
  Emit(token, outcome);
}

void* ApiObjectCallBegin(void* object, intptr_t index) {
  auto* token = static_cast<AsyncToken*>(ApiCallbackBegin(object));
  token->requirement = index;
  return token;
}

void ApiCompleteObjC(void* token, void* object) {
  auto outcome = Outcome(AsyncOutcome::Kind::ObjC);
  outcome->object = object;
  Emit(token, outcome);
}

void ApiCompleteCaseBegin(void* token, intptr_t caseIndex) {
  auto outcome = Outcome(AsyncOutcome::Kind::Case);
  outcome->int64 = caseIndex;
  Emit(token, outcome);
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

// An object JS code builds as a record: maps and tagged enum cases.
bool IsRecord(Isolate* isolate, Local<Value> value) {
  return IsPlainObject(isolate, value) && !value->IsDate() && !value->IsArrayBuffer() &&
         !value->IsArrayBufferView();
}

// Whether `value` can be passed as `code` (overload resolution; no throws, no
// user code). Collections are checked by kind only; Convert checks elements.
bool Accepts(Isolate* isolate, const ModuleInfo& module, const ValueCode& code,
             Local<Value> value) {
  if (code.inout) {
    return IsRecord(isolate, value);
  }
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
    case ValueCode::Kind::Set:
      return value->IsSet() || value->IsArray();
    case ValueCode::Kind::Tuple:
      return code.labels.empty()
                 ? value->IsArray() && value.As<v8::Array>()->Length() == code.element.size()
                 : IsRecord(isolate, value);
    case ValueCode::Kind::Map:
    case ValueCode::Kind::Tagged:
      return IsRecord(isolate, value);
    case ValueCode::Kind::Object: {
      SwiftObjectWrapper* wrapper = SwiftWrapperOf(isolate, value);
      return wrapper && wrapper->Module() == &module &&
             module.IsA(wrapper->TypeIndex(), code.typeIndex);
    }
    case ValueCode::Kind::Function:
      return value->IsFunction();
    case ValueCode::Kind::ObjC:
      return IsObjCInstance(ObjCObjectOf(isolate, value), code);
    case ValueCode::Kind::Protocol: {
      // A Swift value is checked by the thunk.
      SwiftObjectWrapper* wrapper = SwiftWrapperOf(isolate, value);
      return wrapper
                 ? wrapper->Module() == &module
                 : value->IsObject() && !value->IsArray() && ObjCObjectOf(isolate, value) == nil;
    }
    case ValueCode::Kind::AsyncSequence:
    case ValueCode::Kind::Void:
      return false;
  }
  return false;
}

// The index Convert is given for a JS implementation's return value.
constexpr size_t kReturnedValue = static_cast<size_t>(-1);

bool ThrowArgument(Isolate* isolate, const MemberInfo& member, size_t index,
                   const std::string& problem, bool range = false) {
  std::string message = member.swiftName + ": " +
                        (index == kReturnedValue ? std::string("the value returned")
                                                 : "argument " + std::to_string(index + 1)) +
                        " " + problem;
  Local<v8::String> text = tns::ToV8String(isolate, message);
  isolate->ThrowException(range ? Exception::RangeError(text) : Exception::TypeError(text));
  return false;
}

// Storage the slots of one call point into. Deques keep every buffer at a
// fixed address while more are added.
struct SlotArena {
  std::deque<std::string> strings;
  std::deque<std::vector<NSSwiftValue>> slots;
  std::vector<SwiftCallback*> callbacks;
  // By parameter index; empty except for inout arguments.
  std::vector<Local<Object>> references;

  SlotArena() = default;
  SlotArena(const SlotArena&) = delete;
  SlotArena& operator=(const SlotArena&) = delete;
  ~SlotArena() {
    for (SwiftCallback* callback : callbacks) {
      ReleaseCallback(callback);
    }
  }
};

Local<Object> ReferenceAt(const SlotArena* arena, intptr_t index) {
  return arena != nullptr && index < static_cast<intptr_t>(arena->references.size())
             ? arena->references[index]
             : Local<Object>();
}

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
  if (code.inout) {
    ValueCode inner = code;
    inner.inout = false;
    if (!IsRecord(isolate, value)) {
      return ThrowArgument(
          isolate, member, index,
          "is inout: pass a reference object, { value: " + TypeDisplayName(module, inner) + " }");
    }
    Local<Value> current;
    if (!value.As<Object>()->Get(context, tns::ToV8String(isolate, "value")).ToLocal(&current)) {
      return false;
    }
    if (arena.references.size() <= index) {
      arena.references.resize(index + 1);
    }
    arena.references[index] = value.As<Object>();
    return Convert(isolate, context, module, member, index, inner, current, slot, arena);
  }
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

    case ValueCode::Kind::Tuple: {
      size_t count = code.element.size();
      bool labeled = !code.labels.empty();
      if (!Accepts(isolate, module, code, value)) {
        return ThrowArgument(isolate, member, index,
                             labeled ? "must be an object, " + TypeDisplayName(module, code)
                                     : "must be an array of " + std::to_string(count) +
                                           " values, " + TypeDisplayName(module, code));
      }
      arena.slots.emplace_back(count);
      std::vector<NSSwiftValue>& elements = arena.slots.back();
      for (size_t i = 0; i < count; i++) {
        Local<Value> element;
        bool read =
            labeled
                ? value.As<Object>()
                      ->Get(context, tns::ToV8String(isolate, code.labels[i]))
                      .ToLocal(&element)
                : value.As<v8::Array>()->Get(context, static_cast<uint32_t>(i)).ToLocal(&element);
        if (!read || !Convert(isolate, context, module, member, index, code.element[i], element,
                              elements[i], arena)) {
          return false;
        }
      }
      slot.tag = NSSwiftTagArray;
      slot.payload.object = elements.data();
      slot.length = count;
      return true;
    }

    case ValueCode::Kind::Set:
    case ValueCode::Kind::Array: {
      if (code.kind == ValueCode::Kind::Set && value->IsSet()) {
        value = value.As<v8::Set>()->AsArray();
      }
      if (!value->IsArray()) {
        return ThrowArgument(
            isolate, member, index,
            code.kind == ValueCode::Kind::Set ? "must be a Set or an array" : "must be an array");
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

    case ValueCode::Kind::Tagged: {
      const TypeInfo& type = module.types[code.typeIndex];
      std::string expected = "must be a case of " + type.jsName + " ({ case: \"...\" })";
      if (!IsRecord(isolate, value)) {
        return ThrowArgument(isolate, member, index, expected);
      }
      Local<Value> name;
      if (!value.As<Object>()->Get(context, tns::ToV8String(isolate, "case")).ToLocal(&name)) {
        return false;
      }
      std::string caseName = name->IsString() ? tns::ToString(isolate, name) : "";
      size_t caseIndex = 0;
      while (caseIndex < type.cases.size() && type.cases[caseIndex].name != caseName) {
        caseIndex++;
      }
      if (caseIndex == type.cases.size()) {
        return ThrowArgument(isolate, member, index, expected);
      }
      const CaseInfo& info = type.cases[caseIndex];
      arena.slots.emplace_back(1 + info.codes.size());
      std::vector<NSSwiftValue>& values = arena.slots.back();
      values[0].tag = NSSwiftTagInt64;
      values[0].payload.int64 = static_cast<int64_t>(caseIndex);
      for (size_t i = 0; i < info.codes.size(); i++) {
        Local<Value> entry;
        if (!value.As<Object>()
                 ->Get(context, tns::ToV8String(isolate, info.keys[i]))
                 .ToLocal(&entry) ||
            !Convert(isolate, context, module, member, index, info.codes[i], entry, values[1 + i],
                     arena)) {
          return false;
        }
      }
      slot.tag = NSSwiftTagCase;
      slot.payload.object = values.data();
      slot.length = values.size();
      return true;
    }

    case ValueCode::Kind::Protocol: {
      const TypeInfo& protocol = module.types[code.typeIndex];
      if (SwiftObjectWrapper* wrapper = SwiftWrapperOf(isolate, value)) {
        if (wrapper->Module() != &module) {
          return ThrowArgument(isolate, member, index, "must be a " + protocol.jsName);
        }
        slot.tag = NSSwiftTagObject;
        slot.payload.object = wrapper->Object();
        return true;
      }
      if (!value->IsObject() || value->IsArray() || ObjCObjectOf(isolate, value) != nil) {
        return ThrowArgument(isolate, member, index,
                             "must be a " + protocol.jsName + " or an object implementing it");
      }
      // A JS implementation must provide every requirement.
      Local<Object> object = value.As<Object>();
      std::string missing;
      for (const MemberInfo* requirement : protocol.requirements) {
        Local<v8::String> key = tns::ToV8String(isolate, requirement->jsName);
        Local<Value> found;
        bool present = requirement->kind == NSSwiftMemberInstanceProperty
                           ? object->Has(context, key).FromMaybe(false)
                           : object->Get(context, key).ToLocal(&found) && found->IsFunction();
        if (!present) {
          missing += (missing.empty() ? "" : ", ") + requirement->jsName;
        }
      }
      if (!missing.empty()) {
        return ThrowArgument(
            isolate, member, index,
            "does not implement " + protocol.jsName + " (missing " + missing + ")");
      }
      auto* handle = new SwiftCallback(isolate, &module, code, member.swiftName, object);
      arena.callbacks.push_back(handle);
      slot.tag = NSSwiftTagJSObject;
      slot.payload.object = handle;
      return true;
    }

    case ValueCode::Kind::ObjC: {
      id object = ObjCObjectOf(isolate, value);
      if (!IsObjCInstance(object, code)) {
        return ThrowArgument(isolate, member, index, "must be a " + code.className);
      }
      slot.tag = NSSwiftTagObjC;
      slot.payload.object = object;
      return true;
    }

    case ValueCode::Kind::Function: {
      if (!value->IsFunction()) {
        return ThrowArgument(isolate, member, index, "must be a function");
      }
      auto* callback =
          new SwiftCallback(isolate, &module, code, member.swiftName, value.As<Object>());
      arena.callbacks.push_back(callback);
      slot.tag = NSSwiftTagFunction;
      slot.payload.object = callback;
      return true;
    }

    case ValueCode::Kind::AsyncSequence:
    case ValueCode::Kind::Void:
      break;
  }
  return ThrowArgument(isolate, member, index, "has an unsupported type");
}

// --- Calls into JS implementations of protocols -------------------------------------

// A JS implementation's return value as one slot, with the storage it
// points into.
struct ObjectResult {
  NSSwiftValue value{};
  SlotArena arena;
};

// Runs requirement `encoded` of `handle` with `arguments`, on the isolate's
// thread; null when it threw or its value does not convert.
ObjectResult* RunObjectCall(SwiftCallback* handle, AsyncOutcome& arguments, intptr_t encoded) {
  Isolate* isolate = handle->isolate;
  Isolate::Scope isolateScope(isolate);
  HandleScope handleScope(isolate);
  auto* state = Caches::StateFor<IsolateState>(isolate);
  if (state == nullptr) {
    return nullptr;
  }
  Local<Context> context = Caches::Get(isolate)->GetContext();
  Context::Scope contextScope(context);

  const ModuleInfo& module = *handle->module;
  const TypeInfo& protocol = module.types[handle->code.typeIndex];
  size_t position = static_cast<size_t>(encoded / 2);
  bool setter = encoded % 2 == 1;
  if (encoded < 0 || position >= protocol.requirements.size()) {
    return nullptr;
  }
  const MemberInfo& member = *protocol.requirements[position];
  bool property = member.kind == NSSwiftMemberInstanceProperty;

  // The innermost call in progress on this thread made this one.
  CallContext* call = state->calls.empty() ? nullptr : state->calls.back();
  if (call != nullptr && !call->callbackException.IsEmpty()) {
    return nullptr;
  }

  TryCatch tryCatch(isolate);
  Local<Value> exception;
  std::vector<ValueCode> codes;
  if (!property) {
    codes = member.signature.parameters;
  } else if (setter) {
    codes.push_back(member.signature.result);
  }
  std::vector<Local<Value>> argv;
  for (size_t i = 0; i < codes.size() && i < arguments.children.size(); i++) {
    Local<Value> value;
    if (!OutcomeToJS(isolate, context, state, member.swiftName, *arguments.children[i], codes[i],
                     value, exception)) {
      break;
    }
    argv.push_back(value);
  }

  auto result = std::make_unique<ObjectResult>();
  Local<Object> target = handle->target.Get(isolate);
  Local<v8::String> key = tns::ToV8String(isolate, member.jsName);
  bool done = false;
  if (exception.IsEmpty()) {
    Local<Value> returned;
    if (property && setter) {
      done =
          target->Set(context, key, argv.empty() ? Local<Value>(v8::Undefined(isolate)) : argv[0])
              .FromMaybe(false);
      result->value.tag = NSSwiftTagNull;
    } else if (property) {
      done = target->Get(context, key).ToLocal(&returned);
    } else {
      Local<Value> function;
      if (target->Get(context, key).ToLocal(&function)) {
        if (function->IsFunction()) {
          done = function.As<v8::Function>()
                     ->Call(context, target, static_cast<int>(argv.size()), argv.data())
                     .ToLocal(&returned);
        } else {
          exception = Exception::TypeError(tns::ToV8String(
              isolate, protocol.jsName + "." + member.jsName + " is not a function"));
        }
      }
    }
    if (done && !(property && setter)) {
      if (member.signature.result.kind == ValueCode::Kind::Void) {
        result->value.tag = NSSwiftTagNull;
      } else {
        done = Convert(isolate, context, module, member, kReturnedValue, member.signature.result,
                       returned, result->value, result->arena);
      }
    }
  }
  if (done) {
    return result.release();
  }
  if (exception.IsEmpty()) {
    if (!tryCatch.HasCaught() || !tryCatch.CanContinue()) {
      return nullptr;
    }
    exception = tryCatch.Exception();
  }
  if (call != nullptr) {
    call->callbackException.Reset(isolate, exception);
  } else {
    NativeScriptException::ReportToJsHandlersAndLog(isolate, exception, tryCatch.Message());
  }
  return nullptr;
}

// Runs `run` on `handle`'s isolate thread, waiting for it from any other
// thread; null when it fails or cannot run.
ObjectResult* RunAndWait(SwiftCallback* handle, std::function<ObjectResult*()> run) {
  if (Isolate::TryGetCurrent() == handle->isolate) {
    v8::Locker locker(handle->isolate);
    return handle->wrapper.IsValid() ? run() : nullptr;
  }
  // The guard ends the wait when the loop drops the task without running it.
  struct Wait {
    std::mutex mutex;
    std::condition_variable condition;
    bool done = false;
    ObjectResult* result = nullptr;
    void Finish(ObjectResult* value) {
      std::lock_guard<std::mutex> lock(mutex);
      if (!done) {
        done = true;
        result = value;
      } else {
        delete value;
      }
      condition.notify_all();
    }
  };
  struct Guard {
    std::shared_ptr<Wait> wait;
    ~Guard() { wait->Finish(nullptr); }
  };
  auto wait = std::make_shared<Wait>();
  std::shared_ptr<Guard> guard(new Guard{wait});
  NativeScriptPlatform* platform = NativeScriptPlatform::Instance();
  std::shared_ptr<EventLoop> loop =
      platform ? platform->LookupEventLoop(handle->isolate) : std::shared_ptr<EventLoop>();
  IsolateWrapper isolateWrapper = handle->wrapper;
  bool posted = loop && loop->PostInternal([guard, run, isolateWrapper]() {
    guard->wait->Finish(isolateWrapper.IsValid() ? run() : nullptr);
  });
  guard.reset();
  if (!posted) {
    return nullptr;
  }
  std::unique_lock<std::mutex> lock(wait->mutex);
  wait->condition.wait(lock, [&] { return wait->done; });
  return wait->result;
}

const NSSwiftValue* ApiObjectCallEnd(void* rawToken) {
  std::unique_ptr<AsyncToken> token(static_cast<AsyncToken*>(rawToken));
  SwiftCallback* handle = token->callback;
  std::shared_ptr<AsyncOutcome> arguments = token->root;
  intptr_t encoded = token->requirement;
  ObjectResult* result = RunAndWait(handle, [handle, arguments, encoded]() {
    return RunObjectCall(handle, *arguments, encoded);
  });
  ReleaseCallback(handle);
  return result ? &result->value : nullptr;
}

// Calls the JS function `handle` holds with `arguments` and converts what it
// returns; null when it threw or returned a value that does not convert.
ObjectResult* RunFunctionCall(SwiftCallback* handle, AsyncOutcome& arguments) {
  Isolate* isolate = handle->isolate;
  Isolate::Scope isolateScope(isolate);
  HandleScope handleScope(isolate);
  auto* state = Caches::StateFor<IsolateState>(isolate);
  if (state == nullptr) {
    return nullptr;
  }
  Local<Context> context = Caches::Get(isolate)->GetContext();
  Context::Scope contextScope(context);
  CallContext* call = state->calls.empty() ? nullptr : state->calls.back();
  if (call != nullptr && !call->callbackException.IsEmpty()) {
    return nullptr;
  }

  TryCatch tryCatch(isolate);
  Local<Value> exception;
  const ValueCode& code = handle->code;
  std::vector<Local<Value>> argv;
  for (size_t i = 0; i < code.element.size() && i < arguments.children.size(); i++) {
    Local<Value> value;
    if (!OutcomeToJS(isolate, context, state, handle->name, *arguments.children[i], code.element[i],
                     value, exception)) {
      break;
    }
    argv.push_back(value);
  }
  auto result = std::make_unique<ObjectResult>();
  bool done = false;
  if (exception.IsEmpty()) {
    Local<Value> returned;
    done = handle->target.Get(isolate)
               .As<v8::Function>()
               ->Call(context, v8::Undefined(isolate), static_cast<int>(argv.size()), argv.data())
               .ToLocal(&returned);
    if (done && code.returns.empty()) {
      result->value.tag = NSSwiftTagNull;
    } else if (done) {
      MemberInfo member;
      member.swiftName = handle->name + " (closure)";
      done = Convert(isolate, context, *handle->module, member, kReturnedValue, code.returns[0],
                     returned, result->value, result->arena);
    }
  }
  if (done) {
    return result.release();
  }
  if (exception.IsEmpty()) {
    if (!tryCatch.HasCaught() || !tryCatch.CanContinue()) {
      return nullptr;
    }
    exception = tryCatch.Exception();
  }
  if (call != nullptr) {
    call->callbackException.Reset(isolate, exception);
  } else {
    NativeScriptException::ReportToJsHandlersAndLog(isolate, exception, tryCatch.Message());
  }
  return nullptr;
}

const NSSwiftValue* ApiCallbackCallEnd(void* rawToken) {
  std::unique_ptr<AsyncToken> token(static_cast<AsyncToken*>(rawToken));
  SwiftCallback* handle = token->callback;
  std::shared_ptr<AsyncOutcome> arguments = token->root;
  ObjectResult* result =
      RunAndWait(handle, [handle, arguments]() { return RunFunctionCall(handle, *arguments); });
  ReleaseCallback(handle);
  return result ? &result->value : nullptr;
}

void ApiObjectResultRelease(const NSSwiftValue* value) {
  delete reinterpret_cast<ObjectResult*>(const_cast<NSSwiftValue*>(value));
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

  if (matches.size() > 1) {
    // Overloads taking arrays of different element types (a generic
    // function's instantiations): the first elements decide.
    std::vector<const MemberInfo*> preferred;
    for (const MemberInfo* member : matches) {
      bool accepts = true;
      for (size_t i = 0; accepts && i < arguments.size(); i++) {
        const ValueCode& code = member->signature.parameters[i];
        Local<Value> first;
        accepts = code.kind != ValueCode::Kind::Array || code.inout || !arguments[i]->IsArray() ||
                  arguments[i].As<v8::Array>()->Length() == 0 ||
                  (arguments[i].As<v8::Array>()->Get(context, 0).ToLocal(&first) &&
                   Accepts(isolate, module, code.element[0], first));
      }
      if (accepts) {
        preferred.push_back(member);
      }
    }
    if (preferred.size() < 2) {
      matches = std::move(preferred);
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

LoadedModule* LoadedFor(Isolate* isolate, const ModuleInfo* module);
Local<External> DataFor(Isolate* isolate, const void* pointer);

// A Swift iterator owned by the step function JS calls; released when that
// function is collected.
struct IteratorBox {
  Global<v8::Function> step;
  const ModuleInfo* module;
  void* iterator;
  NSSwiftThunk next;
  // Names the steps in errors; its result is the sequence's code.
  MemberInfo member;
};

void StepCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  auto* box = static_cast<IteratorBox*>(
      info.Data().As<External>()->Value(v8::kExternalPointerTypeTagDefault));
  auto* state = Caches::StateFor<IsolateState>(isolate);
  LoadedModule* loaded = LoadedFor(isolate, box->module);
  if (state == nullptr || loaded == nullptr) {
    return;
  }
  NSSwiftValue slot{};
  slot.tag = NSSwiftTagObject;
  slot.payload.object = box->iterator;

  CallContext call;
  call.api = &kAPI;
  call.isolate = isolate;
  call.context = isolate->GetCurrentContext();
  call.module = box->module;
  call.loaded = loaded;
  call.state = state;
  call.member = &box->member;
  call.resultCode = &box->member.signature.result;
  state->calls.push_back(&call);
  box->next(&call, &slot, 1);
  state->calls.pop_back();
  if (!call.callbackException.IsEmpty()) {
    isolate->ThrowException(call.callbackException.Get(isolate));
  } else if (!call.threw && call.completed) {
    info.GetReturnValue().Set(call.result);
  }
}

// Turns a step function (a Promise of `[element]`, or `[]` at the end) into
// an async iterator, one step at a time.
constexpr const char* kIteratorFactory = R"js((function (step) {
  let pending = Promise.resolve();
  return {
    next() {
      const result = pending.then(() => step()).then((values) =>
        values.length ? { value: values[0], done: false } : { value: undefined, done: true });
      pending = result.then(() => undefined, () => undefined);
      return result;
    },
    [Symbol.asyncIterator]() {
      return this;
    },
  };
}))js";

MaybeLocal<Value> MakeAsyncIterator(Isolate* isolate, Local<Context> context,
                                    const ModuleInfo* module, void* iterator, NSSwiftThunk next,
                                    const ValueCode& code, const std::string& name) {
  auto* state = Caches::StateFor<IsolateState>(isolate);
  if (state == nullptr) {
    module->release(iterator);
    return MaybeLocal<Value>();
  }
  if (state->iteratorFactory.IsEmpty()) {
    Local<Script> script;
    Local<Value> factory;
    if (!Script::Compile(context, tns::ToV8String(isolate, kIteratorFactory)).ToLocal(&script) ||
        !script->Run(context).ToLocal(&factory) || !factory->IsFunction()) {
      module->release(iterator);
      return MaybeLocal<Value>();
    }
    state->iteratorFactory.Reset(isolate, factory.As<v8::Function>());
  }

  auto* box = new IteratorBox{{}, module, iterator, next, MemberInfo()};
  box->member.swiftName = name + " (iterator)";
  box->member.signature.result = code;
  Local<v8::Function> step;
  if (!v8::Function::New(context, StepCallback, DataFor(isolate, box)).ToLocal(&step)) {
    module->release(iterator);
    delete box;
    return MaybeLocal<Value>();
  }
  box->step.Reset(isolate, step);
  box->step.SetWeak(
      box,
      [](const WeakCallbackInfo<IteratorBox>& info) {
        IteratorBox* collected = info.GetParameter();
        collected->step.Reset();
        collected->module->release(collected->iterator);
        delete collected;
      },
      WeakCallbackType::kParameter);
  Local<Value> argv[] = {step};
  return state->iteratorFactory.Get(isolate)->Call(context, v8::Undefined(isolate), 1, argv);
}

LoadedModule* LoadedFor(Isolate* isolate, const ModuleInfo* module) {
  auto* state = Caches::StateFor<IsolateState>(isolate);
  if (state == nullptr) {
    return nullptr;
  }
  auto it = state->byInfo.find(module);
  return it == state->byInfo.end() ? nullptr : it->second.get();
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
    if (IsEnumKind(owner.kind)) {
      ValueCode code;
      code.kind = owner.kind == NSSwiftTypeEnum ? ValueCode::Kind::Enum : ValueCode::Kind::Tagged;
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

  call.arena = &arena;

  NSSwiftThunk thunk = setter ? member.setter : member.thunk;
  state->calls.push_back(&call);
  thunk(&call, slots.empty() ? nullptr : slots.data(), static_cast<intptr_t>(slots.size()));
  state->calls.pop_back();

  // A JS exception thrown while the thunk ran caused whatever error the
  // thunk reported, so it is the one JS sees.
  if (!call.callbackException.IsEmpty()) {
    isolate->ThrowException(call.callbackException.Get(isolate));
    return MaybeLocal<Value>();
  }
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
         IsEnumKind(group.module->types[group.owner].kind);
}

// Methods, functions, and enum instance members (whose receiver, a case
// name, is the first argument).
// A family's group holds every instantiation's overloads; an instance call
// can only reach those of the receiver's own type. Returns `group` itself
// unless it filtered into `storage`.
const MemberGroup& ForReceiver(Isolate* isolate, const MemberGroup& group, Local<Value> receiver,
                               MemberGroup& storage) {
  if (!group.mixedOwners || receiver.IsEmpty()) {
    return group;
  }
  SwiftObjectWrapper* wrapper = SwiftWrapperOf(isolate, receiver);
  if (wrapper == nullptr || wrapper->Module() != group.module) {
    return group;
  }
  storage = group;
  storage.overloads.clear();
  for (const MemberInfo* member : group.overloads) {
    if (group.module->IsA(wrapper->TypeIndex(), member->owner)) {
      storage.overloads.push_back(member);
    }
  }
  return storage.overloads.empty() ? group : storage;
}

void MethodCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  const MemberGroup& all = *GroupOf(info);
  Local<Value> receiver;
  int first = 0;
  if (ReceiverIsEnumArgument(all)) {
    if (info.Length() < 1) {
      isolate->ThrowException(Exception::TypeError(
          tns::ToV8String(isolate, all.jsName + " needs a " + all.module->types[all.owner].jsName +
                                       " case name as its first argument")));
      return;
    }
    receiver = info[0];
    first = 1;
  } else if (IsInstanceKind(all.kind)) {
    receiver = info.This();
  }
  MemberGroup storage;
  const MemberGroup& group = ForReceiver(isolate, all, receiver, storage);

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
  const MemberGroup& all = *GroupOf(info);
  Local<Value> receiver = IsInstanceKind(all.kind) ? Local<Value>(info.This()) : Local<Value>();
  MemberGroup storage;
  const MemberGroup& group = ForReceiver(isolate, all, receiver, storage);
  Local<Value> result;
  if (Invoke(isolate, group, *group.overloads[0], receiver, {}, false, Local<Object>())
          .ToLocal(&result)) {
    info.GetReturnValue().Set(result);
  }
}

void SetterCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  const MemberGroup& all = *GroupOf(info);
  Local<Value> receiver = IsInstanceKind(all.kind) ? Local<Value>(info.This()) : Local<Value>();
  MemberGroup storage;
  const MemberGroup& group = ForReceiver(isolate, all, receiver, storage);
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

  // Fills the unit's templates and every module's namespace.
  bool Build() {
    std::map<std::string, Local<Object>> exports;
    for (const auto& name : _module.modules) {
      exports[name] = Object::New(_isolate);
    }

    _loaded.templates.resize(_module.types.size());
    std::vector<Local<FunctionTemplate>> templates(_module.types.size());
    for (const TypeInfo& type : _module.types) {
      if (IsEnumKind(type.kind) || type.family != static_cast<int>(type.index)) {
        continue;
      }
      Local<FunctionTemplate> tmpl =
          FunctionTemplate::New(_isolate, ConstructorCallback, DataFor(_isolate, &type));
      tmpl->SetClassName(tns::ToV8String(_isolate, LastComponent(type.jsName)));
      tmpl->InstanceTemplate()->SetInternalFieldCount(1);
      templates[type.index] = tmpl;
    }
    for (const TypeInfo& type : _module.types) {
      if (!IsEnumKind(type.kind)) {
        templates[type.index] = templates[type.family];
      }
    }
    for (const TypeInfo& type : _module.types) {
      if (type.family == static_cast<int>(type.index) && type.superIndex >= 0 &&
          !templates[type.index].IsEmpty() && !templates[type.superIndex].IsEmpty()) {
        templates[type.index]->Inherit(templates[type.superIndex]);
      }
    }

    std::vector<Local<Object>> enums(_module.types.size());
    for (const TypeInfo& type : _module.types) {
      if (IsEnumKind(type.kind)) {
        enums[type.index] = type.family == static_cast<int>(type.index) ? Object::New(_isolate)
                                                                        : enums[type.family];
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
      if (IsEnumKind(owner.kind)) {
        enumGroups.push_back(group.get());
        continue;
      }
      InstallOnTemplate(templates[group->owner], *group);
    }

    std::vector<Local<Object>> values(_module.types.size());
    for (const TypeInfo& type : _module.types) {
      if (IsEnumKind(type.kind)) {
        values[type.index] = enums[type.index];
        continue;
      }
      if (type.family != static_cast<int>(type.index)) {
        _loaded.templates[type.index].Reset(_isolate, templates[type.index]);
        continue;
      }
      Local<v8::Function> function;
      if (!templates[type.index]->GetFunction(_context).ToLocal(&function)) {
        return false;
      }
      _loaded.templates[type.index].Reset(_isolate, templates[type.index]);
      values[type.index] = function;
    }
    for (const TypeInfo& type : _module.types) {
      values[type.index] = values[type.family];
    }

    // Nested types hang off their parent by JS path ("Polygon.Style"); a
    // parent that is not bridged gets a plain namespace object.
    // Keyed by module and path: modules have their own namespaces.
    std::map<std::string, Local<Object>> containers;
    for (const TypeInfo& type : _module.types) {
      containers[type.swiftModule + ":" + type.jsName] = values[type.index];
    }
    std::vector<const TypeInfo*> byDepth;
    for (const TypeInfo& type : _module.types) {
      byDepth.push_back(&type);
    }
    std::stable_sort(byDepth.begin(), byDepth.end(), [](const TypeInfo* a, const TypeInfo* b) {
      return std::count(a->jsName.begin(), a->jsName.end(), '.') <
             std::count(b->jsName.begin(), b->jsName.end(), '.');
    });
    std::vector<Local<Object>> namespaces;
    for (const TypeInfo* type : byDepth) {
      Local<Object> container = exports[type->swiftModule];
      std::string path = type->swiftModule + ":";
      size_t start = 0;
      for (size_t dot = type->jsName.find('.'); dot != std::string::npos;
           dot = type->jsName.find('.', start)) {
        std::string component = type->jsName.substr(start, dot - start);
        path += (path.back() == ':' ? "" : ".") + component;
        auto existing = containers.find(path);
        if (existing == containers.end()) {
          Local<Object> space = Object::New(_isolate);
          if (!container->Set(_context, tns::ToV8String(_isolate, component), space)
                   .FromMaybe(false)) {
            return false;
          }
          existing = containers.emplace(path, space).first;
          namespaces.push_back(space);
        }
        container = existing->second;
        start = dot + 1;
      }
      if (!container
               ->Set(_context, tns::ToV8String(_isolate, LastComponent(type->jsName)),
                     values[type->index])
               .FromMaybe(false)) {
        return false;
      }
    }

    for (const MemberGroup* group : enumGroups) {
      if (!InstallOnObject(enums[group->owner], *group)) {
        return false;
      }
    }
    for (const MemberGroup* group : moduleGroups) {
      if (!InstallOnObject(exports[group->swiftModule], *group)) {
        return false;
      }
    }
    for (Local<Object> enumObject : enums) {
      if (!enumObject.IsEmpty()) {
        enumObject->SetIntegrityLevel(_context, IntegrityLevel::kFrozen).Check();
      }
    }
    for (Local<Object> space : namespaces) {
      space->SetIntegrityLevel(_context, IntegrityLevel::kFrozen).Check();
    }
    for (auto& entry : exports) {
      entry.second->SetIntegrityLevel(_context, IntegrityLevel::kFrozen).Check();
      _loaded.exports[entry.first].Reset(_isolate, entry.second);
    }
    return true;
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
        if (group.module->types[group.owner].kind == NSSwiftTypeTaggedEnum) {
          // Case values are objects JS builds itself.
          return true;
        }
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

// `track(read, changed)`: Observation tracking through any loaded unit.
void TrackCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  if (info.Length() < 2 || !info[0]->IsFunction() || !info[1]->IsFunction()) {
    isolate->ThrowException(Exception::TypeError(
        tns::ToV8String(isolate, "track(read, onChange) takes two functions")));
    return;
  }
  std::shared_ptr<const ModuleInfo> unit;
  {
    std::lock_guard<std::mutex> lock(gModulesMutex);
    for (const auto& entry : gModules) {
      if (entry.second->error.empty() && entry.second->tracker != nullptr) {
        unit = entry.second;
        break;
      }
    }
  }
  auto* state = Caches::StateFor<IsolateState>(isolate);
  if (!unit || state == nullptr) {
    isolate->ThrowException(Exception::Error(tns::ToV8String(
        isolate, "track() needs a loaded Swift module (swift.module(name)) to observe through")));
    return;
  }
  ValueCode code;
  code.kind = ValueCode::Kind::Function;
  auto* read = new SwiftCallback(isolate, unit.get(), code, "track", info[0].As<Object>());
  auto* changed = new SwiftCallback(isolate, unit.get(), code, "track", info[1].As<Object>());
  // Collects what `read` throws, as a call does.
  CallContext call;
  state->calls.push_back(&call);
  uint8_t tracked = unit->tracker(&kAPI, read, changed);
  state->calls.pop_back();
  ReleaseCallback(read);
  ReleaseCallback(changed);
  if (!call.callbackException.IsEmpty()) {
    isolate->ThrowException(call.callbackException.Get(isolate));
  } else if (!tracked) {
    isolate->ThrowException(
        Exception::Error(tns::ToV8String(isolate, "Observation tracking needs iOS 17 or newer")));
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
  result->Set(context, tns::ToV8String(isolate, "name"), info[0]).Check();
  result->Set(context, tns::ToV8String(isolate, "unit"), tns::ToV8String(isolate, module->name))
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
  std::string error;
  std::shared_ptr<const ModuleInfo> module = LoadModuleInfo(name, error);
  if (!module) {
    isolate->ThrowException(Exception::Error(tns::ToV8String(isolate, error)));
    return MaybeLocal<Object>();
  }

  auto loaded = state->byInfo.find(module.get());
  if (loaded == state->byInfo.end()) {
    auto unit = std::make_unique<LoadedModule>();
    unit->info = module;
    LoadedModule* raw = unit.get();
    loaded = state->byInfo.emplace(module.get(), std::move(unit)).first;
    if (!Builder(isolate, context, *raw).Build()) {
      state->byInfo.erase(module.get());
      return MaybeLocal<Object>();
    }
  }
  return loaded->second->exports[name].Get(isolate);
}

MaybeLocal<Object> CreateBinding(Local<Context> context) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<Object> binding = Object::New(isolate);
  Local<v8::Function> loadModule;
  Local<v8::Function> moduleInfo;
  Local<v8::Function> track;
  if (!v8::Function::New(context, LoadModuleCallback).ToLocal(&loadModule) ||
      !v8::Function::New(context, ModuleInfoCallback).ToLocal(&moduleInfo) ||
      !v8::Function::New(context, TrackCallback).ToLocal(&track) ||
      !binding->Set(context, tns::ToV8String(isolate, "track"), track).FromMaybe(false) ||
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
