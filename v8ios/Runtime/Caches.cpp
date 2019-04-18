#include "Caches.h"

namespace tns {

std::map<std::string, const BaseClassMeta*> Caches::Metadata;
std::map<const Meta*, v8::Persistent<v8::Value>*> Caches::Prototypes;
std::map<const std::string, v8::Persistent<v8::Object>*> Caches::ClassPrototypes;
std::map<const InterfaceMeta*, v8::Persistent<v8::FunctionTemplate>*> Caches::CtorFuncTemplates;
std::map<const InterfaceMeta*, v8::Persistent<v8::Function>*> Caches::CtorFuncs;
std::map<id, v8::Persistent<v8::Object>*> Caches::Instances;

}
