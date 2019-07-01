//
//  NameRetrieverVisitor.h
//  objc-metadata-generator
//
//  Created by Martin Bekchiev on 3.09.18.
//

#ifndef NameRetrieverVisitor_h
#define NameRetrieverVisitor_h

#include "TypeEntities.h"
#include "TypeVisitor.h"
#include <string>

using namespace Meta;

class NameRetrieverVisitor : public ::Meta::TypeVisitor<std::string> {
    
public:
    static NameRetrieverVisitor instanceObjC;
    static NameRetrieverVisitor instanceTs;

    virtual std::string visitVoid();
    
    virtual std::string visitBool();
    
    virtual std::string visitShort();
    
    virtual std::string visitUShort();
    
    virtual std::string visitInt();
    
    virtual std::string visitUInt();
    
    virtual std::string visitLong();
    
    virtual std::string visitUlong();
    
    virtual std::string visitLongLong();
    
    virtual std::string visitULongLong();
    
    virtual std::string visitSignedChar();
    
    virtual std::string visitUnsignedChar();
    
    virtual std::string visitUnichar();
    
    virtual std::string visitCString();
    
    virtual std::string visitFloat();
    
    virtual std::string visitDouble();
    
    virtual std::string visitVaList();
    
    virtual std::string visitSelector();
    
    virtual std::string visitInstancetype();
    
    virtual std::string visitClass(const ClassType& typeDetails);
    
    virtual std::string visitProtocol();
    
    virtual std::string visitId(const IdType& typeDetails);
    
    virtual std::string visitConstantArray(const ConstantArrayType& typeDetails);
    
    virtual std::string visitExtVector(const ExtVectorType& typeDetails);
    
    virtual std::string visitIncompleteArray(const IncompleteArrayType& typeDetails);
    
    virtual std::string visitInterface(const InterfaceType& typeDetails);
    
    virtual std::string visitBridgedInterface(const BridgedInterfaceType& typeDetails);
    
    virtual std::string visitPointer(const PointerType& typeDetails);
    
    virtual std::string visitBlock(const BlockType& typeDetails);
    
    virtual std::string visitFunctionPointer(const FunctionPointerType& typeDetails);
    
    virtual std::string visitStruct(const StructType& typeDetails);
    
    virtual std::string visitUnion(const UnionType& typeDetails);
    
    virtual std::string visitAnonymousStruct(const AnonymousStructType& typeDetails);
    
    virtual std::string visitAnonymousUnion(const AnonymousUnionType& typeDetails);
    
    virtual std::string visitEnum(const EnumType& typeDetails);
    
    virtual std::string visitTypeArgument(const ::Meta::TypeArgumentType& type);

private:
    NameRetrieverVisitor(bool tsNames): tsNames(tsNames) { }

    std::string getFunctionTypeScriptName(const std::vector<Type*> &signature);
    std::string generateFixedArray(const Type *el_type, size_t size);

private:
    bool tsNames;
};

#endif /* NameRetrieverVisitor_h */
