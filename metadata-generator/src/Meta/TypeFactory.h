#pragma once

#include "MetaEntities.h"
#include "TypeEntities.h"
#include <clang/AST/RecursiveASTVisitor.h>
#include <unordered_map>

namespace Meta {
class MetaFactory;

class TypeFactory {
public:
    TypeFactory(MetaFactory* metaFactory)
        : _metaFactory(metaFactory)
        , _cache()
    {
    }

    static std::shared_ptr<Type> getVoid();

    static std::shared_ptr<Type> getBool();

    static std::shared_ptr<Type> getShort();

    static std::shared_ptr<Type> getUShort();

    static std::shared_ptr<Type> getInt();

    static std::shared_ptr<Type> getUInt();

    static std::shared_ptr<Type> getLong();

    static std::shared_ptr<Type> getULong();

    static std::shared_ptr<Type> getLongLong();

    static std::shared_ptr<Type> getULongLong();

    static std::shared_ptr<Type> getSignedChar();

    static std::shared_ptr<Type> getUnsignedChar();

    static std::shared_ptr<Type> getUnichar();

    static std::shared_ptr<Type> getCString();

    static std::shared_ptr<Type> getFloat();

    static std::shared_ptr<Type> getDouble();

    static std::shared_ptr<Type> getVaList();

    static std::shared_ptr<Type> getSelector();

    static std::shared_ptr<Type> getInstancetype();

    static std::shared_ptr<Type> getProtocolType();

    std::shared_ptr<Type> create(const clang::Type* type);

    std::shared_ptr<Type> create(const clang::QualType& type);

    void resolveCachedBridgedInterfaceTypes(std::unordered_map<std::string, InterfaceMeta*>& interfaceMap);

private:
    std::shared_ptr<ConstantArrayType> createFromConstantArrayType(const clang::ConstantArrayType* type);

    std::shared_ptr<IncompleteArrayType> createFromIncompleteArrayType(const clang::IncompleteArrayType* type);

    std::shared_ptr<BlockType> createFromBlockPointerType(const clang::BlockPointerType* type);

    std::shared_ptr<Type> createFromBuiltinType(const clang::BuiltinType* type);

    std::shared_ptr<Type> createFromObjCObjectPointerType(const clang::ObjCObjectPointerType* type);

    std::shared_ptr<Type> createFromPointerType(const clang::PointerType* type);

    std::shared_ptr<Type> createFromEnumType(const clang::EnumType* type);

    std::shared_ptr<Type> createFromRecordType(const clang::RecordType* type);

    std::shared_ptr<Type> createFromTypedefType(const clang::TypedefType* type);
    
    std::shared_ptr<Type> createFromExtVectorType(const clang::ExtVectorType* type);

    std::shared_ptr<Type> createFromVectorType(const clang::VectorType* type);

    std::shared_ptr<Type> createFromElaboratedType(const clang::ElaboratedType* type);

    std::shared_ptr<Type> createFromAdjustedType(const clang::AdjustedType* type);

    std::shared_ptr<Type> createFromFunctionProtoType(const clang::FunctionProtoType* type);

    std::shared_ptr<Type> createFromFunctionNoProtoType(const clang::FunctionNoProtoType* type);

    std::shared_ptr<Type> createFromParenType(const clang::ParenType* type);

    std::shared_ptr<Type> createFromAttributedType(const clang::AttributedType* type);

    std::shared_ptr<Type> createFromObjCTypeParamType(const clang::ObjCTypeParamType* type);

    // helpers
    bool isSpecificTypedefType(const clang::TypedefType* type, const std::string& typedefName);

    bool isSpecificTypedefType(const clang::TypedefType* type, const std::vector<std::string>& typedefNames);

    MetaFactory* _metaFactory;
    typedef std::unordered_map<const clang::Type*, std::pair<std::shared_ptr<Type>, std::string> > Cache;
    Cache _cache;
};
}
