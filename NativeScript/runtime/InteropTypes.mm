#include <Foundation/Foundation.h>
#include "SymbolLoader.h"
#include "Interop.h"
#include "ObjectManager.h"
#include "Helpers.h"
#include "Caches.h"
#include "NativeScriptException.h"
#include "FunctionReference.h"
#include "Reference.h"
#include "Pointer.h"

using namespace v8;

namespace tns {

void Interop::RegisterInteropTypes(Local<Context> context) {
    Isolate* isolate = context->GetIsolate();
    Local<Object> global = context->Global();

    Local<Object> interop = Object::New(isolate);
    Local<Object> types = Object::New(isolate);

    Reference::Register(context, interop);
    Pointer::Register(context, interop);
    FunctionReference::Register(context, interop);
    RegisterBufferFromDataFunction(context, interop);
    RegisterHandleOfFunction(context, interop);
    RegisterAllocFunction(context, interop);
    RegisterFreeFunction(context, interop);
    RegisterAdoptFunction(context, interop);
    RegisterSizeOfFunction(context, interop);

    RegisterInteropType(context, types, "noop", new PrimitiveDataWrapper(ffi_type_pointer.size, CreateEncoding(BinaryTypeEncodingType::VoidEncoding)));
    RegisterInteropType(context, types, "void", new PrimitiveDataWrapper(0, CreateEncoding(BinaryTypeEncodingType::VoidEncoding)));
    RegisterInteropType(context, types, "bool", new PrimitiveDataWrapper(sizeof(bool), CreateEncoding(BinaryTypeEncodingType::BoolEncoding)));
    RegisterInteropType(context, types, "uint8", new PrimitiveDataWrapper(ffi_type_uint8.size, CreateEncoding(BinaryTypeEncodingType::UCharEncoding)));
    RegisterInteropType(context, types, "int8", new PrimitiveDataWrapper(ffi_type_sint8.size, CreateEncoding(BinaryTypeEncodingType::CharEncoding)));
    RegisterInteropType(context, types, "uint16", new PrimitiveDataWrapper(ffi_type_uint16.size, CreateEncoding(BinaryTypeEncodingType::UShortEncoding)));
    RegisterInteropType(context, types, "int16", new PrimitiveDataWrapper(ffi_type_sint16.size, CreateEncoding(BinaryTypeEncodingType::ShortEncoding)));
    RegisterInteropType(context, types, "uint32", new PrimitiveDataWrapper(ffi_type_uint32.size, CreateEncoding(BinaryTypeEncodingType::UIntEncoding)));
    RegisterInteropType(context, types, "int32", new PrimitiveDataWrapper(ffi_type_sint32.size, CreateEncoding(BinaryTypeEncodingType::IntEncoding)));
    RegisterInteropType(context, types, "uint64", new PrimitiveDataWrapper(ffi_type_uint64.size, CreateEncoding(BinaryTypeEncodingType::ULongEncoding)));
    RegisterInteropType(context, types, "int64", new PrimitiveDataWrapper(ffi_type_sint64.size, CreateEncoding(BinaryTypeEncodingType::LongEncoding)));
    RegisterInteropType(context, types, "ulong", new PrimitiveDataWrapper(ffi_type_ulong.size, CreateEncoding(BinaryTypeEncodingType::ULongLongEncoding)));
    RegisterInteropType(context, types, "slong", new PrimitiveDataWrapper(ffi_type_slong.size, CreateEncoding(BinaryTypeEncodingType::LongLongEncoding)));
    RegisterInteropType(context, types, "float", new PrimitiveDataWrapper(ffi_type_float.size, CreateEncoding(BinaryTypeEncodingType::FloatEncoding)));
    RegisterInteropType(context, types, "double", new PrimitiveDataWrapper(ffi_type_double.size, CreateEncoding(BinaryTypeEncodingType::DoubleEncoding)));

    RegisterInteropType(context, types, "id", new PrimitiveDataWrapper(sizeof(void*), CreateEncoding(BinaryTypeEncodingType::IdEncoding)));
//    RegisterInteropType(context, types, "UTF8CString", new PrimitiveDataWrapper(sizeof(void*), CreateEncoding(BinaryTypeEncodingType::VoidEncoding)));
    RegisterInteropType(context, types, "unichar", new PrimitiveDataWrapper(ffi_type_ushort.size, CreateEncoding(BinaryTypeEncodingType::UnicharEncoding)));
    RegisterInteropType(context, types, "protocol", new PrimitiveDataWrapper(sizeof(void*), CreateEncoding(BinaryTypeEncodingType::ProtocolEncoding)));
    RegisterInteropType(context, types, "class", new PrimitiveDataWrapper(sizeof(void*), CreateEncoding(BinaryTypeEncodingType::ClassEncoding)));
    RegisterInteropType(context, types, "selector", new PrimitiveDataWrapper(sizeof(void*), CreateEncoding(BinaryTypeEncodingType::SelectorEncoding)));

    bool success = interop->Set(context, tns::ToV8String(isolate, "types"), types).FromMaybe(false);
    tns::Assert(success, isolate);

    success = global->Set(context, tns::ToV8String(isolate, "interop"), interop).FromMaybe(false);
    tns::Assert(success, isolate);
}

Local<Object> Interop::GetInteropType(Local<Context> context, BinaryTypeEncodingType type) {
    Isolate* isolate = context->GetIsolate();
    std::shared_ptr<Caches> cache = Caches::Get(isolate);
    auto it = cache->PrimitiveInteropTypes.find(type);
    if (it != cache->PrimitiveInteropTypes.end()) {
        return it->second->Get(isolate);
    }

    return Local<Object>();
}

void Interop::RegisterInteropType(Local<Context> context, Local<Object> types, std::string name, PrimitiveDataWrapper* wrapper) {
    Isolate* isolate = context->GetIsolate();
    Local<FunctionTemplate> ctorFuncTemplate = FunctionTemplate::New(isolate, nullptr);
    ctorFuncTemplate->SetClassName(tns::ToV8String(isolate, name));
    ctorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);

    Local<v8::Function> ctorFunc;
    if (!ctorFuncTemplate->GetFunction(context).ToLocal(&ctorFunc)) {
        tns::Assert(false, isolate);
    }

    Local<Value> value;
    if (!ctorFunc->CallAsConstructor(context, 0, nullptr).ToLocal(&value) || value.IsEmpty() || !value->IsObject()) {
        tns::Assert(false, isolate);
    }
    Local<Object> result = value.As<Object>();

    tns::SetValue(isolate, result, wrapper);
    bool success = types->Set(context, tns::ToV8String(isolate, name), result).FromMaybe(false);

    BinaryTypeEncodingType type = wrapper->TypeEncoding()->type;
    std::shared_ptr<Caches> cache = Caches::Get(isolate);
    auto it = cache->PrimitiveInteropTypes.find(type);
    if (it == cache->PrimitiveInteropTypes.end()) {
        cache->PrimitiveInteropTypes.emplace(type, std::make_unique<Persistent<Object>>(isolate, result));
    }

    tns::Assert(success, isolate);
}

void Interop::RegisterBufferFromDataFunction(Local<Context> context, Local<Object> interop) {
    Local<v8::Function> func;
    bool success = v8::Function::New(context, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        tns::Assert(info.Length() == 1 && info[0]->IsObject(), isolate);
        Local<Object> arg = info[0].As<Object>();
        tns::Assert(arg->InternalFieldCount() > 0 && arg->GetInternalField(0)->IsExternal(), isolate);

        Local<External> ext = arg->GetInternalField(0).As<External>();
        ObjCDataWrapper* wrapper = static_cast<ObjCDataWrapper*>(ext->Value());

        id obj = wrapper->Data();
        tns::Assert([obj isKindOfClass:[NSData class]], isolate);

        size_t length = [obj length];
        void* data = const_cast<void*>([obj bytes]);

        std::unique_ptr<v8::BackingStore> backingStore = ArrayBuffer::NewBackingStore(data, length, [](void*, size_t, void*) { }, nullptr);

        Local<ArrayBuffer> result = ArrayBuffer::New(isolate, std::move(backingStore));
        info.GetReturnValue().Set(result);
    }).ToLocal(&func);

    Isolate* isolate = context->GetIsolate();
    tns::Assert(success, isolate);

    success = interop->Set(context, tns::ToV8String(isolate, "bufferFromData"), func).FromMaybe(false);
    tns::Assert(success, isolate);
}

void Interop::RegisterHandleOfFunction(Local<Context> context, Local<Object> interop) {
    Local<v8::Function> func;
    bool success = v8::Function::New(context, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        Local<Context> context = isolate->GetCurrentContext();
        tns::Assert(info.Length() == 1, isolate);
        try {
            Local<Value> arg = info[0];

            Local<Value> result = Interop::HandleOf(context, arg);
            if (result.IsEmpty()) {
                throw NativeScriptException("Unknown type");
            }

            info.GetReturnValue().Set(result);
        } catch (NativeScriptException& ex) {
            ex.ReThrowToV8(isolate);
        }
    }).ToLocal(&func);

    Isolate* isolate = context->GetIsolate();
    tns::Assert(success, isolate);

    success = interop->Set(context, tns::ToV8String(isolate, "handleof"), func).FromMaybe(false);
    tns::Assert(success, isolate);
}

void Interop::RegisterAllocFunction(Local<Context> context, Local<Object> interop) {
    Local<v8::Function> func;
    bool success = v8::Function::New(context, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        tns::Assert(info.Length() == 1, isolate);
        tns::Assert(tns::IsNumber(info[0]), isolate);

        Local<Context> context = isolate->GetCurrentContext();
        Local<Number> arg = info[0].As<Number>();
        int32_t value;
        tns::Assert(arg->Int32Value(context).To(&value), isolate);

        size_t size = static_cast<size_t>(value);

        void* data = calloc(1, size);

        Local<Value> pointerInstance = Pointer::NewInstance(context, data);
        PointerWrapper* wrapper = static_cast<PointerWrapper*>(pointerInstance.As<Object>()->GetInternalField(0).As<External>()->Value());
        wrapper->SetAdopted(true);
        info.GetReturnValue().Set(pointerInstance);
    }).ToLocal(&func);

    Isolate* isolate = context->GetIsolate();
    tns::Assert(success, isolate);

    success = interop->Set(context, tns::ToV8String(isolate, "alloc"), func).FromMaybe(false);
    tns::Assert(success, isolate);
}

void Interop::RegisterFreeFunction(Local<Context> context, Local<Object> interop) {
    Local<v8::Function> func;
    bool success = v8::Function::New(context, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        tns::Assert(info.Length() == 1, isolate);
        Local<Value> arg = info[0];

        BaseDataWrapper* wrapper = tns::GetValue(isolate, arg);
        tns::Assert(wrapper->Type() == WrapperType::Pointer, isolate);

        PointerWrapper* pw = static_cast<PointerWrapper*>(wrapper);
        if (pw->IsAdopted()) {
            // TODO: throw an error that the pointer is adopted
            return;
        }

        if (pw->Data() != nullptr) {
            std::free(pw->Data());
        }

        info.GetReturnValue().SetUndefined();
    }).ToLocal(&func);

    Isolate* isolate = context->GetIsolate();
    tns::Assert(success, isolate);

    success = interop->Set(context, tns::ToV8String(isolate, "free"), func).FromMaybe(false);
    tns::Assert(success, isolate);
}

void Interop::RegisterAdoptFunction(Local<Context> context, Local<Object> interop) {
    Local<v8::Function> func;
    bool success = v8::Function::New(context, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        tns::Assert(info.Length() == 1, isolate);
        Local<Value> arg = info[0];

        BaseDataWrapper* wrapper = tns::GetValue(isolate, arg);
        tns::Assert(wrapper->Type() == WrapperType::Pointer, isolate);

        PointerWrapper* pw = static_cast<PointerWrapper*>(wrapper);
        pw->SetAdopted(true);

        info.GetReturnValue().Set(arg);
    }).ToLocal(&func);

    Isolate* isolate = context->GetIsolate();
    tns::Assert(success, isolate);

    success = interop->Set(context, tns::ToV8String(isolate, "adopt"), func).FromMaybe(false);
    tns::Assert(success, isolate);
}

void Interop::RegisterSizeOfFunction(Local<Context> context, Local<Object> interop) {
    Local<v8::Function> func;
    bool success = v8::Function::New(context, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        tns::Assert(info.Length() == 1, isolate);
        try {
            Local<Value> arg = info[0];
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
                                size = sw->StructInfo().FFIType()->size;
                                break;
                            }
                            case WrapperType::StructType: {
                                StructTypeWrapper* sw = static_cast<StructTypeWrapper*>(wrapper);
                                StructInfo structInfo = sw->StructInfo();
                                size = structInfo.FFIType()->size;
                                break;
                            }
                            default:
                                break;
                        }
                    }
                }
            }

            if (size == 0) {
                throw NativeScriptException("Unknown type");
            } else {
                info.GetReturnValue().Set((double)size);
            }
        } catch (NativeScriptException& ex) {
            ex.ReThrowToV8(isolate);
        }
    }).ToLocal(&func);

    Isolate* isolate = context->GetIsolate();
    tns::Assert(success, isolate);

    success = interop->Set(context, tns::ToV8String(isolate, "sizeof"), func).FromMaybe(false);
    tns::Assert(success, isolate);
}

const TypeEncoding* Interop::CreateEncoding(BinaryTypeEncodingType type) {
    TypeEncoding* typeEncoding = reinterpret_cast<TypeEncoding*>(calloc(1, sizeof(TypeEncoding)));
    typeEncoding->type = type;

    return typeEncoding;
}

Local<Value> Interop::HandleOf(Local<Context> context, Local<Value> value) {
    Isolate* isolate = context->GetIsolate();
    if (!value->IsNullOrUndefined()) {
        if (value->IsArrayBuffer()) {
            Local<ArrayBuffer> buffer = value.As<ArrayBuffer>();
            std::shared_ptr<BackingStore> backingStore = buffer->GetBackingStore();
            return Pointer::NewInstance(context, backingStore->Data());
        } else if (value->IsArrayBufferView()) {
            Local<ArrayBufferView> bufferView = value.As<ArrayBufferView>();
            std::shared_ptr<BackingStore> backingStore = bufferView->Buffer()->GetBackingStore();
            return Pointer::NewInstance(context, backingStore->Data());
        } else if (value->IsObject()) {
            Local<Object> obj = value.As<Object>();
            if (BaseDataWrapper* wrapper = tns::GetValue(isolate, obj)) {
                switch (wrapper->Type()) {
                    case WrapperType::Primitive: {
                        PrimitiveDataWrapper* pdw = static_cast<PrimitiveDataWrapper*>(wrapper);
                        void* handle = pdw;
                        return Pointer::NewInstance(context, handle);
                    }
                    case WrapperType::ObjCClass: {
                        ObjCClassWrapper* cw = static_cast<ObjCClassWrapper*>(wrapper);
                        @autoreleasepool {
                            CFTypeRef ref = CFBridgingRetain(cw->Klass());
                            void* handle = const_cast<void*>(ref);
                            CFRelease(ref);
                            return Pointer::NewInstance(context, handle);
                        }
                        break;
                    }
                    case WrapperType::ObjCProtocol: {
                        ObjCProtocolWrapper* pw = static_cast<ObjCProtocolWrapper*>(wrapper);
                        CFTypeRef ref = CFBridgingRetain(pw->Proto());
                        void* handle = const_cast<void*>(ref);
                        CFRelease(ref);
                        return Pointer::NewInstance(context, handle);
                    }
                    case WrapperType::ObjCObject: {
                        ObjCDataWrapper* w = static_cast<ObjCDataWrapper*>(wrapper);
                        @autoreleasepool {
                            id target = w->Data();
                            CFTypeRef ref = CFBridgingRetain(target);
                            void* handle = const_cast<void*>(ref);
                            CFRelease(ref);
                            return Pointer::NewInstance(context, handle);
                        }
                        break;
                    }
                    case WrapperType::Struct: {
                        StructWrapper* w = static_cast<StructWrapper*>(wrapper);
                        return Pointer::NewInstance(context, w->Data());
                    }
                    case WrapperType::Reference: {
                        ReferenceWrapper* w = static_cast<ReferenceWrapper*>(wrapper);
                        if (w->Value() != nullptr) {
                            Local<Value> wrappedValue = w->Value()->Get(isolate);
                            if (tns::GetValue(isolate, wrappedValue) == nullptr) {
                                return Pointer::NewInstance(context, w->Value());
                            }
                            return HandleOf(context, wrappedValue);
                        } else if (w->Data() != nullptr) {
                            return Pointer::NewInstance(context, w->Data());
                        }
                        break;
                    }
                    case WrapperType::Pointer: {
                        return value;
                    }
                    case WrapperType::Function: {
                        FunctionWrapper* w = static_cast<FunctionWrapper*>(wrapper);
                        const FunctionMeta* meta = w->Meta();
                        void* handle = SymbolLoader::instance().loadFunctionSymbol(meta->topLevelModule(), meta->name());
                        return Pointer::NewInstance(context, handle);
                    }
                    case WrapperType::FunctionReference: {
                        FunctionReferenceWrapper* w = static_cast<FunctionReferenceWrapper*>(wrapper);
                        if (w->Data() != nullptr) {
                            return Pointer::NewInstance(context, w->Data());
                        }
                        break;
                    }
                    case WrapperType::Block: {
                        BlockWrapper* blockWrapper = static_cast<BlockWrapper*>(wrapper);
                        return Pointer::NewInstance(context, blockWrapper->Block());
                    }
                    default:
                        break;
                }
            }
        }
    } else if (value->IsNull()) {
        return v8::Null(isolate);
    }

    return Local<Value>();
}

}
