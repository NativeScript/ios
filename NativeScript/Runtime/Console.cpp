#include "Console.h"
#include "Helpers.h"
#ifdef DEBUG
#include "v8-log-agent-impl.h"
#endif

using namespace v8;

namespace tns {

void Console::Init(Isolate* isolate) {
    Local<Context> context = isolate->GetCurrentContext();
    Context::Scope context_scope(context);
    Local<Object> console = Object::New(isolate);
    bool success = console->SetPrototype(context, Object::New(isolate)).FromMaybe(false);
    assert(success);

    Local<v8::Function> func;
    if (!Function::New(context, LogCallback, console, 0, ConstructorBehavior::kThrow).ToLocal(&func)) {
        return;
    }

    Local<v8::String> logFuncName = tns::ToV8String(isolate, "log");
    func->SetName(logFuncName);
    if (!console->CreateDataProperty(context, logFuncName, func).FromMaybe(false)) {
        assert(false);
    }

    Local<Object> global = context->Global();
    PropertyAttribute readOnlyFlags = static_cast<PropertyAttribute>(PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
    if (!global->DefineOwnProperty(context, tns::ToV8String(isolate, "console"), console, readOnlyFlags).FromMaybe(false)) {
        assert(false);
    }
}

void Console::LogCallback(const FunctionCallbackInfo<Value>& args) {
    Local<Value> value = args[0];
    Isolate* isolate = args.GetIsolate();
    std::string str = tns::ToString(isolate, value);
#ifdef DEBUG
    v8_inspector::V8LogAgentImpl::EntryAdded(str, "info", "", 0);
#endif
    printf("%s", str.c_str());
}

}
