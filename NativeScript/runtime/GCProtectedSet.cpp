#include "GCProtectedSet.h"

#include "Caches.h"
#include "Helpers.h"
#include "Runtime.h"

namespace tns {

using namespace v8;

void GCProtectedSet::Init(v8::Local<v8::Context> context) {
    Isolate* isolate = context->GetIsolate();
    auto cache = Caches::Get(isolate);

    Local<Object> global = context->Global();

    auto* wrapper = MakeGarbageCollected<GCProtectedSet>(isolate);
    Local<Object> gcProtected = CreateWrapperFor(isolate, wrapper);

    Local<Private> globalName = Private::ForApi(isolate, v8::String::NewFromUtf8Literal(isolate, "GCProtectedSet"));

    global->SetPrivate(context, globalName, gcProtected).Check();
}

void GCProtectedSet::Trace(cppgc::Visitor* visitor) const {
    auto cache = Caches::Get(isolate_);

    cache->TraceGCProtectedWrappers(visitor);
}

}
