#include "BuiltinLoader.h"

#include <mutex>
#include <vector>

#include "Helpers.h"

using namespace v8;

namespace tns {

namespace {

// Process-wide bytecode cache shared across isolates (main + workers).
std::mutex builtinCacheMutex;
std::vector<uint8_t> builtinCache[static_cast<unsigned>(BuiltinId::kCount)];

}  // namespace

MaybeLocal<Value> BuiltinLoader::RunBuiltin(Local<Context> context,
                                            BuiltinId id) {
  Isolate* isolate = context->GetIsolate();
  const BuiltinSource& builtin = GetBuiltinSource(id);
  const unsigned index = static_cast<unsigned>(id);

  // Copy the blob out so the shared slot can be refreshed concurrently while
  // this compile still reads from the copy.
  std::vector<uint8_t> blob;
  {
    std::lock_guard<std::mutex> lock(builtinCacheMutex);
    blob = builtinCache[index];
  }

  ScriptOrigin origin(isolate, tns::ToV8String(isolate, builtin.name),
                      0,      // line offset
                      0,      // column offset
                      false,  // shared_cross_origin
                      -1,     // script_id
                      Local<Value>(),
                      false,  // is_opaque
                      false,  // is_wasm
                      false   // is_module
  );
  Local<v8::String> sourceText = tns::ToV8String(
      isolate, builtin.source, static_cast<int>(builtin.length));

  Local<Script> script;
  if (!blob.empty()) {
    // The Source owns and deletes the CachedData object; BufferNotOwned keeps
    // the underlying bytes (our copy) out of its hands.
    auto* cachedData = new ScriptCompiler::CachedData(
        blob.data(), static_cast<int>(blob.size()),
        ScriptCompiler::CachedData::BufferNotOwned);
    ScriptCompiler::Source source(sourceText, origin, cachedData);
    if (ScriptCompiler::Compile(context, &source,
                                ScriptCompiler::kConsumeCodeCache)
            .ToLocal(&script) &&
        !cachedData->rejected) {
      return script->Run(context);
    }
    // Rejected cache (e.g. produced under different flags): fall through and
    // recompile eagerly so the refreshed blob covers inner functions again.
  }

  ScriptCompiler::Source source(sourceText, origin);
  if (!ScriptCompiler::Compile(context, &source, ScriptCompiler::kEagerCompile)
           .ToLocal(&script)) {
    return MaybeLocal<Value>();
  }

  std::unique_ptr<ScriptCompiler::CachedData> produced(
      ScriptCompiler::CreateCodeCache(script->GetUnboundScript()));
  if (produced != nullptr && produced->data != nullptr &&
      produced->length > 0) {
    std::lock_guard<std::mutex> lock(builtinCacheMutex);
    builtinCache[index].assign(produced->data,
                               produced->data + produced->length);
  }

  return script->Run(context);
}

}  // namespace tns
