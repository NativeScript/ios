#include "NativeScriptException.h"
#include "Runtime.h"
#include "Helpers.h"
#include "Caches.h"
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
    id value = Runtime::GetAppConfigValue("discardUncaughtJsExceptions");
    bool isDiscarded = value ? [value boolValue] : false;

    std::string cbName = isDiscarded ? "__onDiscardedError" : "__onUncaughtError";
    bool success = global->Get(context, tns::ToV8String(isolate, cbName)).ToLocal(&handler);

    std::string stackTrace = GetErrorStackTrace(isolate, message->GetStackTrace());
    if (success && handler->IsFunction()) {
        if (error->IsObject()) {
            tns::Assert(error.As<Object>()->Set(context, tns::ToV8String(isolate, "stackTrace"), tns::ToV8String(isolate, stackTrace)).FromMaybe(false), isolate);
        }

        Local<v8::Function> errorHandlerFunc = handler.As<v8::Function>();
        Local<Object> thiz = Object::New(isolate);
        Local<Value> args[] = { error };
        Local<Value> result;
        TryCatch tc(isolate);
        success = errorHandlerFunc->Call(context, thiz, 1, args).ToLocal(&result);
        if (tc.HasCaught()) {
            tns::LogError(isolate, tc);
        }

        tns::Assert(success, isolate);
    }

    if (!isDiscarded) {
        Local<v8::String> messageV8String = message->Get();
        std::string messageString = tns::ToString(isolate, messageV8String);
        NSString* name = [NSString stringWithFormat:@"NativeScript encountered a fatal error: %s\n at \n%s", messageString.c_str(), stackTrace.c_str()];
        // we throw the exception on main thread
        // otherwise it seems that when getting NSException info from NSSetUncaughtExceptionHandler
        // we are missing almost all data. No explanation for why yet
        dispatch_async(dispatch_get_main_queue(), ^(void) {
          NSException* objcException = [NSException exceptionWithName:name reason:nil userInfo:@{ @"sender": @"onUncaughtError" }];

          NSLog(@"***** Fatal JavaScript exception - application has been terminated. *****\n");
          NSLog(@"%@", [objcException description]);
          @throw objcException;
        });
    } else {
        NSLog(@"NativeScript discarding uncaught JS exception!");
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
                tns::Assert(errObj.As<Object>()->Set(context, tns::ToV8String(isolate, "fullMessage"), tns::ToV8String(isolate, this->fullMessage_)).FromMaybe(false), isolate);
            } else if (!this->message_.empty()) {
                tns::Assert(errObj.As<Object>()->Set(context, tns::ToV8String(isolate, "fullMessage"), tns::ToV8String(isolate, this->message_)).FromMaybe(false), isolate);
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
    std::shared_ptr<Caches> cache = Caches::Get(isolate);
    Local<Context> context = cache->GetContext();

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
        tns::Assert(success, isolate);
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

    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);

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
