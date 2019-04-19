#ifndef Common_h
#define Common_h

#include <map>
#include "Metadata.h"
#include "ffi.h"

namespace tns {

enum WrapperType {
    Base = 1,
    Record = 2,
    ObjCObject = 3
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
