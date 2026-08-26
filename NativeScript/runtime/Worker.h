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

  // Turns Worker and the worker global scope into EventTargets and caches the
  // builtin's delivery callout for this isolate. Runs during Runtime::Init,
  // after Events::Init has installed the event primitives it builds on.
  static void InitEvents(v8::Local<v8::Context> context);

  static std::vector<std::string> GlobalFunctions;

 private:
  static void ConstructorCallback(
      const v8::FunctionCallbackInfo<v8::Value>& info);
  static void PostMessageCallback(
      const v8::FunctionCallbackInfo<v8::Value>& info);
  static void TerminateCallback(
      const v8::FunctionCallbackInfo<v8::Value>& info);
  // Builds a MessageEvent out of `message` and dispatches it on `receiver` —
  // the Worker object for worker-to-parent traffic, the global scope's
  // EventTarget for parent-to-worker. A message that cannot be read arrives as
  // a `messageerror` event instead. No-op before InitEvents has run.
  static void OnMessageCallback(v8::Isolate* isolate,
                                v8::Local<v8::Object> receiver,
                                std::shared_ptr<worker::Message> message);
  static void PostMessageToMainCallback(
      const v8::FunctionCallbackInfo<v8::Value>& info);
  static void CloseWorkerCallback(
      const v8::FunctionCallbackInfo<v8::Value>& info);
  static void SetWorkerId(v8::Isolate* isolate, int workerId);
  static int GetWorkerId(v8::Isolate* isolate, v8::Local<v8::Object> global);
};

}  // namespace tns

#endif /* Worker_h */
