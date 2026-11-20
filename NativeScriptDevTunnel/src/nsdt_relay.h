#ifndef nsdt_relay_h
#define nsdt_relay_h

// The dev tunnel relay: plain POSIX C, independent of the runtime, so that it
// also builds for macOS for the host test harness. Wire protocol:
// docs/dev-tunnel.md.

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NSDT_MAX_NAME 32
#define NSDT_MAX_TUNNELS 16
#define NSDT_MAX_BUNDLE_ID 255
#define NSDT_MAX_TOKEN 256
#define NSDT_DEFAULT_TUNNEL_PORT 18283
#define NSDT_PORT_ATTEMPTS 32

typedef void (*nsdt_log_fn)(void* context, const char* message);

typedef struct nsdt_relay nsdt_relay;

typedef struct {
  const char* name;
  uint16_t preferred_port;
} nsdt_tunnel_spec;

typedef struct {
  char name[NSDT_MAX_NAME + 1];
  uint16_t port;
} nsdt_tunnel_entry;

typedef struct {
  char bundle_id[NSDT_MAX_BUNDLE_ID + 1];
  int pid;
  // 0 while the tunnel port is not open.
  uint16_t tunnel_port;
  size_t count;
  nsdt_tunnel_entry tunnels[NSDT_MAX_TUNNELS];
} nsdt_info;

// Never destroyed: its threads and listeners live as long as the process.
// Opens nothing until a request.
nsdt_relay* nsdt_relay_create(const char* bundle_id, nsdt_log_fn log,
                              void* log_context);

// Opens the tunnel port if it is not open (preferring `tunnel_port`, or
// NSDT_DEFAULT_TUNNEL_PORT when 0) and one app-side port per tunnel whose
// name is new; a name that exists keeps its port. A non-empty `token` turns
// authentication on; once on, only the same token is accepted. Returns 0 and
// fills `info` (may be NULL) on success; otherwise -1 with `error` set.
// Tunnels opened before a failure stay open. Any thread.
int nsdt_relay_request(nsdt_relay* relay, const nsdt_tunnel_spec* tunnels,
                       size_t count, uint16_t tunnel_port, const char* token,
                       nsdt_info* info, char* error, size_t error_size);

// Opens the tunnel port if needed, then logs the listening line either way, so
// a tool that can only post a notification finds the ports in the log.
int nsdt_relay_open_tunnel_port(nsdt_relay* relay, char* error,
                                size_t error_size);

void nsdt_relay_info(nsdt_relay* relay, nsdt_info* info);

#ifdef __cplusplus
}
#endif

#endif /* nsdt_relay_h */
