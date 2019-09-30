#include "v8-css-agent-impl.h"
#include "src/inspector/v8-inspector-session-impl.h"
#include "Helpers.h"
#include "utils.h"

using namespace v8;

namespace v8_inspector {

namespace CSSAgentState {
    static const char cssEnabled[] = "cssEnabled";
}

V8CSSAgentImpl::V8CSSAgentImpl(V8InspectorSessionImpl* session,
                               protocol::FrontendChannel* frontendChannel,
                               protocol::DictionaryValue* state)
    : m_frontend(frontendChannel),
      m_state(state),
      m_inspector(session->inspector()),
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
    std::unique_ptr<protocol::Array<protocol::CSS::CSSComputedStyleProperty>> computedStylePropertyArr = std::make_unique<protocol::Array<protocol::CSS::CSSComputedStyleProperty>>();

    Isolate* isolate = m_inspector->isolate();
    Local<Object> cssDomainDebugger;
    Local<v8::Function> getComputedStylesForNodeFunc = v8_inspector::GetDebuggerFunction(isolate, "CSS", "getComputedStyleForNode", cssDomainDebugger);
    if (getComputedStylesForNodeFunc.IsEmpty() || cssDomainDebugger.IsEmpty()) {
        *out_computedStyle = std::move(computedStylePropertyArr);
        return DispatchResponse::Error("Error getting CSS elements.");
    }

    Local<Object> param = Object::New(isolate);
    Local<Context> context = isolate->GetCurrentContext();
    bool success = param->Set(context, tns::ToV8String(isolate, "nodeId"), Number::New(isolate, in_nodeId)).FromMaybe(false);
    assert(success);

    Local<Value> args[] = { param };
    Local<Value> result;
    TryCatch tc(isolate);
    assert(getComputedStylesForNodeFunc->Call(context, cssDomainDebugger, 1, args).ToLocal(&result));
    if (tc.HasCaught() || result.IsEmpty()) {
        *out_computedStyle = std::move(computedStylePropertyArr);
        String16 error = toProtocolString(isolate, tc.Message()->Get());
        return DispatchResponse::Error(error);
    }

    if (!result.IsEmpty() && result->IsObject()) {
        Local<Object> resultObj = result.As<Object>();
        Local<v8::String> resultString;
        assert(v8::JSON::Stringify(context, resultObj->Get(context, tns::ToV8String(isolate, "computedStyle")).ToLocalChecked()).ToLocal(&resultString));

        String16 resultProtocolString = toProtocolString(isolate, resultString);
        std::unique_ptr<protocol::Value> resultJson = protocol::StringUtil::parseJSON(resultProtocolString);
        protocol::ErrorSupport errorSupport;
        std::unique_ptr<protocol::Array<protocol::CSS::CSSComputedStyleProperty>> computedStyles = v8_inspector::fromValue<protocol::CSS::CSSComputedStyleProperty>(resultJson.get(), &errorSupport);

        std::string errorSupportString = errorSupport.errors().utf8();
        if (!errorSupportString.empty()) {
            String16 errorMessage = "Error while parsing CSSComputedStyleProperty object.";
            return DispatchResponse::Error(errorMessage);
        }

        *out_computedStyle = std::move(computedStyles);
        return DispatchResponse::OK();
    }

    *out_computedStyle = std::move(computedStylePropertyArr);
    return DispatchResponse::OK();
}

DispatchResponse V8CSSAgentImpl::getPlatformFontsForNode(int in_nodeId, std::unique_ptr<protocol::Array<protocol::CSS::PlatformFontUsage>>* out_fonts) {
    std::unique_ptr<protocol::Array<protocol::CSS::PlatformFontUsage>> fontsArr = std::make_unique<protocol::Array<protocol::CSS::PlatformFontUsage>>();
    String16 defaultFont = "System Font";
    std::unique_ptr<protocol::CSS::PlatformFontUsage> fontUsage = protocol::CSS::PlatformFontUsage::create()
        .setFamilyName(defaultFont)
        .setGlyphCount(1)
        .setIsCustomFont(false)
        .build();
    fontsArr->emplace_back(std::move(fontUsage));
    *out_fonts = std::move(fontsArr);

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
