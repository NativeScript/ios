#include "NapiEnv.h"

#include <cstdio>
#include <cstdlib>

#include "NapiThreadSafeFunction.h"
#include "runtime/Helpers.h"
#include "runtime/NativeScriptException.h"
#include "runtime/Runtime.h"

using namespace v8;

namespace tns {

NapiEnv::NapiEnv(Local<Context> context)
    : napi_env__(context, NODE_API_DEFAULT_MODULE_API_VERSION),
      runtimeLoop_(CFRunLoopGetCurrent()) {}

NapiEnv::~NapiEnv() = default;

NapiEnv* NapiEnv::Create(Local<Context> context) { return new NapiEnv(context); }

void NapiEnv::Destroy(NapiEnv* env) {
  if (env == nullptr) {
    return;
  }

  // Drops the reference taken at construction, which runs the finalizer drain
  // and deletes the env.
  env->Unref();
}

NapiEnv* NapiEnv::ForIsolate(Isolate* isolate) {
  if (isolate == nullptr) {
    return nullptr;
  }

  Runtime* runtime = Runtime::GetRuntime(isolate);
  if (runtime == nullptr) {
    return nullptr;
  }

  return static_cast<NapiEnv*>(runtime->GetNapiEnv());
}

void NapiEnv::CallFinalizer(napi_finalize cb, void* data, void* hint) {
  if (cb == nullptr) {
    return;
  }

  HandleScope handle_scope(this->isolate);
  Context::Scope context_scope(this->context());

  CallIntoModule([&](napi_env env) { cb(env, data, hint); },
                 [](napi_env env, Local<Value> exception) {
                   if (env->terminatedOrTerminating()) {
                     return;
                   }
                   NativeScriptException::ReportToJsHandlersAndLog(
                       env->isolate, exception, Local<Message>());
                 });
}

void NapiEnv::EnqueueFinalizer(v8impl::RefTracker* finalizer) {
  // Runs inside V8's weak callback, where calling into JS is forbidden. The
  // queue is drained on the next runloop turn instead, which is where Node
  // puts it too (a SetImmediate there, a posted block here). One drain is
  // scheduled per non-empty stretch of the queue.
  bool scheduled = !this->pending_finalizers.empty();
  napi_env__::EnqueueFinalizer(finalizer);

  if (scheduled || this->tearingDown_ || this->runtimeLoop_ == nullptr) {
    return;
  }

  Isolate* isolate = this->isolate;
  NapiEnv* env = this;
  tns::ExecuteOnRunLoop(this->runtimeLoop_, ^{
    if (!Runtime::IsAlive(isolate) || NapiEnv::ForIsolate(isolate) != env) {
      return;
    }

    Locker locker(isolate);
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);
    env->DrainFinalizers();
  });
}

void NapiEnv::DrainFinalizers() {
  while (!this->pending_finalizers.empty()) {
    v8impl::RefTracker* finalizer = *this->pending_finalizers.begin();
    this->pending_finalizers.erase(finalizer);
    finalizer->Finalize();
  }
}

void NapiEnv::DeleteMe() {
  // ~Runtime holds the Locker but never enters the isolate (same situation
  // ObjectManager::DisposeAllRegistered handles), so teardown enters it here
  // before anything below touches handles or the context.
  Isolate::Scope isolate_scope(this->isolate);
  HandleScope handle_scope(this->isolate);

  // Cleanup hooks come first, so an addon gets to release its threadsafe
  // functions and other env-bound resources itself. Execution is already
  // terminating by now, so those releases work but nothing a hook does reaches
  // JS. Whatever survives is closed below, before any reference is finalized —
  // a threadsafe function holds one to its JS callback.
  NapiRunEnvCleanupHooks(this);
  NapiAbortThreadSafeFunctions(this);

  this->DrainFinalizers();

  // Finalizers may still touch the env, so the drain runs before teardown is
  // announced; past this point nothing an addon does may reach JS.
  v8impl::RefTracker::FinalizeAll(&this->finalizing_reflist);
  v8impl::RefTracker::FinalizeAll(&this->reflist);

  this->tearingDown_ = true;
  this->moduleExports_.clear();

  delete this;
}

Local<Private> NapiEnv::PrivateKey(NapiPrivateKeySlot slot) {
  size_t index = static_cast<size_t>(slot);
  if (this->privateKeys_[index].IsEmpty()) {
    const char* name = slot == NapiPrivateKeySlot::wrapper
                           ? "node_api.wrapper"
                           : "node_api.type_tag";
    Local<Private> key =
        Private::New(this->isolate, tns::ToV8String(this->isolate, name));
    this->privateKeys_[index].Set(this->isolate, key);
  }

  return this->privateKeys_[index].Get(this->isolate);
}

MaybeLocal<Object> NapiEnv::CachedModuleExports(const std::string& name) {
  auto it = this->moduleExports_.find(name);
  if (it == this->moduleExports_.end()) {
    return MaybeLocal<Object>();
  }

  return it->second.Get(this->isolate);
}

void NapiEnv::CacheModuleExports(const std::string& name,
                                 Local<Object> exports) {
  this->moduleExports_[name].Reset(this->isolate, exports);
}

Local<Private> NapiPrivateKey(Local<Context> context, NapiPrivateKeySlot slot) {
  // The context argument exists to match upstream's macro; one env per isolate
  // makes it redundant, and V8 no longer exposes Context::GetIsolate.
  (void)context;
  Isolate* isolate = Isolate::GetCurrent();
  NapiEnv* env = NapiEnv::ForIsolate(isolate);
  tns::Assert(env != nullptr, isolate,
              "Node-API private key requested without a napi_env");
  return env->PrivateKey(slot);
}

}  // namespace tns

namespace v8impl {

void OnFatalError(const char* location, const char* message) {
  Log(@"NativeScript Node-API fatal error: %s%s%s", message,
      location != nullptr ? " at " : "", location != nullptr ? location : "");
  tns::LogBacktrace();
  abort();
}

}  // namespace v8impl
