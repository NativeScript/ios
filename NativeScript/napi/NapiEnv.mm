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
      runtimeLoop_(CFRunLoopGetCurrent()),
      eventLoop_(Runtime::GetCurrentRuntime()->GetEventLoop()) {}

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
  // queue is drained on a later event-loop entry instead, which is where Node
  // puts it too (a SetImmediate there, an internal-lane post here). One drain
  // is scheduled per non-empty stretch of the queue.
  bool scheduled = !this->pending_finalizers.empty();
  napi_env__::EnqueueFinalizer(finalizer);

  if (scheduled || this->tearingDown_) {
    return;
  }

  std::shared_ptr<tns::EventLoop> loop = this->GetEventLoop();
  if (loop == nullptr) {
    return;
  }

  // The entry runs under the loop's Locker/scopes; EventLoop::Shutdown drops
  // queued entries before ~Runtime destroys this env, so `this` is live here.
  NapiEnv* env = this;
  loop->PostInternal([env]() { env->DrainFinalizers(); });
}

void NapiEnv::RegisterExternalFinalizer(const std::shared_ptr<NapiExternalFinalizer>& finalizer) {
  this->externalFinalizers_.insert(finalizer);
}

void NapiEnv::RunExternalFinalizer(const std::shared_ptr<NapiExternalFinalizer>& finalizer) {
  if (finalizer->claimed.exchange(true)) {
    return;
  }

  this->CallFinalizer(finalizer->cb, finalizer->data, finalizer->hint);
  this->externalFinalizers_.erase(finalizer);
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

  // From here on can_call_into_js() is false: hooks and finalizers still run
  // and may release env-bound resources (delete refs, release threadsafe
  // functions), but any Node-API call that would enter JS is refused, matching
  // Node's teardown contract.
  this->tearingDown_ = true;

  // Cleanup hooks come first, so an addon gets to release its threadsafe
  // functions and other env-bound resources itself. Whatever survives is
  // closed below, before any reference is finalized — a threadsafe function
  // holds one to its JS callback.
  NapiRunEnvCleanupHooks(this);
  NapiAbortThreadSafeFunctions(this);

  this->DrainFinalizers();

  v8impl::RefTracker::FinalizeAll(&this->finalizing_reflist);
  v8impl::RefTracker::FinalizeAll(&this->reflist);

  // External-buffer finalizers whose backing-store deleter has not fired (or
  // whose posted run was dropped by Shutdown) run here, while the env can
  // still make the callback; the deleter finds them claimed and does nothing.
  while (!this->externalFinalizers_.empty()) {
    this->RunExternalFinalizer(*this->externalFinalizers_.begin());
  }

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
