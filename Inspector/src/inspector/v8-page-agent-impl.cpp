#include "v8-page-agent-impl.h"

namespace v8_inspector {
    
namespace PageAgentState {
    static const char pageEnabled[] = "pageEnabled";
}

V8PageAgentImpl::V8PageAgentImpl(V8InspectorSessionImpl* session, protocol::FrontendChannel* frontendChannel, protocol::DictionaryValue* state)
    : m_session(session),
      m_frontend(frontendChannel),
      m_state(state),
      m_enabled(false),
      m_frameIdentifier(""),
      m_frameUrl("file://") {
}

V8PageAgentImpl::~V8PageAgentImpl() {
}
    
DispatchResponse V8PageAgentImpl::enable() {
    if (m_enabled) {
        return DispatchResponse::OK();
    }
    
    m_state->setBoolean(PageAgentState::pageEnabled, true);
    
    m_enabled = true;
    
    return DispatchResponse::OK();
}

DispatchResponse V8PageAgentImpl::disable() {
    if (!m_enabled) {
        return DispatchResponse::OK();
    }
    
    m_state->setBoolean(PageAgentState::pageEnabled, false);
    
    m_enabled = false;
    
    return DispatchResponse::OK();
}

void V8PageAgentImpl::restore() {
    if (!m_state->booleanProperty(PageAgentState::pageEnabled, false)) {
        return;
    }
    
    enable();
}

DispatchResponse V8PageAgentImpl::addScriptToEvaluateOnLoad(const String& in_scriptSource, String* out_identifier) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8PageAgentImpl::setFontFamilies(std::unique_ptr<protocol::Page::FontFamilies> in_fontFamilies) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8PageAgentImpl::removeScriptToEvaluateOnLoad(const String& in_identifier) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8PageAgentImpl::addScriptToEvaluateOnNewDocument(const String& in_source, Maybe<String> in_worldName, String* out_identifier) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8PageAgentImpl::createIsolatedWorld(const String& in_frameId, Maybe<String> in_worldName, Maybe<bool> in_grantUniveralAccess, int* out_executionContextId) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8PageAgentImpl::getLayoutMetrics(std::unique_ptr<protocol::Page::LayoutViewport>* out_layoutViewport, std::unique_ptr<protocol::Page::VisualViewport>* out_visualViewport, std::unique_ptr<protocol::DOM::Rect>* out_contentSize) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

template<typename T>
static std::unique_ptr<protocol::Array<T>> create()
{
    return std::unique_ptr<protocol::Array<T>>(new protocol::Array<T>());
}

DispatchResponse V8PageAgentImpl::getResourceTree(std::unique_ptr<protocol::Page::FrameResourceTree>* out_frameTree) {
    std::unique_ptr<protocol::Page::Frame> frameObject = protocol::Page::Frame::create()
        .setId(m_frameIdentifier.c_str())
        .setLoaderId("NSLoaderIdentifier")
        .setMimeType("text/directory")
        .setSecurityOrigin("")
        .setUrl(m_frameUrl.c_str())
        .build();
    
    
    std::unique_ptr<protocol::Array<protocol::Page::FrameResource>> subresources = create<protocol::Page::FrameResource>();
    
    std::unique_ptr<protocol::Page::FrameResource> frameResource = protocol::Page::FrameResource::create()
        .setUrl("file:///data/data/com.tns.testapplication/files/app/Infrastructure/Jasmine/jasmine-2.0.1/test.js")
        .setType("Script")
        .setMimeType("text/javascript")
        .build();
    
    subresources->push_back(std::move(frameResource));
    
    *out_frameTree = protocol::Page::FrameResourceTree::create()
        .setFrame(std::move(frameObject))
        .setResources(std::move(subresources))
        .build();

    return DispatchResponse::OK();
}

DispatchResponse V8PageAgentImpl::reload(Maybe<bool> in_ignoreCache, Maybe<String> in_scriptToEvaluateOnLoad) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8PageAgentImpl::removeScriptToEvaluateOnNewDocument(const String& in_identifier) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

void V8PageAgentImpl::searchInResource(const String& in_frameId, const String& in_url, const String& in_query, Maybe<bool> in_caseSensitive, Maybe<bool> in_isRegex, std::unique_ptr<SearchInResourceCallback> callback) {
}
    
DispatchResponse V8PageAgentImpl::setBypassCSP(bool in_enabled) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8PageAgentImpl::startScreencast(Maybe<String> in_format, Maybe<int> in_quality, Maybe<int> in_maxWidth, Maybe<int> in_maxHeight, Maybe<int> in_everyNthFrame) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8PageAgentImpl::setFontSizes(std::unique_ptr<protocol::Page::FontSizes> in_fontSizes) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8PageAgentImpl::setAdBlockingEnabled(bool in_enabled) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8PageAgentImpl::stopLoading() {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}
    
DispatchResponse V8PageAgentImpl::setDocumentContent(const String& in_frameId, const String& in_html) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8PageAgentImpl::stopScreencast() {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8PageAgentImpl::getFrameTree(std::unique_ptr<protocol::Page::FrameTree>* out_frameTree) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8PageAgentImpl::clearCompilationCache() {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8PageAgentImpl::generateTestReport(const String& in_message, Maybe<String> in_group) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

void V8PageAgentImpl::getResourceContent(const String& in_frameId, const String& in_url, std::unique_ptr<GetResourceContentCallback> callback) {
    bool base64Encoded = false;
    String16 content = "alert('ok');";
    callback->sendSuccess(content, base64Encoded);
}

DispatchResponse V8PageAgentImpl::setLifecycleEventsEnabled(bool in_enabled) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8PageAgentImpl::setProduceCompilationCache(bool in_enabled) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8PageAgentImpl::addCompilationCache(const String& in_url, const protocol::Binary& in_data) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8PageAgentImpl::waitForDebugger() {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}
    
}
