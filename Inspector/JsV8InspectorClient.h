#ifndef JsV8InspectorClient_h
#define JsV8InspectorClient_h

#include "include/v8-inspector.h"
#include <vector>

namespace v8_inspector {

std::string ToStdString(const v8_inspector::StringView& value);
std::vector<uint16_t> ToVector(const std::string& value);

class JsV8InspectorClient : public v8_inspector::V8InspectorClient, public v8_inspector::V8Inspector::Channel {
public:
    JsV8InspectorClient(v8::Isolate* isolate);
    void init();
    void connect();
    void createInspectorSession(v8::Isolate* isolate, const v8::Local<v8::Context>& context);
    void disconnect();
    void dispatchMessage(const std::string& message);

    void sendResponse(int callId, std::unique_ptr<StringBuffer> message) override;
    void sendNotification(std::unique_ptr<StringBuffer> message) override;
    void flushProtocolNotifications() override;

    void runMessageLoopOnPause(int context_group_id) override;
    void quitMessageLoopOnPause() override;
    v8::Local<v8::Context> ensureDefaultContextInGroup(int contextGroupId) override;
private:
    static int contextGroupId;
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
};

}

#endif /* JsV8InspectorClient_h */
