#pragma once

#include "CreationException.h"
#include "MetaEntities.h"
#include "TypeFactory.h"
#include "Utils/Noncopyable.h"
#include <clang/AST/RecursiveASTVisitor.h>
#include <clang/Frontend/ASTUnit.h>
#include <clang/Lex/HeaderSearch.h>
#include <clang/Lex/Preprocessor.h>

namespace Meta {

typedef std::unordered_map<const clang::Decl*, std::pair<std::unique_ptr<Meta>, std::unique_ptr<CreationException>> > Cache;
typedef std::unordered_map<const Meta*, const clang::Decl*> MetaToDeclMap;

class MetaFactory {
public:
    MetaFactory(clang::SourceManager& sourceManager, clang::HeaderSearch& headerSearch)
        : _sourceManager(sourceManager)
        , _headerSearch(headerSearch)
        , _typeFactory(this)
    {
    }

    Meta* create(const clang::Decl& decl, bool resetCached = false);

    bool tryCreate(const clang::Decl& decl, Meta** meta);

    TypeFactory& getTypeFactory()
    {
        return this->_typeFactory;
    }

    Cache& getCache()
    {
        return this->_cache;
    }
    
    void validate(Type* type);

    void validate(Meta* meta);
    
    static std::string getTypedefOrOwnName(const clang::TagDecl* tagDecl);
    
    static std::string renameMeta(MetaType type, std::string& originalJsName, int index = 1);

private:
    void createFromFunction(const clang::FunctionDecl& function, FunctionMeta& functionMeta);

    void createFromStruct(const clang::RecordDecl& record, StructMeta& recordMeta);

    void createFromVar(const clang::VarDecl& var, VarMeta& varMeta);

    void createFromEnum(const clang::EnumDecl& enumeration, EnumMeta& enumMeta);

    void createFromEnumConstant(const clang::EnumConstantDecl& enumConstant, EnumConstantMeta& enumMeta);

    void createFromInterface(const clang::ObjCInterfaceDecl& interface, InterfaceMeta& interfaceMeta);

    void createFromProtocol(const clang::ObjCProtocolDecl& protocol, ProtocolMeta& protocolMeta);

    void createFromCategory(const clang::ObjCCategoryDecl& category, CategoryMeta& categoryMeta);

    void createFromMethod(const clang::ObjCMethodDecl& method, MethodMeta& methodMeta);

    void createFromProperty(const clang::ObjCPropertyDecl& property, PropertyMeta& propertyMeta);

    void populateIdentificationFields(const clang::NamedDecl& decl, Meta& meta);

    void populateMetaFields(const clang::NamedDecl& decl, Meta& meta);

    void populateBaseClassMetaFields(const clang::ObjCContainerDecl& decl, BaseClassMeta& baseClassMeta);

    Version convertVersion(const clang::VersionTuple clangVersion);

    llvm::iterator_range<clang::ObjCProtocolList::iterator> getProtocols(const clang::ObjCContainerDecl* objCContainer);

    clang::SourceManager& _sourceManager;
    clang::HeaderSearch& _headerSearch;
    TypeFactory _typeFactory;

    Cache _cache;
    MetaToDeclMap _metaToDecl;
};
}
