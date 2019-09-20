#ifndef RuntimeConfig_h
#define RuntimeConfig_h

#include <sys/types.h>
#include <string>

struct RuntimeConfig {
    std::string BaseDir;
    std::string ApplicationPath;
    void* MetadataPtr;
    const char* NativesPtr;
    size_t NativesSize;
    const char* SnapshotPtr;
    size_t SnapshotSize;
    bool IsDebug;
};

extern struct RuntimeConfig RuntimeConfig;

#endif /* RuntimeConfig_h */
