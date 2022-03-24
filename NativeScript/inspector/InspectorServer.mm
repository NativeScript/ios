#include "InspectorServer.h"
#include <Foundation/Foundation.h>
#include <netinet/in.h>
#include <sys/socket.h>

namespace v8_inspector {

in_port_t InspectorServer::Init(std::function<void (std::function<void (std::string)>)> onClientConnected, std::function<void (std::string)> onMessage) {
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
    } while (bind(serverSocket, (struct sockaddr *) &serverAddress, sizeof(serverAddress)) < 0 && ++listenPort);

    // Make the socket non-blocking
    if (fcntl(serverSocket, F_SETFL, O_NONBLOCK) < 0) {
        shutdown(serverSocket, SHUT_RDWR);
        close(serverSocket);
        assert(false);
    }

    // Set up the dispatch source that will alert us to new incoming connections
    dispatch_queue_t q = dispatch_queue_create("server_queue", DISPATCH_QUEUE_CONCURRENT);
    dispatch_source_t acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, serverSocket, 0, q);
    dispatch_source_set_event_handler(acceptSource, ^{
        const unsigned long numPendingConnections = dispatch_source_get_data(acceptSource);
        for (unsigned long i = 0; i < numPendingConnections; i++) {
            int clientSocket = -1;
            struct sockaddr_in echoClntAddr;
            unsigned int clntLen = sizeof(echoClntAddr);

            // Wait for a client to connect
            if ((clientSocket = accept(serverSocket, (struct sockaddr *) &echoClntAddr, &clntLen)) >= 0) {
                dispatch_io_t channel = dispatch_io_create(DISPATCH_IO_STREAM, clientSocket, q, ^(int error) {
                    if (error) {
                        NSLog(@"Error: %s", strerror(error));
                    }
                    close(clientSocket);
                });

                onClientConnected([channel, q](std::string message) {
                    Send(channel, q, message);
                });

                __block dispatch_io_handler_t receiver = ^(bool done, dispatch_data_t data, int error) {
                    if (error) {
                        NSLog(@"Error: %s", strerror(error));
                    }

                    const void* bytes = [(NSData*)data bytes];
                    if (!bytes) {
                        return;
                    }

                    uint32_t length = ntohl(*(uint32_t*)bytes);

                    // Configure the channel...
                    dispatch_io_set_low_water(channel, length);

                    // Setup read handler
                    dispatch_io_read(channel, 0, length, q, ^(bool done, dispatch_data_t data, int error) {
                        BOOL close = NO;
                        if (error) {
                            NSLog(@"Error: %s", strerror(error));
                            close = YES;
                        }

                        const size_t size = data ? dispatch_data_get_size(data) : 0;
                        if (size) {
                            NSString* payload = [[NSString alloc] initWithData:(NSData*)data encoding:NSUTF16LittleEndianStringEncoding];

                            onMessage([payload UTF8String]);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
                            dispatch_io_read(channel, 0, 4, q, receiver);
#pragma clang diagnostic pop
                        } else {
                            close = YES;
                        }

                        if (close) {
                            dispatch_io_close(channel, DISPATCH_IO_STOP);
                        }
                    });
                };

                if (channel) {
                    dispatch_io_read(channel, 0, 4, q, receiver);
                }
            }
            else {
                NSLog(@"accept() failed;\n");
            }
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

void InspectorServer::Send(dispatch_io_t channel, dispatch_queue_t queue, std::string message) {
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

    dispatch_data_t data = dispatch_data_create(buffer, length + sizeof(uint32_t), queue, ^{
        free(buffer);
    });

    dispatch_io_write(channel, 0, data, queue, ^(bool done, dispatch_data_t data, int error) {
        if (error) {
            NSLog(@"Error: %s", strerror(error));
        }
    });
}

}
