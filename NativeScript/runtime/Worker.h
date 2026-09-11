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

  // Dispatches an `error` ErrorEvent on `receiver` (the Worker object, on the
  // parent isolate) and returns whether a handler took ownership of it —
  // either by returning truthy from the `onerror` attribute or by calling
  // preventDefault(). Only primitives cross the isolate boundary, so the event
  // carries no error object. A listener that throws leaves the exception
  // pending for the caller's TryCatch and reports as unhandled. False before
  // InitEvents has run.
  static bool EmitError(v8::Isolate* isolate, v8::Local<v8::Object> receiver,
                        const std::string& message, const std::string& source,
                        const std::string& stackTrace, int lineNumber);

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
