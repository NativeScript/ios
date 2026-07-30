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

// Every builtin is compiled as a function body receiving this single, fixed
// parameter (Node's internalBinding idiom): natives arrive as properties of
// one bag object and each file destructures what it needs.
constexpr const char* kBindingParamName = "binding";

MaybeLocal<v8::Function> CompileBuiltin(Local<Context> context, BuiltinId id) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  const BuiltinSource& builtin = GetBuiltinSource(id);
  const unsigned index = static_cast<unsigned>(id);

  // Copy the blob out so the shared slot can be refreshed concurrently while
  // this compile still reads from the copy.
  std::vector<uint8_t> blob;
  {
    std::lock_guard<std::mutex> lock(builtinCacheMutex);
    blob = builtinCache[index];
  }

  ScriptOrigin origin(tns::ToV8String(isolate, builtin.name),
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
  Local<v8::String> params[] = {tns::ToV8String(isolate, kBindingParamName)};

  Local<v8::Function> fn;
  if (!blob.empty()) {
    // The Source owns and deletes the CachedData object; BufferNotOwned keeps
    // the underlying bytes (our copy) out of its hands.
    auto* cachedData = new ScriptCompiler::CachedData(
        blob.data(), static_cast<int>(blob.size()),
        ScriptCompiler::CachedData::BufferNotOwned);
    ScriptCompiler::Source source(sourceText, origin, cachedData);
    if (ScriptCompiler::CompileFunction(context, &source, 1, params, 0, nullptr,
                                        ScriptCompiler::kConsumeCodeCache)
            .ToLocal(&fn) &&
        !cachedData->rejected) {
      return fn;
    }
    // Rejected cache (e.g. produced under different flags): fall through and
    // recompile eagerly so the refreshed blob covers inner functions again.
  }

  ScriptCompiler::Source source(sourceText, origin);
  if (!ScriptCompiler::CompileFunction(context, &source, 1, params, 0, nullptr,
                                       ScriptCompiler::kEagerCompile)
           .ToLocal(&fn)) {
    return MaybeLocal<v8::Function>();
  }

  std::unique_ptr<ScriptCompiler::CachedData> produced(
      ScriptCompiler::CreateCodeCacheForFunction(fn));
  if (produced != nullptr && produced->data != nullptr &&
      produced->length > 0) {
    std::lock_guard<std::mutex> lock(builtinCacheMutex);
    builtinCache[index].assign(produced->data,
                               produced->data + produced->length);
  }

  return fn;
}

}  // namespace

MaybeLocal<Value> BuiltinLoader::RunBuiltin(Local<Context> context,
                                            BuiltinId id,
                                            Local<Value> binding) {
  Isolate* isolate = v8::Isolate::GetCurrent();

  Local<v8::Function> fn;
  if (!CompileBuiltin(context, id).ToLocal(&fn)) {
    return MaybeLocal<Value>();
  }

  Local<Value> args[] = {binding.IsEmpty() ? v8::Undefined(isolate).As<Value>()
                                           : binding};
  return fn->Call(context, v8::Undefined(isolate), 1, args);
}

}  // namespace tns
