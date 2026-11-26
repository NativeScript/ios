#include "PromiseProxy.h"

#include "BuiltinLoader.h"
#include "Caches.h"
#include "Checks.h"
#include "EventLoop.h"
#include "Helpers.h"
#include "Runtime.h"

using namespace v8;

namespace tns {

namespace {

struct PromiseProxyState {
  // promise-proxy.js's module.exports: runs the oldest queued settlement.
  Global<v8::Function> runNext;
};

void RunNextSettlement(Isolate* isolate) {
  PromiseProxyState* state = Caches::StateFor<PromiseProxyState>(isolate);
  if (state == nullptr || state->runNext.IsEmpty()) {
    return;
  }
  Local<Context> context = isolate->GetCurrentContext();
  if (context.IsEmpty()) {
    return;
  }
  (void)state->runNext.Get(isolate)->Call(context, v8::Undefined(isolate), 0, nullptr);
}

// Whether the calling thread is the isolate's runtime thread. Its run loop is
// always being pumped, so a promise resolution is marshaled back to its
// creating thread only when that thread is the runtime thread; a promise
// created elsewhere settles on whichever thread resolves it.
void IsRuntimeThreadCallback(const FunctionCallbackInfo<Value>& args) {
  Runtime* runtime = Runtime::GetRuntime(args.GetIsolate());
  args.GetReturnValue().Set(runtime != nullptr && runtime->IsOnRuntimeThread());
}

// Called from a foreign thread holding the isolate's Locker. Each successful
// post runs runNext exactly once on the runtime thread; false means the
// runtime is shutting down and the settlement can never run.
void PostToRuntimeThreadCallback(const FunctionCallbackInfo<Value>& args) {
  Isolate* isolate = args.GetIsolate();
  Runtime* runtime = Runtime::GetRuntime(isolate);
  std::shared_ptr<EventLoop> loop = runtime != nullptr ? runtime->GetEventLoop() : nullptr;
  bool posted =
      loop != nullptr && loop->PostInternal([isolate]() { RunNextSettlement(isolate); });
  args.GetReturnValue().Set(posted);
}

void SetFunction(Isolate* isolate, Local<Context> context, Local<Object> binding,
                 const char* name, FunctionCallback callback) {
  Local<v8::Function> fn;
  bool success = v8::Function::New(context, callback).ToLocal(&fn) &&
                 binding->Set(context, tns::ToV8String(isolate, name), fn).FromMaybe(false);
  NS_CHECK(success, std::string("cannot install the Promise proxy binding ") + name);
}

}  // namespace

void PromiseProxy::Init(v8::Local<v8::Context> context) {
  Isolate* isolate = v8::Isolate::GetCurrent();

  Local<Object> binding = Object::New(isolate);
  SetFunction(isolate, context, binding, "isRuntimeThread", IsRuntimeThreadCallback);
  SetFunction(isolate, context, binding, "postToRuntimeThread", PostToRuntimeThreadCallback);

  Local<Value> runNext;
  NS_CHECK(BuiltinLoader::RunBuiltin(context, BuiltinId::kPromiseProxy, binding).ToLocal(&runNext),
           "the promise-proxy builtin threw");
  NS_CHECK(runNext->IsFunction(), "the promise-proxy builtin must export a function");

  PromiseProxyState* state = Caches::StateFor<PromiseProxyState>(isolate);
  NS_CHECK(state != nullptr, "Promise proxy initialized on an isolate that is tearing down");
  state->runNext.Reset(isolate, runNext.As<v8::Function>());
}

}  // namespace tns
