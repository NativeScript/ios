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
    if (obj->InternalFieldCount() > 1) {
        Local<Value> superValue = obj->GetInternalField(1);
        if (!superValue.IsEmpty() && superValue->IsString()) {
            // Do not dispose the ObjCWrapper contained in a "super" instance
            return true;
        }
    }

    BaseDataWrapper* wrapper = tns::GetValue(isolate, value);
    if (wrapper == nullptr) {
        tns::SetValue(isolate, obj, nullptr);
        return true;
    }

    Caches* cache = Caches::Get(isolate);
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
//            if (referenceWrapper->Value() != nullptr) {
//                Local<Value> value = referenceWrapper->Value()->Get(isolate);
//                ObjectManager::DisposeValue(isolate, value);
//                referenceWrapper->Value()->Reset();
//            }

            if (referenceWrapper->Data() != nullptr) {
                if (referenceWrapper->ShouldDisposeData()) {
                    std::free(referenceWrapper->Data());
                }
                referenceWrapper->SetData(nullptr);
                referenceWrapper->SetEncoding(nullptr);
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
                funcWrapper->Function()->Reset();
            }
            break;
        }
        case WrapperType::AnonymousFunction: {
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
    tns::SetValue(isolate, obj, nullptr);
    return true;
}

}
