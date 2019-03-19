#include <Foundation/Foundation.h>
#include "ObjectManager.h"
#include "MetadataBuilder.h"

using namespace v8;
using namespace std;

namespace tns {

void ObjectManager::Register(Isolate* isolate, const v8::Local<v8::Object> obj) {
    Persistent<Object>* objectHandle = new Persistent<Object>(isolate, obj);
    ObjectWeakCallbackState* state = new ObjectWeakCallbackState(this, objectHandle);
    objectHandle->SetWeak(state, FinalizerCallback, WeakCallbackType::kFinalizer);
}

void ObjectManager::FinalizerCallback(const WeakCallbackInfo<ObjectWeakCallbackState>& data) {
    ObjectWeakCallbackState* state = data.GetParameter();
    Isolate* isolate = data.GetIsolate();
    Local<Object> obj = state->target_->Get(isolate);
    if (obj->InternalFieldCount() > 0) {
        Local<External> ext = obj->GetInternalField(0).As<External>();
        MethodCallbackData* callbackData = reinterpret_cast<MethodCallbackData*>(ext->Value());
        delete callbackData;
    }
    obj->SetInternalField(0, v8::Undefined(isolate));
    state->target_->Reset();
    delete state->target_;
    delete state;
}

}
