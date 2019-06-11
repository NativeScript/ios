#include "ObjectManager.h"
#include "DataWrapper.h"
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

    Local<Value> internalField = obj->GetInternalField(0);
    if (internalField.IsEmpty() || internalField->IsNullOrUndefined() || !internalField->IsExternal()) {
        return;
    }

    Local<External> ext = internalField.As<External>();
    BaseDataWrapper* wrapper = static_cast<BaseDataWrapper*>(ext->Value());
    switch (wrapper->Type()) {
        case WrapperType::Record: {
            StructDataWrapper* structWrapper = static_cast<StructDataWrapper*>(wrapper);
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
                    it->second->Reset();
                    delete it->second;
                    Caches::Instances.erase(it);
                }
            }
            break;
        }
        case WrapperType::Block: {
            BlockDataWrapper* blockWrapper = static_cast<BlockDataWrapper*>(ext->Value());
            free(blockWrapper->Block());
            break;
        }
        case WrapperType::InteropReference: {
            InteropReferenceDataWrapper* referenceWrapper = static_cast<InteropReferenceDataWrapper*>(ext->Value());
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
        default:
            break;
    }

    delete wrapper;
    obj->SetInternalField(0, v8::Undefined(isolate));
}

}
