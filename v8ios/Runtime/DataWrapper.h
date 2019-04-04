#ifndef Common_h
#define Common_h

#include "Metadata.h"

namespace tns {

enum WrapperType {
    Primitive = 1,
    ObjCObject = 2
};

class BaseDataWrapper {
public:
    BaseDataWrapper(const Meta* meta): meta_(meta) {}
    virtual WrapperType Type() = 0;
    const Meta* Metadata() {
        return meta_;
    }
private:
    const Meta* meta_;
};

class PrimitiveDataWrapper: public BaseDataWrapper {
public:
    PrimitiveDataWrapper(const Meta* meta, const void* data): BaseDataWrapper(meta), data_(data) {}
    WrapperType Type() {
        return WrapperType::Primitive;
    }
    const void* Data() {
        return data_;
    }
private:
    const void* data_;
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
