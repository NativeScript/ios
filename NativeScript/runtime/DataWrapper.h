#ifndef DataWrapper_h
#define DataWrapper_h

#include <thread>
#include <functional>
#include "Metadata.h"
#include "libffi.h"
#include "ConcurrentQueue.h"
#include "Common.h"

namespace tns {

class PrimitiveDataWrapper;

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
    AnonymousFunction,
    Block,
    Reference,
    ReferenceType,
    Pointer,
    PointerType,
    FunctionReference,
    FunctionReferenceType,
    Worker,
};

struct StructField {
public:
    StructField(ptrdiff_t offset, ffi_type* ffiType, std::string name, const TypeEncoding* encoding)
        : offset_(offset),
          ffiType_(ffiType),
          name_(name),
          encoding_(encoding) {
    }

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

struct StructInfo {
public:
    StructInfo(std::string name, ffi_type* ffiType, std::vector<StructField> fields)
        : name_(name),
          ffiType_(ffiType),
          fields_(fields) {
    }

    std::string Name() const {
        return this->name_;
    }

    ffi_type* FFIType() const {
        return this->ffiType_;
    }

    std::vector<StructField> Fields() {
        return this->fields_;
    }
private:
    std::string name_;
    ffi_type* ffiType_;
    std::vector<StructField> fields_;
};

class BaseDataWrapper {
public:
    virtual ~BaseDataWrapper() = default;

    const virtual WrapperType Type() {
        return WrapperType::Base;
    }
};

class EnumDataWrapper: public BaseDataWrapper {
public:
    EnumDataWrapper(std::string jsCode)
        : jsCode_(jsCode) {
    }

    const WrapperType Type() {
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
    const WrapperType Type() {
        return WrapperType::PointerType;
    }
};

class PointerWrapper: public BaseDataWrapper {
public:
    PointerWrapper(void* data)
        : data_(data),
          isAdopted_(false) {
    }

    const WrapperType Type() {
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
    const WrapperType Type() {
        return WrapperType::ReferenceType;
    }
};

class ReferenceWrapper: public BaseDataWrapper {
public:
    ReferenceWrapper(BaseDataWrapper* typeWrapper, v8::Persistent<v8::Value>* value)
        : typeWrapper_(typeWrapper),
          value_(value),
          encoding_(nullptr),
          data_(nullptr) {
    }

    const WrapperType Type() {
        return WrapperType::Reference;
    }

    BaseDataWrapper* TypeWrapper() {
        return this->typeWrapper_;
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
        if (this->data_ != nullptr) {
            std::free(this->data_);
        }
        this->data_ = data;
    }
private:
    BaseDataWrapper* typeWrapper_;
    v8::Persistent<v8::Value>* value_;
    const TypeEncoding* encoding_;
    void* data_;
};

class PrimitiveDataWrapper: public BaseDataWrapper {
public:
    PrimitiveDataWrapper(size_t size, const TypeEncoding* typeEncoding)
        : size_(size),
          typeEncoding_(typeEncoding) {
    }

    const WrapperType Type() {
        return WrapperType::Primitive;
    }

    size_t Size() {
        return this->size_;
    }

    const TypeEncoding* TypeEncoding() {
        return this->typeEncoding_;
    }
private:
    size_t size_;
    const struct TypeEncoding* typeEncoding_;
};

class StructTypeWrapper: public BaseDataWrapper {
public:
    StructTypeWrapper(StructInfo structInfo)
        : structInfo_(structInfo) {
    }

    const WrapperType Type() {
        return WrapperType::StructType;
    }

    const StructInfo StructInfo() {
        return this->structInfo_;
    }
private:
    struct StructInfo structInfo_;
};

class StructWrapper: public StructTypeWrapper {
public:
    StructWrapper(struct StructInfo structInfo, void* data)
        : StructTypeWrapper(structInfo),
          data_(data) {
    }

    const WrapperType Type() {
        return WrapperType::Struct;
    }

    void* Data() const {
        return this->data_;
    }
private:
    void* data_;
};

class ObjCDataWrapper: public BaseDataWrapper {
public:
    ObjCDataWrapper(id data)
        : data_(data) {
    }

    const WrapperType Type() {
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
    ObjCClassWrapper(Class klazz, bool extendedClass = false)
        : klass_(klazz),
          extendedClass_(extendedClass) {
    }

    const WrapperType Type() {
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
    ObjCProtocolWrapper(Protocol* proto, const ProtocolMeta* protoMeta)
        : proto_(proto),
          protoMeta_(protoMeta) {
    }

    const WrapperType Type() {
        return WrapperType::ObjCProtocol;
    }

    Protocol* Proto() {
        return this->proto_;
    }

    const ProtocolMeta* ProtoMeta() {
        return this->protoMeta_;
    }
private:
    Protocol* proto_;
    const ProtocolMeta* protoMeta_;
};

class FunctionWrapper: public BaseDataWrapper {
public:
    FunctionWrapper(const FunctionMeta* meta)
        : meta_(meta) {
    }

    const WrapperType Type() {
        return WrapperType::Function;
    }

    const FunctionMeta* Meta() {
        return this->meta_;
    }
private:
    const FunctionMeta* meta_;
};

class AnonymousFunctionWrapper: public BaseDataWrapper {
public:
    AnonymousFunctionWrapper(void* functionPointer, const TypeEncoding* parametersEncoding, size_t parametersCount)
        : data_(functionPointer),
          parametersEncoding_(parametersEncoding) {
    }

    const WrapperType Type() {
        return WrapperType::AnonymousFunction;
    }

    void* Data() {
        return this->data_;
    }

    const TypeEncoding* ParametersEncoding() {
        return this->parametersEncoding_;
    }
private:
    void* data_;
    const TypeEncoding* parametersEncoding_;
};

class BlockWrapper: public BaseDataWrapper {
public:
    BlockWrapper(void* block, const TypeEncoding* typeEncoding)
        : block_(block),
          typeEncoding_(typeEncoding) {
    }

    const WrapperType Type() {
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

class FunctionReferenceTypeWrapper: public BaseDataWrapper {
public:
    const WrapperType Type() {
        return WrapperType::FunctionReferenceType;
    }
};

class FunctionReferenceWrapper: public BaseDataWrapper {
public:
    FunctionReferenceWrapper(v8::Persistent<v8::Value>* function)
        : function_(function),
          data_(nullptr) {
    }

    const WrapperType Type() {
        return WrapperType::FunctionReference;
    }

    v8::Persistent<v8::Value>* Function() {
        return this->function_;
    }

    void* Data() const {
        return this->data_;
    }

    void SetData(void* data) {
        this->data_ = data;
    }
private:
    v8::Persistent<v8::Value>* function_;
    void* data_;
};

class WorkerWrapper: public BaseDataWrapper {
public:
    WorkerWrapper(v8::Isolate* mainIsolate, std::function<void (v8::Isolate*, v8::Local<v8::Object> thiz, std::string)> onMessage);

    void Start(v8::Persistent<v8::Value>* poWorker, std::function<v8::Isolate* ()> func);
    void CallOnErrorHandlers(v8::TryCatch& tc);
    void PassUncaughtExceptionFromWorkerToMain(v8::Isolate* workerIsolate, v8::TryCatch& tc, bool async = true);
    void PostMessage(std::string message);
    void Close();
    void Terminate();

    const WrapperType Type();
    const int Id();
    const bool IsRunning();
    const bool IsClosing();
    const int WorkerId();
private:
    v8::Isolate* mainIsolate_;
    v8::Isolate* workerIsolate_;
    bool isRunning_;
    bool isClosing_;
    bool isTerminating_;
    std::thread thread_;
    std::function<void (v8::Isolate*, v8::Local<v8::Object> thiz, std::string)> onMessage_;
    v8::Persistent<v8::Value>* poWorker_;
    ConcurrentQueue queue_;
    static int nextId_;
    int workerId_;

    void BackgroundLooper(std::function<v8::Isolate* ()> func);
    v8::Local<v8::Object> ConstructErrorObject(v8::Isolate* isolate, std::string message, std::string source, std::string stackTrace, int lineNumber);
};

}

#endif /* DataWrapper_h */
