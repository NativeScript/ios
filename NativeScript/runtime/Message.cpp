//
//  Message.cpp
//  NativeScript
//
//  Created by Eduardo Speroni on 11/22/23.
//  Copyright © 2023 Progress. All rights reserved.
//

#include "Helpers.h"
#include "Message.hpp"
#include "NativeScriptException.h"

using namespace v8;

namespace tns {
namespace worker {
namespace {
void ThrowDataCloneException(Local<Context> context,
                             Local<v8::String> message) {
  Isolate* isolate = context->GetIsolate();
  //  Local<Value> argv[] = {message,
  //                         FIXED_ONE_BYTE_STRING(isolate, "DataCloneError")};
  Local<Value> exception;
  Local<v8::Function> domexception_ctor;
  NativeScriptException except(isolate, tns::ToString(isolate, message),
                               "DataCloneError");
  except.ReThrowToV8(isolate);
}
class SerializerDelegate : public v8::ValueSerializer::Delegate {
 public:
  SerializerDelegate(Isolate* isolate, Local<Context> context, Message* m)
      : isolate_(isolate), context_(context), msg_(m) {}

  void ThrowDataCloneError(Local<v8::String> message) override {
    ThrowDataCloneException(context_, message);
  }

  Maybe<bool> WriteHostObject(Isolate* isolate, Local<Object> object) override {
    return Just(true);
    //    if (BaseObject::IsBaseObject(object)) {
    //      return WriteHostObject(
    //          BaseObjectPtr<BaseObject> { Unwrap<BaseObject>(object) });
    //    }
    //
    //    // Convert process.env to a regular object.
    //    auto env_proxy_ctor_template = env_->env_proxy_ctor_template();
    //    if (!env_proxy_ctor_template.IsEmpty() &&
    //        env_proxy_ctor_template->HasInstance(object)) {
    //      HandleScope scope(isolate);
    //      // TODO(bnoordhuis) Prototype-less object in case process.env
    //      contains
    //      // a "__proto__" key? process.env has a prototype with concomitant
    //      // methods like toString(). It's probably confusing if that gets
    //      lost
    //      // in transmission.
    //      Local<Object> normal_object = Object::New(isolate);
    //      env_->env_vars()->AssignToObject(isolate, env_->context(),
    //      normal_object); serializer->WriteUint32(kNormalObject);  // Instead
    //      of a BaseObject. return serializer->WriteValue(env_->context(),
    //      normal_object);
    //    }
    //
    //    ThrowDataCloneError(env_->clone_unsupported_type_str());
    //    return Nothing<bool>();
  }

  Maybe<uint32_t> GetSharedArrayBufferId(
      Isolate* isolate, Local<SharedArrayBuffer> shared_array_buffer) override {
    uint32_t i;
    for (i = 0; i < seen_shared_array_buffers_.size(); ++i) {
      if (PersistentToLocal::Strong(seen_shared_array_buffers_[i]) ==
          shared_array_buffer) {
        return Just(i);
      }
    }

    seen_shared_array_buffers_.emplace_back(
        Global<SharedArrayBuffer>{isolate, shared_array_buffer});
    msg_->AddSharedArrayBuffer(shared_array_buffer->GetBackingStore());
    return Just(i);
  }

  //  Maybe<uint32_t> GetWasmModuleTransferId(
  //      Isolate* isolate, Local<WasmModuleObject> module) override {
  //    return Just(msg_->AddWASMModule(module->GetCompiledModule()));
  //  }

  //  bool AdoptSharedValueConveyor(Isolate* isolate,
  //                                SharedValueConveyor&& conveyor) override {
  //    msg_->AdoptSharedValueConveyor(std::move(conveyor));
  //    return true;
  //  }

  //  Maybe<bool> Finish(Local<Context> context) {
  //    for (uint32_t i = 0; i < host_objects_.size(); i++) {
  //      BaseObjectPtr<BaseObject> host_object = std::move(host_objects_[i]);
  //      std::unique_ptr<TransferData> data;
  //      if (i < first_cloned_object_index_)
  //        data = host_object->TransferForMessaging();
  //      if (!data)
  //        data = host_object->CloneForMessaging();
  //      if (!data) return Nothing<bool>();
  //      if (data->FinalizeTransferWrite(context, serializer).IsNothing())
  //        return Nothing<bool>();
  //      msg_->AddTransferable(std::move(data));
  //    }
  //    return Just(true);
  //  }

  //  inline void AddHostObject(BaseObjectPtr<BaseObject> host_object) {
  //    // Make sure we have not started serializing the value itself yet.
  //    CHECK_EQ(first_cloned_object_index_, SIZE_MAX);
  //    host_objects_.emplace_back(std::move(host_object));
  //  }
  //
  //  // Some objects in the transfer list may register sub-objects that can be
  //  // transferred. This could e.g. be a public JS wrapper object, such as a
  //  // FileHandle, that is registering its C++ handle for transfer.
  //  inline Maybe<bool> AddNestedHostObjects() {
  //    for (size_t i = 0; i < host_objects_.size(); i++) {
  //      std::vector<BaseObjectPtr<BaseObject>> nested_transferables;
  //      if
  //      (!host_objects_[i]->NestedTransferables().To(&nested_transferables))
  //        return Nothing<bool>();
  //      for (auto& nested_transferable : nested_transferables) {
  //        if (std::find(host_objects_.begin(),
  //                      host_objects_.end(),
  //                      nested_transferable) == host_objects_.end()) {
  //          AddHostObject(nested_transferable);
  //        }
  //      }
  //    }
  //    return Just(true);
  //  }

  ValueSerializer* serializer = nullptr;

 private:
  //  Maybe<bool> WriteHostObject(BaseObjectPtr<BaseObject> host_object) {
  //    BaseObject::TransferMode mode = host_object->GetTransferMode();
  //    if (mode == BaseObject::TransferMode::kUntransferable) {
  //      ThrowDataCloneError(env_->clone_unsupported_type_str());
  //      return Nothing<bool>();
  //    }
  //
  //    for (uint32_t i = 0; i < host_objects_.size(); i++) {
  //      if (host_objects_[i] == host_object) {
  //        serializer->WriteUint32(i);
  //        return Just(true);
  //      }
  //    }
  //
  //    if (mode == BaseObject::TransferMode::kTransferable) {
  //      THROW_ERR_MISSING_TRANSFERABLE_IN_TRANSFER_LIST(env_);
  //      return Nothing<bool>();
  //    }
  //
  //    CHECK_EQ(mode, BaseObject::TransferMode::kCloneable);
  //    uint32_t index = host_objects_.size();
  //    if (first_cloned_object_index_ == SIZE_MAX)
  //      first_cloned_object_index_ = index;
  //    serializer->WriteUint32(index);
  //    host_objects_.push_back(host_object);
  //    return Just(true);
  //  }

  __unused Isolate* isolate_;
  __unused Local<Context> context_;
  Message* msg_;
  std::vector<Global<SharedArrayBuffer>> seen_shared_array_buffers_;
  //  std::vector<BaseObjectPtr<BaseObject>> host_objects_;
  __unused size_t first_cloned_object_index_ = SIZE_MAX;

  friend class tns::worker::Message;
};

class DeserializerDelegate : public ValueDeserializer::Delegate {
 public:
  DeserializerDelegate(
      Message* m, Isolate* isolate,
      //      const std::vector<BaseObjectPtr<BaseObject>>& host_objects,
      const std::vector<Local<SharedArrayBuffer>>& shared_array_buffers
      //      const std::vector<CompiledWasmModule>& wasm_modules,
      //      const std::optional<SharedValueConveyor>& shared_value_conveyor
      )
      :  //    host_objects_(host_objects),
        shared_array_buffers_(shared_array_buffers)
  //        wasm_modules_(wasm_modules),
  //        shared_value_conveyor_(shared_value_conveyor)
  {}

  MaybeLocal<Object> ReadHostObject(Isolate* isolate) override {
    EscapableHandleScope scope(isolate);
    Local<Object> object = Object::New(isolate);
    return scope.Escape(object).As<Object>();
    //    // Identifying the index in the message's BaseObject array is
    //    sufficient. uint32_t id; if (!deserializer->ReadUint32(&id))
    //      return MaybeLocal<Object>();
    //    if (id != kNormalObject) {
    //      CHECK_LT(id, host_objects_.size());
    //      return host_objects_[id]->object(isolate);
    //    }
    //    EscapableHandleScope scope(isolate);
    //    Local<Context> context = isolate->GetCurrentContext();
    //    Local<Value> object;
    //    if (!deserializer->ReadValue(context).ToLocal(&object))
    //      return MaybeLocal<Object>();
    //    CHECK(object->IsObject());
    //    return scope.Escape(object.As<Object>());
  }

  MaybeLocal<SharedArrayBuffer> GetSharedArrayBufferFromId(
      Isolate* isolate, uint32_t clone_id) override {
    //    CHECK_LT(clone_id, shared_array_buffers_.size());
    return shared_array_buffers_[clone_id];
  }

  //  MaybeLocal<WasmModuleObject> GetWasmModuleFromId(
  //      Isolate* isolate, uint32_t transfer_id) override {
  ////    CHECK_LT(transfer_id, wasm_modules_.size());
  //    return WasmModuleObject::FromCompiledModule(
  //        isolate, wasm_modules_[transfer_id]);
  //  }

  //  const SharedValueConveyor* GetSharedValueConveyor(Isolate* isolate)
  //  override {
  ////    CHECK(shared_value_conveyor_.has_value());
  //    return &shared_value_conveyor_.value();
  //  }

  ValueDeserializer* deserializer = nullptr;

 private:
  //  const std::vector<BaseObjectPtr<BaseObject>>& host_objects_;
  const std::vector<Local<SharedArrayBuffer>>& shared_array_buffers_;
  //  const std::vector<CompiledWasmModule>& wasm_modules_;
  //  const std::optional<SharedValueConveyor>& shared_value_conveyor_;
};
};  // namespace

v8::Maybe<bool> Message::Serialize(v8::Isolate* isolate,
                                   v8::Local<v8::Context> context,
                                   v8::Local<v8::Value> input) {
  HandleScope handle_scope(isolate);
  v8::Context::Scope context_scope(context);

  // Verify that we're not silently overwriting an existing message.
  tns::Assert(main_message_buf_.is_empty());

  SerializerDelegate delegate(isolate, context, this);
  ValueSerializer serializer(isolate, &delegate);
  delegate.serializer = &serializer;

  std::vector<Local<ArrayBuffer>> array_buffers;
  //      for (uint32_t i = 0; i < transfer_list_v.length(); ++i) {
  //        Local<Value> entry = transfer_list_v[i];
  //        if (entry->IsObject()) {
  //          // See
  //          https://github.com/nodejs/node/pull/30339#issuecomment-552225353
  //          // for details.
  //          bool untransferable;
  //          if (!entry.As<Object>()->HasPrivate(
  //                  context,
  //                  env->untransferable_object_private_symbol())
  //                  .To(&untransferable)) {
  //            return Nothing<bool>();
  //          }
  //          if (untransferable) {
  //            ThrowDataCloneException(context,
  //            env->transfer_unsupported_type_str()); return Nothing<bool>();
  //          }
  //        }
  //
  //        // Currently, we support ArrayBuffers and BaseObjects for which
  //        // GetTransferMode() returns kTransferable.
  //        if (entry->IsArrayBuffer()) {
  //          Local<ArrayBuffer> ab = entry.As<ArrayBuffer>();
  //          // If we cannot render the ArrayBuffer unusable in this Isolate,
  //          // copying the buffer will have to do.
  //          // Note that we can currently transfer ArrayBuffers even if they
  //          were
  //          // not allocated by Node’s ArrayBufferAllocator in the first
  //          place,
  //          // because we pass the underlying v8::BackingStore around rather
  //          than
  //          // raw data *and* an Isolate with a non-default ArrayBuffer
  //          allocator
  //          // is always going to outlive any Workers it creates, and so will
  //          its
  //          // allocator along with it.
  //          if (!ab->IsDetachable() || ab->WasDetached()) {
  //            ThrowDataCloneException(context,
  //            env->transfer_unsupported_type_str()); return Nothing<bool>();
  //          }
  //          if (std::find(array_buffers.begin(), array_buffers.end(), ab) !=
  //              array_buffers.end()) {
  //            ThrowDataCloneException(
  //                context,
  //                FIXED_ONE_BYTE_STRING(
  //                    env->isolate(),
  //                    "Transfer list contains duplicate ArrayBuffer"));
  //            return Nothing<bool>();
  //          }
  //          // We simply use the array index in the `array_buffers` list as
  //          the
  //          // ID that we write into the serialized buffer.
  //          uint32_t id = array_buffers.size();
  //          array_buffers.push_back(ab);
  //          serializer.TransferArrayBuffer(id, ab);
  //          continue;
  //        } else if (entry->IsObject() &&
  //                   BaseObject::IsBaseObject(entry.As<Object>())) {
  //          // Check if the source MessagePort is being transferred.
  //          if (!source_port.IsEmpty() && entry == source_port) {
  //            ThrowDataCloneException(
  //                context,
  //                FIXED_ONE_BYTE_STRING(env->isolate(),
  //                                      "Transfer list contains source
  //                                      port"));
  //            return Nothing<bool>();
  //          }
  //          BaseObjectPtr<BaseObject> host_object {
  //              Unwrap<BaseObject>(entry.As<Object>()) };
  //          if (env->message_port_constructor_template()->HasInstance(entry)
  //          &&
  //              (!host_object ||
  //               static_cast<MessagePort*>(host_object.get())->IsDetached()))
  //               {
  //            ThrowDataCloneException(
  //                context,
  //                FIXED_ONE_BYTE_STRING(
  //                    env->isolate(),
  //                    "MessagePort in transfer list is already detached"));
  //            return Nothing<bool>();
  //          }
  //          if (std::find(delegate.host_objects_.begin(),
  //                        delegate.host_objects_.end(),
  //                        host_object) != delegate.host_objects_.end()) {
  //            ThrowDataCloneException(
  //                context,
  //                String::Concat(env->isolate(),
  //                    FIXED_ONE_BYTE_STRING(
  //                      env->isolate(),
  //                      "Transfer list contains duplicate "),
  //                    entry.As<Object>()->GetConstructorName()));
  //            return Nothing<bool>();
  //          }
  //          if (host_object && host_object->GetTransferMode() ==
  //                                 BaseObject::TransferMode::kTransferable) {
  //            delegate.AddHostObject(host_object);
  //            continue;
  //          }
  //        }
  //
  //        THROW_ERR_INVALID_TRANSFER_OBJECT(env);
  //        return Nothing<bool>();
  //      }
  //      if (delegate.AddNestedHostObjects().IsNothing())
  //        return Nothing<bool>();

  serializer.WriteHeader();
  if (serializer.WriteValue(context, input).IsNothing()) {
    return Nothing<bool>();
  }

  for (Local<ArrayBuffer> ab : array_buffers) {
    // If serialization succeeded, we render it inaccessible in this Isolate.
    std::shared_ptr<BackingStore> backing_store = ab->GetBackingStore();
    ab->Detach();

    array_buffers_.emplace_back(std::move(backing_store));
  }

  //      if (delegate.Finish(context).IsNothing())
  //        return Nothing<bool>();

  // The serializer gave us a buffer allocated using `malloc()`.
  std::pair<uint8_t*, size_t> data = serializer.Release();
  tns::Assert(data.first != NULL, isolate);
  main_message_buf_ =
      MallocedBuffer<char>(reinterpret_cast<char*>(data.first), data.second);
  return Just(true);
}

MaybeLocal<Value> Message::Deserialize(Isolate* isolate,
                                       Local<Context> context) {
  Context::Scope context_scope(context);

  //  CHECK(!IsCloseMessage());
  //  if (port_list != nullptr && !transferables_.empty()) {
  //    // Need to create this outside of the EscapableHandleScope, but inside
  //    // the Context::Scope.
  //    *port_list = Array::New(env->isolate());
  //  }

  EscapableHandleScope handle_scope(isolate);

  // Create all necessary objects for transferables, e.g. MessagePort handles.
  //  std::vector<BaseObjectPtr<BaseObject>>
  //  host_objects(transferables_.size()); auto cleanup = OnScopeLeave([&]() {
  //    for (BaseObjectPtr<BaseObject> object : host_objects) {
  //      if (!object) continue;
  //
  //      // If the function did not finish successfully, host_objects will
  //      contain
  //      // a list of objects that will never be passed to JS. Therefore, we
  //      // destroy them here.
  //      object->Detach();
  //    }
  //  });

  //  for (uint32_t i = 0; i < transferables_.size(); ++i) {
  //    HandleScope handle_scope(env->isolate());
  //    TransferData* data = transferables_[i].get();
  //    host_objects[i] = data->Deserialize(
  //        env, context, std::move(transferables_[i]));
  //    if (!host_objects[i]) return {};
  //    if (port_list != nullptr) {
  //      // If we gather a list of all message ports, and this transferred
  //      object
  //      // is a message port, add it to that list. This is a bit of an odd
  //      case
  //      // of special handling for MessagePorts (as opposed to applying to all
  //      // transferables), but it's required for spec compliance.
  //      DCHECK((*port_list)->IsArray());
  //      Local<Array> port_list_array = port_list->As<Array>();
  //      Local<Object> obj = host_objects[i]->object();
  //      if (env->message_port_constructor_template()->HasInstance(obj)) {
  //        if (port_list_array->Set(context,
  //                                 port_list_array->Length(),
  //                                 obj).IsNothing()) {
  //          return {};
  //        }
  //      }
  //    }
  //  }
  //  transferables_.clear();

  std::vector<Local<SharedArrayBuffer>> shared_array_buffers;
  // Attach all transferred SharedArrayBuffers to their new Isolate.
  for (uint32_t i = 0; i < shared_array_buffers_.size(); ++i) {
    Local<SharedArrayBuffer> sab =
        SharedArrayBuffer::New(isolate, shared_array_buffers_[i]);
    shared_array_buffers.push_back(sab);
  }

  DeserializerDelegate delegate(
      this, isolate,
      //                                host_objects,
      shared_array_buffers
      //                                wasm_modules_,
      //                                shared_value_conveyor_
  );
  ValueDeserializer deserializer(
      isolate, reinterpret_cast<const uint8_t*>(main_message_buf_.data),
      main_message_buf_.size, &delegate);
  delegate.deserializer = &deserializer;

  // Attach all transferred ArrayBuffers to their new Isolate.
  for (uint32_t i = 0; i < array_buffers_.size(); ++i) {
    Local<ArrayBuffer> ab =
        ArrayBuffer::New(isolate, std::move(array_buffers_[i]));
    deserializer.TransferArrayBuffer(i, ab);
  }

  if (deserializer.ReadHeader(context).IsNothing()) return {};
  Local<Value> return_value;
  if (!deserializer.ReadValue(context).ToLocal(&return_value)) return {};

  //  for (BaseObjectPtr<BaseObject> base_object : host_objects) {
  //    if (base_object->FinalizeTransferRead(context,
  //    &deserializer).IsNothing())
  //      return {};
  //  }

  //  host_objects.clear();
  return handle_scope.Escape(return_value);
}

void Message::AddSharedArrayBuffer(
    std::shared_ptr<BackingStore> backing_store) {
  shared_array_buffers_.emplace_back(std::move(backing_store));
}

Message::Message(MallocedBuffer<char>&& payload)
    : main_message_buf_(std::move(payload)) {}
};  // namespace worker
};  // namespace tns
