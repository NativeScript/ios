#include "ThunkEmitter.h"

#include <llvm/ADT/StringExtras.h>

#include <algorithm>
#include <cstdio>
#include <set>

#include "SwiftSource.h"
#include "SwiftSurface.h"

namespace Swift {

namespace {

// Byte offsets of the API table slots used at registration.
constexpr int kRegisterModuleSlot = 10 * 8;
constexpr int kRegisterTypeSlot = 11 * 8;
constexpr int kRegisterMemberSlot = 12 * 8;

std::string quoted(const std::string& text) {
  std::string out = "\"";
  for (char c : text) {
    if (c == '"' || c == '\\') {
      out += '\\';
    }
    out += c;
  }
  return out + "\"";
}

class Emitter {
 public:
  Emitter(const Module& module, const Classification& classification)
      : _module(module),
        _classification(classification),
        _surface(describeSurface(module, classification)) {}

  ThunkSource run() {
    ThunkSource result;
    result.registerSymbol = "ns_swift_register_" + _module.name;

    std::string thunks;
    for (const auto& member : _surface.members) {
      thunks += emitMember(member);
    }

    result.fingerprint = fingerprint(_registrations);
    result.thunkCount = _thunkCount;
    result.source = header() + support() + enumHelpers() + typeIndexFunction() +
                    thunks + registration(result);
    return result;
  }

 private:
  int typeIndexOf(const std::string& id) const { return _surface.indexOf(id); }

  std::string typeName(const std::string& id) const {
    const Symbol* symbol = _module.find(id);
    return symbol ? qualifiedTypeName(_module, *symbol) : "";
  }

  // Swift expression reading slot `slot` as the non-optional value of
  // `type`, for conversions that cannot fail.
  std::string primitiveRead(const BridgedType& type, int slot) const {
    std::string index = std::to_string(slot);
    switch (type.bridge) {
      case Bridge::Bool:
        return "rt.bool(" + index + ")";
      case Bridge::Integer: {
        const IntegerWidth* info = integerWidth(type);
        std::string swiftType = info ? info->swiftType : "Int";
        bool isSigned = !info || info->isSigned;
        std::string raw =
            isSigned ? "rt.int64(" + index + ")" : "rt.uint64(" + index + ")";
        if (swiftType == "Int64" || swiftType == "UInt64") {
          return raw;
        }
        // The runtime has range-checked the value against the width.
        return swiftType + "(truncatingIfNeeded: " + raw + ")";
      }
      case Bridge::Floating: {
        const std::string& usr = unwrappedNode(type).usr();
        if (usr == KnownTypes::kFloat) {
          return "Float(rt.double(" + index + "))";
        }
        if (usr == KnownTypes::kCGFloat) {
          return "CGFloat(rt.double(" + index + "))";
        }
        return "rt.double(" + index + ")";
      }
      case Bridge::String:
        return "rt.string(" + index + ")";
      default:
        return "";
    }
  }

  // Lines binding `name` to argument `slot`; `label` describes it in errors.
  std::string readArgument(const BridgedType& type, int slot,
                           const std::string& name,
                           const std::string& label) const {
    std::string index = std::to_string(slot);
    std::string cast;
    std::string expected;
    switch (type.bridge) {
      case Bridge::ClassHandle:
        cast = "rt.object(" + index + ") as? " + typeName(type.symbolId);
        expected = typeName(type.symbolId);
        break;
      case Bridge::StructBox:
        cast = "(rt.object(" + index + ") as? __NSBox<" +
               typeName(type.symbolId) + ">)?.value";
        expected = typeName(type.symbolId);
        break;
      case Bridge::EnumCase:
        cast = "__nsEnum" + std::to_string(typeIndexOf(type.symbolId)) +
               "(rt.string(" + index + "))";
        expected = "a case of " + typeName(type.symbolId);
        break;
      default: {
        std::string read = primitiveRead(type, slot);
        if (type.optional) {
          return "  let " + name + " = rt.isNull(" + index +
                 ") ? nil : " + read + "\n";
        }
        return "  let " + name + " = " + read + "\n";
      }
    }
    std::string failure = "return rt.throwTypeError(" +
                          quoted(label + " must be " + expected) + ")";
    if (!type.optional) {
      return "  guard let " + name + " = " + cast + " else { " + failure +
             " }\n";
    }
    return "  var " + name + ": " + valueTypeName(type) + "? = nil\n" +
           "  if !rt.isNull(" + index + ") {\n" +
           "    guard let value = " + cast + " else { " + failure + " }\n" +
           "    " + name + " = value\n" + "  }\n";
  }

  std::string valueTypeName(const BridgedType& type) const {
    if (!type.symbolId.empty()) {
      return typeName(type.symbolId);
    }
    return swiftTypeText(unwrappedNode(type), _module);
  }

  // Statements returning `value` (a non-optional expression of `type`).
  std::string returnValue(const BridgedType& type,
                          const std::string& value) const {
    switch (type.bridge) {
      case Bridge::Void:
        return "rt.returnVoid()";
      case Bridge::Bool:
        return "rt.returnBool(" + value + ")";
      case Bridge::Integer: {
        const IntegerWidth* info = integerWidth(type);
        if (info && !info->isSigned) {
          return "rt.returnUInt64(UInt64(" + value + "))";
        }
        return "rt.returnInt64(Int64(" + value + "))";
      }
      case Bridge::Floating:
        return "rt.returnDouble(Double(" + value + "))";
      case Bridge::String:
        return "rt.returnString(" + value + ")";
      case Bridge::ClassHandle:
        return "rt.returnObject(" + value + ", __nsTypeIndex(" + value + ", " +
               std::to_string(typeIndexOf(type.symbolId)) + "))";
      case Bridge::StructBox:
        return "rt.returnObject(__NSBox(" + value + "), " +
               std::to_string(typeIndexOf(type.symbolId)) + ")";
      case Bridge::EnumCase:
        return "rt.returnString(__nsEnumName" +
               std::to_string(typeIndexOf(type.symbolId)) + "(" + value + "))";
      case Bridge::None:
        return "rt.returnVoid()";
    }
    return "rt.returnVoid()";
  }

  std::string returnResult(const BridgedType& type,
                           const std::string& indent) const {
    if (type.optional) {
      return indent + "if let result {\n" + indent + "  " +
             returnValue(type, "result") + "\n" + indent + "} else {\n" +
             indent + "  rt.returnNull()\n" + indent + "}\n";
    }
    return indent + returnValue(type, "result") + "\n";
  }

  // Receiver binding for instance members; returns the receiver expression.
  std::string bindReceiver(const Symbol& owner, std::string& body) const {
    std::string type = qualifiedTypeName(_module, owner);
    std::string failure =
        "return rt.throwTypeError(" + quoted("receiver must be " + type) + ")";
    if (owner.kind == SymbolKind::Struct) {
      body += "  guard let box = rt.object(0) as? __NSBox<" + type +
              "> else { " + failure + " }\n";
      // Mutating members and setters change the boxed copy in place.
      return "box.value";
    }
    if (owner.kind == SymbolKind::Enum) {
      body += "  guard let receiver = __nsEnum" +
              std::to_string(typeIndexOf(owner.preciseId)) +
              "(rt.string(0)) else { " + failure + " }\n";
      return "receiver";
    }
    body += "  guard let receiver = rt.object(0) as? " + type + " else { " +
            failure + " }\n";
    return "receiver";
  }

  std::string thunkHeader(int index) const {
    return "private func __nsThunk" + std::to_string(index) +
           "(_ call: UnsafeMutableRawPointer, _ args: UnsafeRawPointer?, _ "
           "count: Int) {\n"
           "  let rt = __NSCall(call: call, args: args)\n";
  }

  std::string availabilityGuard(const Invocation& invocation,
                                const Symbol& symbol) const {
    if (invocation.availability.empty()) {
      return "";
    }
    std::string platformVersion =
        llvm::StringRef(invocation.availability).rsplit(',').first.trim().str();
    return "  guard #available(" + invocation.availability +
           ") else { return rt.throwMessage(" +
           quoted(symbol.name + " requires " + platformVersion) + ") }\n";
  }

  std::string emitMember(const SwiftSurface::Member& member) {
    const Symbol& symbol = *member.symbol;
    const Capability& capability = *member.capability;
    Invocation invocation = describeInvocation(_module, symbol, capability);
    const Symbol* owner =
        symbol.parentId.empty() ? nullptr : _module.find(symbol.parentId);
    int ownerIndex = member.owner;
    int kind = member.kind;
    int flags = member.flags;
    const std::string& signature = member.signature;
    const BridgedType& result = member.result;

    if (kind == SwiftSurface::kEnumCase) {
      // Case values are their names; nothing to call.
      addRegistration(ownerIndex, kind, flags, capability.jsName, symbol.name,
                      signature, "nil", "nil");
      return "";
    }

    std::string code;
    bool hasReceiver = invocation.needsReceiver;
    int firstArgument = hasReceiver ? 1 : 0;

    // Getter or call.
    int getterIndex = _thunkCount++;
    code += "// " + symbol.preciseId + "\n" + thunkHeader(getterIndex);
    code += availabilityGuard(invocation, symbol);
    std::string receiver;
    if (hasReceiver) {
      receiver = bindReceiver(*owner, code);
    }
    std::vector<std::string> arguments;
    for (size_t i = 0; i < capability.parameters.size(); i++) {
      std::string name = "a" + std::to_string(i);
      code += readArgument(capability.parameters[i],
                           firstArgument + static_cast<int>(i), name,
                           "argument " + std::to_string(i + 1));
      arguments.push_back(name);
    }
    std::string expression =
        invocationExpression(invocation, receiver, arguments);
    std::string binding = result.bridge == Bridge::Void ? "_" : "result";
    std::string resultType = invocation.resultType;
    if (symbol.isThrowing) {
      code += "  do {\n    let " + binding + ": " + resultType + " = " +
              expression + "\n" + returnResult(result, "    ") +
              "  } catch {\n    rt.throwError(error)\n  }\n";
    } else {
      code += "  let " + binding + ": " + resultType + " = " + expression +
              "\n" + returnResult(result, "  ");
    }
    code += "}\n\n";

    std::string setterName = "nil";
    if (flags & SwiftSurface::kSettable) {
      int setterIndex = _thunkCount++;
      code +=
          "// " + symbol.preciseId + " (setter)\n" + thunkHeader(setterIndex);
      code += availabilityGuard(invocation, symbol);
      std::string setterReceiver;
      if (hasReceiver) {
        setterReceiver = bindReceiver(*owner, code);
      }
      code +=
          readArgument(capability.result, firstArgument, "newValue", "value");
      code += "  " +
              assignmentStatement(invocation, setterReceiver, "newValue") +
              "\n";
      code += "  rt.returnVoid()\n}\n\n";
      setterName = "__nsThunk" + std::to_string(setterIndex);
    }

    addRegistration(ownerIndex, kind, flags, capability.jsName, symbol.name,
                    signature, "__nsThunk" + std::to_string(getterIndex),
                    setterName);
    return code;
  }

  void addRegistration(int owner, int kind, int flags,
                       const std::string& jsName, const std::string& swiftName,
                       const std::string& signature, const std::string& thunk,
                       const std::string& setter) {
    _registrations.push_back(
        "  registerMember(registrar, " + std::to_string(owner) + ", " +
        std::to_string(kind) + ", " + std::to_string(flags) + ", " +
        quoted(jsName) + ", " + quoted(swiftName) + ", " + quoted(signature) +
        ", " + thunk + ", " + setter + ")");
  }

  std::string header() const {
    std::string out = "// Generated by objc-metadata-generator from the " +
                      _module.name +
                      " symbol graphs. Do not edit.\n"
                      "// NativeScript Swift interop thunks, ABI " +
                      std::to_string(kThunkABIVersion) +
                      ": see NativeScript/runtime/SwiftInterop.h.\n"
                      "import Foundation\n"
                      "import " +
                      _module.name + "\n";
    std::set<std::string> overlays;
    for (const auto& entry : _module.symbols) {
      const Capability* capability = _classification.find(entry.first);
      if (capability && capability->tier == Tier::SwiftGenerated &&
          !entry.second.declaringModule.empty()) {
        overlays.insert(entry.second.declaringModule);
      }
    }
    for (const auto& overlay : overlays) {
      out += "import " + overlay + "\n";
    }
    return out + "\n";
  }

  static std::string support() {
    return R"swift(private typealias __NSThunk = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer?, Int) -> Void
private typealias __NSRelease = @convention(c) (UnsafeMutableRawPointer) -> Void

private final class __NSBox<Value> {
  var value: Value
  init(_ value: Value) { self.value = value }
}

// Reads arguments (24-byte slots) and reports results through the runtime's
// API table, whose address is the first word of the call context.
private struct __NSCall {
  let call: UnsafeMutableRawPointer
  let args: UnsafeRawPointer?

  private func slot<Function>(_ index: Int, _: Function.Type) -> Function {
    call.load(as: UnsafeRawPointer.self).load(fromByteOffset: index * 8, as: Function.self)
  }

  func isNull(_ i: Int) -> Bool { args!.load(fromByteOffset: i * 24, as: UInt32.self) == 0 }
  func bool(_ i: Int) -> Bool { args!.load(fromByteOffset: i * 24 + 8, as: UInt8.self) != 0 }
  func int64(_ i: Int) -> Int64 { args!.load(fromByteOffset: i * 24 + 8, as: Int64.self) }
  func uint64(_ i: Int) -> UInt64 { args!.load(fromByteOffset: i * 24 + 8, as: UInt64.self) }
  func double(_ i: Int) -> Double { args!.load(fromByteOffset: i * 24 + 8, as: Double.self) }
  func string(_ i: Int) -> String {
    let base = args!.load(fromByteOffset: i * 24 + 8, as: UnsafePointer<UInt8>?.self)
    let length = Int(args!.load(fromByteOffset: i * 24 + 16, as: UInt64.self))
    return String(decoding: UnsafeBufferPointer(start: base, count: length), as: UTF8.self)
  }
  func object(_ i: Int) -> AnyObject {
    let pointer = args!.load(fromByteOffset: i * 24 + 8, as: UnsafeMutableRawPointer.self)
    return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
  }

  func returnVoid() {
    slot(0, (@convention(c) (UnsafeMutableRawPointer) -> Void).self)(call)
  }
  func returnBool(_ value: Bool) {
    slot(1, (@convention(c) (UnsafeMutableRawPointer, UInt8) -> Void).self)(call, value ? 1 : 0)
  }
  func returnInt64(_ value: Int64) {
    slot(2, (@convention(c) (UnsafeMutableRawPointer, Int64) -> Void).self)(call, value)
  }
  func returnUInt64(_ value: UInt64) {
    slot(3, (@convention(c) (UnsafeMutableRawPointer, UInt64) -> Void).self)(call, value)
  }
  func returnDouble(_ value: Double) {
    slot(4, (@convention(c) (UnsafeMutableRawPointer, Double) -> Void).self)(call, value)
  }
  func returnString(_ value: String) {
    var value = value
    value.withUTF8 {
      slot(5, (@convention(c) (UnsafeMutableRawPointer, UnsafePointer<UInt8>?, Int) -> Void).self)(
        call, $0.baseAddress, $0.count)
    }
  }
  func returnNull() {
    slot(6, (@convention(c) (UnsafeMutableRawPointer) -> Void).self)(call)
  }
  func returnObject(_ object: AnyObject, _ typeIndex: UInt32) {
    slot(7, (@convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32) -> Void).self)(
      call, Unmanaged.passRetained(object).toOpaque(), typeIndex)
  }
  func throwError(_ error: any Error) {
    report(String(describing: error), String(reflecting: type(of: error)))
  }
  func throwMessage(_ message: String) {
    report(message, "")
  }
  func throwTypeError(_ message: String) {
    var message = message
    message.withUTF8 {
      slot(9, (@convention(c) (UnsafeMutableRawPointer, UnsafePointer<UInt8>?, Int) -> Void).self)(
        call, $0.baseAddress, $0.count)
    }
  }
  private func report(_ message: String, _ type: String) {
    var message = message
    var type = type
    message.withUTF8 { messageBytes in
      type.withUTF8 { typeBytes in
        slot(8, (@convention(c) (UnsafeMutableRawPointer, UnsafePointer<UInt8>?, Int,
                                 UnsafePointer<UInt8>?, Int) -> Void).self)(
          call, messageBytes.baseAddress, messageBytes.count, typeBytes.baseAddress, typeBytes.count)
      }
    }
  }
}

private func __nsRelease(_ object: UnsafeMutableRawPointer) {
  Unmanaged<AnyObject>.fromOpaque(object).release()
}

)swift";
  }

  std::string enumHelpers() const {
    std::string out;
    for (const auto& type : _surface.types) {
      const Symbol& symbol = *type.symbol;
      if (symbol.kind != SymbolKind::Enum) {
        continue;
      }
      std::string typeName = qualifiedTypeName(_module, symbol);
      std::string availability = availabilityCondition(_module, symbol);
      std::string attribute =
          availability.empty() ? "" : "@available(" + availability + ")\n";
      std::string index = std::to_string(type.index);
      std::vector<std::string> cases;
      for (const auto& id : symbol.memberIds) {
        const Symbol* member = _module.find(id);
        if (member && member->kind == SymbolKind::EnumCase) {
          cases.push_back(member->baseName);
        }
      }
      out += attribute + "private func __nsEnum" + index +
             "(_ name: String) -> " + typeName + "? {\n  switch name {\n";
      for (const auto& name : cases) {
        // Qualified: a case named `none` would otherwise mean Optional.none.
        out += "  case " + quoted(name) + ": return " + typeName + "." +
               swiftIdentifier(name) + "\n";
      }
      out += "  default: return nil\n  }\n}\n\n";
      out += attribute + "private func __nsEnumName" + index +
             "(_ value: " + typeName + ") -> String {\n  switch value {\n";
      for (const auto& name : cases) {
        out += "  case " + typeName + "." + swiftIdentifier(name) +
               ": return " + quoted(name) + "\n";
      }
      out += "  @unknown default: return String(describing: value)\n  }\n}\n\n";
    }
    return out;
  }

  // Dynamic type index of a returned object: most derived classes first.
  std::string typeIndexFunction() const {
    std::vector<const SwiftSurface::Type*> classes;
    for (const auto& type : _surface.types) {
      if (type.symbol->kind == SymbolKind::Class ||
          type.symbol->kind == SymbolKind::Actor) {
        classes.push_back(&type);
      }
    }
    auto depth = [&](const Symbol* symbol) {
      int value = 0;
      for (const Symbol* current = symbol;
           current && !current->superclassId.empty();
           current = _module.find(current->superclassId)) {
        value++;
      }
      return value;
    };
    std::stable_sort(
        classes.begin(), classes.end(),
        [&](const SwiftSurface::Type* a, const SwiftSurface::Type* b) {
          return depth(a->symbol) > depth(b->symbol);
        });

    std::string out =
        "private func __nsTypeIndex(_ object: AnyObject, _ declared: UInt32) "
        "-> UInt32 {\n";
    for (const SwiftSurface::Type* type : classes) {
      if (depth(type->symbol) == 0) {
        // No registered subclass can be more specific than a root class.
        continue;
      }
      std::string check = "if object is " +
                          qualifiedTypeName(_module, *type->symbol) +
                          " { return " + std::to_string(type->index) + " }";
      std::string availability = availabilityCondition(_module, *type->symbol);
      if (availability.empty()) {
        out += "  " + check + "\n";
      } else {
        out += "  if #available(" + availability + ") { " + check + " }\n";
      }
    }
    return out + "  return declared\n}\n\n";
  }

  std::string registration(const ThunkSource& result) const {
    std::string out = "#if hasAttribute(c)\n@c(" + result.registerSymbol +
                      ")\n#else\n@_cdecl(\"" + result.registerSymbol +
                      "\")\n#endif\n"
                      "public func __nsRegister_" +
                      _module.name +
                      "(_ registrar: UnsafeMutableRawPointer) {\n"
                      "  let api = registrar.load(as: UnsafeRawPointer.self)\n"
                      "  let registerModule = api.load(fromByteOffset: " +
                      std::to_string(kRegisterModuleSlot) +
                      ", as: (@convention(c) (UnsafeMutableRawPointer, UInt32, "
                      "UnsafePointer<CChar>, "
                      "UnsafePointer<CChar>, __NSRelease) -> Void).self)\n"
                      "  let registerType = api.load(fromByteOffset: " +
                      std::to_string(kRegisterTypeSlot) +
                      ", as: (@convention(c) (UnsafeMutableRawPointer, UInt32, "
                      "UInt32, UnsafePointer<CChar>, "
                      "UnsafePointer<CChar>, Int32) -> Void).self)\n"
                      "  let registerMember = api.load(fromByteOffset: " +
                      std::to_string(kRegisterMemberSlot) +
                      ", as: (@convention(c) (UnsafeMutableRawPointer, Int32, "
                      "UInt32, UInt32, "
                      "UnsafePointer<CChar>, UnsafePointer<CChar>, "
                      "UnsafePointer<CChar>, __NSThunk?, "
                      "__NSThunk?) -> Void).self)\n\n"
                      "  registerModule(registrar, " +
                      std::to_string(kThunkABIVersion) + ", " +
                      quoted(_module.name) + ", " + quoted(result.fingerprint) +
                      ", __nsRelease)\n";
    for (const auto& type : _surface.types) {
      const Symbol& symbol = *type.symbol;
      int kind = type.kind;
      out += "  registerType(registrar, " + std::to_string(type.index) + ", " +
             std::to_string(kind) + ", " + quoted(symbol.name) + ", " +
             quoted(qualifiedTypeName(_module, symbol)) + ", " +
             std::to_string(type.superIndex) + ")\n";
    }
    for (const auto& line : _registrations) {
      out += line + "\n";
    }
    return out + "}\n";
  }

  std::string fingerprint(const std::vector<std::string>& registrations) const {
    // FNV-1a over everything registered, so the value changes with the
    // surface but not with emitter formatting.
    uint64_t hash = 1469598103934665603ull;
    auto mix = [&](const std::string& text) {
      for (unsigned char c : text) {
        hash ^= c;
        hash *= 1099511628211ull;
      }
      hash ^= '\n';
      hash *= 1099511628211ull;
    };
    mix(_module.name);
    for (const auto& type : _surface.types) {
      mix(qualifiedTypeName(_module, *type.symbol) + "#" +
          std::to_string(type.index));
    }
    for (const auto& line : registrations) {
      mix(line);
    }
    char buffer[17];
    std::snprintf(buffer, sizeof(buffer), "%016llx",
                  static_cast<unsigned long long>(hash));
    return buffer;
  }

  const Module& _module;
  const Classification& _classification;
  SwiftSurface _surface;
  std::vector<std::string> _registrations;
  int _thunkCount = 0;
};

}  // namespace

ThunkSource emitThunks(const Module& module,
                       const Classification& classification) {
  return Emitter(module, classification).run();
}

}  // namespace Swift
