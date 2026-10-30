#import "TNSExternalMemory.h"

#include <mach/mach.h>

static NSMutableArray* keptData;

static NSData* NewData(NSUInteger length) {
  void* bytes = calloc(length, 1);
  return [[NSData alloc] initWithBytesNoCopy:bytes length:length freeWhenDone:YES];
}

@implementation TNSExternalMemory
+ (void)passFreshDataOfLength:(NSUInteger)length to:(TNSDataCallback)callback {
  NSData* data = NewData(length);
  callback(data);
  [data release];
}

+ (void)passAutoreleasedDataOfLength:(NSUInteger)length to:(TNSDataCallback)callback {
  callback([NewData(length) autorelease]);
}

+ (void)passKeptDataOfLength:(NSUInteger)length to:(TNSDataCallback)callback {
  if (keptData == nil) {
    keptData = [[NSMutableArray alloc] init];
  }
  NSData* data = NewData(length);
  [keptData addObject:data];
  callback(data);
  [data release];
}

+ (void)releaseKeptData {
  [keptData removeAllObjects];
}

+ (void)passSharedDataTo:(TNSDataCallback)callback {
  static NSData* shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    shared = NewData(64 * 1024);
  });
  callback(shared);
}

+ (void)passEmptyDataTo:(TNSDataCallback)callback {
  callback([NSData data]);
}

+ (void)streamDataOfLength:(NSUInteger)length
                     count:(NSUInteger)count
                intervalMs:(double)intervalMs
                        to:(TNSDataCallback)callback
                completion:(void (^)(void))completion {
  dispatch_queue_t queue = dispatch_queue_create("org.nativescript.TNSExternalMemory", NULL);
  TNSDataCallback heldCallback = [callback copy];
  void (^heldCompletion)(void) = [completion copy];
  __block NSUInteger sent = 0;
  __block void (^next)(void) = nil;
  next = [^{
    if (sent == count) {
      heldCompletion();
      [heldCallback release];
      [heldCompletion release];
      [next release];
      dispatch_release(queue);
      return;
    }
    sent++;
    NSData* data = NewData(length);
    heldCallback(data);
    [data release];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(intervalMs * NSEC_PER_MSEC)), queue,
                   next);
  } copy];
  dispatch_async(queue, next);
}

+ (double)physicalFootprint {
  task_vm_info_data_t info;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
    return -1;
  }
  return (double)info.phys_footprint;
}
@end
