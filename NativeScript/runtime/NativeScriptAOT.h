#ifndef NativeScriptAOT_h
#define NativeScriptAOT_h

#include <objc/message.h>
#include <objc/runtime.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef const void* NSAOTCallInfo;
typedef void (*NSAOTCallHandler)(NSAOTCallInfo info);

// --- Target extraction ---
id __ns_aot_get_target(NSAOTCallInfo info, bool* outCallSuper);
Class __ns_aot_get_static_class(NSAOTCallInfo info);

// --- Argument getters ---
id __ns_aot_arg_object(NSAOTCallInfo info, int index);
BOOL __ns_aot_arg_bool(NSAOTCallInfo info, int index);
double __ns_aot_arg_double(NSAOTCallInfo info, int index);
SEL __ns_aot_arg_selector(NSAOTCallInfo info, int index);
Class __ns_aot_arg_class(NSAOTCallInfo info, int index);
void __ns_aot_arg_struct(NSAOTCallInfo info, int index, void* dest,
                         const char* structName);

// --- Result setters ---
// __ns_aot_return_id: marshals NSString→JS string, NSNumber→JS number,
// NSNull→null
void __ns_aot_return_id(NSAOTCallInfo info, id value);
// __ns_aot_return_string: always marshals to JS string (for NSString* returns)
void __ns_aot_return_string(NSAOTCallInfo info, id value);
// __ns_aot_return_object: always wraps as ObjC object (for instancetype
// returns)
void __ns_aot_return_object(NSAOTCallInfo info, id value);
void __ns_aot_return_bool(NSAOTCallInfo info, BOOL value);
void __ns_aot_return_double(NSAOTCallInfo info, double value);
void __ns_aot_return_struct(NSAOTCallInfo info, const void* data,
                            const char* structName);
void __ns_aot_return_class(NSAOTCallInfo info, Class value);

// --- Exception handling ---
void __ns_aot_throw_exception(NSAOTCallInfo info, id exception);

// --- Registration ---
void __ns_aot_register(const char* className, const char* selector,
                       bool isStatic, NSAOTCallHandler handler);

#ifdef __cplusplus
}
#endif

#endif /* NativeScriptAOT_h */
