#include "ObjectManager.h"
#include "DataWrapper.h"
#include "Helpers.h"
#include "Caches.h"

using namespace v8;
using namespace std;

namespace tns {

std::shared_ptr<Persistent<Value>> ObjectManager::Register(Isolate* isolate, const Local<Value> obj) {
    std::shared_ptr<Persistent<Value>> objectHandle = std::make_shared<Persistent<Value>>(isolate, obj);
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
        delete state;
    } else {
        state->target_->ClearWeak();
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
                    std::pair<void*, std::string> key = std::make_pair(data, structWrapper->StructInfo().Name());
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
                long retainCount = 0;
                if (![target isKindOfClass:[NSTimer class]]) { // The retainCount method of NSTimer instances might sometimes hang indefinitely
                    retainCount = [target retainCount];
                }

                if (retainCount > 4) {
                    return false;
                }

                cache->Instances.erase(target);
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
            void* data = extVectorWrapper->Data();
            if (data) {
                std::free(data);
            }
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
