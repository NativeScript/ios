#include "v8-css-agent-impl.h"
#include "../../third_party/inspector_protocol/crdtp/json.h"
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
      m_session(session),
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
        return DispatchResponse::Success();
    }

    m_state->setBoolean(CSSAgentState::cssEnabled, false);

    m_enabled = false;

    return DispatchResponse::Success();
}

// Not supported
DispatchResponse V8CSSAgentImpl::getMatchedStylesForNode(int in_nodeId, Maybe<protocol::CSS::CSSStyle>* out_inlineStyle, Maybe<protocol::CSS::CSSStyle>* out_attributesStyle, Maybe<protocol::Array<protocol::CSS::RuleMatch>>* out_matchedCSSRules, Maybe<protocol::Array<protocol::CSS::PseudoElementMatches>>* out_pseudoElements, Maybe<protocol::Array<protocol::CSS::InheritedStyleEntry>>* out_inherited, Maybe<protocol::Array<protocol::CSS::CSSKeyframesRule>>* out_cssKeyframesRules) {
    return DispatchResponse::Success();
}

DispatchResponse V8CSSAgentImpl::getInlineStylesForNode(int in_nodeId, Maybe<protocol::CSS::CSSStyle>* out_inlineStyle, Maybe<protocol::CSS::CSSStyle>* out_attributesStyle) {
    return DispatchResponse::Success();
}

DispatchResponse V8CSSAgentImpl::getComputedStyleForNode(int in_nodeId, std::unique_ptr<protocol::Array<protocol::CSS::CSSComputedStyleProperty>>* out_computedStyle) {
    std::unique_ptr<protocol::Array<protocol::CSS::CSSComputedStyleProperty>> computedStylePropertyArr = std::make_unique<protocol::Array<protocol::CSS::CSSComputedStyleProperty>>();

    Isolate* isolate = m_inspector->isolate();
    int contextGroupId = this->m_session->contextGroupId();
    InspectedContext* inspected = this->m_inspector->getContext(contextGroupId);
    Local<Context> context = inspected->context();

    Local<Object> cssDomainDebugger;
    Local<v8::Function> getComputedStylesForNodeFunc = v8_inspector::GetDebuggerFunction(context, "CSS", "getComputedStyleForNode", cssDomainDebugger);
    if (getComputedStylesForNodeFunc.IsEmpty() || cssDomainDebugger.IsEmpty()) {
        *out_computedStyle = std::move(computedStylePropertyArr);
        return DispatchResponse::ServerError("Error getting CSS elements.");
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
    assert(getComputedStylesForNodeFunc->Call(context, cssDomainDebugger, 1, args).ToLocal(&result));
    if (tc.HasCaught() || result.IsEmpty()) {
        *out_computedStyle = std::move(computedStylePropertyArr);
        std::string error = tns::ToString(isolate, tc.Message()->Get());
        return DispatchResponse::ServerError(error);
    }

    if (!result.IsEmpty() && result->IsObject()) {
        Local<Object> resultObj = result.As<Object>();
        Local<Value> computedStyleValue;
        bool success = resultObj->Get(context, tns::ToV8String(isolate, "computedStyle")).ToLocal(&computedStyleValue);
        if (!success || computedStyleValue.IsEmpty() || !computedStyleValue->IsArray()) {
            std::string errorMessage = "Error while parsing CSSComputedStyleProperty object.";
            return DispatchResponse::ServerError(errorMessage);
        }

        Local<Array> computedStyleArr = computedStyleValue.As<Array>();
        protocol::Array<protocol::CSS::CSSComputedStyleProperty> computedStyles;

        for (uint32_t i = 0; i < computedStyleArr->Length(); i++) {
            Local<Value> element;
            bool success = computedStyleArr->Get(context, i).ToLocal(&element);
            if (!success) {
                std::string errorMessage = "Error while parsing CSSComputedStyleProperty object.";
                return DispatchResponse::ServerError(errorMessage);
            }

            Local<v8::String> resultString;
            assert(v8::JSON::Stringify(context, element).ToLocal(&resultString));

            String16 resultProtocolString = toProtocolString(isolate, resultString);
            std::vector<uint8_t> cbor;
            v8_crdtp::json::ConvertJSONToCBOR(v8_crdtp::span<uint16_t>(resultProtocolString.characters16(), resultProtocolString.length()), &cbor);

            auto status = protocol::CSS::CSSComputedStyleProperty::ReadFrom(cbor);
            if (!status.ok()) {
                std::string errorMessage = "Error while parsing CSSComputedStyleProperty object.";
                return DispatchResponse::ServerError(errorMessage);
            }

            computedStyles.push_back(std::move(*status));
        }

        auto result = std::make_unique<protocol::Array<protocol::CSS::CSSComputedStyleProperty>>(std::move(computedStyles));
        *out_computedStyle = std::move(result);
        return DispatchResponse::Success();
    }

    *out_computedStyle = std::move(computedStylePropertyArr);
    return DispatchResponse::Success();
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

    return DispatchResponse::Success();
}

DispatchResponse V8CSSAgentImpl::getStyleSheetText(const String& in_styleSheetId, String* out_text) {
    *out_text = "";

    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::addRule(const String& in_styleSheetId, const String& in_ruleText, std::unique_ptr<protocol::CSS::SourceRange> in_location, std::unique_ptr<protocol::CSS::CSSRule>* out_rule) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::collectClassNames(const String& in_styleSheetId, std::unique_ptr<protocol::Array<String>>* out_classNames) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::createStyleSheet(const String& in_frameId, String* out_styleSheetId) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::forcePseudoState(int in_nodeId, std::unique_ptr<protocol::Array<String>> in_forcedPseudoClasses) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::getBackgroundColors(int in_nodeId, Maybe<protocol::Array<String>>* out_backgroundColors, Maybe<String>* out_computedFontSize, Maybe<String>* out_computedFontWeight) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::getMediaQueries(std::unique_ptr<protocol::Array<protocol::CSS::CSSMedia>>* out_medias) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::setEffectivePropertyValueForNode(int in_nodeId, const String& in_propertyName, const String& in_value) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::setKeyframeKey(const String& in_styleSheetId, std::unique_ptr<protocol::CSS::SourceRange> in_range, const String& in_keyText, std::unique_ptr<protocol::CSS::Value>* out_keyText) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::setMediaText(const String& in_styleSheetId, std::unique_ptr<protocol::CSS::SourceRange> in_range, const String& in_text, std::unique_ptr<protocol::CSS::CSSMedia>* out_media) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::setRuleSelector(const String& in_styleSheetId, std::unique_ptr<protocol::CSS::SourceRange> in_range, const String& in_selector, std::unique_ptr<protocol::CSS::SelectorList>* out_selectorList) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::setStyleSheetText(const String& in_styleSheetId, const String& in_text, Maybe<String>* out_sourceMapURL) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::setStyleTexts(std::unique_ptr<protocol::Array<protocol::CSS::StyleDeclarationEdit>> in_edits, std::unique_ptr<protocol::Array<protocol::CSS::CSSStyle>>* out_styles) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::startRuleUsageTracking() {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::stopRuleUsageTracking(std::unique_ptr<protocol::Array<protocol::CSS::RuleUsage>>* out_ruleUsage) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

DispatchResponse V8CSSAgentImpl::takeCoverageDelta(std::unique_ptr<protocol::Array<protocol::CSS::RuleUsage>>* out_coverage) {
    return protocol::DispatchResponse::ServerError("Protocol command not supported.");
}

V8CSSAgentImpl* V8CSSAgentImpl::Instance = 0;

}
