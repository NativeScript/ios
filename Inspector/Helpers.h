#ifndef Helpers_h
#define Helpers_h

#include <functional>

namespace tns {

void ExecuteOnMainThread(std::function<void ()> func, bool async = true);

}

#endif /* Helpers_h */
