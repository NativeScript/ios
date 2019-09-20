#ifndef RuntimeConfig_h
#define RuntimeConfig_h

#include <sys/types.h>

struct RuntimeConfig {
    const char* BaseDir;
    void* MetadataPtr;
    const char* NativesPtr;
    size_t NativesSize;
    const char* SnapshotPtr;
    size_t SnapshotSize;
    bool IsDebug;
};

extern struct RuntimeConfig RuntimeConfig;

#endif /* RuntimeConfig_h */
