//
// Created by Osei Fortune on 14/01/2024.
//
#pragma once

#include "Common.h"
#include "IsolateTracked.h"
#include "ada/ada.h"

namespace tns {

class URLSearchParamsImpl : public IsolateTracked {
 public:
  URLSearchParamsImpl(ada::url_search_params params);

  ada::url_search_params* GetURLSearchParams();

  static URLSearchParamsImpl* GetPointer(v8::Local<v8::Object> object);

  static v8::Local<v8::FunctionTemplate> GetCtor(v8::Isolate* isolate);

  static void Init(v8::Isolate* isolate,
                   v8::Local<v8::ObjectTemplate> globalTemplate);

  static void Ctor(const v8::FunctionCallbackInfo<v8::Value>& args);

  static void Append(const v8::FunctionCallbackInfo<v8::Value>& args);

  static void Delete(const v8::FunctionCallbackInfo<v8::Value>& args);

  static void Entries(const v8::FunctionCallbackInfo<v8::Value>& args);

  static void ForEach(const v8::FunctionCallbackInfo<v8::Value>& args);

  static void Get(const v8::FunctionCallbackInfo<v8::Value>& args);

  static void GetAll(const v8::FunctionCallbackInfo<v8::Value>& args);

  static void Has(const v8::FunctionCallbackInfo<v8::Value>& args);

  static void Keys(const v8::FunctionCallbackInfo<v8::Value>& args);

  static void Set(const v8::FunctionCallbackInfo<v8::Value>& args);

  static void GetSize(v8::Local<v8::Name> name,
                      const v8::PropertyCallbackInfo<v8::Value>& info);

  static void Sort(const v8::FunctionCallbackInfo<v8::Value>& args);

  static void ToString(const v8::FunctionCallbackInfo<v8::Value>& args);

  static void Values(const v8::FunctionCallbackInfo<v8::Value>& args);

 private:
  ada::url_search_params params_;
};

}  // namespace tns
