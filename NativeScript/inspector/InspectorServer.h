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
  // Any number of clients may be connected at once. For one connection the
  // callbacks are ordered: onClientConnected returns before its first
  // onMessage, and onClientDisconnected comes after its last. Callbacks for
  // different connections run concurrently.
  static in_port_t Init(
      std::function<void(uint64_t connectionId, Sender sender)>
          onClientConnected,
      std::function<void(uint64_t connectionId)> onClientDisconnected,
      std::function<void(uint64_t connectionId, const std::string&)> onMessage);
};

}  // namespace v8_inspector

#endif /* InspectorServer_h */
