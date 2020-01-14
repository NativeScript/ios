#ifndef Interop_h
#define Interop_h

#include <CoreFoundation/CFBase.h>
#include "libffi.h"
#include "Common.h"
#include "Metadata.h"
#include "DataWrapper.h"
#include "FFICall.h"

namespace tns {

typedef void (*FFIMethodCallback)(ffi_cif* cif, void* retValue, void** argValues, void* userData);

class Interop {
public:
    static void RegisterInteropTypes(v8::Isolate* isolate);
    static CFTypeRef CreateBlock(const uint8_t initialParamIndex, const uint8_t argsCount, const TypeEncoding* typeEncoding, FFIMethodCallback callback, void* userData);
    static IMP CreateMethod(const uint8_t initialParamIndex, const uint8_t argsCount, const TypeEncoding* typeEncoding, FFIMethodCallback callback, void* userData);
    static id CallInitializer(v8::Isolate* isolate, const MethodMeta* methodMeta, id target, Class clazz, const std::vector<v8::Local<v8::Value>> args);
    static v8::Local<v8::Value> CallFunction(v8::Isolate* isolate, const MethodMeta* meta, id target, Class clazz, const std::vector<v8::Local<v8::Value>> args, bool callSuper);
    static v8::Local<v8::Value> CallFunction(v8::Isolate* isolate, const FunctionMeta* meta, const std::vector<v8::Local<v8::Value>> args);
    static v8::Local<v8::Value> CallFunction(v8::Isolate* isolate, void* functionPointer, const TypeEncoding* typeEncoding, const std::vector<v8::Local<v8::Value>> args);
    static v8::Local<v8::Value> GetResult(v8::Isolate* isolate, const TypeEncoding* typeEncoding, BaseCall* call, bool marshalToPrimitive, std::shared_ptr<v8::Persistent<v8::Value>> parentStruct = nullptr, bool isStructMember = false);
    static void SetStructPropertyValue(v8::Isolate* isolate, StructWrapper* wrapper, StructField field, v8::Local<v8::Value> value);
    static void InitializeStruct(v8::Isolate* isolate, void* destBuffer, std::vector<StructField> fields, v8::Local<v8::Value> inititalizer);
    static void WriteValue(v8::Isolate* isolate, const TypeEncoding* typeEncoding, void* dest, v8::Local<v8::Value> arg);
    static id ToObject(v8::Isolate* isolate, v8::Local<v8::Value> arg);
    static v8::Local<v8::Value> GetPrimitiveReturnType(v8::Isolate* isolate, BinaryTypeEncodingType type, BaseCall* call);
private:
    template <typename T>
    static void SetStructValue(v8::Local<v8::Value> value, void* destBuffer, ptrdiff_t position);
    static void InitializeStruct(v8::Isolate* isolate, void* destBuffer, std::vector<StructField> fields, v8::Local<v8::Value> inititalizer, ptrdiff_t& position);
    static void RegisterInteropType(v8::Isolate* isolate, v8::Local<v8::Object> types, std::string name, PrimitiveDataWrapper* wrapper);
    static void RegisterBufferFromDataFunction(v8::Isolate* isolate, v8::Local<v8::Object> interop);
    static void RegisterHandleOfFunction(v8::Isolate* isolate, v8::Local<v8::Object> interop);
    static void RegisterAllocFunction(v8::Isolate* isolate, v8::Local<v8::Object> interop);
    static void RegisterFreeFunction(v8::Isolate* isolate, v8::Local<v8::Object> interop);
    static void RegisterAdoptFunction(v8::Isolate* isolate, v8::Local<v8::Object> interop);
    static void RegisterSizeOfFunction(v8::Isolate* isolate, v8::Local<v8::Object> interop);
    static void SetFFIParams(v8::Isolate* isolate, const TypeEncoding* typeEncoding, FFICall* call, const int argsCount, const int initialParameterIndex, const std::vector<v8::Local<v8::Value>> args);
    static v8::Local<v8::Array> ToArray(v8::Isolate* isolate, v8::Local<v8::Object> object);
    static v8::Local<v8::Value> StructToValue(v8::Isolate* isolate, void* result, StructInfo structInfo, std::shared_ptr<v8::Persistent<v8::Value>> parentStruct);
    static const TypeEncoding* CreateEncoding(BinaryTypeEncodingType type);
    static v8::Local<v8::Value> HandleOf(v8::Isolate* isolate, v8::Local<v8::Value> value);
    static v8::Local<v8::Value> CallFunctionInternal(v8::Isolate* isolate, bool isPrimitiveFunction, void* functionPointer, const TypeEncoding* typeEncoding, const std::vector<v8::Local<v8::Value>> args, id target, Class clazz, SEL selector, bool callSuper, MetaType metaType, bool provideErrorOurParameter = false);
    static bool IsNumbericType(BinaryTypeEncodingType type);
    static v8::Local<v8::Object> GetInteropType(v8::Isolate* isolate, BinaryTypeEncodingType type);

    template <typename T>
    static inline void SetValue(void* dest, T value) {
        if (std::is_same<T, SEL>::value) {
            memcpy(dest, &value, sizeof(SEL*));
        } else {
            *static_cast<T*>(dest) = value;
        }
    }

    template <typename T>
    static void SetNumericValue(void* dest, double value) {
        if (value < std::numeric_limits<T>::lowest()) {
            Interop::SetValue(dest, std::numeric_limits<T>::lowest());
        } else if (value > std::numeric_limits<T>::max()) {
            Interop::SetValue(dest, std::numeric_limits<T>::max());
        } else {
            Interop::SetValue(dest, (T)value);
        }
    }

    typedef struct JSBlock {
        typedef struct {
            uintptr_t reserved;
            uintptr_t size;
            void (*copy)(struct JSBlock*, const struct JSBlock*);
            void (*dispose)(struct JSBlock*);
        } JSBlockDescriptor;

        enum {
            BLOCK_NEEDS_FREE = (1 << 24), // runtime
            BLOCK_HAS_COPY_DISPOSE = (1 << 25), // compiler
        };

        void* isa;
        volatile int32_t flags; // contains ref count
        int32_t reserved;
        const void* invoke;
        JSBlockDescriptor* descriptor;
        void* userData;

        static JSBlockDescriptor kJSBlockDescriptor;

        static void copyBlock(JSBlock* dst, const JSBlock* src) {
        }

        static void disposeBlock(JSBlock* block) {
        }
    } JSBlock;
};

}

//#ifdef __OBJC__
//#include "Interop_impl.h"
//#endif

#endif /* Interop_h */
