#include "Caches.h"

using namespace v8;

namespace tns {

std::map<std::string, const Meta*> Caches::Metadata;
std::map<const Meta*, Persistent<Value>*> Caches::Prototypes;
std::map<const std::string, Persistent<Object>*> Caches::ClassPrototypes;
std::map<const BaseClassMeta*, Persistent<FunctionTemplate>*> Caches::CtorFuncTemplates;
std::map<std::string, Persistent<v8::Function>*> Caches::CtorFuncs;
std::map<std::string, Persistent<v8::Function>*> Caches::ProtocolCtorFuncs;
std::map<id, Persistent<Object>*> Caches::Instances;
std::map<const void*, Persistent<Object>*> Caches::PointerInstances;
std::map<const StructMeta*, Persistent<v8::Function>*> Caches::StructConstructorFunctions;

}
