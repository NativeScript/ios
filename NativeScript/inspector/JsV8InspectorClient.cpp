#include <stdio.h>
#include "JsV8InspectorClient.h"
#include "src/inspector/v8-inspector-session-impl.h"
#include "Helpers.h"

using namespace v8;

namespace v8_inspector {

void JsV8InspectorClient::inspectorSendEventCallback(const FunctionCallbackInfo<Value>& args) {
    Local<External> data = args.Data().As<External>();
    v8_inspector::JsV8InspectorClient* client = static_cast<v8_inspector::JsV8InspectorClient*>(data->Value());
    Isolate* isolate = args.GetIsolate();
    Local<v8::String> arg = args[0].As<v8::String>();
    std::string message = tns::ToString(isolate, arg);

    if (message.find("\"Network.") != std::string::npos) {
        // The Network domain is handled directly by the corresponding backend
        V8InspectorSessionImpl* session = (V8InspectorSessionImpl*)client->session_.get();
        session->networkArgent()->dispatch(message);
        return;
    }

    if (message.find("\"DOM.") != std::string::npos) {
        // The DOM domain is handled directly by the corresponding backend
        V8InspectorSessionImpl* session = (V8InspectorSessionImpl*)client->session_.get();
        session->domArgent()->dispatch(message);
        return;
    }

    client->dispatchMessage(message);
}

}
