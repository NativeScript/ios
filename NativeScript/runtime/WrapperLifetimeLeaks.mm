#include "WrapperLifetimeLeaks.h"
#import <Foundation/Foundation.h>
#include <malloc/malloc.h>
#include <notify.h>
#include <objc/runtime.h>
#include <v8-profiler.h>
#include <algorithm>
#include <chrono>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <regex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include "Caches.h"
#include "ClassBuilder.h"
#include "DataWrapper.h"
#include "EventLoop.h"
#include "Helpers.h"
#include "Interop.h"
#include "ObjectManager.h"
#include "Runtime.h"
#include "RuntimeConfig.h"
#include "WrapperLifetime.h"
#include "WrapperLifetimeCanary.h"

extern "C" const uintptr_t objc_debug_isa_class_mask;

using namespace v8;

namespace tns {

namespace {

constexpr const char* kCountsNotification = "org.nativescript.wrapperLifetime.counts";
constexpr const char* kCyclesNotification = "org.nativescript.wrapperLifetime.findLeakCycles";
constexpr const char* kStrictCyclesNotification =
    "org.nativescript.wrapperLifetime.findLeakCycles.strict";
constexpr const char* kLogPrefix = "NativeScript wrapper lifetime:";

constexpr size_t kMaxNativeObjects = 200000;
constexpr int kMaxNativeDepth = 8;
constexpr size_t kMaxStorageBytes = 64 * 1024;
constexpr int kMaxStorageDepth = 2;
constexpr size_t kMaxCycleLength = 64;
constexpr size_t kMemoryWarningTopClasses = 10;

// ---- Native object graph -------------------------------------------------

using ClassSet = std::unordered_set<uintptr_t>;

struct NativeEntry {
  Class cls = nil;
  bool block = false;
  // Wrapped by this isolate or holding JS state in it.
  bool seed = false;
  int depth = 0;
  int64_t retainCount = 0;
  int64_t runtimeRetains = 0;
  int64_t incoming = 0;
  std::vector<std::pair<void*, std::string>> out;

  int64_t Unexplained() const { return retainCount - runtimeRetains - incoming; }
  bool Immortal() const { return retainCount >= static_cast<int64_t>(NSUIntegerMax >> 1); }
};

// One findLeakCycles call. The snapshot's embedder graph callback runs on the
// calling thread, inside TakeHeapSnapshot.
struct ProbeRun {
  bool strict = false;
  ClassSet classes;
  std::unordered_map<Class, std::vector<std::pair<size_t, std::string>>> slots;
  std::unordered_map<Class, bool> typedClasses;
  std::unordered_map<Class, IMP> retainCountImps;
  std::unordered_map<void*, NativeEntry> natives;
  // Global handles that stand for native -> JS edges.
  std::unordered_set<SnapshotObjectId> modeledHandles;
  bool truncated = false;

  bool Root(const NativeEntry& entry) const {
    if (entry.Immortal() || entry.Unexplained() > 0) {
      return true;
    }
    return !strict && entry.Unexplained() < 0;
  }
};

thread_local ProbeRun* activeRun_ = nullptr;

bool IsTaggedPointer(uintptr_t p) {
#if defined(__arm64__)
  return (p >> 63) != 0;
#else
  return (p & 1) != 0;
#endif
}

size_t HeapBlockSize(uintptr_t p) {
  if (p == 0 || IsTaggedPointer(p) || (p & (sizeof(void*) - 1)) != 0) {
    return 0;
  }
  if (malloc_zone_from_ptr(reinterpret_cast<void*>(p)) == nullptr) {
    return 0;
  }
  return malloc_size(reinterpret_cast<void*>(p));
}

ClassSet LoadClasses() {
  ClassSet classes;
  unsigned int count = 0;
  Class* list = objc_copyClassList(&count);
  for (unsigned int i = 0; i < count; i++) {
    classes.insert(reinterpret_cast<uintptr_t>(list[i]));
  }
  free(list);
  return classes;
}

// The class of the object starting at `p`, or nil when the block does not
// start with the isa of a known class.
Class ObjectClass(const ClassSet& classes, uintptr_t p, size_t size) {
  if (size < sizeof(void*)) {
    return nil;
  }
  // The simulator's isa keeps more class bits than objc_debug_isa_class_mask
  // admits; classes allocated at runtime (JS-extended ones) live above it.
  uintptr_t isa = *reinterpret_cast<uintptr_t*>(p);
  for (uintptr_t mask :
       {objc_debug_isa_class_mask, static_cast<uintptr_t>(0x00007ffffffffff8ULL)}) {
    uintptr_t cls = isa & mask;
    if (classes.count(cls)) {
      return reinterpret_cast<Class>(cls);
    }
  }
  return nil;
}

std::unordered_set<size_t> LayoutWords(const uint8_t* layout, size_t firstWord) {
  std::unordered_set<size_t> words;
  if (layout == nullptr) {
    return words;
  }
  size_t index = firstWord;
  for (const uint8_t* b = layout; *b; b++) {
    index += (*b >> 4);
    for (int i = 0; i < (*b & 0xf); i++) {
      words.insert(index++);
    }
  }
  return words;
}

// Object ivars that can own: weak ivars are dropped, and so is everything
// outside the strong layout of a class that has one (ARC __unsafe_unretained).
// `typed` is false for classes without object ivars, which are scanned as
// storage instead.
const std::vector<std::pair<size_t, std::string>>& OwningSlots(ProbeRun* run, Class cls,
                                                               bool* typed) {
  auto known = run->typedClasses.find(cls);
  if (known != run->typedClasses.end()) {
    *typed = known->second;
    return run->slots[cls];
  }
  std::vector<std::pair<size_t, std::string>> slots;
  bool anyObjectIvar = false;
  for (Class c = cls; c != nil; c = class_getSuperclass(c)) {
    unsigned int count = 0;
    Ivar* ivars = class_copyIvarList(c, &count);
    size_t firstWord = SIZE_MAX;
    for (unsigned int i = 0; i < count; i++) {
      firstWord =
          std::min(firstWord, static_cast<size_t>(ivar_getOffset(ivars[i])) / sizeof(void*));
    }
    const uint8_t* strong = class_getIvarLayout(c);
    std::unordered_set<size_t> strongWords = LayoutWords(strong, firstWord);
    std::unordered_set<size_t> weakWords = LayoutWords(class_getWeakIvarLayout(c), firstWord);
    for (unsigned int i = 0; i < count; i++) {
      const char* type = ivar_getTypeEncoding(ivars[i]);
      if (type == nullptr || type[0] != '@') {
        continue;
      }
      anyObjectIvar = true;
      size_t offset = ivar_getOffset(ivars[i]);
      size_t word = offset / sizeof(void*);
      if (weakWords.count(word) || (strong != nullptr && !strongWords.count(word))) {
        continue;
      }
      slots.push_back({offset, ivar_getName(ivars[i])});
    }
    free(ivars);
  }
  run->typedClasses[cls] = anyObjectIvar;
  *typed = anyObjectIvar;
  return run->slots[cls] = std::move(slots);
}

// Containers that usually hold their elements weakly. Their strong variants
// become hidden owners: a missed cycle, never a reported one.
bool NonOwningContainer(Class cls) {
  static Class hashTable = objc_getClass("NSConcreteHashTable");
  static Class mapTable = objc_getClass("NSConcreteMapTable");
  static Class pointerArray = objc_getClass("NSConcretePointerArray");
  return cls != nil && (cls == hashTable || cls == mapTable || cls == pointerArray);
}

// Object pointers in a block that is not an object (collection storage, block
// captures), following nested storage a little way.
void ScanStorage(ProbeRun* run, uintptr_t p, size_t size, int depth, const std::string& prefix,
                 std::vector<std::pair<void*, std::string>>* out) {
  size_t limit = std::min(size, kMaxStorageBytes);
  for (size_t offset = 0; offset + sizeof(void*) <= limit; offset += sizeof(void*)) {
    uintptr_t value = *reinterpret_cast<uintptr_t*>(p + offset);
    if (value == p) {
      continue;
    }
    size_t valueSize = HeapBlockSize(value);
    if (valueSize == 0) {
      continue;
    }
    std::string label = prefix + "+" + std::to_string(offset);
    if (ObjectClass(run->classes, value, valueSize) != nil) {
      out->push_back({reinterpret_cast<void*>(value), label});
    } else if (depth < kMaxStorageDepth) {
      ScanStorage(run, value, valueSize, depth + 1, label, out);
    }
  }
}

// libclosure's Block_layout: blocks answer -retainCount with 1, the real count
// is in the flags.
struct BlockHeader {
  void* isa;
  volatile int32_t flags;
  int32_t reserved;
  void* invoke;
  void* descriptor;
};

int64_t RetainCountOf(ProbeRun* run, void* object, const NativeEntry& entry) {
  if (entry.block) {
    return (static_cast<BlockHeader*>(object)->flags & 0xfffe) >> 1;
  }
  // The class's own implementation: a JS-implemented one cannot run here.
  IMP& imp = run->retainCountImps[entry.cls];
  if (imp == nullptr) {
    imp = ClassBuilder::FindNotOverridenMethod(entry.cls, @selector(retainCount));
  }
  return static_cast<int64_t>(
      reinterpret_cast<NSUInteger (*)(id, SEL)>(imp)((__bridge id)object, @selector(retainCount)));
}

void Expand(ProbeRun* run, void* object, NativeEntry* entry) {
  uintptr_t p = reinterpret_cast<uintptr_t>(object);
  size_t size = HeapBlockSize(p);
  if (size == 0 || NonOwningContainer(entry->cls)) {
    return;
  }
  if (entry->block) {
    // A JS block's fields past the header are runtime bookkeeping that points
    // back at the block; its one reference is the callback (a graph edge).
    if (size > sizeof(BlockHeader) && !Interop::IsJSBlock(object)) {
      ScanStorage(run, p + sizeof(BlockHeader), size - sizeof(BlockHeader), 1, "capture",
                  &entry->out);
    }
    return;
  }
  bool typed = false;
  const auto& slots = OwningSlots(run, entry->cls, &typed);
  if (!typed) {
    ScanStorage(run, p + sizeof(void*), size - sizeof(void*), 0, "", &entry->out);
    return;
  }
  for (const auto& slot : slots) {
    if (slot.first + sizeof(void*) > size) {
      continue;
    }
    uintptr_t value = *reinterpret_cast<uintptr_t*>(p + slot.first);
    size_t valueSize = HeapBlockSize(value);
    if (valueSize != 0 && ObjectClass(run->classes, value, valueSize) != nil) {
      entry->out.push_back({reinterpret_cast<void*>(value), slot.second});
    }
  }
}

bool IsAdapter(Class cls) {
  static Class arrayAdapter = objc_getClass("ArrayAdapter");
  static Class dictionaryAdapter = objc_getClass("DictionaryAdapter");
  static Class dataAdapter = objc_getClass("NSDataAdapter");
  for (Class c = cls; c != nil; c = class_getSuperclass(c)) {
    if (c == arrayAdapter || c == dictionaryAdapter || c == dataAdapter) {
      return true;
    }
  }
  return false;
}

// An Instances entry the graph can rely on.
struct Instance {
  Class cls = nil;
  Local<Value> js;
  // A native collection or data adapter backed by a JS object: the adapter
  // holds the JS object strongly, and the JS object does not retain it.
  bool adapter = false;
  ObjectWeakCallbackState* lifetime = nullptr;
};

// False for entries whose key must not be dereferenced as the wrapped object:
// a dead wrapper, a key that is not a live heap object, or an address now
// holding another object than the one its wrapper was made for.
bool ReadInstance(Isolate* isolate, const ClassSet& classes, id key,
                  const std::shared_ptr<Persistent<Value>>& handle, Instance* out) {
  uintptr_t p = reinterpret_cast<uintptr_t>((__bridge void*)key);
  if (handle == nullptr || handle->IsEmpty() || IsTaggedPointer(p)) {
    return false;
  }
  Class cls = ObjectClass(classes, p, HeapBlockSize(p));
  if (cls == nil) {
    return false;
  }
  out->cls = cls;
  out->js = handle->Get(isolate);
  if (IsAdapter(cls)) {
    out->adapter = true;
    return true;
  }
  BaseDataWrapper* data = tns::GetValue(isolate, out->js);
  if (data == nullptr || data->Type() != WrapperType::ObjCObject) {
    return false;
  }
  ObjCDataWrapper* wrapper = static_cast<ObjCDataWrapper*>(data);
  Class made = wrapper->Klass();
  // KVO swaps in a subclass of the original while the object is observed and
  // swaps it back afterwards, so either class can be the one it was wrapped as.
  if (wrapper->Data() != key ||
      (cls != made && class_getSuperclass(cls) != made && class_getSuperclass(made) != cls)) {
    return false;
  }
  out->lifetime = wrapper->LifetimeState();
  return true;
}

bool RootedStrong(const Instance& instance) {
  return instance.lifetime != nullptr && instance.lifetime->lifetimeTracked_ &&
         instance.lifetime->lifetimeStrong_;
}

// Reads native memory that other threads may be mutating; acceptable for an
// on-demand diagnostic, which is why it never runs implicitly.
void BuildNativeGraph(Isolate* isolate, ProbeRun* run, const std::shared_ptr<Caches>& cache) {
  static Class blockClass = objc_getClass("NSBlock");

  std::deque<void*> queue;
  auto add = [&](void* object, int depth) -> NativeEntry* {
    auto found = run->natives.find(object);
    if (found != run->natives.end()) {
      return &found->second;
    }
    if (run->natives.size() >= kMaxNativeObjects) {
      run->truncated = true;
      return nullptr;
    }
    NativeEntry entry;
    entry.cls = object_getClass((__bridge id)object);
    entry.block = blockClass != nil && [entry.cls isSubclassOfClass:blockClass];
    entry.depth = depth;
    queue.push_back(object);
    return &run->natives.emplace(object, std::move(entry)).first->second;
  };

  for (auto& entry : cache->Instances) {
    Instance instance;
    if (!ReadInstance(isolate, run->classes, entry.first, entry.second, &instance)) {
      continue;
    }
    if (NativeEntry* native = add((__bridge void*)entry.first, 0)) {
      native->seed = true;
      native->runtimeRetains = instance.adapter ? 0 : 1;
    }
  }
  WrapperLifetimeCanary::ForEachState(isolate, [&](id object, Local<Object>) {
    if (NativeEntry* entry = add((__bridge void*)object, 0)) {
      entry->seed = true;
    }
  });

  while (!queue.empty()) {
    void* object = queue.front();
    queue.pop_front();
    NativeEntry& entry = run->natives[object];
    if (entry.depth >= kMaxNativeDepth) {
      continue;
    }
    Expand(run, object, &entry);
    // A pointer to itself never owns the object.
    entry.out.erase(std::remove_if(entry.out.begin(), entry.out.end(),
                                   [&](const auto& edge) { return edge.first == object; }),
                    entry.out.end());
    int depth = entry.depth;
    std::vector<std::pair<void*, std::string>> out = entry.out;
    for (const auto& edge : out) {
      if (NativeEntry* target = add(edge.first, depth + 1)) {
        target->incoming++;
      }
    }
  }
  for (auto& native : run->natives) {
    native.second.retainCount = RetainCountOf(run, native.first, native.second);
  }
}

class NativeObjectNode : public EmbedderGraph::Node {
 public:
  NativeObjectNode(void* object, Class cls, bool root)
      : object_(object), root_(root), name_(std::string("ObjC ") + class_getName(cls)) {}
  const char* Name() override { return name_.c_str(); }
  size_t SizeInBytes() override { return malloc_size(object_); }
  const void* GetAddress() override { return object_; }
  bool IsRootNode() override { return root_; }

 private:
  void* object_;
  bool root_;
  std::string name_;
};

void BuildEmbedderGraph(Isolate* isolate, EmbedderGraph* graph, void*) {
  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  if (cache == nullptr || !cache->IsValid()) {
    return;
  }
  ProbeRun* run = activeRun_;
  ClassSet ownClasses;
  if (run != nullptr) {
    run->classes = LoadClasses();
    BuildNativeGraph(isolate, run, cache);
  } else {
    ownClasses = LoadClasses();
  }
  const ClassSet& classes = run != nullptr ? run->classes : ownClasses;
  HeapProfiler* profiler = isolate->GetHeapProfiler();
  std::unordered_map<void*, EmbedderGraph::Node*> nodes;
  auto nodeFor = [&](void* object) {
    EmbedderGraph::Node*& node = nodes[object];
    if (node == nullptr) {
      bool root = false;
      if (run != nullptr) {
        auto found = run->natives.find(object);
        root = found == run->natives.end() || run->Root(found->second);
      }
      node = graph->AddNode(
          std::make_unique<NativeObjectNode>(object, object_getClass((__bridge id)object), root));
    }
    return node;
  };
  auto modeled = [&](Local<Value> value) {
    if (run != nullptr) {
      run->modeledHandles.insert(profiler->GetObjectId(value));
    }
  };

  for (auto& entry : cache->Instances) {
    Instance instance;
    if (!ReadInstance(isolate, classes, entry.first, entry.second, &instance)) {
      continue;
    }
    EmbedderGraph::Node* native = nodeFor((__bridge void*)entry.first);
    EmbedderGraph::Node* js = graph->V8Node(instance.js);
    if (instance.adapter) {
      graph->AddEdge(native, js, "ns:adapter");
      modeled(instance.js);
      continue;
    }
    graph->AddEdge(js, native, "ns:retain");
    if (RootedStrong(instance)) {
      graph->AddEdge(native, js, "ns:owned");
      modeled(instance.js);
    }
  }
  WrapperLifetimeCanary::ForEachState(isolate, [&](id object, Local<Object> state) {
    graph->AddEdge(nodeFor((__bridge void*)object), graph->V8Node(state.As<Value>()), "ns:state");
    modeled(state);
  });
  if (run == nullptr) {
    return;
  }
  for (auto& native : run->natives) {
    EmbedderGraph::Node* from = nodeFor(native.first);
    for (const auto& edge : native.second.out) {
      graph->AddEdge(from, nodeFor(edge.first), edge.second.c_str());
    }
    if (native.second.block) {
      Local<Value> callback = Interop::JSBlockCallback(isolate, native.first);
      if (!callback.IsEmpty()) {
        graph->AddEdge(from, graph->V8Node(callback), "ns:block-callback");
        modeled(callback);
      }
    }
  }
}

// ---- Analysis ------------------------------------------------------------

std::string Utf8(Isolate* isolate, Local<Value> value) {
  v8::String::Utf8Value utf8(isolate, value);
  return *utf8 != nullptr ? std::string(*utf8, utf8.length()) : std::string();
}

std::string EdgeName(Isolate* isolate, const HeapGraphEdge* edge) {
  Local<Value> name = edge->GetName();
  if (name->IsNumber()) {
    return "[" + std::to_string(static_cast<int64_t>(name.As<v8::Number>()->Value())) + "]";
  }
  return Utf8(isolate, name);
}

std::string NodeName(Isolate* isolate, const HeapGraphNode* node) {
  std::string name = Utf8(isolate, node->GetName());
  return name.empty() ? "(anonymous)" : name;
}

bool Strong(const HeapGraphEdge* edge) {
  return edge->GetType() != HeapGraphEdge::kWeak && edge->GetType() != HeapGraphEdge::kShortcut;
}

const HeapGraphNode* Child(Isolate* isolate, const HeapGraphNode* node, const char* name) {
  for (int i = 0; node != nullptr && i < node->GetChildrenCount(); i++) {
    const HeapGraphNode* child = node->GetChild(i)->GetToNode();
    if (NodeName(isolate, child) == name) {
      return child;
    }
  }
  return nullptr;
}

std::string HexAddress(const void* p) {
  char buffer[24];
  snprintf(buffer, sizeof buffer, "0x%lx",
           static_cast<unsigned long>(reinterpret_cast<uintptr_t>(p)));
  return buffer;
}

struct Hop {
  const HeapGraphNode* node;
  std::string edge;
};

struct Cycle {
  std::vector<Hop> hops;
  std::string path;
  std::string signature;
  std::vector<std::pair<std::string, void*>> members;
  std::vector<std::string> reasons;
};

// The shortest cycle through `start` within unmarked nodes.
bool FindCycle(Isolate* isolate, const HeapGraphNode* start,
               const std::unordered_set<const HeapGraphNode*>& marked, std::vector<Hop>* hops) {
  // A rooted-strong wrapper and its object always form a two-node loop; a
  // leak needs a cycle that leaves through another edge.
  const HeapGraphNode* ownWrapper = nullptr;
  for (int i = 0; i < start->GetChildrenCount(); i++) {
    if (EdgeName(isolate, start->GetChild(i)) == "ns:owned") {
      ownWrapper = start->GetChild(i)->GetToNode();
    }
  }
  std::unordered_map<const HeapGraphNode*, std::pair<const HeapGraphNode*, const HeapGraphEdge*>>
      parent;
  std::deque<const HeapGraphNode*> queue{start};
  const HeapGraphNode* closing = nullptr;
  const HeapGraphEdge* closingEdge = nullptr;
  while (!queue.empty() && closing == nullptr) {
    const HeapGraphNode* node = queue.front();
    queue.pop_front();
    for (int i = 0; i < node->GetChildrenCount(); i++) {
      const HeapGraphEdge* edge = node->GetChild(i);
      const HeapGraphNode* to = edge->GetToNode();
      if (!Strong(edge) || marked.count(to) || (node == ownWrapper && to == start)) {
        continue;
      }
      if (to == start) {
        closing = node;
        closingEdge = edge;
        break;
      }
      if (parent.count(to)) {
        continue;
      }
      parent[to] = {node, edge};
      queue.push_back(to);
    }
  }
  if (closing == nullptr) {
    return false;
  }
  std::vector<const HeapGraphNode*> chain;
  for (const HeapGraphNode* node = closing;; node = parent[node].first) {
    chain.push_back(node);
    if (node == start) {
      break;
    }
    if (chain.size() >= kMaxCycleLength) {
      return false;
    }
  }
  std::reverse(chain.begin(), chain.end());
  // Each hop names the edge leaving its node; the last one closes the cycle.
  hops->clear();
  for (size_t i = 0; i < chain.size(); i++) {
    const HeapGraphEdge* leaving = i + 1 < chain.size() ? parent[chain[i + 1]].second : closingEdge;
    hops->push_back({chain[i], EdgeName(isolate, leaving)});
  }
  return true;
}

std::string Describe(Isolate* isolate, const std::vector<Hop>& hops, size_t first,
                     bool forSignature) {
  static const std::regex volatileParts("( @[0-9]+)|(0x[0-9a-f]+)");
  std::string out;
  for (size_t i = 0; i < hops.size(); i++) {
    const Hop& hop = hops[(first + i) % hops.size()];
    std::string name = NodeName(isolate, hop.node);
    if (forSignature) {
      name = std::regex_replace(name, volatileParts, "");
    }
    out += (i == 0 ? "" : " ") + name + " -[" + hop.edge + "]->";
  }
  const Hop& head = hops[first % hops.size()];
  std::string name = NodeName(isolate, head.node);
  return out + " " + (forSignature ? std::regex_replace(name, volatileParts, "") : name);
}

// `inspect` lists class-name prefixes whose native objects the report details
// (retain accounting, root, reached), to explain a missing or unexpected cycle.
Local<Object> FindLeakCycles(Isolate* isolate, Local<Context> context, bool strict,
                             const std::vector<std::string>& inspect = {}) {
  ProbeRun run;
  run.strict = strict;
  auto t0 = std::chrono::steady_clock::now();
  HeapProfiler* profiler = isolate->GetHeapProfiler();
  activeRun_ = &run;
  const HeapSnapshot* snapshot = profiler->TakeHeapSnapshot();
  activeRun_ = nullptr;
  auto t1 = std::chrono::steady_clock::now();

  std::unordered_set<const HeapGraphNode*> modeled;
  for (SnapshotObjectId id : run.modeledHandles) {
    if (const HeapGraphNode* node = snapshot->GetNodeById(id)) {
      modeled.insert(node);
    }
  }
  const HeapGraphNode* globalHandles =
      Child(isolate, Child(isolate, snapshot->GetRoot(), "(GC roots)"), "(Global handles)");

  std::unordered_set<const HeapGraphNode*> marked{snapshot->GetRoot()};
  // How marking reached each node, kept only to explain inspected objects.
  std::unordered_map<const HeapGraphNode*, const HeapGraphEdge*> reachedBy;
  std::deque<const HeapGraphNode*> queue{snapshot->GetRoot()};
  while (!queue.empty()) {
    const HeapGraphNode* node = queue.front();
    queue.pop_front();
    for (int i = 0; i < node->GetChildrenCount(); i++) {
      const HeapGraphEdge* edge = node->GetChild(i);
      const HeapGraphNode* to = edge->GetToNode();
      if (!Strong(edge) || (node == globalHandles && modeled.count(to))) {
        continue;
      }
      if (marked.insert(to).second) {
        queue.push_back(to);
        if (!inspect.empty()) {
          reachedBy[to] = edge;
        }
      }
    }
  }

  std::unordered_map<const HeapGraphNode*, void*> nativeOfNode;
  for (auto& native : run.natives) {
    if (const HeapGraphNode* node =
            snapshot->GetNodeById(profiler->GetObjectId(static_cast<NativeObject>(native.first)))) {
      nativeOfNode[node] = native.first;
    }
  }

  std::vector<Cycle> cycles;
  std::unordered_set<const HeapGraphNode*> covered;
  uint32_t uncertain = 0;
  for (auto& native : run.natives) {
    if (!native.second.Immortal() && native.second.Unexplained() < 0) {
      uncertain++;
    }
  }
  for (auto& native : run.natives) {
    if (!native.second.seed) {
      continue;
    }
    const HeapGraphNode* node =
        snapshot->GetNodeById(profiler->GetObjectId(static_cast<NativeObject>(native.first)));
    std::vector<Hop> hops;
    if (node == nullptr || marked.count(node) || covered.count(node) ||
        !FindCycle(isolate, node, marked, &hops)) {
      // Unmarked off any cycle: garbage the next collection frees, or held by
      // a cycle reported through one of its members.
      continue;
    }
    Cycle cycle;
    cycle.hops = hops;
    std::unordered_set<void*> seen;
    for (const Hop& hop : hops) {
      covered.insert(hop.node);
      auto found = nativeOfNode.find(hop.node);
      if (found == nativeOfNode.end()) {
        // A wrapper on the cycle names its object even when the object itself
        // is off it.
        for (int i = 0; i < hop.node->GetChildrenCount(); i++) {
          const HeapGraphEdge* edge = hop.node->GetChild(i);
          auto wrapped = nativeOfNode.find(edge->GetToNode());
          if (wrapped != nativeOfNode.end() && EdgeName(isolate, edge) == "ns:retain" &&
              seen.insert(wrapped->second).second) {
            cycle.members.push_back(
                {class_getName(run.natives[wrapped->second].cls), wrapped->second});
          }
        }
        continue;
      }
      const NativeEntry& entry = run.natives[found->second];
      if (seen.insert(found->second).second) {
        cycle.members.push_back({class_getName(entry.cls), found->second});
      }
      if (entry.Unexplained() < 0 && !entry.Immortal()) {
        cycle.reasons.push_back(
            std::string(class_getName(entry.cls)) + " " + HexAddress(found->second) +
            ": retainCount " + std::to_string(entry.retainCount) + " is less than the " +
            std::to_string(entry.runtimeRetains + entry.incoming) +
            " retains its graph explains (" + std::to_string(entry.runtimeRetains) + " runtime, " +
            std::to_string(entry.incoming) + " incoming); some incoming edge does not own");
      }
    }
    // Canonical rotation, so the same cycle has one signature in every run.
    size_t first = 0;
    std::string best;
    for (size_t i = 0; i < hops.size(); i++) {
      std::string candidate = Describe(isolate, hops, i, true);
      if (i == 0 || candidate < best) {
        best = candidate;
        first = i;
      }
    }
    cycle.signature = best;
    cycle.path = Describe(isolate, hops, first, false);
    cycles.push_back(std::move(cycle));
  }
  auto t2 = std::chrono::steady_clock::now();

  auto set = [&](Local<Object> object, const char* key, Local<Value> value) {
    object->Set(context, tns::ToV8String(isolate, key), value).FromMaybe(false);
  };
  auto number = [&](double value) { return v8::Number::New(isolate, value).As<Value>(); };
  auto string = [&](const std::string& value) {
    return tns::ToV8String(isolate, value).As<Value>();
  };

  Local<v8::Array> cycleArray = v8::Array::New(isolate, static_cast<int>(cycles.size()));
  for (size_t i = 0; i < cycles.size(); i++) {
    const Cycle& cycle = cycles[i];
    Local<Object> entry = Object::New(isolate);
    set(entry, "signature", string(cycle.signature));
    set(entry, "path", string(cycle.path));
    Local<v8::Array> members = v8::Array::New(isolate, static_cast<int>(cycle.members.size()));
    for (size_t m = 0; m < cycle.members.size(); m++) {
      Local<Object> member = Object::New(isolate);
      set(member, "className", string(cycle.members[m].first));
      set(member, "address", string(HexAddress(cycle.members[m].second)));
      members->Set(context, static_cast<uint32_t>(m), member).FromMaybe(false);
    }
    set(entry, "members", members);
    set(entry, "uncertain", v8::Boolean::New(isolate, !cycle.reasons.empty()));
    Local<v8::Array> reasons = v8::Array::New(isolate, static_cast<int>(cycle.reasons.size()));
    for (size_t r = 0; r < cycle.reasons.size(); r++) {
      reasons->Set(context, static_cast<uint32_t>(r), string(cycle.reasons[r])).FromMaybe(false);
    }
    set(entry, "reasons", reasons);
    cycleArray->Set(context, static_cast<uint32_t>(i), entry).FromMaybe(false);
  }

  Local<Object> result = Object::New(isolate);
  set(result, "mode", string(WrapperLifetimeModeName(GetWrapperLifetimeMode())));
  set(result, "scope", string(WrapperLifetimeScopeName(GetWrapperLifetimeScope())));
  set(result, "strict", v8::Boolean::New(isolate, strict));
  set(result, "cycles", cycleArray);
  set(result, "nativeObjects", number(run.natives.size()));
  set(result, "uncertainNativeObjects", number(uncertain));
  set(result, "truncated", v8::Boolean::New(isolate, run.truncated));
  if (!inspect.empty()) {
    Local<v8::Array> inspected = v8::Array::New(isolate);
    uint32_t count = 0;
    for (auto& native : run.natives) {
      std::string name = class_getName(native.second.cls);
      bool wanted = std::any_of(inspect.begin(), inspect.end(), [&](const std::string& prefix) {
        return name.compare(0, prefix.size(), prefix) == 0;
      });
      if (!wanted) {
        continue;
      }
      const HeapGraphNode* node =
          snapshot->GetNodeById(profiler->GetObjectId(static_cast<NativeObject>(native.first)));
      Local<Object> entry = Object::New(isolate);
      set(entry, "className", string(name));
      set(entry, "address", string(HexAddress(native.first)));
      set(entry, "seed", v8::Boolean::New(isolate, native.second.seed));
      set(entry, "retainCount", number(native.second.retainCount));
      set(entry, "runtimeRetains", number(native.second.runtimeRetains));
      set(entry, "incoming", number(native.second.incoming));
      std::string out;
      for (const auto& edge : native.second.out) {
        out += (out.empty() ? "" : ", ") + edge.second + " -> " +
               class_getName(run.natives[edge.first].cls);
      }
      set(entry, "out", string(out));
      set(entry, "root", v8::Boolean::New(isolate, run.Root(native.second)));
      set(entry, "jsBlock",
          v8::Boolean::New(
              isolate,
              native.second.block && !Interop::JSBlockCallback(isolate, native.first).IsEmpty()));
      set(entry, "reached", v8::Boolean::New(isolate, node != nullptr && marked.count(node) > 0));
      std::string reachedFrom;
      for (const HeapGraphNode* at = node;
           at != nullptr && reachedBy.count(at) && reachedFrom.size() < 4096;) {
        const HeapGraphEdge* edge = reachedBy[at];
        reachedFrom = NodeName(isolate, edge->GetFromNode()) + " -[" + EdgeName(isolate, edge) +
                      "]-> " + (reachedFrom.empty() ? NodeName(isolate, at) : reachedFrom);
        at = edge->GetFromNode();
      }
      set(entry, "reachedFrom", string(reachedFrom));
      inspected->Set(context, count++, entry).FromMaybe(false);
    }
    set(result, "inspected", inspected);
  }
  set(result, "snapshotNodes", number(snapshot->GetNodesCount()));
  set(result, "snapshotMs", number(std::chrono::duration<double, std::milli>(t1 - t0).count()));
  set(result, "analysisMs", number(std::chrono::duration<double, std::milli>(t2 - t1).count()));
  const_cast<HeapSnapshot*>(snapshot)->Delete();
  return result;
}

// ---- Class counts --------------------------------------------------------

struct ClassCounts {
  uint32_t wrappers = 0;
  uint32_t strong = 0;
  uint32_t states = 0;
};

std::map<std::string, ClassCounts> CountByClass(Isolate* isolate) {
  std::map<std::string, ClassCounts> counts;
  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  if (cache == nullptr || !cache->IsValid()) {
    return counts;
  }
  HandleScope scope(isolate);
  ClassSet classes = LoadClasses();
  for (auto& entry : cache->Instances) {
    Instance instance;
    if (!ReadInstance(isolate, classes, entry.first, entry.second, &instance)) {
      continue;
    }
    ClassCounts& count = counts[class_getName(instance.cls)];
    count.wrappers++;
    if (RootedStrong(instance)) {
      count.strong++;
    }
  }
  WrapperLifetimeCanary::ForEachState(isolate, [&](id object, Local<Object>) {
    counts[class_getName(object_getClass(object))].states++;
  });
  return counts;
}

Local<Object> CountsObject(Isolate* isolate, Local<Context> context,
                           const std::map<std::string, ClassCounts>& counts) {
  Local<Object> result = Object::New(isolate);
  for (const auto& [name, entry] : counts) {
    Local<Object> value = Object::New(isolate);
    const std::pair<const char*, uint32_t> fields[] = {
        {"wrappers", entry.wrappers},
        {"strong", entry.strong},
        {"states", entry.states},
    };
    for (const auto& [key, count] : fields) {
      value->Set(context, tns::ToV8String(isolate, key), v8::Number::New(isolate, count))
          .FromMaybe(false);
    }
    result->Set(context, tns::ToV8String(isolate, name), value).FromMaybe(false);
  }
  return result;
}

// ---- JS functions --------------------------------------------------------

void GetWrapperClassCountsCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  info.GetReturnValue().Set(
      CountsObject(isolate, isolate->GetCurrentContext(), CountByClass(isolate)));
}

void FindLeakCyclesCallback(const FunctionCallbackInfo<Value>& info) {
  Isolate* isolate = info.GetIsolate();
  Local<Context> context = isolate->GetCurrentContext();
  bool strict = false;
  std::vector<std::string> inspect;
  if (info.Length() > 0 && !info[0]->IsUndefined()) {
    if (!info[0]->IsObject()) {
      isolate->ThrowException(Exception::TypeError(tns::ToV8String(
          isolate, "findLeakCycles expects ({ strict?: boolean, inspect?: string[] })")));
      return;
    }
    Local<Value> value;
    if (!info[0].As<Object>()->Get(context, tns::ToV8String(isolate, "strict")).ToLocal(&value)) {
      return;
    }
    strict = value->BooleanValue(isolate);
    if (!info[0].As<Object>()->Get(context, tns::ToV8String(isolate, "inspect")).ToLocal(&value)) {
      return;
    }
    if (value->IsArray()) {
      Local<v8::Array> names = value.As<v8::Array>();
      for (uint32_t i = 0; i < names->Length(); i++) {
        Local<Value> name;
        if (names->Get(context, i).ToLocal(&name) && name->IsString()) {
          inspect.push_back(Utf8(isolate, name));
        }
      }
    }
  }
  info.GetReturnValue().Set(FindLeakCycles(isolate, context, strict, inspect));
}

// ---- Triggers ------------------------------------------------------------

bool TriggersEnabled() {
  id config = Runtime::GetAppConfigValue("wrapperLifetime");
  if ([config isKindOfClass:[NSDictionary class]]) {
    id leakProbe = ((NSDictionary*)config)[@"leakProbe"];
    if ([leakProbe isKindOfClass:[NSNumber class]]) {
      return [leakProbe boolValue];
    }
  }
  return RuntimeConfig.IsDebug;
}

// Shared with the notification handlers, which run on other threads and may
// outlive the isolate.
struct TriggerGate {
  std::mutex mutex;
  bool open = true;
  Isolate* isolate = nullptr;
  std::weak_ptr<EventLoop> loop;

  void Post(std::function<void(Isolate*)> task) {
    std::lock_guard<std::mutex> lock(mutex);
    std::shared_ptr<EventLoop> eventLoop = loop.lock();
    if (!open || eventLoop == nullptr) {
      return;
    }
    Isolate* target = isolate;
    eventLoop->PostInternal([target, task]() { task(target); });
  }
};

std::string WriteReport(Isolate* isolate, Local<Context> context, const char* kind,
                        Local<Value> report) {
  Local<v8::String> json;
  if (!v8::JSON::Stringify(context, report).ToLocal(&json)) {
    return std::string();
  }
  NSString* name = [NSString
      stringWithFormat:@"ns-wrapper-lifetime-%s-%lld.json", kind,
                       static_cast<long long>([[NSDate date] timeIntervalSince1970] * 1000)];
  NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
  std::string utf8 = Utf8(isolate, json);
  NSData* data = [NSData dataWithBytes:utf8.data() length:utf8.size()];
  if (![data writeToFile:path atomically:YES]) {
    return std::string();
  }
  return [path UTF8String];
}

// Rooted mode frees a JS-only chain of native objects one link per major
// collection, and releases happen after the collection.
constexpr int kCountCollections = 3;

void ReportCounts(Isolate* isolate) {
  for (int i = 0; i < kCountCollections; i++) {
    isolate->LowMemoryNotification();
    WrapperLifetime::DrainReleases(isolate);
  }
  Local<Context> context = isolate->GetCurrentContext();
  Local<Object> report = Object::New(isolate);
  report
      ->Set(context, tns::ToV8String(isolate, "mode"),
            tns::ToV8String(isolate, WrapperLifetimeModeName(GetWrapperLifetimeMode())))
      .FromMaybe(false);
  report
      ->Set(context, tns::ToV8String(isolate, "scope"),
            tns::ToV8String(isolate, WrapperLifetimeScopeName(GetWrapperLifetimeScope())))
      .FromMaybe(false);
  report
      ->Set(context, tns::ToV8String(isolate, "classes"),
            CountsObject(isolate, context, CountByClass(isolate)))
      .FromMaybe(false);
  if (ObjectManager::LifetimeStats* stats = ObjectManager::GetLifetimeStats(isolate)) {
    Local<Object> counters = Object::New(isolate);
    const std::pair<const char*, uint64_t> fields[] = {
        {"resurrections", stats->resurrections},
        {"collected", stats->collected},
        {"releasedExplicitly", stats->releasedExplicitly},
        {"releasedAccesses", stats->releasedAccesses},
        {"queuedReleases", stats->queuedReleases},
        {"canaryStates", stats->canaryStates},
        {"canaryNativeDeaths", stats->canaryNativeDeaths},
    };
    for (const auto& [key, value] : fields) {
      counters
          ->Set(context, tns::ToV8String(isolate, key),
                v8::Number::New(isolate, static_cast<double>(value)))
          .FromMaybe(false);
    }
    report->Set(context, tns::ToV8String(isolate, "stats"), counters).FromMaybe(false);
  }
  std::string path = WriteReport(isolate, context, "counts", report);
  Log("%s class counts written to %s", kLogPrefix, path.c_str());
}

void ReportCycles(Isolate* isolate, bool strict) {
  Local<Context> context = isolate->GetCurrentContext();
  Local<Object> report = FindLeakCycles(isolate, context, strict);
  Local<Value> cycles;
  uint32_t count = 0;
  if (report->Get(context, tns::ToV8String(isolate, "cycles")).ToLocal(&cycles) &&
      cycles->IsArray()) {
    count = cycles.As<v8::Array>()->Length();
    for (uint32_t i = 0; i < count; i++) {
      Local<Value> cycle, path, uncertain;
      if (cycles.As<v8::Array>()->Get(context, i).ToLocal(&cycle) && cycle->IsObject() &&
          cycle.As<Object>()->Get(context, tns::ToV8String(isolate, "path")).ToLocal(&path) &&
          cycle.As<Object>()
              ->Get(context, tns::ToV8String(isolate, "uncertain"))
              .ToLocal(&uncertain)) {
        Log("%s %scycle %u: %s", kLogPrefix, uncertain->BooleanValue(isolate) ? "uncertain " : "",
            i + 1, Utf8(isolate, path).c_str());
      }
    }
  }
  std::string path = WriteReport(isolate, context, strict ? "cycles-strict" : "cycles", report);
  Log("%s %u leak cycle(s)%s, report written to %s", kLogPrefix, count, strict ? " (strict)" : "",
      path.c_str());
}

struct Triggers {
  std::shared_ptr<TriggerGate> gate = std::make_shared<TriggerGate>();
  id memoryWarningObserver = nil;
  std::vector<int> notifyTokens;
  std::map<std::string, ClassCounts> lastCounts;
  bool haveLastCounts = false;

  ~Triggers() {
    {
      std::lock_guard<std::mutex> lock(gate->mutex);
      gate->open = false;
    }
    for (int token : notifyTokens) {
      notify_cancel(token);
    }
    if (memoryWarningObserver != nil) {
      [[NSNotificationCenter defaultCenter] removeObserver:memoryWarningObserver];
      [memoryWarningObserver release];
    }
  }
};

void OnMemoryWarning(Isolate* isolate) {
  Triggers* triggers = Caches::StateFor<Triggers>(isolate);
  if (triggers == nullptr) {
    return;
  }
  std::map<std::string, ClassCounts> counts = CountByClass(isolate);
  std::vector<std::pair<int64_t, std::string>> growth;
  for (const auto& [name, entry] : counts) {
    int64_t total = static_cast<int64_t>(entry.wrappers) + entry.states;
    int64_t before = 0;
    auto previous = triggers->lastCounts.find(name);
    if (previous != triggers->lastCounts.end()) {
      before = static_cast<int64_t>(previous->second.wrappers) + previous->second.states;
    }
    growth.push_back({total - before, name});
  }
  std::sort(growth.begin(), growth.end(),
            [](const auto& a, const auto& b) { return a.first > b.first; });
  Log("%s memory warning; live wrappers and states per class, growth since %s:", kLogPrefix,
      triggers->haveLastCounts ? "the previous warning" : "startup");
  for (size_t i = 0; i < growth.size() && i < kMemoryWarningTopClasses && growth[i].first > 0;
       i++) {
    const ClassCounts& entry = counts[growth[i].second];
    Log("%s   %s +%lld (wrappers %u, strong %u, states %u)", kLogPrefix, growth[i].second.c_str(),
        static_cast<long long>(growth[i].first), entry.wrappers, entry.strong, entry.states);
  }
  Log("%s to look for JS/native cycles: require(\"ns:runtime\").findLeakCycles(), or "
      "`xcrun simctl spawn <device> notifyutil -p %s`",
      kLogPrefix, kCyclesNotification);
  triggers->lastCounts = std::move(counts);
  triggers->haveLastCounts = true;
}

void InstallTriggers(Isolate* isolate) {
  Triggers* triggers = Caches::StateFor<Triggers>(isolate);
  Runtime* runtime = Runtime::GetRuntime(isolate);
  if (triggers == nullptr || runtime == nullptr) {
    return;
  }
  triggers->gate->isolate = isolate;
  triggers->gate->loop = runtime->GetEventLoop();
  std::shared_ptr<TriggerGate> gate = triggers->gate;

  // By name: the runtime does not link UIKit.
  triggers->memoryWarningObserver = [[[NSNotificationCenter defaultCenter]
      addObserverForName:@"UIApplicationDidReceiveMemoryWarningNotification"
                  object:nil
                   queue:nil
              usingBlock:^(NSNotification*) {
                gate->Post([](Isolate* target) { OnMemoryWarning(target); });
              }] retain];

  const std::pair<const char*, std::function<void(Isolate*)>> handlers[] = {
      {kCountsNotification, [](Isolate* target) { ReportCounts(target); }},
      {kCyclesNotification, [](Isolate* target) { ReportCycles(target, false); }},
      {kStrictCyclesNotification, [](Isolate* target) { ReportCycles(target, true); }},
  };
  for (const auto& [name, handler] : handlers) {
    int token = 0;
    std::function<void(Isolate*)> task = handler;
    uint32_t status = notify_register_dispatch(
        name, &token, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(int) {
          gate->Post(task);
        });
    if (status == NOTIFY_STATUS_OK) {
      triggers->notifyTokens.push_back(token);
    }
  }
}

}  // namespace

void WrapperLifetimeLeaks::Init(Isolate* isolate) {
  isolate->GetHeapProfiler()->AddBuildEmbedderGraphCallback(BuildEmbedderGraph, nullptr);
  std::shared_ptr<Caches> cache = Caches::Get(isolate);
  if (cache != nullptr && !cache->isWorker && TriggersEnabled()) {
    InstallTriggers(isolate);
  }
}

bool WrapperLifetimeLeaks::RegisterFunctions(Local<Context> context, Local<Object> binding) {
  Isolate* isolate = v8::Isolate::GetCurrent();
  Local<v8::Function> counts;
  Local<v8::Function> cycles;
  return v8::Function::New(context, GetWrapperClassCountsCallback).ToLocal(&counts) &&
         v8::Function::New(context, FindLeakCyclesCallback).ToLocal(&cycles) &&
         binding->Set(context, tns::ToV8String(isolate, "getWrapperClassCounts"), counts)
             .FromMaybe(false) &&
         binding->Set(context, tns::ToV8String(isolate, "findLeakCycles"), cycles).FromMaybe(false);
}

}  // namespace tns
