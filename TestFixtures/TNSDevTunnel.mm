#import "TNSDevTunnel.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <notify.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <string>

#include "runtime/DevTunnel.h"

namespace {

NSString* ToNSString(const std::string& value) {
  return [NSString stringWithUTF8String:value.c_str()];
}

std::string Describe(const tns::devtunnel::TunnelInfo& info) {
  std::string tunnels;
  for (const tns::devtunnel::Tunnel& tunnel : info.tunnels) {
    tunnels += (tunnels.empty() ? "" : ",") + tunnel.name + "=" + std::to_string(tunnel.port);
  }
  return std::to_string(info.tunnelPort) + " " + (tunnels.empty() ? "-" : tunnels);
}

class Socket {
 public:
  ~Socket() {
    if (fd_ >= 0) close(fd_);
  }

  bool Connect(int port) {
    fd_ = socket(AF_INET, SOCK_STREAM, 0);
    if (fd_ < 0) return false;
    int one = 1;
    setsockopt(fd_, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    struct timeval timeout = {.tv_sec = 5, .tv_usec = 0};
    setsockopt(fd_, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd_, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    struct sockaddr_in address = {};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(static_cast<uint16_t>(port));
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    return connect(fd_, reinterpret_cast<struct sockaddr*>(&address), sizeof(address)) == 0;
  }

  bool Send(const std::string& data) {
    size_t sent = 0;
    while (sent < data.size()) {
      ssize_t count = send(fd_, data.data() + sent, data.size() - sent, 0);
      if (count <= 0) return false;
      sent += static_cast<size_t>(count);
    }
    return true;
  }

  bool ReadLine(std::string* line) {
    line->clear();
    for (;;) {
      char c;
      if (recv(fd_, &c, 1, 0) != 1) return false;
      if (c == '\n') return true;
      *line += c;
    }
  }

  bool ReadExactly(size_t size, std::string* data) {
    data->assign(size, '\0');
    size_t received = 0;
    while (received < size) {
      ssize_t count = recv(fd_, &(*data)[received], size - received, 0);
      if (count <= 0) return false;
      received += static_cast<size_t>(count);
    }
    return true;
  }

 private:
  int fd_ = -1;
};

const char* kHello = "NSDT/1 HELLO %s 00112233445566778899aabbccddeeff\n";

bool Hello(Socket& socket, const char* role, std::string* ready) {
  char hello[128];
  snprintf(hello, sizeof(hello), kHello, role);
  return socket.Send(hello) && socket.ReadLine(ready) && ready->rfind("NSDT/1 READY ", 0) == 0;
}

NSString* Error(const std::string& message) { return ToNSString("ERROR " + message); }

}  // namespace

bool TNSDevTunnelAvailable(void) { return tns::devtunnel::DevTunnelAvailable(); }

NSString* TNSDevTunnelInfo(void) {
  std::optional<tns::devtunnel::TunnelInfo> info = tns::devtunnel::Info();
  return info.has_value() ? ToNSString(info->bundleId + " " + Describe(*info)) : @"";
}

NSString* TNSDevTunnelRequest(NSString* spec, int tunnelPort, NSString* token) {
  std::vector<tns::devtunnel::TunnelRequest> tunnels;
  for (NSString* entry in [spec componentsSeparatedByString:@","]) {
    NSArray<NSString*>* parts = [entry componentsSeparatedByString:@"="];
    if (parts.count == 2) {
      tunnels.push_back({parts[0].UTF8String, static_cast<uint16_t>(parts[1].intValue)});
    }
  }
  std::optional<uint16_t> port;
  if (tunnelPort > 0) port = static_cast<uint16_t>(tunnelPort);
  std::optional<std::string> secret;
  if (token != nil) secret = std::string(token.UTF8String);
  tns::devtunnel::RequestResult result = tns::devtunnel::Request(tunnels, port, secret);
  if (!result.info.has_value()) return Error(result.error);
  return ToNSString("OK " + Describe(*result.info));
}

void TNSDevTunnelPostTunnelRequest(void) {
  NSString* name = [NSString stringWithFormat:@"%@:NativeScript.Debug.TunnelRequest",
                                              [[NSBundle mainBundle] bundleIdentifier]];
  notify_post(name.UTF8String);
}

NSString* TNSDevTunnelControl(int tunnelPort, NSString* command) {
  Socket socket;
  std::string ready;
  if (!socket.Connect(tunnelPort) || !Hello(socket, "control", &ready)) {
    return Error("no READY on the tunnel port");
  }
  if (command.length == 0) return ToNSString(ready);
  std::string answer;
  if (!socket.Send(std::string(command.UTF8String) + "\n") || !socket.ReadLine(&answer)) {
    return Error("no answer to " + std::string(command.UTF8String));
  }
  return ToNSString(ready + "\n" + answer);
}

NSString* TNSDevTunnelRoundTrip(int tunnelPort, int appPort, NSString* payload) {
  std::string sent = payload.UTF8String;
  Socket pool;
  std::string ready;
  if (!pool.Connect(tunnelPort) || !Hello(pool, "pool", &ready)) {
    return Error("no READY for the pool connection");
  }
  Socket app;
  if (!app.Connect(appPort) || !app.Send(sent)) {
    return Error("cannot reach the app-side port");
  }
  std::string pair;
  std::string received;
  if (!pool.ReadLine(&pair) || !pool.ReadExactly(sent.size(), &received)) {
    return Error("the pool connection was not paired");
  }
  std::string reply = "echo:" + received;
  std::string answer;
  if (!pool.Send(reply) || !app.ReadExactly(reply.size(), &answer)) {
    return Error("the reply did not reach the app");
  }
  return ToNSString(pair + "|" + received + "|" + answer);
}
