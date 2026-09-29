import Foundation
import Network
import MCP
import Synchronization

/// Answers one HTTP request. Called off the main actor, once per request, possibly
/// for several connections at the same time.
typealias MCPHTTPHandler = @Sendable (HTTPRequest) async -> HTTPResponse

/// Counts listeners that are bound and not yet stopped. `MCPServer` gives one to
/// every listener it creates, so tests can prove a superseded start leaves nothing
/// bound behind.
nonisolated final class MCPListenerCounter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    fileprivate func add(_ delta: Int) { count.withLock { $0 += delta } }
}

/// A tiny HTTP/1.1 server bound to the loopback interface that bridges MCP's
/// framework-agnostic `HTTPRequest`/`HTTPResponse` types to raw sockets over
/// Network.framework.
///
/// The official SDK ships its example HTTP host on swift-nio; this app deliberately
/// keeps its dependency count to the core `MCP` library, so the listener and the
/// HTTP/1.1 parser live here (no NIO). It only speaks plain request/response: the
/// stateless MCP transport never streams.
///
/// Thread safety: `@unchecked Sendable` because every mutable property is confined
/// to `queue`, a serial queue. Network.framework delivers all listener and connection
/// callbacks on it, and the public entry points (`start`, `stop`) hop onto it first.
nonisolated final class MCPHTTPListener: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.compositor.mcp.http", qos: .userInitiated,
                              target: .global(qos: .userInitiated))
    private let handler: MCPHTTPHandler
    private let onFailure: @Sendable (String) -> Void
    private let maxRequestBytes: Int
    private let maxConnections: Int
    private let requestTimeout: DispatchTimeInterval
    private let counter: MCPListenerCounter?
    private let gate: MCPAccessGate?
    /// Where refused requests are logged (`MCPHTTPLog`).
    private let log: CompositorLog

    // Confined to `queue`.
    private var listener: NWListener?
    /// The current `listener` became ready and is included in `counter`.
    private var counted = false
    private var connections: [ObjectIdentifier: MCPHTTPConnection] = [:]
    private var readiness: CheckedContinuation<UInt16, any Error>?

    /// - Parameters:
    ///   - gate: the access token requests must carry, checked from each request's head
    ///     before its body is read; nil lets every request through.
    ///   - handler: answers each parsed request.
    ///   - onFailure: called (on the listener's queue) if the listener fails after it
    ///     became ready; failures before that are thrown from `start`.
    init(maxRequestBytes: Int = 32 * 1024 * 1024, maxConnections: Int = 32, requestTimeout: DispatchTimeInterval = .seconds(30),
         counter: MCPListenerCounter? = nil, gate: MCPAccessGate? = nil, log: CompositorLog = .shared,
         handler: @escaping MCPHTTPHandler, onFailure: @escaping @Sendable (String) -> Void) {
        self.maxRequestBytes = maxRequestBytes
        self.maxConnections = maxConnections
        self.requestTimeout = requestTimeout
        self.counter = counter
        self.gate = gate
        self.log = log
        self.handler = handler
        self.onFailure = onFailure
    }

    /// Whether `start` failed because the port is already taken — the one failure that
    /// makes `MCPServer` fall back from its preferred port to an ephemeral one.
    static func isAddressInUse(_ error: any Error) -> Bool {
        if let error = error as? NWError, case .posix(.EADDRINUSE) = error { return true }
        if let error = error as? POSIXError, error.code == .EADDRINUSE { return true }
        return false
    }

    /// Binds `port` on the loopback interface (0 picks a free port) and returns the
    /// bound port once the listener is ready to accept connections. A taken port
    /// throws `EADDRINUSE` (see `isAddressInUse`).
    func start(port: UInt16) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { self.begin(port: port, continuation) }
        }
    }

    /// Stops listening and closes every open connection. Safe to call repeatedly.
    func stop() {
        queue.async {
            if let readiness = self.readiness {
                self.readiness = nil
                readiness.resume(throwing: CancellationError())
            }
            self.cancelListener()
            let active = Array(self.connections.values)
            self.connections.removeAll()
            for connection in active { connection.close() }
        }
    }

    // MARK: - Queue-confined

    private func begin(port: UInt16, _ continuation: CheckedContinuation<UInt16, any Error>) {
        guard listener == nil, readiness == nil else {
            continuation.resume(throwing: POSIXError(.EALREADY))
            return
        }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        // SO_REUSEADDR only: lets the stable port be bound again at once after a restart,
        // while connections from the last run linger in TIME_WAIT. It does not let two
        // listeners share a port — a port another process (or a second Compositor) listens
        // on still fails with EADDRINUSE, which is what triggers the ephemeral fallback
        // (MCPEndpointFileTests prove this against NWListener and BSD-socket holders).
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        // Bound to 127.0.0.1 itself, not the wildcard address with a loopback-only
        // interface filter: `lsof` then shows exactly what is reachable (127.0.0.1:<port>),
        // and nothing depends on the interface filter alone.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            continuation.resume(throwing: error)
            return
        }
        readiness = continuation
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, listener === self.listener else { return }
            self.listenerStateChanged(state)
        }
        listener.start(queue: queue)
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            if !counted {
                counted = true
                counter?.add(1)
            }
            if let readiness {
                self.readiness = nil
                readiness.resume(returning: listener?.port?.rawValue ?? 0)
            }
        case .failed(let error), .waiting(let error):
            if let readiness {
                // Could not bind (typically the port is taken): report it to `start`.
                self.readiness = nil
                cancelListener()
                readiness.resume(throwing: error)
            } else if case .failed = state {
                onFailure("\(error)")
            }
        default:
            break
        }
    }

    private func cancelListener() {
        listener?.cancel()
        listener = nil
        if counted {
            counted = false
            counter?.add(-1)
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < maxConnections else {
            refuse(connection)
            return
        }
        let handler = MCPHTTPConnection(connection: connection, listener: self, gate: gate, handler: handler,
                                        maxRequestBytes: maxRequestBytes, requestTimeout: requestTimeout, queue: queue, log: log)
        connections[ObjectIdentifier(handler)] = handler
        handler.start()
    }

    /// Answers a connection past `maxConnections` with 503 and closes it within `refusalGrace`: every open socket
    /// holds a file descriptor, and the app needs those to open and save files (a GUI app gets 256). The answer ends
    /// the connection's sending side; what the client sent is read and dropped until it closes too, since closing
    /// with its bytes unread would reset the connection before it read the answer.
    private func refuse(_ connection: NWConnection) {
        MCPHTTPLog.refused(503, peer: "\(connection.endpoint)", connection: nil, detail: "too many connections", log: log)
        connection.start(queue: queue)
        connection.send(content: MCPHTTPConnection.plainResponse(status: 503, text: "too many connections"),
                        contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        @Sendable func drain() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, isComplete, error in
                if isComplete || error != nil { connection.cancel() } else { drain() }
            }
        }
        drain()
        queue.asyncAfter(deadline: .now() + Self.refusalGrace) { connection.cancel() }
    }

    /// How long a refused connection may take to read its 503 and close.
    static let refusalGrace: DispatchTimeInterval = .seconds(1)

    /// Forgets a closed connection. Called on `queue`.
    fileprivate func remove(_ connection: MCPHTTPConnection) {
        connections[ObjectIdentifier(connection)] = nil
    }
}

// MARK: - Per-connection handler

/// One keep-alive HTTP/1.1 connection: parses requests off the socket and answers
/// them strictly in order, one at a time.
///
/// Thread safety: `@unchecked Sendable` because every mutable property is confined
/// to the listener's serial `queue`. The only work done elsewhere is awaiting the
/// request handler, whose result hops back with `queue.async`.
nonisolated final class MCPHTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private weak var listener: MCPHTTPListener?
    private let gate: MCPAccessGate?
    private let handler: MCPHTTPHandler
    private let queue: DispatchQueue
    private let maxRequestBytes: Int
    private let requestTimeout: DispatchTimeInterval
    private let log: CompositorLog
    /// This connection's number and client address, for the log.
    private let context: MCPConnectionContext

    // Confined to `queue`.
    private var buffer = Data()
    private var closed = false
    /// A receive is outstanding.
    private var receiving = false
    /// The client finished sending (read side at EOF).
    private var peerFinished = false
    /// A request is being handled; the next one waits in `buffer`.
    private var busy = false
    private var sentContinue = false
    private var idleTimer: DispatchWorkItem?
    /// Runs from a request's first byte until it has arrived whole (`requestTimeout`).
    private var requestTimer: DispatchWorkItem?

    /// A connection with no request in flight is closed after this long without traffic.
    /// A long tool call never times out: the timer is off while a request is handled.
    static let idleTimeout: DispatchTimeInterval = .seconds(120)
    /// The longest request head read: the blank line ending it must come within this many bytes. Heads are a few
    /// hundred bytes, and the bound keeps each search for the blank line short however much is buffered.
    static let maxHeadBytes = 64 * 1024

    init(connection: NWConnection, listener: MCPHTTPListener, gate: MCPAccessGate?, handler: @escaping MCPHTTPHandler,
         maxRequestBytes: Int, requestTimeout: DispatchTimeInterval, queue: DispatchQueue, log: CompositorLog = .shared) {
        self.log = log
        context = MCPConnectionContext(id: MCPConnectionContext.nextID(), peer: "\(connection.endpoint)")
        self.maxRequestBytes = maxRequestBytes
        self.requestTimeout = requestTimeout
        self.connection = connection
        self.listener = listener
        self.gate = gate
        self.handler = handler
        self.queue = queue
    }

    /// Called on `queue`.
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        armIdleTimer()
        receiveMore()
    }

    /// Closes the connection now. Called on `queue`.
    func close() {
        guard !closed else { return }
        closed = true
        disarmIdleTimer()
        disarmRequestTimer()
        listener?.remove(self)
        connection.cancel()
    }

    // MARK: - Reading

    private func receiveMore() {
        guard !closed, !receiving, !peerFinished else { return }
        receiving = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.receiving = false
            if error != nil {
                self.close()
                return
            }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if !self.busy { self.armIdleTimer() }
            }
            if isComplete { self.peerFinished = true }
            self.processBuffer()
            if self.peerFinished, !self.busy { self.close() }
            self.receiveMore()
        }
    }

    /// Enforces the size limit on whatever has arrived, then starts handling the
    /// next complete request in the buffer, if idle.
    private func processBuffer() {
        guard !closed else { return }
        // Checked even while a request is in flight: reading continues then, so bytes
        // piling up behind it must not grow the buffer without bound.
        if buffer.count > maxRequestBytes + 65536 {
            refused(413)
            sendFinal(Self.plainResponse(status: 413, text: "request too large"))
            return
        }
        let head: RequestHead
        switch Self.parseHead(in: buffer) {
        case .incomplete:
            guard !busy else { return }
            if buffer.count > Self.maxHeadBytes {
                refused(431)
                sendFinal(Self.plainResponse(status: 431, text: "request head too large"))
                return
            }
            if !buffer.isEmpty { armRequestTimer() }
            return
        case .refused(let status, let reason):
            // Refused once the request ahead of it is answered, which closing now would lose.
            guard !busy else { return }
            refused(status, detail: reason)
            sendFinal(Self.plainResponse(status: status, text: reason))
            return
        case .complete(let parsed):
            head = parsed
        }
        if head.contentLength > maxRequestBytes {
            refused(413)
            sendFinal(Self.plainResponse(status: 413, text: "request too large"))
            return
        }
        guard !busy else { return }
        // The access token, from the head alone: a caller without it is answered before its body is read (or
        // invited with 100-continue), so nothing it sends is parsed or handed to the MCP transport.
        if let gate, !gate.permits(head.headers["authorization"]) {
            // Whether a credential came at all, never what it was.
            refused(401, authHeader: head.headers["authorization"] == nil ? "missing" : "wrong")
            refuseUnread(Self.unauthorizedResponse)
            return
        }
        // A header block with a body still on the way: answer 100-continue once.
        if !sentContinue, head.headers["expect"]?.lowercased() == "100-continue" {
            sentContinue = true
            send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }
        let bodyEnd = head.bodyStart + head.contentLength
        guard buffer.endIndex >= bodyEnd else {
            armRequestTimer()
            return
        }
        let body = head.contentLength > 0 ? Data(buffer[head.bodyStart..<bodyEnd]) : nil
        buffer.removeSubrange(..<bodyEnd)
        sentContinue = false
        busy = true
        disarmIdleTimer()
        disarmRequestTimer()
        let request = HTTPRequest(method: head.method, headers: head.headers, body: body, path: head.path)
        let closeAfter = head.closeAfterResponse
        let handler = self.handler
        let context = self.context
        Task {
            // The router logs each request with its connection, and names the client that connection initialized.
            let response = await MCPConnectionContext.$current.withValue(context) { await handler(request) }
            self.queue.async { self.respond(response, closeAfter: closeAfter) }
        }
    }

    private func respond(_ response: HTTPResponse, closeAfter: Bool) {
        busy = false
        // The transport's own checks (Origin, Host, Accept, Content-Type, method) answer 4xx before any JSON-RPC runs.
        if response.statusCode >= 400 { refused(response.statusCode) }
        guard !closed else { return }
        let closing = closeAfter || peerFinished
        let data = Self.serialize(response, closing: closing)
        if closing {
            sendFinal(data)
            return
        }
        send(data)
        armIdleTimer()
        processBuffer()
        receiveMore()
    }

    // MARK: - Writing

    private func send(_ data: Data) {
        connection.send(content: data, contentContext: .defaultMessage, isComplete: false,
                        completion: .contentProcessed { _ in })
    }

    /// Sends the last bytes of the response and closes the connection once the
    /// stack has finished with them. Cancelling right after `send` would discard
    /// bytes that are still queued for flushing — which truncated responses at
    /// unpredictable points. Note: `.finalMessage`/`isComplete: true` must NOT be used
    /// here — verified (nw-repro) that a final-message send after default-message
    /// sends is silently dropped, never processed, and so never cancels.
    private func sendFinal(_ data: Data) {
        guard !closed else { return }
        closed = true
        disarmIdleTimer()
        disarmRequestTimer()
        listener?.remove(self)
        let connection = self.connection
        connection.send(content: data, contentContext: .defaultMessage, isComplete: false,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Answers `data` and closes the connection without reading the rest of the request: whatever the client still
    /// sends (a body it didn't wait to be invited for) is read and dropped until it closes its side, for at most
    /// `MCPHTTPListener.refusalGrace`, since closing with its bytes unread would reset the connection before it read
    /// the answer. Default-message sends, as in `sendFinal`: an answer on a connection that already sent others.
    private func refuseUnread(_ data: Data) {
        guard !closed else { return }
        closed = true
        disarmIdleTimer()
        disarmRequestTimer()
        listener?.remove(self)
        buffer = Data()
        let connection = self.connection
        connection.send(content: data, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { _ in })
        @Sendable func drain() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, isComplete, error in
                if isComplete || error != nil { connection.cancel() } else { drain() }
            }
        }
        drain()
        queue.asyncAfter(deadline: .now() + MCPHTTPListener.refusalGrace) { connection.cancel() }
    }

    /// 401 for a request without the access token: a JSON-RPC error (`"id": null`, as for every refusal before the
    /// JSON-RPC layer) with the Bearer challenge, closing the connection.
    static let unauthorizedResponse: Data = serialize(
        .error(statusCode: 401,
               .invalidRequest("Unauthorized: send Compositor's access token as Authorization: Bearer <token> (Compositor's Settings window copies it; the compositor-mcp bridge sends it itself)"),
               extraHeaders: [HTTPHeaderName.wwwAuthenticate: #"Bearer realm="Compositor""#]),
        closing: true)

    private static func serialize(_ response: HTTPResponse, closing: Bool) -> Data {
        var response = response
        if case .stream = response {
            // The stateless transport never streams; refuse rather than hang the client.
            response = .error(statusCode: 500, .internalError("Streaming responses are not supported"))
        }
        let body = response.bodyData
        var headers = response.headers
        if headers["Content-Type"] == nil {
            headers["Content-Type"] = body == nil ? "text/plain" : "application/json"
        }
        headers["Content-Length"] = String(body?.count ?? 0)
        if closing { headers["Connection"] = "close" }
        var data = Data(headString(status: response.statusCode, headers: headers).utf8)
        if let body { data.append(body) }
        return data
    }

    fileprivate static func plainResponse(status: Int, text: String) -> Data {
        let body = Data(text.utf8)
        var data = Data(headString(status: status, headers: [
            "Content-Type": "text/plain",
            "Content-Length": String(body.count),
            "Connection": "close",
        ]).utf8)
        data.append(body)
        return data
    }

    private static func headString(status: Int, headers: [String: String]) -> String {
        var head = "HTTP/1.1 \(status) \(reason(status))\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        return head + "\r\n"
    }

    // MARK: - Idle timeout

    private func armIdleTimer() {
        idleTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self, !self.busy else { return }
            self.close()
        }
        idleTimer = timer
        queue.asyncAfter(deadline: .now() + Self.idleTimeout, execute: timer)
    }

    private func disarmIdleTimer() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    /// Starts the clock on the request whose first bytes are in the buffer, unless it's already running: the
    /// request must arrive whole within `requestTimeout`, however its bytes trickle in (each re-arms the idle timer).
    private func armRequestTimer() {
        guard requestTimer == nil else { return }
        let timer = DispatchWorkItem { [weak self] in
            guard let self, !self.busy else { return }
            self.refused(408)
            self.sendFinal(Self.plainResponse(status: 408, text: "request not received in time"))
        }
        requestTimer = timer
        queue.asyncAfter(deadline: .now() + requestTimeout, execute: timer)
    }

    private func disarmRequestTimer() {
        requestTimer?.cancel()
        requestTimer = nil
    }

    /// Logs a refusal of this connection's request (`MCPHTTPLog`): the status and client, never a header's value.
    private func refused(_ status: Int, detail: String? = nil, authHeader: String? = nil) {
        MCPHTTPLog.refused(status, peer: context.peer, connection: context.id, detail: detail, authHeader: authHeader, log: log)
    }

    // MARK: - HTTP/1.1 parsing

    /// A request's head: its request line and headers, up to the blank line that ends them.
    private struct RequestHead {
        let method: String
        let path: String
        let headers: [String: String]
        /// Where the body begins: just past the blank line.
        let bodyStart: Data.Index
        /// The body's length in bytes: never negative.
        let contentLength: Int
        let closeAfterResponse: Bool
    }

    private enum HeadParse {
        /// The blank line ending the head hasn't arrived yet.
        case incomplete
        /// The head can't be served as sent: answer `status` and close.
        case refused(status: Int, reason: String)
        case complete(RequestHead)
    }

    /// Reads the head at the start of `buffer`. The body's length comes only from Content-Length, as plain ASCII
    /// digits: a sign, a list or two values that disagree can't frame it (and a negative length once crashed the
    /// app), and a Transfer-Encoding body isn't read at all, so each is refused rather than guessed at.
    private static func parseHead(in buffer: Data) -> HeadParse {
        // Only as far as the longest head: past it, `processBuffer` answers 431 instead of searching further.
        let searched = buffer.startIndex..<min(buffer.endIndex, buffer.startIndex + maxHeadBytes + 4)
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8), in: searched) else { return .incomplete }
        guard let text = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .refused(status: 400, reason: "the request head isn't UTF-8 text")
        }
        var lines = text.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 3, parts[2].hasPrefix("HTTP/") else {
            return .refused(status: 400, reason: "malformed request line")
        }
        var headers: [String: String] = [:]
        var lengths: Set<String> = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" { lengths.insert(value) }
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil {
            return .refused(status: 501, reason: "Transfer-Encoding is not supported; send the body with a Content-Length")
        }
        var contentLength = 0
        if let length = lengths.first {
            guard lengths.count == 1, !length.isEmpty, length.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else {
                return .refused(status: 400, reason: "Content-Length must be one number of bytes")
            }
            // Digits too many for an Int are a length past any limit.
            contentLength = Int(length) ?? Int.max
        }
        let version = parts[2]
        let connection = headers["connection"]?.lowercased() ?? ""
        let closeAfterResponse = version.hasPrefix("HTTP/1.0") ? !connection.contains("keep-alive") : connection.contains("close")
        return .complete(RequestHead(method: String(parts[0]), path: String(parts[1]), headers: headers,
                                     bodyStart: end.upperBound, contentLength: contentLength,
                                     closeAfterResponse: closeAfterResponse))
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 408: "Request Timeout"
        case 413: "Payload Too Large"
        case 415: "Unsupported Media Type"
        case 421: "Misdirected Request"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        default: ""
        }
    }
}
