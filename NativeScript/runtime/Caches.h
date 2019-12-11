#ifndef Caches_h
#define Caches_h

#include <string>
#include "ConcurrentMap.h"
#include "Common.h"
#include "Metadata.h"

namespace tns {

struct StructInfo;

struct pair_hash
{
    template <class T1, class T2>
    std::size_t operator() (const std::pair<T1, T2> &pair) const
    {
        return std::hash<T1>()(pair.first) ^ std::hash<T2>()(pair.second);
    }
};

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

    ~Caches();

    static ConcurrentMap<std::string, const Meta*> Metadata;
    static ConcurrentMap<int, WorkerState*> Workers;

    static Caches* Get(v8::Isolate* isolate);
    static void Remove(v8::Isolate* isolate);

    std::unordered_map<const Meta*, v8::Persistent<v8::Value>*> Prototypes;
    std::unordered_map<std::string, v8::Persistent<v8::Object>*> ClassPrototypes;
    std::unordered_map<const BaseClassMeta*, v8::Persistent<v8::FunctionTemplate>*> CtorFuncTemplates;
    std::unordered_map<std::string, v8::Persistent<v8::Function>*> CtorFuncs;
    std::unordered_map<std::string, v8::Persistent<v8::Function>*> ProtocolCtorFuncs;
    std::map<id, v8::Persistent<v8::Value>*> Instances;
    std::unordered_map<const void*, v8::Persistent<v8::Object>*> PointerInstances;
    std::unordered_map<std::string, v8::Persistent<v8::Function>*> StructConstructorFunctions;
    std::unordered_map<std::string, v8::Persistent<v8::Object>*> PrimitiveInteropTypes;
    std::unordered_map<std::string, v8::Persistent<v8::Function>*> CFunctions;

    std::function<v8::Local<v8::FunctionTemplate>(v8::Isolate* isolate, const BaseClassMeta*)> ObjectCtorInitializer;
    std::function<v8::Local<v8::Function>(v8::Isolate*, StructInfo)> StructCtorInitializer;
    v8::Persistent<v8::Function>* ToStringFunc = nullptr;

    v8::Persistent<v8::Function>* EmptyObjCtorFunc = nullptr;
    v8::Persistent<v8::Function>* EmptyStructCtorFunc = nullptr;
    v8::Persistent<v8::Function>* SliceFunc = nullptr;
    v8::Persistent<v8::Function>* OriginalExtendsFunc = nullptr;
    v8::Persistent<v8::Function>* WeakRefGetterFunc = nullptr;
    v8::Persistent<v8::Function>* WeakRefClearFunc = nullptr;
    v8::Persistent<v8::Function>* SmartJSONStringifyFunc = nullptr;

    v8::Persistent<v8::Function>* InteropReferenceCtorFunc = nullptr;
    v8::Persistent<v8::Function>* PointerCtorFunc = nullptr;
    v8::Persistent<v8::Function>* FunctionReferenceCtorFunc = nullptr;

    std::unordered_map<std::pair<void*, std::string>, v8::Persistent<v8::Value>*, pair_hash> StructInstances;

    std::unordered_map<std::string, double> Timers;
private:
    static ConcurrentMap<v8::Isolate*, Caches*> perIsolateCaches_;
};

}

#endif /* Caches_h */
