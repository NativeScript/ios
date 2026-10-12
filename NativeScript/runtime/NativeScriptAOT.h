#ifndef NativeScriptAOT_h
#define NativeScriptAOT_h

// C bridge between app-compiled AOT call stubs and the runtime.
//
// A stub is a plain C function generated per (class, selector) by
// scripts/generate-aot.py from the app's aot-config.json and the metadata
// generator's JSON output. The stub is bound to the method or property getter
// when the class's prototype template is built, so V8 calls it directly in
// place of the generic libffi path. Everything the stub needs from the
// runtime goes through the functions below; it never includes runtime
// headers.
//
// Contract:
//  - A handler returns true when it handled the call (set a return value or
//    threw into V8) and false to decline, in which case the runtime runs the
//    generic path for the same call. A declining handler must not have set a
//    return value, thrown, or had side effects. Declining is how stubs stay
//    correct for everything they do not model: alloc receivers, argument-count
//    mismatches (overloads, optional NSError** out parameters), non-object
//    receivers.
//  - Argument getters return false when conversion threw into V8; the handler
//    must then return true without sending the message.
//  - Exceptions thrown by the callee (NSException) must be caught by the stub
//    and passed to __ns_aot_throw_exception, which converts them the way the
//    generic path does.
//  - Values returned by the callee with +1 ownership (init, copy, new, or
//    methods flagged as owning their return) are passed with owned = true so
//    the runtime balances the retain. The stub file may be compiled with or
//    without ARC; the cast objc_msgSend calls are +0 to ARC either way.
//  - Struct types are resolved once per stub through __ns_aot_struct_type and
//    the handle passed back; the handle is stable for the process lifetime.
//
// This header is public API of the framework and is kept C-compatible.

#include <objc/message.h>
#include <objc/runtime.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef const void* NSAOTCallInfo;
typedef const void* NSAOTStructType;
typedef bool (*NSAOTCallHandler)(NSAOTCallInfo info);

// --- Receiver ---

int __ns_aot_arg_count(NSAOTCallInfo info);

// Returns the receiver for an instance call, or nil when the stub must decline
// (no wrapper, alloc wrapper, non-object wrapper). On success *outSelector is
// the selector to send (the runtime may redirect to a swizzled selector) and
// *outCallSuper tells the stub to use objc_msgSendSuper against the
// receiver's superclass, which is how instances of JS-extended classes reach
// the native implementation.
id __ns_aot_get_target(NSAOTCallInfo info, SEL selector, SEL* outSelector,
                       bool* outCallSuper);

// Returns the class for a static call, or nil when the stub must decline.
Class __ns_aot_get_static_class(NSAOTCallInfo info);

// --- Arguments ---
// Each returns false if the conversion threw into V8.

bool __ns_aot_arg_object(NSAOTCallInfo info, int index, id* out);
bool __ns_aot_arg_bool(NSAOTCallInfo info, int index, BOOL* out);
bool __ns_aot_arg_int64(NSAOTCallInfo info, int index, int64_t* out);
bool __ns_aot_arg_uint64(NSAOTCallInfo info, int index, uint64_t* out);
bool __ns_aot_arg_double(NSAOTCallInfo info, int index, double* out);
bool __ns_aot_arg_selector(NSAOTCallInfo info, int index, SEL* out);
bool __ns_aot_arg_class(NSAOTCallInfo info, int index, Class* out);
bool __ns_aot_arg_pointer(NSAOTCallInfo info, int index, void** out);
bool __ns_aot_arg_struct(NSAOTCallInfo info, int index, NSAOTStructType type,
                         void* dest);

// --- Return values ---

// marshalToPrimitive mirrors the generic path: NSString, NSNumber, NSDate and
// NSNull become JS primitives unless the declared return type is instancetype
// (and an NSString stays an object when the declared type is NSMutableString).
void __ns_aot_return_object(NSAOTCallInfo info, id value, bool owned,
                            bool marshalToPrimitive);
void __ns_aot_return_bool(NSAOTCallInfo info, BOOL value);
void __ns_aot_return_int64(NSAOTCallInfo info, int64_t value);
void __ns_aot_return_uint64(NSAOTCallInfo info, uint64_t value);
void __ns_aot_return_double(NSAOTCallInfo info, double value);
void __ns_aot_return_selector(NSAOTCallInfo info, SEL value);
void __ns_aot_return_class(NSAOTCallInfo info, Class value);
void __ns_aot_return_pointer(NSAOTCallInfo info, void* value);
void __ns_aot_return_struct(NSAOTCallInfo info, NSAOTStructType type,
                            const void* data);

// --- Structs ---

// Resolves a struct type by its metadata name (e.g. "CGRect"). Returns NULL
// if the metadata has no such struct; the stub must then decline.
NSAOTStructType __ns_aot_struct_type(const char* name);

// --- Exceptions ---

void __ns_aot_throw_exception(NSAOTCallInfo info, id exception);

// --- Registration ---

// The generated stubs file exports
//   void __ns_register_aot_calls(void (*reg)(const char*, const char*, bool,
//                                            NSAOTCallHandler));
// which the runtime locates with dlsym at startup and calls once; it must call
// reg(className, selector, isStatic, handler) for every stub. className is
// the class whose metadata declares the member (or adopts the protocol that
// does).

#ifdef __cplusplus
}
#endif

#endif /* NativeScriptAOT_h */
