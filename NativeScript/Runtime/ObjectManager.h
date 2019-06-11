#ifndef ObjectManager_h
#define ObjectManager_h

#include "Common.h"

namespace tns {

class ObjectManager;

struct ObjectWeakCallbackState {
    ObjectWeakCallbackState(v8::Persistent<v8::Value>* target) : target_(target) { }
    v8::Persistent<v8::Value>* target_;
};

class ObjectManager {
public:
    static v8::Persistent<v8::Value>* Register(v8::Isolate* isolate, const v8::Local<v8::Value> obj);
    static void FinalizerCallback(const v8::WeakCallbackInfo<ObjectWeakCallbackState>& data);
private:
    static void DisposeValue(v8::Isolate* isolate, v8::Local<v8::Value> value);
};

}

#endif /* ObjectManager_h */
