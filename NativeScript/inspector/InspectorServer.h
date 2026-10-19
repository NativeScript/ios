#ifndef InspectorServer_h
#define InspectorServer_h

#include <dispatch/dispatch.h>
#include <sys/types.h>

#include <cstdint>
#include <functional>
#include <string>

namespace v8_inspector {

class InspectorServer {
 public:
  using Sender = std::function<void(const std::string&)>;

  // Starts listening and returns the port. Each accepted client gets a
  // process-unique connection id: onClientConnected hands out its sender,
  // and onClientDisconnected fires once with the same id when the
  // connection closes, after which that sender drops every message.
  // Callbacks run on the connection's own serial queue.
  static in_port_t Init(
      std::function<void(uint64_t connectionId, Sender sender)>
          onClientConnected,
      std::function<void(uint64_t connectionId)> onClientDisconnected,
      std::function<void(const std::string&)> onMessage);
};

}  // namespace v8_inspector

#endif /* InspectorServer_h */
