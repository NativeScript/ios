#include "Caches.h"

namespace tns {

std::map<const char*, const InterfaceMeta*, cmp_str> Caches::Metadata;
std::map<const InterfaceMeta*, v8::Persistent<v8::Value>*> Caches::Prototypes;

}
