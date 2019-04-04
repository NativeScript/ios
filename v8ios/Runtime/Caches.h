#ifndef Caches_h
#define Caches_h

#include <string>
#include <map>
#include "NativeScript.h"
#include "Metadata.h"

namespace tns {

class Caches {
public:
    static std::map<std::string, const BaseClassMeta*> Metadata;
    static std::map<const BaseClassMeta*, v8::Persistent<v8::Value>*> Prototypes;
    static std::map<const InterfaceMeta*, v8::Persistent<v8::FunctionTemplate>*> CtorFuncTemplates;
    static std::map<const InterfaceMeta*, v8::Persistent<v8::Function>*> CtorFuncs;
    static std::map<id, v8::Persistent<v8::Object>*> Instances;
};

}

#endif /* Caches_h */
