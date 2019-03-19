#ifndef ObjectManager_h
#define ObjectManager_h

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include "v8.h"
#pragma clang diagnostic pop

namespace tns {

class ObjectManager {
public:
    void Register(v8::Isolate* isolate, const v8::Local<v8::Object> obj);
private:
    struct ObjectWeakCallbackState;
    static void FinalizerCallback(const v8::WeakCallbackInfo<ObjectWeakCallbackState>& data);

    struct ObjectWeakCallbackState {
        ObjectWeakCallbackState(ObjectManager* objectManager, v8::Persistent<v8::Object>* target)
        : objectManager_(objectManager), target_(target) { }
        ObjectManager* objectManager_;
        v8::Persistent<v8::Object>* target_;
    };
};

}

#endif /* ObjectManager_h */
