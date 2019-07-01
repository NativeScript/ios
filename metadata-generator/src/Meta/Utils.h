#pragma once

#include <clang/AST/Decl.h>
#include <clang/Basic/Module.h>

namespace Meta {
class Type;

class Utils {
public:
    template <class T>
    static std::vector<T*> getAttributes(const clang::Decl& decl)
    {
        std::vector<T*> attributes;
        for (clang::Attr* attribute : decl.attrs()) {
            if (T* typedAttribute = clang::dyn_cast<T>(attribute)) {
                attributes.push_back(typedAttribute);
            }
        }
        return attributes;
    }

    static bool areTypesEqual(const Type& type1, const Type& type2);

    static bool areTypesEqual(const std::vector<Type*>& types1, const std::vector<Type*>& types2);

    static std::string calculateEnumFieldsPrefix(const std::string& enumName, const std::vector<std::string>& fields);

    static void getAllLinkLibraries(clang::Module* module, std::vector<clang::Module::LinkLibrary>& result);
};
}