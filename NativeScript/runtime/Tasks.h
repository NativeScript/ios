#ifndef Tasks_h
#define Tasks_h

#include <functional>
#include <vector>

namespace tns {

class Tasks {
 public:
  static void Register(std::function<void()> task);
  static void Drain();

 private:
  static std::vector<std::function<void()>> tasks_;
};

}  // namespace tns

#endif /* Tasks_h */
