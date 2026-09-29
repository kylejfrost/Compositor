import Foundation

/// Writes all of `data` to `fileDescriptor` with write(2), retrying partial writes and
/// EINTR. Returns false on any other error (errno is left set). Never raises: unlike
/// `FileHandle.write(_:)`, a closed pipe is just EPIPE (SIGPIPE is ignored in main).
func writeAll(_ data: Data, to fileDescriptor: Int32) -> Bool {
    data.withUnsafeBytes { buffer in
        guard var pointer = buffer.baseAddress else { return true }
        var remaining = buffer.count
        while remaining > 0 {
            let written = Darwin.write(fileDescriptor, pointer, remaining)
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            pointer += written
            remaining -= written
        }
        return true
    }
}

/// Diagnostics, to stderr only: stdout belongs to JSON-RPC.
enum Log {
    /// Best effort: a client that went away usually closed stderr along with stdout, and
    /// a log line must never be what stops the bridge from exiting cleanly.
    static func write(_ message: String) {
        _ = writeAll(Data((message.hasSuffix("\n") ? message : message + "\n").utf8), to: STDERR_FILENO)
    }

    static func info(_ message: String) {
        write("compositor-mcp: \(message)")
    }

    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }
}

/// Writes JSON-RPC messages to stdout, one per line, one at a time.
actor StdoutWriter {
    private let fileDescriptor: Int32

    init(fileDescriptor: Int32 = STDOUT_FILENO) {
        self.fileDescriptor = fileDescriptor
    }

    /// Writes `message` as one line. A JSON value never holds a raw line break (inside a
    /// string it is escaped), so dropping CR and LF bytes turns pretty-printed JSON into a
    /// single line without changing it.
    func write(_ message: Data) {
        var line = message.filter { $0 != 0x0A && $0 != 0x0D }
        guard !line.isEmpty else { return }
        line.append(0x0A)
        if !writeAll(line, to: fileDescriptor) {
            // The client closed our stdout: nobody is left to answer.
            let reason = String(cString: strerror(errno))
            Log.info("stdout closed (\(reason)); exiting")
            BridgeLog.shared.info("exit", ["reason": "stdout_closed", "detail": reason])
            exit(0)
        }
    }
}

/// Lines read from stdin (newline-delimited JSON-RPC), on a thread of their own so a
/// blocking `read` never holds up the concurrency pool. Blank lines are skipped, a
/// trailing CR is dropped, and a last line without a newline still counts. The
/// sequence ends at EOF.
final class StdinLines: AsyncSequence, Sendable {
    typealias Element = Data

    private let stream: AsyncStream<Data>

    init(fileDescriptor: Int32 = STDIN_FILENO) {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        self.stream = stream
        let thread = Thread {
            var pending = Data()
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            func emit(_ line: Data) {
                var line = line
                while let last = line.last, last == 0x0D || last == 0x20 || last == 0x09 { line.removeLast() }
                if line.contains(where: { $0 != 0x20 && $0 != 0x09 }) { continuation.yield(line) }
            }
            while true {
                let count = chunk.withUnsafeMutableBytes { read(fileDescriptor, $0.baseAddress, $0.count) }
                if count < 0 {
                    if errno == EINTR { continue }
                    Log.info("reading stdin failed: \(String(cString: strerror(errno)))")
                    break
                }
                if count == 0 { break }
                // Only the new bytes are searched, so a long line arriving in many chunks
                // costs linear time.
                var start = 0
                for index in 0..<count where chunk[index] == 0x0A {
                    pending.append(contentsOf: chunk[start..<index])
                    emit(pending)
                    pending = Data()
                    start = index + 1
                }
                pending.append(contentsOf: chunk[start..<count])
            }
            if !pending.isEmpty { emit(pending) }
            continuation.finish()
        }
        thread.name = "compositor-mcp.stdin"
        thread.start()
    }

    func makeAsyncIterator() -> AsyncStream<Data>.Iterator {
        stream.makeAsyncIterator()
    }
}

/// What the bridge needs to know about one line from the client.
struct JSONRPCLine {
    /// The ids the client waits on: one for a request, one per request in a batch,
    /// none for notifications and for responses to the server's own requests.
    /// Kept as `JSONSerialization` read them, so a synthesized error echoes a number
    /// as a number and a string as a string.
    let requestIDs: [Any]
    let method: String?
    /// `params.name` of a single `tools/call`, for the log.
    let toolName: String?
    /// The `X-Compositor-Client` value for the `clientInfo` of a single `initialize`.
    let clientHeader: String?
    let isBatch: Bool
    /// The line isn't JSON at all.
    let isUnparsable: Bool
    /// Whether the client waits for anything on stdout: false for notifications and for
    /// responses to the server's own requests (alone or batched), which JSON-RPC never
    /// answers — not even with an error. True for requests and for invalid messages,
    /// which get the server's `"id": null` error.
    let expectsAnswer: Bool

    init(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            requestIDs = []; method = nil; toolName = nil; clientHeader = nil; isBatch = false; isUnparsable = true
            expectsAnswer = true
            return
        }
        isUnparsable = false
        if let batch = json as? [Any] {
            isBatch = true
            method = nil
            toolName = nil
            clientHeader = nil
            requestIDs = batch.compactMap { ($0 as? [String: Any]).flatMap(Self.requestID) }
            expectsAnswer = batch.isEmpty || batch.contains { Self.expectsAnswer($0) }
        } else {
            isBatch = false
            let object = json as? [String: Any]
            method = object?["method"] as? String
            let params = object?["params"] as? [String: Any]
            toolName = method == "tools/call" ? params?["name"] as? String : nil
            let clientInfo = method == "initialize" ? params?["clientInfo"] as? [String: Any] : nil
            clientHeader = (clientInfo?["name"] as? String).flatMap {
                BridgeHeaders.clientValue(name: $0, version: clientInfo?["version"] as? String ?? "")
            }
            requestIDs = object.flatMap(Self.requestID).map { [$0] } ?? []
            expectsAnswer = Self.expectsAnswer(json)
        }
    }

    /// False only for a notification (a method, no `id` member) or a response (no method,
    /// a `result` or an `error`).
    private static func expectsAnswer(_ element: Any) -> Bool {
        guard let object = element as? [String: Any] else { return true }
        if object["method"] is String { return object.keys.contains("id") }
        return object["result"] == nil && object["error"] == nil
    }

    var isInitialize: Bool { method == "initialize" }

    /// A single `tools/call` request (these are forwarded in order, one at a time).
    var isToolCall: Bool { !isBatch && method == "tools/call" && !requestIDs.isEmpty }

    /// The id of a request (a method and a non-null id); nil for anything else.
    private static func requestID(_ object: [String: Any]) -> Any? {
        guard object["method"] is String, let id = object["id"], !(id is NSNull) else { return nil }
        return id
    }

    /// A JSON-RPC error response for `id`, as one line of JSON.
    static func error(id: Any, code: Int, message: String) -> Data {
        let object: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]))
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
    }
}

/// Headers the bridge adds to its POSTs so Compositor's log can say who each call came from (the app's
/// `MCPBridgeHeaders` reads them). Compositor's transport keeps no sessions, and each line goes as a POST of its own,
/// often on another connection than the client's `initialize` came on, so the server can't tell whose call it runs
/// unless the bridge says. They hold the client's own name and version, nothing else, and change nothing but the log.
enum BridgeHeaders {
    /// `bridge`, on every POST.
    static let transport = "X-Compositor-Transport"
    /// `<name>/<version>` from the last `initialize` read, on its POST and every one after it.
    static let client = "X-Compositor-Client"
    /// The longest `X-Compositor-Client` value (the server ignores a longer one).
    static let maxClientLength = 100
    /// The most of it the version may take, so a long version never crowds out the name.
    static let maxVersionLength = 32

    /// `name/version` for `X-Compositor-Client`, each part `encoded` so the `/` between them is the only one and the
    /// whole fits in `maxClientLength`; nil for an empty name.
    static func clientValue(name: String, version: String) -> String? {
        let version = encoded(version, limit: maxVersionLength)
        let name = encoded(name, limit: maxClientLength - 1 - version.utf8.count)
        return name.isEmpty ? nil : "\(name)/\(version)"
    }

    /// `text` with everything but printable ASCII other than `%` and `/` percent-encoded as UTF-8, cut to at most
    /// `limit` characters where a Unicode scalar ends, so never inside an escape.
    static func encoded(_ text: String, limit: Int) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            let piece = (0x21...0x7E).contains(scalar.value) && scalar != "%" && scalar != "/"
                ? String(scalar)
                : String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
            guard result.utf8.count + piece.utf8.count <= limit else { break }
            result += piece
        }
        return result
    }
}

/// Why the bridge couldn't reach Compositor, worded for the client's user.
struct UnreachableError: Error {
    let reason: String
}

/// POSTs JSON-RPC bodies to an endpoint. Plain URLSession: no MCP SDK.
struct HTTPPoster: Sendable {
    struct Response: Sendable {
        let status: Int
        let contentType: String
        let body: Data
    }

    /// How long a POST may wait for its answer. A tool call holds its POST open while it
    /// waits its turn in Compositor's queue and runs, so this is generous.
    static let requestTimeout: TimeInterval = 600

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        // Loopback only: never route through a system proxy.
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.requestTimeout
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    /// POSTs `body`, with `Authorization: Bearer <token>` when there is a `token`, and the bridge's own headers
    /// (`BridgeHeaders`): `X-Compositor-Transport` always, `X-Compositor-Client` when there is a `client`.
    func post(_ body: Data, to url: URL, token: String?, protocolVersion: String?, client: String? = nil,
              timeout: TimeInterval = requestTimeout) async throws -> Response {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let protocolVersion {
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        request.setValue("bridge", forHTTPHeaderField: BridgeHeaders.transport)
        if let client {
            request.setValue(client, forHTTPHeaderField: BridgeHeaders.client)
        }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        return Response(status: http?.statusCode ?? 0,
                        contentType: http?.value(forHTTPHeaderField: "Content-Type") ?? "",
                        body: data)
    }

    /// Whether a connection error means the request never reached a server (so sending
    /// it again elsewhere can't run it twice).
    static func neverDelivered(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }
}

/// The negotiated protocol version, set by the answer to `initialize`, and the client that sent it.
private actor SessionState {
    var protocolVersion: String?
    /// The `X-Compositor-Client` value of the last `initialize` read from stdin.
    var client: String?

    func setProtocolVersion(_ version: String) {
        protocolVersion = version
    }

    func setClient(_ value: String) {
        client = value
    }
}

/// The stdio ⇄ HTTP pump.
struct Bridge: Sendable {
    let resolver: EndpointResolver
    let writer: StdoutWriter
    let http: HTTPPoster
    private let state = SessionState()

    init(resolver: EndpointResolver, writer: StdoutWriter, http: HTTPPoster) {
        self.resolver = resolver
        self.writer = writer
        self.http = http
    }

    /// Forwards lines as they arrive and returns at EOF once every forwarded line has
    /// been answered.
    ///
    /// `tools/call` requests go one at a time, in stdin order: a client may send
    /// dependent calls (`new_document`, then `add_blank_layer`) without waiting for each
    /// answer, and concurrent POSTs could reach Compositor in any order. Compositor runs
    /// tool calls one at a time anyway, so this costs no throughput. Everything else
    /// (`ping`, `tools/list`, `initialize`, notifications) goes at once, so a long tool
    /// call never holds it up.
    ///
    /// The client an `initialize` names is remembered as the line is read, before anything is
    /// forwarded, so every line read after it names that client to Compositor however the
    /// POSTs overtake one another.
    func run(_ input: StdinLines) async {
        let (toolCalls, toolCallQueue) = AsyncStream.makeStream(of: Data.self)
        await withDiscardingTaskGroup { group in
            group.addTask {
                for await line in toolCalls { await forward(line) }
            }
            for await line in input {
                let message = JSONRPCLine(line)
                if let client = message.clientHeader { await state.setClient(client) }
                if message.isToolCall {
                    toolCallQueue.yield(line)
                } else {
                    group.addTask { await forward(line) }
                }
            }
            toolCallQueue.finish()
        }
    }

    /// One line from the client: POST it and write what the client should see.
    ///
    /// Requests get exactly one line back — the server's answer, or a JSON-RPC error on
    /// the same id when Compositor can't be reached. Notifications (answered 202) and
    /// responses to the server get nothing. A batch is forwarded as is.
    func forward(_ line: Data) async {
        let message = JSONRPCLine(line)
        if message.isUnparsable {
            // JSON-RPC's answer to invalid JSON; no reason to wake Compositor for it.
            await writer.write(JSONRPCLine.error(id: NSNull(), code: -32700, message: "Parse error: the line is not JSON"))
            return
        }
        let started = ContinuousClock.now
        do {
            let response = try await post(line, message: message)
            await relay(response, for: message)
            BridgeLog.shared.forwarded(message, bytes: line.count, response: response, startedAt: started)
        } catch let problem as AccessToken.Problem {
            BridgeLog.shared.unreachable(message, reason: problem.message, startedAt: started)
            if message.requestIDs.isEmpty {
                Log.info("dropped \(message.method ?? "a message"): \(problem.message)")
            }
            await writeErrors(for: message, code: -32000, text: problem.message)
        } catch {
            let reason = (error as? UnreachableError)?.reason ?? error.localizedDescription
            BridgeLog.shared.unreachable(message, reason: reason, startedAt: started)
            if message.requestIDs.isEmpty {
                Log.info("dropped \(message.method ?? "a message"): Compositor is not reachable: \(reason)")
            }
            await writeErrors(for: message, code: -32000, text: "Compositor is not reachable: \(reason)")
        }
    }

    /// POSTs to the current endpoint, with its access token, read afresh each time so a
    /// regenerated token is used at once. When nothing listens there any more (Compositor
    /// quit, or restarted on another port) the endpoint is looked up again — launching
    /// Compositor if allowed — and the line is sent once more: a refused connection never
    /// delivered it. So is a line refused with 401, which the server answers before running
    /// anything: the token requirement may have been turned on, or the token file moved,
    /// since the endpoint was found.
    private func post(_ line: Data, message: JSONRPCLine) async throws -> HTTPPoster.Response {
        let version = message.isInitialize ? nil : await state.protocolVersion
        let client = await state.client
        var endpoint = try await resolver.endpoint()
        var lookedAgainForAnswer = false, lookedAgainForToken = false
        while true {
            let token = try endpoint.tokenFile.map(AccessToken.read)
            let response: HTTPPoster.Response
            do {
                response = try await http.post(line, to: endpoint.url, token: token, protocolVersion: version, client: client)
            } catch where HTTPPoster.neverDelivered(error) && !lookedAgainForAnswer {
                lookedAgainForAnswer = true
                Log.info("\(endpoint.url.absoluteString) stopped answering; looking for Compositor again")
                BridgeLog.shared.notice("connection_failed", ["url": endpoint.url.absoluteString,
                                                              "error": error.localizedDescription, "retrying": true])
                await resolver.invalidate(endpoint)
                endpoint = try await resolver.endpoint()
                continue
            } catch {
                BridgeLog.shared.warning("connection_failed", ["url": endpoint.url.absoluteString,
                                                               "error": error.localizedDescription, "retrying": false])
                await resolver.invalidate(endpoint)
                throw UnreachableError(reason: error.localizedDescription)
            }
            if response.status == 401 && !lookedAgainForToken {
                lookedAgainForToken = true
                Log.info("\(endpoint.url.absoluteString) refused the access token; reading the endpoint file again")
                BridgeLog.shared.notice("retry_401", ["url": endpoint.url.absoluteString, "method": message.method ?? "batch"])
                await resolver.invalidate(endpoint)
                endpoint = try await resolver.endpoint()
                continue
            }
            return response
        }
    }

    private func relay(_ response: HTTPPoster.Response, for message: JSONRPCLine) async {
        if response.status == 401 {
            // Refused before anything ran, even after looking the endpoint up again.
            let text = "Compositor refused the request (HTTP 401): \(AccessToken.refusedHint)"
            if message.requestIDs.isEmpty { Log.info("\(message.method ?? "a message") refused: \(text)") }
            await writeErrors(for: message, code: -32000, text: text)
            return
        }
        let messages = Self.messages(in: response)
        guard message.expectsAnswer else {
            // Notifications and responses are never answered on stdout, even when the
            // server refused them (its `"id": null` error would match nothing the client sent).
            if !(200..<300).contains(response.status) || !messages.isEmpty {
                let text = String(decoding: response.body.prefix(300), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                Log.info("\(message.method ?? (message.isBatch ? "batch" : "message")) refused: HTTP \(response.status) \(text)")
            }
            return
        }
        if message.isBatch, !message.requestIDs.isEmpty,
           !(messages.count == 1 && Self.isJSONArray(messages[0])) {
            // The server didn't answer the batch as a batch — the app's stateless transport
            // refuses batches with one `"id": null` error. Every request in it still gets its
            // own answer, as an array (JSON-RPC's reply to a batch).
            let details = messages.first.flatMap(Self.errorDetails)
            await writeErrors(for: message, code: details?.code ?? -32603,
                              text: details?.message ?? "Compositor's MCP server answered the batch with HTTP \(response.status)")
            return
        }
        if messages.isEmpty {
            if (200..<300).contains(response.status) {
                await writeErrors(for: message, code: -32603, text: "Compositor's MCP server sent no answer")
            } else {
                let text = String(decoding: response.body.prefix(200), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if message.requestIDs.isEmpty {
                    Log.info("\(message.method ?? "message") refused: HTTP \(response.status) \(text)")
                }
                await writeErrors(for: message, code: -32603,
                                  text: "Compositor's MCP server answered HTTP \(response.status)\(text.isEmpty ? "" : ": \(text)")")
            }
            return
        }
        for var reply in messages {
            if message.isInitialize, let version = Self.negotiatedVersion(in: reply) {
                await state.setProtocolVersion(version)
            }
            if !message.isBatch, let id = message.requestIDs.first {
                reply = Self.withID(id, ifMissingIn: reply)
            }
            await writer.write(reply)
        }
    }

    /// Synthesized errors, one per request id: a single response for a request, an array
    /// for a batch. Nothing for notifications.
    private func writeErrors(for message: JSONRPCLine, code: Int, text: String) async {
        guard !message.requestIDs.isEmpty else { return }
        if message.isBatch {
            let errors = message.requestIDs.compactMap {
                try? JSONSerialization.jsonObject(with: JSONRPCLine.error(id: $0, code: code, message: text))
            }
            if let data = try? JSONSerialization.data(withJSONObject: errors, options: [.withoutEscapingSlashes]) {
                await writer.write(data)
            }
        } else if let id = message.requestIDs.first {
            await writer.write(JSONRPCLine.error(id: id, code: code, message: text))
        }
    }

    /// The JSON-RPC messages in an HTTP answer: the JSON body, or each `data:` payload of
    /// a `text/event-stream` body. Empty for 202 and for anything that isn't JSON.
    static func messages(in response: HTTPPoster.Response) -> [Data] {
        guard !response.body.isEmpty else { return [] }
        if response.contentType.lowercased().hasPrefix("text/event-stream") {
            return serverSentEventPayloads(response.body).filter(isJSON)
        }
        return isJSON(response.body) ? [response.body] : []
    }

    private static func isJSON(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func isJSONArray(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) is [Any]
    }

    /// The code and message of a JSON-RPC error response.
    private static func errorDetails(in reply: Data) -> (code: Int, message: String)? {
        let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
        guard let error = object?["error"] as? [String: Any], let code = error["code"] as? Int else { return nil }
        return (code, error["message"] as? String ?? "Compositor's MCP server refused the batch")
    }

    /// The data of each event in an SSE body (multi-line `data:` fields joined by LF).
    static func serverSentEventPayloads(_ body: Data) -> [Data] {
        let text = String(decoding: body, as: UTF8.self)
        var payloads: [Data] = []
        var current: [Substring] = []
        func flush() {
            if !current.isEmpty { payloads.append(Data(current.joined(separator: "\n").utf8)) }
            current = []
        }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("data:") {
                var value = line.dropFirst("data:".count)
                if value.hasPrefix(" ") { value = value.dropFirst() }
                current.append(value)
            }
        }
        flush()
        return payloads
    }

    /// The protocol version an `initialize` result agreed on.
    private static func negotiatedVersion(in reply: Data) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
        return (object?["result"] as? [String: Any])?["protocolVersion"] as? String
    }

    /// An error the server sent before it read the request's id (HTTP-level validation
    /// answers with `"id": null`) is handed back on the request's id, so the client can
    /// match it. Anything that already carries an id is left byte for byte.
    private static func withID(_ id: Any, ifMissingIn reply: Data) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              object["error"] != nil, object["id"] == nil || object["id"] is NSNull
        else { return reply }
        object["id"] = id
        return (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? reply
    }
}
