#include "ClassBuilder.h"

#include <mutex>

#include "UnfairLock.h"

namespace tns {

namespace {
// objc_allocateClassPair only rejects names that are already *registered*, so
// two threads extending the same class name concurrently can both allocate it
// and register duplicate same-named classes (objc keeps both and name lookups
// become ambiguous). Serialize the whole allocate -> register window.
//
// This lock is a leaf — the section never acquires a v8::Locker — so it cannot
// form a cycle with the isolate locks.
UnfairMutex extendedClassRegistrationMutex;

// Registered objc class names are never reclaimed and the ladder below
// allocates suffixes densely under the lock, so a name's taken suffixes form a
// contiguous prefix. Gallop + binary-search with objc_getClass probes to find
// its end, so heavy same-name reuse (worker tests, HMR re-extends of one
// class) stays O(log N) per extend with no side state to grow.
int FirstFreeSuffix(const std::string& initialName) {
  auto taken = [&initialName](int i) {
    return objc_getClass((initialName + std::to_string(i)).c_str()) != nil;
  };
  int hi = 1;
  while (taken(hi)) {
    hi *= 2;
  }
  int lo = hi / 2;
  while (lo + 1 < hi) {
    int mid = lo + (hi - lo) / 2;
    if (taken(mid)) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return hi;
}

// Bounds only *consecutive* failures past the probed free position, i.e.
// allocation failing for reasons other than an ordinary name collision (which
// would otherwise loop forever holding the mutex).
constexpr int kMaxConsecutiveAllocFailures = 100;
}  // namespace

// Moved this method in a separate .cpp file because ARC destroys the class
// created with objc_allocateClassPair when the control leaves this method scope
Class ClassBuilder::GetExtendedClass(const std::string& baseClassName,
                                     const std::string& staticClassName,
                                     int isolateId) {
  Class baseClass = objc_getClass(baseClassName.c_str());
  std::string name = staticClassName;
  if (name.empty()) {
    name = baseClassName;
    name += std::to_string(isolateId);
    name += "__";
    name += std::to_string(++ClassBuilder::classNameCounter_);
  }
  // Allocation failure is the collision signal (objc_getClass beforehand
  // would race), but that only detects *registered* names — hence the lock
  // spanning allocate -> register.
  std::lock_guard<UnfairMutex> lock(extendedClassRegistrationMutex);
  Class clazz = objc_allocateClassPair(baseClass, name.c_str(), 0);

  if (clazz == nil) {
    std::string initialName = name;
    int next = FirstFreeSuffix(initialName);
    for (int attempts = 0;
         clazz == nil && attempts < kMaxConsecutiveAllocFailures; attempts++) {
      name = initialName + std::to_string(next++);
      clazz = objc_allocateClassPair(baseClass, name.c_str(), 0);
    }
    if (clazz == nil) {
      return nil;
    }
  }

  objc_registerClassPair(clazz);
  return clazz;
}

}  // namespace tns
