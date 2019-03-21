#ifndef Caches_h
#define Caches_h

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include "v8.h"
#pragma clang diagnostic pop

#include <string>
#include <map>
#include "Metadata.h"

namespace tns {

class Caches {
public:
    static std::map<std::string, const InterfaceMeta*> Metadata;
    static std::map<const InterfaceMeta*, v8::Persistent<v8::Value>*> Prototypes;
};

}

#endif /* Caches_h */
