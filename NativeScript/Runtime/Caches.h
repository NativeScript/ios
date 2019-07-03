#ifndef Caches_h
#define Caches_h

#include <string>
#include <thread>
#include <map>
#include "Common.h"
#include "Metadata.h"

namespace tns {

class Caches {
public:
    class WorkerState {
    public:
        WorkerState(v8::Isolate* isolate, v8::Persistent<v8::Value>* worker): isolate_(isolate), worker_(worker) {
        }

        v8::Isolate* GetIsolate() {
            return this->isolate_;
        }

        v8::Persistent<v8::Value>* GetWorker() {
            return this->worker_;
        }
    private:
        v8::Isolate* isolate_;
        v8::Persistent<v8::Value>* worker_;
    };

    static std::map<std::string, const Meta*> Metadata;
    static std::map<std::thread::id, WorkerState*> Workers;

    static Caches* Get(v8::Isolate* isolate);

    std::map<const Meta*, v8::Persistent<v8::Value>*> Prototypes;
    std::map<const std::string, v8::Persistent<v8::Object>*> ClassPrototypes;
    std::map<const BaseClassMeta*, v8::Persistent<v8::FunctionTemplate>*> CtorFuncTemplates;
    std::map<std::string, v8::Persistent<v8::Function>*> CtorFuncs;
    std::map<std::string, v8::Persistent<v8::Function>*> ProtocolCtorFuncs;
    std::map<id, v8::Persistent<v8::Value>*> Instances;
    std::map<const void*, v8::Persistent<v8::Object>*> PointerInstances;
    std::map<const StructMeta*, v8::Persistent<v8::Function>*> StructConstructorFunctions;
private:
    static std::map<v8::Isolate*, Caches*> perIsolateCaches_;
};

}

#endif /* Caches_h */
