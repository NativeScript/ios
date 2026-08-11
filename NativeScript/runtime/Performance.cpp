#include "Performance.h"

#include "BuiltinLoader.h"
#include "Helpers.h"
#include "Runtime.h"

using namespace v8;

namespace tns {

void Performance::Init(v8::Local<v8::Context> context) {
  Isolate* isolate = v8::Isolate::GetCurrent();

  // kThrow so `new performance.now()` throws, as WebIDL operations must;
  // kHasNoSideEffect so the debugger can call it during side-effect-free
  // evaluation.
  Local<v8::Function> now;
  bool success = v8::Function::New(context, NowCallback, Local<Value>(), 0,
                                   ConstructorBehavior::kThrow,
                                   SideEffectType::kHasNoSideEffect)
                     .ToLocal(&now);
  tns::Assert(success, isolate);

  Local<Object> binding = Object::New(isolate);
  success = binding->Set(context, tns::ToV8String(isolate, "now"), now)
                .FromMaybe(false);
  tns::Assert(success, isolate);

  success = binding
                ->Set(context, tns::ToV8String(isolate, "timeOrigin"),
                      v8::Number::New(isolate, TimeOriginMillis(isolate)))
                .FromMaybe(false);
  tns::Assert(success, isolate);

  Local<Value> result;
  success = BuiltinLoader::RunBuiltin(context, BuiltinId::kPerformance, binding)
                .ToLocal(&result);
  tns::Assert(success, isolate);
}

double Performance::NowMillis(Isolate* isolate) {
  Runtime* runtime = Runtime::GetRuntime(isolate);
  if (runtime == nullptr) {
    return 0.0;
  }

  return runtime->PerformanceNowMillis();
}

double Performance::TimeOriginMillis(Isolate* isolate) {
  Runtime* runtime = Runtime::GetRuntime(isolate);
  if (runtime == nullptr) {
    return 0.0;
  }

  return runtime->TimeOriginMillis();
}

void Performance::NowCallback(const FunctionCallbackInfo<Value>& info) {
  info.GetReturnValue().Set(NowMillis(info.GetIsolate()));
}

}  // namespace tns
