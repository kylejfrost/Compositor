import Foundation
import MCP
import Testing
@testable import Compositor

/// The access token Compositor's MCP server requires by default: how it is made and kept (`MCPAccessToken`), checked
/// from a request's head before its body is read (`MCPAccessGate` in `MCPHTTPListener`), published (endpoint.json,
/// get_app_info) and changed (Regenerate, the Settings switch).
///
/// Every server binds an ephemeral port and keeps its token and endpoint file in a fresh temporary folder: nothing
/// reads or writes the real token or endpoint file. Failure messages name statuses and paths, never a token.
@MainActor struct MCPAccessTokenTests {
    /// The document workspace every server here serves (a server holds it weakly).
    private let workspace = MCPTestSupport.workspace()

    /// A running server whose token (and endpoint file) live in `folder`, a fresh temporary `mcp` folder.
    private func startServer(requiresToken: Bool = true) async throws -> (server: MCPServer, folder: URL) {
        let folder = MCPTestSupport.tempFile("mcp")
        let server = MCPServer(options: .init(preferredPort: 0,
                                              endpointFileURL: folder.appendingPathComponent("endpoint.json"),
                                              tokenFileURL: folder.appendingPathComponent("token"),
                                              requiresToken: requiresToken))
        server.workspace = workspace
        try await server.start(reason: .session)
        return (server, folder)
    }

    private static let listTools = #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#

    private static func bearer(_ token: String) -> [String: String] {
        RawHTTP.jsonHeaders.merging(["Authorization": "Bearer \(token)"]) { $1 }
    }

    private static func storedToken(in folder: URL) throws -> String {
        try String(contentsOf: folder.appendingPathComponent("token"), encoding: .utf8)
    }

    private static func permissions(_ url: URL) throws -> Int {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    // MARK: - The token and its file

    @Test func aTokenIs32RandomBytesInBase64URLWithoutPadding() throws {
        let first = try MCPAccessToken.generate(), second = try MCPAccessToken.generate()
        #expect(first != second)
        for token in [first, second] {
            #expect(token.count == 43 && MCPAccessToken.isWellFormed(token))
            #expect(token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
            let base64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
            #expect(Data(base64Encoded: base64)?.count == 32)
        }
        for malformed in ["", "short", String(repeating: "a", count: 42), String(repeating: "a", count: 44),
                          String(repeating: "a", count: 42) + "=", String(repeating: "a", count: 42) + "\n"] {
            #expect(!MCPAccessToken.isWellFormed(malformed), "\(malformed.debugDescription)")
        }
    }

    @Test func theTokenFileIsOwnerOnlyInAnOwnerOnlyFolderAndKeptAcrossRestarts() async throws {
        let (server, folder) = try await startServer()
        defer { server.stop() }
        let tokenFile = folder.appendingPathComponent("token")
        let token = try Self.storedToken(in: folder)
        #expect(MCPAccessToken.isWellFormed(token))
        #expect(try Self.permissions(tokenFile) == 0o600)
        #expect(try Self.permissions(folder) == 0o700)
        #expect(try await RawHTTP.send(port: server.port, method: "POST", headers: Self.bearer(token), body: Self.listTools).status == 200)

        // The same token after a restart, and for a new server (the next launch) using the same file.
        server.stop()
        try await server.start(reason: .session)
        #expect(try Self.storedToken(in: folder) == token)
        #expect(try await RawHTTP.send(port: server.port, method: "POST", headers: Self.bearer(token), body: Self.listTools).status == 200)
        server.stop()
        let next = MCPServer(options: server.options)
        next.workspace = workspace
        defer { next.stop() }
        try await next.start(reason: .session)
        #expect(try Self.storedToken(in: folder) == token)
        #expect(try await RawHTTP.send(port: next.port, method: "POST", headers: Self.bearer(token), body: Self.listTools).status == 200)
    }

    @Test func looserPermissionsAreTightenedAtEveryStart() async throws {
        let folder = MCPTestSupport.tempFile("mcp")
        let tokenFile = folder.appendingPathComponent("token")
        let token = try MCPAccessToken.generate()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try Data(token.utf8).write(to: tokenFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tokenFile.path)
        let server = MCPServer(options: .init(preferredPort: 0, endpointFileURL: nil, tokenFileURL: tokenFile, requiresToken: true))
        defer { server.stop() }
        try await server.start(reason: .session)
        #expect(try Self.permissions(tokenFile) == 0o600)
        #expect(try Self.permissions(folder) == 0o700)
        #expect(try Self.storedToken(in: folder) == token, "A well-formed token is kept")
    }

    @Test func aMalformedTokenFileIsReplacedWithANewToken() async throws {
        let folder = MCPTestSupport.tempFile("mcp")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not a token\n".utf8).write(to: folder.appendingPathComponent("token"))
        let server = MCPServer(options: .init(preferredPort: 0, endpointFileURL: nil,
                                              tokenFileURL: folder.appendingPathComponent("token"), requiresToken: true))
        defer { server.stop() }
        try await server.start(reason: .session)
        #expect(MCPAccessToken.isWellFormed(try Self.storedToken(in: folder)))
    }

    // MARK: - Enforcement

    @Test func requestsWithoutTheRightBearerTokenAreRefusedWith401() async throws {
        let (server, folder) = try await startServer()
        defer { server.stop() }
        let token = try Self.storedToken(in: folder)
        let other = try MCPAccessToken.generate()
        let refused: [(String, String?)] = [
            ("no header", nil),
            ("wrong token", "Bearer \(other)"),
            ("wrong scheme", "Basic \(token)"),
            ("no scheme", token),
            ("scheme only", "Bearer"),
            ("token with more after it", "Bearer \(token)x"),
            ("token cut short", "Bearer \(token.dropLast())"),
        ]
        for (label, authorization) in refused {
            var headers = RawHTTP.jsonHeaders
            if let authorization { headers["Authorization"] = authorization }
            let response = try await RawHTTP.send(port: server.port, method: "POST", headers: headers, body: Self.listTools)
            #expect(response.status == 401, "\(label): \(response.status)")
            #expect(response.headers["WWW-Authenticate"] == #"Bearer realm="Compositor""#, "\(label): \(response.headers)")
            #expect(response.headers["Connection"] == "close", "\(label)")
            let body = try RawHTTP.object(response.body)
            #expect(body["jsonrpc"] as? String == "2.0" && body["id"] is NSNull, "\(label): \(body)")
            let error = try #require(body["error"] as? [String: Any], "\(label): \(body)")
            #expect(error["code"] is Int && (error["message"] as? String)?.contains("Authorization: Bearer") == true, "\(label): \(error)")
            #expect(response.accessControlHeaders.isEmpty)
        }
        // The scheme is case-insensitive (RFC 9110); the token is not.
        for authorization in ["Bearer \(token)", "bearer \(token)", "BEARER  \(token)"] {
            let response = try await RawHTTP.send(port: server.port, method: "POST",
                                                  headers: RawHTTP.jsonHeaders.merging(["Authorization": authorization]) { $1 },
                                                  body: Self.listTools)
            #expect(response.status == 200, "\(authorization.prefix(7)): \(response.status)")
            #expect((try RawHTTP.object(response.body)["result"] as? [String: Any])?["tools"] != nil)
        }
        #expect(try await RawHTTP.send(port: server.port, method: "POST",
                                       headers: Self.bearer(token.lowercased() == token ? token.uppercased() : token.lowercased()),
                                       body: Self.listTools).status == 401)
    }

    /// The token is checked from the request head alone: a caller without it gets its 401 before sending a body (or
    /// while the server would still be waiting for one), and a body is never read, let alone parsed.
    @Test func theTokenIsCheckedBeforeTheBodyIsRead() async throws {
        let (server, _) = try await startServer()
        defer { server.stop() }
        let port = server.port
        for expect in ["", "Expect: 100-continue\r\n"] {
            // Announces 1000 bytes and sends none: only the head decides.
            let head = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nAccept: application/json\r\nContent-Length: 1000\r\n\(expect)\r\n".utf8)
            let response = try await RawHTTP.exchange(port: port, bytes: head, timeout: .seconds(10))
            #expect(response.status == 401, "\(expect.debugDescription): \(response.status)")
        }
    }

    @Test func theOtherChecksStillApplyAfterTheToken() async throws {
        let (server, folder) = try await startServer()
        defer { server.stop() }
        let token = try Self.storedToken(in: folder)
        let port = server.port
        // GET: 401 without the token, 405 with it.
        #expect(try await RawHTTP.send(port: port, method: "GET", headers: ["Accept": "text/event-stream"], body: nil).status == 401)
        #expect(try await RawHTTP.send(port: port, method: "GET",
                                       headers: ["Accept": "text/event-stream", "Authorization": "Bearer \(token)"], body: nil).status == 405)
        // A browser's Origin and a rebound Host are refused even with the token.
        #expect(try await RawHTTP.send(port: port, method: "POST",
                                       headers: Self.bearer(token).merging(["Origin": "http://127.0.0.1:\(port)"]) { $1 },
                                       body: Self.listTools).status == 403)
        #expect(try await RawHTTP.send(port: port, method: "POST",
                                       headers: Self.bearer(token).merging(["Host": "evil.example:\(port)"]) { $1 },
                                       body: Self.listTools).status == 421)
    }

    @Test func withTheRequirementOffNoTokenIsNeeded() async throws {
        let (server, folder) = try await startServer(requiresToken: false)
        defer { server.stop() }
        #expect(try await RawHTTP.post(port: server.port, body: Self.listTools).status == 200)
        let record = try #require(MCPEndpointFile.read(at: folder.appendingPathComponent("endpoint.json")))
        #expect(record.auth == "none" && record.token_file == nil)
    }

    @Test func regeneratingTheTokenInvalidatesTheOldOne() async throws {
        let (server, folder) = try await startServer()
        defer { server.stop() }
        let old = try Self.storedToken(in: folder)
        let new = try server.regenerateToken()
        #expect(new != old && MCPAccessToken.isWellFormed(new))
        #expect(try Self.storedToken(in: folder) == new)
        #expect(try Self.permissions(folder.appendingPathComponent("token")) == 0o600)
        #expect(try server.currentToken() == new)
        #expect(try await RawHTTP.send(port: server.port, method: "POST", headers: Self.bearer(old), body: Self.listTools).status == 401)
        #expect(try await RawHTTP.send(port: server.port, method: "POST", headers: Self.bearer(new), body: Self.listTools).status == 200)
        // Only the token file changed: the folder holds the token and the endpoint file, no temporary leftovers.
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["endpoint.json", "token"], "\(names)")
    }

    @Test func theRequirementCanBeTurnedOffAndOnWhileRunning() async throws {
        let (server, folder) = try await startServer()
        defer { server.stop() }
        let endpointFile = folder.appendingPathComponent("endpoint.json")
        try server.setRequiresToken(false)
        #expect(!server.options.requiresToken)
        #expect(try await RawHTTP.post(port: server.port, body: Self.listTools).status == 200)
        #expect(MCPEndpointFile.read(at: endpointFile)?.auth == "none")

        try server.setRequiresToken(true)
        #expect(try await RawHTTP.post(port: server.port, body: Self.listTools).status == 401)
        let token = try Self.storedToken(in: folder)
        #expect(try await RawHTTP.send(port: server.port, method: "POST", headers: Self.bearer(token), body: Self.listTools).status == 200)
        #expect(MCPEndpointFile.read(at: endpointFile)?.auth == "bearer")
    }

    /// The endpoint file says a token is needed and where it is, and get_app_info says the same; neither ever holds
    /// the token itself.
    @Test func theEndpointFileAndGetAppInfoNameTheSchemeButNeverTheToken() async throws {
        let (server, folder) = try await startServer()
        defer { server.stop() }
        let token = try Self.storedToken(in: folder)
        let endpointFile = folder.appendingPathComponent("endpoint.json")
        let text = try String(contentsOf: endpointFile, encoding: .utf8)
        #expect(!text.contains(token), "The endpoint file holds the token")
        let json = try RawHTTP.object(Data(text.utf8))
        #expect(json["auth"] as? String == "bearer")
        #expect(json["token_file"] as? String == folder.appendingPathComponent("token").path)
        #expect(try Self.permissions(endpointFile) == 0o600)

        let record = try #require(MCPEndpointFile.read(at: endpointFile))
        let info = try #require(MCPToolRegistry.endpointInfo(record, pid: getpid()).objectValue)
        #expect(info["auth"]?.stringValue == "bearer")
        #expect(info["url"]?.stringValue == record.url)
        #expect(info["token_file"] == nil && !"\(info)".contains(token))
        // A file written before the token existed says nothing about it: no token needed.
        var older = record
        older.auth = nil
        older.token_file = nil
        #expect(MCPToolRegistry.endpointInfo(older, pid: getpid()).objectValue?["auth"]?.stringValue == "none")
        // Another process's endpoint isn't this server's.
        #expect(MCPToolRegistry.endpointInfo(record, pid: getpid() &+ 1) == .null)
        #expect(MCPToolRegistry.endpointInfo(nil, pid: getpid()) == .null)
    }

    /// Two SDK clients configured with the header (as Claude Code's `--header` does) share the server as before; one
    /// without it can't even initialize.
    @Test func twoSDKClientsSendingTheTokenBothWork() async throws {
        let (server, folder) = try await startServer()
        defer { server.stop() }
        let token = try Self.storedToken(in: folder)
        let url = try #require(server.endpointURL)
        func transport(token: String?) -> HTTPClientTransport {
            HTTPClientTransport(endpoint: url, streaming: false, requestModifier: { request in
                var request = request
                if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                return request
            })
        }
        let a = Client(name: "a", version: "1"), b = Client(name: "b", version: "1")
        let initA = try await a.connect(transport: transport(token: token))
        let initB = try await b.connect(transport: transport(token: token))
        #expect(initA.serverInfo.name == "Compositor" && initB.protocolVersion == initA.protocolVersion)
        #expect(try await a.listTools().tools.count == MCPToolRegistry.tools.count)
        let (content, isError) = try await b.callTool(name: "list_documents", arguments: [:])
        #expect(isError != true && !content.isEmpty)
        await a.disconnect()
        await b.disconnect()

        let stranger = Client(name: "c", version: "1")
        await #expect(throws: (any Error).self) { _ = try await stranger.connect(transport: transport(token: nil)) }
        await stranger.disconnect()
    }

    // MARK: - Checking a header

    @Test func onlyTheSameTokenAfterBearerIsAccepted() throws {
        let token = try MCPAccessToken.generate()
        #expect(MCPAccessToken.authorizes("Bearer \(token)", token: token))
        #expect(MCPAccessToken.authorizes("bearer \(token)", token: token))
        #expect(MCPAccessToken.authorizes("Bearer   \(token)  ", token: token))
        for header in [nil, "", "Bearer", "Bearer ", token, "Basic \(token)", "Bearer \(token) extra", "Bearer \(token)x",
                       "Bearer \(String(token.dropFirst()))", "Bearer\(token)", "Bearer \(try MCPAccessToken.generate())"] {
            #expect(!MCPAccessToken.authorizes(header, token: token), "\(header.map { String($0.prefix(8)) } ?? "nil")")
        }
        #expect(MCPAccessToken.constantTimeEquals(Array("abc".utf8), Array("abc".utf8)))
        #expect(!MCPAccessToken.constantTimeEquals(Array("abd".utf8), Array("abc".utf8)))
        #expect(!MCPAccessToken.constantTimeEquals(Array("ab".utf8), Array("abc".utf8)))
        #expect(!MCPAccessToken.constantTimeEquals(Array("abcd".utf8), Array("abc".utf8)))
        #expect(!MCPAccessToken.constantTimeEquals([], Array("abc".utf8)))
    }

    /// No token is required while the gate holds none; once it holds one, only that token passes.
    @Test func theGateFollowsTheTokenItHolds() throws {
        let gate = MCPAccessGate()
        #expect(gate.permits(nil))
        let token = try MCPAccessToken.generate()
        gate.requiredToken = token
        #expect(!gate.permits(nil) && gate.permits("Bearer \(token)"))
        gate.requiredToken = nil
        #expect(gate.permits(nil))
    }

    // MARK: - Settings

    @Test func theTokenIsRequiredByDefaultAndKeptBesideTheEndpointFile() throws {
        let suite = "MCPAccessTokenTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(MCPSettings.requireTokenKey == "mcp.requireToken")
        #expect(MCPSettings.requiresToken(in: defaults))
        MCPSettings.setRequiresToken(false, in: defaults)
        #expect(!MCPSettings.requiresToken(in: defaults))
        MCPSettings.setRequiresToken(true, in: defaults)
        #expect(MCPSettings.requiresToken(in: defaults))

        let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support", isDirectory: true)
        #expect(MCPSettings.tokenFileURL(under: support).path == "/Users/someone/Library/Application Support/Compositor/mcp/token")
        #expect(MCPSettings.tokenFileURL(under: support).deletingLastPathComponent()
                == MCPSettings.endpointFileURL(under: support).deletingLastPathComponent())
    }

    /// `Options` itself requires no token (tests opt in), so the app's options are what turn it on: with defaults that
    /// were never touched, the app's server refuses a request without the token and keeps the token beside its
    /// endpoint file. Here the defaults are a fresh suite and Application Support a temporary folder.
    @Test func theAppsServerRequiresTheTokenUnlessTheOwnerTurnsItOff() async throws {
        let suite = "MCPAccessTokenTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let support = MCPTestSupport.tempFile("Application Support")
        var options = MCPServer.Options.production(defaults: defaults, applicationSupport: support)
        #expect(options.requiresToken)
        #expect(options.preferredPort == MCPSettings.defaultPort)
        #expect(options.endpointFileURL == MCPSettings.endpointFileURL(under: support))
        #expect(options.tokenFileURL == MCPSettings.tokenFileURL(under: support))

        // Started as the app starts it, but on a free port (never 2667).
        options.preferredPort = 0
        let server = MCPServer(options: options)
        server.workspace = workspace
        defer { server.stop() }
        try await server.start(reason: .session)
        let refused = try await RawHTTP.send(port: server.port, method: "POST", headers: RawHTTP.jsonHeaders, body: Self.listTools)
        #expect(refused.status == 401)
        let tokenFile = MCPSettings.tokenFileURL(under: support)
        let token = try String(contentsOf: tokenFile, encoding: .utf8)
        #expect(MCPAccessToken.isWellFormed(token))
        #expect(try await RawHTTP.send(port: server.port, method: "POST", headers: Self.bearer(token), body: Self.listTools).status == 200)
        let record = try #require(MCPEndpointFile.read(at: MCPSettings.endpointFileURL(under: support)))
        #expect(record.auth == "bearer" && record.token_file == tokenFile.path)
        server.stop()

        MCPSettings.setRequiresToken(false, in: defaults)
        #expect(!MCPServer.Options.production(defaults: defaults, applicationSupport: support).requiresToken)

        // `production` and the app's `MCPServer()` are these options for the real defaults and Application Support
        // folder, which this only reads.
        for app in [MCPServer.Options.production, MCPServer().options] {
            #expect(app.requiresToken == MCPSettings.requiresToken)
            #expect(app.preferredPort == MCPSettings.port)
            #expect(app.endpointFileURL == MCPSettings.endpointFileURL)
            #expect(app.tokenFileURL == MCPSettings.tokenFileURL)
        }
    }
}
