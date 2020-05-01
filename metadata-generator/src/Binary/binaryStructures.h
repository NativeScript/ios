#pragma once

#include <memory>
#include <stdint.h>
#include <vector>

namespace binary {
typedef int32_t MetaFileOffset;
typedef int32_t MetaArrayCount;

class MetaFile;
class BinaryWriter;

enum BinaryTypeEncodingType : uint8_t {
    Void,
    Bool,
    Short,
    UShort,
    Int,
    UInt,
    Long,
    ULong,
    LongLong,
    ULongLong,
    Char,
    UChar,
    Unichar,
    CharS,
    CString,
    Float,
    Double,
    InterfaceDeclarationReference,
    StructDeclarationReference,
    UnionDeclarationReference,
    Pointer,
    VaList,
    Selector,
    Class,
    ProtocolType,
    InstanceType,
    Id,
    ConstantArray,
    IncompleteArray,
    FunctionPointer,
    Block,
    AnonymousStruct,
    AnonymousUnion,
    Vector
};

// BinaryMetaType values must not exceed
enum BinaryMetaType : uint8_t {
    Undefined = 0,
    Struct,
    Union,
    Function,
    JsCode,
    Var,
    Interface,
    Protocol
};

enum BinaryFlags : uint16_t {
    // Common
    HasDemangledName = 1 << 8,
    HasName = 1 << 7,
    IsIosAppExtensionAvailable = 1 << 6,
    // Function
    FunctionIsVariadic = 1 << 5,
    FunctionOwnsReturnedCocoaObject = 1 << 4,
    FunctionReturnsUnmanaged = 1 << 3,
    // Member
    MemberIsOptional = 1 << 0,
    // Method
    MethodIsInitializer = 1 << 1,
    MethodIsVariadic = 1 << 2,
    MethodIsNullTerminatedVariadic = 1 << 3,
    MethodOwnsReturnedCocoaObject = 1 << 4,
    MethodHasErrorOutParameter = 1 << 5,
    // Property
    PropertyHasGetter = 1 << 2,
    PropertyHasSetter = 1 << 3
};

#pragma pack(push, 1)
struct Meta {
public:
    Meta(BinaryMetaType type)
        : _flags(type & 0x7) // 7 = 111 -> get only the first 3 bits of the type
    {
    }

    MetaFileOffset _names = 0;
    MetaFileOffset _topLevelModule = 0;
    uint16_t _flags = 0;
    uint8_t _introduced = 0;

    virtual MetaFileOffset save(BinaryWriter& writer);
};

struct RecordMeta : Meta {
public:
    RecordMeta(BinaryMetaType type)
        : Meta(type)
    {
    }

    MetaFileOffset _fieldNames = 0;
    MetaFileOffset _fieldsEncodings = 0;

    virtual MetaFileOffset save(BinaryWriter& writer) override;
};

struct StructMeta : RecordMeta {
public:
    StructMeta()
        : RecordMeta(BinaryMetaType::Struct)
    {
    }
};

struct UnionMeta : RecordMeta {
public:
    UnionMeta()
        : RecordMeta(BinaryMetaType::Union)
    {
    }
};

struct FunctionMeta : Meta {
public:
    FunctionMeta()
        : Meta(BinaryMetaType::Function)
    {
    }

    MetaFileOffset _encoding = 0;

    virtual MetaFileOffset save(BinaryWriter& writer) override;
};

struct JsCodeMeta : Meta {
public:
    JsCodeMeta()
        : Meta(BinaryMetaType::JsCode)
    {
    }

    MetaFileOffset _jsCode = 0;

    virtual MetaFileOffset save(BinaryWriter& writer) override;
};

struct VarMeta : Meta {
public:
    VarMeta()
        : Meta(BinaryMetaType::Var)
    {
    }

    MetaFileOffset _encoding = 0;

    virtual MetaFileOffset save(BinaryWriter& writer) override;
};

struct MemberMeta : Meta {
public:
    MemberMeta()
        : Meta(BinaryMetaType::Undefined)
    {
    }
};

struct MethodMeta : MemberMeta {
public:
    MetaFileOffset _encoding = 0;
    MetaFileOffset _constructorTokens = 0;

    virtual MetaFileOffset save(BinaryWriter& writer) override;
};

struct PropertyMeta : MemberMeta {
    MetaFileOffset _getter = 0;
    MetaFileOffset _setter = 0;

    virtual MetaFileOffset save(BinaryWriter& writer) override;
};

struct BaseClassMeta : Meta {
public:
    BaseClassMeta(BinaryMetaType type)
        : Meta(type)
    {
    }

    MetaFileOffset _instanceMethods = 0;
    MetaFileOffset _staticMethods = 0;
    MetaFileOffset _instanceProperties = 0;
    MetaFileOffset _staticProperties = 0;
    MetaFileOffset _protocols = 0;
    int16_t _initializersStartIndex = -1;

    virtual MetaFileOffset save(BinaryWriter& writer) override;
};

struct ProtocolMeta : BaseClassMeta {
public:
    ProtocolMeta()
        : BaseClassMeta(BinaryMetaType::Protocol)
    {
    }
};

struct InterfaceMeta : BaseClassMeta {
public:
    InterfaceMeta()
        : BaseClassMeta(BinaryMetaType::Interface)
    {
    }

    MetaFileOffset _baseName = 0;

    virtual MetaFileOffset save(BinaryWriter& writer) override;
};

struct ModuleMeta {
public:
    int8_t _flags;
    MetaFileOffset _name;
    MetaFileOffset _libraries;

    virtual MetaFileOffset save(BinaryWriter& writer);
};

struct LibraryMeta {
public:
    int8_t _flags;
    MetaFileOffset _name;

    virtual MetaFileOffset save(BinaryWriter& writer);
};

#pragma pack(pop)

// type encoding

struct TypeEncoding {
public:
    TypeEncoding(BinaryTypeEncodingType t)
        : _type(t)
    {
    }

    BinaryTypeEncodingType _type;

    virtual MetaFileOffset save(BinaryWriter& writer);
    virtual ~TypeEncoding() { }
};

struct IdEncoding : public TypeEncoding {
public:
    IdEncoding()
    : TypeEncoding(BinaryTypeEncodingType::Id)
    {
    }
    
    MetaFileOffset _protocols;

    virtual MetaFileOffset save(BinaryWriter& writer) override;
};

struct IncompleteArrayEncoding : public TypeEncoding {
public:
    IncompleteArrayEncoding()
        : TypeEncoding(BinaryTypeEncodingType::IncompleteArray)
    {
    }

    std::unique_ptr<TypeEncoding> _elementType;

    virtual MetaFileOffset save(BinaryWriter& writer) override;
};

struct ConstantArrayEncoding : public TypeEncoding {
public:
    ConstantArrayEncoding()
        : TypeEncoding(BinaryTypeEncodingType::ConstantArray)
    {
    }

    int _size;
    std::unique_ptr<TypeEncoding> _elementType;

    virtual MetaFileOffset save(BinaryWriter& writer) override;
};
    
struct ExtVectorEncoding: public TypeEncoding {
public:
    ExtVectorEncoding()
        : TypeEncoding(BinaryTypeEncodingType::Vector)
    {
    }
    
    int _size;
    std::unique_ptr<TypeEncoding> _elementType;
    
    virtual MetaFileOffset save(BinaryWriter& writer) override;
};

struct DeclarationReferenceEncoding : public TypeEncoding {
public:
    DeclarationReferenceEncoding(BinaryTypeEncodingType type)
        : TypeEncoding(type)
    {
    }

    MetaFileOffset _name;
    
    virtual MetaFileOffset save(BinaryWriter& writer) override;
};

struct InterfaceDeclarationReferenceEncoding : public DeclarationReferenceEncoding {
public:
    InterfaceDeclarationReferenceEncoding()
    : DeclarationReferenceEncoding(BinaryTypeEncodingType::InterfaceDeclarationReference)
    {
    }
    
    MetaFileOffset _protocols;
    
    virtual MetaFileOffset save(BinaryWriter& writer) override;
};

struct PointerEncoding : public TypeEncoding {
public:
    PointerEncoding()
        : TypeEncoding(BinaryTypeEncodingType::Pointer)
    {
    }

    std::unique_ptr<TypeEncoding> _target;

    virtual MetaFileOffset save(BinaryWriter& writer) override;
};

struct BlockEncoding : public TypeEncoding {
public:
    BlockEncoding()
        : TypeEncoding(BinaryTypeEncodingType::Block)
    {
    }

    uint8_t _encodingsCount;
    std::vector<std::unique_ptr<TypeEncoding> > _encodings;

    virtual MetaFileOffset save(BinaryWriter& writer) override;
};

struct FunctionEncoding : public TypeEncoding {
public:
    FunctionEncoding()
        : TypeEncoding(BinaryTypeEncodingType::FunctionPointer)
    {
    }

    uint8_t _encodingsCount;
    std::vector<std::unique_ptr<TypeEncoding> > _encodings;

    virtual MetaFileOffset save(BinaryWriter& writer) override;
};

struct AnonymousRecordEncoding : public TypeEncoding {
public:
    AnonymousRecordEncoding(BinaryTypeEncodingType t)
        : TypeEncoding(t)
    {
    }

    uint8_t _fieldsCount = 0;
    std::vector<MetaFileOffset> _fieldNames;
    std::vector<std::unique_ptr<TypeEncoding> > _fieldEncodings;

    virtual MetaFileOffset save(BinaryWriter& writer) override;
};
}
