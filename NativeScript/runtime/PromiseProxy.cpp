#include "PromiseProxy.h"
#include "Helpers.h"

using namespace v8;

namespace tns {

void PromiseProxy::Init(v8::Local<v8::Context> context) {
    std::string source = R"(
        // Ensure that Promise callbacks are executed on the
        // same thread on which they were created
        (() => {
            global.Promise = new Proxy(global.Promise, {
                construct: function(target, args) {
                    let origFunc = args[0];
                    let runloop = CFRunLoopGetCurrent();

                    let promise = new target(function(resolve, reject) {
                        origFunc(value => {
                            const resolveCall = resolve.bind(this, value);
                            if (runloop === CFRunLoopGetCurrent()) {
                                resolveCall();
                            } else {
                                CFRunLoopPerformBlock(runloop, kCFRunLoopDefaultMode, resolveCall);
                                CFRunLoopWakeUp(runloop);
                            }
                        }, reason => {
                            const rejectCall = reject.bind(this, reason);
                            if (runloop === CFRunLoopGetCurrent()) {
                                rejectCall();
                            } else {
                                CFRunLoopPerformBlock(runloop, kCFRunLoopDefaultMode, rejectCall);
                                CFRunLoopWakeUp(runloop);
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
                                if (runloop === CFRunLoopGetCurrent()) {
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
        })();
    )";

    Isolate* isolate = context->GetIsolate();

    Local<Script> script;
    bool success = Script::Compile(context, tns::ToV8String(isolate, source)).ToLocal(&script);
    tns::Assert(success && !script.IsEmpty(), isolate);

    Local<Value> result;
    success = script->Run(context).ToLocal(&result);
    tns::Assert(success, isolate);
}

}
