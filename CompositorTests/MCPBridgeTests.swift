import Foundation
import MCP
import Testing
@testable import Compositor

/// The `compositor-mcp` stdio bridge, run as a real child process: the helper embedded
/// in the test host's own bundle (`Compositor.app/Contents/MacOS/compositor-mcp`, put
/// there by the app's "Embed Helpers" phase), talking to an in-process server.
///
/// Every bridge runs with `--no-launch`, so it never opens or signals a real Compositor,
/// and is pointed at a temporary endpoint file or an explicit ephemeral-port URL: nothing
/// binds the default port or reads or writes the real `endpoint.json`.
///
/// Not `@MainActor`: only the test with a real `MCPServer` needs the main actor, and the
/// others must not wait for it while the rest of the suite keeps it busy.
struct MCPBridgeTests {
    @Test func theBridgeIsEmbeddedInTheAppBundle() {
        let url = BridgeProcess.executableURL
        #expect(url == MCPClientSnippets.bridgeURL(inAppBundle: Bundle.main.bundleURL))
        #expect(FileManager.default.isExecutableFile(atPath: url.path), "No bridge at \(url.path)")
    }

    @MainActor @Test func initializeAndListToolsThroughTheBridge() async throws {
        let workspace = MCPTestSupport.workspace()
        let endpointFile = MCPTestSupport.tempFile("mcp/endpoint.json")
        let server = MCPServer(options: .init(preferredPort: 0, endpointFileURL: endpointFile))
        server.workspace = workspace
        defer { server.stop() }
        try await server.start(reason: .session)

        let bridge = try BridgeProcess(arguments: ["--endpoint-file", endpointFile.path, "--no-launch"])
        defer { bridge.terminate() }
        bridge.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"bridge-test","version":"1"}}}"#)
        bridge.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        bridge.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#)

        var lines = bridge.lines.makeAsyncIterator()
        var responses: [Int: [String: Any]] = [:]
        for _ in 0..<2 {
            let line = try #require(await lines.next(), "The bridge exited early. stderr: \(bridge.errorOutput)")
            let object = try RawHTTP.object(Data(line.utf8))
            let id = try #require(object["id"] as? Int, "Unexpected line: \(line)")
            responses[id] = object
        }
        #expect(Set(responses.keys) == [1, 2])
        let initialize = try #require(responses[1]?["result"] as? [String: Any], "\(String(describing: responses[1]))")
        #expect((initialize["serverInfo"] as? [String: Any])?["name"] as? String == "Compositor")
        #expect(initialize["protocolVersion"] as? String == "2025-06-18")
        let list = try #require(responses[2]?["result"] as? [String: Any], "\(String(describing: responses[2]))")
        #expect((list["tools"] as? [Any])?.count == MCPToolRegistry.tools.count)

        // Closing stdin ends the bridge cleanly; the notification never produced a line.
        bridge.closeInput()
        let extra = await lines.next()
        #expect(extra == nil, "Unexpected output: \(extra ?? "")")
        #expect(await bridge.exitStatus() == 0)
    }

    /// The app's stateless transport refuses JSON-RPC batches with a single `"id": null`
    /// error; the bridge still answers every request in the batch, and keeps a refused
    /// batch of notifications off stdout.
    @MainActor @Test func aBatchSentToTheRealServerGetsOneAnswerPerRequest() async throws {
        let workspace = MCPTestSupport.workspace()
        let endpointFile = MCPTestSupport.tempFile("mcp/endpoint.json")
        let server = MCPServer(options: .init(preferredPort: 0, endpointFileURL: endpointFile))
        server.workspace = workspace
        defer { server.stop() }
        try await server.start(reason: .session)

        let bridge = try BridgeProcess(arguments: ["--endpoint-file", endpointFile.path, "--no-launch"])
        defer { bridge.terminate() }
        var lines = bridge.lines.makeAsyncIterator()
        bridge.send(#"[{"jsonrpc":"2.0","method":"notifications/initialized"}]"#)
        bridge.send(#"{"jsonrpc":"2.0","id":"after","method":"ping"}"#)
        // Nothing for the notification batch: the next line is the ping's answer.
        let ping = try #require(await lines.next(), "stderr: \(bridge.errorOutput)")
        #expect(try RawHTTP.object(Data(ping.utf8))["id"] as? String == "after", "\(ping)")

        bridge.send(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":"b","method":"tools/list","params":{}}]"#)
        let line = try #require(await lines.next(), "stderr: \(bridge.errorOutput)")
        let answers = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [[String: Any]],
                                   "A batch must be answered with an array: \(line)")
        #expect(answers.count == 2)
        #expect(answers.contains { $0["id"] as? Int == 1 } && answers.contains { $0["id"] as? String == "b" }, "\(line)")
        for answer in answers {
            #expect(answer["jsonrpc"] as? String == "2.0")
            #expect((answer["error"] as? [String: Any])?["code"] is Int, "\(answer)")
        }

        bridge.closeInput()
        let extra = await lines.next()
        #expect(extra == nil, "Unexpected output: \(extra ?? "")")
        #expect(await bridge.exitStatus() == 0)
    }

    /// Dependent tool calls written at once reach the server in stdin order even when the
    /// first is slow; a `ping` sent behind them is not held up.
    @Test func toolCallsReachTheServerInTheOrderTheyWereWritten() async throws {
        let recorder = RequestRecorder()
        let listener = MCPHTTPListener(handler: { request in
            recorder.record(request)
            if FakeServer.toolName(of: request) == "new_document" {
                try? await Task.sleep(for: .milliseconds(1000))
            }
            return FakeServer.answer(request)
        }, onFailure: { _ in })
        let port = try await listener.start(port: 0)
        defer { listener.stop() }

        let bridge = try BridgeProcess(arguments: ["--endpoint", "http://127.0.0.1:\(port)/mcp", "--no-launch"])
        defer { bridge.terminate() }
        var lines = bridge.lines.makeAsyncIterator()
        bridge.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"new_document","arguments":{}}}"#
                    + "\n" + #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"add_blank_layer","arguments":{}}}"#
                    + "\n" + #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"render_document","arguments":{}}}"#
                    + "\n" + #"{"jsonrpc":"2.0","id":4,"method":"ping"}"#)
        bridge.closeInput()

        var ids: [Int] = []
        while let line = await lines.next() {
            ids.append(try #require(try RawHTTP.object(Data(line.utf8))["id"] as? Int, "\(line)"))
        }
        #expect(await bridge.exitStatus() == 0)
        #expect(ids.first == 4, "The ping waited behind the slow tool call: \(ids)")
        #expect(ids.filter { $0 != 4 } == [1, 2, 3], "Answers: \(ids)")
        let calls = recorder.requests.compactMap(\.toolName)
        #expect(calls == ["new_document", "add_blank_layer", "render_document"], "Server saw \(calls)")
    }

    /// Claude Desktop closes the bridge's stdout and stderr together when it quits. The
    /// answer then has nowhere to go: the bridge must exit 0, not crash while logging.
    @Test func aClientThatClosesStdoutAndStderrMidCallLeavesTheBridgeExitingCleanly() async throws {
        let listener = MCPHTTPListener(handler: { request in
            if FakeServer.method(of: request) == "slow/answer" {
                try? await Task.sleep(for: .milliseconds(500))
            }
            return FakeServer.answer(request)
        }, onFailure: { _ in })
        let port = try await listener.start(port: 0)
        defer { listener.stop() }

        let bridge = try BridgeProcess(arguments: ["--endpoint", "http://127.0.0.1:\(port)/mcp", "--no-launch"])
        defer { bridge.terminate() }
        bridge.send(#"{"jsonrpc":"2.0","id":1,"method":"slow/answer"}"#)
        bridge.closeOutputs()
        let status = await bridge.exitStatus()
        #expect(status == 0, "The bridge ended with \(String(describing: status)) (\(bridge.terminationDescription))")
    }

    enum Unreachable: CaseIterable, Sendable {
        /// The file names a live process (this one), but nothing listens on its port:
        /// a reused pid must not be trusted without a probe.
        case livePIDClosedPort
        case deadPID
        case missingFile
    }

    @Test(arguments: Unreachable.allCases)
    func anUnreachableServerAnswersWithAJSONRPCErrorOnTheSameID(_ situation: Unreachable) async throws {
        let endpointFile = Self.tempEndpointFile()
        let closedPort = try await Self.closedLoopbackPort()
        switch situation {
        case .livePIDClosedPort: try MCPEndpointFile.write(Self.record(port: closedPort, pid: getpid()), to: endpointFile)
        case .deadPID: try MCPEndpointFile.write(Self.record(port: closedPort, pid: Int32.max), to: endpointFile)
        case .missingFile: break
        }

        let bridge = try BridgeProcess(arguments: ["--endpoint-file", endpointFile.path, "--no-launch"])
        defer { bridge.terminate() }
        bridge.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        bridge.send(#"{"jsonrpc":"2.0","id":"req-7","method":"tools/list","params":{}}"#)
        bridge.send(#"{"jsonrpc":"2.0","id":8,"method":"ping"}"#)

        var lines = bridge.lines.makeAsyncIterator()
        var errors: [String: [String: Any]] = [:]
        for _ in 0..<2 {
            let line = try #require(await lines.next(), "The bridge exited early. stderr: \(bridge.errorOutput)")
            let object = try RawHTTP.object(Data(line.utf8))
            #expect(object["jsonrpc"] as? String == "2.0")
            let error = try #require(object["error"] as? [String: Any], "Expected an error: \(line)")
            #expect(error["code"] as? Int == -32000)
            #expect((error["message"] as? String)?.hasPrefix("Compositor is not reachable: ") == true, "\(error)")
            errors["\(object["id"] ?? "nil")"] = object
        }
        #expect(Set(errors.keys) == ["req-7", "8"])
        #expect(errors["req-7"]?["id"] is String && errors["8"]?["id"] is Int, "ids keep their JSON type")

        bridge.closeInput()
        let extra = await lines.next()
        #expect(extra == nil, "Unexpected output: \(extra ?? "")")
        #expect(await bridge.exitStatus() == 0)
    }

    /// Endpoint files the bridge must not follow even though a live server answers at their URL.
    enum Untrusted: CaseIterable, Sendable {
        /// Others in the owner's group could rewrite it to send the bridge's traffic to a server of theirs.
        case groupWritable
        /// Any account on the Mac could rewrite it.
        case writableByAnyone
        /// The URL reaches 127.0.0.1 through a spelling Compositor never writes: the bridge follows 127.0.0.1,
        /// localhost and [::1] only, so a rewritten file can't send it off the Mac.
        case otherHost

        var reason: String {
            switch self {
            case .groupWritable, .writableByAnyone: "other users can change"
            case .otherHost: "isn't this Mac's loopback address"
            }
        }
    }

    @Test(arguments: Untrusted.allCases)
    func anEndpointFileTheBridgeCantTrustIsNotFollowed(_ situation: Untrusted) async throws {
        let listener = MCPHTTPListener(handler: { FakeServer.answer($0) }, onFailure: { _ in })
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        let endpointFile = Self.tempEndpointFile()
        var record = Self.record(port: port, pid: getpid())
        if situation == .otherHost { record.url = "http://127.1:\(port)/mcp" }
        try MCPEndpointFile.write(record, to: endpointFile)
        switch situation {
        case .groupWritable: try FileManager.default.setAttributes([.posixPermissions: 0o620], ofItemAtPath: endpointFile.path)
        case .writableByAnyone: try FileManager.default.setAttributes([.posixPermissions: 0o602], ofItemAtPath: endpointFile.path)
        case .otherHost: break
        }

        let bridge = try BridgeProcess(arguments: ["--endpoint-file", endpointFile.path, "--no-launch"])
        defer { bridge.terminate() }
        bridge.send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        var lines = bridge.lines.makeAsyncIterator()
        let line = try #require(await lines.next(), "The bridge exited early. stderr: \(bridge.errorOutput)")
        let object = try RawHTTP.object(Data(line.utf8))
        let error = try #require(object["error"] as? [String: Any], "The bridge followed the endpoint file: \(line)")
        let message = try #require(error["message"] as? String)
        #expect(message.hasPrefix("Compositor is not reachable: ") && message.contains(situation.reason), "\(message)")
        bridge.closeInput()
        #expect(await bridge.exitStatus() == 0)
    }

    /// A scripted server behind `--endpoint`: shows what the bridge sends (headers,
    /// bodies) and how it relays every kind of answer as exactly one stdout line.
    @Test func theBridgeRelaysEveryKindOfAnswerAndForwardsTheNegotiatedVersion() async throws {
        let recorder = RequestRecorder()
        let listener = MCPHTTPListener(handler: { request in
            recorder.record(request)
            return FakeServer.answer(request)
        }, onFailure: { _ in })
        let port = try await listener.start(port: 0)
        defer { listener.stop() }

        let bridge = try BridgeProcess(arguments: ["--endpoint", "http://127.0.0.1:\(port)/mcp", "--no-launch"])
        defer { bridge.terminate() }
        var lines = bridge.lines.makeAsyncIterator()

        bridge.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        let initialized = try #require(await lines.next(), "stderr: \(bridge.errorOutput)")
        #expect(try RawHTTP.object(Data(initialized.utf8))["id"] as? Int == 1)

        bridge.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        bridge.send(#"{"jsonrpc":"2.0","id":2,"method":"sse/answer"}"#)
        bridge.send(#"{"jsonrpc":"2.0","id":3,"method":"pretty/answer"}"#)
        bridge.send(#"[{"jsonrpc":"2.0","id":4,"method":"batch/one"},{"jsonrpc":"2.0","id":5,"method":"batch/two"}]"#)
        bridge.send(#"{"jsonrpc":"2.0","id":6,"method":"http/error"}"#)
        // Refused with an `"id": null` error: logged, never written to stdout.
        bridge.send(#"{"jsonrpc":"2.0","method":"notifications/refused"}"#)
        bridge.send(#"{"jsonrpc":"2.0","id":99,"result":{}}"#)
        bridge.send("this is not json")
        // Closing stdin at once: requests still in flight are answered before the bridge exits.
        bridge.closeInput()

        var output: [String] = []
        while let line = await lines.next() { output.append(line) }
        #expect(await bridge.exitStatus() == 0)
        #expect(output.count == 5, "Output: \(output) stderr: \(bridge.errorOutput)")

        var byID: [String: [String: Any]] = [:]
        var batch: [[String: Any]]?
        for line in output {
            let json = try JSONSerialization.jsonObject(with: Data(line.utf8))
            if let array = json as? [[String: Any]] {
                batch = array
            } else if let object = json as? [String: Any] {
                byID["\(object["id"] ?? "nil")"] = object
            }
        }
        // An SSE answer arrives as its JSON-RPC message; a pretty-printed one on one line.
        #expect((byID["2"]?["result"] as? [String: Any])?["via"] as? String == "sse")
        #expect((byID["3"]?["result"] as? [String: Any])?["text"] as? String == "two\nlines")
        // A batch is forwarded and answered as is.
        #expect(batch?.compactMap { $0["id"] as? Int }.sorted() == [4, 5])
        // An HTTP error whose body carries `"id": null` is handed back on the request's id.
        let httpError = try #require(byID["6"]?["error"] as? [String: Any], "\(byID)")
        #expect(httpError["code"] as? Int == -32600)
        // Unparsable input is refused locally, as JSON-RPC prescribes.
        #expect((byID["<null>"]?["error"] as? [String: Any])?["code"] as? Int == -32700, "\(byID.keys)")

        let requests = recorder.requests.filter { $0.method != "ping" }
        #expect(!requests.contains { $0.method == nil }, "Unparsable input must not reach the server")
        for request in requests {
            #expect(request.accept == "application/json, text/event-stream")
            #expect(request.contentType == "application/json")
            #expect(request.authorization == nil, "No token file, so no Authorization header")
            if request.method == "initialize" {
                #expect(request.protocolVersion == nil, "initialize carries its version in the body")
            } else {
                #expect(request.protocolVersion == "2025-03-26", "\(request.method ?? "batch") sent \(request.protocolVersion ?? "no version")")
            }
        }
        #expect(Set(requests.compactMap(\.method)) == ["initialize", "notifications/initialized", "sse/answer",
                                                       "pretty/answer", "http/error", "batch",
                                                       "notifications/refused", "response"])
    }

    @Test func anEndpointThatStopsAnsweringYieldsErrorsNotSilence() async throws {
        let listener = MCPHTTPListener(handler: { FakeServer.answer($0) }, onFailure: { _ in })
        let port = try await listener.start(port: 0)
        let bridge = try BridgeProcess(arguments: ["--endpoint", "http://127.0.0.1:\(port)/mcp", "--no-launch"])
        defer { bridge.terminate() }
        var lines = bridge.lines.makeAsyncIterator()

        bridge.send(#"{"jsonrpc":"2.0","id":1,"method":"pretty/answer"}"#)
        let first = try #require(await lines.next(), "stderr: \(bridge.errorOutput)")
        #expect(try RawHTTP.object(Data(first.utf8))["result"] != nil)

        listener.stop() // Compositor quit.
        bridge.send(#"{"jsonrpc":"2.0","id":2,"method":"pretty/answer"}"#)
        let second = try #require(await lines.next(), "stderr: \(bridge.errorOutput)")
        let object = try RawHTTP.object(Data(second.utf8))
        #expect(object["id"] as? Int == 2)
        #expect((object["error"] as? [String: Any])?["code"] as? Int == -32000, "\(second)")
        bridge.closeInput()
        #expect(await bridge.exitStatus() == 0)
    }

    // MARK: - The access token

    /// The zero-configuration path of a stdio client (Claude Desktop, Hermes): a server that requires its token,
    /// found through the endpoint file, which names the token file. The bridge reads the token and sends it on every
    /// request, and a regenerated token is picked up without restarting anything.
    @MainActor @Test func theBridgeSendsTheTokenTheEndpointFileNames() async throws {
        let workspace = MCPTestSupport.workspace()
        let folder = MCPTestSupport.tempFile("mcp")
        let endpointFile = folder.appendingPathComponent("endpoint.json")
        let tokenFile = folder.appendingPathComponent("token")
        let server = MCPServer(options: .init(preferredPort: 0, endpointFileURL: endpointFile,
                                              tokenFileURL: tokenFile, requiresToken: true))
        server.workspace = workspace
        defer { server.stop() }
        try await server.start(reason: .session)
        #expect(try await RawHTTP.post(port: server.port, body: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#).status == 401,
                "The server must require the token")

        let bridge = try BridgeProcess(arguments: ["--endpoint-file", endpointFile.path, "--no-launch"])
        defer { bridge.terminate() }
        var lines = bridge.lines.makeAsyncIterator()
        bridge.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"bridge-test","version":"1"}}}"#)
        bridge.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        let initialized = try #require(await lines.next(), "stderr: \(bridge.errorOutput)")
        #expect((try RawHTTP.object(Data(initialized.utf8))["result"] as? [String: Any])?["serverInfo"] != nil, "\(initialized)")
        bridge.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#)
        let list = try #require(await lines.next(), "stderr: \(bridge.errorOutput)")
        #expect(((try RawHTTP.object(Data(list.utf8))["result"] as? [String: Any])?["tools"] as? [Any])?.count
                == MCPToolRegistry.tools.count, "\(list.prefix(300))")

        let old = try server.currentToken()
        let new = try server.regenerateToken()
        bridge.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_documents","arguments":{}}}"#)
        let call = try #require(await lines.next(), "stderr: \(bridge.errorOutput)")
        let result = try #require(try RawHTTP.object(Data(call.utf8))["result"] as? [String: Any], "\(call.prefix(300))")
        #expect(result["isError"] as? Bool != true)

        bridge.closeInput()
        #expect(await lines.next() == nil)
        #expect(await bridge.exitStatus() == 0)
        #expect(!bridge.errorOutput.contains(old) && !bridge.errorOutput.contains(new), "The bridge logged the token")
    }

    /// A bridge that found the server while the token was off keeps working once it's turned on: the 401 sends it
    /// back to the endpoint file, which now names the token file.
    @MainActor @Test func aBridgeKeepsWorkingWhenTheTokenIsTurnedOn() async throws {
        let workspace = MCPTestSupport.workspace()
        let folder = MCPTestSupport.tempFile("mcp")
        let endpointFile = folder.appendingPathComponent("endpoint.json")
        let server = MCPServer(options: .init(preferredPort: 0, endpointFileURL: endpointFile,
                                              tokenFileURL: folder.appendingPathComponent("token"), requiresToken: false))
        server.workspace = workspace
        defer { server.stop() }
        try await server.start(reason: .session)

        let bridge = try BridgeProcess(arguments: ["--endpoint-file", endpointFile.path, "--no-launch"])
        defer { bridge.terminate() }
        var lines = bridge.lines.makeAsyncIterator()
        bridge.send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        let before = try #require(await lines.next(), "stderr: \(bridge.errorOutput)")
        #expect(try RawHTTP.object(Data(before.utf8))["result"] != nil, "\(before)")

        try server.setRequiresToken(true)
        bridge.send(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        let after = try #require(await lines.next(), "stderr: \(bridge.errorOutput)")
        #expect(try RawHTTP.object(Data(after.utf8))["result"] != nil, "\(after)")
        bridge.closeInput()
        #expect(await bridge.exitStatus() == 0)
    }

    /// The server refuses the bridge's token (here: none, with an explicit `--endpoint`): the client gets an error
    /// on its own id that says what to do. `--token-file` supplies the token for an explicit endpoint.
    @MainActor @Test func aRefusedTokenIsAnErrorWithAHintAndTokenFileSuppliesOne() async throws {
        let workspace = MCPTestSupport.workspace()
        let folder = MCPTestSupport.tempFile("mcp")
        let tokenFile = folder.appendingPathComponent("token")
        let server = MCPServer(options: .init(preferredPort: 0, endpointFileURL: nil, tokenFileURL: tokenFile, requiresToken: true))
        server.workspace = workspace
        defer { server.stop() }
        try await server.start(reason: .session)
        let url = try #require(server.endpointURL).absoluteString

        let refused = try BridgeProcess(arguments: ["--endpoint", url, "--no-launch"])
        defer { refused.terminate() }
        var refusedLines = refused.lines.makeAsyncIterator()
        refused.send(#"{"jsonrpc":"2.0","id":"a","method":"ping"}"#)
        let line = try #require(await refusedLines.next(), "stderr: \(refused.errorOutput)")
        let object = try RawHTTP.object(Data(line.utf8))
        #expect(object["id"] as? String == "a")
        let error = try #require(object["error"] as? [String: Any], "\(line)")
        #expect(error["code"] as? Int == -32000)
        let message = try #require(error["message"] as? String)
        #expect(message.contains("access token changed or is missing; restart the client or re-copy the setup snippet"), "\(message)")
        refused.closeInput()
        #expect(await refused.exitStatus() == 0)

        let given = try BridgeProcess(arguments: ["--endpoint", url, "--token-file", tokenFile.path, "--no-launch"])
        defer { given.terminate() }
        var givenLines = given.lines.makeAsyncIterator()
        given.send(#"{"jsonrpc":"2.0","id":"b","method":"ping"}"#)
        let answer = try #require(await givenLines.next(), "stderr: \(given.errorOutput)")
        #expect(try RawHTTP.object(Data(answer.utf8))["result"] != nil, "\(answer)")
        given.closeInput()
        #expect(await given.exitStatus() == 0)
    }

    /// A 401 the bridge gets after it found the server (the token changed under it) is tried once more after looking
    /// the endpoint up again, then answered with the hint; the token file's token rides on every request.
    @Test func aRequestRefusedWith401IsRetriedOnceThenAnsweredWithTheHint() async throws {
        let recorder = RequestRecorder()
        let listener = MCPHTTPListener(handler: { request in
            recorder.record(request)
            return FakeServer.answer(request)
        }, onFailure: { _ in })
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        let tokenFile = Self.tempEndpointFile().deletingLastPathComponent().appendingPathComponent("token")
        let token = try MCPAccessToken.regenerate(at: tokenFile)

        let bridge = try BridgeProcess(arguments: ["--endpoint", "http://127.0.0.1:\(port)/mcp", "--token-file", tokenFile.path,
                                                   "--no-launch"])
        defer { bridge.terminate() }
        var lines = bridge.lines.makeAsyncIterator()
        bridge.send(#"{"jsonrpc":"2.0","id":7,"method":"unauthorized/answer"}"#)
        let line = try #require(await lines.next(), "stderr: \(bridge.errorOutput)")
        let object = try RawHTTP.object(Data(line.utf8))
        #expect(object["id"] as? Int == 7)
        let message = try #require((object["error"] as? [String: Any])?["message"] as? String, "\(line)")
        #expect(message.contains("HTTP 401") && message.contains("restart the client or re-copy the setup snippet"), "\(message)")
        bridge.closeInput()
        #expect(await bridge.exitStatus() == 0)

        let requests = recorder.requests
        #expect(requests.filter { $0.method == "unauthorized/answer" }.count == 2, "\(requests.map(\.method))")
        #expect(!requests.isEmpty && requests.allSatisfy { $0.authorization == "Bearer \(token)" },
                "Every request, probes included, carries the token")
        #expect(!bridge.errorOutput.contains(token), "The bridge logged the token")
        // Its diagnostic log says it retried after the 401, and never holds the token either.
        let events = try bridge.logEvents()
        #expect(events.contains { $0["event"] as? String == "retry_401" }, "\(events)")
        let forward = try #require(events.first { $0["event"] as? String == "forward" }, "\(events)")
        #expect(forward["status"] as? Int == 401 && forward["method"] as? String == "unauthorized/answer", "\(forward)")
        #expect(!(try bridge.logText()).contains(token), "The bridge's log holds the token")
    }

    /// The bridge's log (`--log-file`): its start, each line it forwarded (method, id, tool, HTTP status, JSON-RPC
    /// error code, how long it took) and why it exited. A bridge that can't connect says so too.
    @Test func theBridgeLogsItsStartEachForwardedRequestAndItsExit() async throws {
        let listener = MCPHTTPListener(handler: { request in FakeServer.answer(request) }, onFailure: { _ in })
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        let bridge = try BridgeProcess(arguments: ["--endpoint", "http://127.0.0.1:\(port)/mcp", "--no-launch"])
        defer { bridge.terminate() }
        var lines = bridge.lines.makeAsyncIterator()
        bridge.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"new_document","arguments":{"width":64}}}"#)
        _ = try #require(await lines.next(), "stderr: \(bridge.errorOutput)")
        bridge.send(#"{"jsonrpc":"2.0","id":"b","method":"http/error"}"#)
        _ = try #require(await lines.next(), "stderr: \(bridge.errorOutput)")
        bridge.closeInput()
        #expect(await bridge.exitStatus() == 0)

        let events = try bridge.logEvents()
        let start = try #require(events.first, "Nothing logged")
        #expect(start["event"] as? String == "start" && start["cat"] as? String == "bridge", "\(start)")
        #expect((start["args"] as? [String])?.contains("--no-launch") == true && start["endpoint_source"] as? String == "url", "\(start)")
        #expect(start["pid"] is Int && (start["ts"] as? String)?.hasSuffix("Z") == true, "\(start)")
        let forwards = events.filter { $0["event"] as? String == "forward" }
        #expect(forwards.count == 2, "\(forwards)")
        let call = try #require(forwards.first)
        #expect(call["method"] as? String == "tools/call" && call["tool"] as? String == "new_document", "\(call)")
        #expect(call["id"] as? String == "1" && call["status"] as? Int == 200 && call["duration_ms"] is Double, "\(call)")
        #expect(call["rpc_error"] == nil && (call["response_bytes"] as? Int).map { $0 > 0 } == true, "\(call)")
        let refused = try #require(forwards.last)
        #expect(refused["status"] as? Int == 400 && refused["rpc_error"] as? Int == -32600, "\(refused)")
        #expect(events.last?["event"] as? String == "exit" && events.last?["reason"] as? String == "stdin_closed", "\(events)")
        #expect(!(try bridge.logText()).contains("\"width\""), "The bridge logged a call's arguments")
    }

    @Test func aConnectionFailureIsLogged() async throws {
        let closedPort = try await Self.closedLoopbackPort()
        let bridge = try BridgeProcess(arguments: ["--endpoint", "http://127.0.0.1:\(closedPort)/mcp", "--no-launch"])
        defer { bridge.terminate() }
        var lines = bridge.lines.makeAsyncIterator()
        bridge.send(#"{"jsonrpc":"2.0","id":9,"method":"ping"}"#)
        _ = try #require(await lines.next(), "stderr: \(bridge.errorOutput)")
        bridge.closeInput()
        #expect(await bridge.exitStatus() == 0)
        let events = try bridge.logEvents()
        let absent = try #require(events.first { $0["event"] as? String == "unreachable" }, "\(events)")
        #expect(absent["method"] as? String == "ping" && absent["id"] as? String == "9", "\(absent)")
        #expect((absent["reason"] as? String)?.contains("nothing answers") == true, "\(absent)")
        #expect(absent["level"] as? String == "warning")
    }

    // MARK: - Naming the client

    /// Every POST says it came through the bridge, and once the client's `initialize` has gone by, every POST names
    /// that client too: `name/version`, percent-encoded to printable ASCII other than `%` and `/`, at most 100
    /// characters, cut between characters. A later `initialize` names its client from then on.
    @Test func theBridgeNamesTheClientThatInitializedOnEveryLaterRequest() async throws {
        let recorder = RequestRecorder()
        let listener = MCPHTTPListener(handler: { request in
            recorder.record(request)
            return FakeServer.answer(request)
        }, onFailure: { _ in })
        let port = try await listener.start(port: 0)
        defer { listener.stop() }

        let bridge = try BridgeProcess(arguments: ["--endpoint", "http://127.0.0.1:\(port)/mcp", "--no-launch"])
        defer { bridge.terminate() }
        var lines = bridge.lines.makeAsyncIterator()
        func initialize(_ id: Int, name: String, version: String) -> String {
            #"{"jsonrpc":"2.0","id":\#(id),"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"\#(name)","version":"\#(version)"}}}"#
        }
        bridge.send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        _ = try #require(await lines.next(), "stderr: \(bridge.errorOutput)")
        bridge.send(initialize(2, name: "Hermes Agent/β", version: "0.9"))
        bridge.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        _ = try #require(await lines.next(), "stderr: \(bridge.errorOutput)")
        bridge.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_documents","arguments":{}}}"#)
        _ = try #require(await lines.next(), "stderr: \(bridge.errorOutput)")
        // Sixty two-byte characters: six escaped characters each, too many for the 98 the name may take here.
        bridge.send(initialize(4, name: String(repeating: "é", count: 60), version: "1"))
        _ = try #require(await lines.next(), "stderr: \(bridge.errorOutput)")
        bridge.send(#"{"jsonrpc":"2.0","id":5,"method":"ping"}"#)
        _ = try #require(await lines.next(), "stderr: \(bridge.errorOutput)")
        bridge.closeInput()
        #expect(await bridge.exitStatus() == 0)

        let requests = recorder.requests
        #expect(requests.count >= 6 && requests.allSatisfy { $0.transport == "bridge" },
                "Every POST, the endpoint probe included, says it's the bridge: \(requests.map(\.transport))")
        func request(_ id: String) throws -> RequestRecorder.Request {
            try #require(requests.first { $0.id == id }, "No request \(id): \(requests.map(\.id))")
        }
        #expect(try request("1").client == nil, "No client is known before initialize")
        #expect(try request("3").client == "Hermes%20Agent%2F%CE%B2/0.9")
        #expect(requests.first { $0.method == "notifications/initialized" }?.client == "Hermes%20Agent%2F%CE%B2/0.9")
        let long = try #require(try request("5").client)
        #expect(long.count <= 100, "\(long.count) characters")
        #expect(MCPBridgeHeaders.client(fromHeader: long) == MCPClientInfo(name: String(repeating: "é", count: 16), version: "1"),
                "\(long)")
    }

    /// A stdio client's tool calls reach Compositor's log under its own name, whichever connection they arrive on,
    /// marked as bridged. The bridge's headers leave the token requirement as it was, and the log never holds the token.
    @MainActor @Test func aBridgedToolCallIsLoggedWithTheClientThatInitialized() async throws {
        let harness = LogHarness()
        defer { harness.remove() }
        let workspace = MCPTestSupport.workspace()
        let folder = MCPTestSupport.tempFile("mcp")
        let endpointFile = folder.appendingPathComponent("endpoint.json")
        let server = MCPServer(options: .init(preferredPort: 0, endpointFileURL: endpointFile,
                                              tokenFileURL: folder.appendingPathComponent("token"), requiresToken: true,
                                              log: harness.log))
        server.workspace = workspace
        defer { server.stop() }
        try await server.start(reason: .session)
        let token = try server.currentToken()

        let bridge = try BridgeProcess(arguments: ["--endpoint-file", endpointFile.path, "--no-launch"])
        defer { bridge.terminate() }
        var lines = bridge.lines.makeAsyncIterator()
        bridge.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"bridge-log-test","version":"2.0 β"}}}"#)
        bridge.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        _ = try #require(await lines.next(), "stderr: \(bridge.errorOutput)")
        bridge.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_documents","arguments":{}}}"#)
        let answer = try #require(await lines.next(), "stderr: \(bridge.errorOutput)")
        let result = try #require(try RawHTTP.object(Data(answer.utf8))["result"] as? [String: Any], "\(answer.prefix(300))")
        #expect(result["isError"] as? Bool != true)
        bridge.closeInput()
        #expect(await bridge.exitStatus() == 0)

        let expected = ["name": "bridge-log-test", "version": "2.0 β"]
        let call = try await harness.eventually(named: "tool_call")
        #expect(call["tool"] as? String == "list_documents" && call["rpc_id"] as? String == "2", "\(call)")
        #expect(call["client"] as? [String: String] == expected, "\(call)")
        #expect(call["via"] as? String == "bridge", "\(call)")
        let hello = try #require(try harness.events(named: "rpc").first { $0["method"] as? String == "initialize" })
        #expect(hello["client"] as? [String: String] == expected && hello["via"] as? String == "bridge", "\(hello)")
        #expect(!(try harness.text()).contains(token), "The log holds the token")
    }

    /// Token files the bridge must not use: the token is never read from them, nor sent anywhere.
    enum UnusableTokenFile: CaseIterable, Sendable {
        /// Any account on the Mac could read the token (0644).
        case readableByAnyone
        /// Others in the owner's group could read it (0640).
        case readableByTheGroup
        /// Not there (or unreadable): the app makes it when its server starts.
        case missing
        /// Not a token at all.
        case malformed

        var reason: String {
            switch self {
            case .readableByAnyone, .readableByTheGroup: "open to other users"
            case .missing: "can't be read"
            case .malformed: "doesn't hold a token"
            }
        }
    }

    @Test(arguments: UnusableTokenFile.allCases)
    func aTokenFileTheBridgeCantTrustIsNeverSent(_ situation: UnusableTokenFile) async throws {
        let recorder = RequestRecorder()
        let listener = MCPHTTPListener(handler: { request in
            recorder.record(request)
            return FakeServer.answer(request)
        }, onFailure: { _ in })
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        let endpointFile = Self.tempEndpointFile()
        let tokenFile = endpointFile.deletingLastPathComponent().appendingPathComponent("token")
        var record = Self.record(port: port, pid: getpid())
        record.auth = MCPEndpointRecord.bearerAuth
        record.token_file = tokenFile.path
        try MCPEndpointFile.write(record, to: endpointFile)
        switch situation {
        case .readableByAnyone, .readableByTheGroup:
            _ = try MCPAccessToken.regenerate(at: tokenFile)
            try FileManager.default.setAttributes([.posixPermissions: situation == .readableByAnyone ? 0o644 : 0o640],
                                                  ofItemAtPath: tokenFile.path)
        case .missing:
            break
        case .malformed:
            try Data("not a token".utf8).write(to: tokenFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        }

        let bridge = try BridgeProcess(arguments: ["--endpoint-file", endpointFile.path, "--no-launch"])
        defer { bridge.terminate() }
        bridge.send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        var lines = bridge.lines.makeAsyncIterator()
        let line = try #require(await lines.next(), "The bridge exited early. stderr: \(bridge.errorOutput)")
        let object = try RawHTTP.object(Data(line.utf8))
        #expect(object["id"] as? Int == 1)
        let error = try #require(object["error"] as? [String: Any], "The bridge used the token file: \(line)")
        #expect(error["code"] as? Int == -32000)
        let message = try #require(error["message"] as? String)
        #expect(message.contains(situation.reason) && message.contains(tokenFile.path), "\(message)")
        bridge.closeInput()
        #expect(await bridge.exitStatus() == 0)
        #expect(recorder.requests.isEmpty, "Nothing may be sent without a trustworthy token: \(recorder.requests.map(\.method))")
    }

    @Test func badArgumentsExitWithAUsageErrorAndWriteNothingToStdout() async throws {
        let bridge = try BridgeProcess(arguments: ["--no-such-flag"])
        defer { bridge.terminate() }
        var lines = bridge.lines.makeAsyncIterator()
        let line = await lines.next()
        #expect(line == nil)
        #expect(await bridge.exitStatus() == 64)
        #expect(bridge.errorOutput.contains("--no-such-flag"))
    }

    // MARK: - Helpers

    /// A path in a fresh temporary folder (like `MCPTestSupport.tempFile`, minus the main actor).
    private static func tempEndpointFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPBridgeTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("mcp/endpoint.json")
    }

    private static func record(port: UInt16, pid: Int32) -> MCPEndpointRecord {
        MCPEndpointRecord(url: "http://127.0.0.1:\(port)/mcp", port: port, pid: pid, app_version: "9.9",
                          protocol: "2025-06-18", transport: MCPEndpointRecord.statelessTransport,
                          started_at: Date())
    }

    /// A loopback port nothing listens on any more (bound, then released).
    private static func closedLoopbackPort() async throws -> UInt16 {
        let listener = MCPHTTPListener(handler: { _ in .accepted() }, onFailure: { _ in })
        let port = try await listener.start(port: 0)
        listener.stop()
        try await Task.sleep(for: .milliseconds(50))
        return port
    }
}

/// Answers for the scripted server, chosen by JSON-RPC method.
private nonisolated enum FakeServer {
    static func toolName(of request: HTTPRequest) -> String? {
        let json = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        return ((json as? [String: Any])?["params"] as? [String: Any])?["name"] as? String
    }

    static func method(of request: HTTPRequest) -> String? {
        let json = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        return (json as? [String: Any])?["method"] as? String
    }

    static func answer(_ request: HTTPRequest) -> HTTPResponse {
        let body = request.body ?? Data()
        let json = try? JSONSerialization.jsonObject(with: body)
        if let batch = json as? [[String: Any]] {
            let answers = batch.map { ["jsonrpc": "2.0", "id": $0["id"] ?? NSNull(), "result": [:] as [String: Any]] }
            return .data(try! JSONSerialization.data(withJSONObject: answers), headers: ["Content-Type": "application/json"])
        }
        guard let object = json as? [String: Any], let method = object["method"] as? String else {
            return .error(statusCode: 400, .parseError("Parse error"))
        }
        if method == "notifications/refused" {
            return .error(statusCode: 400, .invalidRequest("Bad Request: scripted refusal"))
        }
        guard let id = object["id"] else { return .accepted() }
        func result(_ value: [String: Any], options: JSONSerialization.WritingOptions = []) -> Data {
            try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": value], options: options)
        }
        switch method {
        case "initialize":
            let params = object["params"] as? [String: Any]
            return .data(result(["protocolVersion": params?["protocolVersion"] ?? "2025-06-18",
                                 "capabilities": [:] as [String: Any],
                                 "serverInfo": ["name": "Fake", "version": "1"]]),
                         headers: ["Content-Type": "application/json"])
        case "sse/answer":
            var stream = Data("event: message\n".utf8)
            stream.append(Data("data: ".utf8))
            stream.append(result(["via": "sse"]))
            stream.append(Data("\n\n".utf8))
            return .data(stream, headers: ["Content-Type": "text/event-stream"])
        case "http/error":
            return .error(statusCode: 400, .invalidRequest("Bad Request: scripted"))
        case "unauthorized/answer":
            return .error(statusCode: 401, .invalidRequest("Unauthorized: scripted"),
                          extraHeaders: ["WWW-Authenticate": #"Bearer realm="Compositor""#])
        default:
            return .data(result(["text": "two\nlines"], options: .prettyPrinted), headers: ["Content-Type": "application/json"])
        }
    }
}

/// What the scripted server received.
private nonisolated final class RequestRecorder: @unchecked Sendable {
    struct Request: Sendable {
        /// The JSON-RPC method; `"batch"` for an array, `"response"` for a response to the
        /// server; nil when the body isn't JSON-RPC.
        let method: String?
        let accept: String?
        let contentType: String?
        let protocolVersion: String?
        /// The Authorization header, if any.
        let authorization: String?
        /// `params.name` of a `tools/call`.
        let toolName: String?
        /// The JSON-RPC id, as text.
        let id: String?
        /// The bridge's own headers (`BridgeHeaders`), as sent.
        let client: String?
        let transport: String?
    }

    private let lock = NSLock()
    private var recorded: [Request] = []

    var requests: [Request] { lock.withLock { recorded } }

    func record(_ request: HTTPRequest) {
        let json = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let object = json as? [String: Any]
        let method: String? = json is [Any] ? "batch"
            : object?["method"] as? String ?? (object?["result"] != nil ? "response" : nil)
        let entry = Request(method: method, accept: request.header("Accept"),
                            contentType: request.header("Content-Type"),
                            protocolVersion: request.header("MCP-Protocol-Version"),
                            authorization: request.header("Authorization"),
                            toolName: method == "tools/call" ? FakeServer.toolName(of: request) : nil,
                            id: object?["id"].map { "\($0)" },
                            client: request.header(MCPBridgeHeaders.clientHeader),
                            transport: request.header(MCPBridgeHeaders.transportHeader))
        lock.withLock { recorded.append(entry) }
    }
}

/// `compositor-mcp` as a child process with piped stdio. Output lines arrive on `lines`;
/// a watchdog terminates the process if a test forgets to, or hangs.
nonisolated final class BridgeProcess: @unchecked Sendable {
    /// The helper inside the test host (the app), where the Settings snippet points too.
    static var executableURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/compositor-mcp")
    }

    let lines: AsyncStream<String>
    /// The bridge's diagnostic log: in a temporary folder unless the test passes `--log-file` or `--no-log` itself,
    /// so no test writes the real `~/Library/Logs/Compositor/bridge.jsonl`.
    let logFile: URL
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let exited: AsyncStream<Int32>
    private let lock = NSLock()
    private var pendingOutput = Data()
    private var collectedErrors = Data()
    private var watchdog: Task<Void, Never>?

    init(arguments: [String], timeout: Duration = .seconds(120)) throws {
        let (lines, linesContinuation) = AsyncStream.makeStream(of: String.self)
        let (exited, exitContinuation) = AsyncStream.makeStream(of: Int32.self)
        self.lines = lines
        self.exited = exited
        process.executableURL = Self.executableURL
        logFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPBridgeTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("bridge.jsonl")
        let choosesItsLog = arguments.contains("--log-file") || arguments.contains("--no-log")
        process.arguments = choosesItsLog ? arguments : ["--log-file", logFile.path] + arguments
        // The helper is built with code coverage when the tests are: keep its profile
        // data (and anything else relative) out of the host's working directory, the repo.
        let scratch = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["LLVM_PROFILE_FILE"] = scratch.appendingPathComponent("compositor-mcp-%p.profraw").path
        process.environment = environment
        process.currentDirectoryURL = scratch
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { process in
            exitContinuation.yield(process.terminationStatus)
            exitContinuation.finish()
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                for line in self.takeLines(appending: Data([0x0A])) { linesContinuation.yield(line) }
                linesContinuation.finish()
            } else {
                for line in self.takeLines(appending: data) { linesContinuation.yield(line) }
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.lock.withLock { self?.collectedErrors.append(data) }
        }
        // Writing to a bridge that already exited must fail with EPIPE, not raise SIGPIPE
        // and take the whole test host down.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        let process = self.process
        watchdog = Task.detached {
            try? await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }
    }

    deinit { watchdog?.cancel() }

    /// Everything in the bridge's log file so far.
    func logText() throws -> String {
        try String(contentsOf: logFile, encoding: .utf8)
    }

    /// The bridge's log events so far, oldest first.
    func logEvents() throws -> [[String: Any]] {
        try logText().split(separator: "\n").map { line in
            try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], "Not an object: \(line)")
        }
    }

    /// Everything the bridge wrote to stderr so far, for failure messages.
    var errorOutput: String {
        lock.withLock { String(decoding: collectedErrors, as: UTF8.self) }
    }

    func send(_ line: String) {
        try? input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    func closeInput() {
        try? input.fileHandleForWriting.close()
    }

    /// Closes this end of the bridge's stdout and stderr, as a client that quits does.
    func closeOutputs() {
        for pipe in [output, errors] {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
        }
    }

    /// How the process ended, for failure messages.
    var terminationDescription: String {
        guard !process.isRunning else { return "still running" }
        let reason = process.terminationReason == .uncaughtSignal ? "signal" : "exit"
        return "\(reason) \(process.terminationStatus), stderr: \(errorOutput)"
    }

    func terminate() {
        watchdog?.cancel()
        if process.isRunning { process.terminate() }
    }

    func exitStatus() async -> Int32? {
        var iterator = exited.makeAsyncIterator()
        return await iterator.next()
    }

    /// Appends `data` and returns the complete, non-empty lines now buffered.
    private func takeLines(appending data: Data) -> [String] {
        lock.withLock {
            pendingOutput.append(data)
            var lines: [String] = []
            while let newline = pendingOutput.firstIndex(of: 0x0A) {
                let line = pendingOutput[pendingOutput.startIndex..<newline]
                pendingOutput.removeSubrange(pendingOutput.startIndex...newline)
                if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
            }
            return lines
        }
    }
}
