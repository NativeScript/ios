#ifndef JsV8InspectorClient_h
#define JsV8InspectorClient_h

#include "include/v8-inspector.h"
#include <string>
#include <map>

namespace v8_inspector {

class JsV8InspectorClient : V8InspectorClient, V8Inspector::Channel {
public:
    JsV8InspectorClient(v8::Isolate* isolate, std::string baseDir);
    void init();
    void connect();
    void createInspectorSession();
    void disconnect();
    void dispatchMessage(const std::string& message);

    void sendResponse(int callId, std::unique_ptr<StringBuffer> message) override;
    void sendNotification(std::unique_ptr<StringBuffer> message) override;
    void flushProtocolNotifications() override;

    void runMessageLoopOnPause(int contextGroupId) override;
    void quitMessageLoopOnPause() override;
    v8::Local<v8::Context> ensureDefaultContextInGroup(int contextGroupId) override;
    void registerModules(std::function<void(v8::Isolate*, std::string)> runModule);

    static std::map<std::string, v8::Persistent<v8::Object>*> Domains;
private:
    static int contextGroupId;
    std::string baseDir_;
    bool isConnected_;
    std::unique_ptr<V8Inspector> inspector_;
    v8::Persistent<v8::Context> context_;
    std::unique_ptr<V8InspectorSession> session_;
    v8::Isolate* isolate_;
    bool terminated_;

    void enableInspector();
    void notify(std::unique_ptr<StringBuffer> message);
    template <class TypeName>
    static v8::Local<TypeName> PersistentToLocal(v8::Isolate* isolate, const v8::Persistent<TypeName>& persistent);
    static void registerDomainDispatcherCallback(const v8::FunctionCallbackInfo<v8::Value>& args);
    static void inspectorSendEventCallback(const v8::FunctionCallbackInfo<v8::Value>& args);
    static void inspectorTimestampCallback(const v8::FunctionCallbackInfo<v8::Value>& args);
};

}

#endif /* JsV8InspectorClient_h */
