#ifndef DevTunnel_h
#define DevTunnel_h

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace tns {
namespace devtunnel {

// The runtime's side of NativeScriptDevTunnel.framework (DevTunnelSPI.h),
// which debug builds embed. Everything here works from any thread.

struct TunnelRequest {
  std::string name;
  uint16_t preferredPort;
};

struct Tunnel {
  std::string name;
  uint16_t port;
};

struct TunnelInfo {
  std::string bundleId;
  // 0 while nothing is open.
  uint16_t tunnelPort = 0;
  std::vector<Tunnel> tunnels;
};

struct RequestResult {
  // Set on success.
  std::optional<TunnelInfo> info;
  std::string error;
};

// Attaches the framework, which registers for the tool's TunnelRequest
// notification. Debug builds call it once at startup; later calls do nothing.
void Init();

// Whether the framework is embedded, built for this runtime, and the app is a
// debug build.
bool DevTunnelAvailable();

// Opens the tunnel port if needed (on `tunnelPort` or the first free port
// above it, else the framework's default) and a port per new tunnel name;
// existing names keep their ports. A token turns on authentication for every
// later connection to the tunnel port.
RequestResult Request(const std::vector<TunnelRequest>& tunnels,
                      std::optional<uint16_t> tunnelPort = std::nullopt,
                      std::optional<std::string> token = std::nullopt);

// What is open, whoever asked for it; empty without the framework.
std::optional<TunnelInfo> Info();

}  // namespace devtunnel
}  // namespace tns

#endif /* DevTunnel_h */
