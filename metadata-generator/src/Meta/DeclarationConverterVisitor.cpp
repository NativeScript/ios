#include "DeclarationConverterVisitor.h"
#include <iostream>

using namespace std;

bool Meta::DeclarationConverterVisitor::VisitFunctionDecl(clang::FunctionDecl* function)
{
    return Visit<clang::FunctionDecl>(function);
}

bool Meta::DeclarationConverterVisitor::VisitVarDecl(clang::VarDecl* var)
{
    // It is not exactly a VarDecl but an inheritor of VarDecl (e.g. ParmVarDecl)
    return (var->getKind() == clang::Decl::Kind::Var) ? Visit<clang::VarDecl>(var) : true;
}

bool Meta::DeclarationConverterVisitor::VisitEnumDecl(clang::EnumDecl* enumDecl)
{
    return Visit<clang::EnumDecl>(enumDecl);
}

bool Meta::DeclarationConverterVisitor::VisitEnumConstantDecl(clang::EnumConstantDecl* enumConstant)
{
    return Visit<clang::EnumConstantDecl>(enumConstant);
}

bool Meta::DeclarationConverterVisitor::VisitRecordDecl(clang::RecordDecl* record)
{
    return Visit<clang::RecordDecl>(record);
}

bool Meta::DeclarationConverterVisitor::VisitObjCInterfaceDecl(clang::ObjCInterfaceDecl* interface)
{
    return Visit<clang::ObjCInterfaceDecl>(interface);
}

bool Meta::DeclarationConverterVisitor::VisitObjCProtocolDecl(clang::ObjCProtocolDecl* protocol)
{
    return Visit<clang::ObjCProtocolDecl>(protocol);
}

bool Meta::DeclarationConverterVisitor::VisitObjCCategoryDecl(clang::ObjCCategoryDecl* category)
{
    return Visit<clang::ObjCCategoryDecl>(category);
}