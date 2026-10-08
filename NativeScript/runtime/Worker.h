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

  // The Worker constructor of `context`: the function Init's template
  // produces for it, which is the object the global of that name was created
  // with, whatever `globalThis.Worker` names by now. Empty before Init has
  // run for the isolate.
  static v8::MaybeLocal<v8::Function> Constructor(
      v8::Local<v8::Context> context);

  // Turns Worker and the worker global scope into EventTargets and caches the
  // builtin's delivery callout for this isolate. Runs during Runtime::Init,
  // after Events::Init has installed the event primitives it builds on.
  static void InitEvents(v8::Local<v8::Context> context);

  // Dispatches an `error` ErrorEvent on `receiver` (the Worker object, on the
  // parent isolate). Only primitives cross the isolate boundary, so the event
  // carries no error object; the worker's error is rebuilt from `errorName`,
  // `errorMessage` and `stackTrace`. Returns that error when no handler took
  // ownership of the event, for the caller to report on the parent's global
  // scope, and undefined when one did, either by returning truthy from the
  // `onerror` attribute or by calling preventDefault(). Empty when a listener
  // threw, which leaves the exception pending for the caller's TryCatch, and
  // before InitEvents has run.
  static v8::MaybeLocal<v8::Value> EmitError(
      v8::Isolate* isolate, v8::Local<v8::Object> receiver,
      const std::string& message, const std::string& source,
      const std::string& stackTrace, int lineNumber,
      const std::string& errorName, const std::string& errorMessage);

  // Dispatches `nsworkerended` on `receiver` (the Worker object, on the parent
  // isolate) once the worker's thread has finished. Internal and non-standard:
  // the web has no end-of-worker event, and the node:worker_threads shim is
  // what turns this into an 'exit'. A listener that throws leaves the exception
  // pending for the caller's TryCatch. No-op before InitEvents has run.
  static void EmitEnded(v8::Isolate* isolate, v8::Local<v8::Object> receiver);

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
