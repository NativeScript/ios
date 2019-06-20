#import <Foundation/Foundation.h>
#include "FastEnumerationAdapter.h"
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
    Local<Value> next = iteratorObj->Get(tns::ToV8String(isolate, "next"));
    assert(!next.IsEmpty() && next->IsFunction());

    NSUInteger count = 0;
    state->itemsPtr = buffer;
    while (count < length) {
        Local<v8::Function> nextFunc = next.As<v8::Function>();
        Local<Context> context = isolate->GetCurrentContext();
        Local<Value> nextResult;
        if (!nextFunc->Call(context, iteratorObj, 0, {}).ToLocal(&nextResult)) {
            assert(false);
        }

        if (nextResult.IsEmpty() || !nextResult->IsObject()) {
            Isolate::Scope sc(isolate);
            Local<v8::String> errorMessage = tns::ToV8String(isolate, "The \"next\" method must return an object with at least the \"value\" or \"done\" properties");
            Local<Value> exception = Exception::TypeError(errorMessage);
            isolate->ThrowException(exception);
            return 0;
        }

        Local<Value> done = nextResult.As<Object>()->Get(tns::ToV8String(isolate, "done"));
        assert(tns::IsBool(done));

        if (tns::ToBool(done)) {
            Local<Value> ret = iteratorObj->Get(tns::ToV8String(isolate, "return"));
            if (!ret.IsEmpty() && ret->IsFunction()) {

            }

            poIteratorObj->Reset();
            poIteratorFunc->Reset();
            state->state = State::Done;
            break;
        }

        Local<Value> value = nextResult.As<Object>()->Get(tns::ToV8String(isolate, "value"));
        assert(!value.IsEmpty());

        id result = Interop::ToObject(isolate, value);
        *buffer++ = result;

//        if (tns::IsString(value)) {
//            NSString* result = [NSString stringWithUTF8String:tns::ToString(isolate, value).c_str()];
//            *buffer++ = result;
//        } else if (tns::IsNumber(value)) {
//            *buffer++ = @(tns::ToNumber(value));
//        } else if (tns::IsBool(value)) {
//            *buffer++ = @(tns::ToBool(value));
//        } else if (value->IsArray()) {
//            ArrayAdapter* adapter = [[ArrayAdapter alloc] initWithJSObject:value.As<v8::Array>() isolate:isolate];
//            *buffer++ = adapter;
//        } else if (value->IsObject()) {
//            if (BaseDataWrapper* wrapper = tns::GetValue(isolate, value)) {
//                switch (wrapper->Type()) {
//                    case WrapperType::ObjCObject: {
//                        ObjCDataWrapper* wr = static_cast<ObjCDataWrapper*>(wrapper);
//                        *buffer++ = wr->Data();
//                        break;
//                    }
//                    case WrapperType::ObjCClass: {
//                        ObjCClassWrapper* wr = static_cast<ObjCClassWrapper*>(wrapper);
//                        *buffer++ = wr->Klass();
//                        break;
//                    }
//                    case WrapperType::ObjCProtocol: {
//                        ObjCProtocolWrapper* wr = static_cast<ObjCProtocolWrapper*>(wrapper);
//                        *buffer++ = wr->Proto();
//                        break;
//                    }
//                    default:
//                        // TODO: Unsupported object type
//                        assert(false);
//                        break;
//                }
//            } else {
//                DictionaryAdapter* adapter = [[DictionaryAdapter alloc] initWithJSObject:value isolate:isolate];
//                *buffer++ = adapter;
//            }
//        }

        count++;
    }

    return count;
}

}
