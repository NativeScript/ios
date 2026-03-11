#ifndef InspectorServer_h
#define InspectorServer_h

#include <dispatch/dispatch.h>
#include <sys/types.h>

#include <functional>
#include <string>

namespace v8_inspector {

class InspectorServer {
 public:
  static in_port_t Init(
      std::function<void(std::function<void(const std::string&)>)>
          onClientConnected,
      std::function<void(const std::string&)> onMessage);

 private:
  static void Send(dispatch_io_t channel, dispatch_queue_t queue,
                   const std::string& message);
};

}  // namespace v8_inspector

#endif /* InspectorServer_h */
