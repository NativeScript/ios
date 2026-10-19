#include "InspectorServer.h"
#include <Foundation/Foundation.h>
#include <netinet/in.h>
#include <sys/socket.h>

#include <atomic>
#include <memory>
#include <mutex>

namespace v8_inspector {

namespace {

std::atomic<uint64_t> gLastConnectionId{0};

struct Connection {
  uint64_t id;
  dispatch_queue_t queue;
  dispatch_io_t channel;
  std::atomic<bool> open{true};
  std::function<void(uint64_t)> onDisconnected;
  std::function<void(const std::string&)> onMessage;
};

void CloseConnection(const std::shared_ptr<Connection>& connection) {
  if (!connection->open.exchange(false)) {
    return;
  }
  dispatch_io_close(connection->channel, DISPATCH_IO_STOP);
  connection->onDisconnected(connection->id);
}

// The functions below take the connection by value: a block captures a C++
// reference as a reference, which would dangle once the caller returns.

// Calls onComplete with exactly `length` bytes, or closes the connection if
// the peer goes away (or errors) first.
void ReadExactly(std::shared_ptr<Connection> connection, size_t length,
                 void (^onComplete)(dispatch_data_t data)) {
  __block dispatch_data_t received = dispatch_data_empty;
  dispatch_io_read(connection->channel, 0, length, connection->queue,
                   ^(bool done, dispatch_data_t data, int error) {
                     if (data != nullptr && dispatch_data_get_size(data) > 0) {
                       received = dispatch_data_create_concat(received, data);
                     }
                     if (!done) {
                       return;
                     }
                     if (error != 0 || dispatch_data_get_size(received) < length) {
                       if (error != 0 && error != ECANCELED) {
                         NSLog(@"InspectorServer read error: %s", strerror(error));
                       }
                       CloseConnection(connection);
                       return;
                     }
                     onComplete(received);
                   });
}

// Messages are a big-endian uint32 byte length followed by UTF-16LE text.
void ReadNextMessage(std::shared_ptr<Connection> connection) {
  ReadExactly(connection, sizeof(uint32_t), ^(dispatch_data_t header) {
    uint32_t length = 0;
    [(NSData*)header getBytes:&length length:sizeof(length)];
    length = ntohl(length);
    if (length == 0) {
      CloseConnection(connection);
      return;
    }

    ReadExactly(connection, length, ^(dispatch_data_t body) {
      NSString* payload = [[NSString alloc] initWithData:(NSData*)body
                                                encoding:NSUTF16LittleEndianStringEncoding];
      const char* utf8 = [payload UTF8String];
      if (utf8 != nullptr) {
        connection->onMessage(utf8);
      }
      ReadNextMessage(connection);
    });
  });
}

void Send(std::shared_ptr<Connection> connection, const std::string& message) {
  if (!connection->open.load()) {
    return;
  }

  NSString* str = [NSString stringWithUTF8String:message.c_str()];
  NSUInteger length = [str lengthOfBytesUsingEncoding:NSUTF16LittleEndianStringEncoding];

  uint8_t* buffer = (uint8_t*)malloc(length + sizeof(uint32_t));

  *(uint32_t*)buffer = htonl(length);

  [str getBytes:&buffer[sizeof(uint32_t)]
           maxLength:length
          usedLength:NULL
            encoding:NSUTF16LittleEndianStringEncoding
             options:0
               range:NSMakeRange(0, str.length)
      remainingRange:NULL];

  dispatch_data_t data =
      dispatch_data_create(buffer, length + sizeof(uint32_t), connection->queue, ^{
        free(buffer);
      });

  dispatch_io_write(connection->channel, 0, data, connection->queue,
                    ^(bool done, dispatch_data_t data, int error) {
                      // ECANCELED: the write was still queued when the
                      // connection closed.
                      if (error == 0 || error == ECANCELED) {
                        return;
                      }
                      NSLog(@"InspectorServer::Send error: %s", strerror(error));
                      CloseConnection(connection);
                    });
}

}  // namespace

in_port_t InspectorServer::Init(
    std::function<void(uint64_t connectionId, Sender sender)> onClientConnected,
    std::function<void(uint64_t connectionId)> onClientDisconnected,
    std::function<void(const std::string&)> onMessage) {
  in_port_t listenPort = 18183;

  int serverSocket = -1;
  if ((serverSocket = socket(PF_INET, SOCK_STREAM, IPPROTO_TCP)) < 0) {
    assert(false);
  }

  struct sockaddr_in serverAddress;
  memset(&serverAddress, 0, sizeof(serverAddress));
  serverAddress.sin_family = AF_INET;
  serverAddress.sin_addr.s_addr = htonl(INADDR_ANY);
  do {
    serverAddress.sin_port = htons(listenPort);
  } while (bind(serverSocket, (struct sockaddr*)&serverAddress, sizeof(serverAddress)) < 0 &&
           ++listenPort);

  // Make the socket non-blocking
  if (fcntl(serverSocket, F_SETFL, O_NONBLOCK) < 0) {
    shutdown(serverSocket, SHUT_RDWR);
    close(serverSocket);
    assert(false);
  }

  struct ActiveConnection {
    std::mutex mutex;
    std::weak_ptr<Connection> connection;
  };
  auto active = std::make_shared<ActiveConnection>();

  // Set up the dispatch source that will alert us to new incoming connections
  dispatch_queue_t q = dispatch_queue_create("server_queue", DISPATCH_QUEUE_CONCURRENT);
  dispatch_source_t acceptSource =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, serverSocket, 0, q);
  dispatch_source_set_event_handler(acceptSource, ^{
    const unsigned long numPendingConnections = dispatch_source_get_data(acceptSource);
    for (unsigned long i = 0; i < numPendingConnections; i++) {
      int clientSocket = -1;
      struct sockaddr_in echoClntAddr;
      unsigned int clntLen = sizeof(echoClntAddr);

      // Wait for a client to connect
      if ((clientSocket = accept(serverSocket, (struct sockaddr*)&echoClntAddr, &clntLen)) < 0) {
        NSLog(@"InspectorServer accept() failed");
        continue;
      }

      // A write racing the peer's close must fail with EPIPE, not kill the app.
      int noSigPipe = 1;
      setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));

      auto connection = std::make_shared<Connection>();
      connection->id = ++gLastConnectionId;
      // Serial, so the read handlers that assemble one message never overlap.
      connection->queue =
          dispatch_queue_create("NativeScript.v8.inspector.connection", DISPATCH_QUEUE_SERIAL);
      connection->onDisconnected = onClientDisconnected;
      connection->onMessage = onMessage;
      connection->channel =
          dispatch_io_create(DISPATCH_IO_STREAM, clientSocket, connection->queue, ^(int error) {
            if (error) {
              NSLog(@"InspectorServer channel cleanup error: %s", strerror(error));
            }
            close(clientSocket);
          });

      if (connection->channel == nullptr) {
        close(clientSocket);
        continue;
      }

      dispatch_async(connection->queue, ^{
        {
          // Held across both callbacks so two clients accepted back to back
          // cannot hand out their senders in the opposite order.
          std::lock_guard<std::mutex> lock(active->mutex);
          std::shared_ptr<Connection> previous = active->connection.lock();
          active->connection = connection;
          if (previous != nullptr) {
            CloseConnection(previous);
          }
          onClientConnected(connection->id, [connection](const std::string& message) {
            Send(connection, message);
          });
        }
        ReadNextMessage(connection);
      });
    }
  });

  // Resume the source so we're ready to accept once we listen()
  dispatch_resume(acceptSource);

  // Listen() on the socket
  if (listen(serverSocket, SOMAXCONN) < 0) {
    shutdown(serverSocket, SHUT_RDWR);
    close(serverSocket);
    assert(false);
  }

  return listenPort;
}

}  // namespace v8_inspector
