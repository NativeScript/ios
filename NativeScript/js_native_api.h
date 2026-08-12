// Stable alias so addons can write #include <NativeScript/js_native_api.h>
// without depending on the vendored layout. Addons aiming for source
// compatibility with Node/napi-ios should prefer a bare
// #include <js_native_api.h> with Headers/napi/vendor on the header search
// path (see docs/node-api.md).
#include "napi/vendor/js_native_api.h"
