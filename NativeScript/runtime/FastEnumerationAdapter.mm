#include "FastEnumerationAdapter.h"
#import <Foundation/Foundation.h>
#include "Helpers.h"
#include "Interop.h"
#include "NativeScriptException.h"

using namespace v8;

namespace tns {

NSUInteger FastEnumerationAdapter(Isolate* isolate, id self, NSFastEnumerationState* state,
                                  __unsafe_unretained id buffer[], NSUInteger length,
                                  Persistent<v8::Function>* poIteratorFunc) {
  enum State : decltype(state->state) { Uninitialized = 0, Iterating, Done };

  NSUInteger count = 0;

  try {
    if (state->state == State::Uninitialized) {
      Local<Value> iteratorRes;
      Local<Context> context = isolate->GetCurrentContext();
      Local<v8::Function> iteratorFunc = poIteratorFunc->Get(isolate);
      TryCatch tc(isolate);
      if (!iteratorFunc->Call(context, context->Global(), 0, {}).ToLocal(&iteratorRes)) {
        // JS threw while obtaining the iterator. Surface it to V8 (the
        // outer catch ReThrowsToV8) rather than aborting the process.
        // NOTE: this native fast-enumeration boundary runs under the
        // caller's V8 scopes, so a branded escapeException cannot be
        // safely @thrown here; it surfaces as a JS exception instead.
        throw NativeScriptException(isolate, tc, "Error calling the iterator function");
      }

      tns::Assert(!iteratorRes.IsEmpty() && iteratorRes->IsObject(), isolate);
      Local<Object> iteratorObj = iteratorRes.As<Object>();

      void* selfPtr = (__bridge void*)self;
      state->mutationsPtr = reinterpret_cast<unsigned long*>(selfPtr);
      state->extra[0] =
          reinterpret_cast<unsigned long>(new Persistent<Object>(isolate, iteratorObj));
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
    tns::Assert(success && !next.IsEmpty() && next->IsFunction(), isolate);

    state->itemsPtr = buffer;
    while (count < length) {
      Local<v8::Function> nextFunc = next.As<v8::Function>();
      Local<Context> context = isolate->GetCurrentContext();
      Local<Value> nextResult;
      TryCatch tc(isolate);
      if (!nextFunc->Call(context, iteratorObj, 0, {}).ToLocal(&nextResult)) {
        // Surface a JS throw from the iterator's next() to V8 rather than
        // aborting (see note above about the branded-escape limitation).
        throw NativeScriptException(isolate, tc,
                                    "Error calling the \"next\" method of the iterator");
      }

      if (nextResult.IsEmpty() || !nextResult->IsObject()) {
        throw NativeScriptException("The \"next\" method must return an object with at least the "
                                    "\"value\" or \"done\" properties");
      }

      Local<Value> done;
      bool success =
          nextResult.As<Object>()->Get(context, tns::ToV8String(isolate, "done")).ToLocal(&done);
      tns::Assert(success && tns::IsBool(done), isolate);

      if (tns::ToBool(done)) {
        poIteratorObj->Reset();
        delete poIteratorObj;
        state->state = State::Done;
        break;
      }

      Local<Value> value;
      success =
          nextResult.As<Object>()->Get(context, tns::ToV8String(isolate, "value")).ToLocal(&value);
      tns::Assert(success && !value.IsEmpty(), isolate);

      id result = Interop::ToObject(context, value);
      *buffer++ = result;
      count++;
    }
  } catch (NativeScriptException& ex) {
    ex.ReThrowToV8(isolate);
  }

  return count;
}

}  // namespace tns
