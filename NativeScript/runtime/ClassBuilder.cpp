#include "ClassBuilder.h"
#if TARGET_CPU_X86_64 || TARGET_CPU_X86
#include "SpinLock.h"
#endif

namespace tns {

// Moved this method in a separate .cpp file because ARC destroys the class
// created with objc_allocateClassPair when the control leaves this method scope
// TODO: revist this as there are x86 simulator issues, so maybe a lock is
// needed regardless
Class ClassBuilder::GetExtendedClass(std::string baseClassName,
                                     std::string staticClassName) {
#if TARGET_CPU_X86_64 || TARGET_CPU_X86
  // X86 simulators have this bugged, so we fallback to old behavior
  static SpinMutex m;
  SpinLock lock(m);
  Class baseClass = objc_getClass(baseClassName.c_str());
  std::string name =
      !staticClassName.empty()
          ? staticClassName
          : baseClassName + "_" +
                std::to_string(++ClassBuilder::classNameCounter_);
  Class clazz = objc_getClass(name.c_str());

  if (clazz != nil) {
    int i = 1;
    std::string initialName = name;
    while (clazz != nil) {
      name = initialName + std::to_string(i++);
      clazz = objc_getClass(name.c_str());
    }
  }

  clazz = objc_allocateClassPair(baseClass, name.c_str(), 0);

  objc_registerClassPair(clazz);
  return clazz;
#else
  Class baseClass = objc_getClass(baseClassName.c_str());
  std::string name =
      !staticClassName.empty()
          ? staticClassName
          : baseClassName + "_" +
                std::to_string(++ClassBuilder::classNameCounter_);
  // here we could either call objc_getClass with the name to see if the class
  // already exists or we can just try allocating it, which will return nil if
  // the class already exists so we try allocating it every time to avoid race
  // conditions in case this method is being executed by multiple threads
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
  return clazz;
#endif
}

}  // namespace tns
