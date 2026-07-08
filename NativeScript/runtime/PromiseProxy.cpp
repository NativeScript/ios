#include "PromiseProxy.h"

#include <CoreFoundation/CoreFoundation.h>

#include "Helpers.h"
#include "Runtime.h"

using namespace v8;

namespace tns {

// Reports whether the calling thread runs the isolate's runtime loop. That loop
// is where timers fire and is always being pumped, so a promise resolution is
// marshaled back to its creating thread only when that thread is the runtime
// loop; a promise created elsewhere settles on whichever thread resolves it.
static void IsRuntimeRunloopCallback(const FunctionCallbackInfo<Value>& args) {
    Runtime* runtime = Runtime::GetRuntime(args.GetIsolate());
    bool isRuntimeLoop = runtime != nullptr && CFRunLoopGetCurrent() == runtime->RuntimeLoop();
    args.GetReturnValue().Set(isRuntimeLoop);
}

void PromiseProxy::Init(v8::Local<v8::Context> context) {
    std::string source = R"(
        // Run a Promise's callbacks on the thread that created it, but only when
        // that thread is the runtime loop. A Promise created on a background
        // thread settles on whichever thread resolves it, because the background
        // run loop may be dormant and marshaling a resolution to it would hang.
        (function(isRuntimeRunloop) {
            global.Promise = new Proxy(global.Promise, {
                construct: function(target, args) {
                    let origFunc = args[0];
                    let runloop = CFRunLoopGetCurrent();
                    let originIsRuntimeLoop = isRuntimeRunloop();

                    let promise = new target(function(resolve, reject) {
                        function isFulfilled() {
                            return !resolve;
                        }
                        function markFulfilled() {
                            origFunc = null;
                            resolve = null;
                            reject = null;
                        }
                        origFunc(value => {
                            if (isFulfilled()) {
                                return;
                            }
                            const resolveCall = resolve.bind(this, value);
                            if (!originIsRuntimeLoop || runloop === CFRunLoopGetCurrent()) {
                                markFulfilled();
                                resolveCall();
                            } else {
                                CFRunLoopPerformBlock(runloop, kCFRunLoopDefaultMode, resolveCall);
                                CFRunLoopWakeUp(runloop);
                                markFulfilled();
                            }
                        }, reason => {
                            if (isFulfilled()) {
                                return;
                            }
                            const rejectCall = reject.bind(this, reason);
                            if (!originIsRuntimeLoop || runloop === CFRunLoopGetCurrent()) {
                                markFulfilled();
                                rejectCall();
                            } else {
                                CFRunLoopPerformBlock(runloop, kCFRunLoopDefaultMode, rejectCall);
                                CFRunLoopWakeUp(runloop);
                                markFulfilled();
                            }
                        });
                    });

                    return new Proxy(promise, {
                        get: function(target, name) {
                            let orig = target[name];
                            if (name === "then" || name === "catch" || name === "finally") {
                                return orig.bind(target);
                            }
                            return typeof orig === 'function' ? function(x) {
                                if (!originIsRuntimeLoop || runloop === CFRunLoopGetCurrent()) {
                                    orig.bind(target, x)();
                                    return target;
                                }
                                CFRunLoopPerformBlock(runloop, kCFRunLoopDefaultMode, orig.bind(target, x));
                                CFRunLoopWakeUp(runloop);
                                return target;
                            } : orig;
                        }
                    });
                }
            });
        })
    )";

    Isolate* isolate = context->GetIsolate();

    Local<Script> script;
    bool success = Script::Compile(context, tns::ToV8String(isolate, source)).ToLocal(&script);
    tns::Assert(success && !script.IsEmpty(), isolate);

    Local<Value> result;
    success = script->Run(context).ToLocal(&result);
    tns::Assert(success && result->IsFunction(), isolate);

    Local<v8::Function> installProxy = result.As<v8::Function>();

    Local<v8::Function> isRuntimeRunloop;
    success = v8::Function::New(context, IsRuntimeRunloopCallback).ToLocal(&isRuntimeRunloop);
    tns::Assert(success, isolate);

    Local<Value> installArgs[] = { isRuntimeRunloop };
    Local<Value> installResult;
    success = installProxy->Call(context, context->Global(), 1, installArgs).ToLocal(&installResult);
    tns::Assert(success, isolate);
}

}
