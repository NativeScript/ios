#ifndef TNSAllocLog_h
#define TNSAllocLog_h

@interface TNSAllocLog : NSObject

// Disable ARC for TextFixtures.a and uncomment for debugging puproses
//- (instancetype)retain;
//- (void)release;

- (instancetype)init;
// Ignores `object`.
- (instancetype)initWithObject:(id)object;
// Answers a block that ignores its argument.
+ (void (^)(id))objectSink;
- (void)dealloc;

@end

// -init answers a new TNSAllocLog in place of the receiver.
@interface TNSSubstitutingInit : NSObject

- (instancetype)init;

@end

// Native callers that own what an owned-return message answers and drop it
// straight away.
@interface TNSOwnedReturns : TNSAllocLog

// Answers a new TNSAllocLog.
- (id)newChild;

// Its getter answers a new TNSAllocLog, owned by the caller.
@property(nonatomic, readonly) id newItem;

+ (void)copyAndDrop:(id)object;
+ (void)mutableCopyAndDrop:(id)object;
+ (void)newChildAndDrop:(id)object;
+ (void)awakeAndDrop:(id)object;
+ (void)newItemAndDrop:(id)object;
// Answers `newItem` of `object` without passing ownership on.
+ (id)readNewItemOf:(id)object;
// Sends -init to a new instance of `cls` and drops what it answers.
+ (void)allocInitAndDrop:(Class)cls;

@end

// Keeps one object of each kind JS receives as a primitive: at index 0 a
// string, 1 a number, 2 a date, none of them a tagged pointer.
@interface TNSOwnedPrimitives : NSObject

// Answers the object at `index`, owned by the caller.
- (id)newObjectAt:(NSUInteger)index;
// Answers the object at `index` without passing ownership on.
- (id)objectAt:(NSUInteger)index;
- (NSUInteger)retainCountAt:(NSUInteger)index;
- (BOOL)isTaggedPointerAt:(NSUInteger)index;

@end

// The object `holder` keeps at `index`, owned by the caller.
id TNSOwnedPrimitivesRetainedObjectAt(TNSOwnedPrimitives* holder, NSUInteger index) NS_RETURNS_RETAINED;
// The object `holder` keeps at `index`, without passing ownership on.
id TNSOwnedPrimitivesObjectAt(TNSOwnedPrimitives* holder, NSUInteger index);

// Keeps what -copy answers until -drop.
@interface TNSCopyKeeper : NSObject

- (void)keepCopyOf:(id)object;
// Answers whether both copies are the same object.
- (BOOL)keepTwoCopiesOf:(id)object;
- (void)drop;

@end

// Blocks answered owned or not. Method families do not apply to block
// results, so ownership is declared.
@interface TNSOwnedBlocks : NSObject

// A heap block capturing a new TNSAllocLog; calling it answers `value`.
- (NSInteger (^)(void))retainedBlockAnswering:(NSInteger)value NS_RETURNS_RETAINED;
- (NSInteger (^)(void))blockAnswering:(NSInteger)value;
// Answers `block` itself.
- (NSInteger (^)(void))retainedBlockFrom:(NSInteger (^)(void))block NS_RETURNS_RETAINED;
- (NSInteger (^)(void))blockFrom:(NSInteger (^)(void))block;
+ (NSInteger)callBlock:(NSInteger (^)(void))block;
// Keeps `block` until -retainedStoredBlock hands that reference over.
- (void)storeBlock:(NSInteger (^)(void))block;
- (NSInteger (^)(void))retainedStoredBlock NS_RETURNS_RETAINED;

// One block slot for the whole process, reachable from every isolate.
+ (void)storeSharedBlock:(NSInteger (^)(NSInteger))block;
+ (NSInteger (^)(NSInteger))sharedBlock;
// Answers an extra reference; the slot keeps its own.
+ (NSInteger (^)(NSInteger))retainedSharedBlock NS_RETURNS_RETAINED;
// Hands the slot's reference over and empties the slot.
+ (NSInteger (^)(NSInteger))takeSharedBlock NS_RETURNS_RETAINED;
+ (void)clearSharedBlock;
+ (NSInteger)callBlock:(NSInteger (^)(NSInteger))block withValue:(NSInteger)value;

@end

// Declares the owned-return members of TNSOwnedReturns itself, so JS can
// replace them on this class alone: metadata leaves out members a subclass
// redeclares.
@interface TNSSwizzledOwnedReturns : TNSAllocLog

- (id)newChild;

@property(nonatomic, readonly) id newItem;

@end

// A TNSAllocLog that survives a keyed archive.
@interface TNSCodingAllocLog : TNSAllocLog <NSSecureCoding>

@end

// Implements NSKeyedUnarchiverDelegate: answers the object it is given, or a
// new TNSAllocLog once `substitutes` is set.
@interface TNSDecodeDelegate : NSObject <NSKeyedUnarchiverDelegate>

@property(nonatomic) BOOL substitutes;

@end

// -init sends -initHook to the receiver before returning it.
@interface TNSInitCallsHook : TNSAllocLog

- (void)initHook;

@end

// JS subclasses implement `value`; `name` is state native code sets.
@interface TNSAccessorHost : TNSAllocLog

@property(nonatomic, strong) id value;
@property(nonatomic) CGRect rect;
@property(nonatomic, copy) NSString* name;

@end

// Native properties for the canary write handler specs. Setting `guarded` to a
// negative value raises. Each `via*` property and `dropped` belongs to the one
// spec that redefines or deletes it on this class's prototype.
@interface TNSCanaryWriteTarget : NSObject

@property(nonatomic) NSInteger level;
@property(nonatomic) NSInteger guarded;
@property(nonatomic, readonly) NSInteger fixed;
@property(nonatomic) NSInteger viaDefineProperty;
@property(nonatomic) NSInteger viaDefineProperties;
@property(nonatomic) NSInteger viaReflect;
@property(nonatomic) NSInteger viaDefineSetter;
@property(nonatomic) NSInteger dropped;

@end

// Targets for the canary write handler's native setter cache: `depth` is
// declared three classes above each leaf. Specs that change a prototype use
// the Shadow classes, so the others keep an unchanged chain. `dropped` and
// `reflected` each belong to the one spec that changes them on the prototype.
@interface TNSCanaryCacheBase : NSObject

@property(nonatomic) NSInteger depth;

@end

@interface TNSCanaryCacheMid : TNSCanaryCacheBase
@end

@interface TNSCanaryCacheLeaf : TNSCanaryCacheMid
@end

@interface TNSCanaryCacheShadowBase : NSObject

@property(nonatomic) NSInteger depth;
@property(nonatomic) NSInteger dropped;
@property(nonatomic) NSInteger reflected;

@end

@interface TNSCanaryCacheShadowMid : TNSCanaryCacheShadowBase

- (NSInteger)swizzleTarget;

@end

@interface TNSCanaryCacheShadowLeaf : TNSCanaryCacheShadowMid
@end

// -dealloc reads `value`.
@interface TNSAccessorDeallocHost : TNSAccessorHost

@end

// Reaches the `value` accessors of the host it keeps through compiled property
// access only.
@interface TNSAccessorDriver : NSObject

// Keeps a new instance of `cls`, created natively and named `name`.
- (instancetype)initWithNewHostOf:(Class)cls name:(NSString*)name;
- (instancetype)initWithHost:(TNSAccessorHost*)host;
- (id)readValue;
- (void)writeValue:(id)value;
- (TNSAccessorHost*)host;
- (void)dropHost;
// Key-value observes the host's `value`, without reading it.
- (void)observeHost;
- (void)unobserveHost;
- (id)lastObservedValue;

// Creates an instance of `cls` named `name`, reads its `value` and drops it.
+ (id)valueOfNewHostOf:(Class)cls name:(NSString*)name;
// Creates an instance of `cls` named `name` and drops it.
+ (void)dropNewHostOf:(Class)cls name:(NSString*)name;

// A process-wide host, kept until +dropKeptHost.
+ (void)keepNewHostOf:(Class)cls name:(NSString*)name;
+ (id)readKeptValue;
+ (CGRect)readKeptRect;
+ (void)writeKeptValue:(id)value;
+ (void)dropKeptHost;

// Reads and writes `value` on a new TNSAccessorSwizzleTarget.
+ (id)readSwizzleTargetValue;
+ (void)writeSwizzleTargetValue:(id)value;

@end

// Its `value` accessors are replaced on the prototype, by one spec, for the
// rest of the run.
@interface TNSAccessorSwizzleTarget : NSObject

@property(nonatomic, strong) id value;

@end

// Declares -retainCount and shares its name with the class adopting it, so
// assigning TNSReplaceableRetainCountProtocol.prototype.retainCount replaces
// the method on that class alone, as NSObjectProtocol.prototype does on
// NSObject.
@protocol TNSReplaceableRetainCount

- (NSUInteger)retainCount;

@end

@interface TNSReplaceableRetainCount : TNSAllocLog <TNSReplaceableRetainCount>

// Sends -retainCount to `object`.
+ (NSUInteger)retainCountOf:(id)object;

// Adds a new instance to `owner`, then sends it -retainCount, so a JS
// replacement of -retainCount is what first hands the instance to JS.
+ (void)addNewInstanceTo:(NSMutableArray*)owner;

@end

// Only these fixtures send -tnsCallbackHook, so a JS replacement of it runs
// for their timers alone.
@interface NSTimer (TNSCallbackHook)

- (void)tnsCallbackHook;

// Adds an unscheduled timer targeting a new TNSAllocLog to `owner`, then
// sends it -tnsCallbackHook, so a JS replacement of the hook is what first
// hands the timer to JS.
+ (void)tnsAddHookedTimerTo:(NSMutableArray*)owner;

@end

@interface TNSUninitializedTimer : NSObject

// NSTimer.alloc()'s placeholder, which a JS alloc() call never creates: its
// -retainCount does not return.
+ (id)placeholder;

// Sends -tnsCallbackHook to the placeholder.
+ (void)hookPlaceholder;

@end

// Hands out instances of a class made at runtime and flagged the way the ObjC
// runtime flags Swift actors: objc_setAssociatedObject on one aborts the
// process.
@interface TNSAssociationForbidder : NSObject

+ (id)forbiddingInstance;
// Whether the class of `object` carries that flag.
+ (BOOL)forbidsAssociatedObjects:(id)object;

@end

#endif /* TNSAllocLog_h */
