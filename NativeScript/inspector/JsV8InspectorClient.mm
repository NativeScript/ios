#include <Foundation/Foundation.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <chrono>
#include "JsV8InspectorClient.h"
#include "src/inspector/v8-inspector-session-impl.h"
#include "src/inspector/v8-log-agent-impl.h"
#include "Helpers.h"
#include "utils.h"

using namespace v8;

namespace v8_inspector {

typedef void (^TNSInspectorProtocolHandler)(NSString* message, NSError* error);
typedef void (^TNSInspectorSendMessageBlock)(NSString* message);
typedef TNSInspectorProtocolHandler (^TNSInspectorFrontendConnectedHandler)(TNSInspectorSendMessageBlock sendMessageToFrontend, NSError* error, dispatch_io_t io);
typedef void (^TNSInspectorIoErrorHandler)(NSObject* dummy /*make compatible with CheckError macro*/, NSError* error);

id inspectorLock() {
    static dispatch_once_t once;
    static id lock;
    dispatch_once(&once, ^{
        lock = [[NSObject alloc] init];
    });
    return lock;
}
static int currentInspectorPort = 0;
static dispatch_io_t inspector_io = nil;
static TNSInspectorSendMessageBlock globalSendMessageToFrontend = nullptr;

#define CheckError(retval, handler)                                  \
({                                                                   \
int errorCode = (int)retval;                                         \
BOOL success = NO;                                                   \
if (errorCode == 0)                                                  \
success = YES;                                                       \
else if (errorCode == -1)                                            \
errorCode = errno;                                                   \
if (!success)                                                        \
handler(nil, [NSError errorWithDomain:NSPOSIXErrorDomain             \
code:errorCode                                                       \
userInfo:nil]);                                                      \
success;                                                             \
})

static dispatch_source_t createInspectorServer(TNSInspectorFrontendConnectedHandler connectedHandler, TNSInspectorIoErrorHandler ioErrorHandler, dispatch_block_t clearInspector) {
    dispatch_queue_t queue = dispatch_get_global_queue(0, 0);

    dispatch_fd_t listenSocket = socket(PF_INET, SOCK_STREAM, 0);
    int so_reuseaddr = 1;
    setsockopt(listenSocket, SOL_SOCKET, SO_REUSEADDR, &so_reuseaddr, sizeof(so_reuseaddr));
    struct sockaddr_in addr = {
        sizeof(addr), AF_INET, htons(18183), { INADDR_ANY }, { 0 }
    };

    // Adapter block for CheckError macro
    TNSInspectorProtocolHandler (^connectedErrorHandler)(TNSInspectorSendMessageBlock, NSError*) = ^(TNSInspectorSendMessageBlock sendMessage, NSError* error) {
        return connectedHandler(sendMessage, error, nil);
    };

    if (bind(listenSocket, (const struct sockaddr*)&addr, sizeof(addr)) != 0) {

        // Try getting a random port if the default one is unavailable
        addr.sin_port = htons(0);

        if (!CheckError(bind(listenSocket, (const struct sockaddr*)&addr, sizeof(addr)), connectedErrorHandler)) {
            return nil;
        }
    }

    if (!CheckError(listen(listenSocket, 0), connectedErrorHandler)) {
        return nil;
    }

    // read actually allocated listening port
    socklen_t len = sizeof(addr);
    if (!CheckError(getsockname(listenSocket, (struct sockaddr*)&addr, &len), connectedErrorHandler)) {
        return nil;
    }

    currentInspectorPort = ntohs(addr.sin_port);

    __block dispatch_source_t listenSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, listenSocket, 0, queue);

    dispatch_source_set_event_handler(listenSource, ^{
        // Only one connection is supported at a time. Discard previous inspector.
        clearInspector();

        __block dispatch_fd_t newSocket = accept(listenSocket, NULL, NULL);

        __block dispatch_io_t io = 0;
        __block TNSInspectorProtocolHandler protocolHandler = nil;
        __block TNSInspectorIoErrorHandler dataSocketErrorHandler = ^(NSObject* dummy, NSError* error) {
            @synchronized(inspectorLock()) {
                if (io) {
                    dispatch_io_close(io, DISPATCH_IO_STOP);
                    io = 0;
                }
            }

            if (newSocket) {
                close(newSocket);
                newSocket = 0;
            }

            if (protocolHandler) {
                protocolHandler(nil, error);
            }

            if (ioErrorHandler) {
                ioErrorHandler(nil, error);
            }
        };

        @synchronized(inspectorLock()) {
            io = dispatch_io_create(DISPATCH_IO_STREAM, newSocket, queue, ^(int error) {
                CheckError(error, dataSocketErrorHandler);
            });
        }

        TNSInspectorSendMessageBlock sender = ^(NSString* message) {
            // NSLog(@"NativeScript debugger sending: %@", message);
            NSUInteger length = [message lengthOfBytesUsingEncoding:NSUTF16LittleEndianStringEncoding];

            uint8_t* buffer = (uint8_t*)malloc(length + sizeof(uint32_t));

            *(uint32_t*)buffer = htonl(length);

            [message getBytes:&buffer[sizeof(uint32_t)]
                    maxLength:length
                   usedLength:NULL
                     encoding:NSUTF16LittleEndianStringEncoding
                      options:0
                        range:NSMakeRange(0, message.length)
               remainingRange:NULL];

            dispatch_data_t data = dispatch_data_create(buffer, length + sizeof(uint32_t), queue, ^{
                free(buffer);
            });

            @synchronized(inspectorLock()) {
                if (io) {
                    dispatch_io_write(io, 0, data, queue, ^(bool done, dispatch_data_t data, int error) {
                        CheckError(error, dataSocketErrorHandler);
                    });
                }
            }
        };

        protocolHandler = connectedHandler(sender, nil, io);
        if (!protocolHandler) {
            dataSocketErrorHandler(nil, nil);
            return;
        }

        __block dispatch_io_handler_t receiver = ^(bool done, dispatch_data_t data, int error) {
            if (!CheckError(error, dataSocketErrorHandler)) {
                return;
            }

            const void* bytes = [(NSData*)data bytes];
            if (!bytes) {
                dataSocketErrorHandler(nil, nil);
                return;
            }

            uint32_t length = ntohl(*(uint32_t*)bytes);
            @synchronized(inspectorLock()) {
                if (io) {
                    dispatch_io_set_low_water(io, length);
                    dispatch_io_read(io, 0, length, queue, ^(bool done, dispatch_data_t data, int error) {
                         if (!CheckError(error, dataSocketErrorHandler)) {
                             return;
                         }

                         NSString* payload = [[NSString alloc] initWithData:(NSData*)data encoding:NSUTF16LittleEndianStringEncoding];
                         protocolHandler(payload, nil);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
                         @synchronized(inspectorLock()) {
                             if (io) {
                                 dispatch_io_read(io, 0, 4, queue, receiver);
                             }
                         }
#pragma clang diagnostic pop
                     });
                }
            }
        };

        @synchronized(inspectorLock()) {
            if (io) {
                dispatch_io_read(io, 0, 4, queue, receiver);
            }
        }
    });

    dispatch_source_set_cancel_handler(listenSource, ^{
        listenSource = nil;
        close(listenSocket);
    });
    dispatch_resume(listenSource);

    return listenSource;
}

void JsV8InspectorClient::enableInspector() {
    __block dispatch_source_t listenSource = nil;
    __block dispatch_io_t current_connection_inspector_io = nil;

    dispatch_block_t clearInspector = ^{
        @synchronized(inspectorLock()) {
            if (inspector_io && current_connection_inspector_io != nil && current_connection_inspector_io == inspector_io) {
                dispatch_io_close(inspector_io, DISPATCH_IO_STOP);
                inspector_io = nil;
            }
        }
    };

    dispatch_block_t clear = ^{
        if (listenSource) {
            NSLog(@"NativeScript debugger closing inspector port.");
            dispatch_source_cancel(listenSource);
            listenSource = nil;
        }

        clearInspector();
    };

    TNSInspectorFrontendConnectedHandler connectionHandler = ^TNSInspectorProtocolHandler(TNSInspectorSendMessageBlock sendMessageToFrontend, NSError* error, dispatch_io_t io) {
        if (error) {
            if (listenSource) {
                clear();
            }

            NSLog(@"NativeScript debugger encountered %@.", error);
            return nil;
        }

        globalSendMessageToFrontend = sendMessageToFrontend;

        @synchronized(inspectorLock()) {
            inspector_io = io;
            current_connection_inspector_io = io;
        }

       return ^(NSString* message, NSError* error) {
           tns::ExecuteOnMainThread([this, message]() {
               if (message) {
                   std::string msg = [message UTF8String];
                   this->dispatchMessage(msg);
               }
           });
       };
    };

    TNSInspectorIoErrorHandler ioErrorHandler = ^(NSObject* dummy, NSError* error) {
        clearInspector();
        if (error) {
            NSLog(@"NativeScript debugger encountered %@.", error);
        }
    };

    listenSource = createInspectorServer(connectionHandler, ioErrorHandler, clearInspector);

    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);
}

JsV8InspectorClient::JsV8InspectorClient(Isolate* isolate, std::string baseDir)
    : baseDir_(baseDir),
    isolate_(isolate) {
}

void JsV8InspectorClient::init() {
    if (inspector_ != nullptr) {
        return;
    }

    v8::HandleScope handle_scope(isolate_);

    v8::Local<Context> context = isolate_->GetCurrentContext();

    inspector_ = V8Inspector::create(isolate_, this);

    inspector_->contextCreated(v8_inspector::V8ContextInfo(context, JsV8InspectorClient::contextGroupId, v8_inspector::StringView()));

    v8::Persistent<v8::Context> persistentContext(context->GetIsolate(), JsV8InspectorClient::PersistentToLocal(isolate_, context_));
    context_.Reset(isolate_, persistentContext);

    this->createInspectorSession();
}

void JsV8InspectorClient::connect() {
    this->isConnected_ = true;
    this->enableInspector();
}

void JsV8InspectorClient::createInspectorSession() {
    std::vector<uint16_t> vector = tns::ToVector("{\"baseDir\":\"" + baseDir_ + "\"}");
    StringView state(vector.data(), vector.size());
    this->session_ = this->inspector_->connect(JsV8InspectorClient::contextGroupId, this, state);
}

void JsV8InspectorClient::disconnect() {
    v8::HandleScope handleScope(isolate_);

    session_->resume();
    session_.reset();

    this->isConnected_ = false;

    this->createInspectorSession();
}

void JsV8InspectorClient::runMessageLoopOnPause(int contextGroupId) {
    terminated_ = false;
}

void JsV8InspectorClient::quitMessageLoopOnPause() {
    terminated_ = true;
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
    NSString* str = [NSString stringWithUTF8String:value.c_str()];

    if (globalSendMessageToFrontend) {
        globalSendMessageToFrontend(str);
    }
}

void JsV8InspectorClient::dispatchMessage(const std::string& message) {
    std::vector<uint16_t> vector = tns::ToVector(message);
    StringView messageView(vector.data(), vector.size());
    this->session_->dispatchProtocolMessage(messageView);
}

Local<Context> JsV8InspectorClient::ensureDefaultContextInGroup(int contextGroupId) {
    v8::Local<v8::Context> context = PersistentToLocal(isolate_, context_);
    return context;
}

template<class TypeName>
inline v8::Local<TypeName> StrongPersistentToLocal(const v8::Persistent<TypeName>& persistent) {
    return *reinterpret_cast<v8::Local<TypeName> *>(const_cast<v8::Persistent<TypeName> *>(&persistent));
}

template<class TypeName>
inline v8::Local<TypeName> WeakPersistentToLocal(v8::Isolate* isolate, const v8::Persistent<TypeName>& persistent) {
    return v8::Local<TypeName>::New(isolate, persistent);
}

template<class TypeName>
inline v8::Local<TypeName> JsV8InspectorClient::PersistentToLocal(v8::Isolate* isolate, const v8::Persistent<TypeName>& persistent) {
    if (persistent.IsWeak()) {
        return WeakPersistentToLocal(isolate, persistent);
    } else {
        return StrongPersistentToLocal(persistent);
    }
}

void JsV8InspectorClient::registerModules(std::function<void(v8::Isolate*, std::string)> runModule) {
    HandleScope scope(isolate_);
    Local<Context> context = isolate_->GetCurrentContext();
    Local<Object> global = context->Global();
    Local<Object> inspectorObject = Object::New(isolate_);

    assert(global->Set(context, tns::ToV8String(isolate_, "__inspector"), inspectorObject).FromMaybe(false));
    v8::Local<v8::Function> func;
    bool success = v8::Function::New(context, registerDomainDispatcherCallback).ToLocal(&func);
    assert(success && global->Set(context, tns::ToV8String(isolate_, "__registerDomainDispatcher"), func).FromMaybe(false));

    Local<External> data = External::New(isolate_, this);
    success = v8::Function::New(context, inspectorSendEventCallback, data).ToLocal(&func);
    assert(success && global->Set(context, tns::ToV8String(isolate_, "__inspectorSendEvent"), func).FromMaybe(false));

    success = v8::Function::New(context, inspectorTimestampCallback).ToLocal(&func);
    assert(success && global->Set(context, tns::ToV8String(isolate_, "__inspectorTimestamp"), func).FromMaybe(false));

    runModule(isolate_, "inspector_modules");
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

void JsV8InspectorClient::inspectorSendEventCallback(const FunctionCallbackInfo<Value>& args) {
    Local<External> data = args.Data().As<External>();
    v8_inspector::JsV8InspectorClient* client = static_cast<v8_inspector::JsV8InspectorClient*>(data->Value());
    Isolate* isolate = args.GetIsolate();
    Local<v8::String> arg = args[0].As<v8::String>();
    std::string message = tns::ToString(isolate, arg);

    if (message.find("\"Network.") != std::string::npos) {
        // The Network domain is handled directly by the corresponding backend
        V8InspectorSessionImpl* session = (V8InspectorSessionImpl*)client->session_.get();
        session->networkArgent()->dispatch(message);
        return;
    }

    client->dispatchMessage(message);
}

void JsV8InspectorClient::inspectorTimestampCallback(const v8::FunctionCallbackInfo<v8::Value>& args) {
    Isolate* isolate = args.GetIsolate();
    double timestamp = std::chrono::seconds(std::chrono::seconds(std::time(NULL))).count();
    Local<Number> result = Number::New(isolate, timestamp);
    args.GetReturnValue().Set(result);
}

int JsV8InspectorClient::contextGroupId = 1;
std::map<std::string, v8::Persistent<v8::Object>*> JsV8InspectorClient::Domains;

}

