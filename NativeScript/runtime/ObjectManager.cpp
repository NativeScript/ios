#include "ObjectManager.h"
#include "DataWrapper.h"
#include "Helpers.h"
#include "Caches.h"

using namespace v8;
using namespace std;

namespace tns {

Persistent<Value>* ObjectManager::Register(Isolate* isolate, const Local<Value> obj) {
    Persistent<Value>* objectHandle = new Persistent<Value>(isolate, obj);
    ObjectWeakCallbackState* state = new ObjectWeakCallbackState(objectHandle);
    objectHandle->SetWeak(state, FinalizerCallback, WeakCallbackType::kFinalizer);
    return objectHandle;
}

void ObjectManager::FinalizerCallback(const WeakCallbackInfo<ObjectWeakCallbackState>& data) {
    ObjectWeakCallbackState* state = data.GetParameter();
    Isolate* isolate = data.GetIsolate();
    Local<Value> value = state->target_->Get(isolate);
    bool disposed = ObjectManager::DisposeValue(isolate, value);

    if (disposed) {
        state->target_->Reset();
        delete state->target_;
        delete state;
    } else {
        state->target_->SetWeak(state, FinalizerCallback, WeakCallbackType::kFinalizer);
    }
}

bool ObjectManager::DisposeValue(Isolate* isolate, Local<Value> value) {
    if (value.IsEmpty() || value->IsNullOrUndefined() || !value->IsObject()) {
        return true;
    }

    Local<Object> obj = value.As<Object>();
    if (obj->InternalFieldCount() < 1) {
        return true;
    }

    if (obj->InternalFieldCount() > 1) {
        Local<Value> superValue = obj->GetInternalField(1);
        if (!superValue.IsEmpty() && superValue->IsString()) {
            // Do not dispose the ObjCWrapper contained in a "super" instance
            return true;
        }
    }

    Local<Value> internalField = obj->GetInternalField(0);
    if (internalField.IsEmpty() || internalField->IsNullOrUndefined() || !internalField->IsExternal()) {
        return true;
    }

    void* internalFieldValue = internalField.As<External>()->Value();
    BaseDataWrapper* wrapper = static_cast<BaseDataWrapper*>(internalFieldValue);
    if (wrapper == nullptr) {
        obj->SetInternalField(0, v8::Undefined(isolate));
        return true;
    }

    auto cache = Caches::Get(isolate);
    switch (wrapper->Type()) {
        case WrapperType::Struct: {
            StructWrapper* structWrapper = static_cast<StructWrapper*>(wrapper);
            void* data = structWrapper->Data();
            if (data) {
                std::free(data);
            }
            break;
        }
        case WrapperType::ObjCObject: {
            ObjCDataWrapper* objCObjectWrapper = static_cast<ObjCDataWrapper*>(wrapper);
            id target = objCObjectWrapper->Data();
            if (target != nil) {
                auto it = cache->Instances.find(target);
                if (it != cache->Instances.end()) {
                    cache->Instances.erase(it);
                }
            }
            break;
        }
        case WrapperType::Block: {
            BlockWrapper* blockWrapper = static_cast<BlockWrapper*>(wrapper);
            std::free(blockWrapper->Block());
            break;
        }
        case WrapperType::Reference: {
            ReferenceWrapper* referenceWrapper = static_cast<ReferenceWrapper*>(wrapper);
            if (referenceWrapper->Value() != nullptr) {
                Local<Value> value = referenceWrapper->Value()->Get(isolate);
                ObjectManager::DisposeValue(isolate, value);
                DisposeValue(isolate, referenceWrapper->Value()->Get(isolate));
                referenceWrapper->Value()->Reset();
            }

            if (referenceWrapper->Data() != nullptr) {
                std::free(referenceWrapper->Data());
                referenceWrapper->SetData(nullptr);
            }

            break;
        }
        case WrapperType::Pointer: {
            PointerWrapper* pointerWrapper = static_cast<PointerWrapper*>(wrapper);
            if (pointerWrapper->Data() != nullptr) {
                auto it = cache->PointerInstances.find(pointerWrapper->Data());
                if (it != cache->PointerInstances.end()) {
                    delete it->second;
                    cache->PointerInstances.erase(it);
                }

                if (pointerWrapper->IsAdopted()) {
                    std::free(pointerWrapper->Data());
                    pointerWrapper->SetData(nullptr);
                }
            }
            break;
        }
        case WrapperType::FunctionReference: {
            FunctionReferenceWrapper* funcWrapper = static_cast<FunctionReferenceWrapper*>(wrapper);
            if (funcWrapper->Function() != nullptr) {
                DisposeValue(isolate, funcWrapper->Function()->Get(isolate));
                funcWrapper->Function()->Reset();
            }
            break;
        }
        case WrapperType::Worker: {
            WorkerWrapper* worker = static_cast<WorkerWrapper*>(wrapper);
            if (worker->IsRunning()) {
                return false;
            } else {
                return true;
            }
        }

        default:
            break;
    }

    delete wrapper;
    wrapper = nullptr;
    obj->SetInternalField(0, v8::Undefined(isolate));
    return true;
}

}
