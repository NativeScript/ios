#import "TNSFunctions.h"

CFArrayRef CFArrayCreateWithString(CFStringRef string) {
    const void* values[] = { string };
    return CFArrayCreate(kCFAllocatorDefault, values, 1, &kCFTypeArrayCallBacks);
}
