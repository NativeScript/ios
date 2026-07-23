#ifndef NSExceptionSupport_h
#define NSExceptionSupport_h

// This header is only meaningful inside ObjC/ObjC++ translation units — it
// declares an NSException category and Foundation-typed helpers. Do NOT include
// it from a plain .cpp.
#if defined(__OBJC__)

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// userInfo key under which synthesized escapes and the crash-flag exception
// carry the captured JavaScript stack trace. This is the documented, stable
// contract for crash-SDK integrations (its value matches the historical
// userInfo key so existing consumers keep working).
extern NSString* const TNSJavaScriptStackTraceKey;

// userInfo key under which the escape-site ("escaped at") JS stack is carried,
// present on synthesized escapes only when it differs from the origin stack.
extern NSString* const TNSJavaScriptEscapeStackTraceKey;

@interface NSException (NativeScript)

// Returns the JavaScript stack trace associated with this exception, or nil.
// Stable API for crash-SDK integrations: works uniformly for both synthesized
// escapes and rethrown original native exceptions. Prefers the associated-object
// stack (attached without mutating the exception's identity or userInfo),
// falling back to userInfo[TNSJavaScriptStackTraceKey], then nil.
- (NSString* _Nullable)tns_javascriptStackTrace;

@end

#ifdef __cplusplus
namespace tns {

// Attaches `stack` to `exception` as a copied associated object so
// tns_javascriptStackTrace can surface it without mutating the exception's
// identity or userInfo. No-op when either argument is nil.
void SetJSStackOnException(id exception, NSString* stack);

}  // namespace tns
#endif

NS_ASSUME_NONNULL_END

#endif /* __OBJC__ */

#endif /* NSExceptionSupport_h */
