#include <Foundation/Foundation.h>
#include "ArgConverter.h"
#include "Caches.h"
#include "Constants.h"
#include "ExternalMemory.h"
#include "FunctionReference.h"
#include "Helpers.h"
#include "Interop.h"
#include "NativeScriptException.h"
#include "ObjectManager.h"
#include "Pointer.h"
#include "Reference.h"
#include "SymbolLoader.h"

using namespace v8;

namespace tns {

void Interop::RegisterInteropTypes(Local<Context> context) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<Object> global = context->Global();

  Local<Object> interop = Object::New(isolate);
  Local<Object> types = Object::New(isolate);

  Reference::Register(context, interop);
  Pointer::Register(context, interop);
  FunctionReference::Register(context, interop);
  RegisterBufferFromDataFunction(context, interop);
  RegisterStringFromCString(context, interop);
  RegisterHandleOfFunction(context, interop);
  RegisterAllocFunction(context, interop);
  RegisterFreeFunction(context, interop);
  RegisterAdoptFunction(context, interop);
  RegisterExternalSizeFunctions(context, interop);
  RegisterSizeOfFunction(context, interop);
  RegisterEscapeExceptionFunction(context, interop);

  RegisterInteropType(
      context, types, "noop",
      new PrimitiveDataWrapper(ffi_type_pointer.size,
                               CreateEncoding(BinaryTypeEncodingType::VoidEncoding), true));
  RegisterInteropType(
      context, types, "void",
      new PrimitiveDataWrapper(0, CreateEncoding(BinaryTypeEncodingType::VoidEncoding), true));
  RegisterInteropType(
      context, types, "bool",
      new PrimitiveDataWrapper(sizeof(bool), CreateEncoding(BinaryTypeEncodingType::BoolEncoding),
                               true));
  RegisterInteropType(
      context, types, "uint8",
      new PrimitiveDataWrapper(ffi_type_uint8.size,
                               CreateEncoding(BinaryTypeEncodingType::UCharEncoding), true));
  RegisterInteropType(
      context, types, "int8",
      new PrimitiveDataWrapper(ffi_type_sint8.size,
                               CreateEncoding(BinaryTypeEncodingType::CharEncoding), true));
  RegisterInteropType(
      context, types, "uint16",
      new PrimitiveDataWrapper(ffi_type_uint16.size,
                               CreateEncoding(BinaryTypeEncodingType::UShortEncoding), true));
  RegisterInteropType(
      context, types, "int16",
      new PrimitiveDataWrapper(ffi_type_sint16.size,
                               CreateEncoding(BinaryTypeEncodingType::ShortEncoding), true));
  RegisterInteropType(
      context, types, "uint32",
      new PrimitiveDataWrapper(ffi_type_uint32.size,
                               CreateEncoding(BinaryTypeEncodingType::UIntEncoding), true));
  RegisterInteropType(
      context, types, "int32",
      new PrimitiveDataWrapper(ffi_type_sint32.size,
                               CreateEncoding(BinaryTypeEncodingType::IntEncoding), true));
  RegisterInteropType(
      context, types, "uint64",
      new PrimitiveDataWrapper(ffi_type_uint64.size,
                               CreateEncoding(BinaryTypeEncodingType::ULongEncoding), true));
  RegisterInteropType(
      context, types, "int64",
      new PrimitiveDataWrapper(ffi_type_sint64.size,
                               CreateEncoding(BinaryTypeEncodingType::LongEncoding), true));
  RegisterInteropType(
      context, types, "ulong",
      new PrimitiveDataWrapper(ffi_type_ulong.size,
                               CreateEncoding(BinaryTypeEncodingType::ULongLongEncoding), true));
  RegisterInteropType(
      context, types, "slong",
      new PrimitiveDataWrapper(ffi_type_slong.size,
                               CreateEncoding(BinaryTypeEncodingType::LongLongEncoding), true));
  RegisterInteropType(
      context, types, "float",
      new PrimitiveDataWrapper(ffi_type_float.size,
                               CreateEncoding(BinaryTypeEncodingType::FloatEncoding), true));
  RegisterInteropType(
      context, types, "double",
      new PrimitiveDataWrapper(ffi_type_double.size,
                               CreateEncoding(BinaryTypeEncodingType::DoubleEncoding), true));

  RegisterInteropType(context, types, "id",
                      new PrimitiveDataWrapper(
                          sizeof(void*), CreateEncoding(BinaryTypeEncodingType::IdEncoding), true));
  //    RegisterInteropType(context, types, "UTF8CString", new PrimitiveDataWrapper(sizeof(void*),
  //    CreateEncoding(BinaryTypeEncodingType::VoidEncoding)));
  RegisterInteropType(
      context, types, "unichar",
      new PrimitiveDataWrapper(ffi_type_ushort.size,
                               CreateEncoding(BinaryTypeEncodingType::UnicharEncoding), true));
  RegisterInteropType(
      context, types, "protocol",
      new PrimitiveDataWrapper(sizeof(void*),
                               CreateEncoding(BinaryTypeEncodingType::ProtocolEncoding), true));
  RegisterInteropType(
      context, types, "class",
      new PrimitiveDataWrapper(sizeof(void*), CreateEncoding(BinaryTypeEncodingType::ClassEncoding),
                               true));
  RegisterInteropType(
      context, types, "selector",
      new PrimitiveDataWrapper(sizeof(void*),
                               CreateEncoding(BinaryTypeEncodingType::SelectorEncoding), true));

  bool success = interop->Set(context, tns::ToV8String(isolate, "types"), types).FromMaybe(false);
  tns::Assert(success, isolate);

  success = global->Set(context, tns::ToV8String(isolate, "interop"), interop).FromMaybe(false);
  tns::Assert(success, isolate);
}

Local<Object> Interop::GetInteropType(Local<Context> context, BinaryTypeEncodingType type) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  auto it = cache->PrimitiveInteropTypes.find(type);
  if (it != cache->PrimitiveInteropTypes.end()) {
    return it->second->Get(isolate);
  }

  return Local<Object>();
}

void Interop::RegisterInteropType(Local<Context> context, Local<Object> types, std::string name,
                                  PrimitiveDataWrapper* wrapper, bool autoDelete) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<FunctionTemplate> ctorFuncTemplate = FunctionTemplate::New(isolate, nullptr);
  ctorFuncTemplate->SetClassName(tns::ToV8String(isolate, name));
  ctorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);

  Local<v8::Function> ctorFunc;
  if (!ctorFuncTemplate->GetFunction(context).ToLocal(&ctorFunc)) {
    tns::Assert(false, isolate);
  }

  Local<Value> value;
  if (!ctorFunc->CallAsConstructor(context, 0, nullptr).ToLocal(&value) || value.IsEmpty() ||
      !value->IsObject()) {
    tns::Assert(false, isolate);
  }
  Local<Object> result = value.As<Object>();

  tns::SetValue(isolate, result, wrapper);
  bool success = types->Set(context, tns::ToV8String(isolate, name), result).FromMaybe(false);

  BinaryTypeEncodingType type = wrapper->TypeEncoding()->type;
  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  auto it = cache->PrimitiveInteropTypes.find(type);
  if (it == cache->PrimitiveInteropTypes.end()) {
    auto persistentObj = std::make_unique<Persistent<Object>>(isolate, result);
    if (autoDelete) {
      persistentObj->SetWrapperClassId(Constants::ClassTypes::DataWrapper);
    }
    cache->PrimitiveInteropTypes.emplace(type, std::move(persistentObj));
  } else if (autoDelete) {
    // TODO: review this. We send the void encoding multiple times so this is just a dirty fallback
    // maybe we should have another method on the ObjectManager for cleaning up these
    cache->registerCacheBoundObject(wrapper);
  }

  tns::Assert(success, isolate);
}

void Interop::RegisterBufferFromDataFunction(Local<Context> context, Local<Object> interop) {
  Local<v8::Function> func;
  bool success =
      v8::Function::New(context, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        tns::Assert(info.Length() == 1 && info[0]->IsObject(), isolate);
        Local<Object> arg = info[0].As<Object>();

        BaseDataWrapper* baseWrapper =
            tns::GetValueOrReport(isolate, arg, "interop.bufferFromData");
        if (baseWrapper == nullptr) {
          return;
        }
        tns::Assert(baseWrapper->Type() == WrapperType::ObjCObject, isolate);
        ObjCDataWrapper* wrapper = static_cast<ObjCDataWrapper*>(baseWrapper);

        id obj = wrapper->Data();
        tns::Assert([obj isKindOfClass:[NSData class]], isolate);

        size_t length = [obj length];
        void* data = const_cast<void*>([obj bytes]);

        // Take a +1 retain so the NSData outlives autorelease pool drains while
        // the ArrayBuffer is alive. The deleter below releases this retain when
        // V8 finalises the BackingStore (i.e. the ArrayBuffer is GC'd / detached).
        [obj retain];

        std::unique_ptr<v8::BackingStore> backingStore = ArrayBuffer::NewBackingStore(
            data, length,
            [](void* /*data*/, size_t /*length*/, void* deleter_data) {
              if (deleter_data != nullptr) {
                [(id)deleter_data release];
              }
            },
            obj);

        Local<ArrayBuffer> result = ArrayBuffer::New(isolate, std::move(backingStore));
        info.GetReturnValue().Set(result);
      }).ToLocal(&func);

  Isolate* isolate = v8::Isolate::GetCurrent();
  tns::Assert(success, isolate);

  success =
      interop->Set(context, tns::ToV8String(isolate, "bufferFromData"), func).FromMaybe(false);
  tns::Assert(success, isolate);
}

void Interop::RegisterStringFromCString(Local<Context> context, Local<Object> interop) {
  Local<v8::Function> func;
  bool success =
      v8::Function::New(context, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        tns::Assert(info.Length() >= 1 && info[0]->IsObject(), isolate);
        Local<Object> arg = info[0].As<Object>();
        int stringLength = -1;
        if (info.Length() >= 2 && !info[1].IsEmpty() && !info[1]->IsNullOrUndefined()) {
          auto desiredLength = ToNumber(isolate, info[1]);
          if (desiredLength != NAN) {
            stringLength = desiredLength;
          }
        }
        BaseDataWrapper* wrapper = tns::GetValueOrReport(isolate, arg, "interop.stringFromCString");
        if (wrapper == nullptr) {
          return;
        }
        char* data = nullptr;
        switch (wrapper->Type()) {
          case WrapperType::Pointer: {
            PointerWrapper* pointerWrapper = static_cast<PointerWrapper*>(wrapper);
            data = static_cast<char*>(pointerWrapper->Data());
          } break;
          case WrapperType::Reference: {
            ReferenceWrapper* referenceWrapper = static_cast<ReferenceWrapper*>(wrapper);
            if (referenceWrapper->Data() != nullptr) {
              data = static_cast<char*>(referenceWrapper->Data());
              break;
            }
            auto wrappedValue = referenceWrapper->Value()->Get(isolate);
            auto wrappedWrapper = tns::GetValue(isolate, wrappedValue);
            tns::Assert(wrappedWrapper->Type() == WrapperType::Pointer);
            data = static_cast<char*>((static_cast<PointerWrapper*>(wrappedWrapper))->Data());
          }
          default:
            break;
        }
        tns::Assert(data != nullptr);

        auto result =
            v8::String::NewFromUtf8(isolate, data, v8::NewStringType::kNormal, stringLength)
                .ToLocalChecked();
        info.GetReturnValue().Set(result);
      }).ToLocal(&func);

  Isolate* isolate = v8::Isolate::GetCurrent();
  tns::Assert(success, isolate);

  success =
      interop->Set(context, tns::ToV8String(isolate, "stringFromCString"), func).FromMaybe(false);
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

  Isolate* isolate = v8::Isolate::GetCurrent();
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
                   PointerWrapper* wrapper = static_cast<PointerWrapper*>(
                       pointerInstance.As<Object>()->GetInternalField(0).As<External>()->Value(
                           v8::kExternalPointerTypeTagDefault));
                   wrapper->SetAdopted(true);
                   ExternalMemory::SetSize(isolate, wrapper, size);
                   info.GetReturnValue().Set(pointerInstance);
                 }).ToLocal(&func);

  Isolate* isolate = v8::Isolate::GetCurrent();
  tns::Assert(success, isolate);

  success = interop->Set(context, tns::ToV8String(isolate, "alloc"), func).FromMaybe(false);
  tns::Assert(success, isolate);
}

// Wrappers that die with their JS object. Class, protocol and type wrappers
// live as long as the isolate, so a charge on them could never be returned.
static BaseDataWrapper* GetChargeableWrapper(Isolate* isolate, Local<Value> value) {
  BaseDataWrapper* wrapper = tns::GetValue(isolate, value);
  if (wrapper == nullptr) {
    return nullptr;
  }
  switch (wrapper->Type()) {
    case WrapperType::ObjCObject:
    case WrapperType::Pointer:
    case WrapperType::Reference:
    case WrapperType::Struct:
    case WrapperType::Block:
    case WrapperType::FunctionReference:
    case WrapperType::ExtVector:
      return wrapper;
    default:
      return nullptr;
  }
}

void Interop::RegisterExternalSizeFunctions(Local<Context> context, Local<Object> interop) {
  Isolate* isolate = v8::Isolate::GetCurrent();

  Local<v8::Function> setFunc;
  bool success =
      v8::Function::New(
          context,
          [](const FunctionCallbackInfo<Value>& info) {
            Isolate* isolate = info.GetIsolate();
            BaseDataWrapper* wrapper = GetChargeableWrapper(isolate, info[0]);
            if (wrapper == nullptr) {
              isolate->ThrowException(Exception::TypeError(tns::ToV8String(
                  isolate, "interop.setExternalSize expects a native object, pointer, "
                           "reference, struct or block instance")));
              return;
            }
            // Below V8's sanity limit on a single adjustment, which aborts the
            // process rather than throwing.
            constexpr double kMaxBytes = static_cast<double>(1ull << 34);
            double bytes = info[1]->IsNumber() ? info[1].As<Number>()->Value() : -1;
            if (!(bytes >= 0 && bytes <= kMaxBytes)) {
              isolate->ThrowException(Exception::RangeError(tns::ToV8String(
                  isolate, "interop.setExternalSize expects a byte count between 0 and 2^34")));
              return;
            }
            ExternalMemory::SetSize(isolate, wrapper, static_cast<size_t>(bytes));
          },
          Local<Value>(), 2)
          .ToLocal(&setFunc);
  tns::Assert(success, isolate);
  success =
      interop->Set(context, tns::ToV8String(isolate, "setExternalSize"), setFunc).FromMaybe(false);
  tns::Assert(success, isolate);

  Local<v8::Function> getFunc;
  success = v8::Function::New(
                context,
                [](const FunctionCallbackInfo<Value>& info) {
                  Isolate* isolate = info.GetIsolate();
                  BaseDataWrapper* wrapper = tns::GetValue(isolate, info[0]);
                  ExternalMemoryCharge* charge =
                      wrapper != nullptr ? wrapper->ExternalCharge() : nullptr;
                  double bytes = charge != nullptr && charge->Isolate() == isolate
                                     ? static_cast<double>(charge->Bytes())
                                     : 0;
                  info.GetReturnValue().Set(bytes);
                },
                Local<Value>(), 1)
                .ToLocal(&getFunc);
  tns::Assert(success, isolate);
  success =
      interop->Set(context, tns::ToV8String(isolate, "getExternalSize"), getFunc).FromMaybe(false);
  tns::Assert(success, isolate);
}

// Returns the wrapped NSException value carried by `value` — either `value`
// itself when it wraps an NSException, or its `.nativeException` when `value` is
// an Error carrying a wrapped NSException. Empty handle otherwise.
static Local<Value> GetWrappedNSException(Local<Context> context, Local<Value> value) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  auto isWrappedNSException = [&](Local<Value> v) -> bool {
    if (v.IsEmpty() || !v->IsObject()) {
      return false;
    }
    BaseDataWrapper* wrapper = tns::GetValue(isolate, v);
    if (wrapper == nullptr || wrapper->Type() != WrapperType::ObjCObject) {
      return false;
    }
    id data = static_cast<ObjCDataWrapper*>(wrapper)->Data();
    return [data isKindOfClass:[NSException class]];
  };

  if (isWrappedNSException(value)) {
    return value;
  }
  if (value->IsObject()) {
    Local<Value> nativeExc;
    if (value.As<Object>()
            ->Get(context, tns::ToV8String(isolate, "nativeException"))
            .ToLocal(&nativeExc) &&
        isWrappedNSException(nativeExc)) {
      return nativeExc;
    }
  }
  return Local<Value>();
}

void Interop::RegisterEscapeExceptionFunction(Local<Context> context, Local<Object> interop) {
  Local<v8::Function> func;
  bool success =
      v8::Function::New(context, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        Local<Context> context = isolate->GetCurrentContext();

        if (info.Length() < 1) {
          isolate->ThrowException(Exception::TypeError(tns::ToV8String(
              isolate, "interop.escapeException requires 1 argument, but only 0 present.")));
          return;
        }

        Local<Value> x = info[0];
        Local<Private> brand = ArgConverter::GetEscapeExceptionBrand(isolate);

        // Idempotent: an already-branded value is returned unchanged.
        if (!brand.IsEmpty() && x->IsObject()) {
          Maybe<bool> hasBrand = x.As<Object>()->HasPrivate(context, brand);
          if (hasBrand.IsJust() && hasBrand.FromJust()) {
            info.GetReturnValue().Set(x);
            return;
          }
        }

        // Derive the message string, preferring x.message when x is an Error.
        std::string message;
        bool xIsObject = x->IsObject();
        if (xIsObject) {
          Local<Value> msgVal;
          if (x.As<Object>()->Get(context, tns::ToV8String(isolate, "message")).ToLocal(&msgVal) &&
              !msgVal->IsNullOrUndefined()) {
            message = tns::ToString(isolate, msgVal);
          } else {
            message = tns::ToString(isolate, x);
          }
        } else {
          message = tns::ToString(isolate, x);
        }

        // The returned value is a real JS Error so `throw interop.escapeException(x)`
        // behaves like a normal throw in pure-JS paths.
        Local<Value> errVal = Exception::Error(tns::ToV8String(isolate, message));
        Local<Object> errObj = errVal.As<Object>();

        // Copy stack from x when it is an Error carrying one.
        std::string stack;
        if (xIsObject) {
          Local<Value> stackVal;
          if (x.As<Object>()->Get(context, tns::ToV8String(isolate, "stack")).ToLocal(&stackVal) &&
              stackVal->IsString()) {
            stack = tns::ToString(isolate, stackVal);
            errObj->Set(context, tns::ToV8String(isolate, "stack"), stackVal).FromMaybe(false);
          }
        }

        // Capture the escape-site JS stack: where interop.escapeException was
        // called, distinct from the origin stack of the error being wrapped.
        std::string escapeStack = NativeScriptException::GetErrorStackTrace(
            isolate, v8::StackTrace::CurrentStackTrace(isolate, 100, v8::StackTrace::kOverview));

        // Build the branded payload: the original NSException when x carries one,
        // otherwise synthesis info (name/message/stack). The escape-site stack
        // always travels along, in both shapes.
        Local<Object> payload = Object::New(isolate);
        payload
            ->Set(context, tns::ToV8String(isolate, "escapeStack"),
                  tns::ToV8String(isolate, escapeStack))
            .FromMaybe(false);
        Local<Value> nativeExc = GetWrappedNSException(context, x);
        if (!nativeExc.IsEmpty()) {
          payload->Set(context, tns::ToV8String(isolate, "nativeException"), nativeExc)
              .FromMaybe(false);
          // Also carry the JS origin/propagation stack of the error that wrapped
          // the native exception, when present.
          if (!stack.empty()) {
            payload
                ->Set(context, tns::ToV8String(isolate, "stack"), tns::ToV8String(isolate, stack))
                .FromMaybe(false);
          }
        } else {
          std::string name = "Error";
          if (xIsObject) {
            Local<Value> nameVal;
            if (x.As<Object>()->Get(context, tns::ToV8String(isolate, "name")).ToLocal(&nameVal) &&
                nameVal->IsString()) {
              name = tns::ToString(isolate, nameVal);
            }
          }
          payload->Set(context, tns::ToV8String(isolate, "name"), tns::ToV8String(isolate, name))
              .FromMaybe(false);
          payload
              ->Set(context, tns::ToV8String(isolate, "message"), tns::ToV8String(isolate, message))
              .FromMaybe(false);
          // When x is a non-Error (no .stack, e.g. a plain string) fall back to
          // the escape-site stack so a stack always travels with the escape.
          const std::string& synthStack = stack.empty() ? escapeStack : stack;
          payload
              ->Set(context, tns::ToV8String(isolate, "stack"),
                    tns::ToV8String(isolate, synthStack))
              .FromMaybe(false);
        }

        if (!brand.IsEmpty()) {
          errObj->SetPrivate(context, brand, payload).FromMaybe(false);
        }

        info.GetReturnValue().Set(errObj);
      }).ToLocal(&func);

  Isolate* isolate = v8::Isolate::GetCurrent();
  tns::Assert(success, isolate);

  success =
      interop->Set(context, tns::ToV8String(isolate, "escapeException"), func).FromMaybe(false);
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

  Isolate* isolate = v8::Isolate::GetCurrent();
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

  Isolate* isolate = v8::Isolate::GetCurrent();
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
                               PrimitiveDataWrapper* pw =
                                   static_cast<PrimitiveDataWrapper*>(wrapper);
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
                               const StructInfo& structInfo = sw->StructInfo();
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

  Isolate* isolate = v8::Isolate::GetCurrent();
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
  Isolate* isolate = v8::Isolate::GetCurrent();
  if (!value->IsNullOrUndefined()) {
    if (value->IsArrayBuffer() || value->IsArrayBufferView() || value->IsSharedArrayBuffer()) {
      bool isArrayBuffer = false;
      void* data = tns::TryGetBufferFromArrayBuffer(value, isArrayBuffer);
      return Pointer::NewInstance(context, data);
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
            void* handle =
                SymbolLoader::instance().loadFunctionSymbol(meta->topLevelModule(), meta->name());
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
            if (blockWrapper->OwnsBlock()) {
              return Pointer::NewInstance(context, blockWrapper->Block());
            }
            // A JS function does not keep its block alive: only native
            // references do. A live block is kept for the rest of the turn,
            // like one passed to a native call; a dying one is no handle.
            JSBlock* block = static_cast<JSBlock*>(blockWrapper->Block());
            if (TryRetainJSBlock(block)) {
              CFAutorelease(block);
              return Pointer::NewInstance(context, block);
            }
            break;
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

}  // namespace tns
