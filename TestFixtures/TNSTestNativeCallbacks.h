#include "Api/TNSApi.h"
#include "Interfaces/TNSInheritance.h"
#include "Marshalling/TNSRecords.h"

@interface TNSTestNativeCallbacks : NSObject

+ (void)inheritanceMethodCalls:(TNSDerivedInterface*)derivedInterface;

+ (void)inheritanceConstructorCalls:(Class)JSDerivedInterface;

+ (void)inheritancePropertyCalls:(TNSDerivedInterface*)object;

+ (void)inheritanceVoidSelector:(id)object;

+ (id)inheritanceVariadicSelector:(id)object;

+ (void)inheritanceOptionalProtocolMethodsAndCategories:(TNSIDerivedInterface*)object;

+ (void)apiCustomGetterAndSetter:(TNSApi*)object;

+ (void)apiOverrideWithCustomGetterAndSetter:(TNSApi*)object;

+ (void)apiReadonlyPropertyInProtocolAndOverrideWithSetterInInterface:(UIView*)object;

+ (void)apiDescriptionOverride:(id)object;

+ (void)apiNSErrorOverride:(TNSApi*)object;

+ (void)apiNSErrorExpose:(TNSApi*)object;

+ (void)protocolImplementationMethods:(id<TNSBaseProtocol1, NSObject>)object;

+ (void)categoryProtocolImplementationMethods:(id<TNSBaseCategoryProtocol1, NSObject>)object;

+ (void)protocolImplementationProtocolInheritance:(id<TNSBaseProtocol2, NSObject>)object;

+ (void)protocolImplementationOptionalMethods:(id<TNSBaseProtocol2, NSObject>)object;

+ (void)protocolImplementationProperties:(id<TNSBaseProtocol1, NSObject>)object;

+ (BOOL)protocolWithNameConflict:(id<TNSPropertyMethodConflictProtocol, NSObject>)object;

+ (TNSSimpleStruct)recordsSimpleStruct:(TNSSimpleStruct)object;

+ (TNSStruct16)recordsStruct16:(TNSStruct16)object;

+ (TNSStruct24)recordsStruct24:(TNSStruct24)object;

+ (TNSStruct32)recordsStruct32:(TNSStruct32)object;

+ (TNSNestedStruct)recordsNestedStruct:(TNSNestedStruct)object;

+ (TNSStructWithArray)recordsStructWithArray:(TNSStructWithArray)object;

+ (TNSNestedAnonymousStruct)recordsNestedAnonymousStruct:(TNSNestedAnonymousStruct)object;

+ (TNSComplexStruct)recordsComplexStruct:(TNSComplexStruct)object;

+ (void)recordsPointer:(TNSSimpleStruct*)object;

+ (void)apiNSMutableArrayMethods:(NSMutableArray*)object;

+ (void)apiSwizzle:(TNSSwizzleKlass*)object;

+ (NSString*)callRecursively:(NSString* (^)())block;

+ (NSString*)callOnThread:(NSString* (^)())block;

// Keeps `block` with its own Block_copy and drops that reference from a
// background queue 0-2 ms later, so the last release of a JS-created block can
// land on another thread while JS holds the isolate. `mode` picks the
// releasing queue: 0 a concurrent global queue, 1 a serial queue, 2 like 0 but
// the block is also enqueued on the main operation queue first.
+ (void)keepBlock:(void (^)(void))block releaseMode:(int)mode;

// Calls `step` `count` times on the calling thread, each call inside its own
// autorelease pool, so the runtime's autoreleased copy of a block marshalled
// by `step` is gone before the next call. Sleeps 0-3 ms after each call
// without leaving the JS turn, so a release scheduled by `step` can drop a
// block's last reference while this thread still holds the isolate.
+ (void)repeat:(int)count pausingAfter:(void (^)(int))step;

// Runs `work` on a global background queue, then `completion` on the main
// queue.
+ (void)runOnBackgroundQueue:(void (^)(void))work completion:(void (^)(void))completion;

- (void (^)())getBlock;
- (void (^)())getBlockFromNative;

// Invokes `block` inside @try/@catch and returns the caught NSException, or nil
// when the block completes without raising. Used to observe native exceptions
// escaping from JS through interop.escapeException.
+ (NSException*)invokeBlockCatchingException:(void (^)(void))block;

// Convenience: returns the caught exception's reason, or nil when none was
// raised.
+ (NSString*)invokeAndDescribeException:(void (^)(void))block;

// Returns the JavaScript stack trace associated with `exception` via the
// NSException(NativeScript) category, or nil when unavailable. The category
// lives in the NativeScript framework (loaded in-process at runtime) but is not
// linked by TestFixtures at compile time, so it is invoked via performSelector.
+ (NSString* _Nullable)jsStackTraceForException:(NSException* _Nullable)exception;

// Reads a key from a dictionary natively (exercises the JS-backed
// DictionaryAdapter's objectForKey boundary).
+ (id)dictionaryValueForKey:(NSDictionary*)dictionary key:(NSString*)key;

// Reads a key path from an object natively via KVC (exercises a JS property
// accessor boundary).
+ (id)objectValueForKey:(id)object key:(NSString*)key;

@end
