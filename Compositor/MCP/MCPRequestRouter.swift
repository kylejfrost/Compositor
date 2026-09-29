import Foundation
import MCP

/// Carries one HTTP request into the SDK's `StatelessHTTPServerTransport` with a
/// JSON-RPC id no other request can share, and restores the client's own id in the
/// response.
///
/// The stateless transport serves any number of clients through one `Server`, but it
/// matches responses to waiting HTTP requests by JSON-RPC id alone
/// (`responseWaiters[requestID]`), and `Server` tracks in-flight handlers by id too.
/// Every client numbers its requests 1, 2, 3…, so Claude Code and Codex calling at
/// the same moment would otherwise overwrite each other's waiter: one request would
/// hang forever and the other would receive whichever answer finished first.
///
/// Consequence: a client's `notifications/cancelled` names its own id, which the
/// server never saw, so cancellation of an in-flight call is a no-op (the call runs
/// to completion; stateless mode has no progress or cancellation channel anyway).
nonisolated struct MCPRequestRouter: Sendable {
    let transport: StatelessHTTPServerTransport
    /// Where each JSON-RPC request is logged (`MCPRequestLog`).
    var log: CompositorLog = .shared
    /// The client each connection's `initialize` named, shared with the server's tool-call handler.
    var clients = MCPClientDirectory()

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let started = ContinuousClock.now
        var summary: MCPRequestSummary?
        let response = await route(request, summary: &summary)
        MCPRequestLog.record(summary, bridge: MCPBridgeHeaders(request), response: response, startedAt: started,
                             clients: clients, log: log)
        return response
    }

    private func route(_ request: HTTPRequest, summary: inout MCPRequestSummary?) async -> HTTPResponse {
        guard request.method.uppercased() == "POST", let body = request.body else {
            // GET/DELETE (405) and empty bodies (400) carry no id to isolate.
            return await transport.handleRequest(request)
        }
        let inspected = MCPRequestIDs.inspect(body, prefix: "\(UUID().uuidString)/")
        summary = inspected.summary
        switch inspected.outcome {
        case .passThrough:
            // Notifications (202) and anything unparsable (400): the transport answers.
            return await transport.handleRequest(request)
        case .failed:
            return .error(statusCode: 400, .invalidRequest("Bad Request: the request id must be a string or a number"))
        case .rewritten(let rewritten, let original):
            // Marked with its connection and the client's own id, for the tool call's log event (`MCPCallOrigin`).
            let forwarded = MCPRequestLog.marked(request, body: rewritten, originalID: "\(original)")
            let response = await transport.handleRequest(forwarded)
            if case .data(let data, let headers) = response {
                return .data(MCPRequestIDs.restore(data, original: original), headers: headers)
            }
            // Validation failures answer with `"id": null` before the id is ever used.
            return response
        }
    }
}

/// Rewrites and restores the `id` of a single JSON-RPC request.
nonisolated enum MCPRequestIDs {
    enum Outcome {
        /// Nothing to isolate (notification, response, batch, not JSON): forward as is.
        case passThrough
        case rewritten(body: Data, original: Any)
        /// A request whose id can't be isolated; it must not reach the transport.
        case failed
    }

    /// Classifies `body` and, for a single request, replaces its id with `prefix` +
    /// the original id, as a JSON string. Batch arrays (the stateless transport
    /// rejects them with 400), notifications and responses (no id, or no method), and
    /// anything that isn't a JSON object pass through unchanged. A request whose id is
    /// neither a string nor a number, or that can't be re-serialized, is `.failed`:
    /// forwarding it with its own id would defeat the isolation.
    ///
    /// The original id is kept exactly as `JSONSerialization` read it (an `NSNumber` or
    /// `NSString`), so `restore` writes an integer id back as a number, a string id as
    /// a string. Re-serializing may respell numbers in other fields (`0.1` as
    /// `0.10000000000000001`), which decode to the identical `Double`.
    static func outcome(of body: Data, prefix: String) -> Outcome {
        inspect(body, prefix: prefix).outcome
    }

    /// `outcome`, and what the request is (its method, id, tool and client) for the log, from the one parse.
    static func inspect(_ body: Data, prefix: String) -> (outcome: Outcome, summary: MCPRequestSummary?) {
        guard var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return (.passThrough, nil) }
        let summary = MCPRequestSummary(object)
        guard object["method"] is String, let original = object["id"], !(original is NSNull) else { return (.passThrough, summary) }
        guard original is String || original is NSNumber else { return (.failed, summary) }
        object["id"] = prefix + "\(original)"
        guard let rewritten = try? JSONSerialization.data(withJSONObject: object) else { return (.failed, summary) }
        return (.rewritten(body: rewritten, original: original), summary)
    }

    /// The rewritten body and original id, or nil unless `outcome` is `.rewritten`.
    static func rewrite(_ body: Data, prefix: String) -> (body: Data, original: Any)? {
        guard case .rewritten(let rewritten, let original) = outcome(of: body, prefix: prefix) else { return nil }
        return (rewritten, original)
    }

    /// Puts the client's original id back on a response. A body that isn't a JSON
    /// object with an id is returned unchanged.
    static func restore(_ response: Data, original: Any) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any],
              object["id"] != nil
        else { return response }
        object["id"] = original
        return (try? JSONSerialization.data(withJSONObject: object)) ?? response
    }
}

/// Refuses every request that carries an `Origin` header with 403.
///
/// Browsers always send `Origin` on a cross-origin (and every non-GET) fetch; the
/// agents this server exists for — Claude Code, Codex, other CLI and desktop MCP
/// clients — never do. Refusing any `Origin`, even a loopback one, means a web page
/// can never drive the editor, whatever the Host header says.
nonisolated struct MCPNoBrowserOriginValidator: HTTPRequestValidator {
    func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        guard request.header(HTTPHeaderName.origin) != nil else { return nil }
        return .error(statusCode: 403, .invalidRequest("Forbidden: browser requests are not accepted"))
    }
}

nonisolated extension MCPRequestRouter {
    /// The request checks run by the transport before any JSON-RPC is processed:
    /// no browser Origin (403), a loopback Host naming the bound port (421 otherwise,
    /// DNS-rebinding protection), `Accept: application/json` (406),
    /// `Content-Type: application/json` (415), and a supported `MCP-Protocol-Version` (400).
    static func validationPipeline(port: UInt16) -> StandardValidationPipeline {
        StandardValidationPipeline(validators: [
            MCPNoBrowserOriginValidator(),
            OriginValidator.localhost(port: Int(port)),
            AcceptHeaderValidator(mode: .jsonOnly),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
        ])
    }
}
