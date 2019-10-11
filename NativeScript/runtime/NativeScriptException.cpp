#include "NativeScriptException.h"
#include "Helpers.h"
#include <sstream>

using namespace v8;

namespace tns {

NativeScriptException::NativeScriptException(const std::string& message) {
    this->javascriptException_ = nullptr;
    this->message_ = message;
}

NativeScriptException::NativeScriptException(Isolate* isolate, TryCatch& tc, const std::string& message) {
    Local<Value> error = tc.Exception();
    this->javascriptException_ = new Persistent<Value>(isolate, tc.Exception());
    this->message_ = GetErrorMessage(isolate, error, message);
    this->stackTrace_ = GetErrorStackTrace(isolate, tc.Message()->GetStackTrace());
    this->fullMessage_ = GetFullMessage(isolate, tc, this->message_);
    tc.Reset();
}

void NativeScriptException::OnUncaughtError(Local<Message> message, Local<Value> error) {
    Isolate* isolate = message->GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> global = context->Global();
    Local<Value> handler;
    bool success = global->Get(context, tns::ToV8String(isolate, "__onUncaughtError")).ToLocal(&handler);

    if (success && handler->IsFunction()) {
        std::string stackTrace = GetErrorStackTrace(isolate, message->GetStackTrace());
        if (error->IsObject()) {
            assert(error.As<Object>()->Set(context, tns::ToV8String(isolate, "stackTrace"), tns::ToV8String(isolate, stackTrace)).FromMaybe(false));
        }

        Local<v8::Function> errorHandlerFunc = handler.As<v8::Function>();
        Local<Object> thiz = Object::New(isolate);
        Local<Value> args[] = { error };
        Local<Value> result;
        success = errorHandlerFunc->Call(context, thiz, 1, args).ToLocal(&result);
        assert(success);
    }
}

void NativeScriptException::ReThrowToV8(Isolate* isolate) {
    // The Isolate::Scope here is necessary because the Exception::Error method internally relies on the
    // Isolate::GetCurrent method which might return null if we do not use the proper scope
    Isolate::Scope scope(isolate);

    Local<Context> context = isolate->GetCurrentContext();
    Local<Value> errObj;

    if (this->javascriptException_ != nullptr) {
        errObj = this->javascriptException_->Get(isolate);
        if (errObj->IsObject()) {
            if (!this->fullMessage_.empty()) {
                assert(errObj.As<Object>()->Set(context, tns::ToV8String(isolate, "fullMessage"), tns::ToV8String(isolate, this->fullMessage_)).FromMaybe(false));
            } else if (!this->message_.empty()) {
                assert(errObj.As<Object>()->Set(context, tns::ToV8String(isolate, "fullMessage"), tns::ToV8String(isolate, this->message_)).FromMaybe(false));
            }
        }
    } else if (!this->fullMessage_.empty()) {
        errObj = Exception::Error(tns::ToV8String(isolate, this->fullMessage_));
    } else if (!this->message_.empty()) {
        errObj = Exception::Error(tns::ToV8String(isolate, this->message_));
    } else {
        errObj = Exception::Error(tns::ToV8String(isolate, "No javascript exception or message provided."));
    }

    isolate->ThrowException(errObj);
}

std::string NativeScriptException::GetErrorMessage(Isolate* isolate, Local<Value>& error, const std::string& prependMessage) {
    Local<Context> context = isolate->GetEnteredOrMicrotaskContext();

    // get whole error message from previous stack
    std::stringstream ss;

    if (prependMessage != "") {
        ss << prependMessage << std::endl;
    }

    std::string errMessage;
    bool hasFullErrorMessage = false;
    auto v8FullMessage = tns::ToV8String(isolate, "fullMessage");
    if (error->IsObject() && error.As<Object>()->Has(context, v8FullMessage).ToChecked()) {
        hasFullErrorMessage = true;
        Local<Value> errMsgVal;
        bool success = error.As<Object>()->Get(context, v8FullMessage).ToLocal(&errMsgVal);
        assert(success);
        if (!errMsgVal.IsEmpty()) {
            errMessage = tns::ToString(isolate, errMsgVal.As<v8::String>());
        } else {
            errMessage = "";
        }
        ss << errMessage;
    }

    MaybeLocal<v8::String> str = error->ToDetailString(context);
    if (!str.IsEmpty()) {
        v8::String::Utf8Value utfError(isolate, str.FromMaybe(Local<v8::String>()));
        if (hasFullErrorMessage) {
            ss << std::endl;
        }
        ss << *utfError;
    }

    return ss.str();
}

std::string NativeScriptException::GetErrorStackTrace(Isolate* isolate, const Local<StackTrace>& stackTrace) {
    if (stackTrace.IsEmpty()) {
        return "";
    }

    std::stringstream ss;

    HandleScope handleScope(isolate);

    int frameCount = stackTrace->GetFrameCount();

    for (int i = 0; i < frameCount; i++) {
        Local<StackFrame> frame = stackTrace->GetFrame(isolate, i);
        std::string funcName = tns::ToString(isolate, frame->GetFunctionName());
        std::string srcName = tns::ToString(isolate, frame->GetScriptName());
        int lineNumber = frame->GetLineNumber();
        int column = frame->GetColumn();

        ss << "\t" << (i > 0 ? "at " : "") << funcName.c_str() << "(" << srcName.c_str() << ":" << lineNumber << ":" << column << ")" << std::endl;
    }

    return ss.str();
}

std::string NativeScriptException::GetFullMessage(Isolate* isolate, const TryCatch& tc, const std::string& jsExceptionMessage) {
    Local<Context> context = isolate->GetEnteredOrMicrotaskContext();

    Local<Message> message = tc.Message();

    std::stringstream ss;
    ss << jsExceptionMessage;

    //get script name
    Local<Value> scriptResName = message->GetScriptResourceName();

    //get stack trace
    std::string stackTraceMessage = GetErrorStackTrace(isolate, message->GetStackTrace());

    if (!scriptResName.IsEmpty() && scriptResName->IsString()) {
        ss << std::endl <<"File: (" << tns::ToString(isolate, scriptResName.As<v8::String>());
    } else {
        ss << std::endl <<"File: (<unknown>";
    }
    ss << ":" << message->GetLineNumber(context).ToChecked() << ":" << message->GetStartColumn() << ")" << std::endl << std::endl;
    ss << "StackTrace: " << std::endl << stackTraceMessage << std::endl;

    std::string loggedMessage = ss.str();

    // TODO: Log the error
    // tns::LogError(isolate, tc);

    if (!tc.CanContinue()) {
        std::stringstream errM;
        errM << std::endl << "An uncaught error has occurred and V8's TryCatch block CAN'T be continued. ";
        loggedMessage = errM.str() + loggedMessage;
    }

    return loggedMessage;
}

}
