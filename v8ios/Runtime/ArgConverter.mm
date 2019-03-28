#include <Foundation/Foundation.h>
#include "ArgConverter.h"
#include "Helpers.h"

using namespace v8;
using namespace std;

namespace tns {

void ArgConverter::Init(Isolate* isolate, ObjectManager objectManager) {
    isolate_ = isolate;
    objectManager_ = objectManager;

    poEmptyObjCtorFunc_ = new Persistent<v8::Function>(isolate, CreateEmptyObjectFunction(isolate));
}

void ArgConverter::SetArgument(NSInvocation* invocation, int index, Isolate* isolate, Local<Value> arg, const TypeEncoding* typeEncoding) {
    if (arg->IsNull()) {
        id nullArg = nil;
        [invocation setArgument:&nullArg atIndex:index];
        return;
    }

    if (arg->IsBoolean() && typeEncoding != nullptr && typeEncoding->type == BinaryTypeEncodingType::BoolEncoding) {
        bool value = arg.As<v8::Boolean>()->Value();
        [invocation setArgument:&value atIndex:index];
        return;
    }

    if (arg->IsObject() && typeEncoding != nullptr && typeEncoding->type == BinaryTypeEncodingType::ProtocolEncoding) {
        Local<External> ext = arg.As<Object>()->GetInternalField(0).As<External>();
        DataWrapper* wrapper = static_cast<DataWrapper*>(ext->Value());
        std::string protocolName = wrapper->meta_->name();
        Protocol* protocol = objc_getProtocol(protocolName.c_str());
        [invocation setArgument:&protocol atIndex:index];
        return;
    }

    if (arg->IsString() && typeEncoding != nullptr && typeEncoding->type == BinaryTypeEncodingType::CStringEncoding) {
        std::string str = tns::ToString(isolate, arg);
        const char* s = str.c_str();
        [invocation setArgument:&s atIndex:index];
        return;
    }

    if (arg->IsString() && typeEncoding != nullptr && typeEncoding->type == BinaryTypeEncodingType::SelectorEncoding) {
        std::string str = tns::ToString(isolate, arg);
        NSString* selector = [NSString stringWithUTF8String:str.c_str()];
        SEL res = NSSelectorFromString(selector);
        [invocation setArgument:&res atIndex:index];
        return;
    }

    Local<Context> context = isolate->GetCurrentContext();
    if (arg->IsString()) {
        std::string str = tns::ToString(isolate, arg);
        NSString* result = [NSString stringWithUTF8String:str.c_str()];
        [invocation setArgument:&result atIndex:index];
        return;
    }

    if (arg->IsNumber() || arg->IsDate()) {
        double value;
        if (!arg->NumberValue(context).To(&value)) {
            assert(false);
        }

        if (arg->IsNumber() || arg->IsNumberObject()) {
            SetNumericArgument(invocation, index, value, typeEncoding);
            return;
        } else {
            NSDate* date = [NSDate dateWithTimeIntervalSince1970:value / 1000.0];
            [invocation setArgument:&date atIndex:index];
        }
    }

    if (arg->IsFunction() && typeEncoding != nullptr && typeEncoding->type == BinaryTypeEncodingType::BlockEncoding) {
        Persistent<v8::Object>* poCallback = new Persistent<v8::Object>(isolate, arg.As<Object>());
        ObjectWeakCallbackState* state = new ObjectWeakCallbackState(poCallback);
        poCallback->SetWeak(state, ObjectManager::FinalizerCallback, WeakCallbackType::kFinalizer);

        int argsCount = typeEncoding->details.block.signature.count - 1;
        MethodCallbackWrapper* userData = new MethodCallbackWrapper(isolate, poCallback, 1, argsCount, this);
        CFTypeRef blockPtr = interop_.CreateBlock(1, argsCount, ArgConverter::MethodCallback, userData);
        [invocation setArgument:&blockPtr atIndex:index];
        return;
    }

    if (arg->IsObject()) {
        Local<Object> obj = arg.As<Object>();
        if (obj->InternalFieldCount() > 0) {
            Local<External> ext = obj->GetInternalField(0).As<External>();
            DataWrapper* wrapper = reinterpret_cast<DataWrapper*>(ext->Value());
            const Meta* meta = wrapper->meta_;
            if (meta != nullptr && meta->type() == MetaType::JsCode) {
                const JsCodeMeta* jsCodeMeta = static_cast<const JsCodeMeta*>(meta);
                std::string jsCode = jsCodeMeta->jsCode();

                Local<Script> script;
                if (!Script::Compile(context, tns::ToV8String(isolate, jsCode)).ToLocal(&script)) {
                    assert(false);
                }
                assert(!script.IsEmpty());

                Local<Value> result;
                if (!script->Run(context).ToLocal(&result) && !result.IsEmpty()) {
                    assert(false);
                }

                assert(result->IsNumber());

                double value = result.As<Number>()->Value();
                SetNumericArgument(invocation, index, value, typeEncoding);
                return;
            }

            if (wrapper->data_ != nullptr) {
                [invocation setArgument:&wrapper->data_ atIndex:index];
                return;
            }
        }
    }

    assert(false);
}

Local<Value> ArgConverter::ConvertArgument(Isolate* isolate, NSInvocation* invocation, std::string returnType) {
    if (returnType == "@") {
        id result = nil;
        [invocation getReturnValue:&result];
        if (result != nil) {
            CFBridgingRetain(result);
            return ConvertArgument(isolate, result);
        }
    }

    if (returnType == "*" || returnType == "r*") {
        char* result = nullptr;
        [invocation getReturnValue:&result];
        if (result != nullptr) {
            return tns::ToV8String(isolate, result);
        }
    }

    if (returnType == "i") {
        int result;
        [invocation getReturnValue:&result];
        return Number::New(isolate, result);
    }

    if (returnType == "I") {
        unsigned int result;
        [invocation getReturnValue:&result];
        return Number::New(isolate, result);
    }

    if (returnType == "s") {
        short result;
        [invocation getReturnValue:&result];
        return Number::New(isolate, result);
    }

    if (returnType == "S") {
        unsigned short result;
        [invocation getReturnValue:&result];
        return Number::New(isolate, result);
    }

    if (returnType == "l") {
        long result;
        [invocation getReturnValue:&result];
        return Number::New(isolate, result);
    }

    if (returnType == "L") {
        unsigned long result;
        [invocation getReturnValue:&result];
        return Number::New(isolate, result);
    }

    if (returnType == "q") {
        long long result;
        [invocation getReturnValue:&result];
        return Number::New(isolate, result);
    }

    if (returnType == "Q") {
        unsigned long long result;
        [invocation getReturnValue:&result];
        return Number::New(isolate, result);
    }

    if (returnType == "f") {
        float result;
        [invocation getReturnValue:&result];
        return Number::New(isolate, result);
    }

    if (returnType == "d") {
        double result;
        [invocation getReturnValue:&result];
        return Number::New(isolate, result);
    }

    if (returnType == "B") {
        bool result;
        [invocation getReturnValue:&result];
        return v8::Boolean::New(isolate, result);
    }

    // TODO: Handle all the possible return types https://nshipster.com/type-encodings/

    return Local<Value>();
}

Local<Value> ArgConverter::ConvertArgument(Isolate* isolate, id obj) {
    if (obj == nullptr) {
        return Null(isolate);
    }

    Local<Value> result = CreateJsWrapper(isolate, obj, Local<Object>());
    return result;
}

void ArgConverter::MethodCallback(ffi_cif* cif, void* retValue, void** argValues, void* userData) {
    MethodCallbackWrapper* data = static_cast<MethodCallbackWrapper*>(userData);

    std::vector<id> arguments;
    for (int i = 0; i < data->paramsCount_; i++) {
        const id arg = *static_cast<const id*>(argValues[i + data->initialParamIndex_]);
        arguments.push_back(arg);
    }

    Isolate* isolate = data->isolate_;
    const Persistent<Object>* poCallback = data->callback_;

    Local<Value> (^cb)() = ^Local<Value>() {
        EscapableHandleScope handle_scope(isolate);
        Local<Context> ctx = isolate->GetCurrentContext();
        Local<v8::Function> callback = poCallback->Get(isolate).As<v8::Function>();

        std::vector<Local<Value>> v8Args;
        for (int i = 0; i < arguments.size(); i++) {
            Local<Value> jsWrapper = data->argConverter_->ConvertArgument(isolate, arguments[i]);
            v8Args.push_back(jsWrapper);
        }

        Local<Value> result;
        if (!callback->Call(ctx, ctx->Global(), (int)arguments.size(), v8Args.data()).ToLocal(&result)) {
            assert(false);
        }

        return handle_scope.Escape(result);
    };

    HandleScope handle_scope(isolate);

    Local<Value> result;
    if ([NSThread isMainThread]) {
        result = cb();
        if (result.IsEmpty() || result->IsUndefined()) {
            result = Local<Value>();
        }
    } else {
        Persistent<Value>* __block poResult = nullptr;
        dispatch_group_t group = dispatch_group_create();
        dispatch_group_enter(group);
        dispatch_async(dispatch_get_main_queue(), ^{
            HandleScope handle_scope(isolate);
            Local<Value> localRes = cb();
            if (!localRes.IsEmpty() && !localRes->IsUndefined()) {
                poResult = new Persistent<Value>(isolate, localRes);
            }
            dispatch_group_leave(group);
        });

        if (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) != 0) {
            assert(false);
        }

        if (poResult != nullptr) {
            result = Local<Value>::New(isolate, *poResult);
            poResult->Reset();
            delete poResult;
        }
    }

    if (!result.IsEmpty() && !result->IsUndefined()) {
        // TODO: Handle the return type, i.e. assign the retValue parameter from the v8 result
    }
}
void ArgConverter::SetNumericArgument(NSInvocation* invocation, int index, double value, const TypeEncoding* typeEncoding) {
    switch (typeEncoding->type) {
    case BinaryTypeEncodingType::ShortEncoding: {
        short arg = (short)value;
        [invocation setArgument:&arg atIndex:index];
        break;
    }
    case BinaryTypeEncodingType::UShortEncoding: {
        ushort arg = (ushort)value;
        [invocation setArgument:&arg atIndex:index];
        break;
    }
    case BinaryTypeEncodingType::IntEncoding: {
        int arg = (int)value;
        [invocation setArgument:&arg atIndex:index];
        break;
    }
    case BinaryTypeEncodingType::UIntEncoding: {
        uint arg = (uint)value;
        [invocation setArgument:&arg atIndex:index];
        break;
    }
    case BinaryTypeEncodingType::LongEncoding: {
        long arg = (long)value;
        [invocation setArgument:&arg atIndex:index];
        break;
    }
    case BinaryTypeEncodingType::ULongEncoding: {
        unsigned long arg = (unsigned long)value;
        [invocation setArgument:&arg atIndex:index];
        break;
    }
    case BinaryTypeEncodingType::LongLongEncoding: {
        long long arg = (long long)value;
        [invocation setArgument:&arg atIndex:index];
        break;
    }
    case BinaryTypeEncodingType::ULongLongEncoding: {
        unsigned long long arg = (unsigned long long)value;
        [invocation setArgument:&arg atIndex:index];
        break;
    }
    case BinaryTypeEncodingType::FloatEncoding: {
        float arg = (float)value;
        [invocation setArgument:&arg atIndex:index];
        break;
    }
    case BinaryTypeEncodingType::DoubleEncoding: {
        [invocation setArgument:&value atIndex:index];
        break;
    }
    case BinaryTypeEncodingType::IdEncoding: {
        [invocation setArgument:&value atIndex:index];
        break;
    }
    default: {
        assert(false);
        break;
    }
    }
}

Local<Object> ArgConverter::CreateJsWrapper(Isolate* isolate, id obj, Local<Object> receiver) {
    Local<Context> context = isolate->GetCurrentContext();

    if (receiver.IsEmpty()) {
        receiver = CreateEmptyObject(context);
    }

    const InterfaceMeta* meta = FindInterfaceMeta(obj);
    if (meta != nullptr) {
        auto it = Caches::Prototypes.find(meta);
        if (it != Caches::Prototypes.end()) {
            Persistent<Value>* poPrototype = it->second;
            Local<Value> prototype = Local<Value>::New(isolate, *poPrototype);
            bool success;
            if (!receiver->SetPrototype(context, prototype).To(&success) || !success) {
                assert(false);
            }
        }
    }

    DataWrapper* wrapper = new DataWrapper(obj);
    Local<External> ext = External::New(isolate, wrapper);
    receiver->SetInternalField(0, ext);
    objectManager_.Register(isolate, receiver);

    return receiver;
}

const InterfaceMeta* ArgConverter::FindInterfaceMeta(id obj) {
    if (obj == nullptr) {
        return nullptr;
    }

    Class klass = [obj class];

    std::string origClassName = class_getName(klass);
    auto it = Caches::Metadata.find(origClassName);
    if (it != Caches::Metadata.end()) {
        return it->second;
    }

    std::string className = origClassName;

    while (true) {
        const InterfaceMeta* result = GetInterfaceMeta(className);
        if (result != nullptr) {
            Caches::Metadata.insert(std::make_pair(origClassName, result));
            return result;
        }

        klass = class_getSuperclass(klass);
        if (klass == nullptr) {
            break;
        }

        className = class_getName(klass);
    }

    return nullptr;
}

const InterfaceMeta* ArgConverter::GetInterfaceMeta(std::string className) {
    auto it = Caches::Metadata.find(className);
    if (it != Caches::Metadata.end()) {
        return it->second;
    }

    const GlobalTable* globalTable = MetaFile::instance()->globalTable();
    return globalTable->findInterfaceMeta(className.c_str());
}

Local<Object> ArgConverter::CreateEmptyObject(Local<Context> context) {
    Isolate* isolate = context->GetIsolate();
    Local<v8::Function> emptyObjCtorFunc = Local<v8::Function>::New(isolate, *poEmptyObjCtorFunc_);
    Local<Value> value;
    if (!emptyObjCtorFunc->CallAsConstructor(context, 0, nullptr).ToLocal(&value) || value.IsEmpty() || !value->IsObject()) {
        assert(false);
    }
    Local<Object> result = value.As<Object>();
    return result;
}

Local<v8::Function> ArgConverter::CreateEmptyObjectFunction(Isolate* isolate) {
    Local<FunctionTemplate> emptyObjCtorFuncTemplate = FunctionTemplate::New(isolate, nullptr);
    emptyObjCtorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);
    Local<v8::Function> emptyObjCtorFunc;
    if (!emptyObjCtorFuncTemplate->GetFunction(isolate->GetCurrentContext()).ToLocal(&emptyObjCtorFunc)) {
        assert(false);
    }
    return emptyObjCtorFunc;
}

}
