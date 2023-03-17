#ifndef JsV8InspectorClient_h
#define JsV8InspectorClient_h

#include <functional>
#include <dispatch/dispatch.h>
#include <string>
#include <vector>
#include <map>

#include "include/v8-inspector.h"
#include "src/inspector/v8-console-message.h"

#include "runtime/Runtime.h"

namespace v8_inspector {

class JsV8InspectorClient : V8InspectorClient, V8Inspector::Channel {
public:
    JsV8InspectorClient(tns::Runtime* runtime);
    void init();
    void connect(int argc, char** argv);
    void disconnect();
    void dispatchMessage(const std::string& message);

    // Overrides of V8Inspector::Channel
    void sendResponse(int callId, std::unique_ptr<StringBuffer> message) override;
    void sendNotification(std::unique_ptr<StringBuffer> message) override;
    void flushProtocolNotifications() override;

    // Overrides of V8InspectorClient
    void runMessageLoopOnPause(int contextGroupId) override;
    void quitMessageLoopOnPause() override;

    void scheduleBreak();
    void registerModules();

    void consoleLog(v8::Isolate* isolate, ConsoleAPIType method,
                    const std::vector<v8::Local<v8::Value>>& args);
    
    static std::map<std::string, v8::Persistent<v8::Object>*> Domains;
private:
    static constexpr int contextGroupId = 1;

    bool isConnected_;
    std::unique_ptr<V8Inspector> inspector_;
    v8::Persistent<v8::Context> context_;
    std::unique_ptr<V8InspectorSession> session_;
    tns::Runtime* runtime_;
    bool terminated_;
    std::vector<std::string> messages_;
    bool runningNestedLoops_;
    dispatch_queue_t messagesQueue_;
    dispatch_queue_t messageLoopQueue_;
    dispatch_semaphore_t messageArrived_;
    std::function<void (std::string)> sender_;
    bool isWaitingForDebugger_;

    // Override of V8InspectorClient
    v8::Local<v8::Context> ensureDefaultContextInGroup(int contextGroupId) override;

    void enableInspector(int argc, char** argv);
    void createInspectorSession();
    void notify(std::unique_ptr<StringBuffer> message);
    void onFrontendConnected(std::function<void (std::string)> sender);
    void onFrontendMessageReceived(std::string message);
    std::string PumpMessage();
    static void registerDomainDispatcherCallback(const v8::FunctionCallbackInfo<v8::Value>& args);
    static void inspectorSendEventCallback(const v8::FunctionCallbackInfo<v8::Value>& args);
    static void inspectorTimestampCallback(const v8::FunctionCallbackInfo<v8::Value>& args);
};

}

#endif /* JsV8InspectorClient_h */
