#ifndef DataWrapper_h
#define DataWrapper_h

#include "Metadata.h"
#include "libffi.h"

namespace tns {

enum WrapperType {
    Base = 1,
    Primitive = 2,
    Enum = 3,
    Record = 4,
    ObjCObject = 5
};

class BaseDataWrapper {
public:
    BaseDataWrapper(std::string name): name_(name) {}
    virtual WrapperType Type() {
        return WrapperType::Base;
    }
    std::string Name() {
        return name_;
    }
private:
    std::string name_;
};

class EnumDataWrapper: public BaseDataWrapper {
public:
    EnumDataWrapper(std::string name, std::string jsCode): BaseDataWrapper(name), jsCode_(jsCode) {}
    WrapperType Type() {
        return WrapperType::Enum;
    }
    std::string JSCode() {
        return jsCode_;
    }
private:
    std::string jsCode_;
};

class PrimitiveDataWrapper: public BaseDataWrapper {
public:
    PrimitiveDataWrapper(size_t size, BinaryTypeEncodingType encodingType): BaseDataWrapper(std::string()), encodingType_(encodingType) {
        value_ = calloc(1, size);
    }
    WrapperType Type() {
        return WrapperType::Primitive;
    }
    void* Value() {
        return this->value_;
    }
    BinaryTypeEncodingType EncodingType() {
        return this->encodingType_;
    }
private:
    void* value_;
    BinaryTypeEncodingType encodingType_;
};

class StructDataWrapper: public BaseDataWrapper {
public:
    StructDataWrapper(const Meta* meta, void* data, ffi_type* ffiType): BaseDataWrapper(meta->name()), meta_(meta), data_(data), ffiType_(ffiType) {}
    WrapperType Type() {
        return WrapperType::Record;
    }
    void* Data() {
        return data_;
    }
    ffi_type* FFIType() {
        return ffiType_;
    }
    const Meta* Metadata() {
        return meta_;
    }
private:
    void* data_;
    ffi_type* ffiType_;
    const Meta* meta_;
};

class ObjCDataWrapper: public BaseDataWrapper {
public:
    ObjCDataWrapper(std::string name, id data): BaseDataWrapper(name), data_(data) {}
    WrapperType Type() {
        return WrapperType::ObjCObject;
    }
    id Data() {
        return data_;
    }
private:
    id data_;
};

struct StructField {
public:
    StructField(ptrdiff_t offset, ffi_type* ffiType, const TypeEncoding* encoding)
        : offset_(offset), ffiType_(ffiType), encoding_(encoding) { }

    ptrdiff_t Offset() {
        return this->offset_;
    }

    const TypeEncoding* Encoding() {
        return this->encoding_;
    }

    ffi_type* FFIType() {
        return this->ffiType_;
    }
private:
    ptrdiff_t offset_;
    ffi_type* ffiType_;
    const TypeEncoding* encoding_;
};

}

#endif /* DataWrapper_h */
