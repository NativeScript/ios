#include "Caches.h"

using namespace v8;

namespace tns {

Caches::~Caches() {
    for (auto pair: this->Prototypes) {
        delete pair.second;
    }
    this->Prototypes.clear();

    for (auto pair: this->ClassPrototypes) {
        delete pair.second;
    }
    this->ClassPrototypes.clear();

    for (auto pair: this->CtorFuncTemplates) {
        delete pair.second;
    }
    this->CtorFuncTemplates.clear();

    for (auto pair: this->CtorFuncs) {
        delete pair.second;
    }
    this->CtorFuncs.clear();

    for (auto pair: this->ProtocolCtorFuncs) {
        delete pair.second;
    }
    this->ProtocolCtorFuncs.clear();

    for (auto pair: this->Instances) {
        delete pair.second;
    }
    this->Instances.clear();

    for (auto pair: this->PointerInstances) {
        delete pair.second;
    }
    this->PointerInstances.clear();

    for (auto pair: this->StructConstructorFunctions) {
        delete pair.second;
    }
    this->StructConstructorFunctions.clear();

    for (auto pair: this->PrimitiveInteropTypes) {
        delete pair.second;
    }
    this->PrimitiveInteropTypes.clear();

    for (auto pair: this->CFunctions) {
        delete pair.second;
    }
    this->CFunctions.clear();

    for (auto pair: this->StructInstances) {
        delete pair.second;
    }
    this->StructInstances.clear();

    delete this->ToStringFunc;
    delete this->EmptyObjCtorFunc;
    delete this->EmptyStructCtorFunc;
    delete this->SliceFunc;
    delete this->OriginalExtendsFunc;
    delete this->WeakRefGetterFunc;
    delete this->WeakRefClearFunc;
    delete this->InteropReferenceCtorFunc;
    delete this->PointerCtorFunc;
    delete this->FunctionReferenceCtorFunc;
    delete this->SmartJSONStringifyFunc;
}

Caches* Caches::Get(Isolate* isolate) {
    Caches* caches = Caches::perIsolateCaches_.Get(isolate);
    if (caches == nullptr) {
        caches = new Caches();
        Caches::perIsolateCaches_.Insert(isolate, caches);
    }

    return caches;
}

void Caches::Remove(v8::Isolate* isolate) {
    Caches* caches = nullptr;
    Caches::perIsolateCaches_.Remove(isolate, caches);
    if (caches != nullptr) {
        delete caches;
    }
}

ConcurrentMap<Isolate*, Caches*> Caches::perIsolateCaches_;

ConcurrentMap<std::string, const Meta*> Caches::Metadata;
ConcurrentMap<int, Caches::WorkerState*> Caches::Workers;

}
