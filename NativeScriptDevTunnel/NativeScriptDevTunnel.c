// NativeScriptDevTunnel.framework: lets a dev tool on the Mac reach the app
// over USB and the app reach servers on the Mac (docs/dev-tunnel.md). Apps
// embed it in debug builds only; the runtime attaches it through
// DevTunnelSPI.h. It exports nothing else and has no Objective-C classes, so
// the metadata generator finds nothing in it.

#include <dispatch/dispatch.h>
#include <notify.h>
#include <os/log.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

#include "../NativeScript/runtime/DevTunnelSPI.h"
#include "src/nsdt_relay.h"

_Static_assert(NS_DEV_TUNNEL_MAX_NAME == NSDT_MAX_NAME, "name limits differ");
_Static_assert(NS_DEV_TUNNEL_MAX_TUNNELS == NSDT_MAX_TUNNELS,
               "tunnel limits differ");
_Static_assert(NS_DEV_TUNNEL_MAX_BUNDLE_ID == NSDT_MAX_BUNDLE_ID,
               "bundle id limits differ");

static const NSDevTunnelHost* host_;
static nsdt_relay* relay_;
static pthread_once_t once_ = PTHREAD_ONCE_INIT;

static void relay_log(void* context, const char* message) {
  (void)context;
  host_->log(message);
}

static void copy_info(const nsdt_info* from, NSDevTunnelInfo* to) {
  memset(to, 0, sizeof(*to));
  snprintf(to->bundleId, sizeof(to->bundleId), "%s", from->bundle_id);
  to->tunnelPort = from->tunnel_port;
  to->count = (uint32_t)from->count;
  for (size_t i = 0; i < from->count; i++) {
    snprintf(to->tunnels[i].name, sizeof(to->tunnels[i].name), "%s",
             from->tunnels[i].name);
    to->tunnels[i].port = from->tunnels[i].port;
  }
}

static bool request(const NSDevTunnelSpec* tunnels, size_t count,
                    uint16_t tunnelPort, const char* token,
                    NSDevTunnelInfo* info, char* error, size_t errorSize) {
  if (!host_->isDebug()) {
    snprintf(error, errorSize, "the dev tunnel works in debug builds only");
    return false;
  }
  if (count > NSDT_MAX_TUNNELS) {
    snprintf(error, errorSize, "at most %d tunnels", NSDT_MAX_TUNNELS);
    return false;
  }
  nsdt_tunnel_spec specs[NSDT_MAX_TUNNELS];
  for (size_t i = 0; i < count; i++) {
    specs[i] = (nsdt_tunnel_spec){.name = tunnels[i].name,
                                  .preferred_port = tunnels[i].preferredPort};
  }
  nsdt_info result;
  if (nsdt_relay_request(relay_, specs, count, tunnelPort, token, &result,
                         error, errorSize) != 0) {
    return false;
  }
  if (info != NULL) {
    copy_info(&result, info);
  }
  return true;
}

static void info(NSDevTunnelInfo* out) {
  nsdt_info result;
  nsdt_relay_info(relay_, &result);
  copy_info(&result, out);
}

static const NSDevTunnelTunnel kTunnel = {
    .version = NS_DEV_TUNNEL_SPI_VERSION,
    .size = sizeof(NSDevTunnelTunnel),
    .request = request,
    .info = info,
};

static void start(void) {
  const char* bundle_id = host_->bundleId();
  relay_ = nsdt_relay_create(bundle_id, relay_log, NULL);
  if (relay_ == NULL) {
    return;
  }
  // Like the inspector's AttachRequest, but on a queue of its own: the tool
  // must be able to open the tunnel port while the JS thread is busy or
  // paused in the debugger.
  char name[NS_DEV_TUNNEL_MAX_BUNDLE_ID + 64];
  snprintf(name, sizeof(name), "%s:NativeScript.Debug.TunnelRequest",
           bundle_id);
  dispatch_queue_t queue = dispatch_queue_create("org.nativescript.devtunnel",
                                                 DISPATCH_QUEUE_SERIAL);
  int token;
  notify_register_dispatch(name, &token, queue, ^(int unused) {
    (void)unused;
    if (!host_->isDebug()) {
      return;
    }
    char error[256];
    if (nsdt_relay_open_tunnel_port(relay_, error, sizeof(error)) != 0) {
      // The relay already logged why.
      return;
    }
  });
}

__attribute__((visibility("default"))) const NSDevTunnelTunnel*
NativeScriptDevTunnelConnect(const NSDevTunnelHost* host) {
  if (host == NULL || host->version != NS_DEV_TUNNEL_SPI_VERSION ||
      host->size != sizeof(NSDevTunnelHost)) {
    os_log(OS_LOG_DEFAULT,
           "NativeScriptDevTunnel: built for another runtime version, not "
           "attaching");
    return NULL;
  }
  if (!host->isDebug()) {
    return NULL;
  }
  // The first host wins; the relay is process-wide.
  __sync_bool_compare_and_swap(&host_, NULL, host);
  pthread_once(&once_, start);
  return relay_ != NULL ? &kTunnel : NULL;
}
