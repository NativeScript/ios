//
// Created by Osei Fortune on 30/01/2025.
//

#include "URLPatternImpl.h"

#include <utility>

#include "ModuleBinding.hpp"

using namespace std;
using namespace tns;
using namespace ada;

std::optional<v8::Global<v8::RegExp>> v8_regex_provider::create_instance(
    std::string_view pattern, bool ignore_case) {
  auto isolate = v8::Isolate::GetCurrent();
  if (isolate == nullptr) {
    return std::nullopt;
  }

  v8::Local<v8::String> local_pattern;
  if (!v8::String::NewFromUtf8(isolate, pattern.data(),
                               v8::NewStringType::kNormal, (int)pattern.size())
           .ToLocal(&local_pattern)) {
    return std::nullopt;
  }

  int flags = v8::RegExp::Flags::kUnicode;
  if (ignore_case) {
    flags |= static_cast<int>(v8::RegExp::Flags::kIgnoreCase);
  }

  v8::Local<v8::RegExp> regex;

  if (!v8::RegExp::New(isolate->GetCurrentContext(), local_pattern,
                       static_cast<v8::RegExp::Flags>(flags))
           .ToLocal(&regex)) {
    return std::nullopt;
  }

  return v8::Global<v8::RegExp>(isolate, regex);
}

std::optional<std::vector<std::optional<std::string>>>
v8_regex_provider::regex_search(
    std::string_view input, const tns::v8_regex_provider::regex_type& pattern) {
  auto isolate = v8::Isolate::GetCurrent();
  if (isolate == nullptr) {
    return std::nullopt;
  }
  auto patt = pattern.Get(isolate);
  if (patt.IsEmpty()) {
    return std::nullopt;
  }

  v8::Local<v8::String> local_input;
  if (!v8::String::NewFromUtf8(isolate, input.data(),
                               v8::NewStringType::kNormal, (int)input.size())
           .ToLocal(&local_input)) {
    return std::nullopt;
  }

  v8::Local<v8::Object> matches;
  if (!patt->Exec(isolate->GetCurrentContext(), local_input)
           .ToLocal(&matches) ||
      matches->IsNull()) {
    return std::nullopt;
  }

  std::vector<std::optional<std::string>> ret;
  if (matches->IsArray()) {
    auto array = matches.As<v8::Array>();
    auto len = array->Length();
    ret.reserve(len);
    for (int i = 0; i < len; i++) {
      v8::Local<v8::Value> item;
      if (array->Get(isolate->GetCurrentContext(), i).ToLocal(&item)) {
        return std::nullopt;
      }

      if (item->IsUndefined()) {
        ret.emplace_back(std::nullopt);
      } else if (item->IsString()) {
        ret.emplace_back(tns::ToString(isolate, item));
      }
    }
  }

  return ret;
}

bool v8_regex_provider::regex_match(
    std::string_view input, const tns::v8_regex_provider::regex_type& pattern) {
  auto isolate = v8::Isolate::GetCurrent();
  if (isolate == nullptr) {
    return false;
  }

  v8::Local<v8::String> local_input;
  if (!v8::String::NewFromUtf8(isolate, input.data(),
                               v8::NewStringType::kNormal, (int)input.size())
           .ToLocal(&local_input)) {
    return false;
  }

  auto patt = pattern.Get(isolate);
  if (patt.IsEmpty()) {
    return false;
  }
  v8::Local<v8::Object> matches;

  if (!patt->Exec(isolate->GetCurrentContext(), local_input)
           .ToLocal(&matches)) {
    return false;
  }

  return !matches->IsNull();
}

URLPatternImpl::URLPatternImpl(url_pattern<v8_regex_provider> pattern)
    : pattern_(std::move(pattern)) {}

void URLPatternImpl::Init(v8::Isolate* isolate,
                          v8::Local<v8::ObjectTemplate> globalTemplate) {
  auto URLPatternTemplate = URLPatternImpl::GetCtor(isolate);

  v8::Local<v8::String> name = tns::ToV8String(isolate, "URLPattern");
  globalTemplate->Set(name, URLPatternTemplate);
}

URLPatternImpl* URLPatternImpl::GetPointer(v8::Local<v8::Object> object) {
  auto ptr = object->GetAlignedPointerFromInternalField(0);
  if (ptr == nullptr) {
    return nullptr;
  }
  return static_cast<URLPatternImpl*>(ptr);
}

url_pattern<v8_regex_provider>* URLPatternImpl::GetPattern() {
  return &this->pattern_;
}

v8::Local<v8::FunctionTemplate> URLPatternImpl::GetCtor(v8::Isolate* isolate) {
  v8::Local<v8::FunctionTemplate> ctorTmpl =
      v8::FunctionTemplate::New(isolate, Ctor);
  ctorTmpl->SetClassName(tns::ToV8String(isolate, "URLPattern"));

  auto tmpl = ctorTmpl->InstanceTemplate();
  tmpl->SetInternalFieldCount(1);

  tmpl->Set(tns::ToV8String(isolate, "test"),
            v8::FunctionTemplate::New(isolate, &Test));

  tmpl->Set(tns::ToV8String(isolate, "exec"),
            v8::FunctionTemplate::New(isolate, &Exec));

  tmpl->SetLazyDataProperty(tns::ToV8String(isolate, "hasRegExpGroups"),
                            GetHasRegExpGroups);

  tmpl->SetLazyDataProperty(tns::ToV8String(isolate, "hash"), GetHash);

  tmpl->SetLazyDataProperty(tns::ToV8String(isolate, "hostname"), GetHostName);

  tmpl->SetLazyDataProperty(tns::ToV8String(isolate, "password"), GetPassword);

  tmpl->SetLazyDataProperty(tns::ToV8String(isolate, "pathname"), GetPathName);

  tmpl->SetLazyDataProperty(tns::ToV8String(isolate, "port"), GetPort);

  tmpl->SetLazyDataProperty(tns::ToV8String(isolate, "protocol"), GetProtocol);

  tmpl->SetLazyDataProperty(tns::ToV8String(isolate, "search"), GetSearch);

  tmpl->SetLazyDataProperty(tns::ToV8String(isolate, "username"), GetUserName);

  return ctorTmpl;
}

std::optional<ada::url_pattern_init> URLPatternImpl::ParseInput(
    v8::Isolate* isolate, const v8::Local<v8::Value>& input) {
  v8::Local<v8::Value> protocol;
  v8::Local<v8::Value> username;
  v8::Local<v8::Value> password;
  v8::Local<v8::Value> hostname;
  v8::Local<v8::Value> port;
  v8::Local<v8::Value> pathname;
  v8::Local<v8::Value> search;
  v8::Local<v8::Value> hash;
  v8::Local<v8::Value> baseURL;

  if (input->IsObject()) {
    auto context = isolate->GetCurrentContext();

    auto object = input.As<v8::Object>();

    auto init = ada::url_pattern_init{};
    if (object->Get(context, tns::ToV8String(isolate, "protocol"))
            .ToLocal(&protocol) &&
        protocol->IsString()) {
      init.protocol =
          tns::ToString(isolate, protocol->ToString(context).ToLocalChecked());
    }

    if (object->Get(context, tns::ToV8String(isolate, "username"))
            .ToLocal(&username) &&
        username->IsString()) {
      init.username =
          tns::ToString(isolate, username->ToString(context).ToLocalChecked());
    }

    if (object->Get(context, tns::ToV8String(isolate, "password"))
            .ToLocal(&password) &&
        password->IsString()) {
      init.password =
          tns::ToString(isolate, password->ToString(context).ToLocalChecked());
    }

    if (object->Get(context, tns::ToV8String(isolate, "hostname"))
            .ToLocal(&hostname) &&
        hostname->IsString()) {
      init.hostname =
          tns::ToString(isolate, hostname->ToString(context).ToLocalChecked());
    }

    if (object->Get(context, tns::ToV8String(isolate, "port")).ToLocal(&port) &&
        port->IsString()) {
      init.port =
          tns::ToString(isolate, port->ToString(context).ToLocalChecked());
    }

    if (object->Get(context, tns::ToV8String(isolate, "pathname"))
            .ToLocal(&pathname) &&
        pathname->IsString()) {
      init.pathname =
          tns::ToString(isolate, pathname->ToString(context).ToLocalChecked());
    }

    if (object->Get(context, tns::ToV8String(isolate, "search"))
            .ToLocal(&search) &&
        search->IsString()) {
      init.search =
          tns::ToString(isolate, search->ToString(context).ToLocalChecked());
    }

    if (object->Get(context, tns::ToV8String(isolate, "hash")).ToLocal(&hash) &&
        hash->IsString()) {
      init.hash =
          tns::ToString(isolate, hash->ToString(context).ToLocalChecked());
    }

    if (object->Get(context, tns::ToV8String(isolate, "baseURL"))
            .ToLocal(&baseURL) &&
        baseURL->IsString()) {
      init.base_url =
          tns::ToString(isolate, baseURL->ToString(context).ToLocalChecked());
    }
    return init;
  }

  return {};
}

void SetComponent(v8::Isolate* isolate, const v8::Local<v8::Object>& object,
                  const std::string& componentKey,
                  const url_pattern_component_result& component) {
  auto ctx = isolate->GetCurrentContext();
  auto ret = v8::Object::New(isolate);
  [[maybe_unused]] auto _ = ret->Set(ctx, tns::ToV8String(isolate, "input"),
                                     tns::ToV8String(isolate, component.input));

  auto groupValue = v8::Object::New(isolate);

  for (const auto& [key, value] : component.groups) {
    if (value) {
      _ = groupValue->Set(ctx, tns::ToV8String(isolate, key),
                          tns::ToV8String(isolate, value.value()));
    } else {
      _ = groupValue->Set(ctx, tns::ToV8String(isolate, key),
                          v8::Undefined(isolate));
    }
  }

  _ = ret->Set(ctx, tns::ToV8String(isolate, "groups"), groupValue);

  _ = object->Set(ctx, tns::ToV8String(isolate, componentKey), ret);
}

void BuildJS(v8::Isolate* isolate, const v8::Local<v8::Object>& object,
             const url_pattern_result& result) {
  auto ctx = isolate->GetCurrentContext();

  auto len = result.inputs.size();
  auto inputs = v8::Array::New(isolate, (int)len);
  for (int i = 0; i < len; i++) {
    auto item = result.inputs[i];

    if (std::holds_alternative<std::string_view>(item)) {
      auto view = std::get<std::string_view>(item);
      if (view.empty()) {
        [[maybe_unused]] auto _ =
            inputs->Set(ctx, i, v8::String::Empty(isolate));
      } else {
        [[maybe_unused]] auto _ = inputs->Set(
            ctx, i, tns::ToV8String(isolate, view.data(), (int)view.size()));
      }
    }
  }

  [[maybe_unused]] auto _ =
      object->Set(ctx, tns::ToV8String(isolate, "inputs"), inputs);

  SetComponent(isolate, object, "protocol", result.protocol);
  SetComponent(isolate, object, "hash", result.hash);
  SetComponent(isolate, object, "hostname", result.hostname);
  SetComponent(isolate, object, "username", result.username);
  SetComponent(isolate, object, "password", result.password);
  SetComponent(isolate, object, "pathname", result.pathname);
  SetComponent(isolate, object, "port", result.port);
  SetComponent(isolate, object, "search", result.search);
}

void URLPatternImpl::Ctor(const v8::FunctionCallbackInfo<v8::Value>& args) {
  auto isolate = args.GetIsolate();

  if (args.Length() == 0) {
    auto thiz = args.This();
    auto init = ada::url_pattern_init{};
    ada::url_pattern_input input = init;
    auto url_pattern =
        ada::parse_url_pattern<v8_regex_provider>(std::move(input));
    if (!url_pattern) {
      isolate->ThrowException(v8::Exception::TypeError(
          tns::ToV8String(isolate, "Failed to construct URLPattern")));
      return;
    }

    auto patternImpl = new URLPatternImpl(std::move(*url_pattern));

    thiz->SetAlignedPointerInInternalField(0, patternImpl);

    patternImpl->BindFinalizer(isolate, thiz);

    args.GetReturnValue().Set(thiz);

    return;
  }

  auto baseOrOptions = args[1];
  auto opts = args[2];
  auto context = isolate->GetCurrentContext();

  std::optional<ada::url_pattern_init> init{};
  std::optional<std::string> input{};
  std::optional<std::string> base_url{};
  std::optional<ada::url_pattern_options> options{};

  if (args[0]->IsString()) {
    auto inputValue =
        tns::ToString(isolate, args[0]->ToString(context).ToLocalChecked());

    input = inputValue;
  } else if (args[0]->IsObject()) {
    auto parsed = ParseInput(isolate, args[0]);
    if (parsed) {
      init = std::move(*parsed);
    }
  } else {
    isolate->ThrowException(v8::Exception::TypeError(
        tns::ToV8String(isolate, "Input must be an object or a string")));
    return;
  }

  if (!baseOrOptions.IsEmpty()) {
    if (baseOrOptions->IsString()) {
      auto baseValue = tns::ToString(
          isolate, baseOrOptions->ToString(context).ToLocalChecked());
      base_url = baseValue;
    } else if (baseOrOptions->IsObject()) {
      auto object = baseOrOptions.As<v8::Object>();
      v8::Local<v8::Value> ignoreCase;

      if (object->Get(context, tns::ToV8String(isolate, "ignoreCase"))
              .ToLocal(&ignoreCase) &&
          ignoreCase->IsBoolean()) {
        options = ada::url_pattern_options{.ignore_case =
                                               object->BooleanValue(isolate)};
      }
    }
  }

  if (!opts.IsEmpty() && opts->IsObject()) {
    auto object = opts.As<v8::Object>();
    v8::Local<v8::Value> ignoreCase;

    if (object->Get(context, tns::ToV8String(isolate, "ignoreCase"))
            .ToLocal(&ignoreCase) &&
        ignoreCase->IsBoolean()) {
      options = ada::url_pattern_options{.ignore_case =
                                             object->BooleanValue(isolate)};
    }
  }

  auto thiz = args.This();

  std::string_view base_url_view{};

  if (base_url) {
    base_url_view = {base_url->data(), base_url->size()};
  }

  ada::url_pattern_input arg0;

  if (init.has_value()) {
    arg0 = *init;
  } else {
    arg0 = *input;
  }

  auto url_pattern = ada::parse_url_pattern<v8_regex_provider>(
      std::move(arg0), base_url.has_value() ? &base_url_view : nullptr,
      options.has_value() ? &options.value() : nullptr);
  if (!url_pattern) {
    isolate->ThrowException(v8::Exception::TypeError(
        tns::ToV8String(isolate, "Failed to construct URLPattern")));
    return;
  } else {
    auto patternImpl = new URLPatternImpl(std::move(*url_pattern));

    thiz->SetAlignedPointerInInternalField(0, patternImpl);

    patternImpl->BindFinalizer(isolate, thiz);

    args.GetReturnValue().Set(thiz);
  }
}

void URLPatternImpl::GetHash(v8::Local<v8::Name> property,
                             const v8::PropertyCallbackInfo<v8::Value>& info) {
  URLPatternImpl* ptr = GetPointer(info.This());
  if (ptr == nullptr) {
    info.GetReturnValue().SetEmptyString();
    return;
  }
  auto isolate = info.GetIsolate();

  auto value = ptr->GetPattern()->get_hash();
  info.GetReturnValue().Set(
      tns::ToV8String(isolate, value.data(), (int)value.length()));
}

void URLPatternImpl::GetHostName(
    v8::Local<v8::Name> property,
    const v8::PropertyCallbackInfo<v8::Value>& info) {
  URLPatternImpl* ptr = GetPointer(info.This());
  if (ptr == nullptr) {
    info.GetReturnValue().SetEmptyString();
    return;
  }
  auto isolate = info.GetIsolate();
  auto value = ptr->GetPattern()->get_hostname();

  info.GetReturnValue().Set(
      tns::ToV8String(isolate, value.data(), (int)value.length()));
}

void URLPatternImpl::GetPassword(
    v8::Local<v8::Name> property,
    const v8::PropertyCallbackInfo<v8::Value>& info) {
  URLPatternImpl* ptr = GetPointer(info.This());
  if (ptr == nullptr) {
    info.GetReturnValue().SetEmptyString();
    return;
  }
  auto isolate = info.GetIsolate();

  auto value = ptr->GetPattern()->get_password();

  info.GetReturnValue().Set(
      tns::ToV8String(isolate, value.data(), (int)value.length()));
}

void URLPatternImpl::GetPathName(
    v8::Local<v8::Name> property,
    const v8::PropertyCallbackInfo<v8::Value>& info) {
  URLPatternImpl* ptr = GetPointer(info.This());
  if (ptr == nullptr) {
    info.GetReturnValue().SetEmptyString();
    return;
  }
  auto isolate = info.GetIsolate();

  auto value = ptr->GetPattern()->get_pathname();

  info.GetReturnValue().Set(
      tns::ToV8String(isolate, value.data(), (int)value.length()));
}

void URLPatternImpl::GetPort(v8::Local<v8::Name> property,
                             const v8::PropertyCallbackInfo<v8::Value>& info) {
  URLPatternImpl* ptr = GetPointer(info.This());
  if (ptr == nullptr) {
    info.GetReturnValue().SetEmptyString();
    return;
  }
  auto isolate = info.GetIsolate();

  auto value = ptr->GetPattern()->get_port();

  info.GetReturnValue().Set(
      tns::ToV8String(isolate, value.data(), (int)value.length()));
}

void URLPatternImpl::GetProtocol(
    v8::Local<v8::Name> property,
    const v8::PropertyCallbackInfo<v8::Value>& info) {
  URLPatternImpl* ptr = GetPointer(info.This());
  if (ptr == nullptr) {
    info.GetReturnValue().SetEmptyString();
    return;
  }
  auto isolate = info.GetIsolate();

  auto value = ptr->GetPattern()->get_protocol();

  info.GetReturnValue().Set(
      tns::ToV8String(isolate, value.data(), (int)value.length()));
}

void URLPatternImpl::GetSearch(
    v8::Local<v8::Name> property,
    const v8::PropertyCallbackInfo<v8::Value>& info) {
  URLPatternImpl* ptr = GetPointer(info.This());
  if (ptr == nullptr) {
    info.GetReturnValue().SetEmptyString();
    return;
  }
  auto isolate = info.GetIsolate();

  auto value = ptr->GetPattern()->get_search();

  info.GetReturnValue().Set(
      tns::ToV8String(isolate, value.data(), (int)value.length()));
}

void URLPatternImpl::GetUserName(
    v8::Local<v8::Name> property,
    const v8::PropertyCallbackInfo<v8::Value>& info) {
  URLPatternImpl* ptr = GetPointer(info.This());
  if (ptr == nullptr) {
    info.GetReturnValue().SetEmptyString();
    return;
  }
  auto isolate = info.GetIsolate();

  auto value = ptr->GetPattern()->get_username();

  info.GetReturnValue().Set(
      tns::ToV8String(isolate, value.data(), (int)value.length()));
}

void URLPatternImpl::GetHasRegExpGroups(
    v8::Local<v8::Name> property,
    const v8::PropertyCallbackInfo<v8::Value>& info) {
  URLPatternImpl* ptr = GetPointer(info.This());
  if (ptr == nullptr) {
    info.GetReturnValue().Set(false);
    return;
  }

  auto value = ptr->GetPattern()->has_regexp_groups();

  info.GetReturnValue().Set(value);
}

void URLPatternImpl::Test(const v8::FunctionCallbackInfo<v8::Value>& args) {
  URLPatternImpl* ptr = GetPointer(args.This());
  if (ptr == nullptr) {
    args.GetReturnValue().Set(false);
    return;
  }
  auto isolate = args.GetIsolate();
  auto ctx = isolate->GetCurrentContext();

  ada::url_pattern_input input;
  std::optional<std::string> baseURL{};
  std::string input_base;

  if (args.Length() == 0) {
    input = ada::url_pattern_init{};
  } else if (args[0]->IsObject()) {
    auto parsed = ParseInput(isolate, args[0]);
    if (parsed) {
      input = std::move(*parsed);
    }
  } else if (args[0]->IsString()) {
    input_base =
        tns::ToString(isolate, args[0]->ToString(ctx).ToLocalChecked());
    input = std::string_view(input_base);
  } else {
    isolate->ThrowException(v8::Exception::TypeError(tns::ToV8String(
        isolate, "URLPattern input needs to be a string or an object")));
    return;
  };

  std::optional<std::string> baseUrl{};

  if (args.Length() > 1) {
    if (!args[1]->IsString()) {
      isolate->ThrowException(v8::Exception::TypeError(
          tns::ToV8String(isolate, "baseURL must be a string")));
      return;
    }
    baseURL = tns::ToString(isolate, args[1].As<v8::String>());
  }

  std::optional<std::string_view> baseURL_opt =
      baseURL ? std::optional<std::string_view>(*baseURL) : std::nullopt;

  if (auto result = ptr->GetPattern()->test(
          input, baseURL_opt ? &*baseURL_opt : nullptr)) {
    args.GetReturnValue().Set(result.value());
  } else {
    args.GetReturnValue().SetNull();
  }
}

void URLPatternImpl::Exec(const v8::FunctionCallbackInfo<v8::Value>& args) {
  URLPatternImpl* ptr = GetPointer(args.This());
  if (ptr == nullptr) {
    args.GetReturnValue().Set(false);
    return;
  }
  auto isolate = args.GetIsolate();

  auto ctx = isolate->GetCurrentContext();
  ada::url_pattern_input input;
  std::optional<std::string> baseURL{};
  std::string input_base;

  if (args.Length() == 0) {
    input = ada::url_pattern_init{};
  } else if (args[0]->IsObject()) {
    auto parsed = ParseInput(isolate, args[0]);
    if (parsed) {
      input = std::move(*parsed);
    }
  } else if (args[0]->IsString()) {
    input_base =
        tns::ToString(isolate, args[0]->ToString(ctx).ToLocalChecked());
    input = std::string_view(input_base);
  } else {
    isolate->ThrowException(v8::Exception::TypeError(tns::ToV8String(
        isolate, "URLPattern input needs to be a string or an object")));
    return;
  };

  if (args.Length() > 1) {
    if (!args[1]->IsString()) {
      isolate->ThrowException(v8::Exception::TypeError(
          tns::ToV8String(isolate, "baseURL must be a string")));
      return;
    }
    baseURL = tns::ToString(isolate, args[1].As<v8::String>());
  }

  std::optional<std::string_view> baseURL_opt =
      baseURL ? std::optional<std::string_view>(*baseURL) : std::nullopt;

  if (auto result = ptr->GetPattern()->exec(
          input, baseURL_opt ? &*baseURL_opt : nullptr)) {
    if (result.has_value()) {
      auto value = result.value();

      if (value.has_value()) {
        auto object = v8::Object::New(isolate);

        BuildJS(isolate, object, result->value());

        args.GetReturnValue().Set(object);
      } else {
        args.GetReturnValue().SetNull();
      }

    } else {
      args.GetReturnValue().SetNull();
    }
  } else {
    args.GetReturnValue().SetNull();
  }
}

NODE_BINDING_PER_ISOLATE_INIT_OBJ(urlpattern, tns::URLPatternImpl::Init)
