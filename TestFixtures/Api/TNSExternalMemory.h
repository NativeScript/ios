#import <Foundation/Foundation.h>

typedef void (^TNSDataCallback)(NSData* data);

// Hands JS NSData at +0 the way native APIs do, for the external memory
// accounting tests.
@interface TNSExternalMemory : NSObject
// Calls `callback` with a new NSData, released as soon as it returns.
+ (void)passFreshDataOfLength:(NSUInteger)length to:(TNSDataCallback)callback;
// Calls `callback` with a new autoreleased NSData.
+ (void)passAutoreleasedDataOfLength:(NSUInteger)length to:(TNSDataCallback)callback;
// Calls `callback` with a new NSData that native keeps until -releaseKeptData.
+ (void)passKeptDataOfLength:(NSUInteger)length to:(TNSDataCallback)callback;
+ (void)releaseKeptData;
// Calls `callback` with a process-lifetime NSData.
+ (void)passSharedDataTo:(TNSDataCallback)callback;
// Calls `callback` with an empty NSData.
+ (void)passEmptyDataTo:(TNSDataCallback)callback;
// Calls `callback` `count` times every `intervalMs` from a private serial
// queue, each with a new NSData released when the call returns, then calls
// `completion` from that queue.
+ (void)streamDataOfLength:(NSUInteger)length
                     count:(NSUInteger)count
                intervalMs:(double)intervalMs
                        to:(TNSDataCallback)callback
                completion:(void (^)(void))completion;
// The process's physical footprint, as jetsam measures it.
+ (double)physicalFootprint;
@end
