#include "Caches.h"

namespace tns {

std::map<std::string, const BaseClassMeta*> Caches::Metadata;
std::map<const BaseClassMeta*, v8::Persistent<v8::Value>*> Caches::Prototypes;
std::map<const InterfaceMeta*, v8::Persistent<v8::FunctionTemplate>*> Caches::CtorFuncTemplates;
std::map<const InterfaceMeta*, v8::Persistent<v8::Function>*> Caches::CtorFuncs;
std::map<id, v8::Persistent<v8::Object>*> Caches::Instances;

}
