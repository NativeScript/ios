#ifndef Caches_h
#define Caches_h

#include <string>
#include "ConcurrentMap.h"
#include "Common.h"
#include "Metadata.h"

namespace tns {

class Caches {
public:
    class WorkerState {
    public:
        WorkerState(v8::Isolate* isolate, v8::Persistent<v8::Value>* poWorker, void* userData): isolate_(isolate), poWorker_(poWorker), userData_(userData) {
        }

        v8::Isolate* GetIsolate() {
            return this->isolate_;
        }

        v8::Persistent<v8::Value>* GetWorker() {
            return this->poWorker_;
        }

        void* UserData() {
            return this->userData_;
        }
    private:
        v8::Isolate* isolate_;
        v8::Persistent<v8::Value>* poWorker_;
        void* userData_;
    };

    static ConcurrentMap<std::string, const Meta*> Metadata;
    static ConcurrentMap<int, WorkerState*> Workers;

    static Caches* Get(v8::Isolate* isolate);
    static void Remove(v8::Isolate* isolate);

    std::map<const Meta*, v8::Persistent<v8::Value>*> Prototypes;
    std::map<const std::string, v8::Persistent<v8::Object>*> ClassPrototypes;
    std::map<const BaseClassMeta*, v8::Persistent<v8::FunctionTemplate>*> CtorFuncTemplates;
    std::map<std::string, v8::Persistent<v8::Function>*> CtorFuncs;
    std::map<std::string, v8::Persistent<v8::Function>*> ProtocolCtorFuncs;
    std::map<id, v8::Persistent<v8::Value>*> Instances;
    std::map<const void*, v8::Persistent<v8::Object>*> PointerInstances;
    std::map<const StructMeta*, v8::Persistent<v8::Function>*> StructConstructorFunctions;

    std::function<void (const BaseClassMeta*)> MetaInitializer;
    v8::Persistent<v8::Function>* EmptyObjCtorFunc;
    v8::Persistent<v8::Function>* EmptyStructCtorFunc;
    v8::Persistent<v8::Function>* SliceFunc;
    v8::Persistent<v8::Function>* OriginalExtendsFunc;
    v8::Persistent<v8::Function>* WeakRefGetterFunc;
    v8::Persistent<v8::Function>* WeakRefClearFunc;
    std::map<std::string, v8::Persistent<v8::Function>*> CFunctions;

    v8::Persistent<v8::Function>* InteropReferenceCtorFunc;
    v8::Persistent<v8::Function>* PointerCtorFunc;
    v8::Persistent<v8::Function>* FunctionReferenceCtorFunc;
private:
    static ConcurrentMap<v8::Isolate*, Caches*> perIsolateCaches_;
};

}

#endif /* Caches_h */
