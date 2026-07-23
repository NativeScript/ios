#include "Events.h"

#include "BuiltinLoader.h"
#include "Caches.h"
#include "Helpers.h"

using namespace v8;

namespace tns {

void Events::Init(Local<Context> context) {
  // Generic WHATWG event primitives. Plain (module-free) script, strict inside
  // the IIFE, ES5-ish so it never depends on other runtime extensions. The IIFE
  // installs Event/EventTarget and the global EventTarget methods, then returns
  // the internal EventTarget instance backing the global so native dispatch
  // survives app code overwriting globalThis.dispatchEvent. The error-events
  // layer (ErrorEvents::Init) runs immediately after and installs the native
  // listener-error reporter through _installListenerErrorReporter.
  Isolate* isolate = context->GetIsolate();

  Local<Value> result;
  bool success =
      BuiltinLoader::RunBuiltin(context, BuiltinId::kEvents).ToLocal(&result);
  tns::Assert(success && result->IsFunction(), isolate);

  Local<v8::Function> iife = result.As<v8::Function>();

  Local<Value> iifeResult;
  success =
      iife->Call(context, context->Global(), 0, nullptr).ToLocal(&iifeResult);
  tns::Assert(success && iifeResult->IsObject(), isolate);

  auto cache = Caches::Get(isolate);
  cache->GlobalEventTarget = std::make_unique<Persistent<v8::Object>>(
      isolate, iifeResult.As<Object>());
}

}  // namespace tns
