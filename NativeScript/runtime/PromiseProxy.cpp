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
  Isolate* isolate = v8::Isolate::GetCurrent();

  Local<v8::Function> isRuntimeRunloop;
  bool success = v8::Function::New(context, IsRuntimeRunloopCallback)
                     .ToLocal(&isRuntimeRunloop);
  tns::Assert(success, isolate);

  Local<Object> binding = Object::New(isolate);
  success = binding
                ->Set(context, tns::ToV8String(isolate, "isRuntimeRunloop"),
                      isRuntimeRunloop)
                .FromMaybe(false);
  tns::Assert(success, isolate);

  Local<Value> result;
  success =
      BuiltinLoader::RunBuiltin(context, BuiltinId::kPromiseProxy, binding)
          .ToLocal(&result);
  tns::Assert(success, isolate);
}

}  // namespace tns
