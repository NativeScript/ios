#include <Foundation/Foundation.h>
#include <notify.h>
#include <chrono>
#include "JsV8InspectorClient.h"
#include "InspectorServer.h"
#include "include/libplatform/libplatform.h"
#include "src/inspector/v8-log-agent-impl.h"
#include "Helpers.h"
#include "utils.h"

using namespace v8;

namespace v8_inspector {

#define NOTIFICATION(name)                                                      \
[[NSString stringWithFormat:@"%@:NativeScript.Debug.%s",                        \
    [[NSBundle mainBundle] bundleIdentifier], name] UTF8String]

#define LOG_DEBUGGER_PORT(port) NSLog(@"NativeScript debugger has opened inspector socket on port %d for %@.", port, [[NSBundle mainBundle] bundleIdentifier])

void JsV8InspectorClient::enableInspector(int argc, char** argv) {
    int waitForDebuggerSubscription;
    notify_register_dispatch(NOTIFICATION("WaitForDebugger"), &waitForDebuggerSubscription, dispatch_get_main_queue(), ^(int token) {
        this->isWaitingForDebugger_ = YES;

        dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 30);
        dispatch_after(delay, dispatch_get_main_queue(), ^{
            if (this->isWaitingForDebugger_) {
                this->isWaitingForDebugger_ = NO;
                NSLog(@"NativeScript waiting for debugger timeout elapsed. Continuing execution.");
            }
        });

        NSLog(@"NativeScript waiting for debugger.");
        CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopDefaultMode, ^{
            do {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
            } while (this->isWaitingForDebugger_);
        });
        CFRunLoopWakeUp(CFRunLoopGetMain());
    });

    int attachRequestSubscription;
    notify_register_dispatch(NOTIFICATION("AttachRequest"), &attachRequestSubscription, dispatch_get_main_queue(), ^(int token) {
        in_port_t listenPort = InspectorServer::Init([this](std::function<void (std::string)> sender) {
            this->onFrontendConnected(sender);
        }, [this](std::string message) {
            this->onFrontendMessageReceived(message);
        });

        LOG_DEBUGGER_PORT(listenPort);
        notify_post(NOTIFICATION("ReadyForAttach"));
    });

    notify_post(NOTIFICATION("AppLaunching"));

    for (int i = 1; i < argc; i++) {
        BOOL startListening = NO;
        BOOL shouldWaitForDebugger = NO;

        if (strcmp(argv[i], "--nativescript-debug-brk") == 0) {
            shouldWaitForDebugger = YES;
        } else if (strcmp(argv[i], "--nativescript-debug-start") == 0) {
            startListening = YES;
        }

        if (startListening || shouldWaitForDebugger) {
            notify_post(NOTIFICATION("AttachRequest"));
            if (shouldWaitForDebugger) {
                notify_post(NOTIFICATION("WaitForDebugger"));
            }

            break;
        }
    }

    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);
    notify_cancel(waitForDebuggerSubscription);
}

JsV8InspectorClient::JsV8InspectorClient(tns::Runtime* runtime)
    : runtime_(runtime),
      messages_(),
      runningNestedLoops_(false) {
     this->messagesQueue_ = dispatch_queue_create("NativeScript.v8.inspector.message_queue", DISPATCH_QUEUE_SERIAL);
     this->messageLoopQueue_ = dispatch_queue_create("NativeScript.v8.inspector.message_loop_queue", DISPATCH_QUEUE_SERIAL);
     this->messageArrived_ = dispatch_semaphore_create(0);
}

void JsV8InspectorClient::onFrontendConnected(std::function<void (std::string)> sender) {
    if (this->isWaitingForDebugger_) {
        this->isWaitingForDebugger_ = NO;
        CFRunLoopRef runloop = CFRunLoopGetMain();
        CFRunLoopPerformBlock(runloop, (__bridge CFTypeRef)(NSRunLoopCommonModes), ^{
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1, false);
            this->scheduleBreak();
        });
        CFRunLoopWakeUp(runloop);
    }

    this->sender_ = sender;
    this->disconnect();
}

void JsV8InspectorClient::onFrontendMessageReceived(std::string message) {
    dispatch_sync(this->messagesQueue_, ^{
        this->messages_.push_back(message);
        dispatch_semaphore_signal(messageArrived_);
    });

    tns::ExecuteOnMainThread([this, message]() {
        dispatch_sync(this->messageLoopQueue_, ^{
            // prevent execution if we're already pumping messages
            if (runningNestedLoops_ && !terminated_) {
                return;
            };
            std::string message;
            do {
                message = this->PumpMessage();
                if (!message.empty()) {
                    this->dispatchMessage(message);
                }
            } while (!message.empty());
        });

    });
}

void JsV8InspectorClient::init() {
    if (inspector_ != nullptr) {
        return;
    }

    Isolate* isolate = runtime_->GetIsolate();

    Local<Context> context = isolate->GetEnteredOrMicrotaskContext();

    inspector_ = V8Inspector::create(isolate, this);

    inspector_->contextCreated(v8_inspector::V8ContextInfo(context, JsV8InspectorClient::contextGroupId, v8_inspector::StringView()));

    context_.Reset(isolate, context);

    this->createInspectorSession();
}

void JsV8InspectorClient::connect(int argc, char** argv) {
    this->isConnected_ = true;
    this->enableInspector(argc, argv);
}

void JsV8InspectorClient::createInspectorSession() {
    this->session_ = this->inspector_->connect(JsV8InspectorClient::contextGroupId, this, v8_inspector::StringView());
}

void JsV8InspectorClient::disconnect() {
    Isolate* isolate = runtime_->GetIsolate();
    v8::Locker locker(isolate);
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);

    session_->resume();
    session_.reset();

    this->isConnected_ = false;

    this->createInspectorSession();
}

void JsV8InspectorClient::runMessageLoopOnPause(int contextGroupId) {
    __block auto loopsRunning = false;
    dispatch_sync(this->messageLoopQueue_, ^{
        loopsRunning = runningNestedLoops_;
        terminated_ = false;
        if (runningNestedLoops_) {
            return;
        }
        this->runningNestedLoops_ = true;
    });
    
    if (loopsRunning) {
        return;
    }
    
    bool shouldWait = false;
    while (!terminated_) {
        std::string message = this->PumpMessage();
        if (!message.empty()) {
            this->dispatchMessage(message);
            shouldWait = false;
        } else {
            shouldWait = true;
        }

        std::shared_ptr<Platform> platform = tns::Runtime::GetPlatform();
        Isolate* isolate = runtime_->GetIsolate();
        platform::PumpMessageLoop(platform.get(), isolate, platform::MessageLoopBehavior::kDoNotWait);
        if(shouldWait && !terminated_) {
            dispatch_semaphore_wait(messageArrived_, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_MSEC)); // 1ms
        }
    }
    
    dispatch_sync(this->messageLoopQueue_, ^{
        terminated_ = false;
        runningNestedLoops_ = false;
    });
}

void JsV8InspectorClient::quitMessageLoopOnPause() {
    dispatch_sync(this->messageLoopQueue_, ^{
        terminated_ = true;
    });
}

void JsV8InspectorClient::sendResponse(int callId, std::unique_ptr<StringBuffer> message) {
    this->notify(std::move(message));
}

void JsV8InspectorClient::sendNotification(std::unique_ptr<StringBuffer> message) {
    this->notify(std::move(message));
}

void JsV8InspectorClient::flushProtocolNotifications() {
}

void JsV8InspectorClient::notify(std::unique_ptr<StringBuffer> message) {
    StringView stringView = message->string();
    std::string value = ToStdString(stringView);

    if (this->sender_) {
        this->sender_(value);
    }
}

void JsV8InspectorClient::dispatchMessage(const std::string& message) {
    std::vector<uint16_t> vector = tns::ToVector(message);
    StringView messageView(vector.data(), vector.size());
    Isolate* isolate = this->runtime_->GetIsolate();
    v8::Locker locker(isolate);
    this->session_->dispatchProtocolMessage(messageView);
}

Local<Context> JsV8InspectorClient::ensureDefaultContextInGroup(int contextGroupId) {
    Isolate* isolate = runtime_->GetIsolate();
    Local<Context> context = PersistentToLocal(isolate, context_);
    return context;
}

std::string JsV8InspectorClient::PumpMessage() {
    __block std::string result;
    dispatch_sync(this->messagesQueue_, ^{
        if (this->messages_.size() > 0) {
            result = this->messages_.back();
            this->messages_.pop_back();
        }
    });

    return result;
}

template<class TypeName>
inline Local<TypeName> StrongPersistentToLocal(const Persistent<TypeName>& persistent) {
    return *reinterpret_cast<Local<TypeName> *>(const_cast<Persistent<TypeName> *>(&persistent));
}

template<class TypeName>
inline Local<TypeName> WeakPersistentToLocal(Isolate* isolate, const Persistent<TypeName>& persistent) {
    return Local<TypeName>::New(isolate, persistent);
}

template<class TypeName>
inline Local<TypeName> JsV8InspectorClient::PersistentToLocal(Isolate* isolate, const Persistent<TypeName>& persistent) {
    if (persistent.IsWeak()) {
        return WeakPersistentToLocal(isolate, persistent);
    } else {
        return StrongPersistentToLocal(persistent);
    }
}

void JsV8InspectorClient::scheduleBreak() {
    Isolate* isolate = runtime_->GetIsolate();
    v8::Locker locker(isolate);
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);
    this->session_->schedulePauseOnNextStatement(StringView(), StringView());
}

void JsV8InspectorClient::registerModules() {
    Isolate* isolate = runtime_->GetIsolate();
    Local<Context> context = isolate->GetEnteredOrMicrotaskContext();
    Local<Object> global = context->Global();
    Local<Object> inspectorObject = Object::New(isolate);

    assert(global->Set(context, tns::ToV8String(isolate, "__inspector"), inspectorObject).FromMaybe(false));
    Local<v8::Function> func;
    bool success = v8::Function::New(context, registerDomainDispatcherCallback).ToLocal(&func);
    assert(success && global->Set(context, tns::ToV8String(isolate, "__registerDomainDispatcher"), func).FromMaybe(false));

    Local<External> data = External::New(isolate, this);
    success = v8::Function::New(context, inspectorSendEventCallback, data).ToLocal(&func);
    assert(success && global->Set(context, tns::ToV8String(isolate, "__inspectorSendEvent"), func).FromMaybe(false));

    success = v8::Function::New(context, inspectorTimestampCallback).ToLocal(&func);
    assert(success && global->Set(context, tns::ToV8String(isolate, "__inspectorTimestamp"), func).FromMaybe(false));

    {
        v8::Locker locker(isolate);
        TryCatch tc(isolate);
        runtime_->RunModule("inspector_modules");
    }
}

void JsV8InspectorClient::registerDomainDispatcherCallback(const FunctionCallbackInfo<Value>& args) {
    Isolate* isolate = args.GetIsolate();
    std::string domain = tns::ToString(isolate, args[0].As<v8::String>());
    auto it = Domains.find(domain);
    if (it == Domains.end()) {
        Local<v8::Function> domainCtorFunc = args[1].As<v8::Function>();
        Local<Context> context = isolate->GetCurrentContext();
        Local<Value> ctorArgs[0];
        Local<Value> domainInstance;
        bool success = domainCtorFunc->CallAsConstructor(context, 0, ctorArgs).ToLocal(&domainInstance);
        assert(success && domainInstance->IsObject());

        Local<Object> domainObj = domainInstance.As<Object>();
        Persistent<Object>* poDomainObj = new Persistent<Object>(isolate, domainObj);
        Domains.emplace(domain, poDomainObj);
    }
}

void JsV8InspectorClient::inspectorTimestampCallback(const FunctionCallbackInfo<Value>& args) {
    double timestamp = std::chrono::seconds(std::chrono::seconds(std::time(NULL))).count();
    args.GetReturnValue().Set(timestamp);
}

int JsV8InspectorClient::contextGroupId = 1;
std::map<std::string, Persistent<Object>*> JsV8InspectorClient::Domains;

}
