#include "Caches.h"

using namespace v8;

namespace tns {


Caches* Caches::Get(Isolate* isolate) {
    Caches* caches = nullptr;
    auto it = Caches::perIsolateCaches_.find(isolate);
    if (it == Caches::perIsolateCaches_.end()) {
        caches = new Caches();
        Caches::perIsolateCaches_.insert(std::make_pair(isolate, caches));
    } else {
        caches = it->second;
    }

    return caches;
}

std::map<Isolate*, Caches*> Caches::perIsolateCaches_;

std::map<std::string, const Meta*> Caches::Metadata;
std::map<std::thread::id, Caches::WorkerState*> Caches::Workers;

}
