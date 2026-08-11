//
//  NapiRuntime.h
//  NativeScript
//
//  Copyright © 2026 Progress. All rights reserved.
//

#pragma once
#import <Foundation/Foundation.h>

#include "napi/vendor/node_api.h"

#ifdef __cplusplus
extern "C" {
#endif

// The Node-API environment of the runtime on the calling thread, or NULL when
// this thread has no runtime (or its runtime has torn down). Each runtime —
// the main one and every Worker — owns a separate env.
napi_env NativeScriptNapiEnv(void);

#ifdef __cplusplus
}
#endif

@interface NapiRuntime : NSObject
+ (napi_env)env;
@end
