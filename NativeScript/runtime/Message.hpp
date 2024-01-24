//
//  Message.hpp
//  NativeScript
//
//  Created by Eduardo Speroni on 11/22/23.
//  Copyright © 2023 Progress. All rights reserved.
//

#ifndef Message_hpp
#define Message_hpp
#include "v8.h"

namespace tns {

template <typename T>
inline T* Malloc(size_t n) {
  T* ret = malloc(n);
  return ret;
}

template <typename T>
T* UncheckedRealloc(T* pointer, size_t n) {
  size_t full_size = sizeof(T) * n;

  if (full_size == 0) {
    free(pointer);
    return nullptr;
  }

  void* allocated = realloc(pointer, full_size);

  //  if (UNLIKELY(allocated == nullptr)) {
  //    // Tell V8 that memory is low and retry.
  //    LowMemoryNotification();
  //    allocated = realloc(pointer, full_size);
  //  }

  return static_cast<T*>(allocated);
}

template <typename T>
struct MallocedBuffer {
  T* data;
  size_t size;

  T* release() {
    T* ret = data;
    data = nullptr;
    return ret;
  }

  void Truncate(size_t new_size) {
    CHECK_LE(new_size, size);
    size = new_size;
  }

  void Realloc(size_t new_size) {
    Truncate(new_size);
    data = UncheckedRealloc(data, new_size);
  }

  bool is_empty() const { return data == nullptr; }

  MallocedBuffer() : data(nullptr), size(0) {}
  explicit MallocedBuffer(size_t size) : data(Malloc<T>(size)), size(size) {}
  MallocedBuffer(T* data, size_t size) : data(data), size(size) {}
  MallocedBuffer(MallocedBuffer&& other) : data(other.data), size(other.size) {
    other.data = nullptr;
  }
  MallocedBuffer& operator=(MallocedBuffer&& other) {
    this->~MallocedBuffer();
    return *new (this) MallocedBuffer(std::move(other));
  }
  ~MallocedBuffer() { free(data); }
  MallocedBuffer(const MallocedBuffer&) = delete;
  MallocedBuffer& operator=(const MallocedBuffer&) = delete;
};

namespace worker {

class Message {
 public:
  Message(MallocedBuffer<char>&& payload = MallocedBuffer<char>());
  Message(Message&& other) = default;
  Message& operator=(Message&& other) = default;
  Message& operator=(const Message&) = delete;
  Message(const Message&) = delete;
  v8::Maybe<bool> Serialize(v8::Isolate* isolate,
                            v8::Local<v8::Context> context,
                            v8::Local<v8::Value> input);
  v8::MaybeLocal<v8::Value> Deserialize(v8::Isolate* isolate,
                                        v8::Local<v8::Context> context);
  // Internal method of Message that is called when a new SharedArrayBuffer
  // object is encountered in the incoming value's structure.
  void AddSharedArrayBuffer(std::shared_ptr<v8::BackingStore> backing_store);
  // Internal method of Message that is called once serialization finishes
  // and that transfers ownership of `data` to this message.
  //      void AddTransferable(std::unique_ptr<TransferData>&& data);
  // Internal method of Message that is called when a new WebAssembly.Module
  // object is encountered in the incoming value's structure.
  //      uint32_t AddWASMModule(v8::CompiledWasmModule&& mod);
  // Internal method of Message that is called when a shared value is
  // encountered for the first time in the incoming value's structure.
  //      void AdoptSharedValueConveyor(v8::SharedValueConveyor&& conveyor);

  // The host objects that will be transferred, as recorded by Serialize()
  // (e.g. MessagePorts).
  // Used for warning user about posting the target MessagePort to itself,
  // which will as a side effect destroy the communication channel.
  //      const std::vector<std::unique_ptr<TransferData>>& transferables()
  //      const {
  //        return transferables_;
  //      }
  //      bool has_transferables() const {
  //        return !transferables_.empty() || !array_buffers_.empty();
  //      }

  //      void MemoryInfo(MemoryTracker* tracker) const override;
  //
  //      SET_MEMORY_INFO_NAME(Message)
  //      SET_SELF_SIZE(Message)
 private:
  MallocedBuffer<char> main_message_buf_;
  // TODO(addaleax): Make this a std::variant to save storage size in the common
  // case (which is that all of these vectors are empty) once that is available
  // with C++17.
  std::vector<std::shared_ptr<v8::BackingStore>> array_buffers_;
  std::vector<std::shared_ptr<v8::BackingStore>> shared_array_buffers_;
  //      std::vector<std::unique_ptr<TransferData>> transferables_;
  //      std::vector<v8::CompiledWasmModule> wasm_modules_;
  //      std::optional<v8::SharedValueConveyor> shared_value_conveyor_;
};
};  // namespace worker
}  // namespace tns

#endif /* Message_hpp */
