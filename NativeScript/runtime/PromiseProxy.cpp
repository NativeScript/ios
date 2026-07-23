#include "PromiseProxy.h"

#include <CoreFoundation/CoreFoundation.h>

#include "BuiltinLoader.h"
#include "Helpers.h"
#include "Runtime.h"

using namespace v8;

namespace tns {

// Reports whether the calling thread runs the isolate's runtime loop. That loop
// is where timers fire and is always being pumped, so a promise resolution is
// marshaled back to its creating thread only when that thread is the runtime
// loop; a promise created elsewhere settles on whichever thread resolves it.
static void IsRuntimeRunloopCallback(const FunctionCallbackInfo<Value>& args) {
  Runtime* runtime = Runtime::GetRuntime(args.GetIsolate());
  bool isRuntimeLoop =
      runtime != nullptr && CFRunLoopGetCurrent() == runtime->RuntimeLoop();
  args.GetReturnValue().Set(isRuntimeLoop);
}

void PromiseProxy::Init(v8::Local<v8::Context> context) {
  Isolate* isolate = context->GetIsolate();

  Local<Value> result;
  bool success = BuiltinLoader::RunBuiltin(context, BuiltinId::kPromiseProxy)
                     .ToLocal(&result);
  tns::Assert(success && result->IsFunction(), isolate);

  Local<v8::Function> installProxy = result.As<v8::Function>();

  Local<v8::Function> isRuntimeRunloop;
  success = v8::Function::New(context, IsRuntimeRunloopCallback)
                .ToLocal(&isRuntimeRunloop);
  tns::Assert(success, isolate);

  Local<Value> installArgs[] = {isRuntimeRunloop};
  Local<Value> installResult;
  success = installProxy->Call(context, context->Global(), 1, installArgs)
                .ToLocal(&installResult);
  tns::Assert(success, isolate);
}

}  // namespace tns
