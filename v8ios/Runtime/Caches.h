#ifndef Caches_h
#define Caches_h

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include "v8.h"
#pragma clang diagnostic pop

#include <map>
#include "Metadata.h"

namespace tns {

struct cmp_str {
    bool operator()(char const *a, char const *b) const {
        return std::strcmp(a, b) < 0;
    }
};

class Caches {
public:
    static std::map<const char*, const InterfaceMeta*, cmp_str> Metadata;
    static std::map<const InterfaceMeta*, v8::Persistent<v8::Value>*> Prototypes;
};

}

#endif /* Caches_h */
