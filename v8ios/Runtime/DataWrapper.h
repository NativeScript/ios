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

}

#endif /* Common_h */
