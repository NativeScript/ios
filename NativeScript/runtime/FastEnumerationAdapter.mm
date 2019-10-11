#import <Foundation/Foundation.h>
#include "FastEnumerationAdapter.h"
#include "NativeScriptException.h"
#include "Interop.h"
#include "Helpers.h"
#include "Interop.h"

using namespace v8;

namespace tns {

NSUInteger FastEnumerationAdapter(Isolate* isolate, id self, NSFastEnumerationState* state, __unsafe_unretained id buffer[], NSUInteger length, Persistent<v8::Function>* poIteratorFunc) {
    enum State : decltype(state->state) {
        Uninitialized = 0,
        Iterating,
        Done
    };

    NSUInteger count = 0;

    try {
        if (state->state == State::Uninitialized) {
            Local<Value> iteratorRes;
            Local<Context> context = isolate->GetCurrentContext();
            Local<v8::Function> iteratorFunc = poIteratorFunc->Get(isolate);
            if (!iteratorFunc->Call(context, context->Global(), 0, {}).ToLocal(&iteratorRes)) {
                assert(false);
            }

            assert(!iteratorRes.IsEmpty() && iteratorRes->IsObject());
            Local<Object> iteratorObj = iteratorRes.As<Object>();

            void* selfPtr = (__bridge void*)self;
            state->mutationsPtr = reinterpret_cast<unsigned long*>(selfPtr);
            state->extra[0] = reinterpret_cast<unsigned long>(new Persistent<Object>(isolate, iteratorObj));
            state->state = State::Iterating;
        }

        if (state->state == State::Done) {
            return 0;
        }

        Persistent<Object>* poIteratorObj = reinterpret_cast<Persistent<Object>*>(state->extra[0]);
        Local<Object> iteratorObj = poIteratorObj->Get(isolate);
        Local<Context> context = isolate->GetCurrentContext();
        Local<Value> next;
        bool success = iteratorObj->Get(context, tns::ToV8String(isolate, "next")).ToLocal(&next);
        assert(success && !next.IsEmpty() && next->IsFunction());

        state->itemsPtr = buffer;
        while (count < length) {
            Local<v8::Function> nextFunc = next.As<v8::Function>();
            Local<Context> context = isolate->GetCurrentContext();
            Local<Value> nextResult;
            if (!nextFunc->Call(context, iteratorObj, 0, {}).ToLocal(&nextResult)) {
                assert(false);
            }

            if (nextResult.IsEmpty() || !nextResult->IsObject()) {
                throw NativeScriptException("The \"next\" method must return an object with at least the \"value\" or \"done\" properties");
            }

            Local<Value> done;
            bool success = nextResult.As<Object>()->Get(context, tns::ToV8String(isolate, "done")).ToLocal(&done);
            assert(success && tns::IsBool(done));

            if (tns::ToBool(done)) {
                poIteratorObj->Reset();
                poIteratorFunc->Reset();
                state->state = State::Done;
                break;
            }

            Local<Value> value;
            success = nextResult.As<Object>()->Get(context, tns::ToV8String(isolate, "value")).ToLocal(&value);
            assert(success && !value.IsEmpty());

            id result = Interop::ToObject(isolate, value);
            *buffer++ = result;
            count++;
        }
    } catch (NativeScriptException& ex) {
        ex.ReThrowToV8(isolate);
    }

    return count;
}

}
