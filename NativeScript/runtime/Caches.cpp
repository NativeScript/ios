#include "Caches.h"

using namespace v8;

namespace tns {

Caches::Caches(Isolate* isolate)
    : isolate_(isolate) {
}

Caches::~Caches() {
    this->Prototypes.clear();
    this->ClassPrototypes.clear();
    this->CtorFuncTemplates.clear();
    this->CtorFuncs.clear();
    this->ProtocolCtorFuncs.clear();
    this->StructConstructorFunctions.clear();
    this->PrimitiveInteropTypes.clear();
    this->CFunctions.clear();

    this->Instances.clear();
    this->StructInstances.clear();
    this->PointerInstances.clear();
}

std::shared_ptr<Caches> Caches::Get(Isolate* isolate) {
    std::shared_ptr<Caches> cache = Caches::perIsolateCaches_.Get(isolate);
    if (cache == nullptr) {
        cache = std::make_shared<Caches>(isolate);
        Caches::perIsolateCaches_.Insert(isolate, cache);
    }

    return cache;
}

void Caches::Remove(v8::Isolate* isolate) {
    Caches::perIsolateCaches_.Remove(isolate);
}

void Caches::SetContext(Local<Context> context) {
    this->context_ = std::make_shared<Persistent<Context>>(this->isolate_, context);
}

Local<Context> Caches::GetContext() {
    return this->context_->Get(this->isolate_);
}

ConcurrentMap<Isolate*, std::shared_ptr<Caches>> Caches::perIsolateCaches_;

ConcurrentMap<std::string, const Meta*> Caches::Metadata;
ConcurrentMap<int, std::shared_ptr<Caches::WorkerState>> Caches::Workers;

}
