#include "v8-dom-agent-impl.h"
#include "src/inspector/v8-inspector-session-impl.h"
#include "JsV8InspectorClient.h"
#include "utils.h"
#include "Helpers.h"

using namespace v8;

namespace v8_inspector {

namespace DOMAgentState {
    static const char domEnabled[] = "domEnabled";
}

V8DOMAgentImpl::V8DOMAgentImpl(V8InspectorSessionImpl* session,
                               protocol::FrontendChannel* frontendChannel,
                               protocol::DictionaryValue* state)
    : m_frontend(frontendChannel),
      m_state(state),
      m_inspector(session->inspector()),
      m_enabled(false) {
}

V8DOMAgentImpl::~V8DOMAgentImpl() { }

DispatchResponse V8DOMAgentImpl::enable() {
    if (m_enabled) {
        return DispatchResponse::OK();
    }

    m_state->setBoolean(DOMAgentState::domEnabled, true);

    m_enabled = true;

    return DispatchResponse::OK();
}

DispatchResponse V8DOMAgentImpl::disable() {
    if (!m_enabled) {
        return DispatchResponse::OK();
    }

    m_state->setBoolean(DOMAgentState::domEnabled, false);

    m_enabled = false;

    return DispatchResponse::OK();
}

DispatchResponse V8DOMAgentImpl::getContentQuads(Maybe<int> in_nodeId, Maybe<int> in_backendNodeId, Maybe<String> in_objectId, std::unique_ptr<protocol::Array<protocol::Array<double>>>* out_quads) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::getDocument(Maybe<int> in_depth, Maybe<bool> in_pierce, std::unique_ptr<protocol::DOM::Node>* out_root) {
    std::unique_ptr<protocol::DOM::Node> defaultNode = protocol::DOM::Node::create()
        .setNodeId(0)
        .setBackendNodeId(0)
        .setNodeType(9)
        .setNodeName("Frame")
        .setLocalName("Frame")
        .setNodeValue("")
        .build();

    Isolate* isolate = m_inspector->isolate();
    Local<Object> domDomainDebugger;
    Local<v8::Function> getDocumentFunc = v8_inspector::GetDebuggerFunction(isolate, "DOM", "getDocument", domDomainDebugger);
    if (getDocumentFunc.IsEmpty() || domDomainDebugger.IsEmpty()) {
        *out_root = std::move(defaultNode);
        return DispatchResponse::Error("Error getting DOM tree.");
    }

    Local<Value> args[0];
    Local<Context> context = isolate->GetCurrentContext();

    TryCatch tc(isolate);
    MaybeLocal<Value> maybeResult = getDocumentFunc->Call(context, domDomainDebugger, 0, args);
    if (tc.HasCaught()) {
        String16 error = toProtocolString(isolate, tc.Message()->Get());
        *out_root = std::move(defaultNode);
        return protocol::DispatchResponse::Error(error);
    }

    Local<Value> result;
    if (!maybeResult.ToLocal(&result) || !result->IsObject()) {
        return protocol::DispatchResponse::Error("Didn't get a proper result from getDocument call. Returning empty visual tree.");
    }

    Local<Object> resultObj = result.As<Object>();
    Local<v8::String> resultString;
    assert(v8::JSON::Stringify(context, resultObj->Get(context, tns::ToV8String(isolate, "root")).ToLocalChecked()).ToLocal(&resultString));

    String16 resultProtocolString = toProtocolString(isolate, resultString);
    std::unique_ptr<protocol::Value> resultJson = protocol::StringUtil::parseJSON(resultProtocolString);
    protocol::ErrorSupport errorSupport;
    std::unique_ptr<protocol::DOM::Node> domNode = protocol::DOM::Node::fromValue(resultJson.get(), &errorSupport);

    std::string errorSupportString = errorSupport.errors().utf8();
    if (!errorSupportString.empty()) {
        String16 errorMessage = "Error while parsing debug `DOM Node` object.";
        return DispatchResponse::Error(errorMessage);
    }

    *out_root = std::move(domNode);
    return DispatchResponse::OK();
}

DispatchResponse V8DOMAgentImpl::removeNode(int in_nodeId) {
    Isolate* isolate = m_inspector->isolate();
    Local<Object> domDomainDebugger;
    Local<v8::Function> removeNodeFunc = v8_inspector::GetDebuggerFunction(isolate, "DOM", "removeNode", domDomainDebugger);

    if (removeNodeFunc.IsEmpty() || domDomainDebugger.IsEmpty()) {
        return DispatchResponse::Error("Couldn't remove the selected DOMNode from the visual tree. \"removeNode\" function not found");
    }

    Local<Context> context = isolate->GetCurrentContext();

    Local<Object> param = Object::New(isolate);
    bool success = param->Set(context, tns::ToV8String(isolate, "nodeId"), Number::New(isolate, in_nodeId)).FromMaybe(false);
    assert(success);

    Local<Value> args[] = { param };
    Local<Value> result;
    TryCatch tc(isolate);
    assert(removeNodeFunc->Call(context, domDomainDebugger, 1, args).ToLocal(&result));

    if (tc.HasCaught() || result.IsEmpty()) {
        String16 error = toProtocolString(isolate, tc.Message()->Get());
        return DispatchResponse::Error(error);
    }

    return DispatchResponse::OK();
}

DispatchResponse V8DOMAgentImpl::setAttributeValue(int in_nodeId, const String& in_name, const String& in_value) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::setAttributesAsText(int in_nodeId, const String& in_text, Maybe<String> in_name) {
    Isolate* isolate = m_inspector->isolate();
    Local<Object> domDomainDebugger;
    Local<v8::Function> setAttributesAsTextFunc = v8_inspector::GetDebuggerFunction(isolate, "DOM", "setAttributesAsText", domDomainDebugger);

    if (setAttributesAsTextFunc.IsEmpty() || domDomainDebugger.IsEmpty()) {
        return DispatchResponse::Error("Couldn't change selected DOM node's attribute. \"setAttributesAsText\" function not found");
    }

    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> param = Object::New(isolate);
    assert(param->Set(context, tns::ToV8String(isolate, "nodeId"), Number::New(isolate, in_nodeId)).FromMaybe(false));
    assert(param->Set(context, tns::ToV8String(isolate, "text"), v8_inspector::toV8String(isolate, in_text)).FromMaybe(false));
    assert(param->Set(context, tns::ToV8String(isolate, "name"), v8_inspector::toV8String(isolate, in_name.fromJust())).FromMaybe(false));

    Local<Value> args[] = { param };
    Local<Value> result;
    TryCatch tc(isolate);
    assert(setAttributesAsTextFunc->Call(context, domDomainDebugger, 1, args).ToLocal(&result));

    if (tc.HasCaught() || result.IsEmpty()) {
        String16 error = toProtocolString(isolate, tc.Message()->Get());
        return DispatchResponse::Error(error);
    }

    return DispatchResponse::OK();
}

DispatchResponse V8DOMAgentImpl::removeAttribute(int in_nodeId, const String& in_name) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::performSearch(const String& in_query, Maybe<bool> in_includeUserAgentShadowDOM, String* out_searchId, int* out_resultCount) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::getSearchResults(const String& in_searchId, int in_fromIndex, int in_toIndex, std::unique_ptr<protocol::Array<int>>* out_nodeIds) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::discardSearchResults(const String& in_searchId) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::resolveNode(Maybe<int> in_nodeId, Maybe<int> in_backendNodeId, Maybe<String> in_objectGroup, Maybe<int> in_executionContextId, std::unique_ptr<protocol::Runtime::RemoteObject>* out_object) {
    auto resolvedNode = protocol::Runtime::RemoteObject::create()
        .setType("View")
        .build();

    *out_object = std::move(resolvedNode);

    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::collectClassNamesFromSubtree(int in_nodeId, std::unique_ptr<protocol::Array<String>>* out_classNames) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::copyTo(int in_nodeId, int in_targetNodeId, Maybe<int> in_insertBeforeNodeId, int* out_nodeId) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::describeNode(Maybe<int> in_nodeId, Maybe<int> in_backendNodeId, Maybe<String> in_objectId, Maybe<int> in_depth, Maybe<bool> in_pierce, std::unique_ptr<protocol::DOM::Node>* out_node) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::focus(Maybe<int> in_nodeId, Maybe<int> in_backendNodeId, Maybe<String> in_objectId) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::getAttributes(int in_nodeId, std::unique_ptr<protocol::Array<String>>* out_attributes) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::getBoxModel(Maybe<int> in_nodeId, Maybe<int> in_backendNodeId, Maybe<String> in_objectId, std::unique_ptr<protocol::DOM::BoxModel>* out_model) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::getFlattenedDocument(Maybe<int> in_depth, Maybe<bool> in_pierce, std::unique_ptr<protocol::Array<protocol::DOM::Node>>* out_nodes) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::getNodeForLocation(int in_x, int in_y, Maybe<bool> in_includeUserAgentShadowDOM, int* out_backendNodeId, Maybe<int>* out_nodeId) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::getOuterHTML(Maybe<int> in_nodeId, Maybe<int> in_backendNodeId, Maybe<String> in_objectId, String* out_outerHTML) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::getRelayoutBoundary(int in_nodeId, int* out_nodeId) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::markUndoableState() {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::moveTo(int in_nodeId, int in_targetNodeId, Maybe<int> in_insertBeforeNodeId, int* out_nodeId) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::pushNodeByPathToFrontend(const String& in_path, int* out_nodeId) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::pushNodesByBackendIdsToFrontend(std::unique_ptr<protocol::Array<int>> in_backendNodeIds, std::unique_ptr<protocol::Array<int>>* out_nodeIds) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::querySelector(int in_nodeId, const String& in_selector, int* out_nodeId) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::querySelectorAll(int in_nodeId, const String& in_selector, std::unique_ptr<protocol::Array<int>>* out_nodeIds) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::redo() {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::requestChildNodes(int in_nodeId, Maybe<int> in_depth, Maybe<bool> in_pierce) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::requestNode(const String& in_objectId, int* out_nodeId) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::setFileInputFiles(std::unique_ptr<protocol::Array<String>> in_files, Maybe<int> in_nodeId, Maybe<int> in_backendNodeId, Maybe<String> in_objectId) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::getFileInfo(const String& in_objectId, String* out_path) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::setInspectedNode(int in_nodeId) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::setNodeName(int in_nodeId, const String& in_name, int* out_nodeId) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::setNodeValue(int in_nodeId, const String& in_value) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::setOuterHTML(int in_nodeId, const String& in_outerHTML) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::undo() {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::getFrameOwner(const String& in_frameId, int* out_backendNodeId, Maybe<int>* out_nodeId) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

}

