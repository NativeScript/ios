#import "TNSPointCollection.h"

NS_ASSUME_NONNULL_BEGIN

@implementation TNSPointCollection
{
    TNSPoint *_points;
    NSUInteger _pointCount;
}

- (instancetype)initWithPoints:(const TNSPoint *)points count:(NSUInteger)count
{
    self = [super init];
    if (self)
    {
        _pointCount = count;
        if (count > 0)
        {
            _points = malloc(sizeof(TNSPoint) * count);
            memcpy(_points, points, sizeof(TNSPoint) * count);
        }
        else
        {
            _points = NULL;
        }
    }
    return self;
}

- (NSUInteger)pointCount
{
    return _pointCount;
}

- (TNSPoint *)points
{
    return _points;
}

@end

NS_ASSUME_NONNULL_END
