#include "ClassBuilder.h"

#include <os/lock.h>

namespace tns {

namespace {
// objc_allocateClassPair only rejects names that are already *registered*, so
// two threads extending the same class name concurrently can both allocate it
// and register duplicate same-named classes (objc keeps both and name lookups
// become ambiguous). Serialize the whole allocate -> register window.
//
// os_unfair_lock rather than SpinLock: the section takes objc's runtimeLock
// internally (the holder can sleep) and contending threads run at
// worker-chosen QoS, so a spinning waiter risks priority inversion. This lock
// is a leaf — the section never acquires a v8::Locker — so it cannot form a
// cycle with the isolate locks.
os_unfair_lock extendedClassRegistrationLock = OS_UNFAIR_LOCK_INIT;
}  // namespace

// Moved this method in a separate .cpp file because ARC destroys the class
// created with objc_allocateClassPair when the control leaves this method scope
// TODO: revist this. Maybe a lock is needed regardless
Class ClassBuilder::GetExtendedClass(std::string baseClassName,
                                     std::string staticClassName,
                                     std::string suffix) {
  Class baseClass = objc_getClass(baseClassName.c_str());
  std::string name =
      !staticClassName.empty()
          ? staticClassName
          : baseClassName + suffix + "_" +
                std::to_string(++ClassBuilder::classNameCounter_);
  // Allocation failure is the collision signal (objc_getClass beforehand
  // would race), but that only detects *registered* names — hence the lock
  // spanning allocate -> register.
  os_unfair_lock_lock(&extendedClassRegistrationLock);
  Class clazz = objc_allocateClassPair(baseClass, name.c_str(), 0);

  if (clazz == nil) {
    int i = 1;
    std::string initialName = name;
    while (clazz == nil) {
      name = initialName + std::to_string(i++);
      clazz = objc_allocateClassPair(baseClass, name.c_str(), 0);
    }
  }

  objc_registerClassPair(clazz);
  os_unfair_lock_unlock(&extendedClassRegistrationLock);
  return clazz;
}

}  // namespace tns
