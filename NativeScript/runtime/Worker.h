#ifndef Worker_h
#define Worker_h

#include "Common.h"
#include "Message.hpp"

namespace tns {

class Worker {
 public:
  static void Init(v8::Isolate* isolate,
                   v8::Local<v8::ObjectTemplate> globalTemplate,
                   bool isWorkerThread);
  static void Init(v8::Isolate* isolate,
                   v8::Local<v8::ObjectTemplate> globalTemplate);
  static std::vector<std::string> GlobalFunctions;
  // HMR-oriented helper: terminate every worker the runtime currently knows
  // about, snapshotted from `Caches::Workers`. Exposed by HMRSupport in the
  // main realm's `ns:runtime` builtin as `terminateAllWorkers` (returns the
  // count of workers terminated, as a number). Worker realms do NOT receive
  // this member — terminating workers from inside a worker would let a stuck
  // worker take down its peers.
  static void TerminateAllWorkersCallback(
      const v8::FunctionCallbackInfo<v8::Value>& info);

   private:
    static void ConstructorCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void PostMessageCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void TerminateCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void OnMessageCallback(v8::Isolate* isolate, v8::Local<v8::Value> receiver, std::shared_ptr<worker::Message> message);
    static void PostMessageToMainCallback(const v8::FunctionCallbackInfo<v8::Value>& info);
    static void CloseWorkerCallback(
        const v8::FunctionCallbackInfo<v8::Value>& info);
    static void SetWorkerId(v8::Isolate* isolate, int workerId);
    static int GetWorkerId(v8::Isolate* isolate, v8::Local<v8::Object> global);
};

}  // namespace tns

#endif /* Worker_h */
