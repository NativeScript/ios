//
//  NapiRuntime.mm
//  NativeScript
//
//  Copyright © 2026 Progress. All rights reserved.
//

#import "NapiRuntime.h"

#include "runtime/Runtime.h"

extern "C" napi_env NativeScriptNapiEnv(void) {
  tns::Runtime* runtime = tns::Runtime::GetCurrentRuntime();
  return runtime != nullptr ? runtime->GetNapiEnv() : nullptr;
}

@implementation NapiRuntime

+ (napi_env)env {
  return NativeScriptNapiEnv();
}

@end
