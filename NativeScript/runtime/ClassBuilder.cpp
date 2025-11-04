#include "ClassBuilder.h"

namespace tns {

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
}

}  // namespace tns
