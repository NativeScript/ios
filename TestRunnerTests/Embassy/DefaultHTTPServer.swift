//
//  DefaultHTTPServer.swift
//  Embassy
//
//  Created by Fang-Pen Lin on 5/19/16.
//  Copyright © 2016 Fang-Pen Lin. All rights reserved.
//

import Foundation
import Dispatch

public final class DefaultHTTPServer: HTTPServer {
    public let logger = DefaultLogger()
    public var app: SWSGI

    /// Interface of TCP/IP to bind
    public let interface: String
    /// Port of TCP/IP to bind
    public let port: Int

    // the socket for accepting incoming connections
    private var acceptSocket: TCPSocket!
    private let eventLoop: EventLoop
    private var connections = Set<HTTPConnection>()

    public init(
        eventLoop: EventLoop,
        interface: String = "::1",
        port: Int = 0,
        app: @escaping SWSGI
    ) {
        self.eventLoop = eventLoop
        self.app = app
        self.interface = interface
        self.port = port
    }

    deinit {
        stop()
    }

    public var listenAddress: (host: String, port: Int) {
        return try! acceptSocket.getSockName()
    }

    public func start() throws {
        guard acceptSocket == nil else {
            logger.error("Server already started")
            return
        }
        logger.info("Starting HTTP server on [\(interface)]:\(port) ...")
        acceptSocket = try TCPSocket()
        try acceptSocket.bind(port: port, interface: interface)
        try acceptSocket.listen()
        eventLoop.setReader(acceptSocket.fileDescriptor) { [unowned self] in
            self.handleNewConnection()
        }
        logger.info("HTTP server running")
    }

    public func stop() {
        guard acceptSocket != nil else {
            logger.error("Server not started")
            return
        }
        eventLoop.removeReader(acceptSocket.fileDescriptor)
        acceptSocket.close()
        for connection in connections {
            connection.close()
        }
        connections = []
        logger.info("HTTP server stopped")
    }

    public func stopAndWait() {
        let semaphore = DispatchSemaphore(value: 0)
        eventLoop.call {
            self.stop()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: DispatchTime.distantFuture)
    }

    // called to handle new connections
    private func handleNewConnection() {
        // Resilience: a single bad inbound connection must NEVER crash the server.
        // This server runs inside the XCUITest runner; a fatal error here aborts
        // the entire run ("Executed 0 tests"). A client can reset/close in the
        // window between accept() and getPeerName() — common with rapid
        // fire-and-forget requests — which surfaces as OSError (EINVAL/ENOTCONN);
        // accept() itself can also transiently fail under connection churn. Drop
        // the offending connection instead of `try!`-trapping the whole process.
        let clientSocket: TCPSocket
        do {
            clientSocket = try acceptSocket.accept()
        } catch {
            logger.error("accept() failed; dropping inbound connection: \(error)")
            return
        }

        let address: String
        let port: Int
        do {
            (address, port) = try clientSocket.getPeerName()
        } catch {
            logger.error("getPeerName() failed; closing inbound connection: \(error)")
            clientSocket.close()
            return
        }

        let transport = Transport(socket: clientSocket, eventLoop: eventLoop)
        let connection = HTTPConnection(
            app: appForConnection,
            serverName: "[\(interface)]",
            serverPort: self.port,
            transport: transport,
            eventLoop: eventLoop,
            logger: logger
        )
        connections.insert(connection)
        connection.closedCallback = { [unowned self] in
            self.connections.remove(connection)
        }
        logger.info("New connection \(connection.uuid) from [\(address)]:\(port)")
    }

    private func appForConnection(
        _ environ: [String: Any],
        startResponse: @escaping ((String, [(String, String)]) -> Void),
        sendBody: @escaping ((Data) -> Void)
    ) {
        app(environ, startResponse, sendBody)
    }

}
