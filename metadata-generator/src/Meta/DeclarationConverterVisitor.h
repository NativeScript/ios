#pragma once

#include "CreationException.h"
#include "MetaFactory.h"
#include <clang/AST/RecursiveASTVisitor.h>
#include <clang/Frontend/ASTUnit.h>
#include <clang/Lex/HeaderSearch.h>
#include <clang/Lex/Preprocessor.h>
#include <iostream>
#include <sstream>

namespace Meta {
class DeclarationConverterVisitor : public clang::RecursiveASTVisitor<DeclarationConverterVisitor> {
public:
    explicit DeclarationConverterVisitor(clang::SourceManager& sourceManager, clang::HeaderSearch& headerSearch, bool verbose)
        : _metaContainer()
        , _metaFactory(sourceManager, headerSearch)
        , _verbose(verbose)
    {
    }

    std::list<Meta*>& generateMetadata(clang::TranslationUnitDecl* translationUnit)
    {
        this->TraverseDecl(translationUnit);
        return _metaContainer;
    }

    MetaFactory& getMetaFactory()
    {
        return this->_metaFactory;
    }

    // RecursiveASTVisitor methods
    bool VisitFunctionDecl(clang::FunctionDecl* function);

    bool VisitVarDecl(clang::VarDecl* var);

    bool VisitEnumDecl(clang::EnumDecl* enumDecl);

    bool VisitEnumConstantDecl(clang::EnumConstantDecl* enumConstant);

    bool VisitRecordDecl(clang::RecordDecl* record);

    bool VisitObjCInterfaceDecl(clang::ObjCInterfaceDecl* interface);

    bool VisitObjCProtocolDecl(clang::ObjCProtocolDecl* protocol);

    bool VisitObjCCategoryDecl(clang::ObjCCategoryDecl* protocol);

private:
    template <class T>
    bool Visit(T* decl)
    {
        try {
            Meta* meta = this->_metaFactory.create(*decl);
            _metaContainer.push_back(meta);
            log(std::stringstream() << "verbose: Included " << meta->jsName << " from " << meta->module->getFullModuleName());
        } catch (MetaCreationException& e) {
            if(e.isError()) {
                log(std::stringstream() << "verbose: Exception " << e.getDetailedMessage());
            }
        }
        return true;
    }

    inline void log(const std::stringstream& s) {
        this->log(s.str());
    }
    
    inline void log(std::string str) {
        if (this->_verbose) {
            std::cerr << str << std::endl;
        }
    }
    
    std::list<Meta*> _metaContainer;
    MetaFactory _metaFactory;
    bool _verbose;
};
}
