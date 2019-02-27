//
//  timezone-cache.h
//  v8ios
//
//  Created by Darin Dimitrov on 2/25/19.
//  Copyright © 2019 Progress. All rights reserved.
//

#ifndef timezone_cache_h
#define timezone_cache_h

namespace v8 {
namespace base {
        
class TimezoneCache {
public:
    // Short name of the local timezone (e.g., EST)
    virtual const char* LocalTimezone(double time_ms) = 0;
            
    // ES #sec-daylight-saving-time-adjustment
    // Daylight Saving Time Adjustment
    virtual double DaylightSavingsOffset(double time_ms) = 0;
            
    // ES #sec-local-time-zone-adjustment
    // Local Time Zone Adjustment
    //
    // https://github.com/tc39/ecma262/pull/778
    virtual double LocalTimeOffset(double time_ms, bool is_utc) = 0;
            
    // Called when the local timezone changes
    virtual void Clear() = 0;
            
    // Called when tearing down the isolate
    virtual ~TimezoneCache() = default;
};
        
}  // namespace base
}  // namespace v8

#endif /* timezone_cache_h */
