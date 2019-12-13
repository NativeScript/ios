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
    std::size_t operator() (const std::pair<T1, T2> &pair) const {
        return std::hash<T1>()(pair.first) ^ std::hash<T2>()(pair.second);
    }
};

class Caches {
public:
    class WorkerState {
    public:
        WorkerState(v8::Isolate* isolate, std::shared_ptr<v8::Persistent<v8::Value>> poWorker, void* userData)
            : isolate_(isolate),
              poWorker_(poWorker),
              userData_(userData) {
        }

        v8::Isolate* GetIsolate() {
            return this->isolate_;
        }

        std::shared_ptr<v8::Persistent<v8::Value>> GetWorker() {
            return this->poWorker_;
        }

        void* UserData() {
            return this->userData_;
        }
    private:
        v8::Isolate* isolate_;
        std::shared_ptr<v8::Persistent<v8::Value>> poWorker_;
        void* userData_;
    };

    ~Caches();

    static ConcurrentMap<std::string, const Meta*> Metadata;
    static ConcurrentMap<int, std::shared_ptr<WorkerState>> Workers;

    static std::shared_ptr<Caches> Get(v8::Isolate* isolate);
    static void Remove(v8::Isolate* isolate);

    std::unordered_map<const Meta*, std::unique_ptr<v8::Persistent<v8::Value>>> Prototypes;
    std::unordered_map<std::string, std::unique_ptr<v8::Persistent<v8::Object>>> ClassPrototypes;
    std::unordered_map<const BaseClassMeta*, std::unique_ptr<v8::Persistent<v8::FunctionTemplate>>> CtorFuncTemplates;
    std::unordered_map<std::string, std::unique_ptr<v8::Persistent<v8::Function>>> CtorFuncs;
    std::unordered_map<std::string, std::unique_ptr<v8::Persistent<v8::Function>>> ProtocolCtorFuncs;
    std::unordered_map<std::string, std::unique_ptr<v8::Persistent<v8::Function>>> StructConstructorFunctions;
    std::unordered_map<std::string, std::unique_ptr<v8::Persistent<v8::Object>>> PrimitiveInteropTypes;
    std::unordered_map<std::string, std::unique_ptr<v8::Persistent<v8::Function>>> CFunctions;

    std::map<id, std::shared_ptr<v8::Persistent<v8::Value>>> Instances;
    std::unordered_map<std::pair<void*, std::string>, std::shared_ptr<v8::Persistent<v8::Value>>, pair_hash> StructInstances;
    std::unordered_map<const void*, std::shared_ptr<v8::Persistent<v8::Object>>> PointerInstances;

    std::function<v8::Local<v8::FunctionTemplate>(v8::Isolate* isolate, const BaseClassMeta*)> ObjectCtorInitializer;
    std::function<v8::Local<v8::Function>(v8::Isolate*, StructInfo)> StructCtorInitializer;
    std::unordered_map<std::string, double> Timers;

    std::unique_ptr<v8::Persistent<v8::Function>> ToStringFunc = std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);
    std::unique_ptr<v8::Persistent<v8::Function>> EmptyObjCtorFunc = std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);
    std::unique_ptr<v8::Persistent<v8::Function>> EmptyStructCtorFunc = std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);
    std::unique_ptr<v8::Persistent<v8::Function>> SliceFunc = std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);
    std::unique_ptr<v8::Persistent<v8::Function>> OriginalExtendsFunc = std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);
    std::unique_ptr<v8::Persistent<v8::Function>> WeakRefGetterFunc = std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);
    std::unique_ptr<v8::Persistent<v8::Function>> WeakRefClearFunc = std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);
    std::unique_ptr<v8::Persistent<v8::Function>> SmartJSONStringifyFunc = std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);
    std::unique_ptr<v8::Persistent<v8::Function>> InteropReferenceCtorFunc = std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);
    std::unique_ptr<v8::Persistent<v8::Function>> PointerCtorFunc = std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);
    std::unique_ptr<v8::Persistent<v8::Function>> FunctionReferenceCtorFunc = std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);
private:
    static ConcurrentMap<v8::Isolate*, std::shared_ptr<Caches>> perIsolateCaches_;
};

}

#endif /* Caches_h */
