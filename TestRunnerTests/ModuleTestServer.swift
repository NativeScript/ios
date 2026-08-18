import Foundation
import Network

/// Body reader with the same shape Embassy's SWSGI input had: call it with a
/// chunk callback; the callback receives the body then an empty Data as EOF.
typealias ModuleTestServerInput = (@escaping (Data) -> Void) -> Void

/// Minimal loopback HTTP/1.1 server for the runtime test suite, built on
/// Network.framework so request handling rides ordinary GCD instead of a
/// vendored selector event loop. It exists to answer exactly two clients —
/// the runtime's module loader (NSURLSession + the synchronous NSURLConnection
/// fallback) and the Jasmine reporter — so the HTTP surface is deliberately
/// small: one request per connection, full body buffered before dispatch,
/// `Connection: close` on every response.
final class ModuleTestServer {
    typealias StartResponse = (String, [(String, String)]) -> Void
    typealias SendBody = (Data) -> Void
    typealias Handler = ([String: Any], @escaping StartResponse, @escaping SendBody) -> Void

    private let listener: NWListener
    private let queue = DispatchQueue(label: "org.nativescript.TestRunner.ModuleTestServer")
    private let handler: Handler
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(port: UInt16, handler: @escaping Handler) throws {
        self.handler = handler
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
    }

    func start() {
        listener.start(queue: queue)
    }

    func stop() {
        queue.sync {
            for connection in connections.values {
                connection.cancel()
            }
            connections.removeAll()
        }
        listener.cancel()
    }

    // All connection work runs on `queue`.

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections.removeValue(forKey: ObjectIdentifier(connection))
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(connection, buffered: Data())
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buffer = buffered
            if let data = data {
                buffer.append(data)
            }
            if error != nil {
                connection.cancel()
                return
            }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
                let bodySoFar = buffer.subdata(in: headerEnd.upperBound..<buffer.endIndex)
                guard let head = ParsedRequestHead(headerData) else {
                    self.respondAndClose(connection, status: "400 Bad Request",
                                         headers: [], body: Data())
                    return
                }
                self.receiveBody(connection, head: head, body: bodySoFar)
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.receive(connection, buffered: buffer)
        }
    }

    private func receiveBody(_ connection: NWConnection, head: ParsedRequestHead, body: Data) {
        if body.count >= head.contentLength {
            dispatch(connection, head: head, body: body)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var body = body
            if let data = data {
                body.append(data)
            }
            if error != nil || (isComplete && body.count < head.contentLength) {
                connection.cancel()
                return
            }
            self.receiveBody(connection, head: head, body: body)
        }
    }

    private func dispatch(_ connection: NWConnection, head: ParsedRequestHead, body: Data) {
        let input: ModuleTestServerInput = { deliver in
            deliver(body)
            deliver(Data())
        }
        let environ: [String: Any] = [
            "REQUEST_METHOD": head.method,
            "PATH_INFO": head.path,
            "QUERY_STRING": head.query,
            "swsgi.input": input,
        ]

        // The handler may respond later from another queue (the delayed
        // timeout.mjs route), so the response closures are thread-safe and
        // single-shot.
        let responseLock = NSLock()
        var status = "200 OK"
        var headers: [(String, String)] = []
        var sent = false

        let startResponse: StartResponse = { s, h in
            responseLock.lock()
            status = s
            headers = h
            responseLock.unlock()
        }
        let sendBody: SendBody = { [weak self] data in
            responseLock.lock()
            let alreadySent = sent
            sent = true
            let responseStatus = status
            let responseHeaders = headers
            responseLock.unlock()
            if alreadySent {
                return
            }
            self?.queue.async {
                self?.respondAndClose(connection, status: responseStatus,
                                      headers: responseHeaders, body: data)
            }
        }

        handler(environ, startResponse, sendBody)
    }

    private func respondAndClose(_ connection: NWConnection, status: String,
                                 headers: [(String, String)], body: Data) {
        var response = "HTTP/1.1 \(status)\r\n"
        for (name, value) in headers {
            response += "\(name): \(value)\r\n"
        }
        response += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(response.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private struct ParsedRequestHead {
    let method: String
    let path: String
    let query: String
    let contentLength: Int

    init?(_ headerData: Data) {
        guard let text = String(data: headerData, encoding: .utf8) else {
            return nil
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return nil
        }
        method = String(parts[0])
        let target = String(parts[1])
        if let queryStart = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<queryStart])
            query = String(target[target.index(after: queryStart)...])
        } else {
            path = target
            query = ""
        }
        var length = 0
        for line in lines.dropFirst() {
            let lowered = line.lowercased()
            if lowered.hasPrefix("content-length:") {
                length = Int(line.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        contentLength = length
    }
}
