#include <objc/message.h>
#include "Interop.h"
#include "SymbolLoader.h"

using namespace v8;

namespace tns {

template <typename TMeta>
inline Local<Value> Interop::CallFunction(Isolate* isolate, const TMeta* meta, id target, Class clazz, const std::vector<Local<Value>> args, bool callSuper) {
    void* functionPointer = nullptr;
    SEL selector = nil;
    int initialParameterIndex = 0;
    const TypeEncoding* typeEncoding = nullptr;
    bool isPrimitiveFunction = false;

    if constexpr(std::is_same_v<TMeta, FunctionMeta>) {
        const FunctionMeta* functionMeta = static_cast<const FunctionMeta*>(meta);
        functionPointer = SymbolLoader::instance().loadFunctionSymbol(functionMeta->topLevelModule(), meta->name());
        if (!functionPointer) {
            NSLog(@"Unable to load \"%s\" function", functionMeta->name());
            assert(false);
        }
        typeEncoding = functionMeta->encodings()->first();
        isPrimitiveFunction = true;
    } else if constexpr(std::is_same_v<TMeta, MethodMeta>) {
        const MethodMeta* methodMeta = static_cast<const MethodMeta*>(meta);
        initialParameterIndex = 2;
        typeEncoding = methodMeta->encodings()->first();
        selector = methodMeta->selector();
        if (callSuper) {
            functionPointer = (void*)objc_msgSendSuper;
        } else {
            functionPointer = (void*)objc_msgSend;
        }
    } else {
        assert(false);
    }

    int argsCount = initialParameterIndex + (int)args.size();

    ffi_cif* cif = FFICall::GetCif(typeEncoding, initialParameterIndex, argsCount);

    FFICall call(cif);

    std::unique_ptr<objc_super> sup = std::unique_ptr<objc_super>(new objc_super());

    bool isInstanceMethod = (target && target != nil);

    if (initialParameterIndex > 1) {
#if defined(__x86_64__)
        if (meta->type() == MetaType::Undefined || meta->type() == MetaType::Union) {
            const unsigned UNIX64_FLAG_RET_IN_MEM = (1 << 10);

            ffi_type* returnType = FFICall::GetArgumentType(typeEncoding);

            if (returnType->type == FFI_TYPE_LONGDOUBLE) {
                functionPointer = (void*)objc_msgSend_fpret;
            } else if (returnType->type == FFI_TYPE_STRUCT && (cif->flags & UNIX64_FLAG_RET_IN_MEM)) {
                if (callSuper) {
                    functionPointer = (void*)objc_msgSendSuper_stret;
                } else {
                    functionPointer = (void*)objc_msgSend_stret;
                }
            }
        }
#endif

        if (isInstanceMethod) {
            if (callSuper) {
                sup->receiver = target;
                sup->super_class = class_getSuperclass(object_getClass(target));
                Interop::SetValue(call.ArgumentBuffer(0), sup.get());
            } else {
                Interop::SetValue(call.ArgumentBuffer(0), target);
            }
        } else {
            Interop::SetValue(call.ArgumentBuffer(0), clazz);
        }

        Interop::SetValue(call.ArgumentBuffer(1), selector);
    }

    bool isInstanceReturnType = typeEncoding->type == BinaryTypeEncodingType::InstanceTypeEncoding;
    bool marshalToPrimitive = isPrimitiveFunction || !isInstanceReturnType;

    @autoreleasepool {
        Interop::SetFFIParams(isolate, typeEncoding, &call, argsCount, initialParameterIndex, args);
    }

    ffi_call(cif, FFI_FN(functionPointer), call.ResultBuffer(), call.ArgsArray());

    @autoreleasepool {
        Local<Value> result = Interop::GetResult(isolate, typeEncoding, &call, marshalToPrimitive, nullptr);

        return result;
    }
}

inline id Interop::CallInitializer(Isolate* isolate, const MethodMeta* methodMeta, id target, Class clazz, const std::vector<Local<Value>> args) {
    const TypeEncoding* typeEncoding = methodMeta->encodings()->first();
    SEL selector = methodMeta->selector();
    void* functionPointer = (void*)objc_msgSend;

    int initialParameterIndex = 2;
    int argsCount = initialParameterIndex + (int)args.size();

    ffi_cif* cif = FFICall::GetCif(typeEncoding, initialParameterIndex, argsCount);
    FFICall call(cif);

    Interop::SetValue(call.ArgumentBuffer(0), target);
    Interop::SetValue(call.ArgumentBuffer(1), selector);
    Interop::SetFFIParams(isolate, typeEncoding, &call, argsCount, initialParameterIndex, args);

    ffi_call(cif, FFI_FN(functionPointer), call.ResultBuffer(), call.ArgsArray());

    id result = call.GetResult<id>();

    return result;
}

}
