#include "TypeFactory.h"
#include "CreationException.h"
#include "MetaFactory.h"
#include "Utils.h"
#include <llvm/ADT/STLExtras.h>

namespace Meta {
using namespace std;

static const std::vector<std::string> KNOWN_BRIDGED_TYPES = {
#define CF_TYPE(NAME) #NAME,
#define NON_CF_TYPE(NAME)
#include "CFDatabase.def"
#undef CF_TYPE
#undef NON_CF_TYPE
};

shared_ptr<Type> TypeFactory::getVoid()
{
    static shared_ptr<Type> type(new Type(TypeType::TypeVoid));
    return type;
}

shared_ptr<Type> TypeFactory::getBool()
{
    static shared_ptr<Type> type(new Type(TypeType::TypeBool));
    return type;
}

shared_ptr<Type> TypeFactory::getShort()
{
    static shared_ptr<Type> type(new Type(TypeType::TypeShort));
    return type;
}

shared_ptr<Type> TypeFactory::getUShort()
{
    static shared_ptr<Type> type(new Type(TypeType::TypeUShort));
    return type;
}

shared_ptr<Type> TypeFactory::getInt()
{
    static shared_ptr<Type> type(new Type(TypeType::TypeInt));
    return type;
}

shared_ptr<Type> TypeFactory::getUInt()
{
    static shared_ptr<Type> type(new Type(TypeType::TypeUInt));
    return type;
}

shared_ptr<Type> TypeFactory::getLong()
{
    static shared_ptr<Type> type(new Type(TypeType::TypeLong));
    return type;
}

shared_ptr<Type> TypeFactory::getULong()
{
    static shared_ptr<Type> type(new Type(TypeType::TypeULong));
    return type;
}

shared_ptr<Type> TypeFactory::getLongLong()
{
    static shared_ptr<Type> type(new Type(TypeType::TypeLongLong));
    return type;
}

shared_ptr<Type> TypeFactory::getULongLong()
{
    static shared_ptr<Type> type(new Type(TypeType::TypeULongLong));
    return type;
}

shared_ptr<Type> TypeFactory::getSignedChar()
{
    static shared_ptr<Type> type(new Type(TypeType::TypeSignedChar));
    return type;
}

shared_ptr<Type> TypeFactory::getUnsignedChar()
{
    static shared_ptr<Type> type(new Type(TypeType::TypeUnsignedChar));
    return type;
}

shared_ptr<Type> TypeFactory::getUnichar()
{
    static shared_ptr<Type> type(new Type(TypeType::TypeUnichar));
    return type;
}

shared_ptr<Type> TypeFactory::getCString()
{
    static shared_ptr<Type> type(new Type(TypeType::TypeCString));
    return type;
}

shared_ptr<Type> TypeFactory::getFloat()
{
    static shared_ptr<Type> type(new Type(TypeType::TypeFloat));
    return type;
}

shared_ptr<Type> TypeFactory::getDouble()
{
    static shared_ptr<Type> type(new Type(TypeType::TypeDouble));
    return type;
}

shared_ptr<Type> TypeFactory::getVaList()
{
    static shared_ptr<Type> type(new Type(TypeType::TypeVaList));
    return type;
}

shared_ptr<Type> TypeFactory::getSelector()
{
    static shared_ptr<Type> type(new Type(TypeType::TypeSelector));
    return type;
}

shared_ptr<Type> TypeFactory::getInstancetype()
{
    static shared_ptr<Type> type(new Type(TypeType::TypeInstancetype));
    return type;
}

shared_ptr<Type> TypeFactory::getProtocolType()
{
    static shared_ptr<Type> type(new Type(TypeType::TypeProtocol));
    return type;
}

shared_ptr<Type> TypeFactory::create(const clang::Type* type)
{
    const clang::Type& typeRef = *type;
    shared_ptr<Type> resultType(nullptr);
    
    try {
        // check for cached Type
        unordered_map<const clang::Type*, pair<shared_ptr<Type>, string> >::const_iterator cachedTypeIt = _cache.find(type);
        if (cachedTypeIt != _cache.end()) {
            shared_ptr<Type> resultType = cachedTypeIt->second.first;
            string errorMessage = cachedTypeIt->second.second;
            if (errorMessage.empty()) {
                // revalidate in case the Type's metadata creation has failed after it was returned
                // (e.g. from a forward declaration)
                this->_metaFactory->validate(resultType.get());
                
                return resultType;
            }
            throw TypeCreationException(type, errorMessage, false);
        }

        if (const clang::BuiltinType* concreteType = clang::dyn_cast<clang::BuiltinType>(type))
            resultType = createFromBuiltinType(concreteType);
        else if (const clang::TypedefType* concreteType = clang::dyn_cast<clang::TypedefType>(type))
            resultType = createFromTypedefType(concreteType);
        else if (const clang::ObjCObjectPointerType* concreteType = clang::dyn_cast<clang::ObjCObjectPointerType>(type))
            resultType = createFromObjCObjectPointerType(concreteType);
        else if (const clang::EnumType* concreteType = clang::dyn_cast<clang::EnumType>(type))
            resultType = createFromEnumType(concreteType);
        else if (const clang::PointerType* concreteType = clang::dyn_cast<clang::PointerType>(type))
            resultType = createFromPointerType(concreteType);
        else if (const clang::BlockPointerType* concreteType = clang::dyn_cast<clang::BlockPointerType>(type))
            resultType = createFromBlockPointerType(concreteType);
        else if (const clang::RecordType* concreteType = clang::dyn_cast<clang::RecordType>(type))
            resultType = createFromRecordType(concreteType);
        else if (const clang::ExtVectorType* concreteType = clang::dyn_cast<clang::ExtVectorType>(type))
            resultType = createFromExtVectorType(concreteType);
        else if (const clang::VectorType* concreteType = clang::dyn_cast<clang::VectorType>(type))
            resultType = createFromVectorType(concreteType);
        else if (const clang::ConstantArrayType* concreteType = clang::dyn_cast<clang::ConstantArrayType>(type))
            resultType = createFromConstantArrayType(concreteType);
        else if (const clang::IncompleteArrayType* concreteType = clang::dyn_cast<clang::IncompleteArrayType>(type))
            resultType = createFromIncompleteArrayType(concreteType);
        else if (const clang::ElaboratedType* concreteType = clang::dyn_cast<clang::ElaboratedType>(type))
            resultType = createFromElaboratedType(concreteType);
        else if (const clang::AdjustedType* concreteType = clang::dyn_cast<clang::AdjustedType>(type))
            resultType = createFromAdjustedType(concreteType);
        else if (const clang::FunctionProtoType* concreteType = clang::dyn_cast<clang::FunctionProtoType>(type))
            resultType = createFromFunctionProtoType(concreteType);
        else if (const clang::FunctionNoProtoType* concreteType = clang::dyn_cast<clang::FunctionNoProtoType>(type))
            resultType = createFromFunctionNoProtoType(concreteType);
        else if (const clang::ParenType* concreteType = clang::dyn_cast<clang::ParenType>(type))
            resultType = createFromParenType(concreteType);
        else if (const clang::AttributedType* concreteType = clang::dyn_cast<clang::AttributedType>(type))
            resultType = createFromAttributedType(concreteType);
        else if (const clang::ObjCTypeParamType* concreteType = clang::dyn_cast<clang::ObjCTypeParamType>(type))
            resultType = createFromObjCTypeParamType(concreteType);
        else
            throw TypeCreationException(type, "Unable to create encoding for this type.", true);
    }
    catch (TypeCreationException& e) {
        if (e.getType() == type) {
            _cache.insert(make_pair<Cache::key_type, Cache::mapped_type>(&typeRef, make_pair<shared_ptr<Type>, string>(nullptr, e.getMessage())));
            throw;
        };
        pair<Cache::iterator, bool> insertionResult = _cache.insert(make_pair<Cache::key_type, Cache::mapped_type>(&typeRef, make_pair<shared_ptr<Type>, string>(nullptr, "")));
        string message = CreationException::constructMessage("Can't create type dependency.", e.getDetailedMessage());
        insertionResult.first->second.second = message;
        throw TypeCreationException(type, message, e.isError());
    }
    catch (MetaCreationException& e) {
        pair<Cache::iterator, bool> insertionResult = _cache.insert(make_pair<Cache::key_type, Cache::mapped_type>(&typeRef, make_pair<shared_ptr<Type>, string>(nullptr, "")));
        string message = CreationException::constructMessage("Can't create meta dependency.", e.getDetailedMessage());
        insertionResult.first->second.second = message;
        throw TypeCreationException(type, message, e.isError());
    }
    
    assert(resultType != nullptr);
    pair<Cache::iterator, bool> insertionResult = _cache.insert(make_pair<Cache::key_type, Cache::mapped_type>(&typeRef, make_pair<shared_ptr<Type>, string>(nullptr, "")));
    if (insertionResult.second) {
        assert(insertionResult.first->second.first.get() == nullptr);
        insertionResult.first->second.first = resultType;
        return resultType;
    }
    else {
        return insertionResult.first->second.first;
    }
}

shared_ptr<Type> TypeFactory::create(const clang::QualType& type)
{
    const clang::Type* typePtr = type.getTypePtrOrNull();
    if (typePtr)
        return this->create(typePtr);
    throw TypeCreationException(nullptr, "Unable to get the inner type of qualified type.", true);
}

shared_ptr<ConstantArrayType> TypeFactory::createFromConstantArrayType(const clang::ConstantArrayType* type)
{
    return make_shared<ConstantArrayType>(this->create(type->getElementType()).get(), (int)type->getSize().roundToDouble());
}

shared_ptr<IncompleteArrayType> TypeFactory::createFromIncompleteArrayType(const clang::IncompleteArrayType* type)
{
    return make_shared<IncompleteArrayType>(this->create(type->getElementType()).get());
}

shared_ptr<BlockType> TypeFactory::createFromBlockPointerType(const clang::BlockPointerType* type)
{
    const clang::Type* pointee = type->getPointeeType().getTypePtr();
    Type* pointeeType = this->create(pointee).get();
    assert(pointeeType->is(TypeType::TypeFunctionPointer));
    return make_shared<BlockType>(pointeeType->as<FunctionPointerType>().signature);
}

shared_ptr<Type> TypeFactory::createFromBuiltinType(const clang::BuiltinType* type)
{
    switch (type->getKind()) {
    case clang::BuiltinType::Kind::Void:
        return TypeFactory::getVoid();
    case clang::BuiltinType::Kind::Bool:
        return TypeFactory::getBool();
    case clang::BuiltinType::Kind::Char_S:
    case clang::BuiltinType::Kind::Char_U:
    case clang::BuiltinType::Kind::SChar:
        return TypeFactory::getSignedChar();
    case clang::BuiltinType::Kind::Short:
        return TypeFactory::getShort();
    case clang::BuiltinType::Kind::Int:
        return TypeFactory::getInt();
    case clang::BuiltinType::Kind::Long:
        return TypeFactory::getLong();
    case clang::BuiltinType::Kind::LongLong:
        return TypeFactory::getLongLong();
    case clang::BuiltinType::Kind::UChar: 
        return TypeFactory::getUnsignedChar();
    case clang::BuiltinType::Kind::UShort:
        return TypeFactory::getUShort();
    case clang::BuiltinType::Kind::UInt:
        return TypeFactory::getUInt();
    case clang::BuiltinType::Kind::ULong:
        return TypeFactory::getULong();
    case clang::BuiltinType::Kind::ULongLong:
        return TypeFactory::getULongLong();
    case clang::BuiltinType::Kind::Float:
        return TypeFactory::getFloat();
    case clang::BuiltinType::Kind::Double:
        return TypeFactory::getDouble();
    // Objective-C does not support the long double type. @encode(long double) returns d, which is the same encoding as for double.
    case clang::BuiltinType::Kind::LongDouble:
        return TypeFactory::getDouble();

    // ObjCSel, ObjCId and ObjCClass builtin types should never enter in this method because these types should be handled on upper level.
    // The 'SEL' type is represented as pointer to BuiltinType of kind ObjCSel.
    // The 'id' type is actually represented by clang as TypedefType to ObjCObjectPointerType whose pointee is an ObjCObjectType with base BuiltinType::ObjCIdType.
    // This is also valid for ObjCClass type.

    default:
        throw TypeCreationException(type, string("Not supported builtin type(") + type->getTypeClassName() + ").", true);
    }
}

shared_ptr<Type> TypeFactory::createFromObjCObjectPointerType(const clang::ObjCObjectPointerType* type)
{
    vector<ProtocolMeta*> protocols;
    for (clang::ObjCProtocolDecl* qual : type->quals()) {
        clang::ObjCProtocolDecl* protocolDef = qual->getDefinition();
        Meta* protocolMeta = nullptr;
        if (protocolDef != nullptr && _metaFactory->tryCreate(*protocolDef, &protocolMeta)) {
            assert(protocolMeta->is(MetaType::Protocol));
            protocols.push_back(&protocolMeta->as<ProtocolMeta>());
        }
    }
    if (type->isObjCIdType() || type->isObjCQualifiedIdType()) {
        return make_shared<IdType>(protocols);
    }
    if (type->isObjCClassType() || type->isObjCQualifiedClassType()) {
        return make_shared<ClassType>(protocols);
    }

    if (clang::ObjCInterfaceDecl* interface = type->getObjectType()->getInterface()) {
        if (interface->getNameAsString() == "Protocol") {
            return TypeFactory::getProtocolType();
        }
        else if (clang::ObjCInterfaceDecl* interfaceDef = interface->getDefinition()) {
            vector<Type*> typeArguments;
            for (const clang::QualType& typeArg : type->getTypeArgsAsWritten()) {

                typeArguments.push_back(this->create(typeArg).get());
            }
            return make_shared<InterfaceType>(&_metaFactory->create(*interfaceDef)->as<InterfaceMeta>(), protocols, typeArguments);
        }
    }

    throw TypeCreationException(type, "Invalid interface pointer type.", true);
}

shared_ptr<Type> TypeFactory::createFromPointerType(const clang::PointerType* type)
{
    clang::QualType qualPointee = type->getPointeeType();
    const clang::Type* pointee = qualPointee.getTypePtr();
    const clang::Type* canonicalPointee = pointee->getCanonicalTypeInternal().getTypePtr();

    if (const clang::BuiltinType* builtinType = clang::dyn_cast<clang::BuiltinType>(canonicalPointee)) {
        if (builtinType->getKind() == clang::BuiltinType::Kind::ObjCSel)
            return TypeFactory::getSelector();
        if (builtinType->getKind() == clang::BuiltinType::Kind::Char_S || builtinType->getKind() == clang::BuiltinType::Kind::UChar)
            return TypeFactory::getCString();
    }

    // if is a FunctionPointerType don't wrap the type in another pointer type
    if (clang::isa<clang::ParenType>(pointee)) {
        return this->create(qualPointee);
    }

    return make_shared<PointerType>(this->create(qualPointee).get());
}

shared_ptr<Type> TypeFactory::createFromEnumType(const clang::EnumType* type)
{
    Type* innerType = this->create(type->getDecl()->getIntegerType()).get();
    EnumMeta* enumMeta = &this->_metaFactory->create(*type->getDecl()->getDefinition())->as<EnumMeta>();
    return make_shared<EnumType>(innerType, enumMeta);
}

shared_ptr<Type> TypeFactory::createFromRecordType(const clang::RecordType* type)
{
    
    clang::RecordDecl* recordDef = type->getDecl()->getDefinition();
    if (!recordDef) {
        return TypeFactory::getVoid();
    }
    if (recordDef->isUnion())
        throw TypeCreationException(type, "The record is an union.", true);
    if (!recordDef->isStruct())
        throw TypeCreationException(type, "The record is not a struct.", true);
    const clang::TagDecl* tagDecl = clang::dyn_cast<clang::TagDecl>(type->getDecl());
    if (MetaFactory::getTypedefOrOwnName(tagDecl) == "") {
        // The record is anonymous
        vector<RecordField> fields;
        for (clang::FieldDecl* field : recordDef->fields()) {
            RecordField fieldMeta(field->getNameAsString(), this->create(field->getType()).get());
            fields.push_back(fieldMeta);
        }
        return make_shared<AnonymousStructType>(fields);
    }

    return make_shared<StructType>(&_metaFactory->create(*recordDef)->as<StructMeta>());
}

static shared_ptr<Type> tryCreateFromBridgedType(const clang::Type* type)
{
    if (const clang::PointerType* pointerType = clang::dyn_cast<clang::PointerType>(type)) {
        const clang::Type* pointee = pointerType->getPointeeType().getTypePtr();

        // Check for pointer to toll-free bridged types
        if (const clang::ElaboratedType* elaboratedType = clang::dyn_cast<clang::ElaboratedType>(pointee)) {
            if (const clang::TagType* tagType = clang::dyn_cast<clang::TagType>(elaboratedType->desugar().getTypePtr())) {
                const clang::TagDecl* tagDecl = tagType->getDecl();

                if (clang::ObjCBridgeMutableAttr* bridgeMutableAttr = tagDecl->getAttr<clang::ObjCBridgeMutableAttr>()) {
                    string name = bridgeMutableAttr->getBridgedType()->getName().str();
                    return make_shared<BridgedInterfaceType>(name, nullptr);
                }

                if (clang::ObjCBridgeAttr* bridgeAttr = tagDecl->getAttr<clang::ObjCBridgeAttr>()) {
                    string name = bridgeAttr->getBridgedType()->getName().str();
                    return make_shared<BridgedInterfaceType>(name, nullptr);
                }
            }
        }
    }

    return nullptr;
}

shared_ptr<Type> TypeFactory::createFromTypedefType(const clang::TypedefType* type)
{
    vector<string> boolTypedefs{ "BOOL", "Boolean", "bool"};
    if (isSpecificTypedefType(type, boolTypedefs))
        return TypeFactory::getBool();
    if (isSpecificTypedefType(type, "unichar"))
        return TypeFactory::getUnichar();
    if (isSpecificTypedefType(type, "__builtin_va_list"))
        throw TypeCreationException(type, "VaList type is not supported.", true);
    if (auto bridgedInterfaceType = tryCreateFromBridgedType(type->getDecl()->getUnderlyingType().getTypePtrOrNull())) {
        return bridgedInterfaceType;
    }
    if (isSpecificTypedefType(type, KNOWN_BRIDGED_TYPES)) {
        return make_shared<BridgedInterfaceType>("id", nullptr);
    }
    return this->create(type->getDecl()->getUnderlyingType());
}
    
shared_ptr<Type> TypeFactory::createFromExtVectorType(const clang::ExtVectorType* type)
{
    return make_shared<ExtVectorType>(this->create(type->getElementType()).get(), type->getNumElements());
}

shared_ptr<Type> TypeFactory::createFromVectorType(const clang::VectorType* type)
{
    throw TypeCreationException(type, "Vector type is not supported.", true);
}

shared_ptr<Type> TypeFactory::createFromElaboratedType(const clang::ElaboratedType* type)
{
    return this->create(type->getNamedType());
}

shared_ptr<Type> TypeFactory::createFromAdjustedType(const clang::AdjustedType* type)
{
    return this->create(type->getOriginalType());
}

shared_ptr<Type> TypeFactory::createFromFunctionProtoType(const clang::FunctionProtoType* type)
{
    vector<Type*> signature;
    signature.push_back(this->create(type->getReturnType()).get());
    for (const clang::QualType& parm : type->param_types())
        signature.push_back(this->create(parm).get());
    return make_shared<FunctionPointerType>(signature);
}

shared_ptr<Type> TypeFactory::createFromFunctionNoProtoType(const clang::FunctionNoProtoType* type)
{
    vector<Type*> signature;
    signature.push_back(this->create(type->getReturnType()).get());
    return make_shared<FunctionPointerType>(signature);
}

shared_ptr<Type> TypeFactory::createFromParenType(const clang::ParenType* type)
{
    return this->create(type->desugar().getTypePtr());
}

shared_ptr<Type> TypeFactory::createFromAttributedType(const clang::AttributedType* type)
{
    return this->create(type->getModifiedType());
}

shared_ptr<Type> TypeFactory::createFromObjCTypeParamType(const clang::ObjCTypeParamType* type)
{
    clang::ObjCTypeParamDecl* typeParamDecl = type->getDecl();

    vector<ProtocolMeta*> protocols;
    for (clang::ObjCProtocolDecl* decl : type->getProtocols()) {
        clang::ObjCProtocolDecl* protocolDef = decl->getDefinition();
        Meta* protocolMeta = nullptr;
        if (protocolDef != nullptr && _metaFactory->tryCreate(*protocolDef, &protocolMeta)) {
            assert(protocolMeta->is(MetaType::Protocol));
            protocols.push_back(&protocolMeta->as<ProtocolMeta>());
        }
    }

    return make_shared<TypeArgumentType>(this->create(typeParamDecl->getUnderlyingType()).get(), typeParamDecl->getNameAsString(), protocols);
}

bool TypeFactory::isSpecificTypedefType(const clang::TypedefType* type, const string& typedefName)
{
    const vector<string> typedefNames{ typedefName };
    return this->isSpecificTypedefType(type, typedefNames);
}

bool TypeFactory::isSpecificTypedefType(const clang::TypedefType* type, const vector<string>& typedefNames)
{
    clang::TypedefNameDecl* decl = type->getDecl();
    while (decl) {
        if (find(typedefNames.begin(), typedefNames.end(), decl->getNameAsString()) != typedefNames.end()) {
            return true;
        }

        clang::Type const* innerType = decl->getUnderlyingType().getTypePtr();
        if (const clang::TypedefType* innerTypedef = clang::dyn_cast<clang::TypedefType>(innerType)) {
            decl = innerTypedef->getDecl();
        }
        else {
            return false;
        }
    }
    return false;
}

void TypeFactory::resolveCachedBridgedInterfaceTypes(unordered_map<string, InterfaceMeta*>& interfaceMap)
{
    unordered_map<string, InterfaceMeta*>::const_iterator nsObjectIt = interfaceMap.find("NSObject");
    for (Cache::value_type& typeEntry : _cache) {
        if (typeEntry.second.second.empty()) {
            Type* type = typeEntry.second.first.get();
            if (type->is(TypeType::TypeBridgedInterface)) {
                BridgedInterfaceType* bridgedType = &type->as<BridgedInterfaceType>();
                if (!bridgedType->isId()) {
                    unordered_map<string, InterfaceMeta*>::const_iterator it = interfaceMap.find(bridgedType->name);
                    if (it != interfaceMap.end()) {
                        bridgedType->bridgedInterface = it->second;
                    }
                    else {
                        assert(nsObjectIt != interfaceMap.end());
                        bridgedType->bridgedInterface = nsObjectIt->second;
                        cout << "Unable to resolve bridged interface type. Interface " << bridgedType->name << " not found. NSObject used instead." << endl;
                    }
                }
            }
        }
    }
}
}
