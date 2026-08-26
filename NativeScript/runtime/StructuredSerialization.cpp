#include "StructuredSerialization.h"

#include "BuiltinLoader.h"
#include "Caches.h"
#include "Helpers.h"
#include "NativeScriptException.h"

using namespace v8;

namespace tns {
namespace serialization {

namespace {

// The private symbol markCloneable stamps on every DOMException instance.
// Private, so app code can neither forge the brand onto an impostor nor strip
// it; per isolate because a worker's instances are branded and checked on its
// own isolate, and only bytes cross between them. `anyInstances` flips when
// the first instance is branded and gates HasCustomHostObject: claiming host
// objects makes V8 consult IsHostObject for every plain JS object in a
// serialized graph (~25ns each, ~+12% on an object-heavy clone), and an
// isolate that never constructed a DOMException cannot be holding one, so it
// keeps serializing on the exact pre-claim path. Every instance passes
// through markCloneable — deserialization rebuilds via the constructor — so
// the flag cannot miss one.
struct DomExceptionBrandState {
  Persistent<Private> brand;
  bool anyInstances = false;
};

// Empty once teardown has begun — callers bail to their fallback.
Local<Private> DomExceptionBrand(Isolate* isolate) {
  auto* state = Caches::StateFor<DomExceptionBrandState>(isolate);
  if (state == nullptr) {
    return Local<Private>();
  }
  if (state->brand.IsEmpty()) {
    state->brand.Reset(
        isolate, Private::New(isolate, tns::ToV8String(
                                           isolate, "domExceptionCloneable")));
  }
  return state->brand.Get(isolate);
}

bool AnyDomExceptionInstances(Isolate* isolate) {
  auto* state = Caches::StateFor<DomExceptionBrandState>(isolate);
  return state != nullptr && state->anyInstances;
}

void MarkCloneableCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  if (info.Length() < 1 || !info[0]->IsObject()) {
    return;
  }
  Local<Private> brand = DomExceptionBrand(isolate);
  if (brand.IsEmpty()) {
    return;
  }
  if (info[0]
          .As<Object>()
          ->SetPrivate(isolate->GetCurrentContext(), brand, v8::True(isolate))
          .FromMaybe(false)) {
    Caches::StateFor<DomExceptionBrandState>(isolate)->anyInstances = true;
  }
}

}  // namespace

MaybeLocal<Object> DomExceptionBinding(Local<Context> context) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<Object> binding = Object::New(isolate);
  Local<v8::Function> markCloneable;
  if (!v8::Function::New(context, MarkCloneableCallback)
           .ToLocal(&markCloneable) ||
      !binding
           ->Set(context, tns::ToV8String(isolate, "markCloneable"),
                 markCloneable)
           .FromMaybe(false)) {
    return MaybeLocal<Object>();
  }
  return binding;
}

MaybeLocal<Object> GetDomExceptionExports(Local<Context> context) {
  return BuiltinLoader::GetExports(context, BuiltinId::kDomException,
                                   DomExceptionBinding);
}

void ThrowDataCloneError(Isolate* isolate, const std::string& message) {
  // The spec's DataCloneError is a DOMException; build it through the
  // builtin's exports cache so native and JS throw sites produce the same
  // class. Delegates may call into JS here — V8 allows it, and Node's
  // serializer delegates do the same. The fallback covers a builtin that can
  // no longer run (isolate teardown, broken realm).
  Local<Object> domException;
  {
    TryCatch tc(isolate);
    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> exports;
    Local<Value> ctor;
    if (GetDomExceptionExports(context).ToLocal(&exports) &&
        exports->Get(context, tns::ToV8String(isolate, "DOMException"))
            .ToLocal(&ctor) &&
        ctor->IsFunction()) {
      Local<Value> args[] = {tns::ToV8String(isolate, message),
                             tns::ToV8String(isolate, "DataCloneError")};
      Local<Object> instance;
      if (ctor.As<v8::Function>()
              ->NewInstance(context, 2, args)
              .ToLocal(&instance)) {
        domException = instance;
      }
    }
  }
  if (!domException.IsEmpty()) {
    isolate->ThrowException(domException);
    return;
  }
  NativeScriptException exception(isolate, message, "DataCloneError");
  exception.ReThrowToV8(isolate);
}

namespace {

// Every host object's payload starts with one of these, so the reader can
// dispatch. kHostObjectDegraded carries nothing further; the other two carry a
// uint32 index into one of the SerializedValue's out-of-band lists. The bytes
// never outlive the process (structuredClone round-trips in one isolate,
// worker messages cross isolates in the same binary), so the format can evolve
// freely with this file.
constexpr uint32_t kHostObjectDegraded = 0;
constexpr uint32_t kHostObjectDomException = 1;
constexpr uint32_t kHostObjectMessagePort = 2;

using PortList = std::vector<std::shared_ptr<messaging::NativeMessagePort>>;

class SerializerDelegate : public ValueSerializer::Delegate {
 public:
  SerializerDelegate(
      Isolate* isolate, HostObjectPolicy hostObjectPolicy,
      std::vector<std::shared_ptr<BackingStore>>* sharedBuffers,
      std::vector<SerializedValue::DomExceptionPayload>* domExceptions,
      const PortList* transferPorts)
      : isolate_(isolate),
        hostObjectPolicy_(hostObjectPolicy),
        sharedBuffers_(sharedBuffers),
        domExceptions_(domExceptions),
        transferPorts_(transferPorts),
        uncloneableBrand_(messaging::UncloneableBrandIfAny(isolate)) {}

  void SetSerializer(ValueSerializer* serializer) { serializer_ = serializer; }

  void ThrowDataCloneError(Local<v8::String> message) override {
    serialization::ThrowDataCloneError(isolate_,
                                       tns::ToString(isolate_, message));
  }

  // With this returning true, V8 asks IsHostObject about every plain JS
  // object in the graph — the cost of claiming a plain-JS class as a host
  // object is one private-symbol lookup per object (Node pays the same for
  // its JSTransferable protocol). Claimed only once this isolate has actually
  // constructed a DOMException, created a port or stamped a transfer brand;
  // until then serialization runs the pre-claim path untouched. V8 samples
  // this once per ValueSerializer. Accepted edge: a getter invoked during this
  // very clone could construct the isolate's FIRST DOMException and return it
  // into the graph after a false sample — that one instance degrades to a
  // plain object (the pre-feature behavior) instead of cloning; every later
  // serialization sees the flag.
  bool HasCustomHostObject(Isolate* isolate) override {
    return AnyDomExceptionInstances(isolate) ||
           messaging::AnyPortsOrBrands(isolate);
  }

  Maybe<bool> IsHostObject(Isolate* isolate, Local<Object> object) override {
    // Claiming custom host objects REPLACES V8's own embedder-field detection
    // rather than adding to it, so anything with a native half has to be
    // claimed here too — otherwise an ObjC wrapper would be written out as a
    // plain object, silently losing the half that mattered.
    if (object->InternalFieldCount() > 0) {
      return Just(true);
    }
    if (!uncloneableBrand_.IsEmpty()) {
      bool uncloneable = false;
      if (!object->HasPrivate(isolate->GetCurrentContext(), uncloneableBrand_)
               .To(&uncloneable)) {
        return Nothing<bool>();
      }
      if (uncloneable) {
        return Just(true);
      }
    }
    Local<Private> brand = DomExceptionBrand(isolate);
    if (brand.IsEmpty()) {
      return Just(false);
    }
    return object->HasPrivate(isolate->GetCurrentContext(), brand);
  }

  Maybe<bool> WriteHostObject(Isolate* isolate, Local<Object> object) override {
    // Ports are claimed ahead of every policy: transferring one is explicit
    // intent, so a port in the graph is either in the transfer list or an
    // error — degrading it under kDegrade would strand its sibling forever.
    if (messaging::IsPortWrapper(isolate, object)) {
      return WritePort(isolate, object);
    }
    bool uncloneable = false;
    if (!messaging::IsMarkedUncloneable(isolate, object).To(&uncloneable)) {
      return Nothing<bool>();
    }
    if (uncloneable) {
      serialization::ThrowDataCloneError(
          isolate, "Cannot clone object of unsupported type.");
      return Nothing<bool>();
    }
    // DOMException serializes under both policies: it is [Serializable] in
    // the IDL, and it is a plain JS object with no native half to lose.
    Local<Private> brand = DomExceptionBrand(isolate);
    bool isDomException = false;
    if (!brand.IsEmpty() &&
        !object->HasPrivate(isolate->GetCurrentContext(), brand)
             .To(&isDomException)) {
      return Nothing<bool>();
    }
    if (isDomException) {
      return WriteDomException(isolate, object);
    }
    if (hostObjectPolicy_ == HostObjectPolicy::kDegrade) {
      // Tag only, no payload: the value surfaces as an empty object.
      serializer_->WriteUint32(kHostObjectDegraded);
      return Just(true);
    }
    std::string name = tns::ToString(isolate, object->GetConstructorName());
    serialization::ThrowDataCloneError(isolate,
                                       "#<" + name + "> could not be cloned.");
    return Nothing<bool>();
  }

  // Shared memory is shared, not copied: the receiving isolate builds a new
  // SharedArrayBuffer over this same backing store.
  Maybe<uint32_t> GetSharedArrayBufferId(
      Isolate* isolate, Local<SharedArrayBuffer> sharedArrayBuffer) override {
    std::shared_ptr<BackingStore> backingStore =
        sharedArrayBuffer->GetBackingStore();
    for (size_t i = 0; i < sharedBuffers_->size(); i++) {
      if ((*sharedBuffers_)[i] == backingStore) {
        return Just(static_cast<uint32_t>(i));
      }
    }
    uint32_t id = static_cast<uint32_t>(sharedBuffers_->size());
    sharedBuffers_->push_back(std::move(backingStore));
    return Just(id);
  }

  // Overridden only to keep the DataCloneError name: with a delegate installed
  // V8's default throws a plain Error straight onto the isolate.
  bool AdoptSharedValueConveyor(Isolate* isolate,
                                SharedValueConveyor&& conveyor) override {
    serialization::ThrowDataCloneError(isolate,
                                       "shared value could not be cloned.");
    return false;
  }

 private:
  // A port is written as its position in the transfer list; the port itself
  // travels out of band. Nothing is detached here — the whole graph has to
  // write successfully before anything changes hands.
  Maybe<bool> WritePort(Isolate* isolate, Local<Object> object) {
    messaging::NativeMessagePort* port =
        messaging::PortFromWrapper(isolate, object);
    if (port == nullptr || port->IsDetached()) {
      serialization::ThrowDataCloneError(
          isolate, "Cannot clone object of unsupported type.");
      return Nothing<bool>();
    }
    for (size_t i = 0; i < transferPorts_->size(); i++) {
      if ((*transferPorts_)[i].get() == port) {
        serializer_->WriteUint32(kHostObjectMessagePort);
        serializer_->WriteUint32(static_cast<uint32_t>(i));
        return Just(true);
      }
    }
    serialization::ThrowDataCloneError(
        isolate,
        "Object that needs transfer was found in message but not listed in "
        "transferList");
    return Nothing<bool>();
  }

  // Web IDL's DOMException serialization steps (name and message), plus the
  // stack, matching Node. The payload travels out-of-band and only an index
  // enters the stream: the receiving side must construct instances before
  // ReadValue runs, because V8 forbids JS execution during deserialization.
  Maybe<bool> WriteDomException(Isolate* isolate, Local<Object> object) {
    Local<Context> context = isolate->GetCurrentContext();
    Local<Value> name, message, stack;
    if (!object->Get(context, tns::ToV8String(isolate, "name"))
             .ToLocal(&name) ||
        !object->Get(context, tns::ToV8String(isolate, "message"))
             .ToLocal(&message) ||
        !object->Get(context, tns::ToV8String(isolate, "stack"))
             .ToLocal(&stack)) {
      return Nothing<bool>();
    }
    SerializedValue::DomExceptionPayload payload;
    payload.name = tns::ToString(isolate, name);
    payload.message = tns::ToString(isolate, message);
    // The stack can legitimately be absent or tampered into a non-string;
    // carry it only when it is the string captureStackTrace left.
    payload.hasStack = stack->IsString();
    if (payload.hasStack) {
      payload.stack = tns::ToString(isolate, stack);
    }
    serializer_->WriteUint32(kHostObjectDomException);
    serializer_->WriteUint32(static_cast<uint32_t>(domExceptions_->size()));
    domExceptions_->push_back(std::move(payload));
    return Just(true);
  }

  Isolate* isolate_;
  HostObjectPolicy hostObjectPolicy_;
  std::vector<std::shared_ptr<BackingStore>>* sharedBuffers_;
  std::vector<SerializedValue::DomExceptionPayload>* domExceptions_;
  const PortList* transferPorts_;
  Local<Private> uncloneableBrand_;
  ValueSerializer* serializer_ = nullptr;
};

class DeserializerDelegate : public ValueDeserializer::Delegate {
 public:
  DeserializerDelegate(
      const std::vector<Local<SharedArrayBuffer>>* sharedBuffers,
      const std::vector<Local<Object>>* domExceptions,
      const std::vector<Local<Object>>* ports)
      : sharedBuffers_(sharedBuffers),
        domExceptions_(domExceptions),
        ports_(ports) {}

  void SetDeserializer(ValueDeserializer* deserializer) {
    deserializer_ = deserializer;
  }

  // No JS may run in here (V8 forbids it during a read); DOMException
  // instances and port wrappers were built by Deserialize before ReadValue
  // started, and this only hands them out.
  MaybeLocal<Object> ReadHostObject(Isolate* isolate) override {
    uint32_t tag;
    if (!deserializer_->ReadUint32(&tag)) {
      return MaybeLocal<Object>();
    }
    switch (tag) {
      case kHostObjectDegraded:
        // Counterpart of the kDegrade branch: tag only, so the value arrives
        // as an empty object. Unreachable for a value written under kReject.
        return Object::New(isolate);
      case kHostObjectDomException: {
        uint32_t index;
        if (!deserializer_->ReadUint32(&index) ||
            index >= domExceptions_->size()) {
          return MaybeLocal<Object>();
        }
        return (*domExceptions_)[index];
      }
      case kHostObjectMessagePort: {
        uint32_t index;
        if (!deserializer_->ReadUint32(&index) || index >= ports_->size()) {
          return MaybeLocal<Object>();
        }
        return (*ports_)[index];
      }
      default:
        return MaybeLocal<Object>();
    }
  }

  MaybeLocal<SharedArrayBuffer> GetSharedArrayBufferFromId(
      Isolate* isolate, uint32_t cloneId) override {
    if (cloneId >= sharedBuffers_->size()) {
      return MaybeLocal<SharedArrayBuffer>();
    }
    return (*sharedBuffers_)[cloneId];
  }

 private:
  const std::vector<Local<SharedArrayBuffer>>* sharedBuffers_;
  const std::vector<Local<Object>>* domExceptions_;
  const std::vector<Local<Object>>* ports_;
  ValueDeserializer* deserializer_ = nullptr;
};

// Validates the transfer list and splits it, each half in registration order,
// because the two are handed over by different mechanisms: buffers by id in
// the stream, ports by index into an out-of-band list. The detached and
// detachable checks are load-bearing rather than defensive:
// ArrayBuffer::Detach() aborts the process on a non-detachable buffer instead
// of reporting failure.
bool CollectTransferList(Isolate* isolate, Local<Context> context,
                         Local<Value> transferList, Local<Object> sourcePort,
                         std::vector<Local<ArrayBuffer>>& transfers,
                         PortList& ports) {
  if (transferList.IsEmpty() || transferList->IsUndefined() ||
      transferList->IsNull()) {
    return true;
  }

  if (!transferList->IsArray()) {
    isolate->ThrowException(Exception::TypeError(
        tns::ToV8String(isolate, "The transfer list must be an array")));
    return false;
  }

  Local<v8::Array> list = transferList.As<v8::Array>();
  uint32_t length = list->Length();
  for (uint32_t i = 0; i < length; i++) {
    Local<Value> item;
    if (!list->Get(context, i).ToLocal(&item)) {
      return false;
    }
    if (!item->IsObject()) {
      ThrowDataCloneError(isolate, "Found invalid value in transferList.");
      return false;
    }
    Local<Object> entry = item.As<Object>();

    bool untransferable = false;
    if (!messaging::IsMarkedUntransferable(isolate, entry)
             .To(&untransferable)) {
      return false;
    }
    if (untransferable) {
      ThrowDataCloneError(isolate,
                          "Cannot transfer object of unsupported type.");
      return false;
    }

    if (entry->IsArrayBuffer()) {
      Local<ArrayBuffer> buffer = entry.As<ArrayBuffer>();
      for (const Local<ArrayBuffer>& existing : transfers) {
        if (existing == buffer) {
          ThrowDataCloneError(
              isolate, "The transfer list contains the same ArrayBuffer twice");
          return false;
        }
      }
      if (buffer->WasDetached() || !buffer->IsDetachable()) {
        ThrowDataCloneError(isolate,
                            "An ArrayBuffer in the transfer list is detached "
                            "and cannot be transferred");
        return false;
      }
      transfers.push_back(buffer);
      continue;
    }

    if (messaging::IsPortWrapper(isolate, entry)) {
      // Ports transfer under every policy: the receiving-side plumbing lives
      // in Deserialize itself, so kDegrade callers (Worker.postMessage) carry
      // ports just as structuredClone does.
      // A port cannot travel on itself: the message would arrive on a channel
      // its own delivery destroyed.
      if (!sourcePort.IsEmpty() && entry == sourcePort) {
        ThrowDataCloneError(isolate, "Transfer list contains source port");
        return false;
      }
      messaging::NativeMessagePort* port =
          messaging::PortFromWrapper(isolate, entry);
      if (port == nullptr || port->IsDetached()) {
        ThrowDataCloneError(isolate,
                            "MessagePort in transfer list is already detached");
        return false;
      }
      for (const std::shared_ptr<messaging::NativeMessagePort>& existing :
           ports) {
        if (existing.get() == port) {
          ThrowDataCloneError(
              isolate, "Transfer list contains duplicate " +
                           tns::ToString(isolate, entry->GetConstructorName()));
          return false;
        }
      }
      // Held strongly for the duration of the write: writing the graph runs
      // user getters, and one of them closing a listed port would otherwise
      // leave the delegate with a dangling pointer.
      ports.push_back(port->shared_from_this());
      continue;
    }

    ThrowDataCloneError(isolate, "Found invalid value in transferList.");
    return false;
  }
  return true;
}

}  // namespace

Maybe<bool> SerializedValue::Serialize(Isolate* isolate, Local<Context> context,
                                       Local<Value> input,
                                       Local<Value> transferList,
                                       HostObjectPolicy hostObjectPolicy,
                                       Local<Object> sourcePort) {
  HandleScope handleScope(isolate);
  Context::Scope contextScope(context);
  tns::Assert(buffer_ == nullptr, isolate);

  std::vector<Local<ArrayBuffer>> transfers;
  PortList ports;
  if (!CollectTransferList(isolate, context, transferList, sourcePort,
                           transfers, ports)) {
    return Nothing<bool>();
  }

  SerializerDelegate delegate(isolate, hostObjectPolicy, &sharedBuffers_,
                              &domExceptions_, &ports);
  ValueSerializer serializer(isolate, &delegate);
  delegate.SetSerializer(&serializer);
  for (size_t i = 0; i < transfers.size(); i++) {
    serializer.TransferArrayBuffer(static_cast<uint32_t>(i), transfers[i]);
  }

  serializer.WriteHeader();
  bool written = serializer.WriteValue(context, input).FromMaybe(false);

  // Release() hands ownership over whether or not the write succeeded, so the
  // buffer is claimed either way rather than leaking with the serializer.
  std::pair<uint8_t*, size_t> data = serializer.Release();
  std::unique_ptr<uint8_t, FreeDeleter> owned(data.first);
  if (!written) {
    return Nothing<bool>();
  }

  // Revalidated after the write, not before it: writing the graph runs user
  // getters, and one of them may have closed a listed port. Checked while
  // nothing has changed hands yet, so a message that cannot be completed
  // leaves every buffer and every port exactly as it found them.
  for (const std::shared_ptr<messaging::NativeMessagePort>& port : ports) {
    if (port->IsDetached()) {
      ThrowDataCloneError(isolate,
                          "MessagePort in transfer list is already detached");
      return Nothing<bool>();
    }
  }

  // Only once the value is safely written does the memory change hands: claim
  // each backing store before detaching, since detaching drops the buffer's own
  // reference to it.
  for (Local<ArrayBuffer> buffer : transfers) {
    std::shared_ptr<BackingStore> backingStore = buffer->GetBackingStore();
    // Detach rejects a null key only for a buffer carrying an
    // [[ArrayBufferDetachKey]]: script cannot set one, this runtime never calls
    // SetDetachKey, and the WebAssembly memory buffers that have one are
    // already turned away as non-detachable above. Unreachable, then — but
    // claiming success without moving the memory would hand the receiver an
    // empty buffer, so the failure propagates carrying V8's TypeError, which
    // names the key mismatch.
    if (buffer->Detach(Local<Value>()).IsNothing()) {
      return Nothing<bool>();
    }
    transferredBuffers_.push_back(std::move(backingStore));
  }

  // Each port's handle side closes here and its data joins the message,
  // keeping its group and its queue: senders on the far end go on queueing
  // into it while it is in flight, and the receiving port adopts the backlog.
  for (const std::shared_ptr<messaging::NativeMessagePort>& port : ports) {
    transferredPorts_.push_back(port->TransferForMessaging());
  }

  buffer_ = std::move(owned);
  bufferSize_ = data.second;
  return Just(true);
}

bool SerializedValue::TransfersPort(const messaging::PortData* data) const {
  for (const std::unique_ptr<messaging::PortData>& port : transferredPorts_) {
    if (port.get() == data) {
      return true;
    }
  }
  return false;
}

MaybeLocal<Value> SerializedValue::Deserialize(Isolate* isolate,
                                               Local<Context> context,
                                               Local<Value>* portList) {
  Context::Scope contextScope(context);
  // No handle scope of its own: `portList` hands a second handle back to the
  // caller, and only one can escape an EscapableHandleScope. Every caller
  // opens a scope per message already.

  // A BroadcastChannel hands one message to every listener, which is only
  // sound because a fan-out message carries nothing that can be handed over.
  // Such a message may be read here from several isolates at once, so the
  // consumed flag is written only on the single-receiver path.
  tns::Assert(!consumed_, isolate);
  if (HasTransferables()) {
    consumed_ = true;
  }

  std::vector<Local<SharedArrayBuffer>> sharedBuffers;
  for (const std::shared_ptr<BackingStore>& backingStore : sharedBuffers_) {
    sharedBuffers.push_back(SharedArrayBuffer::New(isolate, backingStore));
  }

  // Construct every DOMException the payload names before the read begins:
  // JS is allowed here and forbidden inside ReadHostObject. Construction goes
  // through the real constructor — on a worker isolate that never touched
  // DOMException this runs the builtin on demand — so each instance is
  // branded again and re-serializes on the next hop.
  std::vector<Local<Object>> domExceptions;
  if (!domExceptions_.empty()) {
    Local<Object> exports;
    Local<Value> ctor;
    if (!GetDomExceptionExports(context).ToLocal(&exports) ||
        !exports->Get(context, tns::ToV8String(isolate, "DOMException"))
             .ToLocal(&ctor) ||
        !ctor->IsFunction()) {
      return MaybeLocal<Value>();
    }
    Local<v8::String> stackKey = tns::ToV8String(isolate, "stack");
    for (const DomExceptionPayload& payload : domExceptions_) {
      Local<Value> args[] = {tns::ToV8String(isolate, payload.message),
                             tns::ToV8String(isolate, payload.name)};
      Local<Object> exception;
      if (!ctor.As<v8::Function>()
               ->NewInstance(context, 2, args)
               .ToLocal(&exception)) {
        return MaybeLocal<Value>();
      }
      // The sender's stack replaces the one captured just now for the
      // receiving side's constructor frame, matching Node.
      if (payload.hasStack &&
          !exception
               ->Set(context, stackKey, tns::ToV8String(isolate, payload.stack))
               .FromMaybe(false)) {
        return MaybeLocal<Value>();
      }
      domExceptions.push_back(exception);
    }
  }

  // Ports are adopted before the read starts, for the same reason the
  // exceptions above are: adopting one runs the JS tier's per-wrapper setup,
  // and ReadHostObject may not run JS. The array doubles as what a message
  // event hands out as its `ports`.
  std::vector<Local<Object>> ports;
  if (!transferredPorts_.empty()) {
    Local<v8::Array> list =
        v8::Array::New(isolate, static_cast<int>(transferredPorts_.size()));
    for (size_t i = 0; i < transferredPorts_.size(); i++) {
      Local<Object> wrapper;
      if (!messaging::AdoptPort(context, std::move(transferredPorts_[i]))
               .ToLocal(&wrapper) ||
          !list->Set(context, static_cast<uint32_t>(i), wrapper)
               .FromMaybe(false)) {
        return MaybeLocal<Value>();
      }
      ports.push_back(wrapper);
    }
    if (portList != nullptr) {
      *portList = list;
    }
  }

  DeserializerDelegate delegate(&sharedBuffers, &domExceptions, &ports);
  ValueDeserializer deserializer(isolate, buffer_.get(), bufferSize_,
                                 &delegate);
  delegate.SetDeserializer(&deserializer);

  for (size_t i = 0; i < transferredBuffers_.size(); i++) {
    deserializer.TransferArrayBuffer(
        static_cast<uint32_t>(i),
        ArrayBuffer::New(isolate, std::move(transferredBuffers_[i])));
  }

  if (deserializer.ReadHeader(context).IsNothing()) {
    return MaybeLocal<Value>();
  }
  Local<Value> result;
  if (!deserializer.ReadValue(context).ToLocal(&result)) {
    return MaybeLocal<Value>();
  }
  return result;
}

}  // namespace serialization
}  // namespace tns
