#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

// The Objective-C half of the interop benchmarks (SwiftInteropBenchmarks.js);
// SwiftDemo's Benchmark is the same API in Swift, reached through ns:swift.

@protocol TNSBenchmarkDelegate <NSObject>
- (NSInteger)valueForIndex:(NSInteger)index;
@end

@interface TNSBenchmarkRecord : NSObject
@property(nonatomic, copy) NSString* name;
@property(nonatomic) double score;
@property(nonatomic) NSInteger rank;
@end

@interface TNSBenchmark : NSObject
@property(nonatomic) NSInteger counter;

+ (void)noop;
+ (NSInteger)echoInt:(NSInteger)value;
+ (double)combine:(double)a times:(double)b plus:(double)c;
+ (BOOL)negate:(BOOL)value;
+ (NSString*)echoString:(NSString*)value;
+ (NSInteger)lengthOf:(NSString*)value;
- (NSInteger)increment;
+ (NSInteger)sum:(NSArray<NSNumber*>*)values;
+ (NSArray<NSNumber*>*)makeArray:(NSInteger)count;
+ (NSInteger)sumValues:(NSDictionary<NSString*, NSNumber*>*)values;
+ (NSDictionary<NSString*, NSNumber*>*)makeDictionary:(NSInteger)count;
+ (CGPoint)midpointOf:(CGPoint)a with:(CGPoint)b;
+ (NSData*)makeData:(NSInteger)length;
+ (NSInteger)checksum:(NSData*)data;
+ (NSInteger)callBlock:(NSInteger (^)(NSInteger))block times:(NSInteger)count;
+ (NSInteger)callDelegate:(id<TNSBenchmarkDelegate>)delegate times:(NSInteger)count;
+ (void)echoLater:(NSInteger)value completion:(void (^)(NSInteger))completion;
+ (BOOL)failWithError:(NSError**)error;
+ (NSArray<TNSBenchmarkRecord*>*)topRecords:(NSInteger)count minimumScore:(double)minimum;
@end
