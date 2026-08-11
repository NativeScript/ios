// The embedder half of Node-API: everything node_api.h declares that the
// vendored js_native_api_v8.cc does not implement. Upstream this is
// src/node_api.cc, which is bound to node::Environment and libuv and so cannot
// be vendored.

// Must precede every include: without NAPI_EXPERIMENTAL, NAPI_VERSION defaults
// to 8 and the version-gated declarations in node_api.h stay invisible, so the
// definitions below would silently not match anything.
#define NAPI_EXPERIMENTAL
#define NODE_API_EXPERIMENTAL_NO_WARNING

#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

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

//=== Phase 2 ==============================================================
// Async work, callback scopes, threadsafe functions, cleanup hooks and the
// module file name are not implemented yet.

napi_status NAPI_CDECL napi_async_init(napi_env env,
                                       napi_value async_resource,
                                       napi_value async_resource_name,
                                       napi_async_context* result) {
  CHECK_ENV(env);
  return napi_set_last_error(env, napi_generic_failure);
}

napi_status NAPI_CDECL napi_async_destroy(napi_env env,
                                          napi_async_context async_context) {
  CHECK_ENV(env);
  return napi_set_last_error(env, napi_generic_failure);
}

napi_status NAPI_CDECL napi_make_callback(napi_env env,
                                          napi_async_context async_context,
                                          napi_value recv,
                                          napi_value func,
                                          size_t argc,
                                          const napi_value* argv,
                                          napi_value* result) {
  CHECK_ENV(env);
  return napi_set_last_error(env, napi_generic_failure);
}

napi_status NAPI_CDECL
napi_create_async_work(napi_env env,
                       napi_value async_resource,
                       napi_value async_resource_name,
                       napi_async_execute_callback execute,
                       napi_async_complete_callback complete,
                       void* data,
                       napi_async_work* result) {
  CHECK_ENV(env);
  return napi_set_last_error(env, napi_generic_failure);
}

napi_status NAPI_CDECL napi_delete_async_work(napi_env env,
                                              napi_async_work work) {
  CHECK_ENV(env);
  return napi_set_last_error(env, napi_generic_failure);
}

napi_status NAPI_CDECL napi_queue_async_work(node_api_basic_env env,
                                             napi_async_work work) {
  CHECK_ENV(env);
  return napi_set_last_error(env, napi_generic_failure);
}

napi_status NAPI_CDECL napi_cancel_async_work(node_api_basic_env env,
                                              napi_async_work work) {
  CHECK_ENV(env);
  return napi_set_last_error(env, napi_generic_failure);
}

napi_status NAPI_CDECL napi_get_uv_event_loop(node_api_basic_env env,
                                              struct uv_loop_s** loop) {
  CHECK_ENV(env);
  return napi_set_last_error(env, napi_generic_failure);
}

napi_status NAPI_CDECL napi_add_env_cleanup_hook(node_api_basic_env env,
                                                 napi_cleanup_hook fun,
                                                 void* arg) {
  CHECK_ENV(env);
  return napi_set_last_error(env, napi_generic_failure);
}

napi_status NAPI_CDECL napi_remove_env_cleanup_hook(node_api_basic_env env,
                                                    napi_cleanup_hook fun,
                                                    void* arg) {
  CHECK_ENV(env);
  return napi_set_last_error(env, napi_generic_failure);
}

napi_status NAPI_CDECL napi_open_callback_scope(napi_env env,
                                                napi_value resource_object,
                                                napi_async_context context,
                                                napi_callback_scope* result) {
  CHECK_ENV(env);
  return napi_set_last_error(env, napi_generic_failure);
}

napi_status NAPI_CDECL napi_close_callback_scope(napi_env env,
                                                 napi_callback_scope scope) {
  CHECK_ENV(env);
  return napi_set_last_error(env, napi_generic_failure);
}

napi_status NAPI_CDECL
napi_create_threadsafe_function(napi_env env,
                                napi_value func,
                                napi_value async_resource,
                                napi_value async_resource_name,
                                size_t max_queue_size,
                                size_t initial_thread_count,
                                void* thread_finalize_data,
                                napi_finalize thread_finalize_cb,
                                void* context,
                                napi_threadsafe_function_call_js call_js_cb,
                                napi_threadsafe_function* result) {
  CHECK_ENV(env);
  return napi_set_last_error(env, napi_generic_failure);
}

napi_status NAPI_CDECL napi_get_threadsafe_function_context(
    napi_threadsafe_function func, void** result) {
  return napi_generic_failure;
}

napi_status NAPI_CDECL
napi_call_threadsafe_function(napi_threadsafe_function func,
                              void* data,
                              napi_threadsafe_function_call_mode is_blocking) {
  return napi_generic_failure;
}

napi_status NAPI_CDECL
napi_acquire_threadsafe_function(napi_threadsafe_function func) {
  return napi_generic_failure;
}

napi_status NAPI_CDECL napi_release_threadsafe_function(
    napi_threadsafe_function func, napi_threadsafe_function_release_mode mode) {
  return napi_generic_failure;
}

napi_status NAPI_CDECL napi_unref_threadsafe_function(
    node_api_basic_env env, napi_threadsafe_function func) {
  CHECK_ENV(env);
  return napi_set_last_error(env, napi_generic_failure);
}

napi_status NAPI_CDECL napi_ref_threadsafe_function(
    node_api_basic_env env, napi_threadsafe_function func) {
  CHECK_ENV(env);
  return napi_set_last_error(env, napi_generic_failure);
}

napi_status NAPI_CDECL
napi_add_async_cleanup_hook(node_api_basic_env env,
                            napi_async_cleanup_hook hook,
                            void* arg,
                            napi_async_cleanup_hook_handle* remove_handle) {
  CHECK_ENV(env);
  return napi_set_last_error(env, napi_generic_failure);
}

napi_status NAPI_CDECL napi_remove_async_cleanup_hook(
    napi_async_cleanup_hook_handle remove_handle) {
  return napi_generic_failure;
}

napi_status NAPI_CDECL node_api_get_module_file_name(node_api_basic_env env,
                                                     const char** result) {
  CHECK_ENV(env);
  return napi_set_last_error(env, napi_generic_failure);
}
