#ifndef Caches_h
#define Caches_h

#include <string>
#include <string_view>
#include <vector>

#include "Common.h"
#include "ConcurrentMap.h"
#include "Metadata.h"
#include "robin_hood.h"

namespace tns {

struct StructInfo;
struct ObjectWeakCallbackState;
class PromiseRejectionTracker;
class IsolateTracked;

// Declaring both halves transparent lets robin_hood probe a map keyed by
// std::string with a string_view, so callers holding a const char* from the
// Obj-C runtime do not have to allocate one just to look up.
struct TransparentStringHash {
  using is_transparent = void;
  size_t operator()(std::string_view key) const {
    return robin_hood::hash_bytes(key.data(), key.size());
  }
};

struct TransparentStringEqual {
  using is_transparent = void;
  bool operator()(std::string_view lhs, std::string_view rhs) const {
    return lhs == rhs;
  }
};

struct pair_hash {
  template <class T1, class T2>
  std::size_t operator()(const std::pair<T1, T2>& pair) const {
    return std::hash<T1>()(pair.first) ^ std::hash<T2>()(pair.second);
  }
};

class Caches {
 public:
  class WorkerState {
   public:
    WorkerState(v8::Isolate* isolate,
                std::shared_ptr<v8::Persistent<v8::Value>> poWorker,
                void* userData)
        : isolate_(isolate), poWorker_(poWorker), userData_(userData) {}

    v8::Isolate* GetIsolate() { return this->isolate_; }

    std::shared_ptr<v8::Persistent<v8::Value>> GetWorker() {
      return this->poWorker_;
    }

    void* UserData() { return this->userData_; }

   private:
    v8::Isolate* isolate_;
    std::shared_ptr<v8::Persistent<v8::Value>> poWorker_;
    void* userData_;
  };

  Caches(v8::Isolate* isolate, const int& isolateId_ = -1);
  ~Caches();

  bool isWorker = false;

  static std::shared_ptr<ConcurrentMap<std::string, const Meta*>> Metadata;
  static std::shared_ptr<
      ConcurrentMap<int, std::shared_ptr<Caches::WorkerState>>>
      Workers;

  inline static std::shared_ptr<Caches> Init(v8::Isolate* isolate,
                                             const int& isolateId) {
    auto cache = std::make_shared<Caches>(isolate, isolateId);
    // create a new shared_ptr that will live until Remove is called
    isolate->SetData(0, static_cast<void*>(new std::shared_ptr<Caches>(cache)));
    return cache;
  }
  inline static std::shared_ptr<Caches> Get(v8::Isolate* isolate) {
    auto cache = isolate->GetData(0);
    if (cache != nullptr) {
      return *reinterpret_cast<std::shared_ptr<Caches>*>(cache);
    }
    // this should only happen when an isolate is accessed after disposal
    // so we return a dummy cache
    return std::make_shared<Caches>(isolate);
  }
  static void Remove(v8::Isolate* isolate);

  inline int getIsolateId() { return isolateId_; }

  inline void InvalidateIsolate() { isolateId_ = -1; }

  inline bool IsValid() { return isolateId_ != -1; }

  void SetContext(v8::Local<v8::Context> context);
  v8::Local<v8::Context> GetContext();
  // GetContext crashes before SetContext; work can run in that window (v8
  // posts foreground tasks during Isolate::New)
  inline bool HasContext() { return context_ != nullptr; }

  // Per-isolate unhandled promise rejection tracking. Fed by
  // NativeScriptException::OnPromiseRejected and drained once per runloop turn.
  std::unique_ptr<PromiseRejectionTracker> PromiseRejections;

  // Head of the intrusive list of wrappers registered by
  // ObjectManager::Register(). V8 no longer offers a way to enumerate
  // persistent handles, so teardown disposal walks this instead. Entries unlink
  // themselves when the wrapper is disposed, so the list only ever holds live
  // wrappers.
  ObjectWeakCallbackState* ObjectManagedValues = nullptr;

  robin_hood::unordered_map<const Meta*,
                            std::unique_ptr<v8::Persistent<v8::Value>>>
      Prototypes;
  robin_hood::unordered_map<std::string,
                            std::unique_ptr<v8::Persistent<v8::Object>>,
                            TransparentStringHash, TransparentStringEqual>
      ClassPrototypes;
  robin_hood::unordered_map<
      const BaseClassMeta*,
      std::unique_ptr<v8::Persistent<v8::FunctionTemplate>>>
      CtorFuncTemplates;
  robin_hood::unordered_map<std::string,
                            std::unique_ptr<v8::Persistent<v8::Function>>>
      CtorFuncs;
  robin_hood::unordered_map<std::string,
                            std::unique_ptr<v8::Persistent<v8::Function>>>
      ProtocolCtorFuncs;
  robin_hood::unordered_map<std::string,
                            std::unique_ptr<v8::Persistent<v8::Function>>>
      StructConstructorFunctions;
  robin_hood::unordered_map<BinaryTypeEncodingType,
                            std::unique_ptr<v8::Persistent<v8::Object>>>
      PrimitiveInteropTypes;
  robin_hood::unordered_map<std::string,
                            std::unique_ptr<v8::Persistent<v8::Function>>>
      CFunctions;

  robin_hood::unordered_map<id, std::shared_ptr<v8::Persistent<v8::Value>>>
      Instances;

  // Native object being adopted by an in-flight ES construct (CreateJsWrapper
  // → CallAsConstructor → super()). void* so this header stays includable
  // from C++ TUs; .mm files cast to/from id. ConstructObject consumes it
  // so super() binds that id and does not alloc/init again.
  void* PendingESAdopt = nullptr;
  robin_hood::unordered_map<std::pair<void*, std::string>,
                            std::shared_ptr<v8::Persistent<v8::Value>>,
                            pair_hash>
      StructInstances;
  robin_hood::unordered_map<const void*,
                            std::shared_ptr<v8::Persistent<v8::Object>>>
      PointerInstances;

  // Live IsolateTracked instances (URL, URLSearchParams, URLPattern). Their
  // weak-callback finalizers never fire at isolate disposal, so teardown
  // sweeps this set to delete whatever GC didn't get to.
  robin_hood::unordered_set<IsolateTracked*> TrackedInstances;

  std::function<v8::Local<v8::FunctionTemplate>(
      v8::Local<v8::Context>, const BaseClassMeta*, KnownUnknownClassPair,
      const std::vector<std::string>&)>
      ObjectCtorInitializer;
  std::function<v8::Local<v8::Function>(v8::Local<v8::Context>, StructInfo)>
      StructCtorInitializer;
  robin_hood::unordered_map<std::string, double> Timers;
  robin_hood::unordered_map<const InterfaceMeta*,
                            std::vector<const MethodMeta*>>
      Initializers;

  std::unique_ptr<v8::Persistent<v8::Function>> EmptyObjCtorFunc =
      std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);
  std::unique_ptr<v8::Persistent<v8::Function>> EmptyStructCtorFunc =
      std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);
  std::unique_ptr<v8::Persistent<v8::Function>> SliceFunc =
      std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);
  std::unique_ptr<v8::Persistent<v8::Function>> OriginalExtendsFunc =
      std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);
  std::unique_ptr<v8::Persistent<v8::Function>> WeakRefGetterFunc =
      std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);
  std::unique_ptr<v8::Persistent<v8::Function>> WeakRefClearFunc =
      std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);
  // console formatter (internal/inspect.js), initialized by Console::Init.
  std::unique_ptr<v8::Persistent<v8::Function>> InspectFunc =
      std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);
  // ns:util's format, used by console.* for %-substitution.
  std::unique_ptr<v8::Persistent<v8::Function>> FormatFunc =
      std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);
  bool FormatFuncUnavailable = false;
  std::unique_ptr<v8::Persistent<v8::Function>> InteropReferenceCtorFunc =
      std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);
  std::unique_ptr<v8::Persistent<v8::Function>> PointerCtorFunc =
      std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);
  std::unique_ptr<v8::Persistent<v8::Function>> FunctionReferenceCtorFunc =
      std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);
  std::unique_ptr<v8::Persistent<v8::Function>> UnmanagedTypeCtorFunc =
      std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);

  // `ns:`/`node:` builtin modules (NsBuiltinModules), keyed by specifier. Both
  // are per isolate: a builtin module is a singleton per realm, so workers get
  // their own exports objects and their own synthetic modules.
  robin_hood::unordered_map<std::string,
                            std::unique_ptr<v8::Persistent<v8::Object>>>
      BuiltinModuleExports;
  robin_hood::unordered_map<std::string,
                            std::unique_ptr<v8::Persistent<v8::Module>>>
      BuiltinModules;
  // Specifiers currently being built, so a shim requiring back into the module
  // that is loading it fails instead of recursing.
  robin_hood::unordered_set<std::string> BuiltinModulesInProgress;
  // The `require` handed to every builtin, resolving builtin specifiers only.
  std::unique_ptr<v8::Persistent<v8::Function>> BuiltinRequire =
      std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);

  // Frozen intrinsics snapshot returned by internal/primordials.js, passed to
  // every builtin as its second fixed parameter (BuiltinLoader::RunBuiltin).
  // Per isolate, so workers snapshot their own realm's intrinsics.
  std::unique_ptr<v8::Persistent<v8::Object>> Primordials =
      std::unique_ptr<v8::Persistent<v8::Object>>(nullptr);

  // Internal EventTarget instance backing the global, returned by the generic
  // event-primitives bootstrap IIFE (Events::Init). Holds the real listener
  // store, so native layers dispatch through it without going through
  // overwritable globals. Cleaned up with the other Persistent members when
  // Caches is destroyed, before isolate disposal.
  std::unique_ptr<v8::Persistent<v8::Object>> GlobalEventTarget =
      std::unique_ptr<v8::Persistent<v8::Object>>(nullptr);

  // Phase 2 WHATWG error-events dispatch closures returned by the bootstrap
  // IIFE (ErrorEvents::Init). They close over the internal listener store, so
  // native dispatch keeps working even if app code overwrites
  // globalThis.dispatchEvent. Cleaned up with the other Persistent members when
  // Caches is destroyed, before isolate disposal.
  std::unique_ptr<v8::Persistent<v8::Function>> DispatchErrorEventFunc =
      std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);
  std::unique_ptr<v8::Persistent<v8::Function>> DispatchUnhandledRejectionFunc =
      std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);
  std::unique_ptr<v8::Persistent<v8::Function>> DispatchRejectionHandledFunc =
      std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);
  std::unique_ptr<v8::Persistent<v8::Function>>
      DispatchReleasedNativeAccessFunc =
          std::unique_ptr<v8::Persistent<v8::Function>>(nullptr);

  // Phase 3 per-isolate brand for interop.escapeException. An isolate-private
  // symbol (v8::Private, not a plain Symbol) so user code cannot discover or
  // forge it. Created lazily via ArgConverter::GetEscapeExceptionBrand and used
  // to mark/extract escaped native exceptions across JS<->native boundaries.
  std::unique_ptr<v8::Persistent<v8::Private>> EscapeExceptionBrand =
      std::unique_ptr<v8::Persistent<v8::Private>>(nullptr);

  using unique_void_ptr = std::unique_ptr<void, void (*)(void const*)>;
  template <typename T>
  auto unique_void(T* ptr) -> unique_void_ptr {
    return unique_void_ptr(ptr, [](void const* data) {
      T const* p = static_cast<T const*>(data);
      delete p;
    });
  }
  std::vector<unique_void_ptr> cacheBoundObjects_;
  template <typename T>
  void registerCacheBoundObject(T* ptr) {
    this->cacheBoundObjects_.push_back(unique_void(ptr));
  }

 private:
  v8::Isolate* isolate_;
  std::shared_ptr<v8::Persistent<v8::Context>> context_;
  int isolateId_;
};

}  // namespace tns

#endif /* Caches_h */
