#include "Caches.h"

namespace tns {

std::map<std::string, const Meta*> Caches::Metadata;
std::map<const Meta*, v8::Persistent<v8::Value>*> Caches::Prototypes;
std::map<const std::string, v8::Persistent<v8::Object>*> Caches::ClassPrototypes;
std::map<const BaseClassMeta*, v8::Persistent<v8::FunctionTemplate>*> Caches::CtorFuncTemplates;
std::map<std::string, v8::Persistent<v8::Function>*> Caches::CtorFuncs;
std::map<std::string, v8::Persistent<v8::Function>*> Caches::ProtocolCtorFuncs;
std::map<id, v8::Persistent<v8::Object>*> Caches::Instances;
std::map<const StructMeta*, v8::Persistent<v8::Function>*> Caches::StructConstructorFunctions;

}
