#include "DataWrapper.h"

#include "Caches.h"
#include "FFICall.h"
#include "ObjectManager.h"

namespace tns {

StructWrapper::~StructWrapper() {
    parent_.Reset();
    if (data_) {
        // v8::Isolate::GetCurrent() may not necessarily be the isolate this object lives in.
        // Remove the (weak) v8::Persistent holding the JS value.
        if (auto cache = Caches::Get(v8::Isolate::GetCurrent()))
            cache->StructInstances.erase(std::make_pair(data_, StructInfo().Name()));
        free(data_);
    }
}


void ObjCDataWrapper::ReleaseNativeCounterpart() {
    id target = data_;
    if (target != nil) {
        if (auto cache = Caches::Get(v8::Isolate::GetCurrent())) {
            auto it = cache->Instances.find(data_);
            if (it != cache->Instances.end()) {
                ObjectWeakCallbackState* state = it->second->ClearWeak<ObjectWeakCallbackState>();
                if (state != nullptr)
                    delete state;
                cache->Instances.erase(target);
            }
        }
        [target release];
    }
    data_ = nil;
}

BlockWrapper::~BlockWrapper() {
    if (!OwnsBlock())
        std::free(Block());
}

ReferenceWrapper::~ReferenceWrapper() {
    if (data_ != nullptr) {
        SetData(nullptr);
        SetEncoding(nullptr);
    }
}

PointerWrapper::~PointerWrapper() {
    if (data_ != nullptr) {
        auto data = data_;
        data_ = nullptr;
        if (auto cache = Caches::Get(v8::Isolate::GetCurrent()))
            cache->PointerInstances.erase(data);

        if (IsAdopted())
            std::free(data);
    }
}

ExtVectorWrapper::~ExtVectorWrapper() {
    FFICall::DisposeFFIType(FFIType(), TypeEncoding());
    if (data_) {
        std::free(data_);
        data_ = nullptr;
    }
}

WorkerWrapper::~WorkerWrapper() {
    // FIXME: This doesn't actually make sense, rethink the ownership model.
    // if (!worker->isDisposed()) {
    //     // during final disposal, inform the worker it should delete itself
    //     if (isFinalDisposal) {
    //         worker->MakeWeak();
    //     }
    //     return false;
    // }
}

}
