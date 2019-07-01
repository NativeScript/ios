//
//  NameRetrieverVisitor.cpp
//  objc-metadata-generator
//
//  Created by Martin Bekchiev on 3.09.18.
//

#include "NameRetrieverVisitor.h"
#include "MetaEntities.h"

#include <sstream>

NameRetrieverVisitor NameRetrieverVisitor::instanceObjC(false);
NameRetrieverVisitor NameRetrieverVisitor::instanceTs(true);

std::string NameRetrieverVisitor::visitVoid() {
    return "void";
}
    
std::string NameRetrieverVisitor::visitBool() {
    return this->tsNames ? "boolean" : "bool";
}
    
std::string NameRetrieverVisitor::visitShort() {
    return this->tsNames ? "number" : "short";
}

std::string NameRetrieverVisitor::visitUShort() {
    return this->tsNames ? "number" : "unsigned short";
}
    
std::string NameRetrieverVisitor::visitInt() {
    return this->tsNames ? "number" : "int";
}
    
std::string NameRetrieverVisitor::visitUInt() {
    return this->tsNames ? "number" : "unsigned int";
}
    
std::string NameRetrieverVisitor::visitLong() {
    return this->tsNames ? "number" : "long";
}
    
std::string NameRetrieverVisitor::visitUlong() {
    return this->tsNames ? "number" : "unsigned long";
}
    
std::string NameRetrieverVisitor::visitLongLong() {
    return this->tsNames ? "number" : "long long";
}
    
std::string NameRetrieverVisitor::visitULongLong() {
    return this->tsNames ? "number" : "unsigned long long";
}
    
std::string NameRetrieverVisitor::visitSignedChar() {
    return this->tsNames ? "number" : "signed char";
}
    
std::string NameRetrieverVisitor::visitUnsignedChar() {
    return this->tsNames ? "number" : "unsigned char";
}
    
std::string NameRetrieverVisitor::visitUnichar() {
    return this->tsNames ? "number" : "wchar_t";
}
    
std::string NameRetrieverVisitor::visitCString() {
    return this->tsNames ? "string" : "char*";
}
    
std::string NameRetrieverVisitor::visitFloat() {
    return this->tsNames ? "number" : "float";
}
    
std::string NameRetrieverVisitor::visitDouble() {
    return this->tsNames ? "number" : "double";
}
    
std::string NameRetrieverVisitor::visitVaList() {
    return "";
}
    
std::string NameRetrieverVisitor::visitSelector() {
    return this->tsNames ? "string" : "SEL";
}
    
std::string NameRetrieverVisitor::visitInstancetype() {
    return this->tsNames ? "any" : "instancetype";
}
    
std::string NameRetrieverVisitor::visitClass(const ClassType& typeDetails) {
    return this->tsNames ? "any" : "Class";
}
    
std::string NameRetrieverVisitor::visitProtocol() {
    return this->tsNames ? "any" : "Protocol";
}
    
std::string NameRetrieverVisitor::visitId(const IdType& typeDetails) {
    return this->tsNames ? "any" : "id";
}
    
std::string NameRetrieverVisitor::visitConstantArray(const ConstantArrayType& typeDetails) {
    return this->generateFixedArray(typeDetails.innerType, typeDetails.size);
}
    
std::string NameRetrieverVisitor::visitExtVector(const ExtVectorType& typeDetails) {
    return this->generateFixedArray(typeDetails.innerType, typeDetails.size);
}

std::string NameRetrieverVisitor::visitIncompleteArray(const IncompleteArrayType& typeDetails) {
    return typeDetails.innerType->visit(*this).append("[]");
}
    
std::string NameRetrieverVisitor::visitInterface(const InterfaceType& typeDetails) {
    return this->tsNames ? typeDetails.interface->jsName : typeDetails.interface->name;
}
    
std::string NameRetrieverVisitor::visitBridgedInterface(const BridgedInterfaceType& typeDetails) {
    return typeDetails.name;
}
    
std::string NameRetrieverVisitor::visitPointer(const PointerType& typeDetails) {
    return this->tsNames ? "any" : typeDetails.innerType->visit(*this).append("*");
}
    
std::string NameRetrieverVisitor::visitBlock(const BlockType& typeDetails) {
    return this->tsNames ? this->getFunctionTypeScriptName(typeDetails.signature) : "void*" /*TODO: construct objective-c full block definition*/;
}

std::string NameRetrieverVisitor::visitFunctionPointer(const FunctionPointerType& typeDetails) {
    return this->tsNames ? this->getFunctionTypeScriptName(typeDetails.signature) : "void*"/*TODO: construct objective-c full function pointer definition*/;
}

std::string NameRetrieverVisitor::visitStruct(const StructType& typeDetails) {
    return this->tsNames ? typeDetails.structMeta->jsName : typeDetails.structMeta->name;
}
    
std::string NameRetrieverVisitor::visitUnion(const UnionType& typeDetails) {
    return this->tsNames ? typeDetails.unionMeta->jsName : typeDetails.unionMeta->name;
}
    
std::string NameRetrieverVisitor::visitAnonymousStruct(const AnonymousStructType& typeDetails) {
    return "";
}
    
std::string NameRetrieverVisitor::visitAnonymousUnion(const AnonymousUnionType& typeDetails) {
    return "";
}
    
std::string NameRetrieverVisitor::visitEnum(const EnumType& typeDetails) {
    return this->tsNames ? typeDetails.enumMeta->jsName : typeDetails.enumMeta->name;
}
    
std::string NameRetrieverVisitor::visitTypeArgument(const ::Meta::TypeArgumentType& type) {
    return type.name;
}

std::string NameRetrieverVisitor::generateFixedArray(const Type *el_type, size_t size) {
    std::stringstream ss(el_type->visit(*this));
    ss << "[";
    if (!this->tsNames) {
        ss << size;
    }
    ss << "]";
    
    return ss.str();
}

std::string NameRetrieverVisitor::getFunctionTypeScriptName(const std::vector<Type*> &signature) {
    // (p1: t1,...) => ret_type
    assert(signature.size() > 0);
    
    std::stringstream ss;
    ss << "(";
    for (size_t i = 1; i < signature.size(); i++) {
        if (i > 1) {
            ss << ", ";
        }
        ss << "p" << i << ": " << signature[i]->visit(*this);
    }
    ss << ")";
    ss << " => ";
    ss << signature[0]->visit(*this);
    
    return ss.str();
}

