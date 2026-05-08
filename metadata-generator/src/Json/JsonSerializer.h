#pragma once

#include <llvm/Support/FileSystem.h>
#include <llvm/Support/JSON.h>
#include <llvm/Support/raw_ostream.h>

#include <string>

#include "Meta/MetaEntities.h"
#include "Meta/Utils.h"

namespace Json {

static std::string typeTypeToString(Meta::TypeType t) {
  switch (t) {
    case Meta::TypeType::TypeVoid:
      return "Void";
    case Meta::TypeType::TypeBool:
      return "Bool";
    case Meta::TypeType::TypeShort:
      return "Short";
    case Meta::TypeType::TypeUShort:
      return "Ushort";
    case Meta::TypeType::TypeInt:
      return "Int";
    case Meta::TypeType::TypeUInt:
      return "UInt";
    case Meta::TypeType::TypeLong:
      return "Long";
    case Meta::TypeType::TypeULong:
      return "ULong";
    case Meta::TypeType::TypeLongLong:
      return "LongLong";
    case Meta::TypeType::TypeULongLong:
      return "ULongLong";
    case Meta::TypeType::TypeSignedChar:
      return "Char";
    case Meta::TypeType::TypeUnsignedChar:
      return "UChar";
    case Meta::TypeType::TypeUnichar:
      return "Unichar";
    case Meta::TypeType::TypeCString:
      return "CString";
    case Meta::TypeType::TypeFloat:
      return "Float";
    case Meta::TypeType::TypeDouble:
      return "Double";
    case Meta::TypeType::TypeSelector:
      return "Selector";
    case Meta::TypeType::TypeClass:
      return "Class";
    case Meta::TypeType::TypeInstancetype:
      return "Instancetype";
    case Meta::TypeType::TypeId:
      return "Id";
    case Meta::TypeType::TypeConstantArray:
      return "ConstantArray";
    case Meta::TypeType::TypeIncompleteArray:
      return "IncompleteArray";
    case Meta::TypeType::TypeInterface:
      return "Interface";
    case Meta::TypeType::TypeBridgedInterface:
      return "BridgedInterface";
    case Meta::TypeType::TypePointer:
      return "Pointer";
    case Meta::TypeType::TypeFunctionPointer:
      return "FunctionPointer";
    case Meta::TypeType::TypeBlock:
      return "Block";
    case Meta::TypeType::TypeStruct:
      return "Struct";
    case Meta::TypeType::TypeUnion:
      return "Union";
    case Meta::TypeType::TypeAnonymousStruct:
      return "AnonymousStruct";
    case Meta::TypeType::TypeAnonymousUnion:
      return "AnonymousUnion";
    case Meta::TypeType::TypeEnum:
      return "Enum";
    case Meta::TypeType::TypeVaList:
      return "VaList";
    case Meta::TypeType::TypeProtocol:
      return "Protocol";
    case Meta::TypeType::TypeTypeArgument:
      return "TypeArgument";
    case Meta::TypeType::TypeExtVector:
      return "ExtVector";
    case Meta::TypeType::TypeNullable:
      return "Nullable";
    case Meta::TypeType::TypeNonNullable:
      return "NonNullable";
  }
  return "Unknown";
}

static std::string metaTypeToString(Meta::MetaType t) {
  switch (t) {
    case Meta::MetaType::Undefined:
      return "Undefined";
    case Meta::MetaType::Struct:
      return "Struct";
    case Meta::MetaType::Union:
      return "Union";
    case Meta::MetaType::Function:
      return "Function";
    case Meta::MetaType::Enum:
      return "Enum";
    case Meta::MetaType::Var:
      return "Var";
    case Meta::MetaType::Interface:
      return "Interface";
    case Meta::MetaType::Protocol:
      return "Protocol";
    case Meta::MetaType::Category:
      return "Category";
    case Meta::MetaType::Method:
      return "Method";
    case Meta::MetaType::Property:
      return "Property";
    case Meta::MetaType::EnumConstant:
      return "EnumConstant";
  }
  return "Unknown";
}

static llvm::json::Object typeToJson(Meta::Type* type) {
  llvm::json::Object obj;
  obj["Type"] = typeTypeToString(type->getType());

  switch (type->getType()) {
    case Meta::TypeType::TypeId: {
      auto& t = type->as<Meta::IdType>();
      llvm::json::Array protocols;
      for (auto* p : t.protocols) protocols.push_back(p->jsName);
      obj["WithProtocols"] = std::move(protocols);
      break;
    }
    case Meta::TypeType::TypeClass: {
      auto& t = type->as<Meta::ClassType>();
      llvm::json::Array protocols;
      for (auto* p : t.protocols) protocols.push_back(p->jsName);
      if (!protocols.empty()) obj["WithProtocols"] = std::move(protocols);
      break;
    }
    case Meta::TypeType::TypeConstantArray: {
      auto& t = type->as<Meta::ConstantArrayType>();
      obj["ArrayType"] = typeToJson(t.innerType);
      obj["Size"] = t.size;
      break;
    }
    case Meta::TypeType::TypeIncompleteArray: {
      auto& t = type->as<Meta::IncompleteArrayType>();
      obj["ArrayType"] = typeToJson(t.innerType);
      break;
    }
    case Meta::TypeType::TypeInterface: {
      auto& t = type->as<Meta::InterfaceType>();
      obj["Name"] = t.interface->name;
      if (!t.typeArguments.empty()) {
        llvm::json::Array args;
        for (auto* a : t.typeArguments) args.push_back(typeToJson(a));
        obj["TypeParameters"] = std::move(args);
      }
      llvm::json::Array protocols;
      for (auto* p : t.protocols) protocols.push_back(p->jsName);
      obj["WithProtocols"] = std::move(protocols);
      break;
    }
    case Meta::TypeType::TypeBridgedInterface: {
      auto& t = type->as<Meta::BridgedInterfaceType>();
      obj["Name"] = t.name;
      std::string bridgedTo = t.isId() ? "id"
                                       : (t.bridgedInterface == nullptr
                                              ? "[None]"
                                              : t.bridgedInterface->jsName);
      obj["BridgedTo"] = bridgedTo;
      break;
    }
    case Meta::TypeType::TypePointer: {
      auto& t = type->as<Meta::PointerType>();
      obj["PointerType"] = typeToJson(t.innerType);
      break;
    }
    case Meta::TypeType::TypeFunctionPointer: {
      auto& t = type->as<Meta::FunctionPointerType>();
      llvm::json::Array sig;
      for (auto* s : t.signature) sig.push_back(typeToJson(s));
      obj["Signature"] = std::move(sig);
      break;
    }
    case Meta::TypeType::TypeBlock: {
      auto& t = type->as<Meta::BlockType>();
      llvm::json::Array sig;
      for (auto* s : t.signature) sig.push_back(typeToJson(s));
      obj["Signature"] = std::move(sig);
      break;
    }
    case Meta::TypeType::TypeStruct: {
      auto& t = type->as<Meta::StructType>();
      obj["Module"] = t.structMeta->module->getFullModuleName();
      obj["Name"] = t.structMeta->name;
      break;
    }
    case Meta::TypeType::TypeUnion: {
      auto& t = type->as<Meta::UnionType>();
      obj["Module"] = t.unionMeta->module->getFullModuleName();
      obj["Name"] = t.unionMeta->name;
      break;
    }
    case Meta::TypeType::TypeAnonymousStruct: {
      auto& t = type->as<Meta::AnonymousStructType>();
      llvm::json::Array fields;
      for (auto& f : t.fields) {
        llvm::json::Object field;
        field["Name"] = f.name;
        field["Signature"] = typeToJson(f.encoding);
        fields.push_back(std::move(field));
      }
      obj["Fields"] = std::move(fields);
      break;
    }
    case Meta::TypeType::TypeAnonymousUnion: {
      auto& t = type->as<Meta::AnonymousUnionType>();
      llvm::json::Array fields;
      for (auto& f : t.fields) {
        llvm::json::Object field;
        field["Name"] = f.name;
        field["Signature"] = typeToJson(f.encoding);
        fields.push_back(std::move(field));
      }
      obj["Fields"] = std::move(fields);
      break;
    }
    case Meta::TypeType::TypeEnum: {
      auto& t = type->as<Meta::EnumType>();
      obj["Name"] = t.enumMeta->jsName;
      break;
    }
    case Meta::TypeType::TypeTypeArgument: {
      auto& t = type->as<Meta::TypeArgumentType>();
      obj["Name"] = t.name;
      obj["UnderlyingType"] = typeToJson(t.underlyingType);
      llvm::json::Array protocols;
      for (auto* p : t.protocols) protocols.push_back(p->jsName);
      if (!protocols.empty()) obj["WithProtocols"] = std::move(protocols);
      break;
    }
    case Meta::TypeType::TypeExtVector: {
      auto& t = type->as<Meta::ExtVectorType>();
      obj["InnerType"] = typeToJson(t.innerType);
      obj["Size"] = t.size;
      break;
    }
    case Meta::TypeType::TypeNullable: {
      auto& t = type->as<Meta::NullableType>();
      obj["InnerType"] = typeToJson(t.innerType);
      break;
    }
    case Meta::TypeType::TypeNonNullable: {
      auto& t = type->as<Meta::NonNullableType>();
      obj["InnerType"] = typeToJson(t.innerType);
      break;
    }
    default:
      break;
  }
  return obj;
}

static llvm::json::Array flagsToJson(Meta::MetaFlags flags) {
  llvm::json::Array arr;
  if (flags & Meta::MetaFlags::IsIosAppExtensionAvailable)
    arr.push_back("IsIosAppExtensionAvailable");
  if (flags & Meta::MetaFlags::MemberIsOptional)
    arr.push_back("MemberIsOptional");
  if (flags & Meta::MetaFlags::FunctionIsVariadic)
    arr.push_back("FunctionIsVariadic");
  if (flags & Meta::MetaFlags::FunctionOwnsReturnedCocoaObject)
    arr.push_back("FunctionOwnsReturnedCocoaObject");
  if (flags & Meta::MetaFlags::FunctionReturnsUnmanaged)
    arr.push_back("FunctionReturnsUnmanaged");
  if (flags & Meta::MetaFlags::MethodIsVariadic)
    arr.push_back("MethodIsVariadic");
  if (flags & Meta::MetaFlags::MethodIsNullTerminatedVariadic)
    arr.push_back("MethodIsNullTerminatedVariadic");
  if (flags & Meta::MetaFlags::MethodOwnsReturnedCocoaObject)
    arr.push_back("MethodOwnsReturnedCocoaObject");
  if (flags & Meta::MetaFlags::MethodHasErrorOutParameter)
    arr.push_back("MethodHasErrorOutParameter");
  if (flags & Meta::MetaFlags::MethodIsInitializer)
    arr.push_back("MethodIsInitializer");
  return arr;
}

static void mapBaseMetaJson(llvm::json::Object& obj, Meta::Meta* meta) {
  obj["Name"] = meta->name;
  obj["JsName"] = meta->jsName;
  if (!meta->demangledName.empty()) obj["DemangledName"] = meta->demangledName;
  obj["Filename"] = meta->fileName;
  obj["Module"] = meta->module ? meta->module->getFullModuleName() : "";
  if (!meta->introducedIn.isUnknown())
    obj["IntroducedIn"] = meta->introducedIn.toString();
  obj["Flags"] = flagsToJson(meta->flags);
  obj["Type"] = metaTypeToString(meta->type);
}

static llvm::json::Object methodToJson(Meta::MethodMeta* meta) {
  llvm::json::Object obj;
  mapBaseMetaJson(obj, meta);
  llvm::json::Array sig;
  for (auto* t : meta->signature) sig.push_back(typeToJson(t));
  obj["Signature"] = std::move(sig);
  return obj;
}

static llvm::json::Object propertyToJson(Meta::PropertyMeta* meta) {
  llvm::json::Object obj;
  mapBaseMetaJson(obj, meta);
  if (meta->getter) obj["Getter"] = methodToJson(meta->getter);
  if (meta->setter) obj["Setter"] = methodToJson(meta->setter);
  return obj;
}

static void mapBaseClassMetaJson(llvm::json::Object& obj,
                                 Meta::BaseClassMeta* meta) {
  mapBaseMetaJson(obj, meta);

  llvm::json::Array instanceMethods;
  for (auto* m : meta->instanceMethods)
    instanceMethods.push_back(methodToJson(m));
  obj["InstanceMethods"] = std::move(instanceMethods);

  llvm::json::Array staticMethods;
  for (auto* m : meta->staticMethods) staticMethods.push_back(methodToJson(m));
  obj["StaticMethods"] = std::move(staticMethods);

  llvm::json::Array instanceProperties;
  for (auto* p : meta->instanceProperties)
    instanceProperties.push_back(propertyToJson(p));
  obj["InstanceProperties"] = std::move(instanceProperties);

  llvm::json::Array staticProperties;
  for (auto* p : meta->staticProperties)
    staticProperties.push_back(propertyToJson(p));
  obj["StaticProperties"] = std::move(staticProperties);

  llvm::json::Array protocols;
  for (auto* p : meta->protocols) protocols.push_back(p->jsName);
  obj["Protocols"] = std::move(protocols);
}

static llvm::json::Object metaToJson(Meta::Meta* meta) {
  llvm::json::Object obj;

  switch (meta->type) {
    case Meta::MetaType::Function: {
      auto& m = meta->as<Meta::FunctionMeta>();
      mapBaseMetaJson(obj, meta);
      llvm::json::Array sig;
      for (auto* t : m.signature) sig.push_back(typeToJson(t));
      obj["Signature"] = std::move(sig);
      break;
    }
    case Meta::MetaType::Struct: {
      auto& m = meta->as<Meta::StructMeta>();
      auto& rec = m.as<Meta::RecordMeta>();
      mapBaseMetaJson(obj, meta);
      llvm::json::Array fields;
      for (auto& f : rec.fields) {
        llvm::json::Object field;
        field["Name"] = f.name;
        field["Signature"] = typeToJson(f.encoding);
        fields.push_back(std::move(field));
      }
      obj["Fields"] = std::move(fields);
      break;
    }
    case Meta::MetaType::Union: {
      auto& m = meta->as<Meta::UnionMeta>();
      auto& rec = m.as<Meta::RecordMeta>();
      mapBaseMetaJson(obj, meta);
      llvm::json::Array fields;
      for (auto& f : rec.fields) {
        llvm::json::Object field;
        field["Name"] = f.name;
        field["Signature"] = typeToJson(f.encoding);
        fields.push_back(std::move(field));
      }
      obj["Fields"] = std::move(fields);
      break;
    }
    case Meta::MetaType::Var: {
      auto& m = meta->as<Meta::VarMeta>();
      mapBaseMetaJson(obj, meta);
      obj["Signature"] = typeToJson(m.signature);
      if (m.hasValue) obj["Value"] = m.value;
      break;
    }
    case Meta::MetaType::Enum: {
      auto& m = meta->as<Meta::EnumMeta>();
      mapBaseMetaJson(obj, meta);
      llvm::json::Array fullNameFields;
      for (auto& f : m.fullNameFields) {
        llvm::json::Object field;
        field[f.name] = f.value;
        fullNameFields.push_back(std::move(field));
      }
      obj["FullNameFields"] = std::move(fullNameFields);
      llvm::json::Array swiftNameFields;
      for (auto& f : m.swiftNameFields) {
        llvm::json::Object field;
        field[f.name] = f.value;
        swiftNameFields.push_back(std::move(field));
      }
      obj["SwiftNameFields"] = std::move(swiftNameFields);
      break;
    }
    case Meta::MetaType::EnumConstant: {
      auto& m = meta->as<Meta::EnumConstantMeta>();
      mapBaseMetaJson(obj, meta);
      obj["Value"] = m.value;
      break;
    }
    case Meta::MetaType::Interface: {
      auto& m = meta->as<Meta::InterfaceMeta>();
      auto& bc = m.as<Meta::BaseClassMeta>();
      mapBaseClassMetaJson(obj, &bc);
      if (m.base != nullptr) obj["Base"] = m.base->jsName;
      break;
    }
    case Meta::MetaType::Protocol: {
      auto& m = meta->as<Meta::ProtocolMeta>();
      auto& bc = m.as<Meta::BaseClassMeta>();
      mapBaseClassMetaJson(obj, &bc);
      break;
    }
    case Meta::MetaType::Category: {
      auto& m = meta->as<Meta::CategoryMeta>();
      auto& bc = m.as<Meta::BaseClassMeta>();
      mapBaseClassMetaJson(obj, &bc);
      if (m.extendedInterface)
        obj["ExtendedInterface"] = m.extendedInterface->jsName;
      break;
    }
    case Meta::MetaType::Method: {
      auto& m = meta->as<Meta::MethodMeta>();
      obj = methodToJson(&m);
      break;
    }
    case Meta::MetaType::Property: {
      auto& m = meta->as<Meta::PropertyMeta>();
      obj = propertyToJson(&m);
      break;
    }
    default:
      mapBaseMetaJson(obj, meta);
      break;
  }
  return obj;
}

static llvm::json::Object moduleToJson(
    std::pair<clang::Module*, std::vector<Meta::Meta*>>& modulePair) {
  llvm::json::Object root;

  // Module info
  llvm::json::Object moduleObj;
  moduleObj["FullName"] = modulePair.first->getFullModuleName();
  moduleObj["IsPartOfFramework"] = modulePair.first->isPartOfFramework();
  moduleObj["IsSystemModule"] = modulePair.first->IsSystem;
  std::vector<clang::Module::LinkLibrary> libs;
  Meta::Utils::getAllLinkLibraries(modulePair.first, libs);
  llvm::json::Array libsArr;
  for (auto& lib : libs) {
    llvm::json::Object libObj;
    libObj["Library"] = lib.Library;
    libObj["IsFramework"] = lib.IsFramework;
    libsArr.push_back(std::move(libObj));
  }
  moduleObj["Libraries"] = std::move(libsArr);
  root["Module"] = std::move(moduleObj);

  // Items
  llvm::json::Array items;
  for (auto* meta : modulePair.second) items.push_back(metaToJson(meta));
  root["Items"] = std::move(items);

  return root;
}

class JsonSerializer {
 public:
  static void serialize(
      const std::string& outputFilePath,
      std::pair<clang::Module*, std::vector<Meta::Meta*>>& modulePair) {
    std::error_code errorCode;
    llvm::raw_fd_ostream fileStream(outputFilePath, errorCode,
                                    llvm::sys::fs::OpenFlags::OF_None);
    if (errorCode)
      throw std::runtime_error(std::string("Unable to open file ") +
                               outputFilePath + ".");

    llvm::json::Object root = moduleToJson(modulePair);
    fileStream << llvm::formatv("{0:2}", llvm::json::Value(std::move(root)));
    fileStream.close();
  }
};

}  // namespace Json
