#include "Events.h"

#include "BuiltinLoader.h"
#include "Caches.h"
#include "Helpers.h"

using namespace v8;

namespace tns {

void Events::Init(Local<Context> context) {
  // Generic WHATWG event primitives (internal/events.js). The builtin installs
  // Event/EventTarget and the global EventTarget methods, then exports the
  // internal EventTarget instance backing the global so native dispatch
  // survives app code overwriting globalThis.dispatchEvent. The error-events
  // layer (ErrorEvents::Init) runs immediately after and installs the native
  // listener-error reporter through _installListenerErrorReporter.
  Isolate* isolate = v8::Isolate::GetCurrent();

  Local<Value> result;
  bool success =
      BuiltinLoader::RunBuiltin(context, BuiltinId::kEvents).ToLocal(&result);
  tns::Assert(success && result->IsObject(), isolate);

  auto cache = Caches::Get(isolate);
  cache->GlobalEventTarget =
      std::make_unique<Persistent<v8::Object>>(isolate, result.As<Object>());

  // AbortController/AbortSignal (internal/abort-signal.js) build directly on
  // the event primitives installed above. The events export is its binding:
  // the abort builtin takes the one-shot listener-mutation hook key from it
  // (_takeListenerChangedKey) for its GC-liveness accounting.
  Local<Value> abortResult;
  success = BuiltinLoader::RunBuiltin(context, BuiltinId::kAbortSignal, result)
                .ToLocal(&abortResult);
  tns::Assert(success, isolate);
}

}  // namespace tns
