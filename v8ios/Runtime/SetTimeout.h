#ifndef SetTimeout_h
#define SetTimeout_h

#include <map>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include "v8.h"
#pragma clang diagnostic pop

namespace tns {

class SetTimeout {
public:
    static void Init(v8::Isolate* isolate);
private:
    struct CacheEntry;
    static void SetTimeoutCallback(const v8::FunctionCallbackInfo<v8::Value>& args);
    static void ClearTimeoutCallback(const v8::FunctionCallbackInfo<v8::Value>& args);
    static void Elapsed(const uint32_t key);
    static void RemoveKey(const uint32_t key);
    static std::map<uint32_t, CacheEntry> cache_;
    static uint32_t count_;

    struct CacheEntry {
        CacheEntry(v8::Isolate* isolate, v8::Persistent<v8::Function>* callback)
        : isolate_(isolate), callback_(callback) {}
        v8::Isolate* isolate_;
        v8::Persistent<v8::Function>* callback_;
    };
};

}

#endif /* SetTimeout_h */
