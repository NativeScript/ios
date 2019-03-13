//
//  platform-ios.mm
//  v8ios
//
//  Created by Darin Dimitrov on 2/23/19.
//  Copyright © 2019 Progress. All rights reserved.
//

#ifndef platform_ios_h
#define platform_ios_h

#include <vector>
#include <string>
#include <stdlib.h>
#include "timezone-cache.h"

namespace v8 {
namespace base {
    
class TimezoneCache;
    
class OS {
public:
    static void SignalCodeMovingGC();
    static TimezoneCache* CreateTimezoneCache();
    static bool ArmUsingHardFloat();
    
    struct SharedLibraryAddress {
        SharedLibraryAddress(const std::string& library_path, uintptr_t start,
                             uintptr_t end)
        : library_path(library_path), start(start), end(end), aslr_slide(0) {}
        SharedLibraryAddress(const std::string& library_path, uintptr_t start,
                             uintptr_t end, intptr_t aslr_slide)
        : library_path(library_path),
        start(start),
        end(end),
        aslr_slide(aslr_slide) {}
        
        std::string library_path;
        uintptr_t start;
        uintptr_t end;
        intptr_t aslr_slide;
    };
    
    static std::vector<SharedLibraryAddress> GetSharedLibraryAddresses();
    
    class MemoryMappedFile {
    public:
        virtual void* memory() const = 0;
        virtual size_t size() const = 0;
        
        static MemoryMappedFile* open(const char* name);
    };
};
    
class PosixTimezoneCache : public TimezoneCache {
public:
    double DaylightSavingsOffset(double time_ms) override;
    void Clear() override {}
    ~PosixTimezoneCache() override = default;
        
protected:
    static const int msPerSecond = 1000;
};
    
class PosixDefaultTimezoneCache : public PosixTimezoneCache {
public:
    const char* LocalTimezone(double time_ms) override;
    double LocalTimeOffset(double time_ms, bool is_utc) override;
        
    ~PosixDefaultTimezoneCache() override = default;
};
    
}
}

#endif /* platform_ios_h */
