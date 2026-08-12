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
  // The thread-local can go stale when a Runtime is destroyed on a different
  // thread than the one that created it; confirm liveness against the registry
  // before dereferencing.
  if (runtime == nullptr || !tns::Runtime::IsAlive(runtime)) {
    return nullptr;
  }

  return runtime->GetNapiEnv();
}

@implementation NapiRuntime

+ (napi_env)env {
  return NativeScriptNapiEnv();
}

@end
