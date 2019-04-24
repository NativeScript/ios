#ifndef Common_h
#define Common_h

#include "Metadata.h"
#include "ffi.h"

namespace tns {

enum WrapperType {
    Base = 1,
    Primitive = 2,
    Record = 3,
    ObjCObject = 4
};

class BaseDataWrapper {
public:
    BaseDataWrapper(const Meta* meta): meta_(meta) {}
    virtual WrapperType Type() {
        return WrapperType::Base;
    }
    const Meta* Metadata() {
        return meta_;
    }
private:
    const Meta* meta_;
};

class PrimitiveDataWrapper: public BaseDataWrapper {
public:
    PrimitiveDataWrapper(ffi_type* ffiType, BinaryTypeEncodingType encodingType): BaseDataWrapper(nullptr), ffiType_(ffiType), encodingType_(encodingType) {
        value_ = malloc(sizeof(ffiType->size));
    }
    WrapperType Type() {
        return WrapperType::Primitive;
    }
    void* Value() {
        return this->value_;
    }
    ffi_type* FFIType() {
        return this->ffiType_;
    }
    BinaryTypeEncodingType EncodingType() {
        return this->encodingType_;
    }
private:
    void* value_;
    ffi_type* ffiType_;
    BinaryTypeEncodingType encodingType_;
};

class RecordDataWrapper: public BaseDataWrapper {
public:
    RecordDataWrapper(const Meta* meta, void* data, ffi_type* ffiType): BaseDataWrapper(meta), data_(data), ffiType_(ffiType) {}
    WrapperType Type() {
        return WrapperType::Record;
    }
    void* Data() {
        return data_;
    }
    ffi_type* FFIType() {
        return ffiType_;
    }
private:
    void* data_;
    ffi_type* ffiType_;
};

class ObjCDataWrapper: public BaseDataWrapper {
public:
    ObjCDataWrapper(const Meta* meta, id data): BaseDataWrapper(meta), data_(data) {}
    WrapperType Type() {
        return WrapperType::ObjCObject;
    }
    id Data() {
        return data_;
    }
private:
    id data_;
};

struct RecordField {
public:
    RecordField(ptrdiff_t offset, size_t size, const TypeEncoding* encoding)
        : offset_(offset), size_(size), encoding_(encoding) { }

    ptrdiff_t Offset() {
        return this->offset_;
    }

    const TypeEncoding* Encoding() {
        return this->encoding_;
    }

    size_t Size() {
        return this->size_;
    }
private:
    ptrdiff_t offset_;
    size_t size_;
    const TypeEncoding* encoding_;
};

}

#endif /* Common_h */
