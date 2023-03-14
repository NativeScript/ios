//
//  NSObject+JSIRuntime.m
//  NativeScript
//
//  Created by Ammar Ahmed on 12/11/2022.
//  Copyright © 2022 Progress. All rights reserved.
//

#import "JSIRuntime.h"
@implementation JSIRuntime

static std::shared_ptr<facebook::jsi::Runtime> rt;

+(std::shared_ptr<facebook::jsi::Runtime>)runtime {
  if (!rt) {
    rt = std::make_shared<rnv8::V8Runtime>();
  }
  return rt;
}

@end
