#include "Caches.h"
#include "Constants.h"

using namespace v8;

namespace tns {

Caches::Caches(Isolate* isolate, const int& isolateId)
    : isolate_(isolate), isolateId_(isolateId) {
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
    this->cacheBoundObjects_.clear();
}

void Caches::Remove(v8::Isolate* isolate) {
    auto cache = isolate->GetData(Constants::CACHES_ISOLATE_SLOT);
    isolate->SetData(Constants::CACHES_ISOLATE_SLOT, nullptr);
    if (cache != nullptr) {
        delete reinterpret_cast<std::shared_ptr<Caches>*>(cache);
    }
}

void Caches::SetContext(Local<Context> context) {
    this->context_ = std::make_shared<Persistent<Context>>(this->isolate_, context);
}

Local<Context> Caches::GetContext() {
    return this->context_->Get(this->isolate_);
}

std::shared_ptr<ConcurrentMap<std::string, const Meta*>> Caches::Metadata = std::make_shared<ConcurrentMap<std::string, const Meta*>>();
std::shared_ptr<ConcurrentMap<int, std::shared_ptr<Caches::WorkerState>>> Caches::Workers = std::make_shared<ConcurrentMap<int, std::shared_ptr<Caches::WorkerState>>>();

}
