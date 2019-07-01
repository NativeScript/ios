//
//  ValidateMetaTypeVisitor.h
//  objc-metadata-generator
//
//  Created by Martin Bekchiev on 21.09.18.
//

#ifndef ValidateMetaTypeVisitor_h
#define ValidateMetaTypeVisitor_h

#include "MetaFactory.h"
#include "TypeEntities.h"
#include "TypeVisitor.h"

using namespace Meta;

class ValidateMetaTypeVisitor : public TypeVisitor<bool> {
    
public:
    explicit ValidateMetaTypeVisitor(MetaFactory& factory): _metaFactory(factory) { }

    virtual bool visitVoid();
    
    virtual bool visitBool();
    
    virtual bool visitShort();
    
    virtual bool visitUShort();
    
    virtual bool visitInt();
    
    virtual bool visitUInt();
    
    virtual bool visitLong();
    
    virtual bool visitUlong();
    
    virtual bool visitLongLong();
    
    virtual bool visitULongLong();
    
    virtual bool visitSignedChar();
    
    virtual bool visitUnsignedChar();
    
    virtual bool visitUnichar();
    
    virtual bool visitCString();
    
    virtual bool visitFloat();
    
    virtual bool visitDouble();
    
    virtual bool visitVaList();
    
    virtual bool visitSelector();
    
    virtual bool visitInstancetype();
    
    virtual bool visitClass(const ClassType& typeDetails);
    
    virtual bool visitProtocol();
    
    virtual bool visitId(const IdType& typeDetails);
    
    virtual bool visitConstantArray(const ConstantArrayType& typeDetails);
    
    virtual bool visitExtVector(const ExtVectorType& typeDetails);
    
    virtual bool visitIncompleteArray(const IncompleteArrayType& typeDetails);
    
    virtual bool visitInterface(const InterfaceType& typeDetails);
    
    virtual bool visitBridgedInterface(const BridgedInterfaceType& typeDetails);
    
    virtual bool visitPointer(const PointerType& typeDetails);
    
    virtual bool visitBlock(const BlockType& typeDetails);
    
    virtual bool visitFunctionPointer(const FunctionPointerType& typeDetails);
    
    virtual bool visitStruct(const StructType& typeDetails);
    
    virtual bool visitUnion(const UnionType& typeDetails);
    
    virtual bool visitAnonymousStruct(const AnonymousStructType& typeDetails);
    
    virtual bool visitAnonymousUnion(const AnonymousUnionType& typeDetails);
    
    virtual bool visitEnum(const EnumType& typeDetails);
    
    virtual bool visitTypeArgument(const ::Meta::TypeArgumentType& type);

    
private:
    MetaFactory& _metaFactory;
};

#endif /* ValidateMetaTypeVisitor_h */
