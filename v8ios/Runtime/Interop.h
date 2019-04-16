#ifndef Interop_h
#define Interop_h

#include <map>
#include "ffi.h"
#include "NativeScript.h"
#include "Metadata.h"

namespace tns {

typedef void (*FFIMethodCallback)(ffi_cif* cif, void* retValue, void** argValues, void* userData);

class Interop {
public:
    static void RegisterInteropTypes(v8::Isolate* isolate);
    static CFTypeRef CreateBlock(const uint8_t initialParamIndex, const uint8_t argsCount, const TypeEncoding* typeEncoding, FFIMethodCallback callback, void* userData);
    static IMP CreateMethod(const uint8_t initialParamIndex, const uint8_t argsCount, const TypeEncoding* typeEncoding, FFIMethodCallback callback, void* userData);
    static void* CallFunction(v8::Isolate* isolate, const Meta* meta, id target, Class clazz, const std::vector<v8::Local<v8::Value>> args, bool callSuper = false);
private:
    static std::map<const TypeEncoding*, ffi_cif*> cifCache_;

    static void RegisterInteropType(v8::Isolate* isolate, v8::Local<v8::Object> types, std::string name, BinaryTypeEncodingType encodingType);
    static ffi_type* GetArgumentType(const TypeEncoding* typeEncoding);
    static void* GetFunctionPointer(const FunctionMeta* meta);
    template <typename T>
    static void SetArgument(void* buffer, T value);

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
