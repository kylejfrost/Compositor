import Foundation
import MCP
import Network
import Testing
@testable import Compositor

/// What the MCP server records in the diagnostic log: one `tool_call` event per call (duration, outcome, undo, result
/// size, a redacted summary of the arguments), `batch_step` events inside run_batch, a JSON-RPC `rpc` event per
/// request with the client that sent it, `refused` events for HTTP refusals (never a header's value), and the
/// server's starts and stops. Calls go to a log in a temporary folder (`CompositorLog.taskLog`, or the server's own
/// `Options.log`); nothing touches the app's log.
@MainActor struct MCPLoggingTests {
    // MARK: Tool calls

    @Test func aSuccessfulCallIsOneEventWithItsDurationOutcomeUndoAndArguments() async throws {
        let harness = LogHarness()
        defer { harness.remove() }
        let workspace = MCPTestSupport.workspace()
        try await CompositorLog.$taskLog.withValue(harness.log) {
            try await MCPTestSupport.call("add_blank_layer", ["name": "Headline"], in: workspace)
        }
        let calls = try harness.events(named: "tool_call")
        #expect(calls.count == 1, "\(calls)")
        let call = try #require(calls.first)
        #expect(call["cat"] as? String == "mcp" && call["level"] as? String == "info")
        #expect(call["tool"] as? String == "add_blank_layer")
        #expect(call["outcome"] as? String == "ok")
        #expect((call["duration_ms"] as? Double).map { $0 >= 0 } == true, "\(call)")
        #expect((call["call"] as? String)?.count == 8, "\(call)")
        #expect((call["args"] as? [String: Any])?["name"] as? String == "Headline", "\(call)")
        let undo = try #require(call["undo"] as? [String: Any], "\(call)")
        #expect(undo["recorded"] as? Bool == true && (undo["name"] as? String)?.isEmpty == false, "\(undo)")
        #expect((call["result_bytes"] as? Int).map { $0 > 0 } == true && call["images"] as? Int == 0, "\(call)")
    }

    @Test func aFailedCallIsOneEventWithItsErrorCodeAndMessage() async throws {
        let harness = LogHarness()
        defer { harness.remove() }
        let workspace = MCPTestSupport.workspace()
        try await CompositorLog.$taskLog.withValue(harness.log) {
            try await MCPTestSupport.call("set_layer_opacity", ["layer": "Nope", "opacity": 0.5], in: workspace,
                                          expectError: "not_found")
        }
        let calls = try harness.events(named: "tool_call")
        #expect(calls.count == 1, "\(calls)")
        let call = try #require(calls.first)
        #expect(call["outcome"] as? String == "error" && call["level"] as? String == "notice", "\(call)")
        #expect((call["duration_ms"] as? Double) != nil)
        let error = try #require(call["error"] as? [String: Any], "\(call)")
        #expect(error["code"] as? String == "not_found")
        #expect((error["message"] as? String)?.contains("Nope") == true, "\(error)")
        #expect(call["undo"] == nil)
    }

    /// Read-only calls say which arguments they had; verbose logging adds the values.
    @Test func readOnlyCallsListTheirArgumentNamesUnlessVerbose() async throws {
        let harness = LogHarness()
        defer { harness.remove() }
        let workspace = MCPTestSupport.workspace()
        try await CompositorLog.$taskLog.withValue(harness.log) {
            try await MCPTestSupport.call("get_document", ["detail": "full"], in: workspace)
            harness.log.setVerbose(true)
            try await MCPTestSupport.call("get_document", ["detail": "full"], in: workspace)
        }
        let calls = try harness.events(named: "tool_call")
        #expect(calls.count == 2)
        #expect(calls.first?["args"] as? [String] == ["detail"], "\(calls)")
        #expect((calls.last?["args"] as? [String: Any])?["detail"] as? String == "full", "\(calls)")
    }

    /// An image result is logged by its size and count; its pixels never reach the log.
    @Test func renderedImagesAreCountedNeverWritten() async throws {
        let harness = LogHarness()
        defer { harness.remove() }
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        try await CompositorLog.$taskLog.withValue(harness.log) {
            try await MCPTestSupport.call("render_document", ["max_size": 32], in: workspace)
        }
        let call = try #require(try harness.events(named: "tool_call").first)
        #expect(call["images"] as? Int == 1, "\(call)")
        #expect((call["result_bytes"] as? Int).map { $0 > 100 } == true, "\(call)")
        #expect(!(try harness.text()).contains("iVBOR"), "PNG data reached the log")
    }

    @Test func eachBatchStepIsLoggedUnderItsBatch() async throws {
        let harness = LogHarness()
        defer { harness.remove() }
        let workspace = MCPTestSupport.workspace()
        try await CompositorLog.$taskLog.withValue(harness.log) {
            try await MCPTestSupport.call("run_batch", ["steps": [
                ["tool": "add_blank_layer", "arguments": ["name": "Headline"]],
                ["tool": "set_layer_opacity", "arguments": ["layer": "Nope", "opacity": 0.5]],
            ]], in: workspace, expectError: "not_found")
        }
        let batch = try #require(try harness.events(named: "tool_call").first)
        #expect(batch["tool"] as? String == "run_batch")
        let steps = try harness.events(named: "batch_step")
        #expect(steps.map { $0["tool"] as? String } == ["add_blank_layer", "set_layer_opacity"], "\(steps)")
        #expect(steps.allSatisfy { $0["batch"] as? String == batch["call"] as? String }, "\(steps) vs \(batch)")
        #expect(steps.map { $0["step"] as? Int } == [0, 1])
        #expect(steps.map { $0["outcome"] as? String } == ["ok", "error"])
        #expect((steps.last?["error"] as? [String: Any])?["code"] as? String == "not_found", "\(steps)")
        #expect(steps.allSatisfy { $0["duration_ms"] is Double })
    }

    // MARK: Settings

    /// get_app_info says whether logging is on, whether it's verbose and where the files are, never what they hold.
    @Test func getAppInfoReportsTheLogSettingsButNotTheLog() async throws {
        let harness = LogHarness(verbose: true)
        defer { harness.remove() }
        let workspace = MCPTestSupport.workspace()
        let info = try await CompositorLog.$taskLog.withValue(harness.log) {
            try await MCPTestSupport.call("get_app_info", in: workspace)
        }
        let logs = try #require(info["logs"]?.objectValue, "\(info)")
        #expect(logs == ["enabled": .bool(true), "verbose": .bool(true), "directory": .string(harness.directory.path)])
    }

    @Test func theSettingsSwitchesAreRememberedAndApplyAtOnce() throws {
        let suite = "MCPLoggingTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let harness = LogHarness()
        defer { harness.remove() }
        #expect(CompositorLogSettings.isEnabled(in: defaults) && !CompositorLogSettings.isVerbose(in: defaults),
                "Logging is on by default, verbose off")
        CompositorLogSettings.setVerbose(true, in: defaults, log: harness.log)
        CompositorLogSettings.setEnabled(false, in: defaults, log: harness.log)
        #expect(!CompositorLogSettings.isEnabled(in: defaults) && CompositorLogSettings.isVerbose(in: defaults))
        #expect(harness.log.status == CompositorLog.Status(isEnabled: false, isVerbose: true, directory: harness.directory))
        harness.log.info(.app, "while off")
        #expect(try harness.lines().isEmpty)
    }

    // MARK: The server

    /// A request without the right token is refused with 401 and logged with who sent it and whether it carried a
    /// token at all, but never the Authorization header's value, nor the server's own token.
    @Test func a401RefusalIsLoggedWithoutAnyHeaderValue() async throws {
        let harness = LogHarness()
        defer { harness.remove() }
        let folder = MCPTestSupport.tempFile("mcp")
        let server = MCPServer(options: .init(preferredPort: 0, endpointFileURL: nil,
                                              tokenFileURL: folder.appendingPathComponent("token"), requiresToken: true,
                                              log: harness.log))
        defer { server.stop() }
        try await server.start(reason: .session)
        let token = try server.currentToken()
        var headers = RawHTTP.jsonHeaders
        headers["Authorization"] = "Bearer wrong-value-Z9y8X7w6V5u4T3s2R1q0"
        let response = try await RawHTTP.send(port: server.port, method: "POST", headers: headers,
                                              body: #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#)
        #expect(response.status == 401)

        let refused = try await harness.eventually(named: "refused")
        #expect(refused["cat"] as? String == "http" && refused["status"] as? Int == 401, "\(refused)")
        #expect(refused["reason"] as? String == "unauthorized")
        #expect(refused["auth_header"] as? String == "wrong", "\(refused)")
        #expect((refused["client"] as? String)?.hasPrefix("127.0.0.1:") == true, "\(refused)")
        let text = try harness.text()
        #expect(!text.contains("wrong-value") && !text.contains(token), "A header value or the token was logged: \(text)")
    }

    /// The transport's own refusals (a GET, a browser's Origin, a Host that isn't this server), which the listener
    /// logs as it sends them, each give their status, reason, connection and client, and never a header's value.
    @Test func theTransportsRefusalsAreLoggedWithoutAnyHeaderValue() async throws {
        let harness = LogHarness()
        defer { harness.remove() }
        let server = MCPServer(options: .init(preferredPort: 0, endpointFileURL: nil, log: harness.log))
        defer { server.stop() }
        try await server.start(reason: .session)
        let port = server.port
        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#
        let agent = ["User-Agent": "probe-agent-7Kq2"]

        let get = try await RawHTTP.send(port: port, method: "GET",
                                         headers: agent.merging(["Accept": "text/event-stream"]) { $1 }, body: nil)
        #expect(get.status == 405)
        let browser = try await RawHTTP.send(port: port, method: "POST", headers: RawHTTP.jsonHeaders.merging(agent) { $1 }
            .merging(["Origin": "http://origin-probe.example:1234"]) { $1 }, body: body)
        #expect(browser.status == 403)
        let rebound = try await RawHTTP.send(port: port, method: "POST", headers: RawHTTP.jsonHeaders.merging(agent) { $1 }
            .merging(["Host": "host-probe.example:\(port)"]) { $1 }, body: body)
        #expect(rebound.status == 421)

        let refused = try await harness.eventually(named: "refused", count: 3)
        try #require(refused.count == 3, "\(refused)")
        #expect(refused.map { $0["status"] as? Int } == [405, 403, 421], "\(refused)")
        #expect(refused.map { $0["reason"] as? String } == ["method_not_allowed", "browser_origin",
                                                             "host_not_loopback_with_this_port"], "\(refused)")
        for event in refused {
            #expect(event["cat"] as? String == "http" && event["level"] as? String == "notice", "\(event)")
            #expect(event["conn"] is Int && event["detail"] == nil, "\(event)")
            #expect((event["client"] as? String)?.hasPrefix("127.0.0.1:") == true, "\(event)")
        }
        let text = try harness.text()
        for value in ["probe-agent", "origin-probe", "host-probe", "text/event-stream"] {
            #expect(!text.contains(value), "The header value \(value) was logged: \(text)")
        }
    }

    /// The listener's own refusals are each logged with their status and reason: a body too large by its
    /// Content-Length and one piling up behind a request in flight (413), a Content-Length that isn't a number (400),
    /// a request that doesn't arrive in time (408), a head that never ends (431) and a connection past the limit (503).
    @Test func theListenersRefusalsAreLoggedWithTheirStatusAndReason() async throws {
        let harness = LogHarness()
        defer { harness.remove() }
        let agent = "User-Agent: probe-agent-7Kq2\r\n"

        // Small limits for the body and the time a request may take; its handler holds each request until the end.
        let (gate, open) = AsyncStream<Void>.makeStream()
        let (entered, enter) = AsyncStream<Void>.makeStream()
        defer { open.finish() }
        let small = MCPHTTPListener(maxRequestBytes: 1024, requestTimeout: .milliseconds(500), log: harness.log, handler: { _ in
            enter.yield()
            for await _ in gate { break }
            return .accepted()
        }, onFailure: { _ in })
        let port = try await small.start(port: 0)
        defer { small.stop() }
        let start = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\(agent)"
        // What the client reads back is the transport suite's concern; a refusal can reset the connection first.
        _ = try? await RawHTTP.exchange(port: port, bytes: Data("\(start)Content-Length: 5000\r\n\r\n".utf8))
        _ = try? await RawHTTP.exchange(port: port, bytes: Data("\(start)Content-Length: 2\r\n\r\n{}".utf8),
                                        then: { for await _ in entered { break } },
                                        more: Data(repeating: UInt8(ascii: "x"), count: 200_000), timeout: .seconds(30))
        _ = try? await RawHTTP.exchange(port: port, bytes: Data("\(start)Content-Length: -1\r\n\r\n{}".utf8))
        _ = try? await RawHTTP.trickle(port: port, head: Data(start.utf8), for: .seconds(20))

        // The usual limits, and room for one connection.
        let single = MCPHTTPListener(maxConnections: 1, log: harness.log, handler: { _ in .accepted() }, onFailure: { _ in })
        let singlePort = try await single.start(port: 0)
        defer { single.stop() }
        var endless = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(singlePort)\r\n\(agent)X-Padding: ".utf8)
        endless.append(Data(repeating: UInt8(ascii: "x"), count: 70 * 1024))
        _ = try? await RawHTTP.exchange(port: singlePort, bytes: endless, timeout: .seconds(20))
        let held = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: singlePort)!, using: .tcp)
        held.start(queue: DispatchQueue(label: "held"))
        defer { held.cancel() }
        // The held connection is accepted in its own time: ask until the listener has counted it.
        let request = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(singlePort)\r\n\(agent)Content-Length: 2\r\nConnection: close\r\n\r\n{}".utf8)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, try await RawHTTP.exchange(port: singlePort, bytes: request).status != 503 {
            try await Task.sleep(for: .milliseconds(20))
        }

        let refused = try await harness.eventually(named: "refused", count: 6)
        try #require(refused.count == 6, "\(refused)")
        #expect(refused.map { $0["status"] as? Int } == [413, 413, 400, 408, 431, 503], "\(refused)")
        #expect(refused.map { $0["reason"] as? String } == ["request_too_large", "request_too_large", "bad_request",
                                                             "request_timeout", "request_head_too_large", "unavailable"],
                "\(refused)")
        #expect(refused.allSatisfy { $0["cat"] as? String == "http" && $0["level"] as? String == "notice" }, "\(refused)")
        #expect(refused.allSatisfy { ($0["client"] as? String)?.hasPrefix("127.0.0.1:") == true }, "\(refused)")
        #expect(refused.prefix(5).allSatisfy { $0["conn"] is Int }, "\(refused)")
        #expect(refused[2]["detail"] as? String == "Content-Length must be one number of bytes", "\(refused)")
        // A connection refused at the door never got a number.
        #expect(refused.last?["conn"] == nil && refused.last?["detail"] as? String == "too many connections", "\(refused)")
        #expect(!(try harness.text()).contains("probe-agent"), "A header value was logged")
    }

    /// The server's start says how it runs; the stop says why. JSON-RPC requests on one connection carry the client
    /// that initialized it, and so does the tool call they lead to.
    @Test func startsRequestsAndStopsAreLoggedWithTheClient() async throws {
        let harness = LogHarness()
        defer { harness.remove() }
        let workspace = MCPTestSupport.workspace()
        let endpointFile = MCPTestSupport.tempFile("mcp/endpoint.json")
        let server = MCPServer(options: .init(preferredPort: 0, endpointFileURL: endpointFile, log: harness.log))
        server.workspace = workspace
        try await server.start(reason: .session)
        let port = server.port

        // Two requests on one keep-alive connection: the client's initialize, then a tool call.
        func request(_ body: String, closing: Bool) -> Data {
            var head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\n"
                + "Accept: application/json, text/event-stream\r\nContent-Length: \(Data(body.utf8).count)\r\n"
            if closing { head += "Connection: close\r\n" }
            return Data((head + "\r\n" + body).utf8)
        }
        let initialize = #"{"jsonrpc":"2.0","id":"init-1","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"log-test","version":"1.2"}}}"#
        let call = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"list_documents","arguments":{}}}"#
        var bytes = request(initialize, closing: false)
        bytes.append(request(call, closing: true))
        let response = try await RawHTTP.exchange(port: port, bytes: bytes)
        #expect(response.status == 200)
        server.stop()

        let started = try await harness.eventually(named: "server_started")
        #expect(started["reason"] as? String == "session" && started["port"] as? Int == Int(port), "\(started)")
        #expect(started["auth"] as? String == "none" && started["fell_back"] as? Bool == false, "\(started)")
        #expect(started["endpoint_file"] as? String == endpointFile.path, "\(started)")

        let rpc = try harness.events(named: "rpc")
        let hello = try #require(rpc.first { $0["method"] as? String == "initialize" }, "\(rpc)")
        #expect(hello["id"] as? String == "init-1" && hello["status"] as? Int == 200, "\(hello)")
        #expect((hello["client"] as? [String: Any])?["name"] as? String == "log-test", "\(hello)")
        #expect((hello["client"] as? [String: Any])?["version"] as? String == "1.2", "\(hello)")
        #expect(hello["duration_ms"] is Double)

        let toolCall = try #require(try harness.events(named: "tool_call").first)
        #expect(toolCall["tool"] as? String == "list_documents")
        #expect((toolCall["client"] as? [String: Any])?["name"] as? String == "log-test", "\(toolCall)")
        #expect(toolCall["rpc_id"] as? String == "7", "\(toolCall)")
        #expect(toolCall["queued_ms"] is Double, "\(toolCall)")

        let stopped = try await harness.eventually(named: "server_stopped")
        #expect(stopped["reason"] as? String == "requested", "\(stopped)")
    }

    // MARK: Requests the bridge forwards

    /// The bridge names its client in `X-Compositor-Client` and itself in `X-Compositor-Transport` on every request,
    /// because its requests rarely share a connection with the `initialize`: the log uses both, even on a connection
    /// that never carried one.
    @Test func aBridgedRequestIsLoggedWithTheClientItsHeaderNames() async throws {
        let harness = LogHarness()
        defer { harness.remove() }
        let workspace = MCPTestSupport.workspace()
        let server = MCPServer(options: .init(preferredPort: 0, endpointFileURL: nil, log: harness.log))
        server.workspace = workspace
        defer { server.stop() }
        try await server.start(reason: .session)
        var headers = RawHTTP.jsonHeaders
        headers["X-Compositor-Client"] = "Hermes%20Agent%2F%CE%B2/0.9"
        headers["X-Compositor-Transport"] = "bridge"
        // Each on a connection of its own, and neither an initialize.
        let list = try await RawHTTP.send(port: server.port, method: "POST", headers: headers,
                                          body: #"{"jsonrpc":"2.0","id":"list-1","method":"tools/list","params":{}}"#)
        #expect(list.status == 200)
        let call = try await RawHTTP.send(port: server.port, method: "POST", headers: headers,
                                          body: #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"list_documents","arguments":{}}}"#)
        #expect(call.status == 200)

        let expected = ["name": "Hermes Agent/β", "version": "0.9"]
        let toolCall = try await harness.eventually(named: "tool_call")
        #expect(toolCall["outcome"] as? String == "ok" && toolCall["rpc_id"] as? String == "7", "\(toolCall)")
        #expect(toolCall["client"] as? [String: String] == expected, "\(toolCall)")
        #expect(toolCall["via"] as? String == "bridge", "\(toolCall)")
        let rpc = try #require(try harness.events(named: "rpc").first { $0["method"] as? String == "tools/list" })
        #expect(rpc["client"] as? [String: String] == expected && rpc["via"] as? String == "bridge", "\(rpc)")
    }

    /// Bridge headers unlike the ones the bridge sends are ignored: the call runs as usual, the log names the client
    /// that initialized its connection (as for any direct client) and doesn't call it bridged, and nothing the
    /// headers held reaches the log.
    @Test func malformedBridgeHeadersAreIgnored() async throws {
        let harness = LogHarness()
        defer { harness.remove() }
        let workspace = MCPTestSupport.workspace()
        let server = MCPServer(options: .init(preferredPort: 0, endpointFileURL: nil, log: harness.log))
        server.workspace = workspace
        defer { server.stop() }
        try await server.start(reason: .session)
        let port = server.port

        // Empty; no name; a broken escape; a control character; raw UTF-8; an escape that isn't UTF-8; too long.
        let malformed = ["", "/1.0", "%ZZQz7/1", "ctl%0AQz7/1", "caféQz7/1", "%C3%28Qz7/1",
                         "Qz7" + String(repeating: "x", count: 98)]
        func request(_ body: String, headers: String = "", closing: Bool) -> Data {
            var head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\n"
                + "Accept: application/json, text/event-stream\r\nContent-Length: \(Data(body.utf8).count)\r\n" + headers
            if closing { head += "Connection: close\r\n" }
            return Data((head + "\r\n" + body).utf8)
        }
        for (index, value) in malformed.enumerated() {
            // One keep-alive connection each: a direct client's initialize, then a call with the bad headers.
            let initialize = #"{"jsonrpc":"2.0","id":"init-\#(index)","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"log-test","version":"1.2"}}}"#
            let call = #"{"jsonrpc":"2.0","id":\#(index),"method":"tools/call","params":{"name":"list_documents","arguments":{}}}"#
            var bytes = request(initialize, closing: false)
            bytes.append(request(call, headers: "X-Compositor-Client: \(value)\r\nX-Compositor-Transport: bridge-Qz7\r\n",
                                 closing: true))
            #expect(try await RawHTTP.exchange(port: port, bytes: bytes).status == 200, "\(value)")
        }

        let calls = try await harness.eventually(named: "tool_call", count: malformed.count)
        try #require(calls.count == malformed.count, "\(calls)")
        for call in calls {
            #expect(call["outcome"] as? String == "ok", "\(call)")
            #expect(call["client"] as? [String: String] == ["name": "log-test", "version": "1.2"], "\(call)")
            #expect(call["via"] == nil, "\(call)")
        }
        #expect(!(try harness.text()).contains("Qz7"), "A bridge header's value reached the log")
    }

    /// `X-Compositor-Client` is read only as the bridge writes it: `name/version`, percent-encoded to printable
    /// ASCII, at most 100 characters.
    @Test(arguments: [
        ("hermes/0.9", MCPClientInfo(name: "hermes", version: "0.9")),
        ("Hermes%20Agent%2F%CE%B2/1.0%2Fbeta", MCPClientInfo(name: "Hermes Agent/β", version: "1.0/beta")),
        ("name-only", MCPClientInfo(name: "name-only", version: "")),
        ("empty-version/", MCPClientInfo(name: "empty-version", version: "")),
        ("a/b/c", MCPClientInfo(name: "a", version: "b/c")),
        (String(repeating: "x", count: 98) + "/1", MCPClientInfo(name: String(repeating: "x", count: 98), version: "1")),
        ("", nil),
        ("/1.0", nil),
        ("%ZZ/1", nil),
        ("%C3%28/1", nil),
        ("ctl%0A/1", nil),
        ("tab%09/1", nil),
        ("café/1", nil),
        ("with space/1", nil),
        (String(repeating: "x", count: 99) + "/1", nil),
    ] as [(String, MCPClientInfo?)])
    func theBridgesClientHeaderIsReadOnlyWhenWellFormed(_ value: String, _ expected: MCPClientInfo?) {
        #expect(MCPBridgeHeaders.client(fromHeader: value) == expected)
    }
}

extension LogHarness {
    /// Every event named `name` written so far, oldest first.
    func events(named name: String) throws -> [[String: Any]] {
        try lines().map { try Self.object($0) }.filter { $0["event"] as? String == name }
    }

    /// The first event named `name`, waiting up to five seconds for it: events logged from the server's connection
    /// queue arrive a moment after the response.
    func eventually(named name: String) async throws -> [String: Any] {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let event = try events(named: name).first { return event }
            try await Task.sleep(for: .milliseconds(20))
        }
        let written = try text()
        return try #require(try events(named: name).first, "No \(name) event in: \(written)")
    }
}
