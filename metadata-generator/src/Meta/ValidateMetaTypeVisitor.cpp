//
//  ValidateMetaTypeVisitor.cpp
//  objc-metadata-generator
//
//  Created by Martin Bekchiev on 21.09.18.
//

#include "ValidateMetaTypeVisitor.h"


bool ValidateMetaTypeVisitor::visitVoid() {
    return true;
}

bool ValidateMetaTypeVisitor::visitBool() {
    return true;
}

bool ValidateMetaTypeVisitor::visitShort() {
    return true;
}

bool ValidateMetaTypeVisitor::visitUShort() {
    return true;
}

bool ValidateMetaTypeVisitor::visitInt() {
    return true;
}

bool ValidateMetaTypeVisitor::visitUInt() {
    return true;
}

bool ValidateMetaTypeVisitor::visitLong() {
    return true;
}

bool ValidateMetaTypeVisitor::visitUlong() {
    return true;
}

bool ValidateMetaTypeVisitor::visitLongLong() {
    return true;
}

bool ValidateMetaTypeVisitor::visitULongLong() {
    return true;
}

bool ValidateMetaTypeVisitor::visitSignedChar() {
    return true;
}

bool ValidateMetaTypeVisitor::visitUnsignedChar() {
    return true;
}

bool ValidateMetaTypeVisitor::visitUnichar() {
    return true;
}

bool ValidateMetaTypeVisitor::visitCString() {
    return true;
}

bool ValidateMetaTypeVisitor::visitFloat() {
    return true;
}

bool ValidateMetaTypeVisitor::visitDouble() {
    return true;
}

bool ValidateMetaTypeVisitor::visitVaList() {
    return true;
}

bool ValidateMetaTypeVisitor::visitSelector() {
    return true;
}

bool ValidateMetaTypeVisitor::visitInstancetype() {
    return true;
}

bool ValidateMetaTypeVisitor::visitClass(const ClassType& typeDetails) {
    for (auto& p : typeDetails.protocols) {
        this->_metaFactory.validate(p);
    }

    return true;
}

bool ValidateMetaTypeVisitor::visitProtocol() {
    return true;
}

bool ValidateMetaTypeVisitor::visitId(const IdType& typeDetails) {
    return true;
}

bool ValidateMetaTypeVisitor::visitConstantArray(const ConstantArrayType& typeDetails) {
    return true;
}

bool ValidateMetaTypeVisitor::visitExtVector(const ExtVectorType& typeDetails) {
    return true;
}

bool ValidateMetaTypeVisitor::visitIncompleteArray(const IncompleteArrayType& typeDetails) {
    return true;
}

bool ValidateMetaTypeVisitor::visitInterface(const InterfaceType& typeDetails) {
    
    this->_metaFactory.validate(typeDetails.interface);

    for (auto& p : typeDetails.protocols) {
        this->_metaFactory.validate(p);
    }
    
    for (auto typeArg : typeDetails.typeArguments) {
        typeArg->visit(*this);
    }
    
    return true;
}

bool ValidateMetaTypeVisitor::visitBridgedInterface(const BridgedInterfaceType& typeDetails) {
    if (typeDetails.bridgedInterface) {
        this->_metaFactory.validate(typeDetails.bridgedInterface);
    }
    
    return true;
}

bool ValidateMetaTypeVisitor::visitPointer(const PointerType& typeDetails) {
    typeDetails.innerType->visit(*this);
    
    return true;
}

bool ValidateMetaTypeVisitor::visitBlock(const BlockType& typeDetails) {
    for (auto type : typeDetails.signature) {
        type->visit(*this);
    }
    
    return true;
}

bool ValidateMetaTypeVisitor::visitFunctionPointer(const FunctionPointerType& typeDetails) {
    for (auto type : typeDetails.signature) {
        type->visit(*this);
    }
    
    return true;
}

bool ValidateMetaTypeVisitor::visitStruct(const StructType& typeDetails) {
    this->_metaFactory.validate(typeDetails.structMeta);

    return true;
}

bool ValidateMetaTypeVisitor::visitUnion(const UnionType& typeDetails) {
    this->_metaFactory.validate(typeDetails.unionMeta);

    return true;
}

bool ValidateMetaTypeVisitor::visitAnonymousStruct(const AnonymousStructType& typeDetails) {
    for (auto field : typeDetails.fields) {
        field.encoding->visit(*this);
    }

    return true;
}

bool ValidateMetaTypeVisitor::visitAnonymousUnion(const AnonymousUnionType& typeDetails) {
    for (auto field : typeDetails.fields) {
        field.encoding->visit(*this);
    }
    
    return true;
}

bool ValidateMetaTypeVisitor::visitEnum(const EnumType& typeDetails) {
    this->_metaFactory.validate(typeDetails.enumMeta);

    return true;
}

bool ValidateMetaTypeVisitor::visitTypeArgument(const TypeArgumentType& typeDetails) {
    for (auto& p : typeDetails.protocols) {
        this->_metaFactory.validate(p);
    }
    
    typeDetails.underlyingType->visit(*this);

    return true;
}

