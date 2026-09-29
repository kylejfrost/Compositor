import Foundation
import MCP
import Synchronization

// What the MCP server records in the diagnostic log (`CompositorLog`, docs/logging.md). The hooks in the server,
// the HTTP listener, the request router and the tool registry each call one function here, so the event shapes live
// in one place.

// MARK: - Tool calls

/// Logs each tool call as one `tool_call` event, and each step of a run_batch as a `batch_step` event under it.
@MainActor
enum MCPCallLog {
    /// The id of the call running in this task, so run_batch can name its steps' batch.
    @TaskLocal static var callID: String?

    /// Runs `body` (the call itself) and logs it: the tool, a summary of its arguments, how long it waited and ran,
    /// how it ended (the error's code, guard and message, or the undo step it recorded) and how big its result was.
    /// Read-only calls list their arguments' names only, unless the log is verbose.
    static func record(_ tool: String, _ args: [String: Value], _ body: () async -> CallTool.Result) async -> CallTool.Result {
        let log = CompositorLog.active
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let origin = MCPCallOrigin.current
        let started = ContinuousClock.now
        let result = await $callID.withValue(id) { await body() }
        let readOnly = MCPToolRegistry.entriesByName[tool]?.tool.annotations.readOnlyHint == true
        let outcome = Outcome(result)
        log.log(outcome.level, .mcp, "tool_call", {
            var fields: [String: LogValue] = [
                "call": .string(id),
                "tool": .string(tool),
                "args": readOnly && !log.isVerbose ? .array(args.keys.sorted().map(LogValue.string)) : summary(args),
                "duration_ms": .milliseconds(since: started),
                "result_bytes": .int(outcome.bytes),
                "images": .int(outcome.images),
            ]
            fields.merge(outcome.fields) { _, new in new }
            if let origin { fields.merge(origin.fields(startedAt: started)) { _, new in new } }
            return fields
        }())
        return result
    }

    /// Logs step `index` of the batch running in this task.
    static func batchStep(_ index: Int, tool: String, arguments: [String: Value], startedAt started: ContinuousClock.Instant,
                          failure: MCPToolError?) {
        let log = CompositorLog.active
        log.log(failure == nil ? .info : .notice, .mcp, "batch_step", {
            var fields: [String: LogValue] = [
                "batch": .text(callID),
                "step": .int(index),
                "tool": .string(tool),
                "args": summary(arguments),
                "duration_ms": .milliseconds(since: started),
                "outcome": .string(failure == nil ? "ok" : "error"),
            ]
            if let failure { fields["error"] = errorFields(failure.value) }
            return fields
        }())
    }

    /// The arguments as the log shows them: `LogEncoding` then cuts, redacts and summarizes their values.
    static func summary(_ args: [String: Value]) -> LogValue {
        .object(args.mapValues(LogValue.init(mcp:)))
    }

    /// `{code, message, guard, detail}` from a result's `error` object.
    static func errorFields(_ error: Value?) -> LogValue {
        let object = error?.objectValue ?? [:]
        var fields: [String: LogValue] = [
            "code": .text(object["code"]?.stringValue),
            "message": .text(object["message"]?.stringValue),
        ]
        if let guardName = object["guard"]?.stringValue { fields["guard"] = .string(guardName) }
        if let detail = object["details"]?.objectValue?["code"]?.stringValue { fields["detail"] = .string(detail) }
        return .object(fields)
    }

    /// How a call ended, read from its result.
    private struct Outcome {
        var level: CompositorLog.Level = .info
        var fields: [String: LogValue] = [:]
        var bytes = 0
        var images = 0

        init(_ result: CallTool.Result) {
            for content in result.content {
                switch content {
                case .text(let text, _, _): bytes += text.utf8.count
                case .image(let data, _, _, _):
                    bytes += data.utf8.count
                    images += 1
                case .audio(let data, _, _, _): bytes += data.utf8.count
                default: break
                }
            }
            let structured = result.structuredContent?.objectValue ?? [:]
            if result.isError == true {
                fields["outcome"] = "error"
                fields["error"] = errorFields(structured["error"])
                // A tool refusing a call is the normal course of an agent's work; an internal error is a bug.
                level = structured["error"]?.objectValue?["code"]?.stringValue == MCPErrorCode.internalError.rawValue
                    ? .error : .notice
            } else {
                fields["outcome"] = "ok"
            }
            if let undo = structured["undo"]?.objectValue {
                fields["undo"] = .object(["name": .text(undo["name"]?.stringValue),
                                          "recorded": undo["recorded"].map(LogValue.init(mcp:)) ?? .null])
            }
        }
    }
}

nonisolated extension LogValue {
    /// An MCP value as a log value; binary data as its size.
    init(mcp value: Value) {
        switch value {
        case .null: self = .null
        case .bool(let flag): self = .bool(flag)
        case .int(let number): self = .int(number)
        case .double(let number): self = .double(number)
        case .string(let text): self = .string(text)
        case .data(let mimeType, let data): self = .string("[binary \(data.count) bytes \(mimeType ?? "")]")
        case .array(let items): self = .array(items.map(LogValue.init(mcp:)))
        case .object(let members): self = .object(members.mapValues(LogValue.init(mcp:)))
        }
    }
}

// MARK: - Where a call came from

/// The HTTP request a tool call arrived on: its connection, the client that sent it (named by the bridge, else the
/// one that initialized that connection), the JSON-RPC id the client gave it, and when it arrived (so the log can
/// tell waiting in the queue from running).
nonisolated struct MCPCallOrigin: Sendable {
    /// Set by the server around each call it runs.
    @TaskLocal static var current: MCPCallOrigin?

    var connection: Int?
    var client: MCPClientInfo?
    var requestID: String?
    /// The `compositor-mcp` bridge forwarded the call.
    var viaBridge = false
    var arrived = ContinuousClock.now

    /// The origin of the request `Server.currentHandlerContext` holds, as `MCPRequestRouter` marked it.
    init(request: HTTPRequest?, clients: MCPClientDirectory) {
        connection = request?.header(MCPRequestLog.connectionHeader).flatMap { Int($0) }
        requestID = request?.header(MCPRequestLog.requestIDHeader)
        let bridge = MCPBridgeHeaders(request)
        viaBridge = bridge.viaBridge
        client = bridge.client ?? connection.flatMap(clients.client(on:))
    }

    func fields(startedAt started: ContinuousClock.Instant) -> [String: LogValue] {
        var fields: [String: LogValue] = ["queued_ms": .milliseconds(started - arrived)]
        if let connection { fields["conn"] = .int(connection) }
        if let client { fields["client"] = client.logValue }
        if let requestID { fields["rpc_id"] = .string(requestID) }
        if viaBridge { fields["via"] = "bridge" }
        return fields
    }
}

/// The `clientInfo` an MCP client sends with `initialize`.
nonisolated struct MCPClientInfo: Sendable, Equatable {
    let name: String
    let version: String

    var logValue: LogValue { .object(["name": .string(name), "version": .string(version)]) }
}

/// Which client initialized each connection: the MCP transport here is stateless, so a client that talks to the
/// server directly is known only by the connection its `initialize` came on. Clients that keep their connection alive
/// (most HTTP clients) are named on every later request; one that opens a new connection per request is named on its
/// `initialize` alone. The bridge names its client on every request itself (`MCPBridgeHeaders`).
nonisolated final class MCPClientDirectory: Sendable {
    /// Connections remembered; the oldest are forgotten past this.
    static let capacity = 256
    private let clients = Mutex<(byConnection: [Int: MCPClientInfo], order: [Int])>(([:], []))

    func record(_ client: MCPClientInfo, on connection: Int) {
        clients.withLock { state in
            if state.byConnection.updateValue(client, forKey: connection) == nil { state.order.append(connection) }
            while state.order.count > Self.capacity { state.byConnection[state.order.removeFirst()] = nil }
        }
    }

    func client(on connection: Int) -> MCPClientInfo? {
        clients.withLock { $0.byConnection[connection] }
    }
}

/// What the `compositor-mcp` bridge says about a request it forwards, in two headers of its own.
///
/// The bridge sends each line from its client as a POST of its own, and URLSession spreads them over as many
/// connections as it likes, so the connection that carried the client's `initialize` rarely carries its tool calls
/// (a Hermes session's calls were all logged without a client). The bridge therefore remembers the `clientInfo` of
/// the `initialize` it forwarded and names it on every later request:
///
/// - `X-Compositor-Client: <name>/<version>`, each part percent-encoded down to printable ASCII other than `%` and
///   `/` (so the one `/` between them is unambiguous), at most 100 characters in all;
/// - `X-Compositor-Transport: bridge` on everything it sends, so the log can tell a bridged call from a direct one.
///
/// Only the log reads them: access, request validation and tools never do. A missing or malformed header is ignored
/// (the connection's client is used, as for a direct client), and what a malformed one held is never logged.
nonisolated struct MCPBridgeHeaders: Sendable, Equatable {
    static let clientHeader = "x-compositor-client"
    static let transportHeader = "x-compositor-transport"
    /// The longest `X-Compositor-Client` value read, as the bridge caps it.
    static let maxClientLength = 100

    /// The client the bridge forwards for; nil without a well-formed `X-Compositor-Client`.
    let client: MCPClientInfo?
    /// The request says it came through the bridge.
    let viaBridge: Bool

    init(_ request: HTTPRequest?) {
        client = Self.client(fromHeader: request?.header(Self.clientHeader))
        viaBridge = request?.header(Self.transportHeader)?.lowercased() == "bridge"
    }

    /// The client an `X-Compositor-Client` value names, or nil unless it is `name/version` as the bridge writes it:
    /// 1 to 100 printable ASCII characters, valid percent-escapes of UTF-8, a name that isn't empty, and no control
    /// characters once decoded. A value without a `/` is a name alone.
    static func client(fromHeader value: String?) -> MCPClientInfo? {
        guard let value, (1...maxClientLength).contains(value.utf8.count),
              value.utf8.allSatisfy({ (0x21...0x7E).contains($0) })
        else { return nil }
        let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let name = parts[0].removingPercentEncoding, !name.isEmpty,
              let version = parts.count > 1 ? parts[1].removingPercentEncoding : "",
              !(name + version).unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return MCPClientInfo(name: name, version: version)
    }
}

// MARK: - JSON-RPC requests

/// The one HTTP connection a request came on, set by `MCPHTTPConnection` while its handler runs.
nonisolated struct MCPConnectionContext: Sendable {
    @TaskLocal static var current: MCPConnectionContext?

    let id: Int
    /// The client's address and port, e.g. `127.0.0.1:52144`.
    let peer: String

    private static let counter = Atomic<Int>(0)

    /// A number for a new connection, unique in this process.
    static func nextID() -> Int {
        counter.wrappingAdd(1, ordering: .relaxed).newValue
    }
}

/// What a JSON-RPC request is, read from its body while `MCPRequestIDs` parses it anyway.
nonisolated struct MCPRequestSummary: Sendable {
    let method: String
    let id: String?
    let tool: String?
    let client: MCPClientInfo?

    init?(_ object: [String: Any]) {
        guard let method = object["method"] as? String else { return nil }
        self.method = method
        id = object["id"].flatMap { $0 is NSNull ? nil : "\($0)" }
        let params = object["params"] as? [String: Any]
        tool = method == "tools/call" ? params?["name"] as? String : nil
        let info = params?["clientInfo"] as? [String: Any]
        client = method == "initialize" ? info.map {
            MCPClientInfo(name: $0["name"] as? String ?? "", version: $0["version"] as? String ?? "")
        } : nil
    }
}

/// Logs each JSON-RPC request the router handles as an `rpc` event.
nonisolated enum MCPRequestLog {
    /// Headers the router sets on the request it forwards, read back by the server's tool-call handler. A client's
    /// own headers by these names are replaced.
    static let connectionHeader = "x-compositor-connection"
    static let requestIDHeader = "x-compositor-request-id"

    /// `request` as forwarded: marked with its connection and the client's own id, anything a client sent under
    /// those names gone.
    static func marked(_ request: HTTPRequest, body: Data, originalID: String?) -> HTTPRequest {
        var headers = request.headers.filter {
            let name = $0.key.lowercased()
            return name != connectionHeader && name != requestIDHeader
        }
        if let connection = MCPConnectionContext.current { headers[connectionHeader] = String(connection.id) }
        if let originalID { headers[requestIDHeader] = originalID }
        return HTTPRequest(method: request.method, headers: headers, body: body, path: request.path)
    }

    /// Logs one answered request. A successful `tools/call` is `debug` (verbose only): its `tool_call` event says
    /// more. Everything else, and any call answered with an error, is `info`. The client is the one an `initialize`
    /// names, else the one the bridge names (`bridge`), else the one that initialized the connection.
    static func record(_ summary: MCPRequestSummary?, bridge: MCPBridgeHeaders, response: HTTPResponse,
                       startedAt started: ContinuousClock.Instant, clients: MCPClientDirectory, log: CompositorLog) {
        guard let summary else { return }
        let connection = MCPConnectionContext.current
        if let client = summary.client, let connection { clients.record(client, on: connection.id) }
        let body = response.bodyData
        // Only a small body can be an error; a tool's result (often an image) is never parsed again here.
        let rpcError: Int? = body.flatMap { data in
            guard data.count < 16 * 1024 else { return nil }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return (object?["error"] as? [String: Any])?["code"] as? Int
        }
        let failed = response.statusCode >= 300 || rpcError != nil
        let level: CompositorLog.Level = summary.method == "tools/call" && !failed ? .debug : .info
        log.log(level, .mcp, "rpc", {
            var fields: [String: LogValue] = [
                "method": .string(summary.method),
                "status": .int(response.statusCode),
                "duration_ms": .milliseconds(since: started),
                "response_bytes": .int(body?.count ?? 0),
            ]
            if let id = summary.id { fields["id"] = .string(id) }
            if let tool = summary.tool { fields["tool"] = .string(tool) }
            if let rpcError { fields["rpc_error"] = .int(rpcError) }
            if let connection { fields["conn"] = .int(connection.id) }
            if let client = summary.client ?? bridge.client ?? connection.flatMap({ clients.client(on: $0.id) }) {
                fields["client"] = client.logValue
            }
            if bridge.viaBridge { fields["via"] = "bridge" }
            return fields
        }())
    }
}

// MARK: - HTTP refusals

/// Logs requests the listener refuses before any JSON-RPC runs, as `refused` events: the status, why, and the
/// client's address, never a header's value.
nonisolated enum MCPHTTPLog {
    /// Why a request was refused, for each status the listener or the transport's checks answer with.
    static func reason(for status: Int) -> String {
        switch status {
        case 400: "bad_request"
        case 401: "unauthorized"
        case 403: "browser_origin"
        case 404: "not_found"
        case 405: "method_not_allowed"
        case 406: "not_acceptable"
        case 408: "request_timeout"
        case 413: "request_too_large"
        case 415: "unsupported_media_type"
        case 421: "host_not_loopback_with_this_port"
        case 431: "request_head_too_large"
        case 501: "transfer_encoding_unsupported"
        case 503: "unavailable"
        default: "http_\(status)"
        }
    }

    /// Logs a refusal. `detail` is the listener's own wording (never a header's value); `authHeader` says for a 401
    /// whether the request carried an Authorization header at all ("missing") or a wrong one ("wrong").
    static func refused(_ status: Int, peer: String, connection: Int?, detail: String? = nil, authHeader: String? = nil,
                        log: CompositorLog) {
        log.notice(.http, "refused", {
            var fields: [String: LogValue] = ["status": .int(status), "reason": .string(reason(for: status)),
                                              "client": .string(peer)]
            if let connection { fields["conn"] = .int(connection) }
            if let detail { fields["detail"] = .string(detail) }
            if let authHeader { fields["auth_header"] = .string(authHeader) }
            return fields
        }())
    }
}

// MARK: - The server

/// Why the server stopped, for the log.
enum MCPServerStopReason: String, Sendable {
    /// Code asked (tests, and any caller that gives no reason).
    case requested
    /// The Settings switch was turned off.
    case settingsSwitch = "settings_switch"
    /// "Stop for this session" in Settings.
    case stoppedForSession = "stopped_for_session"
    case portChanged = "port_changed"
    case listenerFailed = "listener_failed"
    case startFailed = "start_failed"
    /// The token requirement was turned on and the token couldn't be read or made.
    case tokenUnavailable = "token_unavailable"
    case appTerminating = "app_terminating"
}

/// Logs the server's starts, stops and access-token changes (`mcp` category).
@MainActor
enum MCPServerLog {
    static func started(_ server: MCPServer, reason: MCPServer.StartReason, log: CompositorLog) {
        log.info(.mcp, "server_started", [
            "reason": .string(reason == .settings ? "settings" : "session"),
            "port": .int(Int(server.port)),
            "preferred_port": .int(Int(server.options.preferredPort)),
            "fell_back": .bool(server.portFellBack),
            "auth": .string(server.accessGate.requiredToken != nil ? "bearer" : "none"),
            "endpoint_file": .text(server.options.endpointFileURL?.path),
            "pid": .int(Int(getpid())),
        ])
    }

    static func startFailed(_ error: any Error, preferredPort: UInt16, log: CompositorLog) {
        log.error(.mcp, "server_start_failed", ["error": .string(error.localizedDescription),
                                                "preferred_port": .int(Int(preferredPort))])
    }

    static func stopped(_ reason: MCPServerStopReason, port: UInt16, log: CompositorLog) {
        log.info(.mcp, "server_stopped", ["reason": .string(reason.rawValue), "port": .int(Int(port))])
    }

    static func tokenRequirementChanged(_ required: Bool, error: (any Error)?, log: CompositorLog) {
        var fields: [String: LogValue] = ["auth": .string(required ? "bearer" : "none")]
        if let error { fields["error"] = .string(error.localizedDescription) }
        log.info(.mcp, "auth_changed", fields)
    }

    /// The token was replaced; the log never holds either token.
    static func tokenRegenerated(log: CompositorLog) {
        log.info(.mcp, "token_regenerated")
    }

    /// A call refused before it ran: the queue was full, or the server stopped.
    static func callRefused(_ tool: String, _ error: MCPToolError, log: CompositorLog) {
        log.notice(.mcp, "tool_call", ["tool": .string(tool), "outcome": "error", "error": MCPCallLog.errorFields(error.value)])
    }
}
