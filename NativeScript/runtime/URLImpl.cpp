//
// Created by Osei Fortune on 15/011/2023.
//

#include "URLImpl.h"
#include "Helpers.h"
#include "ModuleBinding.hpp"

using namespace tns;
using namespace ada;

URLImpl::URLImpl(url_aggregator url) : url_(url) {}

void URLImpl::Init(v8::Isolate* isolate, v8::Local<v8::ObjectTemplate> globalTemplate) {
    auto URLTemplate = URLImpl::GetCtor(isolate);

    v8::Local<v8::String> urlPropertyName = ToV8String(isolate, "URL");
    globalTemplate->Set(urlPropertyName, URLTemplate);
}

URLImpl *URLImpl::GetPointer(v8::Local<v8::Object> object) {
    auto ptr = object->GetAlignedPointerFromInternalField(0);
    if (ptr == nullptr) {
        return nullptr;
    }
    return static_cast<URLImpl *>(ptr);
}

url_aggregator *URLImpl::GetURL() {
    return &this->url_;
}

v8::Local<v8::FunctionTemplate> URLImpl::GetCtor(v8::Isolate *isolate) {
    v8::Local<v8::FunctionTemplate> ctorTmpl = v8::FunctionTemplate::New(isolate, Ctor);
    
    ctorTmpl->SetClassName(ToV8String(isolate, "URL"));

    auto tmpl = ctorTmpl->InstanceTemplate();
    tmpl->SetInternalFieldCount(1);
    tmpl->SetAccessor(
            ToV8String(isolate, "hash"),
            GetHash, SetHash);
    tmpl->SetAccessor(
            ToV8String(isolate, "host"),
            GetHost, SetHost);
    tmpl->SetAccessor(
            ToV8String(isolate, "hostname"),
            GetHostName, SetHostName);
    tmpl->SetAccessor(
            ToV8String(isolate, "href"),
            GetHref, SetHref);

    tmpl->SetAccessor(
            ToV8String(isolate, "origin"),
            GetOrigin);

    tmpl->SetAccessor(
            ToV8String(isolate, "password"),
            GetPassword, SetPassword);

    tmpl->SetAccessor(
            ToV8String(isolate, "pathname"),
            GetPathName, SetPathName);

    tmpl->SetAccessor(
            ToV8String(isolate, "port"),
            GetPort, SetPort);

    tmpl->SetAccessor(
            ToV8String(isolate, "protocol"),
            GetProtocol, SetProtocol);

    tmpl->SetAccessor(
            ToV8String(isolate, "search"),
            GetSearch, SetSearch);

    tmpl->SetAccessor(
            ToV8String(isolate, "username"),
            GetUserName, SetUserName);

    tmpl->Set(ToV8String(isolate, "toString"),
              v8::FunctionTemplate::New(isolate, &ToString));


    ctorTmpl->Set(ToV8String(isolate, "canParse"),
                  v8::FunctionTemplate::New(isolate, &CanParse));


    return ctorTmpl;
}

void URLImpl::Ctor(const v8::FunctionCallbackInfo<v8::Value> &args) {
    auto count = args.Length();
    auto value = args[0];
    auto isolate = args.GetIsolate();
    auto context = isolate->GetCurrentContext();
    if (count >= 1 && !value->IsString()) {
        isolate->ThrowException(
                v8::Exception::TypeError(ToV8String(isolate, "")));
        return;
    }

    url_aggregator url;

    auto url_string = tns::ToString(isolate, args[0].As<v8::String>());

    if (count > 1) {
        if (args[1]->IsString()) {
            auto base_string = tns::ToString(isolate, args[1].As<v8::String>());
            std::string_view base_string_view(base_string.data(), base_string.length());

            if (!can_parse(url_string, &base_string_view)) {
                isolate->ThrowException(
                        v8::Exception::TypeError(ToV8String(isolate, "")));
                return;
            }
            auto base_url = ada::parse<ada::url_aggregator>(base_string_view, nullptr);

            auto result = ada::parse<ada::url_aggregator>(url_string, &base_url.value());

            if (result) {
                url = result.value();
            } else {
                isolate->ThrowException(
                        v8::Exception::TypeError(ToV8String(isolate, "")));
                return;
            }
        } else if (args[1]->IsObject()) {
            auto base_string = tns::ToString(isolate,
                    args[1]->ToString(context).ToLocalChecked());
            std::string_view base_string_view(base_string.data(), base_string.length());
            if (!can_parse(std::string_view(url_string.data(), url_string.length()),
                           &base_string_view)) {
                isolate->ThrowException(
                        v8::Exception::TypeError(ToV8String(isolate, "")));
                return;
            }


            auto base_url = ada::parse<ada::url_aggregator>(base_string_view, nullptr);

            auto result = ada::parse<ada::url_aggregator>(url_string, &base_url.value());

            if (result) {
                url = result.value();
            } else {
                isolate->ThrowException(
                        v8::Exception::TypeError(ToV8String(isolate, "")));
                return;
            }
        }

    } else {
        auto result = ada::parse<ada::url_aggregator>(url_string, nullptr);
        if (result) {
            url = result.value();
        } else {
            isolate->ThrowException(
                    v8::Exception::TypeError(ToV8String(isolate, "")));
            return;
        }

    }

    auto ret = args.This();

    auto urlImpl = new URLImpl(url);

    ret->SetAlignedPointerInInternalField(0, urlImpl);

    urlImpl->BindFinalizer(isolate, ret);

    args.GetReturnValue().Set(ret);

}


void URLImpl::GetHash(v8::Local<v8::String> property,
                      const v8::PropertyCallbackInfo<v8::Value> &info) {
    URLImpl *ptr = GetPointer(info.This());
    if (ptr == nullptr) {
        info.GetReturnValue().SetEmptyString();
        return;
    }
    auto isolate = info.GetIsolate();

    auto value = ptr->GetURL()->get_hash();
    info.GetReturnValue().Set(ToV8String(isolate, value.data(), (int)value.length()));

}

void URLImpl::SetHash(v8::Local<v8::String> property,
                      v8::Local<v8::Value> value,
                      const v8::PropertyCallbackInfo<void> &info) {
    URLImpl *ptr = GetPointer(info.This());
    if (ptr == nullptr) {
        return;
    }
    auto isolate = info.GetIsolate();
    auto context = isolate->GetCurrentContext();
    auto val = tns::ToString(isolate, value->ToString(context).ToLocalChecked());
    ptr->GetURL()->set_hash(val.c_str());
}


void URLImpl::GetHost(v8::Local<v8::String> property,
                      const v8::PropertyCallbackInfo<v8::Value> &info) {
    URLImpl *ptr = GetPointer(info.This());
    if (ptr == nullptr) {
        info.GetReturnValue().SetEmptyString();
        return;
    }
    auto isolate = info.GetIsolate();

    auto value = ptr->GetURL()->get_host();
    info.GetReturnValue().Set(ToV8String(isolate, value.data(), (int)value.length()));
    
}

void URLImpl::SetHost(v8::Local<v8::String> property,
                      v8::Local<v8::Value> value,
                      const v8::PropertyCallbackInfo<void> &info) {
    URLImpl *ptr = GetPointer(info.This());
    if (ptr == nullptr) {
        return;
    }
    auto isolate = info.GetIsolate();
    auto context = isolate->GetCurrentContext();
    auto val = tns::ToString(isolate, value->ToString(context).ToLocalChecked());
    ptr->GetURL()->set_host(val.c_str());
}


void URLImpl::GetHostName(v8::Local<v8::String> property,
                          const v8::PropertyCallbackInfo<v8::Value> &info) {
    URLImpl *ptr = GetPointer(info.This());
    if (ptr == nullptr) {
        info.GetReturnValue().SetEmptyString();
        return;
    }
    auto isolate = info.GetIsolate();
    auto value = ptr->GetURL()->get_hostname();

    info.GetReturnValue().Set(ToV8String(isolate, value.data(), (int)value.length()));

}

void URLImpl::SetHostName(v8::Local<v8::String> property,
                          v8::Local<v8::Value> value,
                          const v8::PropertyCallbackInfo<void> &info) {
    URLImpl *ptr = GetPointer(info.This());
    if (ptr == nullptr) {
        return;
    }
    auto isolate = info.GetIsolate();
    auto context = isolate->GetCurrentContext();
    auto val = tns::ToString(isolate, value->ToString(context).ToLocalChecked());
    ptr->GetURL()->set_hostname(val.c_str());
}


void URLImpl::GetHref(v8::Local<v8::String> property,
                      const v8::PropertyCallbackInfo<v8::Value> &info) {
    URLImpl *ptr = GetPointer(info.This());
    if (ptr == nullptr) {
        info.GetReturnValue().SetEmptyString();
        return;
    }
    auto isolate = info.GetIsolate();

    auto value = ptr->GetURL()->get_hostname();

    info.GetReturnValue().Set(ToV8String(isolate, value.data(), (int)value.length()));

}

void URLImpl::SetHref(v8::Local<v8::String> property,
                      v8::Local<v8::Value> value,
                      const v8::PropertyCallbackInfo<void> &info) {
    URLImpl *ptr = GetPointer(info.This());
    if (ptr == nullptr) {
        return;
    }
    auto isolate = info.GetIsolate();
    auto context = isolate->GetCurrentContext();
    auto val = tns::ToString(isolate, value->ToString(context).ToLocalChecked());
    ptr->GetURL()->set_href(val.c_str());
}

void URLImpl::GetOrigin(v8::Local<v8::String> property,
                        const v8::PropertyCallbackInfo<v8::Value> &info) {
    URLImpl *ptr = GetPointer(info.This());
    if (ptr == nullptr) {
        info.GetReturnValue().SetEmptyString();
        return;
    }
    auto isolate = info.GetIsolate();

    auto value = ptr->GetURL()->get_origin();

    info.GetReturnValue().Set(ToV8String(isolate, value.c_str()));

}

void URLImpl::GetPassword(v8::Local<v8::String> property,
                          const v8::PropertyCallbackInfo<v8::Value> &info) {
    URLImpl *ptr = GetPointer(info.This());
    if (ptr == nullptr) {
        info.GetReturnValue().SetEmptyString();
        return;
    }
    auto isolate = info.GetIsolate();

    auto value = ptr->GetURL()->get_password();

    info.GetReturnValue().Set(ToV8String(isolate, value.data(), (int)value.length()));

}

void URLImpl::SetPassword(v8::Local<v8::String> property,
                          v8::Local<v8::Value> value,
                          const v8::PropertyCallbackInfo<void> &info) {
    URLImpl *ptr = GetPointer(info.This());
    if (ptr == nullptr) {
        return;
    }
    auto isolate = info.GetIsolate();
    auto context = isolate->GetCurrentContext();
    auto val = tns::ToString(isolate, value->ToString(context).ToLocalChecked());
    ptr->GetURL()->set_password(val.c_str());
}

void URLImpl::GetPathName(v8::Local<v8::String> property,
                          const v8::PropertyCallbackInfo<v8::Value> &info) {
    URLImpl *ptr = GetPointer(info.This());
    if (ptr == nullptr) {
        info.GetReturnValue().SetEmptyString();
        return;
    }
    auto isolate = info.GetIsolate();

    auto value = ptr->GetURL()->get_pathname();

    info.GetReturnValue().Set(ToV8String(isolate, value.data()));

}

void URLImpl::SetPathName(v8::Local<v8::String> property,
                          v8::Local<v8::Value> value,
                          const v8::PropertyCallbackInfo<void> &info) {
    URLImpl *ptr = GetPointer(info.This());
    if (ptr == nullptr) {
        return;
    }
    auto isolate = info.GetIsolate();
    auto context = isolate->GetCurrentContext();
    auto val = tns::ToString(isolate, value->ToString(context).ToLocalChecked());
    ptr->GetURL()->set_pathname(val.c_str());
}

void URLImpl::GetPort(v8::Local<v8::String> property,
                      const v8::PropertyCallbackInfo<v8::Value> &info) {
    URLImpl *ptr = GetPointer(info.This());
    if (ptr == nullptr) {
        info.GetReturnValue().SetEmptyString();
        return;
    }
    auto isolate = info.GetIsolate();

    auto value = ptr->GetURL()->get_port();

    info.GetReturnValue().Set(ToV8String(isolate, value.data(), (int)value.length()));

}

void URLImpl::SetPort(v8::Local<v8::String> property,
                      v8::Local<v8::Value> value,
                      const v8::PropertyCallbackInfo<void> &info) {
    URLImpl *ptr = GetPointer(info.This());
    if (ptr == nullptr) {
        return;
    }
    auto isolate = info.GetIsolate();
    auto context = isolate->GetCurrentContext();
    auto val = tns::ToString(isolate, value->ToString(context).ToLocalChecked());
    ptr->GetURL()->set_port(val.c_str());
}

void URLImpl::GetProtocol(v8::Local<v8::String> property,
                          const v8::PropertyCallbackInfo<v8::Value> &info) {
    URLImpl *ptr = GetPointer(info.This());
    if (ptr == nullptr) {
        info.GetReturnValue().SetEmptyString();
        return;
    }
    auto isolate = info.GetIsolate();

    auto value = ptr->GetURL()->get_protocol();

    info.GetReturnValue().Set(ToV8String(isolate, value.data(), (int)value.length()));

}

void URLImpl::SetProtocol(v8::Local<v8::String> property,
                          v8::Local<v8::Value> value,
                          const v8::PropertyCallbackInfo<void> &info) {
    URLImpl *ptr = GetPointer(info.This());
    if (ptr == nullptr) {
        return;
    }
    auto isolate = info.GetIsolate();
    auto context = isolate->GetCurrentContext();
    auto val = tns::ToString(isolate, value->ToString(context).ToLocalChecked());
    ptr->GetURL()->set_protocol(val.c_str());
}


void URLImpl::GetSearch(v8::Local<v8::String> property,
                        const v8::PropertyCallbackInfo<v8::Value> &info) {
    URLImpl *ptr = GetPointer(info.This());
    if (ptr == nullptr) {
        info.GetReturnValue().SetEmptyString();
        return;
    }
    auto isolate = info.GetIsolate();

    auto value = ptr->GetURL()->get_search();

    info.GetReturnValue().Set(ToV8String(isolate, value.data(), (int)value.length()));

}

void URLImpl::SetSearch(v8::Local<v8::String> property,
                        v8::Local<v8::Value> value,
                        const v8::PropertyCallbackInfo<void> &info) {
    URLImpl *ptr = GetPointer(info.This());
    if (ptr == nullptr) {
        return;
    }
    auto isolate = info.GetIsolate();
    auto context = isolate->GetCurrentContext();
    auto val = tns::ToString(isolate, value->ToString(context).ToLocalChecked());
    ptr->GetURL()->set_search(val.c_str());
}


void URLImpl::GetUserName(v8::Local<v8::String> property,
                          const v8::PropertyCallbackInfo<v8::Value> &info) {
    URLImpl *ptr = GetPointer(info.This());
    if (ptr == nullptr) {
        info.GetReturnValue().SetEmptyString();
        return;
    }
    auto isolate = info.GetIsolate();

    auto value = ptr->GetURL()->get_username();

    info.GetReturnValue().Set(ToV8String(isolate, value.data(), (int)value.length()));

}

void URLImpl::SetUserName(v8::Local<v8::String> property,
                          v8::Local<v8::Value> value,
                          const v8::PropertyCallbackInfo<void> &info) {
    URLImpl *ptr = GetPointer(info.This());
    if (ptr == nullptr) {
        return;
    }
    auto isolate = info.GetIsolate();
    auto context = isolate->GetCurrentContext();
    auto val = tns::ToString(isolate, value->ToString(context).ToLocalChecked());
    ptr->GetURL()->set_username(val.c_str());
}


void URLImpl::ToString(const v8::FunctionCallbackInfo<v8::Value> &args) {
    URLImpl *ptr = GetPointer(args.This());
    if (ptr == nullptr) {
        args.GetReturnValue().SetEmptyString();
        return;
    }
    auto isolate = args.GetIsolate();


    auto value = ptr->GetURL()->get_href();

    auto ret = ToV8String(isolate, value.data(), (int)value.length());

    args.GetReturnValue().Set(ret);
}


void URLImpl::CanParse(const v8::FunctionCallbackInfo<v8::Value> &args) {
    bool value;
    auto count = args.Length();


    auto isolate = args.GetIsolate();
    if (count > 1) {
        auto url_string = tns::ToString(isolate, args[0].As<v8::String>());
        auto base_string = tns::ToString(isolate, args[1].As<v8::String>());
        std::string_view base_string_view(base_string.data(), base_string.length());
        value = can_parse(url_string, &base_string_view);
    } else {
        value = can_parse(tns::ToString(isolate, args[0].As<v8::String>()).c_str(), nullptr);
    }

    args.GetReturnValue().Set(value);
}


NODE_BINDING_PER_ISOLATE_INIT_OBJ(url, tns::URLImpl::Init)
