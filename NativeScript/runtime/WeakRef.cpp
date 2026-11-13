#include "WeakRef.h"

#include "BuiltinLoader.h"
#include "Helpers.h"
#include "WrapperLifetime.h"
#include "WrapperLifetimeCanary.h"

using namespace v8;

namespace tns {

void WeakRef::Init(Local<Context> context) {
  Isolate* isolate = v8::Isolate::GetCurrent();

  TryCatch tc(isolate);
  Local<Value> result;
  bool success =
      BuiltinLoader::RunBuiltin(context, BuiltinId::kWeakRef).ToLocal(&result);
  if (!success && tc.HasCaught()) {
    tns::LogError(isolate, tc);
  }
  tns::Assert(success, isolate);

  if (GetWrapperLifetimeMode() != WrapperLifetimeMode::kCanary) {
    return;
  }
  Local<Object> binding = Object::New(isolate);
  success = WrapperLifetimeCanary::RegisterWrapFunctions(context, binding) &&
            BuiltinLoader::RunBuiltin(context, BuiltinId::kWeakCollections, binding)
                .ToLocal(&result);
  if (!success && tc.HasCaught()) {
    tns::LogError(isolate, tc);
  }
  tns::Assert(success, isolate);
}

}  // namespace tns
