#include "v8-page-agent-impl.h"
#include "src/inspector/v8-inspector-session-impl.h"
#include "src/inspector/v8-inspector-impl.h"
#include "../../base64.h"
#include "../../utils.h"
#include "Runtime/Helpers.h"
#include <dirent.h>

namespace v8_inspector {

namespace PageAgentState {
    static const char pageEnabled[] = "pageEnabled";
}

V8PageAgentImpl::V8PageAgentImpl(V8InspectorSessionImpl* session, protocol::FrontendChannel* frontendChannel,
                                 protocol::DictionaryValue* state, const std::string baseDir)
    : m_inspector(session->inspector()),
      m_isolate(m_inspector->isolate()),
      m_session(session),
      m_frontend(frontendChannel),
      m_state(state),
      m_enabled(false),
      m_frameIdentifier(""),
      m_frameUrl("file://"),
      m_baseDir(baseDir) {
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

DispatchResponse V8PageAgentImpl::getResourceTree(std::unique_ptr<protocol::Page::FrameResourceTree>* out_frameTree) {
    std::unique_ptr<protocol::Page::Frame> frameObject = protocol::Page::Frame::create()
    .setId(m_frameIdentifier.c_str())
    .setLoaderId("NSLoaderIdentifier")
    .setMimeType("text/directory")
    .setSecurityOrigin("")
    .setUrl(m_frameUrl.c_str())
    .build();

    std::unique_ptr<protocol::Array<protocol::Page::FrameResource>> subresources = std::unique_ptr<protocol::Array<protocol::Page::FrameResource>>(new protocol::Array<protocol::Page::FrameResource>());

    std::vector<V8PageAgentImpl::PageEntry> entries;
    this->ReadEntries(m_baseDir, entries);

    for (PageEntry entry : entries) {
        std::unique_ptr<protocol::Page::FrameResource> frameResource = protocol::Page::FrameResource::create()
            .setUrl(entry.Name.c_str())
            .setType(entry.Type.c_str())
            .setMimeType(entry.MimeType.c_str())
            .build();

        subresources->push_back(std::move(frameResource));
    }

    *out_frameTree = protocol::Page::FrameResourceTree::create()
        .setFrame(std::move(frameObject))
        .setResources(std::move(subresources))
        .build();

    return DispatchResponse::OK();
}

void V8PageAgentImpl::getResourceContent(const String& in_frameId, const String& in_url, std::unique_ptr<GetResourceContentCallback> callback) {
    if (in_url.utf8().compare(m_frameUrl) == 0) {
        auto content = "";
        auto base64Encoded = false;

        callback->sendSuccess(content, base64Encoded);
        return;
    }

    std::string fullPath = in_url.utf8();
    std::string filePath = fullPath;
    filePath.erase(0, 7); // deletes the 'file://' part before the full file path
    std::string type = GetResourceType(filePath);
    bool shouldEncode = !HasTextContent(type);
    std::string content = tns::ReadText(filePath);

    if (shouldEncode) {
        content = base64_encode(content.c_str(), (uint)content.length());
    }

    std::vector<uint16_t> vector = ToVector(content);
    String16 result(vector.data(), vector.size());

    callback->sendSuccess(result, shouldEncode);
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

void V8PageAgentImpl::ReadEntries(std::string baseDir, std::vector<V8PageAgentImpl::PageEntry>& entries) {
    DIR* dir = opendir(baseDir.c_str());
    if (dir == nullptr) {
        return;
    }

    dirent* entry;
    while ((entry = readdir(dir)) != nullptr) {
        if (entry->d_type != DT_DIR && entry->d_type != DT_REG) {
            continue;
        }

        std::string entryName(entry->d_name, entry->d_namlen);
        if (entry->d_type == DT_DIR && (entryName == "." || entryName == "..")) {
            continue;
        }

        std::string fullPath = baseDir + "/" + entryName;
        std::string mimeType = GetMIMEType(fullPath);
        std::string type = GetResourceType(fullPath);
        std::string fullPathWithScheme = "file://" + fullPath;

        PageEntry pageEntry{
            fullPathWithScheme,
            type,
            mimeType
        };

        if (entry->d_type == DT_REG) {
            entries.push_back(pageEntry);
        }

        if (entry->d_type == DT_DIR) {
            this->ReadEntries(baseDir + "/" + entryName, entries);
        }
    }

    closedir(dir);
}

bool V8PageAgentImpl::HasTextContent(std::string type) {
    return strcmp(type.c_str(), protocol::Network::ResourceTypeEnum::Document) == 0 ||
        strcmp(type.c_str(), protocol::Network::ResourceTypeEnum::Stylesheet) == 0 ||
        strcmp(type.c_str(), protocol::Network::ResourceTypeEnum::Script) == 0;
}

std::string V8PageAgentImpl::GetResourceType(std::string fullPath) {
    std::string mimeType = GetMIMEType(fullPath);

    std::string type = protocol::Network::ResourceTypeEnum::Document;
    if (!mimeType.empty()) {
        auto it = s_mimeTypeMap.find(mimeType);
        if (it != s_mimeTypeMap.end()) {
            type = s_mimeTypeMap.at(mimeType);
        }
    }

    return type;
}

std::map<std::string, const char*> V8PageAgentImpl::s_mimeTypeMap = {
    { "text/xml", v8_inspector::protocol::Network::ResourceTypeEnum::Document },
    { "text/plain", v8_inspector::protocol::Network::ResourceTypeEnum::Document },
    { "application/xml", v8_inspector::protocol::Network::ResourceTypeEnum::Document },
    // text/css mime type is regarded as document so as to display in the Sources tab
    { "text/css", v8_inspector::protocol::Network::ResourceTypeEnum::Document },
    { "text/javascript", v8_inspector::protocol::Network::ResourceTypeEnum::Script },
    { "application/javascript", v8_inspector::protocol::Network::ResourceTypeEnum::Script },
    { "application/json", v8_inspector::protocol::Network::ResourceTypeEnum::Document },
    { "text/typescript", v8_inspector::protocol::Network::ResourceTypeEnum::Script },
    { "image/jpeg", v8_inspector::protocol::Network::ResourceTypeEnum::Image },
    { "image/png", v8_inspector::protocol::Network::ResourceTypeEnum::Image },
    { "application/binary", v8_inspector::protocol::Network::ResourceTypeEnum::Other },
    { "application/macbinary", v8_inspector::protocol::Network::ResourceTypeEnum::Other }
};

}
