#import "NSExceptionSupport.h"
#import <objc/runtime.h>

NSString* const TNSJavaScriptStackTraceKey = @"JavaScriptStack";
NSString* const TNSJavaScriptEscapeStackTraceKey = @"JavaScriptEscapeStack";

// File-static, address-unique key for the associated-object slot.
static const void* kTNSJSStackKey = &kTNSJSStackKey;

@implementation NSException (NativeScript)

- (NSString* _Nullable)tns_javascriptStackTrace {
  NSString* associated = objc_getAssociatedObject(self, kTNSJSStackKey);
  if (associated != nil) {
    return associated;
  }
  id fromUserInfo = self.userInfo[TNSJavaScriptStackTraceKey];
  if ([fromUserInfo isKindOfClass:[NSString class]]) {
    return (NSString*)fromUserInfo;
  }
  return nil;
}

@end

namespace tns {

void SetJSStackOnException(id exception, NSString* stack) {
  if (exception == nil || stack == nil) {
    return;
  }
  objc_setAssociatedObject(exception, kTNSJSStackKey, stack, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

}  // namespace tns
