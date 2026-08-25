#include "Events.h"

#include "BuiltinLoader.h"
#include "Caches.h"
#include "Helpers.h"

using namespace v8;

namespace tns {

void Events::Init(Local<Context> context) {
  // Generic WHATWG event primitives (internal/events.js). The builtin installs
  // Event/EventTarget and the global EventTarget methods; its exports carry
  // the internal EventTarget instance backing the global (cached here so
  // native dispatch survives app code overwriting globalThis.dispatchEvent)
  // and the CustomEvent interface the lazy-global tier places. Run through
  // GetExports so that tier's read shares this run. The error-events layer
  // (ErrorEvents::Init) runs immediately after and installs the native
  // listener-error reporter through _installListenerErrorReporter.
  Isolate* isolate = v8::Isolate::GetCurrent();

  Local<Object> exports;
  bool success = BuiltinLoader::GetExports(context, BuiltinId::kEvents, nullptr)
                     .ToLocal(&exports);
  tns::Assert(success, isolate);

  Local<Value> globalEventTarget;
  success = exports->Get(context, tns::ToV8String(isolate, "globalEventTarget"))
                .ToLocal(&globalEventTarget) &&
            globalEventTarget->IsObject();
  tns::Assert(success, isolate);

  auto cache = Caches::Get(isolate);
  cache->GlobalEventTarget = std::make_unique<Persistent<v8::Object>>(
      isolate, globalEventTarget.As<Object>());

  // AbortController/AbortSignal (internal/abort-signal.js) build directly on
  // the event primitives installed above; the listener-mutation hook key for
  // its GC-liveness accounting comes from the events builtin's exports, via
  // require("internal/events").
  Local<Value> abortResult;
  success = BuiltinLoader::RunBuiltin(context, BuiltinId::kAbortSignal)
                .ToLocal(&abortResult);
  tns::Assert(success, isolate);
}

}  // namespace tns
