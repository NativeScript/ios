#include "PromiseProxy.h"

#include "BuiltinLoader.h"
#include "Helpers.h"
#include "Runtime.h"

using namespace v8;

namespace tns {

// Reports whether the calling thread is the isolate's runtime thread. That
// thread's run loop is where timers fire and is always being pumped, so a
// promise resolution is marshaled back to its creating thread only when that
// thread is the runtime thread; a promise created elsewhere settles on
// whichever thread resolves it. Don't use CFRunLoopGetCurrent() here: it
// creates a run loop for any thread that lacks one.
static void IsRuntimeThreadCallback(const FunctionCallbackInfo<Value>& args) {
  Runtime* runtime = Runtime::GetRuntime(args.GetIsolate());
  args.GetReturnValue().Set(runtime != nullptr && runtime->IsOnRuntimeThread());
}

void PromiseProxy::Init(v8::Local<v8::Context> context) {
  Isolate* isolate = v8::Isolate::GetCurrent();

  Local<v8::Function> isRuntimeThread;
  bool success = v8::Function::New(context, IsRuntimeThreadCallback)
                     .ToLocal(&isRuntimeThread);
  tns::Assert(success, isolate);

  Local<Object> binding = Object::New(isolate);
  success = binding
                ->Set(context, tns::ToV8String(isolate, "isRuntimeThread"),
                      isRuntimeThread)
                .FromMaybe(false);
  tns::Assert(success, isolate);

  Local<Value> result;
  success =
      BuiltinLoader::RunBuiltin(context, BuiltinId::kPromiseProxy, binding)
          .ToLocal(&result);
  tns::Assert(success, isolate);
}

}  // namespace tns
