//
//  NSObject+JSIRuntime.h
//  NativeScript
//
//  Created by Ammar Ahmed on 12/11/2022.
//  Copyright © 2022 Progress. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "v8runtime/V8Runtime.h"
#include "runtime/Runtime.h"

@interface JSIRuntime: NSObject
+(std::shared_ptr<facebook::jsi::Runtime>) runtime;
@end
