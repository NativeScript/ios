#include "Common.h"
#include "Caches.h"

namespace tns {
    // static
    v8::Local<v8::Object> CommonPrivate::CreateExtensibleWrapperObject(v8::Isolate* isolate, v8::Local<v8::Context> context)
    {
        return Caches::Get(isolate)->WrapperObjectTemplate.Get(isolate)->NewInstance(context).ToLocalChecked();
    }
}
