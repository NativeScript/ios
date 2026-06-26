//
//  Transport.swift
//  Embassy
//
//  Created by Fang-Pen Lin on 5/21/16.
//  Copyright © 2016 Fang-Pen Lin. All rights reserved.
//

import Foundation

public final class Transport {
    enum CloseReason {
        /// Connection closed by peer
        case byPeer
        /// Connection closed by ourselve
        case byLocal

        var isByPeer: Bool {
            if case .byPeer = self {
                return true
            }
            return false
        }

        var isByLocal: Bool {
            if case .byLocal = self {
                return true
            }
            return false
        }
    }

    /// Size for recv
    static let recvChunkSize = 1024

    /// Is this transport closed or not
    private(set) var closed: Bool = false
    /// Is this transport closing
    private(set) var closing: Bool = false
    var closedCallback: ((CloseReason) -> Void)?
    var readDataCallback: ((Data) -> Void)?

    private let socket: TCPSocket
    private let eventLoop: EventLoop
    // buffer for sending data out
    private var outgoingBuffer = Data()
    // is reading enabled or not
    private var reading: Bool = true

    init(
        socket: TCPSocket,
        eventLoop: EventLoop,
        closedCallback: ((CloseReason) -> Void)? = nil,
        readDataCallback: ((Data) -> Void)? = nil
    ) {
        socket.ignoreSigPipe = true
        self.socket = socket
        self.eventLoop = eventLoop
        self.closedCallback = closedCallback
        self.readDataCallback = readDataCallback
        eventLoop.setReader(socket.fileDescriptor, callback: handleRead)
    }

    deinit {
        eventLoop.removeReader(socket.fileDescriptor)
        eventLoop.removeWriter(socket.fileDescriptor)
    }

    /// Send data to peer (append in buffer and will be sent out later)
    ///  - Parameter data: data to send
    func write(data: Data) {
        // ensure we are not closed nor closing
        guard !closed && !closing else {
            // TODO: or raise error?
            return
        }
        // TODO: more efficient way to handle the outgoing buffer?
        outgoingBuffer.append(data)
        handleWrite()
    }

    /// Send string with UTF8 encoding to peer
    ///  - Parameter string: string to send as UTF8
    func write(string: String) {
        write(data: Data(string.utf8))
    }

    /// Flush outgoing data and close the transport
    func close() {
        // ensure we are not closed nor closing
        guard !closed && !closing else {
            // TODO: or raise error?
            return
        }
        closing = true
        handleWrite()
    }

    func resume(reading: Bool) {
        // switch from not-reading to reading
        if reading && !self.reading {
            // call handle read later to check is there data available for reading
            eventLoop.call {
                self.handleRead()
            }
        }
        self.reading = reading
    }

    private func closedByPeer() {
        closed = true
        eventLoop.removeReader(socket.fileDescriptor)
        eventLoop.removeWriter(socket.fileDescriptor)
        if let callback = closedCallback {
            callback(.byPeer)
        }
        socket.close()
    }

    private func handleRead() {
        // ensure we are not closed
        guard !closed else {
            return
        }
        guard reading else {
            return
        }
        var data: Data!
        do {
            data = try socket.recv(size: Transport.recvChunkSize)
        } catch OSError.ioError(let number, _) {
            guard number != EAGAIN else {
                // if it's EAGAIN, it means no data to be read for now, just return
                // (usually means that this function was called by resumeReading)
                return
            }
            // NativeScript test harness: do NOT fatalError. This server runs in
            // the XCUITest runner, where a trap aborts the whole run ("Executed
            // 0 tests"). A half-closed client socket (e.g. the runtime's
            // NSURLConnection module loader) makes recv() fail with
            // ECONNRESET/ENOTCONN/EINVAL — tear the connection down like a peer
            // close instead of crashing the runner.
            closedByPeer()
            return
        } catch {
            closedByPeer()
            return
        }
        guard data.count > 0 else {
            closedByPeer()
            return
        }
        // ensure we are not closing
        guard !closing else {
            return
        }
        if let callback = readDataCallback {
            callback(data)
        }
    }

    private func handleWrite() {
        // ensure we are not closed
        guard !closed else {
            return
        }
        // ensure we have something to write
        guard outgoingBuffer.count > 0 else {
            if closing {
                closed = true
                eventLoop.removeWriter(socket.fileDescriptor)
                eventLoop.removeReader(socket.fileDescriptor)
                if let callback = closedCallback {
                    callback(.byLocal)
                }
                socket.close()
            }
            return
        }
        do {
            let sentBytes = try socket.send(data: outgoingBuffer)
            outgoingBuffer.removeFirst(sentBytes)
            if outgoingBuffer.count > 0 {
                // Not all was written; register write handler.
                eventLoop.setWriter(socket.fileDescriptor, callback: handleWrite)
            } else {
                eventLoop.removeWriter(socket.fileDescriptor)
                if closing {
                    closed = true
                    eventLoop.removeReader(socket.fileDescriptor)
                    if let callback = closedCallback {
                        callback(.byLocal)
                    }
                    socket.close()
                }
            }
        } catch let OSError.ioError(number, _) {
            switch number {
            case EAGAIN:
                break
            // Apparently on macOS EPROTOTYPE can be returned when the socket is not
            // fully shutdown (as an EPIPE would indicate). Here we treat them
            // essentially the same since we just tear the transport down anyway.
            // http://erickt.github.io/blog/2014/11/19/adventures-in-debugging-a-potential-osx-kernel-bug/
            case EPROTOTYPE:
                fallthrough
            case EPIPE:
                closedByPeer()

            default:
                // NativeScript test harness: do NOT fatalError (it would abort
                // the XCUITest runner -> "Executed 0 tests"). Any other send()
                // failure on a half-dead client socket just means the peer is
                // gone; tear the connection down instead of crashing.
                closedByPeer()
            }
        } catch {
            closedByPeer()
        }
    }
}
