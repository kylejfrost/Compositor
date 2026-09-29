import Foundation
import Network
import Testing
import MCP
@testable import Compositor

/// End-to-end tests for the embedded MCP server over real loopback HTTP: several
/// clients at once, JSON-RPC id isolation across connections, request validation
/// (method, Host, Origin), and the bounded tool queue.
///
/// Every server here binds an ephemeral port (`preferredPort: 0`) and publishes no
/// endpoint file, so parallel runs never collide and nothing touches Application Support.
@MainActor struct MCPTransportTests {
    private func startServer() async throws -> (MCPServer, ProjectWorkspace, UInt16) {
        let workspace = MCPTestSupport.workspace()
        let server = MCPServer(options: .init(preferredPort: 0, endpointFileURL: nil))
        server.workspace = workspace
        try await server.start(reason: .session)
        #expect(server.isRunning && server.port != 0)
        return (server, workspace, server.port)
    }

    @Test func twoClientsInitializeListAndCallOverLoopback() async throws {
        let (server, workspace, _) = try await startServer()
        defer { server.stop() }
        _ = workspace
        let url = try #require(server.endpointURL)
        let a = Client(name: "a", version: "1"), b = Client(name: "b", version: "1")
        let initA = try await a.connect(transport: HTTPClientTransport(endpoint: url, streaming: false))
        // The second initialize must succeed: the SDK's default handler refuses it.
        let initB = try await b.connect(transport: HTTPClientTransport(endpoint: url, streaming: false))
        #expect(initA.serverInfo.name == "Compositor" && initB.protocolVersion == initA.protocolVersion)
        #expect(initA.instructions == MCPToolRegistry.instructions)
        #expect(try await a.listTools().tools.contains { $0.name == "list_documents" })
        let (content, isError) = try await b.callTool(name: "new_document", arguments: ["width": 10, "height": 10])
        #expect(isError != true && !content.isEmpty)
        // A client that reconnects (a restarted agent) initializes again on the same server.
        await a.disconnect()
        let again = Client(name: "a", version: "2")
        _ = try await again.connect(transport: HTTPClientTransport(endpoint: url, streaming: false))
        #expect(try await again.listTools().tools.count == MCPToolRegistry.tools.count)
        await again.disconnect()
        await b.disconnect()
    }

    @Test func sameJSONRPCIDsFromTwoConnectionsDoNotCollide() async throws {
        let (server, workspace, port) = try await startServer()
        defer { server.stop() }
        _ = workspace
        let render = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"render_document","arguments":{"max_size":64}}}"#
        let list = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_documents","arguments":{}}}"#
        // Each RawHTTP call opens its own TCP connection.
        async let first = RawHTTP.post(port: port, body: render)
        async let second = RawHTTP.post(port: port, body: list)
        let (renderResponse, listResponse) = try await (first, second)

        for response in [renderResponse, listResponse] {
            #expect(response.status == 200)
            #expect(response.accessControlHeaders.isEmpty, "Unexpected CORS headers: \(response.headers)")
        }
        let renderJSON = try RawHTTP.object(renderResponse.body)
        let listJSON = try RawHTTP.object(listResponse.body)
        #expect(renderJSON["id"] as? Int == 1 && listJSON["id"] as? Int == 1)
        let renderResult = try #require(renderJSON["result"] as? [String: Any])
        let listResult = try #require(listJSON["result"] as? [String: Any])
        let renderStructured = try #require(renderResult["structuredContent"] as? [String: Any])
        let listStructured = try #require(listResult["structuredContent"] as? [String: Any])
        #expect(renderStructured["width"] as? Int == 64, "render_document got: \(renderStructured)")
        let renderContent = try #require(renderResult["content"] as? [[String: Any]])
        #expect(renderContent.first?["type"] as? String == "image" && renderContent.first?["mimeType"] as? String == "image/png")
        #expect(listStructured["tabs"] != nil, "list_documents got: \(listStructured)")
    }

    @Test func getIsRejectedWith405AndBrowserOriginWith403() async throws {
        let (server, workspace, port) = try await startServer()
        defer { server.stop() }
        _ = workspace
        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#

        let get = try await RawHTTP.send(port: port, method: "GET", headers: ["Accept": "text/event-stream"], body: nil)
        #expect(get.status == 405)

        let browser = try await RawHTTP.send(port: port, method: "POST",
                                             headers: RawHTTP.jsonHeaders.merging(["Origin": "http://localhost:1234"]) { $1 },
                                             body: body)
        #expect(browser.status == 403)

        // Even an Origin that names this very server is refused: CLI and desktop clients never send one.
        let sameOrigin = try await RawHTTP.send(port: port, method: "POST",
                                                headers: RawHTTP.jsonHeaders.merging(["Origin": "http://127.0.0.1:\(port)"]) { $1 },
                                                body: body)
        #expect(sameOrigin.status == 403)

        // DNS rebinding: a Host that isn't loopback-with-this-port is refused by the SDK's
        // OriginValidator with 421 Misdirected Request.
        let rebound = try await RawHTTP.send(port: port, method: "POST",
                                             headers: RawHTTP.jsonHeaders.merging(["Host": "evil.example:\(port)"]) { $1 },
                                             body: body)
        #expect(rebound.status == 421)
        let otherPort = port == 1 ? 2 : port - 1
        let wrongPort = try await RawHTTP.send(port: port, method: "POST",
                                               headers: RawHTTP.jsonHeaders.merging(["Host": "127.0.0.1:\(otherPort)"]) { $1 },
                                               body: body)
        #expect(wrongPort.status == 421)

        for host in ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"] {
            let ok = try await RawHTTP.send(port: port, method: "POST",
                                            headers: RawHTTP.jsonHeaders.merging(["Host": host]) { $1 },
                                            body: body)
            #expect(ok.status == 200, "Host \(host) should be accepted, got \(ok.status)")
            #expect(ok.accessControlHeaders.isEmpty, "Unexpected CORS headers: \(ok.headers)")
        }

        for response in [get, browser, sameOrigin, rebound, wrongPort] {
            #expect(response.accessControlHeaders.isEmpty, "Unexpected CORS headers on \(response.status): \(response.headers)")
        }
    }

    @Test func toolQueueRunsCallsInOrderAndRefusesBeyondItsLimit() async throws {
        let queue = MCPToolQueue(limit: 2)
        let log = CallLog()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let first = Task { try await queue.run { () -> Int in
            for await _ in gate { break }
            log.order.append(1)
            return 1
        } }
        let second = Task { try await queue.run { () -> Int in
            log.order.append(2)
            return 2
        } }
        while queue.depth < 2 { await Task.yield() }
        await #expect(throws: MCPQueueFull.self) { try await queue.run { 3 } }
        open.yield()
        open.finish()
        #expect(try await first.value == 1)
        #expect(try await second.value == 2)
        #expect(log.order == [1, 2])
        #expect(queue.depth == 0)
    }

    @Test func startingTwiceAndStoppingAreSafe() async throws {
        let (server, workspace, port) = try await startServer()
        _ = workspace
        try await server.start(reason: .session)
        #expect(server.port == port && server.startReason == .session)
        server.stop()
        #expect(!server.isRunning && server.endpointURL == nil)
        try await server.start(reason: .settings)
        #expect(server.isRunning && server.startReason == .settings)
        server.stop()
    }

    @Test func concurrentStartsBothAwaitReadinessAndShareOnePort() async throws {
        _ = MCPTestSupport.workspace()
        let server = MCPServer(options: .init(preferredPort: 0, endpointFileURL: nil))
        defer { server.stop() }
        @MainActor @Sendable func startAndObserve(_ reason: MCPServer.StartReason) async throws -> (running: Bool, port: UInt16) {
            try await server.start(reason: reason)
            return (server.isRunning, server.port)
        }
        async let session = startAndObserve(.session)
        async let settings = startAndObserve(.settings)
        let (a, b) = try await (session, settings)
        #expect(a.running && b.running, "Both callers must return only once the server is running: \(a), \(b)")
        #expect(a.port != 0 && a.port == b.port)
        // Settings outranks a session start: the switch in Settings owns the server now.
        #expect(server.startReason == .settings)
        try await server.start(reason: .session)
        #expect(server.startReason == .settings)
    }

    @Test func startStopStartEndsRunning() async throws {
        _ = MCPTestSupport.workspace()
        let server = MCPServer(options: .init(preferredPort: 0, endpointFileURL: nil))
        defer { server.stop() }
        // The Settings switch flipped on, off and on again before the first start finished.
        let first = Task { try await server.start(reason: .settings) }
        await Task.yield()
        server.stop()
        try await server.start(reason: .settings)
        #expect(server.isRunning)
        _ = try? await first.value
        #expect(server.isRunning && server.endpointURL != nil, "The superseded start must not stop the newer one")
        // The superseded start must leave no listener bound: exactly the live one remains.
        #expect(server.liveListeners.value == 1, "Listeners still bound: \(server.liveListeners.value)")
        let answer = try await RawHTTP.post(port: server.port, body: #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#)
        #expect(answer.status == 200)
        server.stop()
        #expect(await Self.eventually { server.liveListeners.value == 0 }, "Listeners still bound after stop: \(server.liveListeners.value)")
    }

    @Test func aStartSupersededWhileBindingStopsItsListener() async throws {
        _ = MCPTestSupport.workspace()
        let server = MCPServer(options: .init(preferredPort: 0, endpointFileURL: nil))
        defer { server.stop() }
        // Let the first start get as far as binding before the stop and restart.
        let first = Task { try await server.start(reason: .settings) }
        for _ in 0..<3 { await Task.yield() }
        server.stop()
        try await server.start(reason: .session)
        _ = try? await first.value
        #expect(server.isRunning)
        #expect(await Self.eventually { server.liveListeners.value == 1 }, "Listeners still bound: \(server.liveListeners.value)")
        server.stop()
        #expect(await Self.eventually { server.liveListeners.value == 0 }, "Listeners still bound after stop: \(server.liveListeners.value)")
    }

    @Test func aCallQueuedBeforeARestartDoesNotRunOnTheNewServer() async throws {
        let (server, workspace, _) = try await startServer()
        defer { server.stop() }
        let tabsBefore = workspace.tabs.count
        let (gate, open) = AsyncStream<Void>.makeStream()
        defer { open.finish() }
        let blocker = Task { try await server.toolQueue.run { for await _ in gate { break } } }
        let queued = Task { await server.invokeTool(.init(name: "new_document", arguments: ["width": 10, "height": 10])) }
        #expect(await Self.eventually { server.toolQueue.depth == 2 })
        server.stop()
        try await server.start(reason: .session)
        open.finish()
        try await blocker.value
        let result = await queued.value
        #expect(result.isError == true, "A call queued for the old server ran on the new one")
        #expect(workspace.tabs.count == tabsBefore)
    }

    /// A call that never returns (a read stuck on a dead volume, say) holds only its own server's queue: once the
    /// server is stopped and started again, calls run at once instead of queueing behind it until 64 wait and every
    /// call fails with busy.
    @Test func aCallThatNeverReturnsDoesNotHoldUpTheRestartedServer() async throws {
        let (server, workspace, _) = try await startServer()
        defer { server.stop() }
        _ = workspace
        let (gate, open) = AsyncStream<Void>.makeStream()
        defer { open.finish() }
        let stuck = Task { try await server.toolQueue.run { for await _ in gate { break } } }
        #expect(await Self.eventually { server.toolQueue.depth == 1 })
        server.stop()
        try await server.start(reason: .session)
        let log = CallLog()
        let next = Task {
            let result = await server.invokeTool(.init(name: "list_documents", arguments: [:]))
            log.order.append(1)
            return result
        }
        #expect(await Self.eventually { log.order == [1] }, "The restarted server's call waited behind the stuck one")
        open.finish()
        try await stuck.value
        #expect(await next.value.isError != true)
    }

    /// Polls `condition` on the main actor until it holds or `timeout` passes.
    private static func eventually(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    @Test func aCallThatRunsAfterStopLeavesTheDocumentAlone() async throws {
        let (server, workspace, _) = try await startServer()
        let tabsBefore = workspace.tabs.count
        server.stop()
        let result = await server.invokeTool(.init(name: "new_document", arguments: ["width": 10, "height": 10]))
        #expect(result.isError == true)
        #expect(workspace.tabs.count == tabsBefore)
    }

    @Test func aRequestWhoseIDCannotBeIsolatedIsRejectedWith400() async throws {
        let (server, workspace, port) = try await startServer()
        defer { server.stop() }
        _ = workspace
        let response = try await RawHTTP.post(port: port, body: #"{"jsonrpc":"2.0","id":{"n":1},"method":"tools/list","params":{}}"#)
        #expect(response.status == 400)
        let error = try #require(try RawHTTP.object(response.body)["error"] as? [String: Any])
        #expect(error["code"] != nil)
    }

    @Test func bytesPilingUpBehindAnInFlightRequestAreCutOffWith413() async throws {
        let (gate, open) = AsyncStream<Void>.makeStream()
        let (entered, enter) = AsyncStream<Void>.makeStream()
        defer { open.finish() }
        let listener = MCPHTTPListener(maxRequestBytes: 1024, handler: { _ in
            enter.yield()
            for await _ in gate { break }
            return .accepted()
        }, onFailure: { _ in })
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        // One request that stays in flight; once the handler has it, far more than the
        // limit follows with no end in sight.
        let request = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 2\r\n\r\n{}".utf8)
        let flood = Data(repeating: UInt8(ascii: "x"), count: 200_000)
        // The server answers 413 and closes at once. While the client is still sending,
        // closing with unread bytes can reset the connection before the 413 is read;
        // either way the connection was cut off. (Without the limit it hangs until
        // RawHTTP's timeout cancels it, which surfaces as ECANCELED.)
        do {
            let response = try await RawHTTP.exchange(port: port, bytes: request, then: {
                for await _ in entered { break }
            }, more: flood, timeout: .seconds(30))
            #expect(response.status == 413)
        } catch let error as NWError {
            guard case .posix(.ECONNRESET) = error else { throw error }
        }
    }

    /// Framings the parser can't trust, each with the status it answers: a Content-Length that isn't plain digits (a
    /// negative one used to crash the app, before any Host or Origin check), two that disagree, a list, any
    /// Transfer-Encoding (only Content-Length bodies are read), and a head that isn't HTTP at all.
    static let unusableFramings: [(headers: String, status: Int)] = [
        ("Content-Length: -1000\r\n", 400),
        ("Content-Length: \(Int.min)\r\n", 400),
        ("Content-Length: +2\r\n", 400),
        ("Content-Length: 0x2\r\n", 400),
        ("Content-Length: 2, 2\r\n", 400),
        ("Content-Length: 2\r\nContent-Length: 3\r\n", 400),
        ("Transfer-Encoding: chunked\r\n", 501),
        ("Content-Length: 2\r\nTransfer-Encoding: chunked\r\n", 501),
    ]

    /// Each is refused with its status and the connection closed, and the server goes on answering other requests.
    @Test func aRequestWhoseBodyCantBeFramedIsRefusedAndTheServerKeepsServing() async throws {
        let listener = MCPHTTPListener(maxRequestBytes: 1024, handler: { _ in .accepted() }, onFailure: { _ in })
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        for (headers, status) in Self.unusableFramings {
            let request = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\(headers)\r\n{}".utf8)
            let refused = try await RawHTTP.exchange(port: port, bytes: request)
            #expect(refused.status == status, "\(headers.debugDescription)")
            #expect(refused.headers["Connection"] == "close", "\(headers.debugDescription)")
        }
        let garbage = try await RawHTTP.exchange(port: port, bytes: Data("NOT-HTTP\r\n\r\n".utf8))
        #expect(garbage.status == 400)
        // Repeating one value is the same length, as HTTP allows.
        let repeated = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 2\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".utf8)
        #expect(try await RawHTTP.exchange(port: port, bytes: repeated).status == 202)
        let ordinary = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".utf8)
        #expect(try await RawHTTP.exchange(port: port, bytes: ordinary).status == 202)
    }

    /// A head that runs past 64 KiB without its blank line is cut off with 431 at once, rather than buffered up to the
    /// 32 MiB body limit and scanned again for every chunk that arrives.
    @Test func aHeadThatNeverEndsIsCutOffWith431() async throws {
        let listener = MCPHTTPListener(handler: { _ in .accepted() }, onFailure: { _ in })
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        var head = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n".utf8)
        head.append(Data("X-Padding: ".utf8) + Data(repeating: UInt8(ascii: "x"), count: 70 * 1024))
        do {
            let response = try await RawHTTP.exchange(port: port, bytes: head, timeout: .seconds(20))
            #expect(response.status == 431)
        } catch let error as NWError {
            // Closing with unread bytes can reset the connection before the 431 is read; it was cut off either way.
            // Without the limit the server waits for the rest, and the exchange times out (ECANCELED).
            guard case .posix(.ECONNRESET) = error else { throw error }
        }
    }

    /// A request must arrive whole within the listener's request timeout of its first byte: a client trickling bytes
    /// (each of which re-arms the 120-second idle timer) no longer holds its connection open for good.
    @Test func aRequestTrickledInIsCutOffAtItsDeadline() async throws {
        let listener = MCPHTTPListener(requestTimeout: .milliseconds(500), handler: { _ in .accepted() }, onFailure: { _ in })
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        let response = try await RawHTTP.trickle(port: port, head: Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n".utf8),
                                                 for: .seconds(20))
        #expect(response?.status == 408, "The server kept waiting for a request that never completed")
    }

    /// Connections past the listener's limit are answered 503 and closed at once, so idle sockets can't use up the
    /// file descriptors the app needs to open and save files; one that closes frees its place.
    @Test func connectionsPastTheLimitAreRefusedWith503() async throws {
        let listener = MCPHTTPListener(maxConnections: 2, handler: { _ in .accepted() }, onFailure: { _ in })
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        let held = (0..<2).map { _ in NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp) }
        for connection in held { connection.start(queue: DispatchQueue(label: "held")) }
        defer { for connection in held { connection.cancel() } }
        let request = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".utf8)
        // The held connections are accepted in their own time: ask until the server has counted them.
        func status(until expected: Int) async throws -> Int? {
            let deadline = ContinuousClock.now + .seconds(10)
            var last: Int?
            while ContinuousClock.now < deadline {
                last = try await RawHTTP.exchange(port: port, bytes: request).status
                if last == expected { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            return last
        }
        #expect(try await status(until: 503) == 503)
        held[0].cancel()
        #expect(try await status(until: 202) == 202)
    }
}

@MainActor private final class CallLog {
    var order: [Int] = []
}

/// A raw HTTP/1.1 client over `NWConnection`, so tests control every header (URLSession
/// won't let a caller set `Host`) and see exactly what the server sends back.
nonisolated enum RawHTTP {
    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data

        var accessControlHeaders: [String] {
            headers.keys.filter { $0.lowercased().hasPrefix("access-control-allow-") }
        }
    }

    static let jsonHeaders = ["Content-Type": "application/json", "Accept": "application/json, text/event-stream"]

    static func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // `@concurrent`: run on the global executor, not the caller's (MainActor) one, so a
    // busy main actor during a full parallel test run can't stall the exchange.
    @concurrent static func post(port: UInt16, body: String) async throws -> Response {
        try await send(port: port, method: "POST", headers: jsonHeaders, body: body)
    }

    @concurrent static func send(port: UInt16, method: String, headers: [String: String], body: String?) async throws -> Response {
        var all = ["Host": "127.0.0.1:\(port)", "Connection": "close"]
        all.merge(headers) { $1 }
        let bodyData = Data((body ?? "").utf8)
        all["Content-Length"] = String(bodyData.count)
        var head = "\(method) /mcp HTTP/1.1\r\n"
        for (name, value) in all { head += "\(name): \(value)\r\n" }
        var request = Data((head + "\r\n").utf8)
        request.append(bodyData)
        return try await exchange(port: port, bytes: request)
    }

    /// Sends `bytes` as they are and reads until the server closes the connection.
    /// With `more`, sends `bytes`, awaits `then`, and only then sends `more`. Gives up
    /// (cancelling the connection, which surfaces as ECANCELED) after `timeout`.
    @concurrent static func exchange(port: UInt16, bytes request: Data,
                                     then: (@Sendable () async -> Void)? = nil, more: Data? = nil,
                                     timeout: Duration = .seconds(10)) async throws -> Response {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "RawHTTP")
        connection.start(queue: queue)
        defer { connection.cancel() }
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            connection.cancel()
        }
        defer { watchdog.cancel() }
        connection.send(content: request, completion: .contentProcessed { _ in })
        if let more {
            // `then` may wait on the server; never wait on it longer than `timeout`.
            if let then {
                let proceeded = await withTaskGroup(of: Bool.self) { group in
                    group.addTask { await then(); return true }
                    group.addTask { try? await Task.sleep(for: timeout); return false }
                    let first = await group.next() ?? false
                    group.cancelAll()
                    return first
                }
                if !proceeded { throw POSIXError(.ETIMEDOUT) }
            }
            connection.send(content: more, completion: .contentProcessed { _ in })
        }

        var received = Data()
        while true {
            let (chunk, complete): (Data?, Bool) = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: (data, isComplete))
                    }
                }
            }
            if let chunk { received.append(chunk) }
            if complete || (chunk?.isEmpty ?? true) { break }
        }
        return try parse(received)
    }

    /// Sends `head`, then one more byte every 100 ms, for up to `duration` or until the server answers or closes;
    /// returns the answer, or nil when none came in that time.
    @concurrent static func trickle(port: UInt16, head: Data, for duration: Duration) async throws -> Response? {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: DispatchQueue(label: "RawHTTP.trickle"))
        defer { connection.cancel() }
        connection.send(content: head, completion: .contentProcessed { _ in })
        let dripping = Task {
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(100))
                connection.send(content: Data("X".utf8), completion: .contentProcessed { _ in })
            }
        }
        defer { dripping.cancel() }
        let watchdog = Task {
            try await Task.sleep(for: duration)
            connection.cancel()
        }
        defer { watchdog.cancel() }
        var received = Data()
        while true {
            let (chunk, complete): (Data?, Bool)
            do {
                (chunk, complete) = try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (data, isComplete)) }
                    }
                }
            } catch {
                // Cancelled by the watchdog: nothing (or nothing whole) came back in time.
                return received.isEmpty ? nil : try parse(received)
            }
            if let chunk { received.append(chunk) }
            if complete || (chunk?.isEmpty ?? true) { break }
        }
        return received.isEmpty ? nil : try parse(received)
    }

    private static func parse(_ data: Data) throws -> Response {
        let separator = Data("\r\n\r\n".utf8)
        let end = try #require(data.range(of: separator), "No HTTP header block in \(data.count) bytes")
        let text = try #require(String(data: data[..<end.lowerBound], encoding: .utf8))
        var lines = text.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ")
        let status = try #require(statusLine.count >= 2 ? Int(statusLine[1]) : nil)
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Response(status: status, headers: headers, body: Data(data[end.upperBound...]))
    }
}
