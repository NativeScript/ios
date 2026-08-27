#include "ObjectManager.h"
#include <Block.h>
#include <CoreFoundation/CoreFoundation.h>
#include <sstream>
#include "Caches.h"
#include "Constants.h"
#include "DataWrapper.h"
#include "FFICall.h"
#include "Helpers.h"

using namespace v8;
using namespace std;

namespace tns {

static Class NSTimerClass = objc_getClass("NSTimer");

void ObjectManager::Init(Isolate* isolate, Local<ObjectTemplate> globalTemplate) {
  globalTemplate->Set(tns::ToV8String(isolate, "__releaseNativeCounterpart"),
                      FunctionTemplate::New(isolate, ReleaseNativeCounterpartCallback));
}

namespace {

void LinkRegistered(v8::Isolate* isolate, ObjectWeakCallbackState* state) {
  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  if (cache == nullptr) {
    return;
  }
  state->head_ = &cache->ObjectManagedValues;
  state->next_ = *state->head_;
  if (state->next_ != nullptr) {
    state->next_->prev_ = state;
  }
  *state->head_ = state;
}

void UnlinkRegistered(ObjectWeakCallbackState* state) {
  if (state->head_ == nullptr) {
    return;
  }
  if (state->prev_ != nullptr) {
    state->prev_->next_ = state->next_;
  } else if (*state->head_ == state) {
    *state->head_ = state->next_;
  }
  if (state->next_ != nullptr) {
    state->next_->prev_ = state->prev_;
  }
  state->head_ = nullptr;
  state->prev_ = nullptr;
  state->next_ = nullptr;
}

}  // namespace

std::shared_ptr<Persistent<Value>> ObjectManager::Register(Local<Context> context,
                                                           const Local<Value> obj) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  std::shared_ptr<Persistent<Value>> objectHandle =
      std::make_shared<Persistent<Value>>(isolate, obj);
  objectHandle->SetWrapperClassId(Constants::ClassTypes::ObjectManagedValue);
  ObjectWeakCallbackState* state = new ObjectWeakCallbackState(objectHandle);
  objectHandle->SetWeak(state, FinalizerCallback, WeakCallbackType::kFinalizer);

  LinkRegistered(isolate, state);

  return objectHandle;
}

namespace {

// The DataWrapper-tagged handles used to be reached through
// Isolate::VisitHandlesWithClassIds; they all live in Caches, so walk those
// directly instead.
template <typename Map>
void DisposeHandleMap(v8::Isolate* isolate, Map& map) {
  for (auto& entry : map) {
    if (entry.second == nullptr || entry.second->IsEmpty()) {
      continue;
    }
    ObjectManager::DisposeValue(isolate, entry.second->Get(isolate), true);
  }
}

void DisposeHandle(v8::Isolate* isolate,
                   const std::unique_ptr<v8::Persistent<v8::Function>>& handle) {
  if (handle == nullptr || handle->IsEmpty()) {
    return;
  }
  ObjectManager::DisposeValue(isolate, handle->Get(isolate), true);
}

}  // namespace

void ObjectManager::DisposeAllRegistered(Isolate* isolate) {
  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  if (cache == nullptr) {
    return;
  }

  // Runs from ~Runtime, which holds a Locker but has not entered the isolate;
  // creating handles below requires it to be entered.
  Isolate::Scope isolateScope(isolate);
  HandleScope scope(isolate);

  // Detach the whole list first so disposal can't walk into freed entries.
  ObjectWeakCallbackState* state = cache->ObjectManagedValues;
  cache->ObjectManagedValues = nullptr;

  while (state != nullptr) {
    ObjectWeakCallbackState* next = state->next_;

    std::shared_ptr<Persistent<Value>> handle = state->target_;
    if (handle != nullptr && !handle->IsEmpty()) {
      ObjectManager::DisposeValue(isolate, handle->Get(isolate), true);
      if (handle->IsWeak()) {
        handle->ClearWeak<ObjectWeakCallbackState>();
      }
      handle->Reset();
    }
    delete state;

    state = next;
  }

  DisposeHandleMap(isolate, cache->CtorFuncs);
  DisposeHandleMap(isolate, cache->ProtocolCtorFuncs);
  DisposeHandleMap(isolate, cache->CFunctions);
  DisposeHandleMap(isolate, cache->PrimitiveInteropTypes);
  DisposeHandle(isolate, cache->InteropReferenceCtorFunc);
  DisposeHandle(isolate, cache->PointerCtorFunc);
  DisposeHandle(isolate, cache->FunctionReferenceCtorFunc);
}

void ObjectManager::FinalizerCallback(const WeakCallbackInfo<ObjectWeakCallbackState>& data) {
  ObjectWeakCallbackState* state = data.GetParameter();
  Isolate* isolate = data.GetIsolate();
  Local<Value> value = state->target_->Get(isolate);
  bool disposed = ObjectManager::DisposeValue(isolate, value);

  if (disposed) {
    UnlinkRegistered(state);
    state->target_->Reset();
    delete state;
  } else {
    state->target_->ClearWeak<void>();
    state->target_->SetWeak(state, FinalizerCallback, WeakCallbackType::kFinalizer);
  }
}

bool ObjectManager::DisposeValue(Isolate* isolate, Local<Value> value, bool isFinalDisposal) {
  if (value.IsEmpty() || value->IsNullOrUndefined() || !value->IsObject()) {
    return true;
  }

  Local<Object> obj = value.As<Object>();
  if (obj->InternalFieldCount() > 1 && !isFinalDisposal) {
    Local<Value> superValue = obj->GetInternalField(1).As<v8::Value>();
    if (!superValue.IsEmpty() && superValue->IsString()) {
      // Do not dispose the ObjCWrapper contained in a "super" instance
      return true;
    }
  }

  BaseDataWrapper* wrapper = tns::GetValue(isolate, value);
  // NSLog(@"dispose %p", wrapper);
  if (wrapper == nullptr) {
    tns::SetValue(isolate, obj, nullptr);
    return true;
  }

  if (wrapper->IsGcProtected() && !isFinalDisposal) {
    return false;
  }

  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  switch (wrapper->Type()) {
    case WrapperType::Struct: {
      StructWrapper* structWrapper = static_cast<StructWrapper*>(wrapper);
      void* data = structWrapper->Data();

      std::shared_ptr<Persistent<Value>> poParentStruct = structWrapper->Parent();
      if (poParentStruct != nullptr) {
        Local<Value> parentStruct = poParentStruct->Get(isolate);
        BaseDataWrapper* parentWrapper = tns::GetValue(isolate, parentStruct);
        if (parentWrapper != nullptr && parentWrapper->Type() == WrapperType::Struct) {
          StructWrapper* parentStructWrapper = static_cast<StructWrapper*>(parentWrapper);
          parentStructWrapper->DecrementChildren();
        }
      } else {
        if (structWrapper->ChildCount() == 0) {
          std::pair<void*, std::string> key =
              std::make_pair(data, structWrapper->StructInfo().Name());
          cache->StructInstances.erase(key);
          std::free(data);
        } else {
          return false;
        }
      }
      break;
    }
    case WrapperType::ObjCObject: {
      ObjCDataWrapper* objCObjectWrapper = static_cast<ObjCDataWrapper*>(wrapper);
      id target = objCObjectWrapper->Data();
      if (target != nil) {
        // Instances is keyed on the raw address, so an entry rebuilt for a
        // later object living there must survive this wrapper going away —
        // only the entry that still points back at this object is ours.
        auto it = cache->Instances.find(target);
        if (it != cache->Instances.end()) {
          Local<Value> cached = it->second->Get(isolate);
          if (cached.IsEmpty() || cached == value) {
            cache->Instances.erase(it);
          }
        }
        [target release];
      }
      break;
    }
    case WrapperType::Block: {
      BlockWrapper* blockWrapper = static_cast<BlockWrapper*>(wrapper);
      if (blockWrapper->OwnsBlock()) {
        // Balance the Block_copy taken when a native block was wrapped for JS
        // (see Interop::GetResult). Block_release is the correct counterpart to
        // Block_copy and runs the block's dispose helper once we drop the last
        // reference. (Using CFRelease here over-released stack blocks that were
        // never promoted to the heap, crashing in objc_release during GC.)
        Block_release(blockWrapper->Block());
      }
      // Blocks created from JS callbacks (OwnsBlock() == false) are owned by
      // the native code they were handed to (e.g. NSNotificationCenter);
      // freeing them here would leave that code with a dangling pointer. The
      // JSBlock dispose helper cleans up once the last native reference goes.
      break;
    }
    case WrapperType::Reference: {
      ReferenceWrapper* referenceWrapper = static_cast<ReferenceWrapper*>(wrapper);
      if (referenceWrapper->Data() != nullptr) {
        referenceWrapper->SetData(nullptr);
        referenceWrapper->SetEncoding(nullptr);
      }

      break;
    }
    case WrapperType::Pointer: {
      PointerWrapper* pointerWrapper = static_cast<PointerWrapper*>(wrapper);
      if (pointerWrapper->Data() != nullptr) {
        cache->PointerInstances.erase(pointerWrapper->Data());

        if (pointerWrapper->IsAdopted()) {
          std::free(pointerWrapper->Data());
          pointerWrapper->SetData(nullptr);
        }
      }
      break;
    }
    case WrapperType::FunctionReference: {
      FunctionReferenceWrapper* funcWrapper = static_cast<FunctionReferenceWrapper*>(wrapper);
      std::shared_ptr<Persistent<Value>> func = funcWrapper->Function();
      if (func != nullptr) {
        func->Reset();
      }
      break;
    }
    case WrapperType::AnonymousFunction: {
      break;
    }
    case WrapperType::ExtVector: {
      ExtVectorWrapper* extVectorWrapper = static_cast<ExtVectorWrapper*>(wrapper);
      FFICall::DisposeFFIType(extVectorWrapper->FFIType(), extVectorWrapper->TypeEncoding());
      void* data = extVectorWrapper->Data();
      if (data) {
        std::free(data);
      }
      break;
    }
    case WrapperType::Worker: {
      WorkerWrapper* worker = static_cast<WorkerWrapper*>(wrapper);
      if (!worker->isDisposed()) {
        // A running worker's Worker object is rooted (WorkerWrapper::
        // RootWorkerObject), so a weak callback should not reach a live worker
        // at all. This refusal stays as the floor under that: re-arming keeps
        // the wrapper alive for another cycle, which is safe, whereas freeing
        // it while the thread still posts through it is not. Reaching it is not
        // free either -- a re-armed handle that is also a weak-collection key
        // can corrupt the collector's ephemeron bookkeeping -- so it is a
        // fallback, not a mechanism to rely on.
        //
        // During final disposal, inform the worker it should delete itself.
        if (isFinalDisposal) {
          worker->MakeWeak();
        }
        return false;
      }
      break;
    }

    default:
      break;
  }

  delete wrapper;
  wrapper = nullptr;
  tns::DeleteValue(isolate, obj);
  return true;
}

void ObjectManager::ReleaseNativeCounterpartCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();

  if (info.Length() != 1) {
    std::ostringstream errorStream;
    errorStream << "Actual arguments count: \"" << info.Length() << "\". Expected: \"1\".";
    std::string errorMessage = errorStream.str();
    Local<Value> error = Exception::Error(tns::ToV8String(isolate, errorMessage));
    isolate->ThrowException(error);
    return;
  }

  Local<Value> value = info[0];
  BaseDataWrapper* wrapper = tns::GetValue(isolate, value);

  if (wrapper == nullptr) {
    std::string arg0 = tns::ToString(isolate, info[0]);
    std::ostringstream errorStream;
    errorStream << arg0 << " is an object which is not a native wrapper.";
    std::string errorMessage = errorStream.str();
    Local<Value> error = Exception::Error(tns::ToV8String(isolate, errorMessage));
    isolate->ThrowException(error);
    return;
  }

  if (wrapper->Type() != WrapperType::ObjCObject) {
    return;
  }

  ObjCDataWrapper* objcWrapper = static_cast<ObjCDataWrapper*>(wrapper);
  id data = objcWrapper->Data();
  if (data != nil) {
    std::shared_ptr<Caches> cache = Caches::Get(isolate);
    auto it = cache->Instances.find(data);
    if (it != cache->Instances.end()) {
      ObjectWeakCallbackState* state = it->second->ClearWeak<ObjectWeakCallbackState>();
      if (state != nullptr) {
        UnlinkRegistered(state);
        delete state;
      }
      cache->Instances.erase(it);
    }

    // Release the runtime's strong reference (taken when the object was first
    // wrapped or adopted from an alloc/new/copy return). For instances solely
    // owned by JS this deallocates immediately; for shared natives (e.g. an
    // NSNotificationCenter observer token) the remaining owners keep it alive.
    // Calling [data dealloc] here, as this used to do, destroyed objects that
    // were still referenced elsewhere and caused use-after-free crashes.
    [data release];

    delete wrapper;
    tns::SetValue(isolate, value.As<Object>(), nullptr);
  }
}

bool ObjectManager::IsInstanceOf(id obj, Class clazz) { return [obj isKindOfClass:clazz]; }

long ObjectManager::GetRetainCount(id obj) {
  if (!obj) {
    return 0;
  }

  if (ObjectManager::IsInstanceOf(obj, NSTimerClass)) {
    return 0;
  }

  return CFGetRetainCount(obj);
}

}  // namespace tns
