#include "StructuredClone.h"

#include <cstdlib>
#include <memory>
#include <string>
#include <vector>

#include "BuiltinLoader.h"
#include "Helpers.h"

using namespace v8;

namespace tns {

namespace {

// There is no DOMException in this runtime, so a clone failure surfaces as an
// Error carrying the spec's exception name — the same shape the
// native-exception bridge uses (docs/error-handling.md). Failing to attach the
// name is ignored: throwing something is more useful than throwing nothing.
void ThrowDataCloneError(Isolate* isolate, Local<v8::String> message) {
  Local<Value> error = Exception::Error(message);
  Local<Context> context = isolate->GetCurrentContext();
  bool named = error.As<Object>()
                   ->Set(context, tns::ToV8String(isolate, "name"),
                         tns::ToV8String(isolate, "DataCloneError"))
                   .FromMaybe(false);
  (void)named;
  isolate->ThrowException(error);
}

void ThrowDataCloneError(Isolate* isolate, const std::string& message) {
  ThrowDataCloneError(isolate, tns::ToV8String(isolate, message));
}

class CloneDelegate : public ValueSerializer::Delegate {
 public:
  explicit CloneDelegate(Isolate* isolate) : isolate_(isolate) {}

  void ThrowDataCloneError(Local<v8::String> message) override {
    tns::ThrowDataCloneError(isolate_, message);
  }

  // Objects backed by native state — ObjC wrappers, interop pointers, function
  // references — reach the serializer as host objects. They have no
  // serialization form, and cloning the JS shell without its native counterpart
  // would hand back a wrapper pointing at nothing.
  Maybe<bool> WriteHostObject(Isolate* isolate, Local<Object> object) override {
    std::string name = tns::ToString(isolate, object->GetConstructorName());
    ThrowDataCloneError(
        tns::ToV8String(isolate, "#<" + name + "> could not be cloned."));
    return Nothing<bool>();
  }

  // Shared memory has no owner to hand it to in a single-agent clone. Both
  // hooks below are overridden only to keep the DataCloneError name: V8's
  // defaults throw a plain Error directly on the isolate instead of going
  // through ThrowDataCloneError.
  Maybe<uint32_t> GetSharedArrayBufferId(
      Isolate* isolate, Local<SharedArrayBuffer> sharedArrayBuffer) override {
    ThrowDataCloneError(
        tns::ToV8String(isolate, "#<SharedArrayBuffer> could not be cloned."));
    return Nothing<uint32_t>();
  }

  bool AdoptSharedValueConveyor(Isolate* isolate,
                                SharedValueConveyor&& conveyor) override {
    ThrowDataCloneError(
        tns::ToV8String(isolate, "shared value could not be cloned."));
    return false;
  }

 private:
  Isolate* isolate_;
};

// Validates the transfer list the builtin materialized and collects it in
// registration order. Returns false with an exception pending.
bool CollectTransferList(Isolate* isolate, Local<Context> context,
                         Local<Value> transferValue,
                         std::vector<Local<ArrayBuffer>>& transfers) {
  if (!transferValue->IsArray()) {
    return true;
  }

  Local<v8::Array> list = transferValue.As<v8::Array>();
  uint32_t length = list->Length();
  for (uint32_t i = 0; i < length; i++) {
    Local<Value> item;
    if (!list->Get(context, i).ToLocal(&item)) {
      return false;
    }
    if (!item->IsArrayBuffer()) {
      ThrowDataCloneError(isolate,
                          "structuredClone: value in transfer list is not "
                          "transferable");
      return false;
    }

    Local<ArrayBuffer> buffer = item.As<ArrayBuffer>();
    for (const Local<ArrayBuffer>& existing : transfers) {
      if (existing == buffer) {
        ThrowDataCloneError(isolate,
                            "structuredClone: transfer list contains the same "
                            "ArrayBuffer twice");
        return false;
      }
    }
    if (buffer->WasDetached() || !buffer->IsDetachable()) {
      ThrowDataCloneError(isolate,
                          "structuredClone: an ArrayBuffer in the transfer "
                          "list is detached and cannot be transferred");
      return false;
    }

    transfers.push_back(buffer);
  }
  return true;
}

// binding.clone(value, transferArrayOrUndefined): serialize and deserialize in
// this one isolate, which is what the spec's StructuredDeserialize(
// StructuredSerializeWithTransfer(...)) amounts to when there is no second
// agent involved.
void CloneCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Context> context = isolate->GetCurrentContext();
  Local<Value> value =
      info.Length() > 0 ? info[0] : v8::Undefined(isolate).As<Value>();

  std::vector<Local<ArrayBuffer>> transfers;
  if (info.Length() > 1 &&
      !CollectTransferList(isolate, context, info[1], transfers)) {
    return;
  }

  CloneDelegate delegate(isolate);
  ValueSerializer serializer(isolate, &delegate);
  for (size_t i = 0; i < transfers.size(); i++) {
    serializer.TransferArrayBuffer(static_cast<uint32_t>(i), transfers[i]);
  }

  serializer.WriteHeader();
  bool written = serializer.WriteValue(context, value).FromMaybe(false);

  // Release() hands over ownership of a buffer the default delegate grew with
  // realloc(), so it is free()d rather than deleted — and it must be released
  // even after a failed write, or the buffer leaks with the serializer.
  std::pair<uint8_t*, size_t> data = serializer.Release();
  std::unique_ptr<uint8_t, void (*)(void*)> owned(data.first, std::free);
  if (!written) {
    return;
  }

  ValueDeserializer deserializer(isolate, data.first, data.second);

  // Transferred memory changes hands here, after serialization succeeded: the
  // backing store is claimed before the source is detached (detaching drops the
  // buffer's own reference to it) and handed to a fresh ArrayBuffer under the
  // same id the serializer wrote.
  for (size_t i = 0; i < transfers.size(); i++) {
    std::shared_ptr<BackingStore> backingStore =
        transfers[i]->GetBackingStore();
    if (transfers[i]->Detach(Local<Value>()).IsNothing()) {
      return;
    }
    deserializer.TransferArrayBuffer(static_cast<uint32_t>(i),
                                     ArrayBuffer::New(isolate, backingStore));
  }

  if (deserializer.ReadHeader(context).IsNothing()) {
    return;
  }

  Local<Value> result;
  if (!deserializer.ReadValue(context).ToLocal(&result)) {
    return;
  }
  info.GetReturnValue().Set(result);
}

}  // namespace

void StructuredClone::Init(Local<Context> context) {
  Isolate* isolate = v8::Isolate::GetCurrent();

  Local<v8::Function> clone;
  bool success = v8::Function::New(context, CloneCallback).ToLocal(&clone);
  tns::Assert(success, isolate);

  Local<Object> binding = Object::New(isolate);
  success = binding->Set(context, tns::ToV8String(isolate, "clone"), clone)
                .FromMaybe(false);
  tns::Assert(success, isolate);

  Local<Value> result;
  success =
      BuiltinLoader::RunBuiltin(context, BuiltinId::kStructuredClone, binding)
          .ToLocal(&result);
  tns::Assert(success, isolate);
}

}  // namespace tns
