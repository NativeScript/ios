#include "v8-network-agent-impl.h"
#include "../../third_party/inspector_protocol/crdtp/json.h"
#include "src/inspector/v8-inspector-session-impl.h"
#include "Helpers.h"
#include "utils.h"

using namespace v8;

namespace v8_inspector {

namespace NetworkAgentState {
    static const char networkEnabled[] = "networkEnabled";
}

V8NetworkAgentImpl::V8NetworkAgentImpl(V8InspectorSessionImpl* session, protocol::FrontendChannel* frontendChannel, protocol::DictionaryValue* state)
    : m_frontend(frontendChannel),
      m_state(state),
      m_inspector(session->inspector()),
      m_enabled(false) {
}

V8NetworkAgentImpl::~V8NetworkAgentImpl() {
}

DispatchResponse V8NetworkAgentImpl::enable(Maybe<int> in_maxTotalBufferSize, Maybe<int> in_maxResourceBufferSize, Maybe<int> in_maxPostDataSize) {
    if (m_enabled) {
        return DispatchResponse::OK();
    }

    m_state->setBoolean(NetworkAgentState::networkEnabled, true);

    m_enabled = true;

    return DispatchResponse::OK();
}

DispatchResponse V8NetworkAgentImpl::disable() {
    if (!m_enabled) {
        return DispatchResponse::OK();
    }

    m_state->setBoolean(NetworkAgentState::networkEnabled, false);

    m_enabled = false;

    return DispatchResponse::OK();
}

void V8NetworkAgentImpl::dispatch(std::string message) {
    Isolate* isolate = m_inspector->isolate();
    Local<Context> context = isolate->GetCurrentContext();
    Local<Value> value;
    assert(v8::JSON::Parse(context, tns::ToV8String(isolate, message)).ToLocal(&value) && value->IsObject());
    Local<Object> obj = value.As<Object>();
    std::string method = GetDomainMethod(isolate, obj, "Network.");

    if (method == "requestWillBeSent") {
        this->RequestWillBeSent(obj);
    } else if (method == "responseReceived") {
        this->ResponseReceived(obj);
    } else if (method == "loadingFinished") {
        this->LoadingFinished(obj);
    }
}

DispatchResponse V8NetworkAgentImpl::canClearBrowserCache(bool* out_result) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8NetworkAgentImpl::canClearBrowserCookies(bool* out_result) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8NetworkAgentImpl::emulateNetworkConditions(bool in_offline, double in_latency, double in_downloadThroughput, double in_uploadThroughput, Maybe<String> in_connectionType) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

void V8NetworkAgentImpl::getResponseBody(const String& in_requestId, std::unique_ptr<GetResponseBodyCallback> callback) {
    Isolate* isolate = m_inspector->isolate();
    Local<Object> networkDomainDebugger;
    Local<v8::Function> getResponseBodyFunc = GetDebuggerFunction(isolate, "Network", "getResponseBody", networkDomainDebugger);

    if (getResponseBodyFunc.IsEmpty() || networkDomainDebugger.IsEmpty()) {
        auto error = "Couldn't get response body. \"getResponseBody\" function not found";
        callback->sendFailure(DispatchResponse::Error(error));
        return;
    }

    Local<Context> context = isolate->GetCurrentContext();

    Local<Object> param = Object::New(isolate);
    bool success = param->Set(context, tns::ToV8String(isolate, "requestId"), tns::ToV8String(isolate, in_requestId.utf8())).FromMaybe(false);
    assert(success);

    Local<Value> args[] = { param };
    Local<Value> result;
    assert(getResponseBodyFunc->Call(context, networkDomainDebugger, 1, args).ToLocal(&result));

    TryCatch tc(isolate);
    if (tc.HasCaught() || result.IsEmpty() || !result->IsObject()) {
        String16 error = toProtocolString(isolate, tc.Message()->Get());
        callback->sendFailure(DispatchResponse::Error(error));
    }

    Local<Object> resultObj = result.As<Object>();
    Local<Value> bodyVal = resultObj->Get(context, tns::ToV8String(isolate, "body")).ToLocalChecked();
    Local<Value> base64EncodedVal = resultObj->Get(context, tns::ToV8String(isolate, "base64Encoded")).ToLocalChecked();

    String16 body = toProtocolString(isolate, bodyVal.As<v8::String>());
    bool base64Encoded = base64EncodedVal.As<v8::Boolean>()->Value();

    callback->sendSuccess(body, base64Encoded);
}

void V8NetworkAgentImpl::getRequestPostData(const String& in_requestId, std::unique_ptr<GetRequestPostDataCallback> callback) {
}

DispatchResponse V8NetworkAgentImpl::searchInResponseBody(const String& in_requestId, const String& in_query, Maybe<bool> in_caseSensitive, Maybe<bool> in_isRegex, std::unique_ptr<protocol::Array<protocol::Debugger::SearchMatch>>* out_result) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8NetworkAgentImpl::setBypassServiceWorker(bool in_bypass) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8NetworkAgentImpl::getCertificate(const String& in_origin, std::unique_ptr<protocol::Array<String>>* out_tableNames) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8NetworkAgentImpl::setCacheDisabled(bool in_cacheDisabled) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8NetworkAgentImpl::setDataSizeLimitsForTest(int in_maxTotalSize, int in_maxResourceSize) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8NetworkAgentImpl::replayXHR(const String& in_requestId) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8NetworkAgentImpl::setBlockedURLs(std::unique_ptr<protocol::Array<String>> in_urls) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

DispatchResponse V8NetworkAgentImpl::setExtraHTTPHeaders(std::unique_ptr<protocol::Network::Headers> in_headers) {
    return protocol::DispatchResponse::Error("Protocol command not supported.");
}

void V8NetworkAgentImpl::RequestWillBeSent(const Local<Object>& obj) {
    Isolate* isolate = m_inspector->isolate();
    Local<Context> context = isolate->GetCurrentContext();

    Local<Object> params = obj->Get(context, tns::ToV8String(isolate, "params")).ToLocalChecked().As<Object>();
    Local<v8::String> requestId = params->Get(context, tns::ToV8String(isolate, "requestId")).ToLocalChecked()->ToString(context).ToLocalChecked();
    Local<v8::String> url = params->Get(context, tns::ToV8String(isolate, "url")).ToLocalChecked()->ToString(context).ToLocalChecked();
    Local<Value> request = params->Get(context, tns::ToV8String(isolate, "request")).ToLocalChecked();
    long long timestamp = params->Get(context, tns::ToV8String(isolate, "timestamp")).ToLocalChecked()->ToNumber(context).ToLocalChecked()->IntegerValue(context).ToChecked();
    long long wallTime = 0;
    Local<v8::String> type = tns::ToV8String(isolate, "Document");
    if (params->Has(context, tns::ToV8String(isolate, "type")).FromMaybe(false)) {
        type = params->Get(context, tns::ToV8String(isolate, "type")).ToLocalChecked()->ToString(context).ToLocalChecked();
    }

    Local<Object> requestAsObj = request->ToObject(context).ToLocalChecked();
    Local<v8::String> initialPriorityProp = tns::ToV8String(isolate, "initialPriority");
    Local<v8::String> referrerPolicyProp = tns::ToV8String(isolate, "referrerPolicy");
    if (!requestAsObj->Has(context, initialPriorityProp).FromMaybe(false)) {
        assert(requestAsObj->Set(context, initialPriorityProp, tns::ToV8String(isolate, "Medium")).FromMaybe(false));
    }
    if (!requestAsObj->Has(context, referrerPolicyProp).FromMaybe(false)) {
        assert(requestAsObj->Set(context, referrerPolicyProp, tns::ToV8String(isolate, "no-referrer-when-downgrade")).FromMaybe(false));
    }

    assert(requestAsObj->Set(context, tns::ToV8String(isolate, "headers"), Object::New(isolate)).FromMaybe(false));

    Local<v8::String> requestJson;
    assert(JSON::Stringify(context, request).ToLocal(&requestJson));

    const String16& requestJsonString16 = toProtocolString(isolate, requestJson);
    std::vector<uint8_t> cbor;
    v8_crdtp::json::ConvertJSONToCBOR(v8_crdtp::span<uint16_t>(requestJsonString16.characters16(), requestJsonString16.length()), &cbor);
    std::unique_ptr<protocol::Value> protocolRequestJson = protocol::Value::parseBinary(cbor.data(), cbor.size());

    protocol::ErrorSupport errorSupport;
    auto protocolRequestObj = protocol::Network::Request::fromValue(protocolRequestJson.get(), &errorSupport);

    std::vector<uint8_t> json;
    v8_crdtp::json::ConvertCBORToJSON(errorSupport.Errors(), &json);
    auto errorString = String16(reinterpret_cast<const char*>(json.data()), json.size()).utf8();

    if (!errorString.empty()) {
        std::string errorMessage = "Error while parsing debug `request` object. ";
        Log("%s Error: %s", errorMessage.c_str(), errorString.c_str());
        return;
    }

    protocol::Maybe<String16> frameId("");
    protocol::Maybe<String16> typeArg(tns::ToString(isolate, type).c_str());
    protocol::Maybe<protocol::Network::Response> emptyRedirect;

    this->m_frontend.requestWillBeSent(
        tns::ToString(isolate, requestId).c_str(),
        "Loader Identifier",
        tns::ToString(isolate, url).c_str(),
        std::move(protocolRequestObj),
        timestamp,
        wallTime,
        protocol::Network::Initiator::create().setType(protocol::Network::Initiator::TypeEnum::Script).build(),
        std::move(emptyRedirect),
        std::move(typeArg),
        std::move(frameId)
    );
}

void V8NetworkAgentImpl::ResponseReceived(const Local<Object>& obj) {
    Isolate* isolate = m_inspector->isolate();
    Local<Context> context = isolate->GetCurrentContext();

    Local<Object> params = obj->Get(context, tns::ToV8String(isolate, "params")).ToLocalChecked().As<Object>();
    Local<v8::String> requestId = params->Get(context, tns::ToV8String(isolate, "requestId")).ToLocalChecked()->ToString(context).ToLocalChecked();
    Local<Value> response = params->Get(context, tns::ToV8String(isolate, "response")).ToLocalChecked();
    long long timestamp = params->Get(context, tns::ToV8String(isolate, "timestamp")).ToLocalChecked()->ToNumber(context).ToLocalChecked()->IntegerValue(context).ToChecked();
    Local<v8::String> type = tns::ToV8String(isolate, "Document");
    if (params->Has(context, tns::ToV8String(isolate, "type")).FromMaybe(false)) {
        type = params->Get(context, tns::ToV8String(isolate, "type")).ToLocalChecked()->ToString(context).ToLocalChecked();
    }

    Local<Object> responseAsObj = response->ToObject(context).ToLocalChecked();
    Local<v8::String> connectionReusedProp = tns::ToV8String(isolate, "connectionReused");
    if (!responseAsObj->Has(context, connectionReusedProp).FromMaybe(false)) {
        assert(responseAsObj->Set(context, connectionReusedProp, v8::Boolean::New(isolate, true)).FromMaybe(false));
    }
    Local<v8::String> connectionIdProp = tns::ToV8String(isolate, "connectionId");
    if (!responseAsObj->Has(context, connectionIdProp).FromMaybe(false)) {
        assert(responseAsObj->Set(context, connectionIdProp, v8::Number::New(isolate, 0)).FromMaybe(false));
    }
    Local<v8::String> encodedDataLengthProp = tns::ToV8String(isolate, "encodedDataLength");
    if (!responseAsObj->Has(context, encodedDataLengthProp).FromMaybe(false)) {
        assert(responseAsObj->Set(context, encodedDataLengthProp, v8::Number::New(isolate, 0)).FromMaybe(false));
    }
    Local<v8::String> securityStateProp = tns::ToV8String(isolate, "securityState");
    if (!responseAsObj->Has(context, securityStateProp).FromMaybe(false)) {
        assert(responseAsObj->Set(context, securityStateProp, tns::ToV8String(isolate, "info")).FromMaybe(false));
    }

    Local<v8::String> responseJson;
    assert(JSON::Stringify(context, response).ToLocal(&responseJson));

    const String16 responseJsonString = toProtocolString(isolate, responseJson);
    std::vector<uint8_t> cbor;
    v8_crdtp::json::ConvertJSONToCBOR(v8_crdtp::span<uint16_t>(responseJsonString.characters16(), responseJsonString.length()), &cbor);
    std::unique_ptr<protocol::Value> protocolResponseJson = protocol::Value::parseBinary(cbor.data(), cbor.size());

    protocol::ErrorSupport errorSupport;
    auto protocolResponseObj = protocol::Network::Response::fromValue(protocolResponseJson.get(), &errorSupport);

    std::vector<uint8_t> json;
    v8_crdtp::json::ConvertCBORToJSON(errorSupport.Errors(), &json);
    auto errorString = String16(reinterpret_cast<const char*>(json.data()), json.size()).utf8();

    if (!errorString.empty()) {
        std::string errorMessage = "Error while parsing debug `response` object.";
        Log("%s Error: %s", errorMessage.c_str(), errorString.c_str());
        return;
    }

    protocol::Maybe<String16> frameId("");
    protocol::Maybe<String16> typeArg(tns::ToString(isolate, type).c_str());
    protocol::Maybe<protocol::Network::Response> emptyRedirect;

    this->m_frontend.responseReceived(
        tns::ToString(isolate, requestId).c_str(),
        "Loader Identifier",
        timestamp,
        tns::ToString(isolate, type).c_str(),
        std::move(protocolResponseObj),
        std::move(frameId)
    );
}

void V8NetworkAgentImpl::LoadingFinished(const Local<Object>& obj) {
    Isolate* isolate = m_inspector->isolate();
    Local<Context> context = isolate->GetCurrentContext();

    Local<Object> params = obj->Get(context, tns::ToV8String(isolate, "params")).ToLocalChecked().As<Object>();
    Local<v8::String> requestId = params->Get(context, tns::ToV8String(isolate, "requestId")).ToLocalChecked()->ToString(context).ToLocalChecked();
    long long timestamp = params->Get(context, tns::ToV8String(isolate, "timestamp")).ToLocalChecked()->ToNumber(context).ToLocalChecked()->IntegerValue(context).ToChecked();

    long long int encodedDataLength = 0;
    Local<v8::String> encodedDataLengthProp = tns::ToV8String(isolate, "encodedDataLength");
    if (params->Has(context, encodedDataLengthProp).FromMaybe(true)) {
        encodedDataLength = params->Get(context, encodedDataLengthProp).ToLocalChecked()->ToNumber(context).ToLocalChecked()->IntegerValue(context).ToChecked();
    }

    this->m_frontend.loadingFinished(
        tns::ToString(isolate, requestId).c_str(),
        timestamp,
        encodedDataLength
    );
}

}
