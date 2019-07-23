#include "v8-css-agent-impl.h"


namespace v8_inspector {
    
namespace CSSAgentState {
    static const char cssEnabled[] = "cssEnabled";
}

V8CSSAgentImpl::V8CSSAgentImpl(V8InspectorSessionImpl* session,
                               protocol::FrontendChannel* frontendChannel,
                               protocol::DictionaryValue* state)
    : m_session(session),
    m_frontend(frontendChannel),
    m_state(state),
    m_enabled(false) {
    Instance = this;
}

V8CSSAgentImpl::~V8CSSAgentImpl() { }

void V8CSSAgentImpl::enable(std::unique_ptr<EnableCallback> callback) {
    if (m_enabled) {
        callback->sendSuccess();
        return;
    }
    
    m_state->setBoolean(CSSAgentState::cssEnabled, true);
    m_enabled = true;
    
    callback->sendSuccess();
}

DispatchResponse V8CSSAgentImpl::disable() {
    if (!m_enabled) {
        return DispatchResponse::OK();
    }
    
    m_state->setBoolean(CSSAgentState::cssEnabled, false);
    
    m_enabled = false;
    
    return DispatchResponse::OK();
}

// Not supported
DispatchResponse V8CSSAgentImpl::getMatchedStylesForNode(int in_nodeId, Maybe<protocol::CSS::CSSStyle>* out_inlineStyle, Maybe<protocol::CSS::CSSStyle>* out_attributesStyle, Maybe<protocol::Array<protocol::CSS::RuleMatch>>* out_matchedCSSRules, Maybe<protocol::Array<protocol::CSS::PseudoElementMatches>>* out_pseudoElements, Maybe<protocol::Array<protocol::CSS::InheritedStyleEntry>>* out_inherited, Maybe<protocol::Array<protocol::CSS::CSSKeyframesRule>>* out_cssKeyframesRules) {
    return DispatchResponse::OK();
}

DispatchResponse V8CSSAgentImpl::getInlineStylesForNode(int in_nodeId, Maybe<protocol::CSS::CSSStyle>* out_inlineStyle, Maybe<protocol::CSS::CSSStyle>* out_attributesStyle) {
    return DispatchResponse::OK();
}

DispatchResponse V8CSSAgentImpl::getComputedStyleForNode(int in_nodeId, std::unique_ptr<protocol::Array<protocol::CSS::CSSComputedStyleProperty>>* out_computedStyle) {
//    auto computedStylePropertyArr = protocol::Array<protocol::CSS::CSSComputedStyleProperty>::create();
//
//    *out_computedStyle = std::move(computedStylePropertyArr);
    
    return DispatchResponse::OK();
}

DispatchResponse V8CSSAgentImpl::getPlatformFontsForNode(int in_nodeId, std::unique_ptr<protocol::Array<protocol::CSS::PlatformFontUsage>>* out_fonts) {
//    auto fontsArr = protocol::Array<protocol::CSS::PlatformFontUsage>::create();
//    auto defaultFont = "System Font";
//    fontsArr->addItem(std::move(protocol::CSS::PlatformFontUsage::create()
//                                .setFamilyName(defaultFont)
//                                .setGlyphCount(1)
//                                .setIsCustomFont(false)
//                                .build()));
//    *out_fonts = std::move(fontsArr);
    
    return DispatchResponse::OK();
}

DispatchResponse V8CSSAgentImpl::getStyleSheetText(const String& in_styleSheetId, String* out_text) {
    *out_text = "";
    
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::addRule(const String& in_styleSheetId, const String& in_ruleText, std::unique_ptr<protocol::CSS::SourceRange> in_location, std::unique_ptr<protocol::CSS::CSSRule>* out_rule) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::collectClassNames(const String& in_styleSheetId, std::unique_ptr<protocol::Array<String>>* out_classNames) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::createStyleSheet(const String& in_frameId, String* out_styleSheetId) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::forcePseudoState(int in_nodeId, std::unique_ptr<protocol::Array<String>> in_forcedPseudoClasses) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::getBackgroundColors(int in_nodeId, Maybe<protocol::Array<String>>* out_backgroundColors, Maybe<String>* out_computedFontSize, Maybe<String>* out_computedFontWeight) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::getMediaQueries(std::unique_ptr<protocol::Array<protocol::CSS::CSSMedia>>* out_medias) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::setEffectivePropertyValueForNode(int in_nodeId, const String& in_propertyName, const String& in_value) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::setKeyframeKey(const String& in_styleSheetId, std::unique_ptr<protocol::CSS::SourceRange> in_range, const String& in_keyText, std::unique_ptr<protocol::CSS::Value>* out_keyText) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::setMediaText(const String& in_styleSheetId, std::unique_ptr<protocol::CSS::SourceRange> in_range, const String& in_text, std::unique_ptr<protocol::CSS::CSSMedia>* out_media) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::setRuleSelector(const String& in_styleSheetId, std::unique_ptr<protocol::CSS::SourceRange> in_range, const String& in_selector, std::unique_ptr<protocol::CSS::SelectorList>* out_selectorList) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::setStyleSheetText(const String& in_styleSheetId, const String& in_text, Maybe<String>* out_sourceMapURL) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::setStyleTexts(std::unique_ptr<protocol::Array<protocol::CSS::StyleDeclarationEdit>> in_edits, std::unique_ptr<protocol::Array<protocol::CSS::CSSStyle>>* out_styles) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::startRuleUsageTracking() {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::stopRuleUsageTracking(std::unique_ptr<protocol::Array<protocol::CSS::RuleUsage>>* out_ruleUsage) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::takeCoverageDelta(std::unique_ptr<protocol::Array<protocol::CSS::RuleUsage>>* out_coverage) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

V8CSSAgentImpl* V8CSSAgentImpl::Instance = 0;
    
}
