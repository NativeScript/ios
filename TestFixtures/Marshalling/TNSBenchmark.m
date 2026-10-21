#import "TNSBenchmark.h"

@implementation TNSBenchmarkRecord
@end

@implementation TNSBenchmark

+ (void)noop {
}

+ (NSInteger)echoInt:(NSInteger)value {
  return value;
}

+ (double)combine:(double)a times:(double)b plus:(double)c {
  return a * b + c;
}

+ (BOOL)negate:(BOOL)value {
  return !value;
}

+ (NSString*)echoString:(NSString*)value {
  return value;
}

+ (NSInteger)lengthOf:(NSString*)value {
  return value.length;
}

- (NSInteger)increment {
  return ++self.counter;
}

+ (NSInteger)sum:(NSArray<NSNumber*>*)values {
  NSInteger total = 0;
  for (NSNumber* value in values) {
    total += value.integerValue;
  }
  return total;
}

+ (NSArray<NSNumber*>*)makeArray:(NSInteger)count {
  NSMutableArray<NSNumber*>* values = [NSMutableArray arrayWithCapacity:count];
  for (NSInteger i = 0; i < count; i++) {
    [values addObject:@(i)];
  }
  return values;
}

+ (NSInteger)sumValues:(NSDictionary<NSString*, NSNumber*>*)values {
  NSInteger total = 0;
  for (NSString* key in values) {
    total += values[key].integerValue;
  }
  return total;
}

+ (NSDictionary<NSString*, NSNumber*>*)makeDictionary:(NSInteger)count {
  NSMutableDictionary<NSString*, NSNumber*>* values =
      [NSMutableDictionary dictionaryWithCapacity:count];
  for (NSInteger i = 0; i < count; i++) {
    values[[NSString stringWithFormat:@"key%ld", (long)i]] = @(i);
  }
  return values;
}

+ (CGPoint)midpointOf:(CGPoint)a with:(CGPoint)b {
  return CGPointMake((a.x + b.x) / 2, (a.y + b.y) / 2);
}

+ (NSData*)makeData:(NSInteger)length {
  NSMutableData* data = [NSMutableData dataWithLength:length];
  uint8_t* bytes = data.mutableBytes;
  for (NSInteger i = 0; i < length; i++) {
    bytes[i] = (uint8_t)i;
  }
  return data;
}

+ (NSInteger)checksum:(NSData*)data {
  const uint8_t* bytes = data.bytes;
  NSInteger total = 0;
  for (NSUInteger i = 0; i < data.length; i++) {
    total += bytes[i];
  }
  return total;
}

+ (NSInteger)callBlock:(NSInteger (^)(NSInteger))block times:(NSInteger)count {
  NSInteger total = 0;
  for (NSInteger i = 0; i < count; i++) {
    total += block(i);
  }
  return total;
}

+ (NSInteger)callDelegate:(id<TNSBenchmarkDelegate>)delegate times:(NSInteger)count {
  NSInteger total = 0;
  for (NSInteger i = 0; i < count; i++) {
    total += [delegate valueForIndex:i];
  }
  return total;
}

+ (void)echoLater:(NSInteger)value completion:(void (^)(NSInteger))completion {
  dispatch_async(dispatch_get_main_queue(), ^{
    completion(value);
  });
}

+ (BOOL)failWithError:(NSError**)error {
  if (error) {
    *error = [NSError errorWithDomain:@"TNSBenchmark" code:1 userInfo:nil];
  }
  return NO;
}

+ (NSArray<TNSBenchmarkRecord*>*)topRecords:(NSInteger)count minimumScore:(double)minimum {
  NSMutableArray<TNSBenchmarkRecord*>* records = [NSMutableArray arrayWithCapacity:count];
  for (NSInteger i = 0; i < count; i++) {
    double score = (double)((i * 7919) % 1000) / 10.0;
    if (score < minimum) {
      continue;
    }
    TNSBenchmarkRecord* record = [TNSBenchmarkRecord new];
    record.name = [NSString stringWithFormat:@"record %ld", (long)i];
    record.score = score;
    [records addObject:record];
  }
  [records sortUsingComparator:^NSComparisonResult(TNSBenchmarkRecord* a, TNSBenchmarkRecord* b) {
    return a.score > b.score ? NSOrderedAscending
                             : (a.score < b.score ? NSOrderedDescending : NSOrderedSame);
  }];
  for (NSUInteger i = 0; i < records.count; i++) {
    records[i].rank = (NSInteger)i + 1;
  }
  return records;
}

@end
