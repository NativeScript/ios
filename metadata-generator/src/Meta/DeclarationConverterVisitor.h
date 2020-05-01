#pragma once

#include "CreationException.h"
#include "MetaFactory.h"
#include "Filters/ModulesBlacklist.h"
#include <clang/AST/RecursiveASTVisitor.h>
#include <clang/Frontend/ASTUnit.h>
#include <clang/Lex/HeaderSearch.h>
#include <clang/Lex/Preprocessor.h>
#include <iostream>
#include <sstream>

namespace Meta {
class DeclarationConverterVisitor : public clang::RecursiveASTVisitor<DeclarationConverterVisitor> {
public:
    explicit DeclarationConverterVisitor(clang::SourceManager& sourceManager, clang::HeaderSearch& headerSearch, bool verbose, ModulesBlacklist& modulesBlacklist)
        : _metaContainer()
        , _metaFactory(sourceManager, headerSearch)
        , _verbose(verbose)
        , _modulesBlacklist(modulesBlacklist)
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
            // Remove from cache if present to have a chance to process any errors
            // in dependant types which have been pending when it was cached the 1st time.
            // If we have the following (inspired from Tcl_HashTable):
            // struct HashTable;
            //
            // struct HashEntry {
            //  HashTable*table;
            //  union {
            //  }
            // }
            //
            // struct HashTable {
            //  HashEntry **entries;
            // }
            // We do not support unions, so HashEntry is not included in the metadata.
            // But before the cache purge we were leaving HashTable and it caused crashes
            // if accessed at runtime.

            Meta* meta = this->_metaFactory.create(*decl, /*resetCached*/ true);
            std::string whitelistRule, blacklistRule;
            // Never blacklist NSObject - it's special and always needed by both the {N} runtime and the MDG
            if (meta->name != "NSObject" && meta->module && _modulesBlacklist.shouldBlacklist(meta->module->getFullModuleName(), meta->name.empty() ? meta->jsName : meta->name, /*r*/whitelistRule, /*r*/blacklistRule)) {
                logSymbolAction("Blacklisted", meta, whitelistRule, blacklistRule);
            } else {
                _metaContainer.push_back(meta);
                logSymbolAction("Included", meta, whitelistRule, blacklistRule);
            }
        } catch (MetaCreationException& e) {
            if (e.isError()) {
                log(std::stringstream() << "Exception " << e.getDetailedMessage());
            } else {
                  // Uncomment for maximum verbosity when debugging metadata generation issues
//                auto namedDecl = clang::dyn_cast<clang::NamedDecl>(decl);
//                auto name = namedDecl ? namedDecl->getNameAsString() : "<unknown>";
//                log(std::stringstream() << "Skipping " << name << ": " << e.getMessage());
            }
        }
        return true;
    }

    void logSymbolAction(const std::string& action, const Meta *meta, const std::string &whitelistRule, const std::string &blacklistRule) {
        std::stringstream ss;
        ss << action << " ";
        
        if (!meta->name.empty() && meta->name != meta->jsName) {
            ss << meta->name << " (JS: " << meta->jsName << ")";
        } else {
            ss << meta->jsName;
        }
        
        ss << " from " << meta->module->getFullModuleName();

        if (!whitelistRule.empty() || !blacklistRule.empty()) {
            ss << " (";
            if (!whitelistRule.empty()) {
                ss << "enabled by '" << whitelistRule << "'";
                if (!blacklistRule.empty()) {
                    ss << ", ";
                }
            }
            if (!blacklistRule.empty()) {
                ss << "disabled by '" << blacklistRule << "'";
            }
            ss << ")";
        }
        log(ss);
    }
    
    inline void log(const std::stringstream& s) {
        this->log(s.str());
    }
    
    inline void log(std::string str) {
        if (this->_verbose) {
            std::cerr << "verbose: " << str << std::endl;
        }
    }
    
    std::list<Meta*> _metaContainer;
    MetaFactory _metaFactory;
    bool _verbose;
    ModulesBlacklist& _modulesBlacklist;
};
} // namespace Meta
