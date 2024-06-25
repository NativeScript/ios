#pragma once

#include "MetaVisitor.h"
#include "TypeEntities.h"
#include "Utils/Noncopyable.h"
#include <clang/AST/DeclBase.h>
#include <clang/Basic/Module.h>
#include <iostream>
#include <llvm/ADT/iterator_range.h>
#include <map>
#include <string>
#include <unordered_map>
#include <vector>

#define UNKNOWN_VERSION \
    {                   \
        -1, -1, -1      \
    }

namespace Meta {
struct Version {
    static Version Unknown;
    
    int Major;
    int Minor;
    int SubMinor;
    
    bool isUnknown() const {
        return this->Major <= 0;
    }
    
    bool isGreaterThanOrUnknown(const Version& other) const {
        return this->isUnknown() ||  (*this > other && !other.isUnknown());
    }

    bool operator ==(const Version& other) const {
        return this->Major == other.Major &&
            this->Minor == other.Minor && this->SubMinor == other.SubMinor;
    }

    bool operator !=(const Version& other) const {
        return !(*this == other);
    }
    
    bool operator <(const Version& other) const {
        return this->Major < other.Major ||
                (this->Major == other.Major &&
                    (this->Minor < other.Minor ||
                     (this->Minor == other.Minor && this->SubMinor < other.SubMinor)
                    )
                );
    }

    bool operator <=(const Version& other) const {
        return *this == other || *this < other;
    }

    bool operator >(const Version& other) const {
        return !(*this <= other);
    }

    bool operator >=(const Version& other) const {
        return !(*this < other);
    }
    std::string toString() const {
        std::string result;
        if (Major >= 0) {
            result.append(std::to_string(Major));
            if (Minor >= 0) {
                result.append("." + std::to_string(Minor));
                if (SubMinor >= 0) {
                    result.append("." + std::to_string(SubMinor));
                }
            }
        }
        return result;
    }
};

enum MetaFlags : uint16_t {
    // Common
    None = 0,
    IsIosAppExtensionAvailable = 1 << 0,
    // Function
    FunctionIsVariadic = 1 << 1,
    FunctionOwnsReturnedCocoaObject = 1 << 2,
    FunctionReturnsUnmanaged = 1 << 3,
    // Method
    MethodIsVariadic = 1 << 4,
    MethodIsNullTerminatedVariadic = 1 << 5,
    MethodOwnsReturnedCocoaObject = 1 << 6,
    MethodHasErrorOutParameter = 1 << 7,
    MethodIsInitializer = 1 << 8,
    
    // Member
    MemberIsOptional = 1 << 10,
};

enum MetaType {
    Undefined = 0,
    Struct,
    Union,
    Function,
    Enum,
    Var,
    Interface,
    Protocol,
    Category,
    Method,
    Property,
    EnumConstant
};

class Meta {
public:
    MetaType type = MetaType::Undefined;
    MetaFlags flags = MetaFlags::None;

    std::string name;
    std::string demangledName;
    std::string jsName;
    std::string fileName;
    clang::Module* module = nullptr;
    const clang::Decl* declaration = nullptr;

    // Availability
    Version introducedIn = UNKNOWN_VERSION;
    Version obsoletedIn = UNKNOWN_VERSION;
    Version deprecatedIn = UNKNOWN_VERSION;

    Meta() = default;
    virtual ~Meta() = default;

    // visitors
    virtual void visit(MetaVisitor* serializer) = 0;

    bool is(MetaType type) const
    {
        return this->type == type;
    }

    bool getFlags(MetaFlags flags) const
    {
        return (this->flags & flags) == flags;
    }

    void setFlags(MetaFlags flags, bool value)
    {
        if (value) {
            this->flags = static_cast<MetaFlags>(this->flags | flags);
        } else {
            this->flags = static_cast<MetaFlags>(this->flags & ~flags);
        }
    }

    template <class T>
    const T& as() const
    {
        return *static_cast<const T*>(this);
    }

    template <class T>
    T& as()
    {
        return *static_cast<T*>(this);
    }

    std::string identificationString() const
    {
        return std::string("[Name: '") + name + "', JsName: '" + jsName + "', Module: '" + ((module == nullptr) ? "" : module->getFullModuleName()) + "', File: '" + fileName + "']";
    }
};

class MethodMeta : public Meta {
public:
    MethodMeta()
        : Meta()
    {
        this->type = MetaType::Method;
    }

    // just a more convenient way to get the selector of method
    std::string getSelector() const
    {
        return this->name;
    }

    std::vector<Type*> signature;
    std::string constructorTokens;

    virtual void visit(MetaVisitor* visitor) override;
};

class PropertyMeta : public Meta {
public:
    PropertyMeta()
        : Meta()
    {
        this->type = MetaType::Property;
    }

    MethodMeta* getter = nullptr;
    MethodMeta* setter = nullptr;

    virtual void visit(MetaVisitor* visitor) override;
};

class BaseClassMeta : public Meta {
public:
    std::vector<MethodMeta*> instanceMethods;
    std::vector<MethodMeta*> staticMethods;
    std::vector<PropertyMeta*> instanceProperties;
    std::vector<PropertyMeta*> staticProperties;
    std::vector<ProtocolMeta*> protocols;
};

class ProtocolMeta : public BaseClassMeta {
public:
    ProtocolMeta()
    {
        this->type = MetaType::Protocol;
    }

    virtual void visit(MetaVisitor* visitor) override;
};

class CategoryMeta : public BaseClassMeta {
public:
    CategoryMeta()
    {
        this->type = MetaType::Category;
    }

    InterfaceMeta* extendedInterface;

    virtual void visit(MetaVisitor* visitor) override;
};

class InterfaceMeta : public BaseClassMeta {
public:
    InterfaceMeta()
    {
        this->type = MetaType::Interface;
    }

    InterfaceMeta* base;

    virtual void visit(MetaVisitor* visitor) override;
};

class RecordMeta : public Meta {
public:
    std::vector<RecordField> fields;
};

class StructMeta : public RecordMeta {
public:
    StructMeta()
    {
        this->type = MetaType::Struct;
    }

    virtual void visit(MetaVisitor* visitor) override;
};

class UnionMeta : public RecordMeta {
public:
    UnionMeta()
    {
        this->type = MetaType::Union;
    }

    virtual void visit(MetaVisitor* visitor) override;
};

class FunctionMeta : public Meta {
public:
    FunctionMeta()
    {
        this->type = MetaType::Function;
    }
    std::vector<Type*> signature;

    virtual void visit(MetaVisitor* visitor) override;
};

class EnumConstantMeta : public Meta {
public:
    EnumConstantMeta()
    {
        this->type = MetaType::EnumConstant;
    }

    std::string value;

    bool isScoped = false;

    virtual void visit(MetaVisitor* visitor) override;
};

struct EnumField {
    std::string name;
    std::string value;
};

class EnumMeta : public Meta {
public:
    EnumMeta()
    {
        this->type = MetaType::Enum;
    }

    std::vector<EnumField> fullNameFields;

    std::vector<EnumField> swiftNameFields;

    virtual void visit(MetaVisitor* visitor) override;
};

class VarMeta : public Meta {
public:
    VarMeta()
    {
        this->type = MetaType::Var;
    }

    Type* signature = nullptr;
    bool hasValue = false;
    std::string value;

    virtual void visit(MetaVisitor* visitor) override;
};
}
