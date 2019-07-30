#ifndef Helpers_h
#define Helpers_h

#include <functional>
#include <string>

namespace tns {

std::string ReadText(const std::string& file);
void ExecuteOnMainThread(std::function<void ()> func, bool async = true);

}

#endif /* Helpers_h */
