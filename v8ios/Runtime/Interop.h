#ifndef Interop_h
#define Interop_h

#include <map>
#include "ffi.h"
#include "NativeScript.h"
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
    static v8::Local<v8::Value> CallFunction(v8::Isolate* isolate, const Meta* meta, id target, Class clazz, const std::vector<v8::Local<v8::Value>> args, bool callSuper = false);
    static v8::Local<v8::Value> GetResult(v8::Isolate* isolate, const TypeEncoding* typeEncoding, ffi_type* returnType, BaseFFICall* call, bool isInstanceMethod, ffi_type* structFieldFFIType = nullptr);
    static void SetStructPropertyValue(StructDataWrapper* wrapper, StructField field, v8::Local<v8::Value> value);
    static void InitializeStruct(v8::Isolate* isolate, void* destBuffer, const StructMeta* structMeta, v8::Local<v8::Value> inititalizer, ptrdiff_t& position);
private:
    template <typename T>
    static size_t SetStructValue(v8::Local<v8::Value> value, void* destBuffer, ptrdiff_t position);
    static void RegisterInteropType(v8::Isolate* isolate, v8::Local<v8::Object> types, std::string name, PrimitiveDataWrapper* wrapper);
    static void RegisterReferenceInteropType(v8::Isolate* isolate, v8::Local<v8::Object> interop);
    static void SetFFIParams(v8::Isolate* isolate, const TypeEncoding* typeEncoding, FFICall* call, const int argsCount, const int initialParameterIndex, const std::vector<v8::Local<v8::Value>> args);
    static v8::Local<v8::Value> GetPrimitiveReturnType(v8::Isolate* isolate, BinaryTypeEncodingType type, BaseFFICall* call);

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

        static JSBlockDescriptor kJSBlockDescriptor;

        static void copyBlock(JSBlock* dst, const JSBlock* src) {
        }

        static void disposeBlock(JSBlock* block) {
        }
    } JSBlock;
};

}

#endif /* Interop_h */
