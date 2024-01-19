//
// Created by Osei Fortune on 14/01/2024.
//

#include "URLSearchParamsImpl.h"
#include "Helpers.h"

using namespace ada;

namespace tns {
    URLSearchParamsImpl::URLSearchParamsImpl(ada::url_search_params params) : params_(params) {}

    URLSearchParamsImpl *URLSearchParamsImpl::GetPointer(v8::Local<v8::Object> object) {
        auto ptr = object->GetAlignedPointerFromInternalField(0);
        if (ptr == nullptr) {
            return nullptr;
        }
        return static_cast<URLSearchParamsImpl *>(ptr);
    }

    v8::Local<v8::FunctionTemplate> URLSearchParamsImpl::GetCtor(v8::Isolate *isolate) {
        v8::Local<v8::FunctionTemplate> ctorTmpl = v8::FunctionTemplate::New(isolate, Ctor);
        ctorTmpl->SetClassName(ToV8String(isolate, "URLSearchParams"));

        auto tmpl = ctorTmpl->InstanceTemplate();
        tmpl->SetInternalFieldCount(1);
        tmpl->Set(
                ToV8String(isolate, "append"),
                v8::FunctionTemplate::New(isolate, Append));
        tmpl->Set(
                ToV8String(isolate, "delete"),
                v8::FunctionTemplate::New(isolate, Delete));

        tmpl->Set(
                ToV8String(isolate, "entries"),
                v8::FunctionTemplate::New(isolate, Entries));

        tmpl->Set(
                ToV8String(isolate, "forEach"),
                v8::FunctionTemplate::New(isolate, ForEach));

        tmpl->Set(
                ToV8String(isolate, "get"),
                v8::FunctionTemplate::New(isolate, Get));

        tmpl->Set(
                ToV8String(isolate, "getAll"),
                v8::FunctionTemplate::New(isolate, GetAll));

        tmpl->Set(
                ToV8String(isolate, "has"),
                v8::FunctionTemplate::New(isolate, Has));

        tmpl->Set(
                ToV8String(isolate, "keys"),
                v8::FunctionTemplate::New(isolate, Keys));

        tmpl->Set(
                ToV8String(isolate, "set"),
                v8::FunctionTemplate::New(isolate, Set));

        tmpl->SetAccessor(
                ToV8String(isolate, "size"),
                GetSize
        );


        tmpl->Set(
                ToV8String(isolate, "sort"),
                v8::FunctionTemplate::New(isolate, Sort));

        tmpl->Set(ToV8String(isolate, "toString"),
                  v8::FunctionTemplate::New(isolate, &ToString));


        tmpl->Set(ToV8String(isolate, "values"),
                  v8::FunctionTemplate::New(isolate, &Values));


        return ctorTmpl;
    }

    void URLSearchParamsImpl::Ctor(const v8::FunctionCallbackInfo<v8::Value> &args) {
        auto value = args[0];
        auto isolate = args.GetIsolate();
        auto context = isolate->GetCurrentContext();

        auto ret = args.This();

        ada::url_search_params params;
        if (value->IsString()) {
            params = ada::url_search_params(tns::ToString(isolate, value.As<v8::String>()));
        } else if (value->IsObject()) {
            params = ada::url_search_params(
                    tns::ToString(isolate, value->ToString(context).ToLocalChecked()));
        }


        auto searchParams = new URLSearchParamsImpl(params);

        ret->SetAlignedPointerInInternalField(0, searchParams);

        searchParams->BindFinalizer(isolate, ret);

        args.GetReturnValue().Set(ret);

    }

    void URLSearchParamsImpl::Append(const v8::FunctionCallbackInfo<v8::Value> &args) {
        URLSearchParamsImpl *ptr = GetPointer(args.This());
        if (ptr == nullptr) {
            return;
        }
        auto isolate = args.GetIsolate();
        auto key = tns::ToString(isolate, args[0].As<v8::String>());
        auto value = tns::ToString(isolate, args[1].As<v8::String>());
        ptr->GetURLSearchParams()->append(key.c_str(), value.c_str());
    }

    void URLSearchParamsImpl::Delete(const v8::FunctionCallbackInfo<v8::Value> &args) {
        URLSearchParamsImpl *ptr = GetPointer(args.This());
        if (ptr == nullptr) {
            return;
        }
        auto isolate = args.GetIsolate();
        auto key = tns::ToString(isolate, args[0].As<v8::String>());
        ptr->GetURLSearchParams()->remove(key.c_str());
    }

    void URLSearchParamsImpl::Entries(const v8::FunctionCallbackInfo<v8::Value> &args) {
        URLSearchParamsImpl *ptr = GetPointer(args.This());
        auto isolate = args.GetIsolate();
        auto context = isolate->GetCurrentContext();
        if (ptr == nullptr) {
            args.GetReturnValue().Set(v8::Array::New(isolate));
            return;
        }

        
        auto keys = ptr->GetURLSearchParams()->get_keys();
        auto len = ptr->GetURLSearchParams()->size();
        auto ret = v8::Array::New(isolate, (int)len);
        int i = 0;
        while (keys.has_next()) {
            auto key = keys.next();
            if (key) {
                auto keyValue = key.value();
                auto value = ptr->GetURLSearchParams()->get(keyValue).value();
                v8::Local<v8::Value> values[] = {
                        ToV8String(isolate, keyValue.data()),
                        ToV8String(isolate, value.data()),
                };
                auto success = ret->Set(context, i++, v8::Array::New(isolate, values, 2)).FromMaybe(false);
                tns::Assert(success, isolate);
            }

        }
        args.GetReturnValue().Set(ret);
    }

    void URLSearchParamsImpl::ForEach(const v8::FunctionCallbackInfo<v8::Value> &args) {
        URLSearchParamsImpl *ptr = GetPointer(args.This());
        auto isolate = args.GetIsolate();
        auto context = isolate->GetCurrentContext();
        if (ptr == nullptr) {
            return;
        }
        auto callback = args[0].As<v8::Function>();
        auto keys = ptr->GetURLSearchParams()->get_keys();
        while (keys.has_next()) {
            auto key = keys.next();
            if (key) {
                auto keyValue = key.value();
                auto value = ptr->GetURLSearchParams()->get(keyValue).value();
                v8::Local<v8::Value> values[] = {
                        ToV8String(isolate, keyValue.data()),
                        ToV8String(isolate, value.data()),
                };
                v8::Local<v8::Value> result;
                if (!callback->Call(context, v8::Local<v8::Value>(), 2, values).ToLocal(&result)){
                    tns::Assert(false, isolate);
                }
            }

        }
    }

    void URLSearchParamsImpl::Get(const v8::FunctionCallbackInfo<v8::Value> &args) {
        URLSearchParamsImpl *ptr = GetPointer(args.This());
        auto isolate = args.GetIsolate();
        if (ptr == nullptr) {
            args.GetReturnValue().SetUndefined();
            return;
        }
        auto key = args[0].As<v8::String>();
        auto value = ptr->GetURLSearchParams()->get(tns::ToString(isolate, key));
        if (value.has_value()) {
            auto ret = ToV8String(isolate, std::string(value.value()));
            args.GetReturnValue().Set(ret);
        } else {
            args.GetReturnValue().SetUndefined();
        }
    }

    void URLSearchParamsImpl::GetAll(const v8::FunctionCallbackInfo<v8::Value> &args) {
        URLSearchParamsImpl *ptr = GetPointer(args.This());
        auto isolate = args.GetIsolate();
        auto context = isolate->GetCurrentContext();
        if (ptr == nullptr) {
            args.GetReturnValue().Set(v8::Array::New(isolate));
            return;
        }
        auto key = args[0].As<v8::String>();
        auto values = ptr->GetURLSearchParams()->get_all(tns::ToString(isolate, key));
        auto ret = v8::Array::New(isolate, (int)values.size());
        int i = 0;
        for (auto item: values) {
            tns::Assert(ret->Set(context, i++, ToV8String(isolate, item)).FromMaybe(false), isolate);
        }
        args.GetReturnValue().Set(ret);
    }

    void URLSearchParamsImpl::Has(const v8::FunctionCallbackInfo<v8::Value> &args) {
        URLSearchParamsImpl *ptr = GetPointer(args.This());
        if (ptr == nullptr) {
            args.GetReturnValue().Set(false);
            return;
        }
        auto isolate = args.GetIsolate();
        auto key = args[0].As<v8::String>();
        auto value = ptr->GetURLSearchParams()->has(tns::ToString(isolate, key));

        args.GetReturnValue().Set(value);
    }

    void URLSearchParamsImpl::Keys(const v8::FunctionCallbackInfo<v8::Value> &args) {
        URLSearchParamsImpl *ptr = GetPointer(args.This());
        auto isolate = args.GetIsolate();
        auto context = isolate->GetCurrentContext();
        if (ptr == nullptr) {
            args.GetReturnValue().Set(v8::Array::New(isolate));
            return;
        }

        auto keys = ptr->GetURLSearchParams()->get_keys();

        auto len = ptr->GetURLSearchParams()->size();
        auto ret = v8::Array::New(isolate, (int)len);
        int i = 0;
        while (keys.has_next()) {
            auto key = keys.next();
            if (key) {
                auto keyValue = key.value();
                tns::Assert(ret->Set(context, i++, ToV8String(isolate, keyValue.data())).FromMaybe(false), isolate);
            }

        }
        args.GetReturnValue().Set(ret);

    }

    void URLSearchParamsImpl::Set(const v8::FunctionCallbackInfo<v8::Value> &args) {
        URLSearchParamsImpl *ptr = GetPointer(args.This());
        if (ptr == nullptr) {
            return;
        }
        auto key = args[0].As<v8::String>();
        auto value = args[1].As<v8::String>();

        auto isolate = args.GetIsolate();
        ptr->GetURLSearchParams()->set(
                tns::ToString(isolate, key),
                tns::ToString(isolate, value)
        );
    }

    void URLSearchParamsImpl::GetSize(v8::Local<v8::String> property,
                                      const v8::PropertyCallbackInfo<v8::Value> &info) {
        URLSearchParamsImpl *ptr = GetPointer(info.This());
        if (ptr == nullptr) {
            info.GetReturnValue().Set(0);
            return;
        }

        auto value = ptr->GetURLSearchParams()->size();
        info.GetReturnValue().Set((int) value);

    }

    void URLSearchParamsImpl::Sort(const v8::FunctionCallbackInfo<v8::Value> &args) {
        URLSearchParamsImpl *ptr = GetPointer(args.This());
        if (ptr == nullptr) {
            return;
        }
        ptr->GetURLSearchParams()->sort();
    }

    void URLSearchParamsImpl::ToString(const v8::FunctionCallbackInfo<v8::Value> &args) {
        URLSearchParamsImpl *ptr = GetPointer(args.This());
        if (ptr == nullptr) {
            args.GetReturnValue().SetEmptyString();
            return;
        }
        auto isolate = args.GetIsolate();


        auto value = ptr->GetURLSearchParams()->to_string();

        auto ret = ToV8String(isolate, value);

        args.GetReturnValue().Set(ret);
    }

    void URLSearchParamsImpl::Values(const v8::FunctionCallbackInfo<v8::Value> &args) {
        URLSearchParamsImpl *ptr = GetPointer(args.This());
        auto isolate = args.GetIsolate();
        auto context = isolate->GetCurrentContext();
        if (ptr == nullptr) {
            args.GetReturnValue().Set(v8::Array::New(isolate));
            return;
        }

        auto keys = ptr->GetURLSearchParams()->get_keys();

        auto len = ptr->GetURLSearchParams()->size();
        auto ret = v8::Array::New(isolate, (int)len);
        int i = 0;
        while (keys.has_next()) {
            auto key = keys.next();
            if (key) {
                auto value = ptr->GetURLSearchParams()->get(key.value());
                if (value.has_value()) {
                    tns::Assert(ret->Set(context, i++,
                             ToV8String(isolate, std::string(value.value()))).FromMaybe(false), isolate);
                }

            }

        }
        args.GetReturnValue().Set(ret);

    }


    url_search_params *URLSearchParamsImpl::GetURLSearchParams() {
        return &this->params_;
    }

} // tns
