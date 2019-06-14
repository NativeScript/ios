#include "ObjectManager.h"
#include "DataWrapper.h"
#include "Helpers.h"
#include "Caches.h"

using namespace v8;
using namespace std;

namespace tns {

Persistent<Value>* ObjectManager::Register(Isolate* isolate, const v8::Local<v8::Value> obj) {
    Persistent<Value>* objectHandle = new Persistent<Value>(isolate, obj);
    ObjectWeakCallbackState* state = new ObjectWeakCallbackState(objectHandle);
    objectHandle->SetWeak(state, FinalizerCallback, WeakCallbackType::kFinalizer);
    return objectHandle;
}

void ObjectManager::FinalizerCallback(const WeakCallbackInfo<ObjectWeakCallbackState>& data) {
    ObjectWeakCallbackState* state = data.GetParameter();
    Isolate* isolate = data.GetIsolate();
    Local<Value> value = state->target_->Get(isolate);
    ObjectManager::DisposeValue(isolate, value);

    state->target_->Reset();
    delete state->target_;
    delete state;
}

void ObjectManager::DisposeValue(Isolate* isolate, Local<Value> value) {
    if (value.IsEmpty() || value->IsNullOrUndefined() || !value->IsObject()) {
        return;
    }

    Local<Object> obj = value.As<Object>();
    if (obj->InternalFieldCount() < 1) {
        return;
    }

    BaseDataWrapper* wrapper = tns::GetValue(isolate, obj);
    if (wrapper == nullptr) {
        return;
    }

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
            if (objCObjectWrapper->Data() != nil) {
                auto it = Caches::Instances.find(objCObjectWrapper->Data());
                if (it != Caches::Instances.end()) {
                    Caches::Instances.erase(it);
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
                auto it = Caches::PointerInstances.find(pointerWrapper->Data());
                if (it != Caches::PointerInstances.end()) {
                    delete it->second;
                    Caches::PointerInstances.erase(it);
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

        default:
            break;
    }

    delete wrapper;
    obj->SetInternalField(0, v8::Undefined(isolate));
}

}
