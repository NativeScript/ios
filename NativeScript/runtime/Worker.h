#ifndef Worker_h
#define Worker_h

#include "Common.h"
#include "Message.hpp"

namespace tns {

class Worker {
public:
    static void Init(v8::Isolate* isolate, v8::Local<v8::ObjectTemplate> globalTemplate, bool isWorkerThread);
    static void Init(v8::Isolate* isolate, v8::Local<v8::ObjectTemplate> globalTemplate);
    static std::vector<std::string> GlobalFunctions;
private:
    static void ConstructorCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void PostMessageCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void TerminateCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    // HMR-oriented helper: terminate every worker the runtime currently knows
    // about, snapshotted from `Caches::Workers`. Registered on the main
    // isolate as `globalThis.__nsTerminateAllWorkers` (returns the count of
    // workers terminated, as a number). Worker threads do NOT receive this
    // global — terminating workers from inside a worker would let a stuck
    // worker take down its peers.
    static void TerminateAllWorkersCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void OnMessageCallback(v8::Isolate* isolate, v8::Local<v8::Value> receiver, std::shared_ptr<worker::Message> message);
    static void PostMessageToMainCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void CloseWorkerCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static v8::Local<v8::String> Serialize(v8::Isolate* isolate, v8::Local<v8::Value> value, v8::Local<v8::Value>& error);
    static void SetWorkerId(v8::Isolate* isolate, int workerId);
    static int GetWorkerId(v8::Isolate* isolate, v8::Local<v8::Object> global);
};

}

#endif /* Worker_h */
