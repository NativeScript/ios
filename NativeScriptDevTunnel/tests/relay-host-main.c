// A macOS process standing in for an app that embeds the framework, driven by
// run-host-tests.mjs. It attaches through the same SPI the runtime uses.
//
// Usage: relay-host [--bundle-id <id>] [--release]
// Commands on stdin, one per line; answers on stdout, relay logs on stderr:
//   request <tunnelPort|-> <token|-> [<name>=<port> ...]
//       -> OK <tunnelPort> <name>=<port>,...|-   or   ERROR <message>
//   info -> INFO <bundleId> <tunnelPort> <name>=<port>,...|-
// The process exits when stdin closes.

#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../NativeScript/runtime/DevTunnelSPI.h"

const NSDevTunnelTunnel* NativeScriptDevTunnelConnect(
    const NSDevTunnelHost* host);

static const char* bundle_id_ = "org.nativescript.devtunnel.host";
static bool debug_ = true;

static bool is_debug(void) { return debug_; }

static void log_line(const char* message) {
  fprintf(stderr, "LOG %s\n", message);
  fflush(stderr);
}

static const char* bundle_id(void) { return bundle_id_; }

static const NSDevTunnelHost kHost = {
    .version = NS_DEV_TUNNEL_SPI_VERSION,
    .size = sizeof(NSDevTunnelHost),
    .isDebug = is_debug,
    .log = log_line,
    .bundleId = bundle_id,
};

static void print_tunnels(const NSDevTunnelInfo* info) {
  if (info->count == 0) {
    printf("-");
  }
  for (uint32_t i = 0; i < info->count; i++) {
    printf("%s%s=%u", i == 0 ? "" : ",", info->tunnels[i].name,
           info->tunnels[i].port);
  }
}

static void usage(const char* program) {
  fprintf(stderr, "usage: %s [--bundle-id <id>] [--release]\n", program);
}

int main(int argc, char** argv) {
  static const struct option options[] = {
      {"bundle-id", required_argument, NULL, 'b'},
      {"release", no_argument, NULL, 'r'},
      {"help", no_argument, NULL, 'h'},
      {NULL, 0, NULL, 0},
  };
  int option;
  while ((option = getopt_long(argc, argv, "b:rh", options, NULL)) != -1) {
    switch (option) {
      case 'b':
        bundle_id_ = optarg;
        break;
      case 'r':
        debug_ = false;
        break;
      case 'h':
        usage(argv[0]);
        return 0;
      default:
        usage(argv[0]);
        return 2;
    }
  }

  const NSDevTunnelTunnel* tunnel = NativeScriptDevTunnelConnect(&kHost);
  // A release host gets no table, as the runtime would.
  char line[4096];
  setvbuf(stdout, NULL, _IOLBF, 0);
  while (fgets(line, sizeof(line), stdin) != NULL) {
    line[strcspn(line, "\r\n")] = '\0';
    char* fields[2 + NS_DEV_TUNNEL_MAX_TUNNELS + 1];
    int count = 0;
    for (char* field = strtok(line, " ");
         field != NULL && count < (int)(sizeof(fields) / sizeof(fields[0]));
         field = strtok(NULL, " ")) {
      fields[count++] = field;
    }
    if (count == 0) {
      continue;
    }
    if (tunnel == NULL) {
      printf("ERROR no dev tunnel (release host)\n");
      continue;
    }
    NSDevTunnelInfo info;
    if (strcmp(fields[0], "info") == 0) {
      tunnel->info(&info);
      printf("INFO %s %u ", info.bundleId, info.tunnelPort);
      print_tunnels(&info);
      printf("\n");
      continue;
    }
    if (strcmp(fields[0], "request") == 0 && count >= 3) {
      uint16_t tunnel_port =
          strcmp(fields[1], "-") == 0 ? 0 : (uint16_t)atoi(fields[1]);
      const char* token = strcmp(fields[2], "-") == 0 ? NULL : fields[2];
      NSDevTunnelSpec specs[NS_DEV_TUNNEL_MAX_TUNNELS + 1];
      size_t spec_count = 0;
      for (int i = 3; i < count; i++) {
        char* equals = strchr(fields[i], '=');
        if (equals == NULL) {
          continue;
        }
        *equals = '\0';
        specs[spec_count++] = (NSDevTunnelSpec){
            .name = fields[i], .preferredPort = (uint16_t)atoi(equals + 1)};
      }
      char error[256] = "";
      if (tunnel->request(specs, spec_count, tunnel_port, token, &info, error,
                          sizeof(error))) {
        printf("OK %u ", info.tunnelPort);
        print_tunnels(&info);
        printf("\n");
      } else {
        printf("ERROR %s\n", error);
      }
      continue;
    }
    printf("ERROR unknown command\n");
  }
  return 0;
}
