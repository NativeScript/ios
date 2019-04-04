#ifndef ObjectManager_h
#define ObjectManager_h

#include "NativeScript.h"

namespace tns {

class ObjectManager;

struct ObjectWeakCallbackState {
    ObjectWeakCallbackState(v8::Persistent<v8::Object>* target) : target_(target) { }
    v8::Persistent<v8::Object>* target_;
};

class ObjectManager {
public:
    v8::Persistent<v8::Object>* Register(v8::Isolate* isolate, const v8::Local<v8::Object> obj);
    static void FinalizerCallback(const v8::WeakCallbackInfo<ObjectWeakCallbackState>& data);
private:
};

}

#endif /* ObjectManager_h */
