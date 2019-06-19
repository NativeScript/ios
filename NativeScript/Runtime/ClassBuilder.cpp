#include "ClassBuilder.h"

namespace tns {

// Moved this method in a separate .cpp file because ARC destroys the class created with objc_allocateClassPair
// when the control leaves this method scope

Class ClassBuilder::GetExtendedClass(std::string baseClassName, std::string staticClassName) {
    Class baseClass = objc_getClass(baseClassName.c_str());
    std::string name = !staticClassName.empty() ? staticClassName : baseClassName + "_" + std::to_string(++ClassBuilder::classNameCounter_);
    Class clazz = objc_getClass(name.c_str());

    if (clazz != nil) {
        int i = 1;
        while (clazz != nil) {
            name = name + std::to_string(i++);
            clazz = objc_getClass(name.c_str());
        }
    }

    clazz = objc_allocateClassPair(baseClass, name.c_str(), 0);

    objc_registerClassPair(clazz);
    return clazz;
}

}
