#ifndef DevTunnelSPI_h
#define DevTunnelSPI_h

// The interface between the runtime and NativeScriptDevTunnel.framework, the
// dev tunnel apps embed in debug builds only. The runtime looks up
// NS_DEV_TUNNEL_CONNECT_SYMBOL with dlsym and hands the framework a Host; the
// framework answers with its Tunnel table. Both sides check version and size
// and refuse any other, so a stale framework copy is ignored rather than
// misread. C only: the framework is written in C and sees nothing else of the
// runtime.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NS_DEV_TUNNEL_SPI_VERSION 1
#define NS_DEV_TUNNEL_CONNECT_SYMBOL "NativeScriptDevTunnelConnect"

#define NS_DEV_TUNNEL_MAX_NAME 32
#define NS_DEV_TUNNEL_MAX_TUNNELS 16
#define NS_DEV_TUNNEL_MAX_BUNDLE_ID 255

typedef struct NSDevTunnelHost {
  uint32_t version;
  uint32_t size;
  // The framework opens nothing unless this is true.
  bool (*isDebug)(void);
  // Any thread. Writes `message` to the system log, readable on a device.
  void (*log)(const char* message);
  // The app's bundle identifier; never null.
  const char* (*bundleId)(void);
} NSDevTunnelHost;

typedef struct NSDevTunnelSpec {
  const char* name;
  uint16_t preferredPort;
} NSDevTunnelSpec;

typedef struct NSDevTunnelEntry {
  char name[NS_DEV_TUNNEL_MAX_NAME + 1];
  uint16_t port;
} NSDevTunnelEntry;

typedef struct NSDevTunnelInfo {
  char bundleId[NS_DEV_TUNNEL_MAX_BUNDLE_ID + 1];
  // 0 while nothing is open.
  uint16_t tunnelPort;
  uint32_t count;
  NSDevTunnelEntry tunnels[NS_DEV_TUNNEL_MAX_TUNNELS];
} NSDevTunnelInfo;

typedef struct NSDevTunnelTunnel {
  uint32_t version;
  uint32_t size;
  // Any thread. Opens the tunnel port if needed (preferring `tunnelPort`, or
  // the framework's default when 0) and a port for each tunnel whose name is
  // new; existing names keep their ports. A non-empty `token` turns on
  // authentication; null or empty leaves it as it is. True fills `info`;
  // false writes a message to `error`.
  bool (*request)(const NSDevTunnelSpec* tunnels, size_t count,
                  uint16_t tunnelPort, const char* token, NSDevTunnelInfo* info,
                  char* error, size_t errorSize);
  // Any thread.
  void (*info)(NSDevTunnelInfo* info);
} NSDevTunnelTunnel;

typedef const NSDevTunnelTunnel* (*NSDevTunnelConnectFunction)(
    const NSDevTunnelHost* host);

#ifdef __cplusplus
}
#endif

#endif /* DevTunnelSPI_h */
