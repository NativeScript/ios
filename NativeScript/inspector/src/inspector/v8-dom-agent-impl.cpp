#include "v8-dom-agent-impl.h"

namespace v8_inspector {
    
namespace DOMAgentState {
    static const char domEnabled[] = "domEnabled";
}

V8DOMAgentImpl::V8DOMAgentImpl(V8InspectorSessionImpl* session,
                               protocol::FrontendChannel* frontendChannel,
                               protocol::DictionaryValue* state)
    : m_frontend(frontendChannel),
      m_state(state),
      m_enabled(false) {
    Instance = this;
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
    
    *out_root = std::move(defaultNode);
    return DispatchResponse::Error("Error getting DOM tree.");
}

DispatchResponse V8DOMAgentImpl::removeNode(int in_nodeId) {
    return DispatchResponse::Error("Couldn't remove the selected DOMNode from the visual tree. Global Inspector object not found.");
}

DispatchResponse V8DOMAgentImpl::setAttributeValue(int in_nodeId, const String& in_name, const String& in_value) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8DOMAgentImpl::setAttributesAsText(int in_nodeId, const String& in_text, Maybe<String> in_name) {
    return DispatchResponse::Error("Couldn't change selected DOM node's attribute. Global Inspector object not found.");
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

V8DOMAgentImpl* V8DOMAgentImpl::Instance = 0;

}

