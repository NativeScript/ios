
#import <Foundation/Foundation.h>

typedef struct TNSPoint {
    int x;
    int y;
} TNSPoint;

@interface TNSPointCollection : NSObject
- (instancetype)initWithPoints:(const TNSPoint *)points count:(NSUInteger)count;
@property (nonatomic, readonly) TNSPoint *points NS_RETURNS_INNER_POINTER;
@property (nonatomic, readonly) NSUInteger pointCount;
@end
