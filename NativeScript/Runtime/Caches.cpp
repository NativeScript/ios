#include "Caches.h"

using namespace v8;

namespace tns {


Caches* Caches::Get(Isolate* isolate) {
    Caches* caches = Caches::perIsolateCaches_.Get(isolate);
    if (caches == nullptr) {
        caches = new Caches();
        Caches::perIsolateCaches_.Insert(isolate, caches);
    }

    return caches;
}

void Caches::Remove(v8::Isolate* isolate) {
    Caches::perIsolateCaches_.Remove(isolate);
}

ConcurrentMap<Isolate*, Caches*> Caches::perIsolateCaches_;

ConcurrentMap<std::string, const Meta*> Caches::Metadata;
ConcurrentMap<int, Caches::WorkerState*> Caches::Workers;

}
