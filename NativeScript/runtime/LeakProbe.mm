#include "LeakProbe.h"
#include <dlfcn.h>
#include <memory>
#include <unordered_map>
#include "Caches.h"
#include "ClassBuilder.h"
#include "DataWrapper.h"
#include "EventLoop.h"
#include "Helpers.h"
#include "Interop.h"
#include "LeakProbeSPI.h"
#include "ObjectManager.h"
#include "Runtime.h"
#include "RuntimeConfig.h"
#include "WrapperLifetime.h"
#include "WrapperLifetimeCanary.h"

using namespace v8;

namespace tns {
namespace leakprobe {

struct Poster {
  Isolate* isolate;
  std::weak_ptr<EventLoop> loop;
};

}  // namespace leakprobe

namespace {

using leakprobe::Host;
using leakprobe::Instance;
using leakprobe::Poster;
using leakprobe::Probe;

constexpr const char* kFramework = "NativeScriptLeakProbe.framework";

struct ProbeState {
  bool attached = false;
  void* state = nullptr;
  void (*destroy)(void*) = nullptr;

  ~ProbeState() {
    if (destroy != nullptr) {
      destroy(state);
    }
  }
};

bool ForEachInstance(Isolate* isolate, void* context,
                     void (*visit)(void* context, const Instance& instance)) {
  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  if (cache == nullptr || !cache->IsValid()) {
    return false;
  }
  // A wrapper built for an object whose previous wrapper's release is still
  // queued replaces its Instances entry, so a queued retain may have none.
  std::unordered_map<void*, uint32_t> queued;
  WrapperLifetime::ForEachQueuedRelease(isolate,
                                        [&](id object) { queued[(__bridge void*)object]++; });
  for (auto& entry : cache->Instances) {
    const std::shared_ptr<Persistent<Value>>& handle = entry.second;
    Instance instance{};
    instance.object = (__bridge void*)entry.first;
    auto pending = queued.find(instance.object);
    if (pending != queued.end()) {
      instance.queued = pending->second;
      queued.erase(pending);
    }
    if (handle != nullptr && !handle->IsEmpty()) {
      instance.wrapper = handle->Get(isolate);
      BaseDataWrapper* data = GetValue(isolate, instance.wrapper);
      if (data != nullptr && data->Type() == WrapperType::ObjCObject) {
        ObjCDataWrapper* wrapper = static_cast<ObjCDataWrapper*>(data);
        instance.objc = true;
        instance.wrapped = (__bridge void*)wrapper->Data();
        instance.wrappedClass = wrapper->Klass();
        ObjectWeakCallbackState* lifetime = wrapper->LifetimeState();
        instance.rootedStrong =
            lifetime != nullptr && lifetime->lifetimeTracked_ && lifetime->lifetimeStrong_;
        ObjectWeakCallbackState* ownership = wrapper->OwnershipState();
        instance.reconciledStrong = ownership != nullptr && !ownership->disposing_ &&
                                    ownership->target_ == handle && !handle->IsWeak();
        // A handle under ownership tracking is reconciled before every major
        // collection, the snapshot's included, so reconciledStrong covers it.
        instance.resurrects = handle->IsWeak() && wrapper->IsGcProtected();
      }
    }
    visit(context, instance);
  }
  for (const auto& [object, count] : queued) {
    Instance instance{};
    instance.object = object;
    instance.queued = count;
    visit(context, instance);
  }
  return true;
}

void ForEachCanaryState(Isolate* isolate, void* context,
                        void (*visit)(void* context, id object, Local<Object> state)) {
  WrapperLifetimeCanary::ForEachState(
      isolate, [&](id object, Local<Object> state) { visit(context, object, state); });
}

void ForEachCanaryStateHandle(Isolate* isolate, void* context,
                              void (*visit)(void* context, Local<Object> state)) {
  WrapperLifetimeCanary::ForEachStateHandle(isolate,
                                            [&](Local<Object> state) { visit(context, state); });
}

void DrainReleases(Isolate* isolate) {
  WrapperLifetime::DrainReleases(isolate);
  WrapperLifetimeCanary::ReleaseDeadStates(isolate);
}

void* IsolateState(Isolate* isolate) {
  ProbeState* probe = Caches::StateFor<ProbeState>(isolate);
  return probe != nullptr ? probe->state : nullptr;
}

bool SetIsolateState(Isolate* isolate, void* state, void (*destroy)(void*)) {
  ProbeState* probe = Caches::StateFor<ProbeState>(isolate);
  if (probe == nullptr) {
    return false;
  }
  if (probe->destroy != nullptr) {
    probe->destroy(probe->state);
  }
  probe->state = state;
  probe->destroy = destroy;
  return true;
}

Poster* CreatePoster(Isolate* isolate) {
  Runtime* runtime = Runtime::GetRuntime(isolate);
  if (runtime == nullptr || runtime->GetEventLoop() == nullptr) {
    return nullptr;
  }
  return new Poster{isolate, runtime->GetEventLoop()};
}

bool Post(Poster* poster, void (*task)(Isolate* isolate, void* context), void* context) {
  std::shared_ptr<EventLoop> loop = poster->loop.lock();
  if (loop == nullptr) {
    return false;
  }
  Isolate* isolate = poster->isolate;
  return loop->PostInternal([isolate, task, context]() { task(isolate, context); });
}

bool LifetimeStats(Isolate* isolate, leakprobe::LifetimeStats* out) {
  ObjectManager::LifetimeStats* stats = ObjectManager::GetLifetimeStats(isolate);
  if (stats == nullptr) {
    return false;
  }
  *out = {
      .resurrections = stats->resurrections,
      .collected = stats->collected,
      .releasedExplicitly = stats->releasedExplicitly,
      .releasedAccesses = stats->releasedAccesses,
      .queuedReleases = stats->queuedReleases,
      .canaryStates = stats->canaryStates,
      .canaryNativeDeaths = stats->canaryNativeDeaths,
  };
  return true;
}

const Host kHost = {
    .version = leakprobe::kVersion,
    .size = sizeof(Host),
    .forEachInstance = ForEachInstance,
    .forEachCanaryState = ForEachCanaryState,
    .forEachCanaryStateHandle = ForEachCanaryStateHandle,
    .isJSBlock = Interop::IsJSBlock,
    .jsBlockCallback = Interop::JSBlockCallback,
    .nativeClass = ClassBuilder::FindNativeClass,
    .isolateState = IsolateState,
    .setIsolateState = SetIsolateState,
    .createPoster = CreatePoster,
    .post = Post,
    .destroyPoster = [](Poster* poster) { delete poster; },
    .drainReleases = DrainReleases,
    .lifetimeMode = []() { return WrapperLifetimeModeName(GetWrapperLifetimeMode()); },
    .lifetimeScope = []() { return WrapperLifetimeScopeName(GetWrapperLifetimeScope()); },
    .lifetimeStats = LifetimeStats,
    .appConfigValue = [](const char* key) { return Runtime::GetAppConfigValue(key); },
    .isDebug = []() { return RuntimeConfig.IsDebug; },
    .log = [](const char* message) { Log("%s", message); },
};

// The framework's Probe, once per process: dyld loads the framework, when the
// app embeds it, before the runtime starts.
const Probe* ConnectedProbe() {
  static const Probe* probe = []() -> const Probe* {
    auto connect = reinterpret_cast<leakprobe::ConnectFunction>(
        dlsym(RTLD_DEFAULT, leakprobe::kConnectSymbol));
    if (connect == nullptr) {
      return nullptr;
    }
    const Probe* connected = connect(&kHost);
    if (connected == nullptr || connected->version != leakprobe::kVersion ||
        connected->size != sizeof(Probe)) {
      Log("NativeScript: ignoring %s, built for another runtime version", kFramework);
      return nullptr;
    }
    return connected;
  }();
  return probe;
}

const Probe* AttachedProbe(Isolate* isolate) {
  ProbeState* state = Caches::ExistingStateFor<ProbeState>(isolate);
  return state != nullptr && state->attached ? ConnectedProbe() : nullptr;
}

void ThrowAbsent(Isolate* isolate, const char* function) {
  std::string message = std::string(function) + " needs " + kFramework +
                        ", which apps embed only in debug builds by default. To ship it in "
                        "other builds, add " +
                        kFramework + " to NS_SHIP_DEBUG_FRAMEWORKS in the app's build.xcconfig.";
  isolate->ThrowException(Exception::Error(ToV8String(isolate, message)));
}

void FindLeakCyclesCallback(const FunctionCallbackInfo<Value>& info) {
  if (const Probe* probe = AttachedProbe(info.GetIsolate())) {
    probe->findLeakCycles(info);
    return;
  }
  ThrowAbsent(info.GetIsolate(), "findLeakCycles");
}

void GetWrapperClassCountsCallback(const FunctionCallbackInfo<Value>& info) {
  if (const Probe* probe = AttachedProbe(info.GetIsolate())) {
    probe->getWrapperClassCounts(info);
    return;
  }
  ThrowAbsent(info.GetIsolate(), "getWrapperClassCounts");
}

}  // namespace

void LeakProbe::Init(Isolate* isolate) {
  const Probe* probe = ConnectedProbe();
  if (probe == nullptr) {
    return;
  }
  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  ProbeState* state = Caches::StateFor<ProbeState>(isolate);
  if (cache == nullptr || state == nullptr) {
    return;
  }
  state->attached = probe->attach(isolate, !cache->isWorker);
}

bool LeakProbe::RegisterFunctions(Local<Context> context, Local<Object> binding) {
  Isolate* isolate = Isolate::GetCurrent();
  Local<v8::Function> counts;
  Local<v8::Function> cycles;
  return v8::Function::New(context, GetWrapperClassCountsCallback).ToLocal(&counts) &&
         v8::Function::New(context, FindLeakCyclesCallback).ToLocal(&cycles) &&
         binding->Set(context, ToV8String(isolate, "getWrapperClassCounts"), counts)
             .FromMaybe(false) &&
         binding->Set(context, ToV8String(isolate, "findLeakCycles"), cycles).FromMaybe(false);
}

}  // namespace tns
