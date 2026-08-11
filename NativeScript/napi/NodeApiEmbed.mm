// The embedder half of Node-API: everything node_api.h declares that the
// vendored js_native_api_v8.cc does not implement. Upstream this is
// src/node_api.cc, which is bound to node::Environment and libuv and so cannot
// be vendored.

// Must precede every include: without NAPI_EXPERIMENTAL, NAPI_VERSION defaults
// to 8 and the version-gated declarations in node_api.h stay invisible, so the
// definitions below would silently not match anything.
#define NAPI_EXPERIMENTAL
#define NODE_API_EXPERIMENTAL_NO_WARNING

#include <dispatch/dispatch.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include "node_api.h"

#include "js_native_api_v8.h"

#include "NapiEnv.h"
#include "NapiModules.h"
#include "runtime/Helpers.h"
#include "runtime/NativeScriptException.h"
#include "runtime/Runtime.h"

namespace {

struct ModuleRegistry {
  std::mutex mutex;
  std::unordered_map<std::string, napi_module*> modules;
};

// Addons register from static constructors at image-load time and are read
// much later from JS threads, so the table must outlive both the static
// initialization order and every other TU's static destructors.
ModuleRegistry& Registry() {
  static ModuleRegistry* registry = new ModuleRegistry();
  return *registry;
}

napi_module* FindModule(const std::string& name) {
  ModuleRegistry& registry = Registry();
  std::lock_guard<std::mutex> lock(registry.mutex);
  auto it = registry.modules.find(name);
  return it == registry.modules.end() ? nullptr : it->second;
}

}  // namespace

//=== Module registration ==================================================

void NAPI_CDECL napi_module_register(napi_module* mod) {
  if (mod == nullptr || mod->nm_modname == nullptr) {
    return;
  }

  ModuleRegistry& registry = Registry();
  std::lock_guard<std::mutex> lock(registry.mutex);
  registry.modules[mod->nm_modname] = mod;
}

// The symbol node-gyp addons built against Node's internal registration path
// emit instead of napi_module_register.
extern "C" NAPI_MODULE_EXPORT void node_module_register(void* mod);

extern "C" NAPI_MODULE_EXPORT void node_module_register(void* mod) {
  napi_module_register(static_cast<napi_module*>(mod));
}

namespace tns {

bool NapiModules::IsRegistered(const std::string& name) {
  return FindModule(name) != nullptr;
}

v8::MaybeLocal<v8::Object> NapiModules::GetExports(v8::Local<v8::Context> context,
                                                   const std::string& name) {
  napi_module* mod = FindModule(name);
  if (mod == nullptr || mod->nm_register_func == nullptr) {
    return v8::MaybeLocal<v8::Object>();
  }

  v8::Isolate* isolate = v8::Isolate::GetCurrent();
  NapiEnv* env = NapiEnv::ForIsolate(isolate);
  if (env == nullptr) {
    return v8::MaybeLocal<v8::Object>();
  }

  v8::Local<v8::Object> cached;
  if (env->CachedModuleExports(name).ToLocal(&cached)) {
    return cached;
  }

  v8::Local<v8::Object> exports = v8::Object::New(isolate);

  v8::Local<v8::Context> envContext = env->context();
  v8::Context::Scope contextScope(envContext);
  v8::TryCatch tc(isolate);

  napi_value returned = mod->nm_register_func(
      env, v8impl::JsValueFromV8LocalValue(exports));
  if (tc.HasCaught()) {
    tc.ReThrow();
    return v8::MaybeLocal<v8::Object>();
  }

  if (returned != nullptr) {
    v8::Local<v8::Value> value = v8impl::V8LocalValueFromJsValue(returned);
    // A primitive return has no way to become a module namespace, so the
    // object handed to the register func stays authoritative.
    if (value->IsObject()) {
      exports = value.As<v8::Object>();
    }
  }

  env->CacheModuleExports(name, exports);
  return exports;
}

}  // namespace tns

//=== Version and fatal errors =============================================

napi_status NAPI_CDECL napi_get_node_version(
    node_api_basic_env env, const napi_node_version** version) {
  CHECK_ENV(env);
  CHECK_ARG(env, version);

  static const napi_node_version node_version = {26, 7, 0, "node"};
  *version = &node_version;

  return napi_clear_last_error(env);
}

void NAPI_CDECL napi_fatal_error(const char* location,
                                 size_t location_len,
                                 const char* message,
                                 size_t message_len) {
  std::string location_string;
  if (location != nullptr) {
    location_string.assign(location, location_len == NAPI_AUTO_LENGTH
                                         ? strlen(location)
                                         : location_len);
  }

  std::string message_string;
  if (message != nullptr) {
    message_string.assign(
        message,
        message_len == NAPI_AUTO_LENGTH ? strlen(message) : message_len);
  }

  Log("FATAL ERROR: %s %s", location_string.c_str(), message_string.c_str());
  abort();
}

napi_status NAPI_CDECL napi_fatal_exception(napi_env env, napi_value err) {
  CHECK_ENV(env);
  CHECK_ARG(env, err);

  v8::HandleScope scope(env->isolate);
  tns::NativeScriptException::ReportToJsHandlersAndLog(
      env->isolate,
      v8impl::V8LocalValueFromJsValue(err),
      v8::Local<v8::Message>());

  return napi_clear_last_error(env);
}

//=== Buffers ==============================================================
//
// There is no node::Buffer here: a napi buffer is a plain Uint8Array, which is
// what addons observe through napi_get_buffer_info either way.

napi_status NAPI_CDECL napi_create_buffer(napi_env env,
                                          size_t length,
                                          void** data,
                                          napi_value* result) {
  NAPI_PREAMBLE(env);
  CHECK_ARG(env, result);

  v8::Local<v8::ArrayBuffer> buffer = v8::ArrayBuffer::New(env->isolate, length);
  v8::Local<v8::Uint8Array> array = v8::Uint8Array::New(buffer, 0, length);

  if (data != nullptr) {
    *data = buffer->Data();
  }

  *result = v8impl::JsValueFromV8LocalValue(array);
  return GET_RETURN_STATUS(env);
}

napi_status NAPI_CDECL napi_create_buffer_copy(napi_env env,
                                               size_t length,
                                               const void* data,
                                               void** result_data,
                                               napi_value* result) {
  NAPI_PREAMBLE(env);
  CHECK_ARG(env, result);

  v8::Local<v8::ArrayBuffer> buffer = v8::ArrayBuffer::New(env->isolate, length);
  if (length > 0) {
    CHECK_ARG(env, data);
    memcpy(buffer->Data(), data, length);
  }

  v8::Local<v8::Uint8Array> array = v8::Uint8Array::New(buffer, 0, length);

  if (result_data != nullptr) {
    *result_data = buffer->Data();
  }

  *result = v8impl::JsValueFromV8LocalValue(array);
  return GET_RETURN_STATUS(env);
}

napi_status NAPI_CDECL
napi_create_external_buffer(napi_env env,
                            size_t length,
                            void* data,
                            node_api_basic_finalize finalize_cb,
                            void* finalize_hint,
                            napi_value* result) {
  NAPI_PREAMBLE(env);
  CHECK_ARG(env, result);

  struct FinalizerData {
    v8::Isolate* isolate;
    napi_env env;
    napi_finalize cb;
    void* hint;
  };
  // Nothing keeps the env alive for the backing store, and V8 also runs
  // deleters while disposing the isolate — past the point where the env was
  // destroyed. Dropping the callback there leaks the addon's data, which beats
  // calling through a dangling env.
  auto deleter = [](void* external_data, size_t, void* deleter_data) {
    std::unique_ptr<FinalizerData> fd(
        static_cast<FinalizerData*>(deleter_data));
    if (fd == nullptr || !tns::Runtime::IsAlive(fd->isolate) ||
        tns::NapiEnv::ForIsolate(fd->isolate) != fd->env) {
      return;
    }

    fd->env->CallFinalizer(fd->cb, external_data, fd->hint);
  };

  FinalizerData* deleter_data = nullptr;
  if (finalize_cb != nullptr) {
    deleter_data =
        new FinalizerData{env->isolate, env,
                          reinterpret_cast<napi_finalize>(finalize_cb),
                          finalize_hint};
  }

  std::unique_ptr<v8::BackingStore> backing_store =
      v8::ArrayBuffer::NewBackingStore(
          data, length, deleter, reinterpret_cast<void*>(deleter_data));
  CHECK(!!backing_store);  // Cannot fail.

  v8::Local<v8::ArrayBuffer> buffer =
      v8::ArrayBuffer::New(env->isolate, std::move(backing_store));
  v8::Local<v8::Uint8Array> array = v8::Uint8Array::New(buffer, 0, length);

  *result = v8impl::JsValueFromV8LocalValue(array);
  return GET_RETURN_STATUS(env);
}

napi_status NAPI_CDECL
node_api_create_buffer_from_arraybuffer(napi_env env,
                                        napi_value arraybuffer,
                                        size_t byte_offset,
                                        size_t byte_length,
                                        napi_value* result) {
  NAPI_PREAMBLE(env);
  CHECK_ARG(env, arraybuffer);
  CHECK_ARG(env, result);

  v8::Local<v8::Value> value = v8impl::V8LocalValueFromJsValue(arraybuffer);
  RETURN_STATUS_IF_FALSE(env, value->IsArrayBuffer(), napi_invalid_arg);

  v8::Local<v8::ArrayBuffer> buffer = value.As<v8::ArrayBuffer>();
  THROW_RANGE_ERROR_IF_FALSE(
      env,
      byte_offset <= buffer->ByteLength() &&
          byte_length <= buffer->ByteLength() - byte_offset,
      "ERR_OUT_OF_RANGE",
      "The byte offset + length is out of range");

  v8::Local<v8::Uint8Array> array =
      v8::Uint8Array::New(buffer, byte_offset, byte_length);

  *result = v8impl::JsValueFromV8LocalValue(array);
  return GET_RETURN_STATUS(env);
}

napi_status NAPI_CDECL napi_is_buffer(napi_env env,
                                      napi_value value,
                                      bool* result) {
  CHECK_ENV_NOT_IN_GC(env);
  CHECK_ARG(env, value);
  CHECK_ARG(env, result);

  v8::Local<v8::Value> val = v8impl::V8LocalValueFromJsValue(value);
  *result = val->IsUint8Array();

  return napi_clear_last_error(env);
}

napi_status NAPI_CDECL napi_get_buffer_info(napi_env env,
                                            napi_value value,
                                            void** data,
                                            size_t* length) {
  CHECK_ENV_NOT_IN_GC(env);
  CHECK_ARG(env, value);

  v8::Local<v8::Value> val = v8impl::V8LocalValueFromJsValue(value);
  RETURN_STATUS_IF_FALSE(env, val->IsUint8Array(), napi_invalid_arg);

  v8::Local<v8::Uint8Array> array = val.As<v8::Uint8Array>();

  if (data != nullptr) {
    // Calling Buffer() may have the side effect of allocating the buffer,
    // so only do this when it's needed.
    *data = static_cast<uint8_t*>(array->Buffer()->Data()) +
            array->ByteOffset();
  }

  if (length != nullptr) {
    *length = array->ByteLength();
  }

  return napi_clear_last_error(env);
}

//=== Async contexts and callback scopes ===================================
//
// There is no async_hooks here, so an async context is an opaque token that
// keeps its resource objects alive for as long as the addon holds it, and a
// callback scope is the depth counter the vendored sources balance against.

struct napi_async_context__ {
  napi_env env = nullptr;
  napi_ref resource = nullptr;
};

struct napi_callback_scope__ {
  napi_env env = nullptr;
};

napi_status NAPI_CDECL napi_async_init(napi_env env,
                                       napi_value async_resource,
                                       napi_value async_resource_name,
                                       napi_async_context* result) {
  CHECK_ENV(env);
  CHECK_ARG(env, async_resource_name);
  CHECK_ARG(env, result);

  std::unique_ptr<napi_async_context__> context(new napi_async_context__());
  context->env = env;

  if (async_resource != nullptr) {
    STATUS_CALL(
        napi_create_reference(env, async_resource, 1, &context->resource));
  }
  // The name only feeds async_hooks, which don't exist here — and referencing
  // it would fail anyway: a string ref needs module API version >= 10 and envs
  // default to 8.

  *result = context.release();
  return napi_clear_last_error(env);
}

napi_status NAPI_CDECL napi_async_destroy(napi_env env,
                                          napi_async_context async_context) {
  CHECK_ENV(env);
  CHECK_ARG(env, async_context);
  RETURN_STATUS_IF_FALSE(env, async_context->env == env, napi_invalid_arg);

  if (async_context->resource != nullptr) {
    napi_delete_reference(env, async_context->resource);
  }
  delete async_context;

  return napi_clear_last_error(env);
}

napi_status NAPI_CDECL napi_open_callback_scope(napi_env env,
                                                napi_value resource_object,
                                                napi_async_context context,
                                                napi_callback_scope* result) {
  CHECK_ENV(env);
  CHECK_ARG(env, result);

  // Both only matter to async_hooks listeners, which do not exist here.
  (void)resource_object;
  (void)context;

  napi_callback_scope__* scope = new napi_callback_scope__();
  scope->env = env;
  env->open_callback_scopes++;

  *result = scope;
  return napi_clear_last_error(env);
}

napi_status NAPI_CDECL napi_close_callback_scope(napi_env env,
                                                 napi_callback_scope scope) {
  CHECK_ENV(env);
  CHECK_ARG(env, scope);
  RETURN_STATUS_IF_FALSE(env, scope->env == env, napi_callback_scope_mismatch);
  RETURN_STATUS_IF_FALSE(env, env->open_callback_scopes > 0,
                         napi_callback_scope_mismatch);

  env->open_callback_scopes--;
  delete scope;

  return napi_clear_last_error(env);
}

napi_status NAPI_CDECL napi_make_callback(napi_env env,
                                          napi_async_context async_context,
                                          napi_value recv,
                                          napi_value func,
                                          size_t argc,
                                          const napi_value* argv,
                                          napi_value* result) {
  NAPI_PREAMBLE(env);
  CHECK_ARG(env, recv);
  if (argc > 0) {
    CHECK_ARG(env, argv);
  }

  // Entering the isolate is only ever legal from the thread that owns it;
  // reaching JS from anywhere else is what threadsafe functions are for.
  RETURN_STATUS_IF_FALSE(
      env,
      CFRunLoopGetCurrent() == static_cast<tns::NapiEnv*>(env)->RuntimeLoop(),
      napi_generic_failure);

  (void)async_context;

  v8::Local<v8::Context> context = env->context();

  v8::Local<v8::Object> v8recv;
  CHECK_TO_OBJECT(env, context, v8recv, recv);

  v8::Local<v8::Function> v8func;
  CHECK_TO_FUNCTION(env, v8func, func);

  env->open_callback_scopes++;
  v8::MaybeLocal<v8::Value> callback_result = v8func->Call(
      context, v8recv, static_cast<int>(argc),
      reinterpret_cast<v8::Local<v8::Value>*>(const_cast<napi_value*>(argv)));
  env->open_callback_scopes--;

  // Node drains microtasks as the outermost callback scope closes; this
  // isolate is left on V8's automatic policy, which already does that when the
  // call returns to native code.

  if (try_catch.HasCaught()) {
    return napi_set_last_error(env, napi_pending_exception);
  }

  CHECK_MAYBE_EMPTY(env, callback_result, napi_generic_failure);
  if (result != nullptr) {
    *result = v8impl::JsValueFromV8LocalValue(callback_result.ToLocalChecked());
  }

  return GET_RETURN_STATUS(env);
}

//=== Async work ===========================================================

struct napi_async_work__ {
  enum class State { idle, queued, executing, completed };

  ~napi_async_work__() {
    if (loop != nullptr) {
      CFRelease(loop);
    }
  }

  tns::NapiEnv* env = nullptr;
  v8::Isolate* isolate = nullptr;
  // Retained: the execute callback can outlive the thread that owns the loop,
  // and posting the completion to a deallocated one is fatal.
  CFRunLoopRef loop = nullptr;
  napi_async_execute_callback execute = nullptr;
  napi_async_complete_callback complete = nullptr;
  void* data = nullptr;

  std::mutex mutex;
  State state = State::idle;
  bool cancelled = false;
};

namespace {

// The env's thread. `work` belongs to the addon, which is free to delete it
// from the complete callback, so nothing may touch it afterwards.
void CompleteAsyncWork(napi_async_work work, napi_status status) {
  v8::Isolate* isolate = work->isolate;
  tns::NapiEnv* env = work->env;
  {
    std::lock_guard<std::mutex> lock(work->mutex);
    work->state = napi_async_work__::State::completed;
  }

  // The env died while the work was in flight. The complete callback is the
  // only thing that would have freed whatever the addon hung off `data`, so
  // this drops it — the same trade Node makes at environment shutdown.
  if (!tns::Runtime::IsAlive(isolate) ||
      tns::NapiEnv::ForIsolate(isolate) != env) {
    return;
  }

  napi_async_complete_callback complete = work->complete;
  if (complete == nullptr) {
    return;
  }

  v8::Locker locker(isolate);
  v8::Isolate::Scope isolate_scope(isolate);
  v8::HandleScope handle_scope(isolate);
  v8::Context::Scope context_scope(env->context());

  void* data = work->data;
  env->CallIntoModule(
      [&](napi_env moduleEnv) { complete(moduleEnv, status, data); },
      [](napi_env moduleEnv, v8::Local<v8::Value> exception) {
        if (moduleEnv->terminatedOrTerminating()) {
          return;
        }
        tns::NativeScriptException::ReportToJsHandlersAndLog(
            moduleEnv->isolate, exception, v8::Local<v8::Message>());
      });
}

}  // namespace

napi_status NAPI_CDECL
napi_create_async_work(napi_env env,
                       napi_value async_resource,
                       napi_value async_resource_name,
                       napi_async_execute_callback execute,
                       napi_async_complete_callback complete,
                       void* data,
                       napi_async_work* result) {
  CHECK_ENV(env);
  CHECK_ARG(env, async_resource_name);
  CHECK_ARG(env, execute);
  CHECK_ARG(env, result);

  // Only async_hooks listeners would observe the resource, and there are none.
  (void)async_resource;

  tns::NapiEnv* tnsEnv = static_cast<tns::NapiEnv*>(env);
  RETURN_STATUS_IF_FALSE(env, tnsEnv->RuntimeLoop() != nullptr,
                         napi_generic_failure);

  napi_async_work__* work = new napi_async_work__();
  work->env = tnsEnv;
  work->isolate = env->isolate;
  work->loop = tnsEnv->RuntimeLoop();
  CFRetain(work->loop);
  work->execute = execute;
  work->complete = complete;
  work->data = data;

  *result = work;
  return napi_clear_last_error(env);
}

napi_status NAPI_CDECL napi_delete_async_work(napi_env env,
                                              napi_async_work work) {
  CHECK_ENV(env);
  CHECK_ARG(env, work);

  {
    // Node deletes unconditionally, which leaves the pointer the queued work
    // still holds dangling. Refusing leaks the work instead, which an addon
    // deleting straight after a cancel will notice.
    std::lock_guard<std::mutex> lock(work->mutex);
    RETURN_STATUS_IF_FALSE(env,
                           work->state == napi_async_work__::State::idle ||
                               work->state ==
                                   napi_async_work__::State::completed,
                           napi_generic_failure);
  }

  delete work;
  return napi_clear_last_error(env);
}

napi_status NAPI_CDECL napi_queue_async_work(node_api_basic_env basic_env,
                                             napi_async_work work) {
  CHECK_ENV(basic_env);
  CHECK_ARG(basic_env, work);

  napi_env env = const_cast<napi_env>(basic_env);
  RETURN_STATUS_IF_FALSE(env, work->env == env, napi_invalid_arg);

  {
    std::lock_guard<std::mutex> lock(work->mutex);
    RETURN_STATUS_IF_FALSE(env, work->state == napi_async_work__::State::idle ||
                                    work->state ==
                                        napi_async_work__::State::completed,
                           napi_generic_failure);
    work->state = napi_async_work__::State::queued;
    work->cancelled = false;
  }

  CFRunLoopRef loop = work->loop;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    napi_status status = napi_ok;
    {
      std::lock_guard<std::mutex> lock(work->mutex);
      if (work->cancelled) {
        status = napi_cancelled;
      } else {
        work->state = napi_async_work__::State::executing;
      }
    }

    // Off the env's thread: the execute callback may not touch the isolate,
    // which is exactly the contract Node states for it.
    if (status == napi_ok) {
      work->execute(work->env, work->data);
    }

    tns::ExecuteOnRunLoop(loop, ^{
      CompleteAsyncWork(work, status);
    });
  });

  return napi_clear_last_error(env);
}

napi_status NAPI_CDECL napi_cancel_async_work(node_api_basic_env basic_env,
                                              napi_async_work work) {
  CHECK_ENV(basic_env);
  CHECK_ARG(basic_env, work);

  napi_env env = const_cast<napi_env>(basic_env);
  RETURN_STATUS_IF_FALSE(env, work->env == env, napi_invalid_arg);

  std::lock_guard<std::mutex> lock(work->mutex);
  // Once the execute callback is running there is nothing to cancel; the same
  // mutex is what makes the answer truthful.
  RETURN_STATUS_IF_FALSE(env, work->state == napi_async_work__::State::queued,
                         napi_generic_failure);
  work->cancelled = true;

  return napi_clear_last_error(env);
}

napi_status NAPI_CDECL napi_get_uv_event_loop(node_api_basic_env env,
                                              struct uv_loop_s** loop) {
  // This runtime drives a CFRunLoop; there is no uv_loop_t to hand out, and
  // inventing one would be worse than saying so.
  CHECK_ENV(env);
  return napi_set_last_error(env, napi_generic_failure);
}

//=== Cleanup hooks ========================================================

struct napi_async_cleanup_hook_handle__ {
  napi_env env = nullptr;
  napi_async_cleanup_hook hook = nullptr;
  void* data = nullptr;
};

namespace {

// One entry per registered hook, in registration order: Node runs both kinds
// off a single list, most recently added first, and addons rely on that to
// undo their work in the reverse order they set it up.
struct CleanupEntry {
  napi_cleanup_hook hook = nullptr;
  void* arg = nullptr;
  napi_async_cleanup_hook_handle__* asyncHandle = nullptr;
};

struct CleanupRegistry {
  std::mutex mutex;
  std::unordered_map<napi_env, std::vector<CleanupEntry>> byEnv;
  // Handles outlive their env's entry, so removal can be answered without
  // reading through a `napi_env` that may already be gone.
  std::unordered_set<napi_async_cleanup_hook_handle__*> liveHandles;
};

CleanupRegistry& Cleanups() {
  static CleanupRegistry* registry = new CleanupRegistry();
  return *registry;
}

}  // namespace

napi_status NAPI_CDECL napi_add_env_cleanup_hook(node_api_basic_env basic_env,
                                                 napi_cleanup_hook fun,
                                                 void* arg) {
  CHECK_ENV(basic_env);
  CHECK_ARG(basic_env, fun);

  napi_env env = const_cast<napi_env>(basic_env);

  CleanupRegistry& registry = Cleanups();
  std::lock_guard<std::mutex> lock(registry.mutex);
  registry.byEnv[env].push_back(CleanupEntry{fun, arg, nullptr});

  return napi_clear_last_error(env);
}

napi_status NAPI_CDECL napi_remove_env_cleanup_hook(
    node_api_basic_env basic_env, napi_cleanup_hook fun, void* arg) {
  CHECK_ENV(basic_env);
  CHECK_ARG(basic_env, fun);

  napi_env env = const_cast<napi_env>(basic_env);

  CleanupRegistry& registry = Cleanups();
  std::lock_guard<std::mutex> lock(registry.mutex);
  auto it = registry.byEnv.find(env);
  if (it == registry.byEnv.end()) {
    return napi_set_last_error(env, napi_invalid_arg);
  }

  std::vector<CleanupEntry>& entries = it->second;
  auto entry = std::find_if(
      entries.rbegin(), entries.rend(), [&](const CleanupEntry& candidate) {
        return candidate.asyncHandle == nullptr && candidate.hook == fun &&
               candidate.arg == arg;
      });
  if (entry == entries.rend()) {
    return napi_set_last_error(env, napi_invalid_arg);
  }

  entries.erase(std::next(entry).base());
  return napi_clear_last_error(env);
}

napi_status NAPI_CDECL
napi_add_async_cleanup_hook(node_api_basic_env basic_env,
                            napi_async_cleanup_hook hook,
                            void* arg,
                            napi_async_cleanup_hook_handle* remove_handle) {
  CHECK_ENV(basic_env);
  CHECK_ARG(basic_env, hook);

  napi_env env = const_cast<napi_env>(basic_env);

  napi_async_cleanup_hook_handle__* handle =
      new napi_async_cleanup_hook_handle__();
  handle->env = env;
  handle->hook = hook;
  handle->data = arg;

  {
    CleanupRegistry& registry = Cleanups();
    std::lock_guard<std::mutex> lock(registry.mutex);
    registry.byEnv[env].push_back(CleanupEntry{nullptr, nullptr, handle});
    registry.liveHandles.insert(handle);
  }

  if (remove_handle != nullptr) {
    *remove_handle = handle;
  }

  return napi_clear_last_error(env);
}

napi_status NAPI_CDECL napi_remove_async_cleanup_hook(
    napi_async_cleanup_hook_handle remove_handle) {
  if (remove_handle == nullptr) {
    return napi_invalid_arg;
  }

  CleanupRegistry& registry = Cleanups();
  {
    std::lock_guard<std::mutex> lock(registry.mutex);
    if (registry.liveHandles.erase(remove_handle) == 0) {
      return napi_invalid_arg;
    }

    auto it = registry.byEnv.find(remove_handle->env);
    if (it != registry.byEnv.end()) {
      std::vector<CleanupEntry>& entries = it->second;
      entries.erase(std::remove_if(entries.begin(), entries.end(),
                                   [&](const CleanupEntry& candidate) {
                                     return candidate.asyncHandle ==
                                            remove_handle;
                                   }),
                    entries.end());
    }
  }

  delete remove_handle;
  return napi_ok;
}

namespace tns {

void NapiRunEnvCleanupHooks(NapiEnv* env) {
  CleanupRegistry& registry = Cleanups();

  // A hook reaches back into Node-API through an env it stashed away, and
  // teardown holds the isolate's lock but opens no scopes of its own. Note
  // that execution is already terminating by then: a hook can still release
  // env-bound resources, but nothing it does will reach JS.
  v8::HandleScope handle_scope(env->isolate);
  v8::Context::Scope context_scope(env->context());

  // Hooks add and remove other hooks as they run, so each round is taken from
  // the live list rather than a snapshot — one that dropped an entry would
  // call through a hook another hook already deleted.
  for (;;) {
    CleanupEntry entry;
    {
      std::lock_guard<std::mutex> lock(registry.mutex);
      auto it = registry.byEnv.find(env);
      if (it == registry.byEnv.end()) {
        return;
      }

      std::vector<CleanupEntry>& entries = it->second;
      if (entries.empty()) {
        registry.byEnv.erase(it);
        return;
      }

      entry = entries.back();
      entries.pop_back();
    }

    if (entry.asyncHandle == nullptr) {
      entry.hook(entry.arg);
      continue;
    }

    // Node waits for every async hook to report back through
    // napi_remove_async_cleanup_hook before the env goes away. Nothing can
    // wait here: the thread running this teardown is the one that would have
    // to run the completion, so a hook that defers is simply not awaited. Its
    // handle stays live so a late removal is still safe, and it can no longer
    // reach JS.
    entry.asyncHandle->hook(entry.asyncHandle, entry.asyncHandle->data);
  }
}

}  // namespace tns

//=== Not implemented ======================================================

napi_status NAPI_CDECL node_api_get_module_file_name(node_api_basic_env env,
                                                     const char** result) {
  // Addons are linked into the app binary rather than loaded from a file, and
  // nothing identifies the calling module at this point.
  CHECK_ENV(env);
  return napi_set_last_error(env, napi_generic_failure);
}
