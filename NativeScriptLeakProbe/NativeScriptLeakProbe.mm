// NativeScriptLeakProbe.framework: finds what the wrapper lifetime modes leak,
// JS <-> native cycles. Apps embed it in debug builds only; the runtime hands
// it its state through LeakProbeSPI.h.
//
// Heap snapshots carry both heaps: an embedder graph adds a node per native
// object the runtime wraps or keeps JS state for, and the runtime's own
// cross-heap edges (wrapper -> object retain, rooted-strong object -> wrapper,
// canary object -> state, adapter -> JS object). Any snapshot gets these,
// DevTools' included. JS block -> callback edges are added by findLeakCycles()
// only: the runtime keeps no list of its JS blocks, and never wraps one made
// for the same isolate, so only its native walk finds them.
//
// findLeakCycles() adds the native objects reachable from those through owning
// references (strong object ivars, collection and block storage) and runs a
// trial deletion: a native object is a root only while its retain count is not
// explained by the graph (the runtime's own retain plus incoming owning edges);
// the global handles that stand for native -> JS edges are not roots. What the
// marking does not reach and that lies on a cycle is reported.
//
// Blind spots: retains made by code without an owning ivar or storage pointer
// (manual retain/release bookkeeping, C++ members, associated objects) read as
// external owners, so their cycles are missed rather than misreported. Pointers
// that do not own (MRC assign ivars, weak storage outside the known weak
// containers) over-explain a retain count; such objects are "uncertain" and
// stay roots unless the probe runs strict.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <notify.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <v8-profiler.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdarg>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <regex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include "../NativeScript/runtime/LeakProbeSPI.h"

extern "C" const uintptr_t objc_debug_isa_class_mask;

using namespace v8;

namespace tns {

namespace {

using leakprobe::Host;
using leakprobe::Instance;
using leakprobe::Poster;

const Host* host_ = nullptr;

// The runtime's log, which splits what os_log would truncate.
__attribute__((format(printf, 1, 2))) void Log(const char* format, ...) {
  va_list args;
  va_start(args, format);
  va_list copy;
  va_copy(copy, args);
  int length = vsnprintf(nullptr, 0, format, copy);
  va_end(copy);
  std::string message(length > 0 ? static_cast<size_t>(length) : 0, '\0');
  vsnprintf(message.data(), message.size() + 1, format, args);
  va_end(args);
  host_->log(message.c_str());
}

Local<v8::String> ToV8String(Isolate* isolate, const std::string& value) {
  return v8::String::NewFromUtf8(isolate, value.data(), NewStringType::kNormal,
                                 static_cast<int>(value.size()))
      .ToLocalChecked();
}

template <typename Visit>
bool ForEachInstance(Isolate* isolate, Visit&& visit) {
  return host_->forEachInstance(isolate, &visit, [](void* context, const Instance& instance) {
    (*static_cast<std::remove_reference_t<Visit>*>(context))(instance);
  });
}

template <typename Visit>
void ForEachState(Isolate* isolate, Visit&& visit) {
  host_->forEachCanaryState(isolate, &visit, [](void* context, id object, Local<Object> state) {
    (*static_cast<std::remove_reference_t<Visit>*>(context))(object, state);
  });
}

constexpr const char* kCountsNotification = "org.nativescript.wrapperLifetime.counts";
constexpr const char* kCyclesNotification = "org.nativescript.wrapperLifetime.findLeakCycles";
constexpr const char* kStrictCyclesNotification =
    "org.nativescript.wrapperLifetime.findLeakCycles.strict";
// Inspects the class-name prefixes listed one per line in
// <tmp>/ns-wrapper-lifetime-inspect.txt.
constexpr const char* kInspectCyclesNotification =
    "org.nativescript.wrapperLifetime.findLeakCycles.inspect";
constexpr const char* kLogPrefix = "NativeScript wrapper lifetime:";

constexpr size_t kMaxNativeObjects = 200000;
constexpr int kMaxNativeDepth = 8;
constexpr size_t kMaxStorageBytes = 64 * 1024;
constexpr int kMaxStorageDepth = 2;
constexpr size_t kMaxCycleLength = 64;
constexpr size_t kMemoryWarningTopClasses = 10;
constexpr uint32_t kMaxChangedListed = 50;

// ---- Native object graph -------------------------------------------------

using ClassSet = std::unordered_set<uintptr_t>;

// An owning reference found in native memory. `cls` is read together with the
// pointer: other threads keep running while the probe walks, so an object can
// be freed after it was found, and its memory must not be read for its class
// again.
struct NativeEdge {
  void* to;
  Class cls;
  std::string label;
};

struct NativeEntry {
  Class cls = nil;
  size_t size = 0;
  bool block = false;
  // Wrapped by this isolate or holding JS state in it.
  bool seed = false;
  // No longer the object that was found at this address: freed, or freed and
  // reused, while the probe ran.
  bool changed = false;
  // No -retainCount the probe can call without messaging: owned from outside.
  bool countUnknown = false;
  int depth = 0;
  int64_t retainCount = 0;
  int64_t runtimeRetains = 0;
  int64_t incoming = 0;
  // The first reference that led to a non-seed object.
  void* foundFrom = nullptr;
  std::string foundVia;
  std::vector<NativeEdge> out;

  int64_t Unexplained() const { return retainCount - runtimeRetains - incoming; }
  bool Immortal() const { return retainCount >= static_cast<int64_t>(NSUIntegerMax >> 1); }
};

// Storage slots a scan does not follow, by their labels.
using SlotSkips = std::unordered_set<std::string>;

// Layouts read instead of scanned, measured once on objects the probe builds
// before its first snapshot. A measurement that does not come out as expected
// leaves the plain storage scan in place.
struct Calibration {
  // CALayer keeps its delegate and its superlayer in its C++ layer, neither
  // retained: the slots of the delegate and of the link up to the
  // superlayer's C++ layer, which also reaches the superlayer's delegate.
  // A layer with a superlayer keeps its delegate slot: when the delegate is
  // its view, that edge is the only one standing for the superview's retain
  // of the view, which UIKit keeps outside any ivar or storage.
  Class layerClass = nil;
  SlotSkips layerSkips;
  SlotSkips attachedLayerSkips;
  std::vector<std::vector<size_t>> superlayerPaths;
  // __NSArrayM is a ring buffer whose storage keeps pointers to removed
  // elements: only its live range is read. Offset of its `storage` ivar.
  Class mutableArrayClass = nil;
  size_t ringStorage = 0;
};

// One findLeakCycles call. The snapshot's embedder graph callback runs on the
// calling thread, inside TakeHeapSnapshot.
struct ProbeRun {
  bool strict = false;
  const Calibration* calibration = nullptr;
  ClassSet classes;
  std::unordered_map<Class, std::vector<std::pair<size_t, std::string>>> slots;
  std::unordered_map<Class, bool> typedClasses;
  std::unordered_map<Class, IMP> retainCountImps;
  std::unordered_map<void*, NativeEntry> natives;
  // Global handles that stand for native -> JS edges.
  std::unordered_set<SnapshotObjectId> modeledHandles;
  bool truncated = false;
  // Where the walk stopped short; cycles past these limits are not seen.
  uint32_t depthCutOffs = 0;
  uint32_t storageCutOffs = 0;

  bool Root(const NativeEntry& entry) const {
    // A gone object keeps nothing alive.
    if (entry.changed) {
      return false;
    }
    if (entry.countUnknown || entry.Immortal() || entry.Unexplained() > 0) {
      return true;
    }
    return !strict && entry.Unexplained() < 0;
  }
};

thread_local ProbeRun* activeRun_ = nullptr;

// A tagged pointer carries its value in the pointer itself: no heap block.
// Only x86_64 macOS and Mac Catalyst tag the low bit.
bool IsTaggedPointer(uintptr_t p) {
#if defined(__x86_64__) && (TARGET_OS_OSX || TARGET_OS_MACCATALYST)
  return (p & 1) != 0;
#else
  return (p >> 63) != 0;
#endif
}

size_t HeapBlockSize(uintptr_t p) {
  if (p == 0 || IsTaggedPointer(p) || (p & (sizeof(void*) - 1)) != 0) {
    return 0;
  }
  return malloc_size(reinterpret_cast<void*>(p));
}

// Copies `length` bytes (whole words) at `p`, inside a heap block of
// `blockSize` bytes that another thread may free meanwhile. A block of a page
// or more is read with vm_read_overwrite, which fails instead of faulting once
// its pages are unmapped; smaller blocks sit in malloc regions that stay
// mapped. Uninstrumented: reading a stale block is expected here.
__attribute__((no_sanitize("address"))) bool ReadMemory(uintptr_t p, size_t length,
                                                        size_t blockSize, void* out) {
  if (blockSize >= vm_page_size) {
    vm_size_t copied = 0;
    return vm_read_overwrite(mach_task_self(), p, length, reinterpret_cast<vm_address_t>(out),
                             &copied) == KERN_SUCCESS &&
           copied == length;
  }
  // Volatile, so the loop does not become a memcpy, which ASan intercepts.
  const volatile uintptr_t* from = reinterpret_cast<const volatile uintptr_t*>(p);
  uintptr_t* to = static_cast<uintptr_t*>(out);
  for (size_t i = 0; i < length / sizeof(uintptr_t); i++) {
    to[i] = from[i];
  }
  return true;
}

bool ReadWord(uintptr_t p, size_t blockSize, uintptr_t* out) {
  return ReadMemory(p, sizeof(uintptr_t), blockSize, out);
}

// Realized classes only, when the runtime can list them: objc_copyClassList
// realizes every class in the process. A class is realized by the time it has
// an instance.
ClassSet LoadClasses() {
  using CopyClassList = Class* (*)(unsigned int*);
  static CopyClassList copyClassList = [] {
    void* realized = dlsym(RTLD_DEFAULT, "objc_copyRealizedClassList");
    return realized != nullptr ? reinterpret_cast<CopyClassList>(realized) : &objc_copyClassList;
  }();
  ClassSet classes;
  unsigned int count = 0;
  Class* list = copyClassList(&count);
  for (unsigned int i = 0; i < count; i++) {
    classes.insert(reinterpret_cast<uintptr_t>(list[i]));
  }
  free(list);
  return classes;
}

// The class of the object starting at `p`, or nil when the block does not
// start with the isa of a known class.
Class ObjectClass(const ClassSet& classes, uintptr_t p, size_t size) {
  uintptr_t isa = 0;
  if (size < sizeof(void*) || !ReadWord(p, size, &isa)) {
    return nil;
  }
  // The simulator's isa keeps more class bits than objc_debug_isa_class_mask
  // admits; classes allocated at runtime (JS-extended ones) live above it.
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
void ScanStorage(const ClassSet& classes, uintptr_t p, size_t size, int depth,
                 const std::string& prefix, std::vector<NativeEdge>* out,
                 const SlotSkips* skips = nullptr, uint32_t* cutOffs = nullptr) {
  if (size > kMaxStorageBytes && cutOffs != nullptr) {
    (*cutOffs)++;
  }
  size_t limit = std::min(size, kMaxStorageBytes) & ~(sizeof(void*) - 1);
  std::vector<uintptr_t> words(limit / sizeof(void*));
  if (!ReadMemory(p, limit, size, words.data())) {
    return;
  }
  for (size_t i = 0; i < words.size(); i++) {
    size_t offset = i * sizeof(void*);
    uintptr_t value = words[i];
    if (value == p) {
      continue;
    }
    size_t valueSize = HeapBlockSize(value);
    if (valueSize == 0) {
      continue;
    }
    std::string label = prefix + "+" + std::to_string(offset);
    if (skips != nullptr && skips->count(label)) {
      continue;
    }
    if (Class cls = ObjectClass(classes, value, valueSize)) {
      out->push_back({reinterpret_cast<void*>(value), cls, label});
    } else if (depth < kMaxStorageDepth) {
      ScanStorage(classes, value, valueSize, depth + 1, label, out, skips, cutOffs);
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

uint32_t BlockFlags(uintptr_t block, size_t size) {
  uintptr_t word = 0;
  ReadWord(block + offsetof(BlockHeader, flags), size, &word);
  return static_cast<uint32_t>(word);
}

// Copies memory that is not a heap block the probe sized, failing instead of
// faulting when it is not mapped.
bool ReadMapped(uintptr_t p, size_t length, void* out) {
  vm_size_t copied = 0;
  return vm_read_overwrite(mach_task_self(), p, length, reinterpret_cast<vm_address_t>(out),
                           &copied) == KERN_SUCCESS &&
         copied == length;
}

// Block_private.h.
constexpr uint32_t kBlockHasCopyDispose = 1u << 25;
constexpr uint32_t kBlockSmallDescriptor = 1u << 22;
constexpr uint32_t kBlockHasSignature = 1u << 30;
constexpr uint32_t kBlockHasExtendedLayout = 1u << 31;
constexpr uint32_t kByrefLayoutMask = 0xfu << 28;
constexpr uint32_t kByrefLayoutNonObject = 2u << 28;
constexpr uint32_t kByrefLayoutWeak = 4u << 28;
constexpr uint32_t kByrefLayoutUnretained = 5u << 28;

struct Capture {
  size_t offset;
  bool byref;
};

// The captures a heap block retains: strong objects and __block variables,
// read from its extended layout, which also lists __weak and
// __unsafe_unretained ones. A block without copy/dispose helpers retains
// nothing. False when the layout cannot be read; every word is then scanned.
bool OwnedCaptures(uintptr_t block, size_t size, std::vector<Capture>* captures) {
  uint32_t flags = BlockFlags(block, size);
  if ((flags & kBlockHasCopyDispose) == 0) {
    return true;
  }
  if ((flags & kBlockSmallDescriptor) != 0 || (flags & kBlockHasSignature) == 0 ||
      (flags & kBlockHasExtendedLayout) == 0) {
    return false;
  }
  uintptr_t descriptor = 0;
  // A signed or otherwise unusual descriptor pointer is not decoded.
  if (!ReadWord(block + offsetof(BlockHeader, descriptor), size, &descriptor) || descriptor == 0 ||
      (descriptor >> 47) != 0) {
    return false;
  }
  // reserved, size, copy, dispose, signature, layout.
  uintptr_t fields[6];
  if (!ReadMapped(descriptor, sizeof fields, fields)) {
    return false;
  }
  uintptr_t layout = fields[5];
  size_t offset = sizeof(BlockHeader);
  auto add = [&](size_t count, bool byref) {
    for (size_t i = 0; i < count; i++, offset += sizeof(void*)) {
      captures->push_back({offset, byref});
    }
  };
  if (layout == 0) {
    return false;
  }
  if (layout < 0x1000) {
    // 0xXYZ: X strong words, then Y byref words, then Z weak words.
    add((layout >> 8) & 0xf, false);
    add((layout >> 4) & 0xf, true);
  } else {
    // Bytes 0xPN, operator P on N + 1 words, up to a 0x00.
    uint8_t ops[64];
    uintptr_t pageEnd = (layout | (vm_page_size - 1)) + 1;
    size_t length = std::min<size_t>(sizeof ops, pageEnd - layout);
    if (!ReadMapped(layout, length, ops)) {
      return false;
    }
    size_t i = 0;
    for (; i < length && ops[i] != 0; i++) {
      size_t count = (ops[i] & 0xf) + 1;
      switch (ops[i] >> 4) {
        case 2:  // non-object words
        case 5:  // weak
        case 6:  // unretained
          offset += count * sizeof(void*);
          break;
        case 3:
          add(count, false);
          break;
        case 4:
          add(count, true);
          break;
        default:
          return false;
      }
    }
    if (i == length) {
      return false;
    }
  }
  return offset <= size;
}

// A __block variable that its own flags say is not retained.
bool UnretainedByref(uintptr_t byref, size_t size) {
  // isa, forwarding, flags.
  uintptr_t word = 0;
  if (!ReadWord(byref + 2 * sizeof(void*), size, &word)) {
    return true;
  }
  uint32_t layout = static_cast<uint32_t>(word) & kByrefLayoutMask;
  return layout == kByrefLayoutNonObject || layout == kByrefLayoutWeak ||
         layout == kByrefLayoutUnretained;
}

bool IsKindOf(Class cls, Class base) {
  for (Class c = cls; c != nil && base != nil; c = class_getSuperclass(c)) {
    if (c == base) {
      return true;
    }
  }
  return false;
}

// __NSArrayM's `storage` ivar, as calibrated.
struct Ring {
  uintptr_t list;
  uint32_t offset;
  uint32_t size;
  uint32_t used;
};

constexpr const char* kRingStorageType =
    "{?=\"list\"^@\"offset\"I\"size\"I\"state\"(?=\"mutations\"Q\"\"{?=\"muts\"I\"used\"I})}";

// The live elements of a __NSArrayM, in order, at most `limit` of them; false
// when its storage does not read as a ring.
bool RingElements(const Calibration& calibration, uintptr_t array, size_t size, size_t limit,
                  std::vector<uintptr_t>* elements, bool* cut) {
  uintptr_t words[3];
  if (calibration.ringStorage + sizeof words > size ||
      !ReadMemory(array + calibration.ringStorage, sizeof words, size, words)) {
    return false;
  }
  Ring ring{words[0], static_cast<uint32_t>(words[1]), static_cast<uint32_t>(words[1] >> 32),
            static_cast<uint32_t>(words[2] >> 32)};
  if (ring.used == 0) {
    return true;
  }
  size_t listSize = HeapBlockSize(ring.list);
  if (ring.offset >= ring.size || ring.used > ring.size ||
      listSize < static_cast<size_t>(ring.size) * sizeof(void*)) {
    return false;
  }
  std::vector<uintptr_t> list(std::min<size_t>(ring.size, limit));
  if (!ReadMemory(ring.list, list.size() * sizeof(void*), listSize, list.data())) {
    return false;
  }
  for (uint32_t i = 0; i < ring.used; i++) {
    size_t slot = (static_cast<size_t>(ring.offset) + i) % ring.size;
    if (slot >= list.size()) {
      *cut = true;
      continue;
    }
    elements->push_back(list[slot]);
  }
  return true;
}

template <typename R = id, typename... Args>
R Send(id target, const char* selector, Args... args) {
  return reinterpret_cast<R (*)(id, SEL, Args...)>(objc_msgSend)(target, sel_registerName(selector),
                                                                 args...);
}

std::vector<size_t> LabelPath(const std::string& label) {
  std::vector<size_t> path;
  for (size_t at = label.find('+'); at != std::string::npos; at = label.find('+', at + 1)) {
    path.push_back(std::stoul(label.substr(at + 1)));
  }
  return path;
}

std::string PathLabel(const std::vector<size_t>& path, size_t length) {
  std::string label;
  for (size_t i = 0; i < length; i++) {
    label += "+" + std::to_string(path[i]);
  }
  return label;
}

// What the first `length` steps of `path` lead to from `object`, scanned as
// storage the way Expand does; 0 when a step leaves the heap.
uintptr_t Resolve(uintptr_t object, const std::vector<size_t>& path, size_t length) {
  size_t size = HeapBlockSize(object);
  if (size <= sizeof(void*)) {
    return 0;
  }
  uintptr_t block = object + sizeof(void*);
  size -= sizeof(void*);
  for (size_t i = 0; i < length; i++) {
    uintptr_t value = 0;
    if (path[i] + sizeof(void*) > size || !ReadWord(block + path[i], size, &value)) {
      return 0;
    }
    if (i + 1 == length) {
      return value;
    }
    block = value;
    size = HeapBlockSize(value);
    if (size == 0) {
      return 0;
    }
  }
  return block;
}

std::vector<NativeEdge> ScanObject(const ClassSet& classes, id object, const SlotSkips* skips) {
  std::vector<NativeEdge> edges;
  uintptr_t p = reinterpret_cast<uintptr_t>(object);
  size_t size = HeapBlockSize(p);
  if (size > sizeof(void*)) {
    ScanStorage(classes, p + sizeof(void*), size - sizeof(void*), 0, "", &edges, skips);
  }
  return edges;
}

bool Reaches(const std::vector<NativeEdge>& edges, id target) {
  return std::any_of(edges.begin(), edges.end(),
                     [&](const NativeEdge& edge) { return edge.to == (__bridge void*)target; });
}

// Whether `edges`, or the storage of another object they lead to, hold
// `target`: sublayers sit in an array the layer owns.
bool Holds(const ClassSet& classes, id owner, const std::vector<NativeEdge>& edges, id target) {
  return Reaches(edges, target) ||
         std::any_of(edges.begin(), edges.end(), [&](const NativeEdge& edge) {
           return edge.to != (__bridge void*)owner &&
                  Reaches(ScanObject(classes, (__bridge id)edge.to, nullptr), target);
         });
}

void CalibrateLayer(Calibration* calibration) {
  Class layerClass = objc_getClass("CALayer");
  Class transaction = objc_getClass("CATransaction");
  if (layerClass == nil || transaction == nil) {
    return;
  }
  Send<void>(transaction, "begin");
  Send<void>(transaction, "setDisableActions:", YES);
  auto newLayer = [&]() { return Send(Send(layerClass, "alloc"), "init"); };
  id parent = newLayer();
  id layer = newLayer();
  id sublayer = newLayer();
  id mask = newLayer();
  id parentDelegate = [[NSObject alloc] init];
  id delegate = [[NSObject alloc] init];
  Send<void>(parent, "setDelegate:", parentDelegate);
  Send<void>(layer, "setDelegate:", delegate);
  Send<void>(parent, "addSublayer:", layer);
  Send<void>(layer, "addSublayer:", sublayer);
  Send<void>(layer, "setMask:", mask);

  ClassSet classes = LoadClasses();
  uintptr_t layerAddress = reinterpret_cast<uintptr_t>(layer);
  uintptr_t parentAddress = reinterpret_cast<uintptr_t>(parent);
  SlotSkips skips;
  SlotSkips links;
  bool sawDelegate = false;
  bool sawParent = false;
  for (const NativeEdge& edge : ScanObject(classes, layer, nullptr)) {
    if (edge.to == (__bridge void*)delegate) {
      sawDelegate = true;
      skips.insert(edge.label);
    } else if (edge.to == (__bridge void*)parent) {
      sawParent = true;
      // The first step that leaves this layer's storage for the parent's.
      std::vector<size_t> path = LabelPath(edge.label);
      std::string skip = edge.label;
      for (size_t k = 1; k < path.size() && skip == edge.label; k++) {
        uintptr_t block = Resolve(layerAddress, path, k);
        for (size_t j = 1; j <= k; j++) {
          if (block != 0 && block == Resolve(parentAddress, path, j)) {
            skip = PathLabel(path, k);
            break;
          }
        }
      }
      skips.insert(skip);
      links.insert(skip);
    }
  }
  bool valid = sawDelegate && sawParent;
  if (valid) {
    std::vector<NativeEdge> fromLayer = ScanObject(classes, layer, &skips);
    std::vector<NativeEdge> fromParent = ScanObject(classes, parent, &skips);
    std::vector<NativeEdge> fromMask = ScanObject(classes, mask, &skips);
    valid = !Reaches(fromLayer, delegate) && !Reaches(fromLayer, parent) &&
            !Reaches(fromLayer, parentDelegate) && Reaches(fromLayer, mask) &&
            Holds(classes, layer, fromLayer, sublayer) &&
            Holds(classes, parent, fromParent, layer) && !Reaches(fromParent, parentDelegate) &&
            !Reaches(fromMask, layer);
  }
  if (valid) {
    calibration->layerClass = layerClass;
    calibration->layerSkips = std::move(skips);
    calibration->attachedLayerSkips = links;
    for (const std::string& link : links) {
      calibration->superlayerPaths.push_back(LabelPath(link));
    }
  }

  Send<void>(layer, "setMask:", nil);
  Send<void>(sublayer, "removeFromSuperlayer");
  Send<void>(layer, "removeFromSuperlayer");
  Send<void>(layer, "setDelegate:", nil);
  Send<void>(parent, "setDelegate:", nil);
  for (id object : {parent, layer, sublayer, mask, parentDelegate, delegate}) {
    [object release];
  }
  Send<void>(transaction, "commit");
}

void CalibrateRing(Calibration* calibration) {
  Class arrayClass = objc_getClass("__NSArrayM");
  Ivar storage = arrayClass != nil ? class_getInstanceVariable(arrayClass, "storage") : nullptr;
  const char* type = storage != nullptr ? ivar_getTypeEncoding(storage) : nullptr;
  if (type == nullptr || strcmp(type, kRingStorageType) != 0) {
    return;
  }
  Calibration probe;
  probe.ringStorage = static_cast<size_t>(ivar_getOffset(storage));
  std::vector<id> items;
  for (int i = 0; i < 9; i++) {
    items.push_back([[NSObject alloc] init]);
  }
  // Removed at both ends, and wrapped around by an insertion at the front.
  NSMutableArray* trimmed = [[NSMutableArray alloc] init];
  NSMutableArray* wrapped = [[NSMutableArray alloc] init];
  for (int i = 0; i < 8; i++) {
    [trimmed addObject:items[i]];
  }
  [trimmed removeObjectAtIndex:0];
  [trimmed removeObjectAtIndex:0];
  [trimmed removeLastObject];
  for (int i = 0; i < 4; i++) {
    [wrapped addObject:items[i]];
  }
  [wrapped insertObject:items[8] atIndex:0];
  auto matches = [&](NSMutableArray* array, std::vector<id> expected) {
    std::vector<uintptr_t> elements;
    bool cut = false;
    uintptr_t p = reinterpret_cast<uintptr_t>(array);
    if (object_getClass(array) != arrayClass ||
        !RingElements(probe, p, HeapBlockSize(p), SIZE_MAX, &elements, &cut) ||
        elements.size() != expected.size()) {
      return false;
    }
    for (size_t i = 0; i < expected.size(); i++) {
      if (elements[i] != reinterpret_cast<uintptr_t>(expected[i])) {
        return false;
      }
    }
    return true;
  };
  if (matches(trimmed, {items[2], items[3], items[4], items[5], items[6]}) &&
      matches(wrapped, {items[8], items[0], items[1], items[2], items[3]})) {
    calibration->mutableArrayClass = arrayClass;
    calibration->ringStorage = probe.ringStorage;
  }
  [trimmed release];
  [wrapped release];
  for (id item : items) {
    [item release];
  }
}

// Messages Foundation and QuartzCore classes: must run outside the snapshot.
const Calibration* GetCalibration() {
  static Calibration* calibration = [] {
    Calibration* result = new Calibration();
    @autoreleasepool {
      CalibrateLayer(result);
      CalibrateRing(result);
    }
    return result;
  }();
  return calibration;
}

// Whether `object` still holds the object that was found there. A freed and
// reused address that holds an object of the same class again passes.
bool StillThere(ProbeRun* run, void* object, const NativeEntry& entry) {
  uintptr_t p = reinterpret_cast<uintptr_t>(object);
  return ObjectClass(run->classes, p, HeapBlockSize(p)) == entry.cls;
}

// The native class's -retainCount, read from the method lists:
// class_getInstanceMethod and class_getMethodImplementation run the method
// resolver, and with it +initialize, when a class lacks the method. Null for
// a class without one (an NSZombie) or whose one forwards.
IMP RetainCountImp(Class cls) {
  // NSTimer.alloc()'s placeholder: its -retainCount can hang.
  static Class timerPlaceholder = objc_getClass("NSCFTimer");
  if (cls == timerPlaceholder) {
    return nullptr;
  }
  SEL selector = @selector(retainCount);
  for (Class c = host_->nativeClass(cls); c != nil; c = class_getSuperclass(c)) {
    unsigned int count = 0;
    Method* methods = class_copyMethodList(c, &count);
    IMP imp = nullptr;
    for (unsigned int i = 0; i < count && imp == nullptr; i++) {
      if (method_getName(methods[i]) == selector) {
        imp = method_getImplementation(methods[i]);
      }
    }
    free(methods);
    if (imp != nullptr) {
      return imp == reinterpret_cast<IMP>(_objc_msgForward) ? nullptr : imp;
    }
  }
  return nullptr;
}

void ReadRetainCount(ProbeRun* run, void* object, NativeEntry* entry) {
  if (entry->block) {
    entry->retainCount =
        (BlockFlags(reinterpret_cast<uintptr_t>(object), entry->size) & 0xfffe) >> 1;
    return;
  }
  auto found = run->retainCountImps.find(entry->cls);
  if (found == run->retainCountImps.end()) {
    found = run->retainCountImps.emplace(entry->cls, RetainCountImp(entry->cls)).first;
  }
  if (found->second == nullptr) {
    entry->countUnknown = true;
    return;
  }
  entry->retainCount = static_cast<int64_t>(reinterpret_cast<NSUInteger (*)(id, SEL)>(
      found->second)((__bridge id)object, @selector(retainCount)));
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
    if (size <= sizeof(BlockHeader) || host_->isJSBlock(object)) {
      return;
    }
    std::vector<Capture> captures;
    if (!OwnedCaptures(p, size, &captures)) {
      ScanStorage(run->classes, p + sizeof(BlockHeader), size - sizeof(BlockHeader), 1, "capture",
                  &entry->out, nullptr, &run->storageCutOffs);
      return;
    }
    for (const Capture& capture : captures) {
      uintptr_t value = 0;
      if (!ReadWord(p + capture.offset, size, &value)) {
        continue;
      }
      size_t valueSize = HeapBlockSize(value);
      std::string label = "capture+" + std::to_string(capture.offset - sizeof(BlockHeader));
      if (valueSize == 0) {
        continue;
      }
      if (Class cls = ObjectClass(run->classes, value, valueSize)) {
        entry->out.push_back({reinterpret_cast<void*>(value), cls, label});
      } else if (capture.byref && !UnretainedByref(value, valueSize)) {
        ScanStorage(run->classes, value, valueSize, kMaxStorageDepth, label, &entry->out, nullptr,
                    &run->storageCutOffs);
      }
    }
    return;
  }
  const Calibration& calibration = *run->calibration;
  if (entry->cls == calibration.mutableArrayClass && calibration.mutableArrayClass != nil) {
    std::vector<uintptr_t> elements;
    bool cut = false;
    if (RingElements(calibration, p, size, kMaxStorageBytes / sizeof(void*), &elements, &cut)) {
      run->storageCutOffs += cut ? 1 : 0;
      for (size_t i = 0; i < elements.size(); i++) {
        size_t valueSize = HeapBlockSize(elements[i]);
        if (Class cls = valueSize != 0 ? ObjectClass(run->classes, elements[i], valueSize) : nil) {
          entry->out.push_back(
              {reinterpret_cast<void*>(elements[i]), cls, "[" + std::to_string(i) + "]"});
        }
      }
      return;
    }
  }
  bool typed = false;
  const auto& slots = OwningSlots(run, entry->cls, &typed);
  if (!typed) {
    const SlotSkips* skips = nullptr;
    if (!calibration.layerSkips.empty() && IsKindOf(entry->cls, calibration.layerClass)) {
      bool attached = std::any_of(
          calibration.superlayerPaths.begin(), calibration.superlayerPaths.end(),
          [&](const std::vector<size_t>& path) { return Resolve(p, path, path.size()) != 0; });
      skips = attached ? &calibration.attachedLayerSkips : &calibration.layerSkips;
    }
    ScanStorage(run->classes, p + sizeof(void*), size - sizeof(void*), 0, "", &entry->out, skips,
                &run->storageCutOffs);
    return;
  }
  for (const auto& slot : slots) {
    if (slot.first + sizeof(void*) > size) {
      continue;
    }
    uintptr_t value = 0;
    if (!ReadWord(p + slot.first, size, &value)) {
      continue;
    }
    size_t valueSize = HeapBlockSize(value);
    if (Class cls = valueSize != 0 ? ObjectClass(run->classes, value, valueSize) : nil) {
      entry->out.push_back({reinterpret_cast<void*>(value), cls, slot.second});
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

// A wrapper map entry the graph can rely on.
struct Wrapped {
  Class cls = nil;
  Local<Value> js;
  // A native collection or data adapter backed by a JS object: the adapter
  // holds the JS object strongly, and the JS object does not retain it.
  bool adapter = false;
  bool rootedStrong = false;
  // The map's handle is the strong one the runtime keeps while native code
  // also retains the object: a wrapper no lifetime mode adopted.
  bool reconciledStrong = false;
};

// False for entries whose key must not be dereferenced as the wrapped object:
// a dead wrapper, a key that is not a live heap object, or an address now
// holding another object than the one its wrapper was made for.
bool ReadInstance(const ClassSet& classes, const Instance& instance, Wrapped* out) {
  uintptr_t p = reinterpret_cast<uintptr_t>(instance.object);
  if (instance.wrapper.IsEmpty() || IsTaggedPointer(p)) {
    return false;
  }
  Class cls = ObjectClass(classes, p, HeapBlockSize(p));
  if (cls == nil) {
    return false;
  }
  out->cls = cls;
  out->js = instance.wrapper;
  if (IsAdapter(cls)) {
    out->adapter = true;
    return true;
  }
  if (!instance.objc) {
    return false;
  }
  Class made = instance.wrappedClass;
  // KVO swaps in a subclass of the original while the object is observed and
  // swaps it back afterwards, so either class can be the one it was wrapped as.
  if (instance.wrapped != instance.object ||
      (cls != made && class_getSuperclass(cls) != made && class_getSuperclass(made) != cls)) {
    return false;
  }
  out->rootedStrong = instance.rootedStrong;
  out->reconciledStrong = instance.reconciledStrong;
  return true;
}

// Reads native memory that other threads may be mutating; acceptable for an
// on-demand diagnostic, which is why it never runs implicitly.
// False when the isolate is tearing down.
bool BuildNativeGraph(Isolate* isolate, ProbeRun* run) {
  // Classes are only inspected through the runtime functions, never messaged:
  // a first message runs +initialize, arbitrary code inside the snapshot.
  static Class blockClass = objc_getClass("NSBlock");

  std::deque<void*> queue;
  auto add = [&](void* object, Class cls, int depth) -> NativeEntry* {
    auto found = run->natives.find(object);
    if (found != run->natives.end()) {
      return &found->second;
    }
    if (run->natives.size() >= kMaxNativeObjects) {
      run->truncated = true;
      return nullptr;
    }
    NativeEntry entry;
    entry.cls = cls;
    entry.size = HeapBlockSize(reinterpret_cast<uintptr_t>(object));
    for (Class c = cls; c != nil && !entry.block; c = class_getSuperclass(c)) {
      entry.block = c == blockClass;
    }
    entry.depth = depth;
    queue.push_back(object);
    return &run->natives.emplace(object, std::move(entry)).first->second;
  };

  bool valid = ForEachInstance(isolate, [&](const Instance& instance) {
    Wrapped wrapped;
    if (!ReadInstance(run->classes, instance, &wrapped)) {
      return;
    }
    if (NativeEntry* native = add(instance.object, wrapped.cls, 0)) {
      native->seed = true;
      native->runtimeRetains = wrapped.adapter ? 0 : 1;
    }
  });
  if (!valid) {
    return false;
  }
  // The registry lock keeps a stateful object from being freed meanwhile.
  ForEachState(isolate, [&](id object, Local<Object>) {
    if (NativeEntry* entry = add((__bridge void*)object, object_getClass(object), 0)) {
      entry->seed = true;
    }
  });

  while (!queue.empty()) {
    void* object = queue.front();
    queue.pop_front();
    NativeEntry& entry = run->natives[object];
    if (entry.depth >= kMaxNativeDepth) {
      run->depthCutOffs++;
      continue;
    }
    Expand(run, object, &entry);
    // A pointer to itself never owns the object.
    entry.out.erase(std::remove_if(entry.out.begin(), entry.out.end(),
                                   [&](const auto& edge) { return edge.to == object; }),
                    entry.out.end());
    int depth = entry.depth;
    std::vector<NativeEdge> out = entry.out;
    for (const auto& edge : out) {
      auto known = run->natives.find(edge.to);
      if (known != run->natives.end() && known->second.cls != edge.cls) {
        known->second.changed = true;
      }
      if (NativeEntry* target = add(edge.to, edge.cls, depth + 1)) {
        target->incoming++;
        if (!target->seed && target->foundFrom == nullptr) {
          target->foundFrom = object;
          target->foundVia = edge.label;
        }
      }
    }
  }
  for (auto& native : run->natives) {
    if (!native.second.changed && StillThere(run, native.first, native.second)) {
      ReadRetainCount(run, native.first, &native.second);
    } else {
      native.second.changed = true;
    }
  }
  return true;
}

class NativeObjectNode : public EmbedderGraph::Node {
 public:
  NativeObjectNode(void* object, Class cls, size_t size, bool root)
      : object_(object),
        size_(size),
        root_(root),
        name_(std::string("ObjC ") + class_getName(cls)) {}
  const char* Name() override { return name_.c_str(); }
  size_t SizeInBytes() override { return size_; }
  const void* GetAddress() override { return object_; }
  bool IsRootNode() override { return root_; }

 private:
  void* object_;
  size_t size_;
  bool root_;
  std::string name_;
};

void BuildEmbedderGraph(Isolate* isolate, EmbedderGraph* graph, void*) {
  ProbeRun* run = activeRun_;
  ClassSet ownClasses;
  if (run != nullptr) {
    if (!BuildNativeGraph(isolate, run)) {
      return;
    }
  } else {
    ownClasses = LoadClasses();
  }
  const ClassSet& classes = run != nullptr ? run->classes : ownClasses;
  HeapProfiler* profiler = isolate->GetHeapProfiler();
  std::unordered_map<void*, EmbedderGraph::Node*> nodes;
  // `cls` must have been read while the object was known to be alive.
  auto nodeFor = [&](void* object, Class cls) {
    EmbedderGraph::Node*& node = nodes[object];
    if (node == nullptr) {
      bool root = false;
      size_t size = 0;
      if (run != nullptr) {
        auto found = run->natives.find(object);
        root = found == run->natives.end() || run->Root(found->second);
        if (found != run->natives.end()) {
          cls = found->second.cls;
          size = found->second.size;
        }
      }
      node = graph->AddNode(std::make_unique<NativeObjectNode>(object, cls, size, root));
    }
    return node;
  };
  auto modeled = [&](Local<Value> value) {
    if (run != nullptr) {
      run->modeledHandles.insert(profiler->GetObjectId(value));
    }
  };

  bool valid = ForEachInstance(isolate, [&](const Instance& instance) {
    Wrapped wrapped;
    if (!ReadInstance(classes, instance, &wrapped)) {
      if (run != nullptr) {
        auto found = run->natives.find(instance.object);
        if (found != run->natives.end() && found->second.seed) {
          found->second.changed = true;
        }
      }
      return;
    }
    EmbedderGraph::Node* native = nodeFor(instance.object, wrapped.cls);
    EmbedderGraph::Node* js = graph->V8Node(wrapped.js);
    if (wrapped.adapter) {
      graph->AddEdge(native, js, "ns:adapter");
      modeled(wrapped.js);
      return;
    }
    graph->AddEdge(js, native, "ns:retain");
    if (wrapped.rootedStrong || wrapped.reconciledStrong) {
      graph->AddEdge(native, js, "ns:owned");
      modeled(wrapped.js);
    }
  });
  if (!valid) {
    return;
  }
  ForEachState(isolate, [&](id object, Local<Object> state) {
    graph->AddEdge(nodeFor((__bridge void*)object, object_getClass(object)),
                   graph->V8Node(state.As<Value>()), "ns:state");
    modeled(state);
  });
  if (run == nullptr) {
    return;
  }
  for (auto& native : run->natives) {
    EmbedderGraph::Node* from = nodeFor(native.first, native.second.cls);
    for (const auto& edge : native.second.out) {
      graph->AddEdge(from, nodeFor(edge.to, edge.cls), edge.label.c_str());
    }
    // A JS block's disposal takes the isolate's Locker, which the snapshot
    // holds, so a block found alive stays readable until the snapshot ends.
    if (native.second.block && !native.second.changed) {
      Local<Value> callback = host_->jsBlockCallback(isolate, native.first);
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

// Ephemeron tables hold their keys and values through weak edges.
bool HasWeakEdges(const HeapGraphNode* node) {
  for (int i = 0; i < node->GetChildrenCount(); i++) {
    if (node->GetChild(i)->GetType() == HeapGraphEdge::kWeak) {
      return true;
    }
  }
  return false;
}

// V8 records each WeakMap entry as two internal edges to the value, one from
// the key and one from the table, both named "... pair in WeakMap (table @<id>)"
// (V8HeapExplorer::ExtractEphemeronHashTableReferences). Only the key's is
// followed: the table's would keep every value alive while the map is,
// whatever its key.
bool EphemeronTableEdge(Isolate* isolate, const HeapGraphNode* table, const HeapGraphEdge* edge) {
  if (edge->GetType() != HeapGraphEdge::kInternal) {
    return false;
  }
  std::string name = EdgeName(isolate, edge);
  std::string suffix = " pair in WeakMap (table @" + std::to_string(table->GetId()) + ")";
  return name.size() > suffix.size() &&
         name.compare(name.size() - suffix.size(), suffix.size(), suffix) == 0;
}

// Calls `visit` with the edges of `node` that keep their target alive.
template <typename Visit>
void ForEachOwningEdge(Isolate* isolate, const HeapGraphNode* node, Visit&& visit) {
  bool table = HasWeakEdges(node);
  for (int i = 0; i < node->GetChildrenCount(); i++) {
    const HeapGraphEdge* edge = node->GetChild(i);
    if (Strong(edge) && !(table && EphemeronTableEdge(isolate, node, edge))) {
      if (!visit(edge)) {
        return;
      }
    }
  }
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
               const std::unordered_set<const HeapGraphNode*>& marked, std::vector<Hop>* hops,
               bool* tooLong) {
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
    ForEachOwningEdge(isolate, node, [&](const HeapGraphEdge* edge) {
      const HeapGraphNode* to = edge->GetToNode();
      if (marked.count(to) || (node == ownWrapper && to == start)) {
        return true;
      }
      if (to == start) {
        closing = node;
        closingEdge = edge;
        return false;
      }
      if (!parent.count(to)) {
        parent[to] = {node, edge};
        queue.push_back(to);
      }
      return true;
    });
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
      *tooLong = true;
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
  // Element indices and storage offsets move with a collection's contents,
  // and V8 numbers the edges it names twice ("2 / part of key ...").
  static const std::regex positions("\\[[0-9]+\\]|\\+[0-9]+|^[0-9]+ / ");
  std::string out;
  for (size_t i = 0; i < hops.size(); i++) {
    const Hop& hop = hops[(first + i) % hops.size()];
    std::string name = NodeName(isolate, hop.node);
    std::string edge = hop.edge;
    if (forSignature) {
      name = std::regex_replace(name, volatileParts, "");
      edge = std::regex_replace(std::regex_replace(edge, volatileParts, ""), positions, "#");
    }
    out += (i == 0 ? "" : " ") + name + " -[" + edge + "]->";
  }
  const Hop& head = hops[first % hops.size()];
  std::string name = NodeName(isolate, head.node);
  return out + " " + (forSignature ? std::regex_replace(name, volatileParts, "") : name);
}

// `inspect` lists class-name prefixes whose native objects the report details
// (retain accounting, root, reached), to explain a missing or unexpected cycle.
MaybeLocal<Object> FindLeakCycles(Isolate* isolate, Local<Context> context, bool strict,
                                  const std::vector<std::string>& inspect = {}) {
  ProbeRun run;
  run.strict = strict;
  run.calibration = GetCalibration();
  auto t0 = std::chrono::steady_clock::now();
  run.classes = LoadClasses();
  HeapProfiler* profiler = isolate->GetHeapProfiler();
  // A snapshot leaves V8 assigning ids and tracking object moves until the
  // ids are cleared. Ids that already existed belong to DevTools or
  // allocation tracking, and stay.
  bool hadObjectIds = profiler->GetObjectId(context->Global()) != HeapProfiler::kUnknownObjectId;
  activeRun_ = &run;
  const HeapSnapshot* snapshot = profiler->TakeHeapSnapshot();
  activeRun_ = nullptr;
  auto deleteSnapshot = [&]() {
    const_cast<HeapSnapshot*>(snapshot)->Delete();
    if (profiler->GetSnapshotCount() == 0) {
      // Frees the strings the snapshot interned.
      profiler->DeleteAllHeapSnapshots();
      if (!hadObjectIds) {
        profiler->ClearObjectIds();
      }
    }
  };
  auto t1 = std::chrono::steady_clock::now();
  for (auto& native : run.natives) {
    if (!native.second.changed && !StillThere(&run, native.first, native.second)) {
      native.second.changed = true;
    }
  }

  std::unordered_set<const HeapGraphNode*> modeled;
  for (SnapshotObjectId id : run.modeledHandles) {
    if (const HeapGraphNode* node = snapshot->GetNodeById(id)) {
      modeled.insert(node);
    }
  }
  const HeapGraphNode* gcRoots = Child(isolate, snapshot->GetRoot(), "(GC roots)");
  const HeapGraphNode* globalHandles = Child(isolate, gcRoots, "(Global handles)");
  if (globalHandles == nullptr) {
    // Without it the runtime's handles would all read as roots.
    deleteSnapshot();
    isolate->ThrowException(Exception::Error(
        ToV8String(isolate, "findLeakCycles: the heap snapshot has no (Global handles) root")));
    return MaybeLocal<Object>();
  }

  auto nodeOf = [&](void* native) {
    return snapshot->GetNodeById(profiler->GetObjectId(static_cast<NativeObject>(native)));
  };
  std::unordered_map<const HeapGraphNode*, void*> nativeOfNode;
  for (auto& native : run.natives) {
    if (const HeapGraphNode* node = nodeOf(native.first)) {
      nativeOfNode[node] = native.first;
    }
  }
  // A native node that was a root when the graph was built has an edge from
  // (GC roots); an object that changed since keeps nothing alive.
  auto staleRoot = [&](const HeapGraphNode* from, const HeapGraphNode* to) {
    if (from != gcRoots) {
      return false;
    }
    auto found = nativeOfNode.find(to);
    return found != nativeOfNode.end() && run.natives[found->second].changed;
  };
  // How marking reached each node, kept only to explain inspected objects.
  std::unordered_map<const HeapGraphNode*, const HeapGraphEdge*> reachedBy;
  auto mark = [&](const std::vector<const HeapGraphNode*>& extraRoots) {
    std::unordered_set<const HeapGraphNode*> marked{snapshot->GetRoot()};
    std::deque<const HeapGraphNode*> queue{snapshot->GetRoot()};
    for (const HeapGraphNode* root : extraRoots) {
      if (marked.insert(root).second) {
        queue.push_back(root);
      }
    }
    reachedBy.clear();
    while (!queue.empty()) {
      const HeapGraphNode* node = queue.front();
      queue.pop_front();
      ForEachOwningEdge(isolate, node, [&](const HeapGraphEdge* edge) {
        const HeapGraphNode* to = edge->GetToNode();
        if ((node == globalHandles && modeled.count(to)) || staleRoot(node, to)) {
          return true;
        }
        if (marked.insert(to).second) {
          queue.push_back(to);
          if (!inspect.empty()) {
            reachedBy[to] = edge;
          }
        }
        return true;
      });
    }
    return marked;
  };

  // Seeds in a fixed order, so that one heap yields one set of cycles.
  std::vector<std::pair<std::string, void*>> seeds;
  for (auto& native : run.natives) {
    if (native.second.seed) {
      seeds.push_back({class_getName(native.second.cls), native.first});
    }
  }
  std::sort(seeds.begin(), seeds.end());

  std::vector<Cycle> cycles;
  std::unordered_set<const HeapGraphNode*> covered;
  uint32_t longCycles = 0;
  uint32_t uncertain = 0;
  uint32_t changed = 0;
  for (auto& native : run.natives) {
    if (native.second.changed) {
      changed++;
    } else if (!native.second.countUnknown && !native.second.Immortal() &&
               native.second.Unexplained() < 0) {
      uncertain++;
    }
  }
  auto collect = [&](const std::unordered_set<const HeapGraphNode*>& marked) {
    for (const auto& seed : seeds) {
      const HeapGraphNode* node = nodeOf(seed.second);
      std::vector<Hop> hops;
      bool tooLong = false;
      if (node == nullptr || marked.count(node) || covered.count(node) ||
          !FindCycle(isolate, node, marked, &hops, &tooLong)) {
        // Unmarked off any cycle: garbage the next collection frees, or held by
        // a cycle reported through one of its members.
        longCycles += tooLong ? 1 : 0;
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
        if (entry.changed) {
          cycle.reasons.push_back(std::string(class_getName(entry.cls)) + " " +
                                  HexAddress(found->second) +
                                  ": freed or replaced while the probe ran; its references are "
                                  "as found before");
        } else if (!entry.countUnknown && entry.Unexplained() < 0 && !entry.Immortal()) {
          cycle.reasons.push_back(
              std::string(class_getName(entry.cls)) + " " + HexAddress(found->second) +
              ": retainCount " + std::to_string(entry.retainCount) + " is less than the " +
              std::to_string(entry.runtimeRetains + entry.incoming) +
              " retains its graph explains (" + std::to_string(entry.runtimeRetains) +
              " runtime, " + std::to_string(entry.incoming) +
              " incoming); some incoming edge does not own");
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
  };
  if (strict) {
    // The default run's cycles first: its marking adds the objects only it
    // treats as owned from outside, so strict reports every default cycle as
    // the default run finds it, then the uncertain ones through those objects.
    std::vector<const HeapGraphNode*> defaultRoots;
    for (auto& native : run.natives) {
      const NativeEntry& entry = native.second;
      if (!entry.changed && !entry.countUnknown && !entry.Immortal() && entry.Unexplained() < 0) {
        if (const HeapGraphNode* node = nodeOf(native.first)) {
          defaultRoots.push_back(node);
        }
      }
    }
    collect(mark(defaultRoots));
  }
  std::unordered_set<const HeapGraphNode*> marked = mark({});
  collect(marked);
  auto t2 = std::chrono::steady_clock::now();

  auto set = [&](Local<Object> object, const char* key, Local<Value> value) {
    object->Set(context, ToV8String(isolate, key), value).FromMaybe(false);
  };
  auto number = [&](double value) { return v8::Number::New(isolate, value).As<Value>(); };
  auto string = [&](const std::string& value) { return ToV8String(isolate, value).As<Value>(); };

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
  set(result, "mode", string(host_->lifetimeMode()));
  set(result, "scope", string(host_->lifetimeScope()));
  set(result, "strict", v8::Boolean::New(isolate, strict));
  set(result, "cycles", cycleArray);
  set(result, "nativeObjects", number(run.natives.size()));
  set(result, "uncertainNativeObjects", number(uncertain));
  set(result, "changedNativeObjects", number(changed));
  Local<v8::Array> changedList = v8::Array::New(isolate);
  uint32_t listed = 0;
  for (auto& native : run.natives) {
    if (!native.second.changed || listed >= kMaxChangedListed) {
      continue;
    }
    Local<Object> entry = Object::New(isolate);
    set(entry, "className", string(class_getName(native.second.cls)));
    set(entry, "address", string(HexAddress(native.first)));
    set(entry, "seed", v8::Boolean::New(isolate, native.second.seed));
    set(entry, "depth", number(native.second.depth));
    std::string from;
    if (native.second.foundFrom != nullptr) {
      auto parent = run.natives.find(native.second.foundFrom);
      from = std::string(parent != run.natives.end() ? class_getName(parent->second.cls) : "?") +
             " " + HexAddress(native.second.foundFrom) + " -[" + native.second.foundVia + "]->";
    }
    set(entry, "foundFrom", string(from));
    changedList->Set(context, listed++, entry).FromMaybe(false);
  }
  set(result, "changed", changedList);
  set(result, "truncated", v8::Boolean::New(isolate, run.truncated));
  Local<Object> cutOffs = Object::New(isolate);
  set(cutOffs, "depth", number(run.depthCutOffs));
  set(cutOffs, "storage", number(run.storageCutOffs));
  set(cutOffs, "cycleLength", number(longCycles));
  set(result, "cutOffs", cutOffs);
  Local<Object> calibrated = Object::New(isolate);
  set(calibrated, "layer", v8::Boolean::New(isolate, run.calibration->layerClass != nil));
  set(calibrated, "mutableArray",
      v8::Boolean::New(isolate, run.calibration->mutableArrayClass != nil));
  set(result, "calibrated", calibrated);
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
      const HeapGraphNode* node = nodeOf(native.first);
      Local<Object> entry = Object::New(isolate);
      set(entry, "className", string(name));
      set(entry, "address", string(HexAddress(native.first)));
      set(entry, "seed", v8::Boolean::New(isolate, native.second.seed));
      set(entry, "retainCount", number(native.second.retainCount));
      set(entry, "retainCountUnknown", v8::Boolean::New(isolate, native.second.countUnknown));
      set(entry, "runtimeRetains", number(native.second.runtimeRetains));
      set(entry, "incoming", number(native.second.incoming));
      std::string out;
      for (const auto& edge : native.second.out) {
        out += (out.empty() ? "" : ", ") + edge.label + " -> " + class_getName(edge.cls);
      }
      set(entry, "out", string(out));
      set(entry, "root", v8::Boolean::New(isolate, run.Root(native.second)));
      set(entry, "jsBlock",
          v8::Boolean::New(isolate, native.second.block && !native.second.changed &&
                                        !host_->jsBlockCallback(isolate, native.first).IsEmpty()));
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
  deleteSnapshot();
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
  HandleScope scope(isolate);
  ClassSet classes = LoadClasses();
  bool valid = ForEachInstance(isolate, [&](const Instance& instance) {
    Wrapped wrapped;
    if (!ReadInstance(classes, instance, &wrapped)) {
      return;
    }
    ClassCounts& count = counts[class_getName(wrapped.cls)];
    count.wrappers++;
    if (wrapped.rootedStrong) {
      count.strong++;
    }
  });
  if (!valid) {
    return {};
  }
  ForEachState(isolate, [&](id object, Local<Object>) {
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
      value->Set(context, ToV8String(isolate, key), v8::Number::New(isolate, count))
          .FromMaybe(false);
    }
    result->Set(context, ToV8String(isolate, name), value).FromMaybe(false);
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
      isolate->ThrowException(Exception::TypeError(ToV8String(
          isolate, "findLeakCycles expects ({ strict?: boolean, inspect?: string[] })")));
      return;
    }
    Local<Value> value;
    if (!info[0].As<Object>()->Get(context, ToV8String(isolate, "strict")).ToLocal(&value)) {
      return;
    }
    strict = value->BooleanValue(isolate);
    if (!info[0].As<Object>()->Get(context, ToV8String(isolate, "inspect")).ToLocal(&value)) {
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
  Local<Object> report;
  if (FindLeakCycles(isolate, context, strict, inspect).ToLocal(&report)) {
    info.GetReturnValue().Set(report);
  }
}

// ---- Triggers ------------------------------------------------------------

bool TriggersEnabled() {
  id config = host_->appConfigValue("wrapperLifetime");
  if ([config isKindOfClass:[NSDictionary class]]) {
    id leakProbe = ((NSDictionary*)config)[@"leakProbe"];
    if ([leakProbe isKindOfClass:[NSNumber class]]) {
      return [leakProbe boolValue];
    }
  }
  return host_->isDebug();
}

enum class Trigger : uintptr_t {
  kMemoryWarning,
  kCounts,
  kCycles,
  kStrictCycles,
  kInspectCycles,
};

void RunTrigger(Isolate* isolate, void* trigger);

// Shared with the notification handlers, which run on other threads and may
// outlive the isolate.
struct TriggerGate {
  std::mutex mutex;
  bool open = true;
  Poster* poster = nullptr;

  ~TriggerGate() {
    if (poster != nullptr) {
      host_->destroyPoster(poster);
    }
  }

  void Post(Trigger trigger) {
    std::lock_guard<std::mutex> lock(mutex);
    if (open) {
      host_->post(poster, RunTrigger, reinterpret_cast<void*>(static_cast<uintptr_t>(trigger)));
    }
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
    host_->drainReleases(isolate);
  }
  Local<Context> context = isolate->GetCurrentContext();
  Local<Object> report = Object::New(isolate);
  report->Set(context, ToV8String(isolate, "mode"), ToV8String(isolate, host_->lifetimeMode()))
      .FromMaybe(false);
  report->Set(context, ToV8String(isolate, "scope"), ToV8String(isolate, host_->lifetimeScope()))
      .FromMaybe(false);
  report
      ->Set(context, ToV8String(isolate, "classes"),
            CountsObject(isolate, context, CountByClass(isolate)))
      .FromMaybe(false);
  leakprobe::LifetimeStats stats;
  if (host_->lifetimeStats(isolate, &stats)) {
    Local<Object> counters = Object::New(isolate);
    const std::pair<const char*, uint64_t> fields[] = {
        {"resurrections", stats.resurrections},
        {"collected", stats.collected},
        {"releasedExplicitly", stats.releasedExplicitly},
        {"releasedAccesses", stats.releasedAccesses},
        {"queuedReleases", stats.queuedReleases},
        {"canaryStates", stats.canaryStates},
        {"canaryNativeDeaths", stats.canaryNativeDeaths},
    };
    for (const auto& [key, value] : fields) {
      counters
          ->Set(context, ToV8String(isolate, key),
                v8::Number::New(isolate, static_cast<double>(value)))
          .FromMaybe(false);
    }
    report->Set(context, ToV8String(isolate, "stats"), counters).FromMaybe(false);
  }
  std::string path = WriteReport(isolate, context, "counts", report);
  if (path.empty()) {
    Log("%s could not write the class counts report", kLogPrefix);
  } else {
    Log("%s class counts written to %s", kLogPrefix, path.c_str());
  }
}

std::vector<std::string> InspectPrefixes() {
  std::vector<std::string> prefixes;
  NSString* path =
      [NSTemporaryDirectory() stringByAppendingPathComponent:@"ns-wrapper-lifetime-inspect.txt"];
  NSString* text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
  for (NSString* line in
       [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
    NSString* prefix = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (prefix.length > 0) {
      prefixes.push_back(prefix.UTF8String);
    }
  }
  return prefixes;
}

void ReportCycles(Isolate* isolate, bool strict, const std::vector<std::string>& inspect = {}) {
  Local<Context> context = isolate->GetCurrentContext();
  TryCatch tryCatch(isolate);
  Local<Object> report;
  if (!FindLeakCycles(isolate, context, strict, inspect).ToLocal(&report)) {
    Log("%s %s", kLogPrefix,
        tryCatch.HasCaught() ? Utf8(isolate, tryCatch.Exception()).c_str() : "probe failed");
    return;
  }
  Local<Value> cycles;
  uint32_t count = 0;
  if (report->Get(context, ToV8String(isolate, "cycles")).ToLocal(&cycles) && cycles->IsArray()) {
    count = cycles.As<v8::Array>()->Length();
    for (uint32_t i = 0; i < count; i++) {
      Local<Value> cycle, path, uncertain;
      if (cycles.As<v8::Array>()->Get(context, i).ToLocal(&cycle) && cycle->IsObject() &&
          cycle.As<Object>()->Get(context, ToV8String(isolate, "path")).ToLocal(&path) &&
          cycle.As<Object>()->Get(context, ToV8String(isolate, "uncertain")).ToLocal(&uncertain)) {
        Log("%s %scycle %u: %s", kLogPrefix, uncertain->BooleanValue(isolate) ? "uncertain " : "",
            i + 1, Utf8(isolate, path).c_str());
      }
    }
  }
  const char* kind = !inspect.empty() ? "cycles-inspect" : strict ? "cycles-strict" : "cycles";
  std::string path = WriteReport(isolate, context, kind, report);
  Local<Value> changed;
  uint32_t changedCount = 0;
  if (report->Get(context, ToV8String(isolate, "changedNativeObjects")).ToLocal(&changed) &&
      changed->IsNumber()) {
    changedCount = static_cast<uint32_t>(changed.As<v8::Number>()->Value());
  }
  Log("%s %u leak cycle(s)%s, %u native object(s) freed while probing, %s%s", kLogPrefix, count,
      strict ? " (strict)" : "", changedCount,
      path.empty() ? "could not write the report" : "report written to ", path.c_str());
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
  Triggers* triggers = static_cast<Triggers*>(host_->isolateState(isolate));
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

void RunTrigger(Isolate* isolate, void* trigger) {
  switch (static_cast<Trigger>(reinterpret_cast<uintptr_t>(trigger))) {
    case Trigger::kMemoryWarning:
      OnMemoryWarning(isolate);
      break;
    case Trigger::kCounts:
      ReportCounts(isolate);
      break;
    case Trigger::kCycles:
      ReportCycles(isolate, false);
      break;
    case Trigger::kStrictCycles:
      ReportCycles(isolate, true);
      break;
    case Trigger::kInspectCycles:
      for (int i = 0; i < kCountCollections; i++) {
        isolate->LowMemoryNotification();
        host_->drainReleases(isolate);
      }
      ReportCycles(isolate, false, InspectPrefixes());
      break;
  }
}

void InstallTriggers(Isolate* isolate) {
  Poster* poster = host_->createPoster(isolate);
  if (poster == nullptr) {
    return;
  }
  Triggers* triggers = new Triggers();
  triggers->gate->poster = poster;
  if (!host_->setIsolateState(isolate, triggers,
                              [](void* state) { delete static_cast<Triggers*>(state); })) {
    delete triggers;
    return;
  }
  std::shared_ptr<TriggerGate> gate = triggers->gate;

  // By name: the framework does not link UIKit.
  triggers->memoryWarningObserver = [[[NSNotificationCenter defaultCenter]
      addObserverForName:@"UIApplicationDidReceiveMemoryWarningNotification"
                  object:nil
                   queue:nil
              usingBlock:^(NSNotification*) {
                gate->Post(Trigger::kMemoryWarning);
              }] retain];

  const std::pair<const char*, Trigger> handlers[] = {
      {kCountsNotification, Trigger::kCounts},
      {kCyclesNotification, Trigger::kCycles},
      {kStrictCyclesNotification, Trigger::kStrictCycles},
      {kInspectCyclesNotification, Trigger::kInspectCycles},
  };
  for (const auto& [name, trigger] : handlers) {
    int token = 0;
    Trigger posted = trigger;
    uint32_t status = notify_register_dispatch(
        name, &token, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(int) {
          gate->Post(posted);
        });
    if (status == NOTIFY_STATUS_OK) {
      triggers->notifyTokens.push_back(token);
    }
  }
}

// Set by the test suite, to see ns:runtime without the framework.
std::atomic<bool> declineIsolates_{false};

bool Attach(Isolate* isolate, bool mainIsolate) {
  if (declineIsolates_.load()) {
    return false;
  }
  isolate->GetHeapProfiler()->AddBuildEmbedderGraphCallback(BuildEmbedderGraph, nullptr);
  if (mainIsolate && TriggersEnabled()) {
    InstallTriggers(isolate);
  }
  return true;
}

const leakprobe::Probe kProbe = {
    .version = leakprobe::kVersion,
    .size = sizeof(leakprobe::Probe),
    .attach = Attach,
    .findLeakCycles = FindLeakCyclesCallback,
    .getWrapperClassCounts = GetWrapperClassCountsCallback,
};

}  // namespace

}  // namespace tns

extern "C" __attribute__((visibility("default"))) const tns::leakprobe::Probe*
NativeScriptLeakProbeConnect(const tns::leakprobe::Host* host) {
  if (host == nullptr || host->version != tns::leakprobe::kVersion ||
      host->size != sizeof(tns::leakprobe::Host)) {
    NSLog(@"NativeScriptLeakProbe: built for another runtime version, not attaching");
    return nullptr;
  }
  tns::host_ = host;
  return &tns::kProbe;
}

// Isolates that start while set get no probe, as if the framework were absent.
extern "C" __attribute__((visibility("default"))) void NativeScriptLeakProbeDeclineIsolates(
    bool decline) {
  tns::declineIsolates_.store(decline);
}
