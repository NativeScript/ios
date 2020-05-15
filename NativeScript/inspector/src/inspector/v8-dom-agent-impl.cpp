#include "v8-dom-agent-impl.h"
#include "../../third_party/inspector_protocol/crdtp/json.h"
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
      m_session(session),
      m_enabled(false) {
}

V8DOMAgentImpl::~V8DOMAgentImpl() { }

DispatchResponse V8DOMAgentImpl::enable() {
    if (m_enabled) {
        return DispatchResponse::Success();
    }

    m_state->setBoolean(DOMAgentState::domEnabled, true);

    m_enabled = true;

    return DispatchResponse::Success();
}

DispatchResponse V8DOMAgentImpl::disable() {
    if (!m_enabled) {
        return DispatchResponse::Success();
    }

    m_state->setBoolean(DOMAgentState::domEnabled, false);

    m_enabled = false;

    return DispatchResponse::Success();
}

void V8DOMAgentImpl::dispatch(std::string message) {
    Isolate* isolate = m_inspector->isolate();
    int contextGroupId = this->m_session->contextGroupId();
    InspectedContext* inspected = this->m_inspector->getContext(contextGroupId);
    Local<Context> context = inspected->context();

    Local<Value> value;
    assert(v8::JSON::Parse(context, tns::ToV8String(isolate, message)).ToLocal(&value) && value->IsObject());
    Local<Object> obj = value.As<Object>();
    std::string method = GetDomainMethod(isolate, obj, "DOM.");

    if (method == "childNodeInserted") {
        this->ChildNodeInserted(obj);
    } else if (method == "childNodeRemoved") {
        this->ChildNodeRemoved(obj);
    } else if (method == "attributeModified") {
        this->AttributeModified(obj);
    } else if (method == "attributeRemoved") {
        this->AttributeRemoved(obj);
    } else if (method == "documentUpdated") {
        this->DocumentUpdated();
    }
}

DispatchResponse V8DOMAgentImpl::getContentQuads(Maybe<int> in_nodeId, Maybe<int> in_backendNodeId, Maybe<String> in_objectId, std::unique_ptr<protocol::Array<protocol::Array<double>>>* out_quads) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
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
    int contextGroupId = this->m_session->contextGroupId();
    InspectedContext* inspected = this->m_inspector->getContext(contextGroupId);
    Local<Context> context = inspected->context();

    Local<Object> domDomainDebugger;
    Local<v8::Function> getDocumentFunc = v8_inspector::GetDebuggerFunction(context, "DOM", "getDocument", domDomainDebugger);
    if (getDocumentFunc.IsEmpty() || domDomainDebugger.IsEmpty()) {
        *out_root = std::move(defaultNode);
        return DispatchResponse::ServerError("Error getting DOM tree.");
    }

    Local<Value> args[0];

    TryCatch tc(isolate);
    MaybeLocal<Value> maybeResult = getDocumentFunc->Call(context, domDomainDebugger, 0, args);
    if (tc.HasCaught()) {
        std::string error = tns::ToString(isolate, tc.Message()->Get());
        *out_root = std::move(defaultNode);
        return protocol::DispatchResponse::ServerError(error);
    }

    Local<Value> result;
    if (!maybeResult.ToLocal(&result) || !result->IsObject()) {
        return protocol::DispatchResponse::ServerError("Didn't get a proper result from getDocument call. Returning empty visual tree.");
    }

    Local<Object> resultObj = result.As<Object>();
    Local<v8::String> resultString;
    assert(v8::JSON::Stringify(context, resultObj->Get(context, tns::ToV8String(isolate, "root")).ToLocalChecked()).ToLocal(&resultString));

    String16 resultProtocolString = toProtocolString(isolate, resultString);
    std::vector<uint8_t> cbor;
    v8_crdtp::json::ConvertJSONToCBOR(v8_crdtp::span<uint16_t>(resultProtocolString.characters16(), resultProtocolString.length()), &cbor);
    std::unique_ptr<protocol::Value> resultJson = protocol::Value::parseBinary(cbor.data(), cbor.size());
    protocol::ErrorSupport errorSupport;
    std::unique_ptr<protocol::DOM::Node> domNode = protocol::DOM::Node::fromValue(resultJson.get(), &errorSupport);

    std::vector<uint8_t> json;
    v8_crdtp::json::ConvertCBORToJSON(errorSupport.Errors(), &json);
    auto errorSupportString = String16(reinterpret_cast<const char*>(json.data()), json.size()).utf8();
    if (!errorSupportString.empty()) {
        std::string errorMessage = "Error while parsing debug `DOM Node` object.";
        return DispatchResponse::ServerError(errorMessage);
    }

    *out_root = std::move(domNode);
    return DispatchResponse::Success();
}

DispatchResponse V8DOMAgentImpl::removeNode(int in_nodeId) {
    Isolate* isolate = m_inspector->isolate();
    int contextGroupId = this->m_session->contextGroupId();
    InspectedContext* inspected = this->m_inspector->getContext(contextGroupId);
    Local<Context> context = inspected->context();

    Local<Object> domDomainDebugger;
    Local<v8::Function> removeNodeFunc = v8_inspector::GetDebuggerFunction(context, "DOM", "removeNode", domDomainDebugger);

    if (removeNodeFunc.IsEmpty() || domDomainDebugger.IsEmpty()) {
        return DispatchResponse::ServerError("Couldn't remove the selected DOMNode from the visual tree. \"removeNode\" function not found");
    }

    Local<ObjectTemplate> objTemplate = ObjectTemplate::New(isolate);
    Local<Object> param;
    bool success = objTemplate->NewInstance(context).ToLocal(&param);
    assert(success);

    success = param->Set(context, tns::ToV8String(isolate, "nodeId"), Number::New(isolate, in_nodeId)).FromMaybe(false);
    assert(success);

    Local<Value> args[] = { param };
    Local<Value> result;
    TryCatch tc(isolate);
    assert(removeNodeFunc->Call(context, domDomainDebugger, 1, args).ToLocal(&result));

    if (tc.HasCaught() || result.IsEmpty()) {
        std::string error = tns::ToString(isolate, tc.Message()->Get());
        return DispatchResponse::ServerError(error);
    }

    return DispatchResponse::Success();
}

DispatchResponse V8DOMAgentImpl::setAttributeValue(int in_nodeId, const String& in_name, const String& in_value) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::setAttributesAsText(int in_nodeId, const String& in_text, Maybe<String> in_name) {
    Isolate* isolate = m_inspector->isolate();
    int contextGroupId = this->m_session->contextGroupId();
    InspectedContext* inspected = this->m_inspector->getContext(contextGroupId);
    Local<Context> context = inspected->context();

    Local<Object> domDomainDebugger;
    Local<v8::Function> setAttributesAsTextFunc = v8_inspector::GetDebuggerFunction(context, "DOM", "setAttributesAsText", domDomainDebugger);

    if (setAttributesAsTextFunc.IsEmpty() || domDomainDebugger.IsEmpty()) {
        return DispatchResponse::ServerError("Couldn't change selected DOM node's attribute. \"setAttributesAsText\" function not found");
    }

    Local<ObjectTemplate> objTemplate = ObjectTemplate::New(isolate);
    Local<Object> param;
    bool success = objTemplate->NewInstance(context).ToLocal(&param);
    assert(success);

    assert(param->Set(context, tns::ToV8String(isolate, "nodeId"), Number::New(isolate, in_nodeId)).FromMaybe(false));
    assert(param->Set(context, tns::ToV8String(isolate, "text"), v8_inspector::toV8String(isolate, in_text)).FromMaybe(false));
    assert(param->Set(context, tns::ToV8String(isolate, "name"), v8_inspector::toV8String(isolate, in_name.fromJust())).FromMaybe(false));

    Local<Value> args[] = { param };
    Local<Value> result;
    TryCatch tc(isolate);
    assert(setAttributesAsTextFunc->Call(context, domDomainDebugger, 1, args).ToLocal(&result));

    if (tc.HasCaught() || result.IsEmpty()) {
        std::string error = tns::ToString(isolate, tc.Message()->Get());
        return DispatchResponse::ServerError(error);
    }

    return DispatchResponse::Success();
}

DispatchResponse V8DOMAgentImpl::removeAttribute(int in_nodeId, const String& in_name) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::performSearch(const String& in_query, Maybe<bool> in_includeUserAgentShadowDOM, String* out_searchId, int* out_resultCount) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::getSearchResults(const String& in_searchId, int in_fromIndex, int in_toIndex, std::unique_ptr<protocol::Array<int>>* out_nodeIds) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::discardSearchResults(const String& in_searchId) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::resolveNode(Maybe<int> in_nodeId, Maybe<int> in_backendNodeId, Maybe<String> in_objectGroup, Maybe<int> in_executionContextId, std::unique_ptr<protocol::Runtime::RemoteObject>* out_object) {
    auto resolvedNode = protocol::Runtime::RemoteObject::create()
        .setType("View")
        .build();

    *out_object = std::move(resolvedNode);

    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::collectClassNamesFromSubtree(int in_nodeId, std::unique_ptr<protocol::Array<String>>* out_classNames) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::copyTo(int in_nodeId, int in_targetNodeId, Maybe<int> in_insertBeforeNodeId, int* out_nodeId) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::describeNode(Maybe<int> in_nodeId, Maybe<int> in_backendNodeId, Maybe<String> in_objectId, Maybe<int> in_depth, Maybe<bool> in_pierce, std::unique_ptr<protocol::DOM::Node>* out_node) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::focus(Maybe<int> in_nodeId, Maybe<int> in_backendNodeId, Maybe<String> in_objectId) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::getAttributes(int in_nodeId, std::unique_ptr<protocol::Array<String>>* out_attributes) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::getBoxModel(Maybe<int> in_nodeId, Maybe<int> in_backendNodeId, Maybe<String> in_objectId, std::unique_ptr<protocol::DOM::BoxModel>* out_model) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::getFlattenedDocument(Maybe<int> in_depth, Maybe<bool> in_pierce, std::unique_ptr<protocol::Array<protocol::DOM::Node>>* out_nodes) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::getNodeForLocation(int in_x, int in_y, Maybe<bool> in_includeUserAgentShadowDOM, Maybe<bool> in_ignorePointerEventsNone, int* out_backendNodeId, String* out_frameId, Maybe<int>* out_nodeId) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::getOuterHTML(Maybe<int> in_nodeId, Maybe<int> in_backendNodeId, Maybe<String> in_objectId, String* out_outerHTML) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::getRelayoutBoundary(int in_nodeId, int* out_nodeId) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::markUndoableState() {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::moveTo(int in_nodeId, int in_targetNodeId, Maybe<int> in_insertBeforeNodeId, int* out_nodeId) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::pushNodeByPathToFrontend(const String& in_path, int* out_nodeId) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::pushNodesByBackendIdsToFrontend(std::unique_ptr<protocol::Array<int>> in_backendNodeIds, std::unique_ptr<protocol::Array<int>>* out_nodeIds) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::querySelector(int in_nodeId, const String& in_selector, int* out_nodeId) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::querySelectorAll(int in_nodeId, const String& in_selector, std::unique_ptr<protocol::Array<int>>* out_nodeIds) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::redo() {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::requestChildNodes(int in_nodeId, Maybe<int> in_depth, Maybe<bool> in_pierce) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::requestNode(const String& in_objectId, int* out_nodeId) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::setFileInputFiles(std::unique_ptr<protocol::Array<String>> in_files, Maybe<int> in_nodeId, Maybe<int> in_backendNodeId, Maybe<String> in_objectId) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::getFileInfo(const String& in_objectId, String* out_path) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::setInspectedNode(int in_nodeId) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::setNodeName(int in_nodeId, const String& in_name, int* out_nodeId) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::setNodeValue(int in_nodeId, const String& in_value) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::setOuterHTML(int in_nodeId, const String& in_outerHTML) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::undo() {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::getFrameOwner(const String& in_frameId, int* out_backendNodeId, Maybe<int>* out_nodeId) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::setNodeStackTracesEnabled(bool in_enable) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::getNodeStackTraces(int in_nodeId, Maybe<protocol::Runtime::StackTrace>* out_creation) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

void V8DOMAgentImpl::ChildNodeInserted(const Local<Object>& obj) {
    Isolate* isolate = m_inspector->isolate();
    int contextGroupId = this->m_session->contextGroupId();
    InspectedContext* inspected = this->m_inspector->getContext(contextGroupId);
    Local<Context> context = inspected->context();
    Local<Object> params = obj->Get(context, tns::ToV8String(isolate, "params")).ToLocalChecked().As<Object>();
    Local<Number> parentNodeId = params->Get(context, tns::ToV8String(isolate, "parentNodeId")).ToLocalChecked()->ToNumber(context).ToLocalChecked();
    Local<Number> previousNodeId = params->Get(context, tns::ToV8String(isolate, "previousNodeId")).ToLocalChecked()->ToNumber(context).ToLocalChecked();
    Local<Value> node = params->Get(context, tns::ToV8String(isolate, "node")).ToLocalChecked();

    Local<v8::String> nodeJson;
    assert(JSON::Stringify(context, node).ToLocal(&nodeJson));

    std::u16string nodeString = AddBackendNodeIdProperty(context, nodeJson);
    auto nodeUtf16Data = nodeString.data();
    const String16& nodeString16 = String16((const uint16_t*) nodeUtf16Data);
    std::vector<uint8_t> cbor;
    v8_crdtp::json::ConvertJSONToCBOR(v8_crdtp::span<uint16_t>(nodeString16.characters16(), nodeString16.length()), &cbor);
    std::unique_ptr<protocol::Value> protocolNodeJson = protocol::Value::parseBinary(cbor.data(), cbor.size());

    protocol::ErrorSupport errorSupport;
    auto domNode = protocol::DOM::Node::fromValue(protocolNodeJson.get(), &errorSupport);

    std::vector<uint8_t> json;
    v8_crdtp::json::ConvertCBORToJSON(errorSupport.Errors(), &json);
    auto errorSupportString = String16(reinterpret_cast<const char*>(json.data()), json.size()).utf8();
    if (!errorSupportString.empty()) {
        std::string errorMessage = "Error while parsing debug `DOM Node` object.";
        Log("%s Error: %s", errorMessage.c_str(), errorSupportString.c_str());
        return;
    }

    this->m_frontend.childNodeInserted(parentNodeId->Int32Value(context).ToChecked(), previousNodeId->Int32Value(context).ToChecked(), std::move(domNode));
}

void V8DOMAgentImpl::ChildNodeRemoved(const Local<Object>& obj) {
    Isolate* isolate = m_inspector->isolate();
    int contextGroupId = this->m_session->contextGroupId();
    InspectedContext* inspected = this->m_inspector->getContext(contextGroupId);
    Local<Context> context = inspected->context();
    Local<Object> params = obj->Get(context, tns::ToV8String(isolate, "params")).ToLocalChecked().As<Object>();
    Local<Number> nodeId = params->Get(context, tns::ToV8String(isolate, "nodeId")).ToLocalChecked()->ToNumber(context).ToLocalChecked();
    Local<Number> parentNodeId = params->Get(context, tns::ToV8String(isolate, "parentNodeId")).ToLocalChecked()->ToNumber(context).ToLocalChecked();

    this->m_frontend.childNodeRemoved(
        parentNodeId->Int32Value(context).ToChecked(),
        nodeId->Int32Value(context).ToChecked()
    );
}

void V8DOMAgentImpl::AttributeModified(const Local<Object>& obj) {
    Isolate* isolate = m_inspector->isolate();
    int contextGroupId = this->m_session->contextGroupId();
    InspectedContext* inspected = this->m_inspector->getContext(contextGroupId);
    Local<Context> context = inspected->context();
    Local<Object> params = obj->Get(context, tns::ToV8String(isolate, "params")).ToLocalChecked().As<Object>();
    Local<Number> nodeId = params->Get(context, tns::ToV8String(isolate, "nodeId")).ToLocalChecked()->ToNumber(context).ToLocalChecked();
    Local<v8::String> attributeName = params->Get(context, tns::ToV8String(isolate, "name")).ToLocalChecked()->ToString(context).ToLocalChecked();
    Local<v8::String> attributeValue = params->Get(context, tns::ToV8String(isolate, "value")).ToLocalChecked()->ToString(context).ToLocalChecked();

    this->m_frontend.attributeModified(
        nodeId->Int32Value(context).ToChecked(),
        v8_inspector::toProtocolString(isolate, attributeName),
        v8_inspector::toProtocolString(isolate, attributeValue)
    );
}

void V8DOMAgentImpl::AttributeRemoved(const Local<Object>& obj) {
    Isolate* isolate = m_inspector->isolate();
    int contextGroupId = this->m_session->contextGroupId();
    InspectedContext* inspected = this->m_inspector->getContext(contextGroupId);
    Local<Context> context = inspected->context();
    Local<Object> params = obj->Get(context, tns::ToV8String(isolate, "params")).ToLocalChecked().As<Object>();
    Local<Number> nodeId = params->Get(context, tns::ToV8String(isolate, "nodeId")).ToLocalChecked()->ToNumber(context).ToLocalChecked();
    Local<v8::String> attributeName = params->Get(context, tns::ToV8String(isolate, "name")).ToLocalChecked()->ToString(context).ToLocalChecked();

    this->m_frontend.attributeRemoved(
        nodeId->Int32Value(context).ToChecked(),
        v8_inspector::toProtocolString(isolate, attributeName)
    );
}

void V8DOMAgentImpl::DocumentUpdated() {
    this->m_frontend.documentUpdated();
}

std::u16string V8DOMAgentImpl::AddBackendNodeIdProperty(Local<Context> context, Local<Value> jsonInput) {
    std::string scriptSource =
        "(function () {"
        "   function addBackendNodeId(node) {"
        "       if (!node.backendNodeId) {"
        "           node.backendNodeId = 0;"
        "       }"
        "       if (node.children) {"
        "           for (var i = 0; i < node.children.length; i++) {"
        "               addBackendNodeId(node.children[i]);"
        "           }"
        "       }"
        "   }"
        "   return function(stringifiedNode) {"
        "       try {"
        "           const node = JSON.parse(stringifiedNode);"
        "           addBackendNodeId(node);"
        "           return JSON.stringify(node);"
        "       } catch (e) {"
        "           return stringifiedNode;"
        "       }"
        "   }"
        "})()";

    Isolate* isolate = context->GetIsolate();
    auto source = tns::ToV8String(isolate, scriptSource);
    Local<Script> script;
    assert(v8::Script::Compile(context, source).ToLocal(&script));

    Local<Value> result;
    assert(script->Run(context).ToLocal(&result));
    Local<v8::Function> addBackendNodeIdFunction = result.As<v8::Function>();

    Local<Value> funcArguments[] = { jsonInput };
    Local<Value> scriptResult;
    assert(addBackendNodeIdFunction->Call(context, context->Global(), 1, funcArguments).ToLocal(&scriptResult));

    std::u16string resultString = tns::ToUtf16String(isolate, scriptResult->ToString(context).ToLocalChecked());
    return resultString;
}

}

