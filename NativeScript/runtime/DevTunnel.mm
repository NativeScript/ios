#include "DevTunnel.h"
#include <Foundation/Foundation.h>
#include <dlfcn.h>
#include <os/log.h>
#include "DevTunnelSPI.h"
#include "Helpers.h"
#include "RuntimeConfig.h"

namespace tns {
namespace devtunnel {

namespace {

const char* BundleId() {
  static const std::string bundleId = []() -> std::string {
    NSString* identifier = [[NSBundle mainBundle] bundleIdentifier];
    return identifier != nil ? std::string(identifier.UTF8String) : std::string();
  }();
  return bundleId.c_str();
}

const NSDevTunnelHost kHost = {
    .version = NS_DEV_TUNNEL_SPI_VERSION,
    .size = sizeof(NSDevTunnelHost),
    .isDebug = []() -> bool { return RuntimeConfig.IsDebug; },
    // NSLog's arguments read as <private> on a device; tools find the ports
    // in this line.
    .log = [](const char* message) { os_log(OS_LOG_DEFAULT, "%{public}s", message); },
    .bundleId = BundleId,
};

// Once per process: dyld loads the framework, when the app embeds it, before
// the runtime starts.
const NSDevTunnelTunnel* Connected() {
  static const NSDevTunnelTunnel* tunnel = []() -> const NSDevTunnelTunnel* {
    if (!RuntimeConfig.IsDebug) {
      return nullptr;
    }
    auto connect = reinterpret_cast<NSDevTunnelConnectFunction>(
        dlsym(RTLD_DEFAULT, NS_DEV_TUNNEL_CONNECT_SYMBOL));
    if (connect == nullptr) {
      return nullptr;
    }
    const NSDevTunnelTunnel* connected = connect(&kHost);
    if (connected == nullptr) {
      return nullptr;
    }
    if (connected->version != NS_DEV_TUNNEL_SPI_VERSION ||
        connected->size != sizeof(NSDevTunnelTunnel)) {
      Log("NativeScript: ignoring %s, built for another runtime version",
          NS_DEV_TUNNEL_CONNECT_SYMBOL);
      return nullptr;
    }
    return connected;
  }();
  return tunnel;
}

TunnelInfo Convert(const NSDevTunnelInfo& raw) {
  TunnelInfo info;
  info.bundleId = raw.bundleId;
  info.tunnelPort = raw.tunnelPort;
  for (uint32_t i = 0; i < raw.count && i < NS_DEV_TUNNEL_MAX_TUNNELS; i++) {
    info.tunnels.push_back({raw.tunnels[i].name, raw.tunnels[i].port});
  }
  return info;
}

}  // namespace

void Init() { Connected(); }

bool DevTunnelAvailable() { return Connected() != nullptr; }

RequestResult Request(const std::vector<TunnelRequest>& tunnels, std::optional<uint16_t> tunnelPort,
                      std::optional<std::string> token) {
  RequestResult result;
  const NSDevTunnelTunnel* tunnel = Connected();
  if (tunnel == nullptr) {
    result.error = RuntimeConfig.IsDebug ? "the dev tunnel framework is not embedded in this app"
                                         : "the dev tunnel works in debug builds only";
    return result;
  }
  std::vector<NSDevTunnelSpec> specs;
  specs.reserve(tunnels.size());
  for (const TunnelRequest& request : tunnels) {
    specs.push_back({request.name.c_str(), request.preferredPort});
  }
  NSDevTunnelInfo raw;
  char error[256] = "";
  if (tunnel->request(specs.data(), specs.size(), tunnelPort.value_or(0),
                      token.has_value() ? token->c_str() : nullptr, &raw, error, sizeof(error))) {
    result.info = Convert(raw);
  } else {
    result.error = error;
  }
  return result;
}

std::optional<TunnelInfo> Info() {
  const NSDevTunnelTunnel* tunnel = Connected();
  if (tunnel == nullptr) {
    return std::nullopt;
  }
  NSDevTunnelInfo raw;
  tunnel->info(&raw);
  return Convert(raw);
}

}  // namespace devtunnel
}  // namespace tns
