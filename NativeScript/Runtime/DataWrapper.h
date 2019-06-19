#ifndef DataWrapper_h
#define DataWrapper_h

#include "Metadata.h"
#include "libffi.h"
#include "Common.h"

namespace tns {

enum class WrapperType {
    Base,
    Primitive,
    Enum,
    Struct,
    StructType,
    ObjCObject,
    ObjCClass,
    ObjCProtocol,
    Function,
    Block,
    Reference,
    ReferenceType,
    Pointer,
    PointerType,
    FunctionReference,
    FunctionReferenceType,
};

class BaseDataWrapper {
public:
    BaseDataWrapper(std::string name): name_(name) {
    }

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
    EnumDataWrapper(std::string name, std::string jsCode): BaseDataWrapper(name), jsCode_(jsCode) {
    }

    WrapperType Type() {
        return WrapperType::Enum;
    }

    std::string JSCode() {
        return jsCode_;
    }
private:
    std::string jsCode_;
};

class PointerTypeWrapper: public BaseDataWrapper {
public:
    PointerTypeWrapper(): BaseDataWrapper(std::string()) {
    }

    WrapperType Type() {
        return WrapperType::PointerType;
    }
};

class PointerWrapper: public BaseDataWrapper {
public:
    PointerWrapper(void* data): BaseDataWrapper(std::string()), data_(data), isAdopted_(false) {
    }

    WrapperType Type() {
        return WrapperType::Pointer;
    }

    void* Data() const {
        return this->data_;
    }

    void SetData(void* data) {
        this->data_ = data;
    }

    bool IsAdopted() const {
        return this->isAdopted_;
    }

    void SetAdopted(bool value) {
        this->isAdopted_ = value;
    }
private:
    void* data_;
    bool isAdopted_;
};

class ReferenceTypeWrapper: public BaseDataWrapper {
public:
    ReferenceTypeWrapper(): BaseDataWrapper(std::string()) {
    }

    WrapperType Type() {
        return WrapperType::ReferenceType;
    }
};

class ReferenceWrapper: public BaseDataWrapper {
public:
    ReferenceWrapper(v8::Persistent<v8::Value>* value): BaseDataWrapper(std::string()), value_(value), encoding_(nullptr), data_(nullptr) {
    }

    WrapperType Type() {
        return WrapperType::Reference;
    }

    v8::Persistent<v8::Value>* Value() {
        return this->value_;
    }

    void SetValue(v8::Persistent<v8::Value>* value) {
        if (this->value_ != nullptr) {
            this->value_->Reset();
        }
        this->value_ = value;
    }

    const TypeEncoding* Encoding() {
        return this->encoding_;
    }

    void SetEncoding(const TypeEncoding* encoding) {
        this->encoding_ = encoding;
    }

    void* Data() const {
        return this->data_;
    }

    void SetData(void* data) {
        this->data_ = data;
    }
private:
    v8::Persistent<v8::Value>* value_;
    const TypeEncoding* encoding_;
    void* data_;
};

class PrimitiveDataWrapper: public BaseDataWrapper {
public:
    PrimitiveDataWrapper(size_t size, BinaryTypeEncodingType encodingType): BaseDataWrapper(std::string()), size_(size), encodingType_(encodingType) {
    }

    WrapperType Type() {
        return WrapperType::Primitive;
    }

    size_t Size() {
        return this->size_;
    }

    BinaryTypeEncodingType EncodingType() {
        return this->encodingType_;
    }
private:
    size_t size_;
    BinaryTypeEncodingType encodingType_;
};

class StructTypeWrapper: public BaseDataWrapper {
public:
    StructTypeWrapper(const StructMeta* meta): BaseDataWrapper(meta->name()), meta_(meta) {
    }

    WrapperType Type() {
        return WrapperType::StructType;
    }

    const StructMeta* Meta() {
        return this->meta_;
    }
private:
    const StructMeta* meta_;
};

class StructWrapper: public StructTypeWrapper {
public:
    StructWrapper(const StructMeta* meta, void* data, ffi_type* ffiType): StructTypeWrapper(meta), data_(data), ffiType_(ffiType) {
    }

    WrapperType Type() {
        return WrapperType::Struct;
    }

    void* Data() const {
        return this->data_;
    }

    ffi_type* FFIType() {
        return this->ffiType_;
    }
private:
    void* data_;
    ffi_type* ffiType_;
};

class ObjCDataWrapper: public BaseDataWrapper {
public:
    ObjCDataWrapper(std::string name, id data): BaseDataWrapper(name), data_(data) {
    }

    WrapperType Type() {
        return WrapperType::ObjCObject;
    }

    id Data() {
        return data_;
    }
private:
    id data_;
};

class ObjCClassWrapper: public BaseDataWrapper {
public:
    ObjCClassWrapper(Class klazz, bool extendedClass = false): BaseDataWrapper(std::string()), klass_(klazz), extendedClass_(extendedClass) {
    }

    WrapperType Type() {
        return WrapperType::ObjCClass;
    }

    Class Klass() {
        return this->klass_;
    }

    bool ExtendedClass() {
        return this->extendedClass_;
    }
private:
    Class klass_;
    bool extendedClass_;
};

class ObjCProtocolWrapper: public BaseDataWrapper {
public:
    ObjCProtocolWrapper(Protocol* proto): BaseDataWrapper(std::string()), proto_(proto) {
    }

    WrapperType Type() {
        return WrapperType::ObjCProtocol;
    }

    Protocol* Proto() {
        return this->proto_;
    }
private:
    Protocol* proto_;
};

class FunctionWrapper: public BaseDataWrapper {
public:
    FunctionWrapper(const FunctionMeta* meta): BaseDataWrapper(std::string()), meta_(meta) {
    }

    WrapperType Type() {
        return WrapperType::Function;
    }

    const FunctionMeta* Meta() {
        return this->meta_;
    }
private:
    const FunctionMeta* meta_;
};

class BlockWrapper: public BaseDataWrapper {
public:
    BlockWrapper(void* block, const TypeEncoding* typeEncoding)
        : BaseDataWrapper(std::string()), block_(block), typeEncoding_(typeEncoding) {
    }

    WrapperType Type() {
        return WrapperType::Block;
    }

    void* Block() {
        return this->block_;
    }

    const TypeEncoding* Encodings() {
        return this->typeEncoding_;
    }
private:
    void* block_;
    const TypeEncoding* typeEncoding_;
};

struct StructField {
public:
    StructField(ptrdiff_t offset, ffi_type* ffiType, std::string name, const TypeEncoding* encoding)
        : offset_(offset), ffiType_(ffiType), name_(name), encoding_(encoding) { }

    ptrdiff_t Offset() {
        return this->offset_;
    }

    ffi_type* FFIType() {
        return this->ffiType_;
    }

    std::string Name() {
        return this->name_;
    }

    const TypeEncoding* Encoding() {
        return this->encoding_;
    }
private:
    ptrdiff_t offset_;
    ffi_type* ffiType_;
    std::string name_;
    const TypeEncoding* encoding_;
};

class FunctionReferenceTypeWrapper: public BaseDataWrapper {
public:
    FunctionReferenceTypeWrapper(): BaseDataWrapper(std::string()) {
    }

    WrapperType Type() {
        return WrapperType::FunctionReferenceType;
    }
};

class FunctionReferenceWrapper: public BaseDataWrapper {
public:
    FunctionReferenceWrapper(v8::Persistent<v8::Function>* function): BaseDataWrapper(std::string()), function_(function), data_(nullptr) {
    }

    WrapperType Type() {
        return WrapperType::FunctionReference;
    }

    v8::Persistent<v8::Function>* Function() {
        return this->function_;
    }

    void* Data() const {
        return this->data_;
    }

    void SetData(void* data) {
        this->data_ = data;
    }
private:
    v8::Persistent<v8::Function>* function_;
    void* data_;
};

}

#endif /* DataWrapper_h */
