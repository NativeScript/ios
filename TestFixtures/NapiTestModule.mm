#include <stdlib.h>
#include <string.h>

#include "napi/vendor/node_api.h"

// A failed call leaves either a pending JS exception or only an extended error
// info record; JS must see a throw either way.
static void NapiThrowLastError(napi_env env) {
  bool pending = false;
  if (napi_is_exception_pending(env, &pending) == napi_ok && pending) {
    return;
  }

  const napi_extended_error_info* info = NULL;
  napi_get_last_error_info(env, &info);
  napi_throw_error(
      env, NULL,
      (info != NULL && info->error_message != NULL) ? info->error_message : "napi call failed");
}

#define NAPI_CALL(env, call)   \
  do {                         \
    if ((call) != napi_ok) {   \
      NapiThrowLastError(env); \
      return NULL;             \
    }                          \
  } while (0)

#define NAPI_METHOD(name, fn) {(name), NULL, (fn), NULL, NULL, NULL, napi_default, NULL}
#define NAPI_GETTER(name, fn) {(name), NULL, NULL, (fn), NULL, NULL, napi_enumerable, NULL}
#define NAPI_VALUE(name, val) {(name), NULL, NULL, NULL, NULL, (val), napi_enumerable, NULL}

typedef struct {
  double value;
} NapiTestPayload;

static int sFinalizerRuns = 0;
static int sWrapCount = 0;
static napi_ref sHeldRef = NULL;

static napi_value EchoString(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  NAPI_CALL(env, napi_get_cb_info(env, info, &argc, args, NULL, NULL));

  size_t length = 0;
  NAPI_CALL(env, napi_get_value_string_utf8(env, args[0], NULL, 0, &length));

  char* buffer = (char*)malloc(length + 1);
  if (buffer == NULL) {
    napi_throw_error(env, NULL, "out of memory");
    return NULL;
  }

  napi_value result = NULL;
  napi_status status = napi_get_value_string_utf8(env, args[0], buffer, length + 1, &length);
  if (status == napi_ok) {
    status = napi_create_string_utf8(env, buffer, length, &result);
  }
  free(buffer);

  if (status != napi_ok) {
    NapiThrowLastError(env);
    return NULL;
  }

  return result;
}

static napi_value DoubleNumber(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  NAPI_CALL(env, napi_get_cb_info(env, info, &argc, args, NULL, NULL));

  double value = 0;
  NAPI_CALL(env, napi_get_value_double(env, args[0], &value));

  napi_value result = NULL;
  NAPI_CALL(env, napi_create_double(env, value * 2, &result));
  return result;
}

static napi_value NegateBool(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  NAPI_CALL(env, napi_get_cb_info(env, info, &argc, args, NULL, NULL));

  bool value = false;
  NAPI_CALL(env, napi_get_value_bool(env, args[0], &value));

  napi_value result = NULL;
  NAPI_CALL(env, napi_get_boolean(env, !value, &result));
  return result;
}

static napi_value TransformObject(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  NAPI_CALL(env, napi_get_cb_info(env, info, &argc, args, NULL, NULL));

  napi_value input = NULL;
  NAPI_CALL(env, napi_get_named_property(env, args[0], "value", &input));

  double value = 0;
  NAPI_CALL(env, napi_get_value_double(env, input, &value));

  napi_value doubled = NULL;
  NAPI_CALL(env, napi_create_double(env, value * 2, &doubled));

  napi_value tag = NULL;
  NAPI_CALL(env, napi_create_string_utf8(env, "napi", NAPI_AUTO_LENGTH, &tag));

  napi_value result = NULL;
  NAPI_CALL(env, napi_create_object(env, &result));
  NAPI_CALL(env, napi_set_named_property(env, result, "value", doubled));
  NAPI_CALL(env, napi_set_named_property(env, result, "tag", tag));
  return result;
}

static napi_value TransformArray(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  NAPI_CALL(env, napi_get_cb_info(env, info, &argc, args, NULL, NULL));

  uint32_t length = 0;
  NAPI_CALL(env, napi_get_array_length(env, args[0], &length));

  napi_value first = NULL;
  double firstValue = 0;
  if (length > 0) {
    NAPI_CALL(env, napi_get_element(env, args[0], 0, &first));
    NAPI_CALL(env, napi_get_value_double(env, first, &firstValue));
  }

  napi_value result = NULL;
  NAPI_CALL(env, napi_create_array_with_length(env, 2, &result));

  napi_value lengthValue = NULL;
  NAPI_CALL(env, napi_create_double(env, (double)length, &lengthValue));
  NAPI_CALL(env, napi_set_element(env, result, 0, lengthValue));

  napi_value firstOut = NULL;
  NAPI_CALL(env, napi_create_double(env, firstValue, &firstOut));
  NAPI_CALL(env, napi_set_element(env, result, 1, firstOut));
  return result;
}

static napi_value ThrowError(napi_env env, napi_callback_info info) {
  (void)info;
  napi_throw_error(env, "ERR_TEST_CODE", "napi test failure");
  return NULL;
}

static void FinalizePayload(napi_env env, void* data, void* hint) {
  (void)env;
  (void)hint;
  free(data);
  sFinalizerRuns++;
}

static napi_value WrapValue(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  NAPI_CALL(env, napi_get_cb_info(env, info, &argc, args, NULL, NULL));

  double value = 0;
  NAPI_CALL(env, napi_get_value_double(env, args[1], &value));

  NapiTestPayload* payload = (NapiTestPayload*)malloc(sizeof(NapiTestPayload));
  if (payload == NULL) {
    napi_throw_error(env, NULL, "out of memory");
    return NULL;
  }
  payload->value = value;

  napi_status status = napi_wrap(env, args[0], payload, FinalizePayload, NULL, NULL);
  if (status != napi_ok) {
    free(payload);
    NapiThrowLastError(env);
    return NULL;
  }

  sWrapCount++;
  return args[0];
}

static napi_value UnwrapValue(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  NAPI_CALL(env, napi_get_cb_info(env, info, &argc, args, NULL, NULL));

  void* payload = NULL;
  NAPI_CALL(env, napi_unwrap(env, args[0], &payload));

  napi_value result = NULL;
  NAPI_CALL(env, napi_create_double(env, ((NapiTestPayload*)payload)->value, &result));
  return result;
}

static napi_value FinalizerRan(napi_env env, napi_callback_info info) {
  (void)info;
  napi_value result = NULL;
  NAPI_CALL(env, napi_get_boolean(env, sFinalizerRuns > 0, &result));
  return result;
}

static napi_value ResetFinalizerFlag(napi_env env, napi_callback_info info) {
  (void)info;
  sFinalizerRuns = 0;

  napi_value result = NULL;
  NAPI_CALL(env, napi_get_undefined(env, &result));
  return result;
}

static napi_value HoldRef(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  NAPI_CALL(env, napi_get_cb_info(env, info, &argc, args, NULL, NULL));

  if (sHeldRef != NULL) {
    napi_delete_reference(env, sHeldRef);
    sHeldRef = NULL;
  }
  NAPI_CALL(env, napi_create_reference(env, args[0], 1, &sHeldRef));

  napi_value result = NULL;
  NAPI_CALL(env, napi_get_undefined(env, &result));
  return result;
}

static napi_value GetRef(napi_env env, napi_callback_info info) {
  (void)info;
  napi_value result = NULL;
  if (sHeldRef != NULL) {
    NAPI_CALL(env, napi_get_reference_value(env, sHeldRef, &result));
  }

  // A weak or already-collected reference yields NULL rather than an error.
  if (result == NULL) {
    NAPI_CALL(env, napi_get_undefined(env, &result));
  }
  return result;
}

static napi_value ReleaseRef(napi_env env, napi_callback_info info) {
  (void)info;
  bool released = false;
  if (sHeldRef != NULL) {
    NAPI_CALL(env, napi_delete_reference(env, sHeldRef));
    sHeldRef = NULL;
    released = true;
  }

  napi_value result = NULL;
  NAPI_CALL(env, napi_get_boolean(env, released, &result));
  return result;
}

static napi_value GetWrapCount(napi_env env, napi_callback_info info) {
  (void)info;
  napi_value result = NULL;
  NAPI_CALL(env, napi_create_double(env, (double)sWrapCount, &result));
  return result;
}

static napi_value InitNapiTestModule(napi_env env, napi_value exports) {
  napi_value moduleName = NULL;
  NAPI_CALL(env, napi_create_string_utf8(env, "napitestmodule", NAPI_AUTO_LENGTH, &moduleName));

  napi_property_descriptor properties[] = {
      NAPI_METHOD("echoString", EchoString),
      NAPI_METHOD("doubleNumber", DoubleNumber),
      NAPI_METHOD("negateBool", NegateBool),
      NAPI_METHOD("transformObject", TransformObject),
      NAPI_METHOD("transformArray", TransformArray),
      NAPI_METHOD("throwError", ThrowError),
      NAPI_METHOD("wrapValue", WrapValue),
      NAPI_METHOD("unwrapValue", UnwrapValue),
      NAPI_METHOD("finalizerRan", FinalizerRan),
      NAPI_METHOD("resetFinalizerFlag", ResetFinalizerFlag),
      NAPI_METHOD("holdRef", HoldRef),
      NAPI_METHOD("getRef", GetRef),
      NAPI_METHOD("releaseRef", ReleaseRef),
      NAPI_GETTER("wrapCount", GetWrapCount),
      NAPI_VALUE("moduleName", moduleName),
  };

  NAPI_CALL(env, napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]),
                                        properties));
  return exports;
}

// A statically linked addon cannot use NAPI_MODULE_INIT: the generated symbol
// carries no name and only one can exist per image.
static napi_module sNapiTestModule = {
    NAPI_MODULE_VERSION, 0, __FILE__, InitNapiTestModule, "napitestmodule", NULL, {0},
};

__attribute__((constructor)) static void RegisterNapiTestModule(void) {
  napi_module_register(&sNapiTestModule);
}
