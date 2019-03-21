#include "Caches.h"

namespace tns {

std::map<std::string, const InterfaceMeta*> Caches::Metadata;
std::map<const InterfaceMeta*, v8::Persistent<v8::Value>*> Caches::Prototypes;

}
