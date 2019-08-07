#include <Foundation/Foundation.h>
#include "SymbolLoader.h"
#include "Interop.h"
#include "ObjectManager.h"
#include "Helpers.h"
#include "FunctionReference.h"
#include "Reference.h"
#include "Pointer.h"

using namespace v8;

namespace tns {

void Interop::RegisterInteropTypes(Isolate* isolate) {
    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> global = context->Global();

    Local<Object> interop = Object::New(isolate);
    Local<Object> types = Object::New(isolate);

    Reference::Register(isolate, interop);
    Pointer::Register(isolate, interop);
    FunctionReference::Register(isolate, interop);
    RegisterBufferFromDataFunction(isolate, interop);
    RegisterHandleOfFunction(isolate, interop);
    RegisterAllocFunction(isolate, interop);
    RegisterFreeFunction(isolate, interop);
    RegisterAdoptFunction(isolate, interop);
    RegisterSizeOfFunction(isolate, interop);

    RegisterInteropType(isolate, types, "noop", new PrimitiveDataWrapper(ffi_type_pointer.size, BinaryTypeEncodingType::VoidEncoding));
    RegisterInteropType(isolate, types, "void", new PrimitiveDataWrapper(0, BinaryTypeEncodingType::VoidEncoding));
    RegisterInteropType(isolate, types, "bool", new PrimitiveDataWrapper(sizeof(bool), BinaryTypeEncodingType::BoolEncoding));
    RegisterInteropType(isolate, types, "uint8", new PrimitiveDataWrapper(ffi_type_uint8.size, BinaryTypeEncodingType::UShortEncoding));
    RegisterInteropType(isolate, types, "int8", new PrimitiveDataWrapper(ffi_type_sint8.size, BinaryTypeEncodingType::ShortEncoding));
    RegisterInteropType(isolate, types, "uint16", new PrimitiveDataWrapper(ffi_type_uint16.size, BinaryTypeEncodingType::UIntEncoding));
    RegisterInteropType(isolate, types, "int16", new PrimitiveDataWrapper(ffi_type_sint16.size, BinaryTypeEncodingType::IntEncoding));
    RegisterInteropType(isolate, types, "uint32", new PrimitiveDataWrapper(ffi_type_uint32.size, BinaryTypeEncodingType::ULongEncoding));
    RegisterInteropType(isolate, types, "int32", new PrimitiveDataWrapper(ffi_type_sint32.size, BinaryTypeEncodingType::LongEncoding));
    RegisterInteropType(isolate, types, "uint64", new PrimitiveDataWrapper(ffi_type_uint64.size, BinaryTypeEncodingType::ULongLongEncoding));
    RegisterInteropType(isolate, types, "int64", new PrimitiveDataWrapper(ffi_type_sint64.size, BinaryTypeEncodingType::LongLongEncoding));
    RegisterInteropType(isolate, types, "float", new PrimitiveDataWrapper(ffi_type_float.size, BinaryTypeEncodingType::FloatEncoding));
    RegisterInteropType(isolate, types, "double", new PrimitiveDataWrapper(ffi_type_double.size, BinaryTypeEncodingType::DoubleEncoding));

    RegisterInteropType(isolate, types, "id", new PrimitiveDataWrapper(sizeof(void*), BinaryTypeEncodingType::IdEncoding));
    RegisterInteropType(isolate, types, "UTF8CString", new PrimitiveDataWrapper(sizeof(void*), BinaryTypeEncodingType::VoidEncoding));
    RegisterInteropType(isolate, types, "unichar", new PrimitiveDataWrapper(ffi_type_ushort.size, BinaryTypeEncodingType::VoidEncoding));
    RegisterInteropType(isolate, types, "protocol", new PrimitiveDataWrapper(sizeof(void*), BinaryTypeEncodingType::VoidEncoding));
    RegisterInteropType(isolate, types, "class", new PrimitiveDataWrapper(sizeof(void*), BinaryTypeEncodingType::VoidEncoding));
    RegisterInteropType(isolate, types, "selector", new PrimitiveDataWrapper(sizeof(void*), BinaryTypeEncodingType::VoidEncoding));

    bool success = interop->Set(context, tns::ToV8String(isolate, "types"), types).FromMaybe(false);
    assert(success);

    success = global->Set(context, tns::ToV8String(isolate, "interop"), interop).FromMaybe(false);
    assert(success);
}

void Interop::RegisterInteropType(Isolate* isolate, Local<Object> types, std::string name, PrimitiveDataWrapper* wrapper) {
    Local<Context> context = isolate->GetCurrentContext();
    Local<FunctionTemplate> ctorFuncTemplate = FunctionTemplate::New(isolate, nullptr);
    ctorFuncTemplate->SetClassName(tns::ToV8String(isolate, name));
    ctorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);

    Local<v8::Function> ctorFunc;
    if (!ctorFuncTemplate->GetFunction(context).ToLocal(&ctorFunc)) {
        assert(false);
    }

    Local<Value> value;
    if (!ctorFunc->CallAsConstructor(context, 0, nullptr).ToLocal(&value) || value.IsEmpty() || !value->IsObject()) {
        assert(false);
    }
    Local<Object> result = value.As<Object>();

    ObjectManager::Register(isolate, result);

    tns::SetValue(isolate, result, wrapper);
    bool success = types->Set(context, tns::ToV8String(isolate, name), result).FromMaybe(false);
    assert(success);
}

void Interop::RegisterBufferFromDataFunction(v8::Isolate* isolate, v8::Local<v8::Object> interop) {
    Local<Context> context = isolate->GetCurrentContext();
    Local<v8::Function> func;
    bool success = v8::Function::New(context, [](const FunctionCallbackInfo<Value>& info) {
        assert(info.Length() == 1 && info[0]->IsObject());
        Local<Object> arg = info[0].As<Object>();
        assert(arg->InternalFieldCount() > 0 && arg->GetInternalField(0)->IsExternal());

        Local<External> ext = arg->GetInternalField(0).As<External>();
        ObjCDataWrapper* wrapper = static_cast<ObjCDataWrapper*>(ext->Value());

        id obj = wrapper->Data();
        assert([obj isKindOfClass:[NSData class]]);

        Isolate* isolate = info.GetIsolate();
        size_t length = [obj length];
        void* data = const_cast<void*>([obj bytes]);

        Local<ArrayBuffer> result = ArrayBuffer::New(isolate, data, length);
        info.GetReturnValue().Set(result);
    }).ToLocal(&func);
    assert(success);

    success = interop->Set(context, tns::ToV8String(isolate, "bufferFromData"), func).FromMaybe(false);
    assert(success);
}

void Interop::RegisterHandleOfFunction(Isolate* isolate, Local<Object> interop) {
    Local<Context> context = isolate->GetCurrentContext();
    Local<v8::Function> func;
    bool success = v8::Function::New(context, [](const FunctionCallbackInfo<Value>& info) {
        assert(info.Length() == 1);

        Isolate* isolate = info.GetIsolate();
        Local<Value> arg = info[0];

        void* handle = nullptr;
        bool hasHandle = false;

        if (!arg->IsNullOrUndefined()) {
            if (arg->IsArrayBuffer()) {
                Local<ArrayBuffer> buffer = arg.As<ArrayBuffer>();
                ArrayBuffer::Contents contents = buffer->GetContents();
                handle = contents.Data();
                hasHandle = true;
            } else if (arg->IsArrayBufferView()) {
                Local<ArrayBufferView> bufferView = arg.As<ArrayBufferView>();
                ArrayBuffer::Contents contents = bufferView->Buffer()->GetContents();
                handle = contents.Data();
                hasHandle = true;
            } else if (arg->IsObject()) {
                Local<Object> obj = arg.As<Object>();
                if (BaseDataWrapper* wrapper = tns::GetValue(isolate, obj)) {
                    switch (wrapper->Type()) {
                        case WrapperType::ObjCClass: {
                            ObjCClassWrapper* cw = static_cast<ObjCClassWrapper*>(wrapper);
                            @autoreleasepool {
                                CFTypeRef ref = CFBridgingRetain(cw->Klass());
                                handle = const_cast<void*>(ref);
                                CFRelease(ref);
                                hasHandle = true;
                            }
                            break;
                        }
                        case WrapperType::ObjCProtocol: {
                            ObjCProtocolWrapper* pw = static_cast<ObjCProtocolWrapper*>(wrapper);
                            CFTypeRef ref = CFBridgingRetain(pw->Proto());
                            handle = const_cast<void*>(ref);
                            CFRelease(ref);
                            hasHandle = true;
                            break;
                        }
                        case WrapperType::ObjCObject: {
                            ObjCDataWrapper* w = static_cast<ObjCDataWrapper*>(wrapper);
                            @autoreleasepool {
                                id target = w->Data();
                                CFTypeRef ref = CFBridgingRetain(target);
                                handle = const_cast<void*>(ref);
                                hasHandle = true;
                                CFRelease(ref);
                            }
                            break;
                        }
                        case WrapperType::Struct: {
                            StructWrapper* w = static_cast<StructWrapper*>(wrapper);
                            handle = w->Data();
                            hasHandle = true;
                            break;
                        }
                        case WrapperType::Reference: {
                            ReferenceWrapper* w = static_cast<ReferenceWrapper*>(wrapper);
                            if (w->Data() != nullptr) {
                                handle = w->Data();
                                hasHandle = true;
                            }
                            break;
                        }
                        case WrapperType::Pointer: {
                            PointerWrapper* w = static_cast<PointerWrapper*>(wrapper);
                            handle = w->Data();
                            hasHandle = true;
                            break;
                        }
                        case WrapperType::Function: {
                            FunctionWrapper* w = static_cast<FunctionWrapper*>(wrapper);
                            const FunctionMeta* meta = w->Meta();
                            handle = SymbolLoader::instance().loadFunctionSymbol(meta->topLevelModule(), meta->name());
                            hasHandle = true;
                            break;
                        }
                        case WrapperType::FunctionReference: {
                            FunctionReferenceWrapper* w = static_cast<FunctionReferenceWrapper*>(wrapper);
                            if (w->Data() != nullptr) {
                                handle = w->Data();
                                hasHandle = true;
                            }
                            break;
                        }
                        case WrapperType::Block: {
                            BlockWrapper* blockWrapper = static_cast<BlockWrapper*>(wrapper);
                            handle = blockWrapper->Block();
                            hasHandle = true;
                            break;
                        }

                        default:
                            break;
                    }
                }
            }
        } else if (arg->IsNull()) {
            hasHandle = true;
        }

        if (!hasHandle) {
            tns::ThrowError(isolate, "Unknown type");
            return;
        }

        if (handle == nullptr) {
            info.GetReturnValue().Set(Null(isolate));
            return;
        }

        Local<Value> pointerInstance = Pointer::NewInstance(isolate, handle);
        info.GetReturnValue().Set(pointerInstance);
    }).ToLocal(&func);
    assert(success);

    success = interop->Set(context, tns::ToV8String(isolate, "handleof"), func).FromMaybe(false);
    assert(success);
}

void Interop::RegisterAllocFunction(Isolate* isolate, Local<Object> interop) {
    Local<Context> context = isolate->GetCurrentContext();
    Local<v8::Function> func;
    bool success = v8::Function::New(context, [](const FunctionCallbackInfo<Value>& info) {
        assert(info.Length() == 1);
        assert(tns::IsNumber(info[0]));

        Isolate* isolate = info.GetIsolate();
        Local<Context> context = isolate->GetCurrentContext();
        Local<Number> arg = info[0].As<Number>();
        int32_t value;
        assert(arg->Int32Value(context).To(&value));

        size_t size = static_cast<size_t>(value);

        void* data = calloc(size, 1);

        Local<Value> pointerInstance = Pointer::NewInstance(isolate, data);
        PointerWrapper* wrapper = static_cast<PointerWrapper*>(pointerInstance.As<Object>()->GetInternalField(0).As<External>()->Value());
        wrapper->SetAdopted(true);
        info.GetReturnValue().Set(pointerInstance);
    }).ToLocal(&func);
    assert(success);

    success = interop->Set(context, tns::ToV8String(isolate, "alloc"), func).FromMaybe(false);
    assert(success);
}

void Interop::RegisterFreeFunction(Isolate* isolate, Local<Object> interop) {
    Local<Context> context = isolate->GetCurrentContext();
    Local<v8::Function> func;
    bool success = v8::Function::New(context, [](const FunctionCallbackInfo<Value>& info) {
        assert(info.Length() == 1);
        Local<Value> arg = info[0];

        Isolate* isolate = info.GetIsolate();

        BaseDataWrapper* wrapper = tns::GetValue(isolate, arg);
        assert(wrapper->Type() == WrapperType::Pointer);

        PointerWrapper* pw = static_cast<PointerWrapper*>(wrapper);
        if (pw->IsAdopted()) {
            // TODO: throw an error that the pointer is adopted
            return;
        }

        if (pw->Data() != nullptr) {
            std::free(pw->Data());
        }

        info.GetReturnValue().Set(v8::Undefined(isolate));
    }).ToLocal(&func);
    assert(success);

    success = interop->Set(context, tns::ToV8String(isolate, "free"), func).FromMaybe(false);
    assert(success);
}

void Interop::RegisterAdoptFunction(Isolate* isolate, Local<Object> interop) {
    Local<Context> context = isolate->GetCurrentContext();
    Local<v8::Function> func;
    bool success = v8::Function::New(context, [](const FunctionCallbackInfo<Value>& info) {
        assert(info.Length() == 1);
        Local<Value> arg = info[0];

        Isolate* isolate = info.GetIsolate();

        BaseDataWrapper* wrapper = tns::GetValue(isolate, arg);
        assert(wrapper->Type() == WrapperType::Pointer);

        PointerWrapper* pw = static_cast<PointerWrapper*>(wrapper);
        pw->SetAdopted(true);

        info.GetReturnValue().Set(arg);
    }).ToLocal(&func);
    assert(success);

    success = interop->Set(context, tns::ToV8String(isolate, "adopt"), func).FromMaybe(false);
    assert(success);
}

void Interop::RegisterSizeOfFunction(Isolate* isolate, Local<Object> interop) {
    Local<Context> context = isolate->GetCurrentContext();
    Local<v8::Function> func;
    bool success = v8::Function::New(context, [](const FunctionCallbackInfo<Value>& info) {
        assert(info.Length() == 1);
        Local<Value> arg = info[0];
        Isolate* isolate = info.GetIsolate();
        size_t size = 0;

        if (!arg->IsNullOrUndefined()) {
            if (arg->IsObject()) {
                Local<Object> obj = arg.As<Object>();
                if (BaseDataWrapper* wrapper = tns::GetValue(isolate, obj)) {
                    switch (wrapper->Type()) {
                        case WrapperType::ObjCClass:
                        case WrapperType::ObjCProtocol:
                        case WrapperType::ObjCObject:
                        case WrapperType::PointerType:
                        case WrapperType::Pointer:
                        case WrapperType::Reference:
                        case WrapperType::ReferenceType:
                        case WrapperType::Block:
                        case WrapperType::FunctionReference:
                        case WrapperType::FunctionReferenceType:
                        case WrapperType::Function: {
                            size = sizeof(void*);
                            break;
                        }
                        case WrapperType::Primitive: {
                            PrimitiveDataWrapper* pw = static_cast<PrimitiveDataWrapper*>(wrapper);
                            size = pw->Size();
                            break;
                        }
                        case WrapperType::Struct: {
                            StructWrapper* sw = static_cast<StructWrapper*>(wrapper);
                            size = sw->FFIType()->size;
                            break;
                        }
                        case WrapperType::StructType: {
                            StructTypeWrapper* sw = static_cast<StructTypeWrapper*>(wrapper);
                            const StructMeta* structMeta = sw->Meta();
                            std::vector<StructField> fields;
                            ffi_type* ffiType = FFICall::GetStructFFIType(structMeta, fields);
                            size = ffiType->size;
                            break;
                        }
                        default:
                            break;
                    }
                }
            }
        }

        if (size == 0) {
            tns::ThrowError(isolate, "Unknown type");
        } else {
            info.GetReturnValue().Set(Number::New(isolate, size));
        }
    }).ToLocal(&func);
    assert(success);

    success = interop->Set(context, tns::ToV8String(isolate, "sizeof"), func).FromMaybe(false);
    assert(success);
}

}
