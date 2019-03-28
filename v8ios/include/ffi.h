#ifndef ffi_h
#define ffi_h

#if defined __arm64 && __arm64__
#include "libffi/arm64/ffi.h"
#elif defined __x86_64__ && __x86_64__
#include "libffi/x86_64/ffi.h"
#endif

#endif /* ffi_h */
