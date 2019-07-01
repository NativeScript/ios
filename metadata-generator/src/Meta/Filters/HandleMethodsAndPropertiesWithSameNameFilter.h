#pragma once

#include "Meta/MetaEntities.h"
#include "Meta/MetaFactory.h"
#include <clang/AST/DeclObjC.h>

namespace Meta {
class HandleMethodsAndPropertiesWithSameNameFilter {
public:
    HandleMethodsAndPropertiesWithSameNameFilter(MetaFactory& metaFactory);

    void filter(std::list<Meta*>& container);

private:
    MetaFactory& m_metaFactory;
    void replaceMethodWithPropertyIfNecessary(clang::ObjCMethodDecl* duplicate, clang::ObjCPropertyDecl* propertyDecl);
    void deleteStaticMethod(const clang::ObjCMethodDecl* duplicateMethod, const clang::ObjCInterfaceDecl* owner);
};
}
