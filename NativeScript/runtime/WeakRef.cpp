#include "WeakRef.h"

#include "BuiltinLoader.h"
#include "Helpers.h"

using namespace v8;

namespace tns {

void WeakRef::Init(Local<Context> context) {
  Isolate* isolate = v8::Isolate::GetCurrent();

  Local<Value> result;
  bool success =
      BuiltinLoader::RunBuiltin(context, BuiltinId::kWeakRef).ToLocal(&result);
  tns::Assert(success, isolate);
}

}  // namespace tns
