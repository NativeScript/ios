#include <cmath>
#include <sys/mman.h>
#include "platform.h"

namespace v8 {
namespace base {

void OS::SignalCodeMovingGC() {
}
    
v8::base::TimezoneCache* OS::CreateTimezoneCache() {
    return new PosixDefaultTimezoneCache();
}
    
std::vector<OS::SharedLibraryAddress> OS::GetSharedLibraryAddresses() {
    std::vector<SharedLibraryAddress> result;
    return result;
}
    
bool OS::ArmUsingHardFloat() {
    return true;
}

const char* PosixDefaultTimezoneCache::LocalTimezone(double time) {
    if (std::isnan(time)) return "";
    time_t tv = static_cast<time_t>(std::floor(time / msPerSecond));
    struct tm tm;
    struct tm* t = localtime_r(&tv, &tm);
    if (!t || !t->tm_zone) return "";
    return t->tm_zone;
}
    
double PosixDefaultTimezoneCache::LocalTimeOffset(double time_ms, bool is_utc) {
    // Preserve the old behavior for non-ICU implementation by ignoring both
    // time_ms and is_utc.
    time_t tv = time(nullptr);
    struct tm tm;
    struct tm* t = localtime_r(&tv, &tm);
    // tm_gmtoff includes any daylight savings offset, so subtract it.
    return static_cast<double>(t->tm_gmtoff * msPerSecond -
                                (t->tm_isdst > 0 ? 3600 * msPerSecond : 0));
}
    
double PosixTimezoneCache::DaylightSavingsOffset(double time) {
    if (std::isnan(time)) return std::numeric_limits<double>::quiet_NaN();
    time_t tv = static_cast<time_t>(std::floor(time/msPerSecond));
    struct tm tm;
    struct tm* t = localtime_r(&tv, &tm);
    if (nullptr == t) return std::numeric_limits<double>::quiet_NaN();
    return t->tm_isdst > 0 ? 3600 * msPerSecond : 0;
}
    
class PosixMemoryMappedFile final : public OS::MemoryMappedFile {
public:
    PosixMemoryMappedFile(FILE* file, void* memory, size_t size) : file_(file), memory_(memory), size_(size) { }
    void* memory() const final { return memory_; }
    size_t size() const final { return size_; }
        
private:
    FILE* const file_;
    void* const memory_;
    size_t const size_;



};

    
OS::MemoryMappedFile* OS::MemoryMappedFile::open(const char* name) {
    if (FILE* file = fopen(name, "r+")) {
        if (fseek(file, 0, SEEK_END) == 0) {
            long size = ftell(file);  // NOLINT(runtime/int)
            if (size == 0) return new PosixMemoryMappedFile(file, nullptr, 0);
            if (size > 0) {
                void* const memory = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, fileno(file), 0);
                if (memory != MAP_FAILED) {
                    return new PosixMemoryMappedFile(file, memory, size);
                }
            }
        }
        fclose(file);
    }
    return nullptr;
}
    
}
}

