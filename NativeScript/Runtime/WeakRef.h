#ifndef WeakRef_h
#define WeakRef_h

#include "Common.h"
#include <map>

namespace tns {

class WeakRef {
public:
    static void Init(v8::Isolate* isolate, v8::Local<v8::ObjectTemplate> globalTemplate);
private:
    static std::map<v8::Isolate*, v8::Persistent<v8::Function>*> poGetterFuncs_;
    static std::map<v8::Isolate*, v8::Persistent<v8::Function>*> poClearFuncs_;

    struct CallbackState {
        CallbackState(v8::Persistent<v8::Object>* target, v8::Persistent<v8::Object>* holder)
            : target_(target), holder_(holder) {}
        v8::Persistent<v8::Object>* target_;
        v8::Persistent<v8::Object>* holder_;
    };

    static v8::Local<v8::Function> GetGetterFunction(v8::Isolate* isolate);
    static v8::Local<v8::Function> GetClearFunction(v8::Isolate* isolate);
    static void ConstructorCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void WeakTargetCallback(const v8::WeakCallbackInfo<CallbackState>& data);
    static void WeakHolderCallback(const v8::WeakCallbackInfo<CallbackState>& data);
    static void GetCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void ClearCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
};

}

#endif /* WeakRef_h */
