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
constexpr int kRegisterUnitModuleSlot = 42 * 8;

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
    for (const auto& name : _module.swiftModules()) {
      result.registerSymbols.push_back("ns_swift_register_" + name);
    }

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

  struct ValueExpression {
    std::string code;
    // The expression is optional: nil means the JS value did not convert.
    bool failable;
  };

  // Swift expression reading slot `index` of `slots` as the non-optional
  // value of `type`. Collections recurse through element closures.
  ValueExpression valueExpression(const BridgedType& type,
                                  const std::string& slots,
                                  const std::string& index) const {
    auto read = [&](const std::string& reader) {
      return slots + "." + reader + "(" + index + ")";
    };
    switch (type.bridge) {
      case Bridge::Bool:
        return {read("bool"), false};
      case Bridge::Integer: {
        const IntegerWidth* info = integerWidth(type);
        std::string swiftType = info ? info->swiftType : "Int";
        bool isSigned = !info || info->isSigned;
        std::string raw = read(isSigned ? "int64" : "uint64");
        if (swiftType == "Int64" || swiftType == "UInt64") {
          return {raw, false};
        }
        // The runtime has range-checked the value against the width.
        return {swiftType + "(truncatingIfNeeded: " + raw + ")", false};
      }
      case Bridge::Floating: {
        const std::string& usr = unwrappedNode(type).usr();
        if (usr == KnownTypes::kFloat) {
          return {"Float(" + read("double") + ")", false};
        }
        if (usr == KnownTypes::kCGFloat) {
          return {"CGFloat(" + read("double") + ")", false};
        }
        return {read("double"), false};
      }
      case Bridge::String:
        return {read("string"), false};
      case Bridge::Date:
        return {"Date(timeIntervalSince1970: " + read("double") + " / 1000)",
                false};
      case Bridge::URL:
        return {"URL(string: " + read("string") + ")", true};
      case Bridge::Data:
        return {read("bytes"), false};
      case Bridge::ClassHandle:
        return {read("object") + " as? " + typeName(type.symbolId), true};
      case Bridge::ObjCObject:
        return {read("object") + " as? " + valueTypeName(type), true};
      case Bridge::StructBox:
        return {"(" + read("object") + " as? __NSBox<" +
                    typeName(type.symbolId) + ">)?.value",
                true};
      case Bridge::EnumCase:
        return {"__nsEnum" + std::to_string(typeIndexOf(type.symbolId)) + "(" +
                    read("string") + ")",
                true};
      case Bridge::TaggedEnum:
        return {"__nsReadCase" + std::to_string(typeIndexOf(type.symbolId)) +
                    "(" + slots + ", " + index + ")",
                true};
      case Bridge::Array:
      case Bridge::Dictionary: {
        const BridgedType& element = type.elements.at(0);
        ValueExpression inner = valueExpression(element, "s", "j");
        std::string reader =
            type.bridge == Bridge::Array ? "__nsReadArray" : "__nsReadMap";
        // An explicit closure argument: trailing closures cannot appear in
        // guard conditions.
        return {reader + "(" + slots + ", " + index +
                    ", { (s: __NSSlots, j: Int) -> " + valueTypeName(element) +
                    "? in " + inner.code + " })",
                true};
      }
      case Bridge::Closure: {
        // A closure that reports its arguments to the JS function; the
        // explicit type keeps attributes (@Sendable, @MainActor) the
        // parameter requires.
        std::vector<std::string> parameters;
        std::vector<std::string> reports;
        for (size_t i = 0; i < type.elements.size(); i++) {
          const BridgedType& element = type.elements[i];
          std::string name = "p" + std::to_string(i);
          parameters.push_back(name + ": " +
                               swiftTypeText(element.node, _module));
          std::string report = returnValue(element, "r", name);
          reports.push_back(element.optional
                                ? "if let " + name + " { " + report +
                                      " } else { r.returnNull() }"
                                : report);
        }
        std::string closureType = swiftTypeText(unwrappedNode(type), _module);
        std::string body =
            reports.empty() ? "_ in" : "r in " + llvm::join(reports, "; ");
        return {"{ () -> " + closureType +
                    " in let callback = __NSCallback(api: rt.api, handle: " +
                    read("callback") + "); return { (" +
                    llvm::join(parameters, ", ") + ") in callback.invoke { " +
                    body + " } } }()",
                false};
      }
      case Bridge::Void:
      case Bridge::None:
        break;
    }
    return {"nil", true};
  }

  // Lines binding `name` to argument `slot`; `label` describes it in errors.
  std::string readArgument(const BridgedType& type, int slot,
                           const std::string& name,
                           const std::string& label) const {
    std::string index = std::to_string(slot);
    ValueExpression value = valueExpression(type, "rt.slots", index);
    if (!value.failable) {
      if (type.optional) {
        return "  let " + name + " = rt.slots.isNull(" + index +
               ") ? nil : " + value.code + "\n";
      }
      return "  let " + name + " = " + value.code + "\n";
    }
    std::string failure = "return rt.throwTypeError(" +
                          quoted(label + " must be " + describe(type)) + ")";
    if (!type.optional) {
      return "  guard let " + name + " = " + value.code + " else { " + failure +
             " }\n";
    }
    return "  var " + name + ": " + valueTypeName(type) + "? = nil\n" +
           "  if !rt.slots.isNull(" + index + ") {\n" +
           "    guard let value = " + value.code + " else { " + failure +
           " }\n" + "    " + name + " = value\n" + "  }\n";
  }

  // How errors describe what a value must be.
  std::string describe(const BridgedType& type) const {
    switch (type.bridge) {
      case Bridge::EnumCase:
      case Bridge::TaggedEnum:
        return "a case of " + typeName(type.symbolId);
      case Bridge::URL:
        return "a valid URL";
      case Bridge::Array:
        return "an array of " + describe(type.elements.at(0));
      case Bridge::Dictionary:
        return "an object whose values are " + describe(type.elements.at(0));
      case Bridge::ClassHandle:
      case Bridge::StructBox:
        return typeName(type.symbolId);
      case Bridge::ObjCObject:
        return "a " + valueTypeName(type);
      default:
        return valueTypeName(type);
    }
  }

  std::string valueTypeName(const BridgedType& type) const {
    if (!type.symbolId.empty()) {
      return typeName(type.symbolId);
    }
    return swiftTypeText(unwrappedNode(type), _module);
  }

  // Statements returning `value` (a non-optional expression of `type`).
  std::string returnValue(const BridgedType& type, const std::string& reporter,
                          const std::string& value) const {
    switch (type.bridge) {
      case Bridge::Void:
        return reporter + ".returnVoid()";
      case Bridge::Bool:
        return reporter + ".returnBool(" + value + ")";
      case Bridge::Integer: {
        const IntegerWidth* info = integerWidth(type);
        if (info && !info->isSigned) {
          return reporter + ".returnUInt64(UInt64(" + value + "))";
        }
        return reporter + ".returnInt64(Int64(" + value + "))";
      }
      case Bridge::Floating:
        return reporter + ".returnDouble(Double(" + value + "))";
      case Bridge::String:
        return reporter + ".returnString(" + value + ")";
      case Bridge::ClassHandle:
        return reporter + ".returnObject(" + value + ", __nsTypeIndex(" +
               value + ", " + std::to_string(typeIndexOf(type.symbolId)) + "))";
      case Bridge::StructBox:
        return reporter + ".returnObject(__NSBox(" + value + "), " +
               std::to_string(typeIndexOf(type.symbolId)) + ")";
      case Bridge::ObjCObject:
        return reporter + ".returnObjC(" + value + ")";
      case Bridge::EnumCase:
        return reporter + ".returnString(__nsEnumName" +
               std::to_string(typeIndexOf(type.symbolId)) + "(" + value + "))";
      case Bridge::TaggedEnum:
        return "__nsReportCase" + std::to_string(typeIndexOf(type.symbolId)) +
               "(" + reporter + ", " + value + ")";
      case Bridge::Date:
        return reporter + ".returnDouble(" + value +
               ".timeIntervalSince1970 * 1000)";
      case Bridge::URL:
        return reporter + ".returnString(" + value + ".absoluteString)";
      case Bridge::Data:
        return reporter + ".returnBytes(" + value + ")";
      case Bridge::Array:
        return reporter + ".returnArray(" + value + ") { element in " +
               returnValue(type.elements.at(0), reporter, "element") + " }";
      case Bridge::Dictionary:
        return reporter + ".returnMap(" + value + ") { key, element in " +
               reporter + ".returnString(key); " +
               returnValue(type.elements.at(0), reporter, "element") + " }";
      case Bridge::Closure:
      case Bridge::None:
        return reporter + ".returnVoid()";
    }
    return reporter + ".returnVoid()";
  }

  std::string returnResult(const BridgedType& type, const std::string& indent,
                           const std::string& reporter = "rt") const {
    if (type.optional) {
      return indent + "if let result {\n" + indent + "  " +
             returnValue(type, reporter, "result") + "\n" + indent +
             "} else {\n" + indent + "  " + reporter + ".returnNull()\n" +
             indent + "}\n";
    }
    return indent + returnValue(type, reporter, "result") + "\n";
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
      std::string index = std::to_string(typeIndexOf(owner.preciseId));
      body += hasAssociatedValues(_module, owner)
                  ? "  guard let receiver = __nsReadCase" + index +
                        "(rt.slots, 0) else { " + failure + " }\n"
                  : "  guard let receiver = __nsEnum" + index +
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

  // `body` run on the main actor, after rejecting calls from other threads
  // (assumeIsolated would trap).
  std::string onMainActor(const Symbol& symbol, const std::string& body) const {
    std::string indented;
    llvm::SmallVector<llvm::StringRef, 16> lines;
    llvm::StringRef(body).split(lines, '\n', -1, false);
    for (llvm::StringRef line : lines) {
      indented += "  " + line.str() + "\n";
    }
    return "  guard Thread.isMainThread else { return rt.throwMessage(" +
           quoted(
               symbol.name +
               " is isolated to the main actor; call it on the main thread") +
           ") }\n  MainActor.assumeIsolated {\n" + indented + "  }\n";
  }

  // Starts the call in a Task and settles the call's Promise from there.
  // Arguments are read before the Task starts: their slots only live for
  // the synchronous call.
  std::string asyncCall(const Symbol* owner, bool hasReceiver,
                        const std::vector<std::string>& arguments,
                        const std::string& expression,
                        const std::string& binding,
                        const std::string& resultType,
                        const BridgedType& result, bool throwing) const {
    std::vector<std::string> captured;
    if (hasReceiver) {
      captured.push_back(
          owner && owner->kind == SymbolKind::Struct ? "box" : "receiver");
    }
    captured.insert(captured.end(), arguments.begin(), arguments.end());

    std::string code = "  let completion = rt.beginAsync()\n";
    std::string unpack;
    if (captured.size() == 1) {
      code += "  let captured = __NSUnchecked(" + captured[0] + ")\n";
      unpack = "    let " + captured[0] + " = captured.value\n";
    } else if (!captured.empty()) {
      std::string list = llvm::join(captured, ", ");
      code += "  let captured = __NSUnchecked((" + list + "))\n";
      unpack = "    let (" + list + ") = captured.value\n";
    }
    code += "  Task {\n" + unpack;
    if (throwing) {
      code += "    do {\n      let " + binding + ": " + resultType + " = " +
              expression + "\n" + returnResult(result, "      ", "completion") +
              "    } catch {\n      completion.throwError(error)\n    }\n";
    } else {
      code += "    let " + binding + ": " + resultType + " = " + expression +
              "\n" + returnResult(result, "    ", "completion");
    }
    return code + "  }\n";
  }

  std::string emitMember(const SwiftSurface::Member& member) {
    const Symbol& symbol = *member.symbol;
    const Capability& capability = *member.capability;
    Invocation invocation = describeInvocation(_module, symbol, capability);
    const Symbol* owner =
        symbol.parentId.empty() ? nullptr : _module.find(symbol.parentId);
    int flags = member.flags;
    const BridgedType& result = member.result;

    if (member.kind == SwiftSurface::kEnumCase) {
      // Cases are values (names, or objects JS builds); nothing to call.
      addRegistration(member, "nil", "nil");
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
    // Reports of inout arguments' final values, after a successful call.
    std::string writeBacks;
    for (size_t i = 0; i < capability.parameters.size(); i++) {
      const BridgedType& parameter = capability.parameters[i];
      std::string name = "a" + std::to_string(i);
      std::string read = parameter.isInout ? "v" + std::to_string(i) : name;
      code += readArgument(parameter, firstArgument + static_cast<int>(i), read,
                           "argument " + std::to_string(i + 1));
      if (parameter.isInout) {
        code += "  var " + name + " = " + read + "\n";
        std::string statement = returnValue(parameter, "rt", name);
        writeBacks +=
            "rt.writeBack(" + std::to_string(i) + ") { " +
            (parameter.optional ? "if let " + name + " { " + statement +
                                      " } else { rt.returnNull() }"
                                : statement) +
            " }\n";
      }
      arguments.push_back(name);
    }
    std::string expression =
        invocationExpression(invocation, receiver, arguments);
    std::string binding = result.bridge == Bridge::Void ? "_" : "result";
    std::string resultType = invocation.resultType;
    if (invocation.isAsync) {
      code += asyncCall(owner, hasReceiver, arguments, expression, binding,
                        resultType, result, symbol.isThrowing);
    } else {
      auto indented = [&](const std::string& indent) {
        std::string out;
        llvm::SmallVector<llvm::StringRef, 4> lines;
        llvm::StringRef(writeBacks).split(lines, '\n', -1, false);
        for (llvm::StringRef line : lines) {
          out += indent + line.str() + "\n";
        }
        return out;
      };
      std::string body;
      if (symbol.isThrowing) {
        body = "  do {\n    let " + binding + ": " + resultType + " = " +
               expression + "\n" + indented("    ") +
               returnResult(result, "    ") +
               "  } catch {\n    rt.throwError(error)\n  }\n";
      } else {
        body = "  let " + binding + ": " + resultType + " = " + expression +
               "\n" + indented("  ") + returnResult(result, "  ");
      }
      code += invocation.isMainActor ? onMainActor(symbol, body) : body;
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
      std::string body =
          "  " + assignmentStatement(invocation, setterReceiver, "newValue") +
          "\n  rt.returnVoid()\n";
      code += invocation.isMainActor ? onMainActor(symbol, body) : body;
      code += "}\n\n";
      setterName = "__nsThunk" + std::to_string(setterIndex);
    }

    addRegistration(member, "__nsThunk" + std::to_string(getterIndex),
                    setterName);
    return code;
  }

  void addRegistration(const SwiftSurface::Member& member,
                       const std::string& thunk, const std::string& setter) {
    _registrations.push_back(
        "  registerMember(registrar, " + std::to_string(member.owner) + ", " +
        std::to_string(member.kind) + ", " + std::to_string(member.flags) +
        ", " + quoted(member.module) + ", " +
        quoted(member.capability->jsName) + ", " + quoted(member.symbol->name) +
        ", " + quoted(member.signature) + ", " + thunk + ", " + setter + ")");
  }

  std::string header() const {
    std::string out = "// Generated by objc-metadata-generator from the " +
                      _module.name +
                      " symbol graphs. Do not edit.\n"
                      "// NativeScript Swift interop thunks, ABI " +
                      std::to_string(kThunkABIVersion) +
                      ": see NativeScript/runtime/SwiftInterop.h.\n"
                      "import Foundation\n";
    return out + swiftImports(_module, _classification) + "\n";
  }

  static std::string support() {
    return R"swift(private typealias __NSThunk = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer?, Int) -> Void
private typealias __NSRelease = @convention(c) (UnsafeMutableRawPointer) -> Void

private final class __NSBox<Value> {
  var value: Value
  init(_ value: Value) { self.value = value }
}

// The result entries calls and completions share, so value reporting code
// serves both.
private protocol __NSReporter {
  func returnVoid()
  func returnBool(_ value: Bool)
  func returnInt64(_ value: Int64)
  func returnUInt64(_ value: UInt64)
  func returnDouble(_ value: Double)
  func returnString(_ value: String)
  func returnNull()
  func returnBytes(_ value: Data)
  func returnArray<Elements: Collection>(_ values: Elements, _ each: (Elements.Element) -> Void)
  func returnMap<Value>(_ values: [String: Value], _ each: (String, Value) -> Void)
  func returnObject(_ object: AnyObject, _ typeIndex: UInt32)
  func returnCase(_ index: Int, _ values: () -> Void)
  func returnObjC(_ object: AnyObject)
}

// Reads arguments (24-byte slots) and reports results through the runtime's
// API table, whose address is the first word of the call context.
// 24-byte argument slots: tag at 0, payload at 8, length at 16. Arrays and
// maps point at their own slots (a map's are key, value, key, value, ...).
private struct __NSSlots {
  let base: UnsafeRawPointer?

  func isNull(_ i: Int) -> Bool { base!.load(fromByteOffset: i * 24, as: UInt32.self) == 0 }
  func bool(_ i: Int) -> Bool { base!.load(fromByteOffset: i * 24 + 8, as: UInt8.self) != 0 }
  func int64(_ i: Int) -> Int64 { base!.load(fromByteOffset: i * 24 + 8, as: Int64.self) }
  func uint64(_ i: Int) -> UInt64 { base!.load(fromByteOffset: i * 24 + 8, as: UInt64.self) }
  func double(_ i: Int) -> Double { base!.load(fromByteOffset: i * 24 + 8, as: Double.self) }
  private func buffer(_ i: Int) -> UnsafeBufferPointer<UInt8> {
    let start = base!.load(fromByteOffset: i * 24 + 8, as: UnsafePointer<UInt8>?.self)
    let length = Int(base!.load(fromByteOffset: i * 24 + 16, as: UInt64.self))
    return UnsafeBufferPointer(start: start, count: length)
  }
  func string(_ i: Int) -> String { String(decoding: buffer(i), as: UTF8.self) }
  func bytes(_ i: Int) -> Data { Data(buffer(i)) }
  func object(_ i: Int) -> AnyObject {
    let pointer = base!.load(fromByteOffset: i * 24 + 8, as: UnsafeMutableRawPointer.self)
    return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
  }
  func callback(_ i: Int) -> UnsafeMutableRawPointer {
    base!.load(fromByteOffset: i * 24 + 8, as: UnsafeMutableRawPointer.self)
  }
  func elements(_ i: Int) -> (__NSSlots, Int) {
    let start = base!.load(fromByteOffset: i * 24 + 8, as: UnsafeRawPointer?.self)
    return (__NSSlots(base: start), Int(base!.load(fromByteOffset: i * 24 + 16, as: UInt64.self)))
  }
}

// nil when an element does not convert.
private func __nsReadArray<Element>(_ slots: __NSSlots, _ i: Int,
                                    _ read: (__NSSlots, Int) -> Element?) -> [Element]? {
  let (elements, count) = slots.elements(i)
  var result: [Element] = []
  result.reserveCapacity(count)
  for j in 0..<count {
    guard let element = read(elements, j) else { return nil }
    result.append(element)
  }
  return result
}

private func __nsReadMap<Value>(_ slots: __NSSlots, _ i: Int,
                                _ read: (__NSSlots, Int) -> Value?) -> [String: Value]? {
  let (entries, count) = slots.elements(i)
  var result: [String: Value] = [:]
  result.reserveCapacity(count)
  for j in 0..<count {
    guard let value = read(entries, 2 * j + 1) else { return nil }
    result[entries.string(2 * j)] = value
  }
  return result
}

private struct __NSCall: __NSReporter {
  let call: UnsafeMutableRawPointer
  let slots: __NSSlots

  init(call: UnsafeMutableRawPointer, args: UnsafeRawPointer?) {
    self.call = call
    self.slots = __NSSlots(base: args)
  }

  private func slot<Function>(_ index: Int, _: Function.Type) -> Function {
    call.load(as: UnsafeRawPointer.self).load(fromByteOffset: index * 8, as: Function.self)
  }

  var api: UnsafeRawPointer { call.load(as: UnsafeRawPointer.self) }
  func string(_ i: Int) -> String { slots.string(i) }
  func object(_ i: Int) -> AnyObject { slots.object(i) }

  func beginAsync() -> __NSCompletion {
    let token = slot(13, (@convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer).self)(call)
    return __NSCompletion(api: call.load(as: UnsafeRawPointer.self), token: token)
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
  func returnBytes(_ value: Data) {
    value.withUnsafeBytes {
      slot(5, (@convention(c) (UnsafeMutableRawPointer, UnsafePointer<UInt8>?, Int) -> Void).self)(
        call, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
    }
  }
  // Each element is reported with the ordinary return* entries.
  func returnArray<Elements: Collection>(_ values: Elements, _ each: (Elements.Element) -> Void) {
    slot(23, (@convention(c) (UnsafeMutableRawPointer, Int) -> Void).self)(call, values.count)
    for value in values { each(value) }
    slot(24, (@convention(c) (UnsafeMutableRawPointer) -> Void).self)(call)
  }
  // `each` reports the key (a string), then the value.
  func returnMap<Value>(_ values: [String: Value], _ each: (String, Value) -> Void) {
    slot(25, (@convention(c) (UnsafeMutableRawPointer, Int) -> Void).self)(call, values.count)
    for (key, value) in values { each(key, value) }
    slot(26, (@convention(c) (UnsafeMutableRawPointer) -> Void).self)(call)
  }
  // `values` reports the case's associated values in order.
  func returnCase(_ index: Int, _ values: () -> Void) {
    slot(34, (@convention(c) (UnsafeMutableRawPointer, Int) -> Void).self)(call, index)
    values()
    slot(36, (@convention(c) (UnsafeMutableRawPointer) -> Void).self)(call)
  }
  // `value` reports the final value of inout argument `index`.
  func writeBack(_ index: Int, _ value: () -> Void) {
    slot(38, (@convention(c) (UnsafeMutableRawPointer, Int) -> Void).self)(call, index)
    value()
    slot(39, (@convention(c) (UnsafeMutableRawPointer) -> Void).self)(call)
  }
  func returnObject(_ object: AnyObject, _ typeIndex: UInt32) {
    slot(7, (@convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32) -> Void).self)(
      call, Unmanaged.passRetained(object).toOpaque(), typeIndex)
  }
  func returnObjC(_ object: AnyObject) {
    slot(40, (@convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Void).self)(
      call, Unmanaged.passRetained(object).toOpaque())
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

// Carries values into a Task; the runtime only touches them on one thread at
// a time.
private final class __NSUnchecked<Value>: @unchecked Sendable {
  let value: Value
  init(_ value: Value) { self.value = value }
}

// Settles an async call's Promise from any thread; the first report consumes
// the token.
private struct __NSCompletion: @unchecked Sendable, __NSReporter {
  let api: UnsafeRawPointer
  let token: UnsafeMutableRawPointer

  private func slot<Function>(_ index: Int, _: Function.Type) -> Function {
    api.load(fromByteOffset: index * 8, as: Function.self)
  }

  func returnVoid() {
    slot(14, (@convention(c) (UnsafeMutableRawPointer) -> Void).self)(token)
  }
  func returnBool(_ value: Bool) {
    slot(15, (@convention(c) (UnsafeMutableRawPointer, UInt8) -> Void).self)(token, value ? 1 : 0)
  }
  func returnInt64(_ value: Int64) {
    slot(16, (@convention(c) (UnsafeMutableRawPointer, Int64) -> Void).self)(token, value)
  }
  func returnUInt64(_ value: UInt64) {
    slot(17, (@convention(c) (UnsafeMutableRawPointer, UInt64) -> Void).self)(token, value)
  }
  func returnDouble(_ value: Double) {
    slot(18, (@convention(c) (UnsafeMutableRawPointer, Double) -> Void).self)(token, value)
  }
  func returnString(_ value: String) {
    var value = value
    value.withUTF8 {
      slot(19, (@convention(c) (UnsafeMutableRawPointer, UnsafePointer<UInt8>?, Int) -> Void).self)(
        token, $0.baseAddress, $0.count)
    }
  }
  func returnNull() {
    slot(20, (@convention(c) (UnsafeMutableRawPointer) -> Void).self)(token)
  }
  func returnBytes(_ value: Data) {
    value.withUnsafeBytes {
      slot(19, (@convention(c) (UnsafeMutableRawPointer, UnsafePointer<UInt8>?, Int) -> Void).self)(
        token, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
    }
  }
  func returnArray<Elements: Collection>(_ values: Elements, _ each: (Elements.Element) -> Void) {
    slot(27, (@convention(c) (UnsafeMutableRawPointer, Int) -> Void).self)(token, values.count)
    for value in values { each(value) }
    slot(28, (@convention(c) (UnsafeMutableRawPointer) -> Void).self)(token)
  }
  func returnMap<Value>(_ values: [String: Value], _ each: (String, Value) -> Void) {
    slot(29, (@convention(c) (UnsafeMutableRawPointer, Int) -> Void).self)(token, values.count)
    for (key, value) in values { each(key, value) }
    slot(30, (@convention(c) (UnsafeMutableRawPointer) -> Void).self)(token)
  }
  func returnCase(_ index: Int, _ values: () -> Void) {
    slot(35, (@convention(c) (UnsafeMutableRawPointer, Int) -> Void).self)(token, index)
    values()
    slot(37, (@convention(c) (UnsafeMutableRawPointer) -> Void).self)(token)
  }
  func returnObject(_ object: AnyObject, _ typeIndex: UInt32) {
    slot(21, (@convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32) -> Void).self)(
      token, Unmanaged.passRetained(object).toOpaque(), typeIndex)
  }
  func returnObjC(_ object: AnyObject) {
    slot(41, (@convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Void).self)(
      token, Unmanaged.passRetained(object).toOpaque())
  }
  func throwError(_ error: any Error) {
    var message = String(describing: error)
    var type = String(reflecting: Swift.type(of: error))
    message.withUTF8 { messageBytes in
      type.withUTF8 { typeBytes in
        slot(22, (@convention(c) (UnsafeMutableRawPointer, UnsafePointer<UInt8>?, Int,
                                  UnsafePointer<UInt8>?, Int) -> Void).self)(
          token, messageBytes.baseAddress, messageBytes.count, typeBytes.baseAddress, typeBytes.count)
      }
    }
  }
}

// A JS function held as a Swift closure. Calls may come from any thread; the
// runtime runs the function on its isolate's thread.
private final class __NSCallback: @unchecked Sendable {
  let api: UnsafeRawPointer
  let handle: UnsafeMutableRawPointer

  init(api: UnsafeRawPointer, handle: UnsafeMutableRawPointer) {
    self.api = api
    self.handle = handle
    api.load(fromByteOffset: 32 * 8, as: (@convention(c) (UnsafeMutableRawPointer) -> Void).self)(handle)
  }

  deinit {
    api.load(fromByteOffset: 33 * 8, as: (@convention(c) (UnsafeMutableRawPointer) -> Void).self)(handle)
  }

  // `arguments` reports each argument through the ordinary return entries.
  func invoke(_ arguments: (__NSCompletion) -> Void) {
    let begin = api.load(fromByteOffset: 31 * 8,
                         as: (@convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer).self)
    let completion = __NSCompletion(api: api, token: begin(handle))
    arguments(completion)
    api.load(fromByteOffset: 28 * 8, as: (@convention(c) (UnsafeMutableRawPointer) -> Void).self)(completion.token)
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
      if (type.kind == SwiftSurface::kTaggedEnum) {
        out += taggedEnumHelpers(type);
        continue;
      }
      if (symbol.kind != SymbolKind::Enum) {
        continue;
      }
      std::string typeName = qualifiedTypeName(_module, symbol);
      std::string availability = availabilityCondition(_module, symbol);
      std::string attribute =
          availability.empty() ? "" : "@available(" + availability + ")\n";
      std::string index = std::to_string(type.index);
      // Cases newer than their enum are reached under #available.
      struct Case {
        std::string name;
        std::string availability;
      };
      std::vector<Case> cases;
      bool anyGated = false;
      for (const auto& id : symbol.memberIds) {
        const Symbol* member = _module.find(id);
        const Capability* capability = _classification.find(id);
        if (!member || member->kind != SymbolKind::EnumCase || !capability ||
            capability->tier != Tier::SwiftGenerated) {
          continue;
        }
        std::string condition = availabilityCondition(_module, *member);
        if (condition == availability) {
          condition.clear();
        }
        anyGated |= !condition.empty();
        cases.push_back(Case{member->baseName, condition});
      }

      out += "// " + symbol.preciseId + "\n";
      out += attribute + "private func __nsEnum" + index +
             "(_ name: String) -> " + typeName + "? {\n  switch name {\n";
      for (const auto& entry : cases) {
        // Qualified: a case named `none` would otherwise mean Optional.none.
        std::string value = typeName + "." + swiftIdentifier(entry.name);
        out += "  case " + quoted(entry.name) + ": ";
        out += entry.availability.empty()
                   ? "return " + value + "\n"
                   : "if #available(" + entry.availability + ") { return " +
                         value + " } else { return nil }\n";
      }
      out += "  default: return nil\n  }\n}\n\n";

      out += attribute + "private func __nsEnumName" + index +
             "(_ value: " + typeName + ") -> String {\n  switch value {\n";
      for (const auto& entry : cases) {
        if (entry.availability.empty()) {
          out += "  case " + typeName + "." + swiftIdentifier(entry.name) +
                 ": return " + quoted(entry.name) + "\n";
        }
      }
      if (anyGated) {
        // A case pattern cannot be guarded by #available.
        out += "  default:\n";
        for (const auto& entry : cases) {
          if (!entry.availability.empty()) {
            out += "    if #available(" + entry.availability +
                   "), value == " + typeName + "." +
                   swiftIdentifier(entry.name) + " { return " +
                   quoted(entry.name) + " }\n";
          }
        }
        out += "    return String(describing: value)\n  }\n}\n\n";
      } else {
        out +=
            "  @unknown default: return String(describing: value)\n  }\n}\n\n";
      }
    }
    return out;
  }

  // __nsReadCase<n> builds the enum from a case slot (NSSwiftTagCase: the
  // case index, then its associated values) and __nsReportCase<n> reports
  // one, both by the case's registration index.
  std::string taggedEnumHelpers(const SwiftSurface::Type& type) const {
    const Symbol& symbol = *type.symbol;
    std::string typeName = qualifiedTypeName(_module, symbol);
    std::string availability = availabilityCondition(_module, symbol);
    std::string attribute =
        availability.empty() ? "" : "@available(" + availability + ")\n";
    std::string index = std::to_string(type.index);
    std::vector<const SwiftSurface::Member*> cases =
        _surface.casesOf(type.index);

    std::string read = "// " + symbol.preciseId + "\n" + attribute +
                       "private func __nsReadCase" + index +
                       "(_ slots: __NSSlots, _ i: Int) -> " + typeName +
                       "? {\n  let (s, _) = slots.elements(i)\n"
                       "  switch s.int64(0) {\n";
    std::string report = attribute + "private func __nsReportCase" + index +
                         "<R: __NSReporter>(_ r: R, _ value: " + typeName +
                         ") {\n  switch value {\n";
    std::string gatedReports;
    for (size_t k = 0; k < cases.size(); k++) {
      const Symbol& member = *cases[k]->symbol;
      const auto& elements = cases[k]->capability->parameters;
      std::string condition = availabilityCondition(_module, member);
      if (condition == availability) {
        condition.clear();
      }
      std::string value = typeName + "." + swiftIdentifier(member.baseName);

      read += "  case " + std::to_string(k) + ":\n";
      if (!condition.empty()) {
        read += "    guard #available(" + condition + ") else { return nil }\n";
      }
      std::vector<std::string> arguments;
      std::vector<std::string> bindings;
      std::vector<std::string> reports;
      for (size_t e = 0; e < elements.size(); e++) {
        std::string name = "e" + std::to_string(e);
        read += readCaseElement(elements[e], e + 1, name);
        const std::string& label =
            e < member.parameters.size() ? member.parameters[e].label : "";
        arguments.push_back(label.empty() ? name : label + ": " + name);
        std::string bound = "p" + std::to_string(e);
        bindings.push_back(bound);
        std::string statement = returnValue(elements[e], "r", bound);
        reports.push_back(elements[e].optional
                              ? "if let " + bound + " { " + statement +
                                    " } else { r.returnNull() }"
                              : statement);
      }
      read +=
          "    return " + value +
          (arguments.empty() ? "" : "(" + llvm::join(arguments, ", ") + ")") +
          "\n";

      std::string pattern =
          value +
          (bindings.empty() ? "" : "(" + llvm::join(bindings, ", ") + ")");
      std::string body = "r.returnCase(" + std::to_string(k) + ") { " +
                         llvm::join(reports, "; ") + " }";
      if (condition.empty()) {
        report += "  case " + std::string(bindings.empty() ? "" : "let ") +
                  pattern + ": " + body + "\n";
      } else {
        // A case pattern cannot be guarded by #available.
        gatedReports += "    if #available(" + condition + "), case " +
                        (bindings.empty() ? "" : "let ") + pattern +
                        " = value { " + body + "; return }\n";
      }
    }
    read += "  default: return nil\n  }\n}\n\n";
    size_t declared = 0;
    for (const auto& id : symbol.memberIds) {
      const Symbol* member = _module.find(id);
      declared += member && member->kind == SymbolKind::EnumCase;
    }
    // Cases JS never sees (unavailable ones) report null.
    report += gatedReports.empty() && declared == cases.size()
                  ? "  @unknown default: r.returnNull()\n"
                  : "  default:\n" + gatedReports + "    r.returnNull()\n";
    report += "  }\n}\n\n";
    return read + report;
  }

  // Lines binding `name` to associated value slot `slot` of `s`, returning
  // nil when it does not convert.
  std::string readCaseElement(const BridgedType& type, size_t slot,
                              const std::string& name) const {
    std::string index = std::to_string(slot);
    ValueExpression value = valueExpression(type, "s", index);
    std::string typeText = valueTypeName(type);
    if (!type.optional) {
      return value.failable ? "    guard let " + name + " = " + value.code +
                                  " else { return nil }\n"
                            : "    let " + name + " = " + value.code + "\n";
    }
    if (!value.failable) {
      return "    let " + name + ": " + typeText + "? = s.isNull(" + index +
             ") ? nil : " + value.code + "\n";
    }
    return "    var " + name + ": " + typeText + "? = nil\n    if !s.isNull(" +
           index + ") {\n      guard let value = " + value.code +
           " else { return nil }\n      " + name + " = value\n    }\n";
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
    std::string out =
        "private func __nsRegister(_ registrar: UnsafeMutableRawPointer) {\n"
        "  let api = registrar.load(as: UnsafeRawPointer.self)\n"
        "  let registerModule = api.load(fromByteOffset: " +
        std::to_string(kRegisterModuleSlot) +
        ", as: (@convention(c) (UnsafeMutableRawPointer, UInt32, "
        "UnsafePointer<CChar>, "
        "UnsafePointer<CChar>, __NSRelease) -> Void).self)\n"
        "  let registerType = api.load(fromByteOffset: " +
        std::to_string(kRegisterTypeSlot) +
        ", as: (@convention(c) (UnsafeMutableRawPointer, UInt32, "
        "UInt32, UnsafePointer<CChar>, UnsafePointer<CChar>, "
        "UnsafePointer<CChar>, Int32) -> Void).self)\n"
        "  let registerMember = api.load(fromByteOffset: " +
        std::to_string(kRegisterMemberSlot) +
        ", as: (@convention(c) (UnsafeMutableRawPointer, Int32, "
        "UInt32, UInt32, UnsafePointer<CChar>, "
        "UnsafePointer<CChar>, UnsafePointer<CChar>, "
        "UnsafePointer<CChar>, __NSThunk?, "
        "__NSThunk?) -> Void).self)\n"
        "  let registerUnitModule = api.load(fromByteOffset: " +
        std::to_string(kRegisterUnitModuleSlot) +
        ", as: (@convention(c) (UnsafeMutableRawPointer, "
        "UnsafePointer<CChar>) -> Void).self)\n\n"
        "  registerModule(registrar, " +
        std::to_string(kThunkABIVersion) + ", " + quoted(_module.name) + ", " +
        quoted(result.fingerprint) + ", __nsRelease)\n";
    for (const auto& name : _module.swiftModules()) {
      out += "  registerUnitModule(registrar, " + quoted(name) + ")\n";
    }
    for (const auto& type : _surface.types) {
      const Symbol& symbol = *type.symbol;
      int kind = type.kind;
      out += "  registerType(registrar, " + std::to_string(type.index) + ", " +
             std::to_string(kind) + ", " + quoted(type.module) + ", " +
             quoted(llvm::join(symbol.pathComponents, ".")) + ", " +
             quoted(qualifiedTypeName(_module, symbol)) + ", " +
             std::to_string(type.superIndex) + ")\n";
    }
    for (const auto& line : _registrations) {
      out += line + "\n";
    }
    out += "}\n";
    for (size_t i = 0; i < result.registerSymbols.size(); i++) {
      const std::string& symbol = result.registerSymbols[i];
      out += "\n#if hasAttribute(c)\n@c(" + symbol + ")\n#else\n@_cdecl(\"" +
             symbol + "\")\n#endif\npublic func __nsRegister_" +
             _module.swiftModules()[i] +
             "(_ registrar: UnsafeMutableRawPointer) {\n  "
             "__nsRegister(registrar)\n}\n";
    }
    return out;
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
