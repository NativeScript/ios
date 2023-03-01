#include <Foundation/Foundation.h>
#include "SymbolIterator.h"
#include "Helpers.h"
#include "ArgConverter.h"

using namespace v8;

namespace tns {

void SymbolIterator::Set(Local<Context> context, Local<Value> object) {
    Isolate* isolate = context->GetIsolate();

    Local<v8::Function> iterator;
    bool success = v8::Function::New(context, [](const FunctionCallbackInfo<Value>& args) {
        Isolate* isolate = args.GetIsolate();
        Local<Context> context = isolate->GetCurrentContext();
        Local<Value> object = args.Data();
        Local<Object> result = CreateIteratorObject(context, object);
        args.GetReturnValue().Set(result);
    }, object).ToLocal(&iterator);
    tns::Assert(success, isolate);

    Local<Value> symbolIteratorKey = Symbol::GetIterator(isolate);
    success = object.As<Object>()->Set(context, symbolIteratorKey, iterator).FromMaybe(false);
}

Local<Object> SymbolIterator::CreateIteratorObject(Local<Context> context, Local<Value> object) {
    Isolate* isolate = context->GetIsolate();
    Local<ObjectTemplate> objectTemplate = ObjectTemplate::New(isolate);
    objectTemplate->SetInternalFieldCount(2);
    Local<Object> result;
    bool success = objectTemplate->NewInstance(context).ToLocal(&result);
    tns::Assert(success, isolate);

    int index = 0;
    result->SetInternalField(0, object);
    result->SetAlignedPointerInInternalField(1, reinterpret_cast<void*>(index << 1));

    Local<v8::Function> next;
    success = v8::Function::New(context, NextCallback).ToLocal(&next);
    tns::Assert(success, isolate);
    success = result->Set(context, tns::ToV8String(isolate, "next"), next).FromMaybe(false);
    tns::Assert(success, isolate);

    return result;
}

void SymbolIterator::NextCallback(const v8::FunctionCallbackInfo<v8::Value>& args) {
    Isolate* isolate = args.GetIsolate();
    Local<Object> thiz = args.This();
    size_t index = (size_t)thiz->GetAlignedPointerFromInternalField(1) >> 1;

    Local<Value> object = thiz->GetInternalField(0);

    BaseDataWrapper* wrapper = tns::GetValue(isolate, object);
    if (wrapper == nullptr || wrapper->Type() != WrapperType::ObjCObject) {
        return;
    }

    ObjCDataWrapper* objcWrapper = static_cast<ObjCDataWrapper*>(wrapper);
    id target = objcWrapper->Data();
    if (target == nil || ![target isKindOfClass:[NSArray class]]) {
        return;
    }

    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> obj = Object::New(isolate);

    if (index >= [target count]) {
        bool success = obj->Set(context, tns::ToV8String(isolate, "done"), v8::Boolean::New(isolate, true)).FromMaybe(false);
        tns::Assert(success, isolate);
        success = obj->Set(context, tns::ToV8String(isolate, "value"), v8::Undefined(isolate)).FromMaybe(false);
        tns::Assert(success, isolate);
    } else {
        id item = [target objectAtIndex:index];
        Local<Value> val;
        if ([item isKindOfClass:[NSNumber class]]) {
            val = Number::New(isolate, [item doubleValue]);
        } else if ([item isKindOfClass:[NSString class]]) {
            val = tns::ToV8String(isolate, [item UTF8String]);
        } else {
            auto wrapper = new ObjCDataWrapper(item);
            val = ArgConverter::CreateJsWrapper(context, wrapper, Local<Object>());
            tns::DeleteWrapperIfUnused(isolate, val, wrapper);
        }

        bool success = obj->Set(context, tns::ToV8String(isolate, "done"), v8::Boolean::New(isolate, false)).FromMaybe(false);
        tns::Assert(success, isolate);
        success = obj->Set(context, tns::ToV8String(isolate, "value"), val).FromMaybe(false);
        tns::Assert(success, isolate);

        index++;
        thiz->SetAlignedPointerInInternalField(1, reinterpret_cast<void*>(index << 1));
    }

    args.GetReturnValue().Set(obj);
}

}
