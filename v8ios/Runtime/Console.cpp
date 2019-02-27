#include "Console.h"

namespace tns {

void Console::Init(Isolate* isolate) {
    Local<Context> context = isolate->GetCurrentContext();
    Context::Scope context_scope(context);
    Local<Object> console = Object::New(isolate);
    bool success = console->SetPrototype(context, Object::New(isolate)).FromMaybe(false);
    assert(success);

    Local<Function> func;
    if (!Function::New(context, LogCallback, console, 0, ConstructorBehavior::kThrow).ToLocal(&func)) {
        return;
    }

    Local<String> logFuncName = String::NewFromUtf8(isolate, "log");
    func->SetName(logFuncName);
    if (!console->CreateDataProperty(context, logFuncName, func).FromMaybe(false)) {
        assert(false);
    }

    Local<Object> global = context->Global();
    PropertyAttribute readOnlyFlags = static_cast<PropertyAttribute>(PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
    if (!global->DefineOwnProperty(context, String::NewFromUtf8(isolate, "console"), console, readOnlyFlags).FromMaybe(false)) {
        assert(false);
    }
}

void Console::LogCallback(const FunctionCallbackInfo<Value>& args) {
    Local<Value> value = args[0];
    Isolate* isolate = args.GetIsolate();
    String::Utf8Value str(isolate, value);
    printf("%s", *str);
}

}
