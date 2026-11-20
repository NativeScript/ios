#include "nsdt_relay.h"

#include <CommonCrypto/CommonHMAC.h>
#include <CommonCrypto/CommonRandom.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

// Protocol lines, '\n' included.
#define LINE_MAX_BYTES 256
#define MAX_QUEUE 256
#define MAX_HANDSHAKES 64
#define MAX_CONTROLS 16
#define MAX_LISTENERS (2 * (NSDT_MAX_TUNNELS + 1))
#define HANDSHAKE_TIMEOUT_MS 2000
#define PENDING_TIMEOUT_MS 10000
#define REBIND_INTERVAL_MS 1000
#define SPLICE_BUFFER_SIZE 65536
#define NONCE_BYTES 16
#define MIN_HOST_NONCE_BYTES 8
#define MAX_HOST_NONCE_BYTES 32
#define PROOF_BYTES CC_SHA256_DIGEST_LENGTH
// "NSDT/1 READY " B " " pid " " port " " L " " nonce " " proof "\n" with the
// widest pid, port and proof: B + L may use what is left of LINE_MAX_BYTES.
#define READY_FIXED_BYTES \
  (13 + 1 + 10 + 1 + 5 + 1 + 1 + 2 * NONCE_BYTES + 1 + 2 * PROOF_BYTES + 1)
#define READY_BUDGET (LINE_MAX_BYTES - READY_FIXED_BYTES)

enum { kTunnelPortOwner = -1 };

enum request_failure {
  kFailureNone = 0,
  kFailureName,
  kFailurePort,
  kFailureBind,
  kFailureFull,
  kFailureToken,
  kFailureBundle,
  kFailureInternal,
  kFailureAuth,
};

#define kAnyEpoch UINT64_MAX

static const char* failure_reason(enum request_failure failure) {
  switch (failure) {
    case kFailureName:
      return "name";
    case kFailurePort:
      return "port";
    case kFailureBind:
      return "bind";
    case kFailureFull:
      return "full";
    case kFailureToken:
      return "token";
    case kFailureBundle:
      return "bundle";
    case kFailureAuth:
      return "auth";
    default:
      return "internal";
  }
}

typedef struct {
  int fd;
  int family;
  uint16_t port;
  // kTunnelPortOwner, or the index of the tunnel it accepts app connections
  // for.
  int owner;
  bool defunct;
  bool reported_rebind_failure;
  uint64_t next_rebind_ms;
} listener;

typedef struct {
  int fd;
  int tunnel;
  uint64_t since_ms;
} pending_app;

// A pool or control connection admitted under token epoch `epoch`.
typedef struct {
  int fd;
  uint64_t epoch;
} admitted;

struct nsdt_relay {
  pthread_mutex_t lock;
  pthread_cond_t changed;
  // Serializes requests, which bind outside `lock`.
  pthread_mutex_t request_lock;

  char bundle_id[NSDT_MAX_BUNDLE_ID + 1];
  bool bundle_id_valid;
  nsdt_log_fn log;
  void* log_context;

  bool listener_started;
  bool pairing_started;
  int wake[2];

  uint16_t tunnel_port;
  nsdt_tunnel_entry tunnels[NSDT_MAX_TUNNELS];
  size_t tunnel_count;
  listener listeners[MAX_LISTENERS];
  size_t listener_count;

  pending_app pending[MAX_QUEUE];
  size_t pending_count;
  admitted idle[MAX_QUEUE];
  size_t idle_count;
  admitted controls[MAX_CONTROLS];
  size_t control_count;
  int handshakes;

  char token[NSDT_MAX_TOKEN + 1];
  size_t token_length;
  // Bumped when a token is configured: connections admitted earlier did not
  // authenticate and must not be used.
  uint64_t epoch;

  uint64_t next_connection_id;
};

// ---------------------------------------------------------------------------
// Utilities

static uint64_t now_ms(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000;
}

static void relay_log(nsdt_relay* relay, const char* format, ...)
    __attribute__((format(printf, 2, 3)));

static void relay_log(nsdt_relay* relay, const char* format, ...) {
  if (relay->log == NULL) {
    return;
  }
  char message[512];
  va_list args;
  va_start(args, format);
  vsnprintf(message, sizeof(message), format, args);
  va_end(args);
  relay->log(relay->log_context, message);
}

static void set_error(char* error, size_t size, const char* format, ...)
    __attribute__((format(printf, 3, 4)));

static void set_error(char* error, size_t size, const char* format, ...) {
  if (error == NULL || size == 0) {
    return;
  }
  va_list args;
  va_start(args, format);
  vsnprintf(error, size, format, args);
  va_end(args);
}

static bool spawn_detached(void* (*body)(void*), void* argument) {
  pthread_t thread;
  pthread_attr_t attributes;
  pthread_attr_init(&attributes);
  pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
  int result = pthread_create(&thread, &attributes, body, argument);
  pthread_attr_destroy(&attributes);
  return result == 0;
}

static void configure_connection(int fd) {
  int flags = fcntl(fd, F_GETFL);
  // Accepted sockets inherit the listener's O_NONBLOCK.
  if (flags >= 0) {
    fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
  }
  int one = 1;
  // A write to a peer that already closed must fail with EPIPE, not raise
  // SIGPIPE, which would kill the app.
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
}

static bool send_all(int fd, const char* buffer, size_t length) {
  while (length > 0) {
    ssize_t written = send(fd, buffer, length, 0);
    if (written < 0) {
      if (errno == EINTR) {
        continue;
      }
      return false;
    }
    buffer += written;
    length -= (size_t)written;
  }
  return true;
}

static bool send_line(int fd, const char* format, ...)
    __attribute__((format(printf, 2, 3)));

static bool send_line(int fd, const char* format, ...) {
  char line[LINE_MAX_BYTES + 1];
  va_list args;
  va_start(args, format);
  int length = vsnprintf(line, sizeof(line), format, args);
  va_end(args);
  if (length < 0 || length >= LINE_MAX_BYTES) {
    return false;
  }
  line[length++] = '\n';
  return send_all(fd, line, (size_t)length);
}

static void deny(int fd, const char* reason) {
  send_line(fd, "NSDT/1 DENY %s", reason);
}

static void to_hex(const uint8_t* bytes, size_t length, char* out) {
  static const char digits[] = "0123456789abcdef";
  for (size_t i = 0; i < length; i++) {
    out[2 * i] = digits[bytes[i] >> 4];
    out[2 * i + 1] = digits[bytes[i] & 0xf];
  }
  out[2 * length] = '\0';
}

static int hex_value(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// The number of bytes decoded, or -1.
static int from_hex(const char* hex, uint8_t* out, size_t capacity) {
  size_t length = strlen(hex);
  if (length == 0 || length % 2 != 0 || length / 2 > capacity) {
    return -1;
  }
  for (size_t i = 0; i < length / 2; i++) {
    int high = hex_value(hex[2 * i]);
    int low = hex_value(hex[2 * i + 1]);
    if (high < 0 || low < 0) {
      return -1;
    }
    out[i] = (uint8_t)(high << 4 | low);
  }
  return (int)(length / 2);
}

static void hmac(const char* key, size_t key_length, const uint8_t* data,
                 size_t length, uint8_t out[PROOF_BYTES]) {
  CCHmac(kCCHmacAlgSHA256, key, key_length, data, length, out);
}

static bool equal_constant_time(const uint8_t* a, const uint8_t* b,
                                size_t length) {
  uint8_t difference = 0;
  for (size_t i = 0; i < length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

static bool valid_name(const char* name) {
  size_t length = name != NULL ? strlen(name) : 0;
  if (length == 0 || length > NSDT_MAX_NAME) {
    return false;
  }
  for (size_t i = 0; i < length; i++) {
    char c = name[i];
    bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
    if (!ok) {
      return false;
    }
  }
  return true;
}

static bool valid_bundle_id(const char* bundle_id) {
  size_t length = strlen(bundle_id);
  if (length == 0 || length + 1 > READY_BUDGET) {
    return false;
  }
  for (size_t i = 0; i < length; i++) {
    unsigned char c = (unsigned char)bundle_id[i];
    if (c <= ' ' || c >= 0x7f) {
      return false;
    }
  }
  return true;
}

static int split_fields(char* line, char** fields, int capacity) {
  int count = 0;
  char* cursor = line;
  while (*cursor != '\0') {
    while (*cursor == ' ') cursor++;
    if (*cursor == '\0') break;
    if (count == capacity) return capacity + 1;
    fields[count++] = cursor;
    while (*cursor != '\0' && *cursor != ' ') cursor++;
    if (*cursor == ' ') *cursor++ = '\0';
  }
  return count;
}

static bool parse_port(const char* text, uint16_t* port) {
  if (text == NULL || *text == '\0' || strlen(text) > 5) {
    return false;
  }
  unsigned value = 0;
  for (const char* c = text; *c != '\0'; c++) {
    if (*c < '0' || *c > '9') return false;
    value = value * 10 + (unsigned)(*c - '0');
  }
  if (value == 0 || value > 65535) {
    return false;
  }
  *port = (uint16_t)value;
  return true;
}

// ---------------------------------------------------------------------------
// Line reading

typedef struct {
  char buffer[LINE_MAX_BYTES];
  size_t length;
} line_reader;

enum { kLineEnd = -1, kLineTimeout = -2, kLineTooLong = -3 };

// Reads one '\n'-terminated line into `out` (LINE_MAX_BYTES bytes) without the
// terminator; `deadline_ms` 0 waits forever. Returns its length or a kLine*
// value.
static int read_line(line_reader* reader, int fd, uint64_t deadline_ms,
                     char* out) {
  for (;;) {
    char* newline = memchr(reader->buffer, '\n', reader->length);
    if (newline != NULL) {
      size_t length = (size_t)(newline - reader->buffer);
      memcpy(out, reader->buffer, length);
      out[length] = '\0';
      if (length > 0 && out[length - 1] == '\r') {
        out[--length] = '\0';
      }
      size_t consumed = (size_t)(newline - reader->buffer) + 1;
      memmove(reader->buffer, reader->buffer + consumed,
              reader->length - consumed);
      reader->length -= consumed;
      return (int)length;
    }
    if (reader->length == sizeof(reader->buffer)) {
      return kLineTooLong;
    }
    if (deadline_ms != 0) {
      uint64_t now = now_ms();
      if (now >= deadline_ms) {
        return kLineTimeout;
      }
      struct pollfd poll_fd = {.fd = fd, .events = POLLIN, .revents = 0};
      int ready = poll(&poll_fd, 1, (int)(deadline_ms - now));
      if (ready < 0 && errno == EINTR) {
        continue;
      }
      if (ready == 0) {
        return kLineTimeout;
      }
      if (ready < 0) {
        return kLineEnd;
      }
    }
    ssize_t count = recv(fd, reader->buffer + reader->length,
                         sizeof(reader->buffer) - reader->length, 0);
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count <= 0) {
      return kLineEnd;
    }
    reader->length += (size_t)count;
  }
}

// ---------------------------------------------------------------------------
// Listening sockets

static int open_socket(int family, bool loopback, uint16_t port, bool reuse,
                       bool listening, int* error) {
  int fd = socket(family, SOCK_STREAM, 0);
  if (fd < 0) {
    *error = errno;
    return -1;
  }
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
  if (reuse) {
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  }
  int result;
  if (family == AF_INET6) {
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof(one));
    struct sockaddr_in6 address;
    memset(&address, 0, sizeof(address));
    address.sin6_len = sizeof(address);
    address.sin6_family = AF_INET6;
    address.sin6_port = htons(port);
    address.sin6_addr = loopback ? in6addr_loopback : in6addr_any;
    result = bind(fd, (struct sockaddr*)&address, sizeof(address));
  } else {
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(loopback ? INADDR_LOOPBACK : INADDR_ANY);
    result = bind(fd, (struct sockaddr*)&address, sizeof(address));
  }
  if (result == 0 && listening) {
    result = listen(fd, 128);
    if (result == 0) {
      int flags = fcntl(fd, F_GETFL);
      result = flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }
  }
  if (result != 0) {
    *error = errno;
    close(fd);
    return -1;
  }
  return fd;
}

// Binds a loopback listener. SO_REUSEADDR alone would let it share the port
// with another process's wildcard listener and take that listener's loopback
// traffic, while without it the TIME_WAIT connections of a previous run of the
// app keep the port busy for a while. So reuse is used only once a wildcard
// bind shows no other listener covers the port.
static int listen_loopback(int family, uint16_t port, int* error) {
  int fd = open_socket(family, true, port, false, true, error);
  if (fd >= 0 || *error != EADDRINUSE) {
    return fd;
  }
  int probe = open_socket(family, false, port, true, false, error);
  if (probe < 0) {
    *error = EADDRINUSE;
    return -1;
  }
  close(probe);
  return open_socket(family, true, port, true, true, error);
}

static bool ipv6_unavailable(int error) {
  return error == EADDRNOTAVAIL || error == EAFNOSUPPORT ||
         error == EPROTONOSUPPORT;
}

// Binds 127.0.0.1 and ::1 on the same port, from `preferred` upward.
static bool bind_pair(nsdt_relay* relay, uint16_t preferred, int fds[2],
                      uint16_t* bound, char* error, size_t error_size) {
  unsigned port = preferred;
  for (int attempt = 0; attempt < NSDT_PORT_ATTEMPTS && port <= 65535;
       attempt++, port++) {
    int failure = 0;
    int v4 = listen_loopback(AF_INET, (uint16_t)port, &failure);
    if (v4 < 0) {
      if (failure == EADDRINUSE) continue;
      set_error(error, error_size, "127.0.0.1 port %u: %s", port,
                strerror(failure));
      return false;
    }
    int v6 = listen_loopback(AF_INET6, (uint16_t)port, &failure);
    if (v6 < 0) {
      if (failure == EADDRINUSE) {
        close(v4);
        continue;
      }
      if (!ipv6_unavailable(failure)) {
        close(v4);
        set_error(error, error_size, "[::1] port %u: %s", port,
                  strerror(failure));
        return false;
      }
      relay_log(relay,
                "NativeScript dev tunnel for %s: no IPv6 loopback (%s), port "
                "%u on 127.0.0.1 only",
                relay->bundle_id, strerror(failure), port);
    }
    fds[0] = v4;
    fds[1] = v6;
    *bound = (uint16_t)port;
    return true;
  }
  set_error(error, error_size, "ports %u-%u are in use", preferred,
            (unsigned)(port > 65535 ? 65535 : port - 1));
  return false;
}

static void wake_listener(nsdt_relay* relay) {
  char byte = 0;
  ssize_t ignored = write(relay->wake[1], &byte, 1);
  (void)ignored;
}

static void add_listeners_locked(nsdt_relay* relay, const int fds[2],
                                 uint16_t port, int owner) {
  const int families[2] = {AF_INET, AF_INET6};
  for (int i = 0; i < 2; i++) {
    if (fds[i] < 0) continue;
    relay->listeners[relay->listener_count++] = (listener){
        .fd = fds[i], .family = families[i], .port = port, .owner = owner};
  }
}

// ---------------------------------------------------------------------------
// State descriptions

static size_t format_tunnels_locked(nsdt_relay* relay, char separator,
                                    char* out, size_t size) {
  if (relay->tunnel_count == 0) {
    return (size_t)snprintf(out, size, "-");
  }
  size_t length = 0;
  for (size_t i = 0; i < relay->tunnel_count; i++) {
    if (i > 0 && length + 1 < size) {
      out[length++] = separator;
    }
    int written = snprintf(out + length, size - length, "%s=%u",
                           relay->tunnels[i].name, relay->tunnels[i].port);
    if (written < 0 || (size_t)written >= size - length) {
      break;
    }
    length += (size_t)written;
  }
  return length;
}

static void log_listening_locked(nsdt_relay* relay) {
  char tunnels[NSDT_MAX_TUNNELS * (NSDT_MAX_NAME + 8) + 2];
  format_tunnels_locked(relay, ' ', tunnels, sizeof(tunnels));
  relay_log(relay,
            "NativeScript dev tunnel listening for %s: tunnel port %u; %s",
            relay->bundle_id, relay->tunnel_port, tunnels);
}

static void fill_info_locked(nsdt_relay* relay, nsdt_info* info) {
  memset(info, 0, sizeof(*info));
  snprintf(info->bundle_id, sizeof(info->bundle_id), "%s", relay->bundle_id);
  info->pid = (int)getpid();
  info->tunnel_port = relay->tunnel_port;
  info->count = relay->tunnel_count;
  memcpy(info->tunnels, relay->tunnels,
         relay->tunnel_count * sizeof(nsdt_tunnel_entry));
}

// "NSDT/1 READY <bundleId> <pid> <tunnelPort> <tunnels> <nonce> <proof>"
static bool send_ready(nsdt_relay* relay, int fd, const char* nonce,
                       const char* proof) {
  char tunnels[LINE_MAX_BYTES];
  pthread_mutex_lock(&relay->lock);
  format_tunnels_locked(relay, ',', tunnels, sizeof(tunnels));
  uint16_t tunnel_port = relay->tunnel_port;
  pthread_mutex_unlock(&relay->lock);
  return send_line(fd, "NSDT/1 READY %s %d %u %s %s %s", relay->bundle_id,
                   (int)getpid(), tunnel_port, tunnels, nonce, proof);
}

// ---------------------------------------------------------------------------
// Pairing

typedef struct {
  int app_fd;
  int pool_fd;
  atomic_int open_directions;
} splice_pair;

typedef struct {
  splice_pair* pair;
  int from;
  int to;
} splice_direction;

static void* splice_main(void* argument) {
  splice_direction* direction = argument;
  char* buffer = malloc(SPLICE_BUFFER_SIZE);
  for (;;) {
    if (buffer == NULL) {
      shutdown(direction->from, SHUT_RDWR);
      shutdown(direction->to, SHUT_RDWR);
      break;
    }
    ssize_t count = recv(direction->from, buffer, SPLICE_BUFFER_SIZE, 0);
    if (count == 0) {
      // Half-close: the other direction keeps flowing until its own EOF.
      shutdown(direction->to, SHUT_WR);
      break;
    }
    if (count < 0) {
      if (errno == EINTR) continue;
      shutdown(direction->from, SHUT_RDWR);
      shutdown(direction->to, SHUT_RDWR);
      break;
    }
    if (!send_all(direction->to, buffer, (size_t)count)) {
      shutdown(direction->from, SHUT_RDWR);
      shutdown(direction->to, SHUT_RDWR);
      break;
    }
  }
  free(buffer);
  splice_pair* pair = direction->pair;
  free(direction);
  if (atomic_fetch_sub(&pair->open_directions, 1) == 1) {
    close(pair->app_fd);
    close(pair->pool_fd);
    free(pair);
  }
  return NULL;
}

static void start_splice(int app_fd, int pool_fd) {
  splice_pair* pair = malloc(sizeof(splice_pair));
  splice_direction* upstream = malloc(sizeof(splice_direction));
  splice_direction* downstream = malloc(sizeof(splice_direction));
  if (pair == NULL || upstream == NULL || downstream == NULL) {
    free(pair);
    free(upstream);
    free(downstream);
    close(app_fd);
    close(pool_fd);
    return;
  }
  pair->app_fd = app_fd;
  pair->pool_fd = pool_fd;
  atomic_init(&pair->open_directions, 2);
  *upstream = (splice_direction){.pair = pair, .from = app_fd, .to = pool_fd};
  *downstream = (splice_direction){.pair = pair, .from = pool_fd, .to = app_fd};
  if (!spawn_detached(splice_main, upstream)) {
    free(upstream);
    free(downstream);
    free(pair);
    close(app_fd);
    close(pool_fd);
    return;
  }
  if (!spawn_detached(splice_main, downstream)) {
    // The upstream thread owns the pair: closing both ends lets it finish.
    free(downstream);
    atomic_fetch_sub(&pair->open_directions, 1);
    shutdown(app_fd, SHUT_RDWR);
    shutdown(pool_fd, SHUT_RDWR);
  }
}

// An idle pool connection never receives data before it is paired, so
// readability means the host closed it or broke the protocol.
static bool idle_connection_unusable(int fd) {
  struct pollfd poll_fd = {.fd = fd, .events = POLLIN, .revents = 0};
  return poll(&poll_fd, 1, 0) > 0;
}

static void reap_idle_locked(nsdt_relay* relay) {
  size_t kept = 0;
  for (size_t i = 0; i < relay->idle_count; i++) {
    admitted entry = relay->idle[i];
    if (entry.epoch != relay->epoch || idle_connection_unusable(entry.fd)) {
      close(entry.fd);
    } else {
      relay->idle[kept++] = entry;
    }
  }
  relay->idle_count = kept;
}

static void expire_pending_locked(nsdt_relay* relay) {
  uint64_t now = now_ms();
  size_t kept = 0;
  int expired[NSDT_MAX_TUNNELS] = {0};
  for (size_t i = 0; i < relay->pending_count; i++) {
    pending_app entry = relay->pending[i];
    if (now - entry.since_ms >= PENDING_TIMEOUT_MS) {
      close(entry.fd);
      expired[entry.tunnel]++;
    } else {
      relay->pending[kept++] = entry;
    }
  }
  relay->pending_count = kept;
  for (size_t i = 0; i < relay->tunnel_count; i++) {
    if (expired[i] > 0) {
      relay_log(relay,
                "NativeScript dev tunnel for %s: closed %d connection(s) to %s "
                "after %d s without a "
                "tunnel connection; is the device connected and the dev tool "
                "running?",
                relay->bundle_id, expired[i], relay->tunnels[i].name,
                PENDING_TIMEOUT_MS / 1000);
    }
  }
}

static void* pair_main(void* argument) {
  nsdt_relay* relay = argument;
  pthread_mutex_lock(&relay->lock);
  for (;;) {
    reap_idle_locked(relay);
    expire_pending_locked(relay);
    if (relay->pending_count > 0 && relay->idle_count > 0) {
      pending_app app = relay->pending[0];
      memmove(&relay->pending[0], &relay->pending[1],
              (relay->pending_count - 1) * sizeof(pending_app));
      relay->pending_count--;
      // The most recently opened connection is the least likely to be stale.
      int pool_fd = relay->idle[--relay->idle_count].fd;
      char header[LINE_MAX_BYTES];
      snprintf(header, sizeof(header), "NSDT/1 PAIR %s %u %llu\n",
               relay->tunnels[app.tunnel].name, relay->tunnels[app.tunnel].port,
               (unsigned long long)++relay->next_connection_id);
      pthread_mutex_unlock(&relay->lock);
      if (send_all(pool_fd, header, strlen(header))) {
        start_splice(app.fd, pool_fd);
        pthread_mutex_lock(&relay->lock);
        continue;
      }
      close(pool_fd);
      pthread_mutex_lock(&relay->lock);
      if (relay->pending_count < MAX_QUEUE) {
        memmove(&relay->pending[1], &relay->pending[0],
                relay->pending_count * sizeof(pending_app));
        relay->pending[0] = app;
        relay->pending_count++;
      } else {
        close(app.fd);
      }
      continue;
    }
    struct timeval now;
    gettimeofday(&now, NULL);
    struct timespec deadline = {.tv_sec = now.tv_sec + 1,
                                .tv_nsec = (long)now.tv_usec * 1000};
    pthread_cond_timedwait(&relay->changed, &relay->lock, &deadline);
  }
  return NULL;
}

// ---------------------------------------------------------------------------
// Tunnel-port connections

static void drop_unauthenticated_locked(nsdt_relay* relay) {
  reap_idle_locked(relay);
  for (size_t i = 0; i < relay->control_count; i++) {
    if (relay->controls[i].epoch != relay->epoch) {
      // Its thread sees the end of the stream, unregisters and closes it.
      shutdown(relay->controls[i].fd, SHUT_RDWR);
    }
  }
}

static int relay_request(nsdt_relay* relay, const nsdt_tunnel_spec* tunnels,
                         size_t count, uint16_t tunnel_port, const char* token,
                         nsdt_info* info, char* error, size_t error_size,
                         uint64_t required_epoch,
                         enum request_failure* failure);

// `epoch`: the token epoch the connection was admitted under. Once a token is
// configured later, the connection may not do anything more.
static void control_loop(nsdt_relay* relay, int fd, line_reader* reader,
                         uint64_t epoch) {
  char line[LINE_MAX_BYTES];
  for (;;) {
    int length = read_line(reader, fd, 0, line);
    if (length == kLineTooLong) {
      deny(fd, "protocol");
      return;
    }
    if (length < 0) {
      return;
    }
    pthread_mutex_lock(&relay->lock);
    bool current = relay->epoch == epoch;
    pthread_mutex_unlock(&relay->lock);
    if (!current) {
      deny(fd, "auth");
      return;
    }
    char* fields[5];
    int count = split_fields(line, fields, 4);
    if (count >= 2 && strcmp(fields[0], "NSDT/1") == 0 &&
        strcmp(fields[1], "LIST") == 0 && count == 2) {
      if (!send_ready(relay, fd, "-", "-")) return;
      continue;
    }
    if (count == 4 && strcmp(fields[0], "NSDT/1") == 0 &&
        strcmp(fields[1], "OPEN") == 0) {
      uint16_t port = 0;
      if (!valid_name(fields[2])) {
        if (!send_line(fd, "NSDT/1 DENY name")) return;
        continue;
      }
      if (!parse_port(fields[3], &port)) {
        if (!send_line(fd, "NSDT/1 DENY port")) return;
        continue;
      }
      nsdt_tunnel_spec spec = {.name = fields[2], .preferred_port = port};
      nsdt_info info;
      char error[256];
      enum request_failure failure = kFailureNone;
      bool sent;
      if (relay_request(relay, &spec, 1, 0, NULL, &info, error, sizeof(error),
                        epoch, &failure) == 0) {
        uint16_t bound = 0;
        for (size_t i = 0; i < info.count; i++) {
          if (strcmp(info.tunnels[i].name, spec.name) == 0)
            bound = info.tunnels[i].port;
        }
        sent = send_line(fd, "NSDT/1 OPENED %s %u", spec.name, bound);
      } else {
        sent = send_line(fd, "NSDT/1 DENY %s", failure_reason(failure));
      }
      if (!sent || failure == kFailureAuth) return;
      continue;
    }
    deny(fd, "protocol");
    return;
  }
}

typedef struct {
  nsdt_relay* relay;
  int fd;
} handshake_job;

static void* handshake_main(void* argument) {
  handshake_job* job = argument;
  nsdt_relay* relay = job->relay;
  int fd = job->fd;
  free(job);

  line_reader reader = {.length = 0};
  char line[LINE_MAX_BYTES];
  bool control = false;
  bool keep = false;
  uint64_t epoch = 0;

  int length = read_line(&reader, fd, now_ms() + HANDSHAKE_TIMEOUT_MS, line);
  if (length < 0) {
    if (length == kLineTooLong) deny(fd, "protocol");
    goto done;
  }
  {
    char* fields[5];
    int count = split_fields(line, fields, 4);
    if (count < 1 || strcmp(fields[0], "NSDT/1") != 0) {
      deny(fd, strncmp(line, "NSDT/", 5) == 0 ? "version" : "protocol");
      goto done;
    }
    if (count != 4 || strcmp(fields[1], "HELLO") != 0) {
      deny(fd, "protocol");
      goto done;
    }
    if (strcmp(fields[2], "control") == 0) {
      control = true;
    } else if (strcmp(fields[2], "pool") != 0) {
      deny(fd, "role");
      goto done;
    }
    uint8_t host_nonce[MAX_HOST_NONCE_BYTES];
    int host_nonce_length = from_hex(fields[3], host_nonce, sizeof(host_nonce));
    if (host_nonce_length < MIN_HOST_NONCE_BYTES) {
      deny(fd, "nonce");
      goto done;
    }

    char token[NSDT_MAX_TOKEN + 1];
    size_t token_length;
    pthread_mutex_lock(&relay->lock);
    memcpy(token, relay->token, sizeof(token));
    token_length = relay->token_length;
    epoch = relay->epoch;
    pthread_mutex_unlock(&relay->lock);

    uint8_t relay_nonce[NONCE_BYTES];
    if (CCRandomGenerateBytes(relay_nonce, sizeof(relay_nonce)) != kCCSuccess) {
      deny(fd, "internal");
      goto done;
    }
    char relay_nonce_hex[2 * NONCE_BYTES + 1];
    to_hex(relay_nonce, sizeof(relay_nonce), relay_nonce_hex);
    char proof_hex[2 * PROOF_BYTES + 1] = "-";
    if (token_length > 0) {
      uint8_t proof[PROOF_BYTES];
      hmac(token, token_length, host_nonce, (size_t)host_nonce_length, proof);
      to_hex(proof, sizeof(proof), proof_hex);
    }
    if (!send_ready(relay, fd, relay_nonce_hex, proof_hex)) {
      goto done;
    }

    if (token_length > 0) {
      length = read_line(&reader, fd, now_ms() + HANDSHAKE_TIMEOUT_MS, line);
      count = length >= 0 ? split_fields(line, fields, 4) : 0;
      uint8_t answer[PROOF_BYTES];
      uint8_t expected[PROOF_BYTES];
      hmac(token, token_length, relay_nonce, sizeof(relay_nonce), expected);
      bool authenticated =
          count == 3 && strcmp(fields[0], "NSDT/1") == 0 &&
          strcmp(fields[1], "AUTH") == 0 &&
          from_hex(fields[2], answer, sizeof(answer)) == PROOF_BYTES &&
          equal_constant_time(answer, expected, PROOF_BYTES);
      memset(token, 0, sizeof(token));
      if (!authenticated) {
        deny(fd, "auth");
        goto done;
      }
    }
  }

  pthread_mutex_lock(&relay->lock);
  if (relay->epoch != epoch) {
    pthread_mutex_unlock(&relay->lock);
    deny(fd, "auth");
    goto done;
  }
  if (!control) {
    if (reader.length > 0) {
      pthread_mutex_unlock(&relay->lock);
      deny(fd, "protocol");
      goto done;
    }
    if (relay->idle_count < MAX_QUEUE) {
      relay->idle[relay->idle_count++] = (admitted){.fd = fd, .epoch = epoch};
      pthread_cond_broadcast(&relay->changed);
      keep = true;
    }
  } else if (relay->control_count < MAX_CONTROLS) {
    relay->controls[relay->control_count++] =
        (admitted){.fd = fd, .epoch = epoch};
    keep = true;
  }
  relay->handshakes--;
  pthread_mutex_unlock(&relay->lock);
  if (!keep) {
    deny(fd, "busy");
    close(fd);
    return NULL;
  }
  if (control) {
    control_loop(relay, fd, &reader, epoch);
    pthread_mutex_lock(&relay->lock);
    for (size_t i = 0; i < relay->control_count; i++) {
      if (relay->controls[i].fd == fd) {
        relay->controls[i] = relay->controls[--relay->control_count];
        break;
      }
    }
    pthread_mutex_unlock(&relay->lock);
    close(fd);
  }
  return NULL;

done:
  pthread_mutex_lock(&relay->lock);
  relay->handshakes--;
  pthread_mutex_unlock(&relay->lock);
  close(fd);
  return NULL;
}

// ---------------------------------------------------------------------------
// Accepting

static void mark_defunct_locked(nsdt_relay* relay, listener* entry, int error) {
  relay_log(relay,
            "NativeScript dev tunnel for %s: listener on %s port %u failed "
            "(%s); rebinding",
            relay->bundle_id, entry->family == AF_INET6 ? "[::1]" : "127.0.0.1",
            entry->port, strerror(error));
  close(entry->fd);
  entry->fd = -1;
  entry->defunct = true;
  entry->reported_rebind_failure = false;
  entry->next_rebind_ms = 0;
}

static void accept_connections(nsdt_relay* relay, size_t index) {
  pthread_mutex_lock(&relay->lock);
  int listen_fd = relay->listeners[index].fd;
  int owner = relay->listeners[index].owner;
  pthread_mutex_unlock(&relay->lock);
  for (;;) {
    int fd = accept(listen_fd, NULL, NULL);
    if (fd < 0) {
      int error = errno;
      if (error == EINTR || error == ECONNABORTED) continue;
      if (error == EAGAIN || error == EWOULDBLOCK) return;
      if (error == EMFILE || error == ENFILE || error == ENOBUFS ||
          error == ENOMEM) {
        usleep(100 * 1000);
        return;
      }
      pthread_mutex_lock(&relay->lock);
      mark_defunct_locked(relay, &relay->listeners[index], error);
      pthread_mutex_unlock(&relay->lock);
      return;
    }
    configure_connection(fd);
    pthread_mutex_lock(&relay->lock);
    bool accepted = false;
    if (owner == kTunnelPortOwner) {
      if (relay->handshakes < MAX_HANDSHAKES) {
        handshake_job* job = malloc(sizeof(handshake_job));
        if (job != NULL) {
          *job = (handshake_job){.relay = relay, .fd = fd};
          relay->handshakes++;
          if (spawn_detached(handshake_main, job)) {
            accepted = true;
          } else {
            relay->handshakes--;
            free(job);
          }
        }
      }
    } else if (relay->pending_count < MAX_QUEUE) {
      relay->pending[relay->pending_count++] =
          (pending_app){.fd = fd, .tunnel = owner, .since_ms = now_ms()};
      pthread_cond_broadcast(&relay->changed);
      accepted = true;
    }
    pthread_mutex_unlock(&relay->lock);
    if (!accepted) {
      if (owner == kTunnelPortOwner) deny(fd, "busy");
      close(fd);
    }
  }
}

static void* listener_main(void* argument) {
  nsdt_relay* relay = argument;
  struct pollfd fds[MAX_LISTENERS + 1];
  size_t indexes[MAX_LISTENERS + 1];
  for (;;) {
    size_t count = 0;
    bool any_defunct = false;
    fds[count++] =
        (struct pollfd){.fd = relay->wake[0], .events = POLLIN, .revents = 0};
    pthread_mutex_lock(&relay->lock);
    uint64_t now = now_ms();
    for (size_t i = 0; i < relay->listener_count; i++) {
      listener* entry = &relay->listeners[i];
      if (entry->defunct && now >= entry->next_rebind_ms) {
        int error = 0;
        int fd = listen_loopback(entry->family, entry->port, &error);
        if (fd >= 0) {
          entry->fd = fd;
          entry->defunct = false;
          relay_log(
              relay,
              "NativeScript dev tunnel for %s: listening again on %s port %u",
              relay->bundle_id,
              entry->family == AF_INET6 ? "[::1]" : "127.0.0.1", entry->port);
        } else {
          if (!entry->reported_rebind_failure) {
            relay_log(relay,
                      "NativeScript dev tunnel for %s: cannot listen on %s "
                      "port %u again: %s",
                      relay->bundle_id,
                      entry->family == AF_INET6 ? "[::1]" : "127.0.0.1",
                      entry->port, strerror(error));
            entry->reported_rebind_failure = true;
          }
          entry->next_rebind_ms = now + REBIND_INTERVAL_MS;
        }
      }
      if (entry->defunct) {
        any_defunct = true;
        continue;
      }
      indexes[count] = i;
      fds[count++] =
          (struct pollfd){.fd = entry->fd, .events = POLLIN, .revents = 0};
    }
    pthread_mutex_unlock(&relay->lock);

    int ready = poll(fds, (nfds_t)count, any_defunct ? REBIND_INTERVAL_MS : -1);
    if (ready < 0) {
      if (errno != EINTR) usleep(100 * 1000);
      continue;
    }
    if (fds[0].revents != 0) {
      char drain[64];
      while (read(relay->wake[0], drain, sizeof(drain)) > 0) {
      }
    }
    for (size_t k = 1; k < count; k++) {
      short revents = fds[k].revents;
      if (revents == 0) continue;
      if ((revents & POLLIN) == 0) {
        pthread_mutex_lock(&relay->lock);
        mark_defunct_locked(relay, &relay->listeners[indexes[k]],
                            (revents & POLLNVAL) != 0 ? EBADF : EINVAL);
        pthread_mutex_unlock(&relay->lock);
        continue;
      }
      accept_connections(relay, indexes[k]);
    }
  }
  return NULL;
}

// ---------------------------------------------------------------------------
// Requests

static bool start_threads_locked(nsdt_relay* relay) {
  if (!relay->listener_started) {
    relay->listener_started = spawn_detached(listener_main, relay);
  }
  if (!relay->pairing_started) {
    relay->pairing_started = spawn_detached(pair_main, relay);
  }
  return relay->listener_started && relay->pairing_started;
}

static int relay_request(nsdt_relay* relay, const nsdt_tunnel_spec* tunnels,
                         size_t count, uint16_t tunnel_port, const char* token,
                         nsdt_info* info, char* error, size_t error_size,
                         uint64_t required_epoch,
                         enum request_failure* failure) {
  *failure = kFailureNone;
  if (!relay->bundle_id_valid) {
    *failure = kFailureBundle;
    set_error(error, error_size,
              "bundle id '%s' cannot be sent in a protocol line",
              relay->bundle_id);
    return -1;
  }
  for (size_t i = 0; i < count; i++) {
    if (!valid_name(tunnels[i].name)) {
      *failure = kFailureName;
      set_error(
          error, error_size,
          "invalid tunnel name '%s': 1-%d characters from A-Z a-z 0-9 . _ -",
          tunnels[i].name != NULL ? tunnels[i].name : "", NSDT_MAX_NAME);
      return -1;
    }
    if (tunnels[i].preferred_port == 0) {
      *failure = kFailurePort;
      set_error(error, error_size, "tunnel '%s' needs a preferred port",
                tunnels[i].name);
      return -1;
    }
  }
  size_t token_length = token != NULL ? strlen(token) : 0;
  if (token_length > NSDT_MAX_TOKEN) {
    *failure = kFailureToken;
    set_error(error, error_size, "the token is longer than %d bytes",
              NSDT_MAX_TOKEN);
    return -1;
  }

  pthread_mutex_lock(&relay->request_lock);
  int result = 0;
  bool changed = false;

  if (required_epoch != kAnyEpoch) {
    pthread_mutex_lock(&relay->lock);
    bool current = relay->epoch == required_epoch;
    pthread_mutex_unlock(&relay->lock);
    if (!current) {
      *failure = kFailureAuth;
      set_error(error, error_size, "the connection did not authenticate");
      result = -1;
      goto finish;
    }
  }

  if (token_length > 0) {
    pthread_mutex_lock(&relay->lock);
    if (relay->token_length > 0 &&
        (relay->token_length != token_length ||
         memcmp(relay->token, token, token_length) != 0)) {
      pthread_mutex_unlock(&relay->lock);
      *failure = kFailureToken;
      set_error(error, error_size, "a different token is already configured");
      result = -1;
      goto finish;
    }
    if (relay->token_length == 0) {
      memcpy(relay->token, token, token_length);
      relay->token[token_length] = '\0';
      relay->token_length = token_length;
      relay->epoch++;
      drop_unauthenticated_locked(relay);
    }
    pthread_mutex_unlock(&relay->lock);
  }

  if (relay->tunnel_port == 0) {
    pthread_mutex_lock(&relay->lock);
    bool started = start_threads_locked(relay);
    pthread_mutex_unlock(&relay->lock);
    if (!started) {
      *failure = kFailureInternal;
      set_error(error, error_size, "cannot start the relay threads");
      result = -1;
      goto finish;
    }
    uint16_t preferred =
        tunnel_port != 0 ? tunnel_port : NSDT_DEFAULT_TUNNEL_PORT;
    int fds[2];
    uint16_t bound = 0;
    char reason[192];
    if (!bind_pair(relay, preferred, fds, &bound, reason, sizeof(reason))) {
      relay_log(relay,
                "NativeScript dev tunnel for %s: cannot open the tunnel port "
                "(preferred %u): %s",
                relay->bundle_id, preferred, reason);
      *failure = kFailureBind;
      set_error(error, error_size,
                "cannot open the tunnel port (preferred %u): %s", preferred,
                reason);
      result = -1;
      goto finish;
    }
    pthread_mutex_lock(&relay->lock);
    add_listeners_locked(relay, fds, bound, kTunnelPortOwner);
    relay->tunnel_port = bound;
    pthread_mutex_unlock(&relay->lock);
    wake_listener(relay);
    changed = true;
  }

  for (size_t i = 0; i < count; i++) {
    const nsdt_tunnel_spec* spec = &tunnels[i];
    pthread_mutex_lock(&relay->lock);
    bool exists = false;
    for (size_t t = 0; t < relay->tunnel_count; t++) {
      exists = exists || strcmp(relay->tunnels[t].name, spec->name) == 0;
    }
    char current[LINE_MAX_BYTES];
    size_t list_length =
        format_tunnels_locked(relay, ',', current, sizeof(current));
    size_t tunnel_count = relay->tunnel_count;
    pthread_mutex_unlock(&relay->lock);
    if (exists) {
      continue;
    }
    size_t new_length =
        (tunnel_count == 0 ? 0 : list_length + 1) + strlen(spec->name) + 1 + 5;
    if (tunnel_count == NSDT_MAX_TUNNELS ||
        strlen(relay->bundle_id) + new_length > READY_BUDGET) {
      *failure = kFailureFull;
      set_error(error, error_size,
                "cannot add tunnel '%s': the tunnel list would not fit the "
                "%d-byte protocol line",
                spec->name, LINE_MAX_BYTES);
      relay_log(relay, "NativeScript dev tunnel for %s: %s", relay->bundle_id,
                error);
      result = -1;
      goto finish;
    }
    int fds[2];
    uint16_t bound = 0;
    char reason[192];
    if (!bind_pair(relay, spec->preferred_port, fds, &bound, reason,
                   sizeof(reason))) {
      relay_log(relay,
                "NativeScript dev tunnel for %s: cannot open tunnel %s "
                "(preferred %u): %s",
                relay->bundle_id, spec->name, spec->preferred_port, reason);
      *failure = kFailureBind;
      set_error(error, error_size,
                "cannot open tunnel '%s' (preferred port %u): %s", spec->name,
                spec->preferred_port, reason);
      result = -1;
      goto finish;
    }
    pthread_mutex_lock(&relay->lock);
    nsdt_tunnel_entry* entry = &relay->tunnels[relay->tunnel_count];
    snprintf(entry->name, sizeof(entry->name), "%s", spec->name);
    entry->port = bound;
    add_listeners_locked(relay, fds, bound, (int)relay->tunnel_count);
    relay->tunnel_count++;
    pthread_mutex_unlock(&relay->lock);
    wake_listener(relay);
    changed = true;
  }

finish:
  pthread_mutex_lock(&relay->lock);
  if (changed) {
    log_listening_locked(relay);
  }
  if (info != NULL) {
    fill_info_locked(relay, info);
  }
  pthread_mutex_unlock(&relay->lock);
  pthread_mutex_unlock(&relay->request_lock);
  return result;
}

// ---------------------------------------------------------------------------
// Public API

nsdt_relay* nsdt_relay_create(const char* bundle_id, nsdt_log_fn log,
                              void* log_context) {
  nsdt_relay* relay = calloc(1, sizeof(nsdt_relay));
  if (relay == NULL) {
    return NULL;
  }
  if (pipe(relay->wake) != 0) {
    free(relay);
    return NULL;
  }
  for (int i = 0; i < 2; i++) {
    int flags = fcntl(relay->wake[i], F_GETFL);
    fcntl(relay->wake[i], F_SETFL, flags | O_NONBLOCK);
  }
  pthread_mutex_init(&relay->lock, NULL);
  pthread_mutex_init(&relay->request_lock, NULL);
  pthread_cond_init(&relay->changed, NULL);
  snprintf(relay->bundle_id, sizeof(relay->bundle_id), "%s",
           bundle_id != NULL && bundle_id[0] != '\0' ? bundle_id : "unknown");
  relay->bundle_id_valid = bundle_id != NULL &&
                           valid_bundle_id(relay->bundle_id) &&
                           strlen(bundle_id) < sizeof(relay->bundle_id);
  relay->log = log;
  relay->log_context = log_context;
  return relay;
}

int nsdt_relay_request(nsdt_relay* relay, const nsdt_tunnel_spec* tunnels,
                       size_t count, uint16_t tunnel_port, const char* token,
                       nsdt_info* info, char* error, size_t error_size) {
  enum request_failure failure;
  return relay_request(relay, tunnels, count, tunnel_port, token, info, error,
                       error_size, kAnyEpoch, &failure);
}

int nsdt_relay_open_tunnel_port(nsdt_relay* relay, char* error,
                                size_t error_size) {
  pthread_mutex_lock(&relay->lock);
  bool open = relay->tunnel_port != 0;
  if (open) {
    log_listening_locked(relay);
  }
  pthread_mutex_unlock(&relay->lock);
  if (open) {
    return 0;
  }
  return nsdt_relay_request(relay, NULL, 0, 0, NULL, NULL, error, error_size);
}

void nsdt_relay_info(nsdt_relay* relay, nsdt_info* info) {
  pthread_mutex_lock(&relay->lock);
  fill_info_locked(relay, info);
  pthread_mutex_unlock(&relay->lock);
}
