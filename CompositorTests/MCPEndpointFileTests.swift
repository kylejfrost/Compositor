import Foundation
import MCP
import Network
import Testing
@testable import Compositor

/// The endpoint file agents use to discover the running server, the stable port with its
/// ephemeral fallback, and how launch arguments pick a start reason.
///
/// Nothing here binds the real default port or touches the real endpoint file: every
/// server gets a fresh temporary endpoint path, and busy/free ports are found on the fly.
@MainActor struct MCPEndpointFileTests {
    private func tempEndpointFile() -> URL {
        MCPTestSupport.tempFile("mcp/endpoint.json")
    }

    private func record(port: UInt16 = 51_234, pid: Int32 = getpid()) -> MCPEndpointRecord {
        MCPEndpointRecord(url: "http://127.0.0.1:\(port)/mcp", port: port, pid: pid, app_version: "9.9",
                          protocol: "2025-06-18", transport: "streamable-http-stateless",
                          started_at: Date(timeIntervalSince1970: 1_800_000_000))
    }

    // MARK: - The file itself

    @Test func writeReadAndRemoveRoundTrip() throws {
        let url = tempEndpointFile()
        try MCPEndpointFile.write(record(), to: url)
        let read = try #require(MCPEndpointFile.read(at: url))
        #expect(read.url == "http://127.0.0.1:51234/mcp" && read.port == 51_234 && read.pid == getpid())
        #expect(read.app_version == "9.9" && read.protocol == "2025-06-18")
        #expect(read.transport == "streamable-http-stateless")
        #expect(read.started_at == Date(timeIntervalSince1970: 1_800_000_000))

        // Plain JSON with the documented snake_case keys, readable by any client.
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(Set(json.keys) == ["url", "port", "pid", "app_version", "protocol", "transport", "started_at"])
        #expect(json["started_at"] is String, "started_at must be an ISO 8601 string: \(json)")

        MCPEndpointFile.remove(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(MCPEndpointFile.read(at: url) == nil)
        MCPEndpointFile.remove(at: url) // Removing a missing file is harmless.
    }

    /// Only its owner can read or change the file: the bridge refuses one that other accounts could rewrite to point it
    /// at a server of theirs, and a umask that makes files group-writable must not lock it out of the app's own.
    @Test func theFileIsReadableAndWritableByItsOwnerOnly() throws {
        let url = tempEndpointFile()
        try MCPEndpointFile.write(record(), to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // Rewriting keeps it so.
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: url.path)
        try MCPEndpointFile.write(record(port: 51_235), to: url)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func aRecordIsAliveOnlyWhileItsProcessIs() {
        #expect(MCPEndpointFile.isAlive(record(pid: getpid())))
        #expect(!MCPEndpointFile.isAlive(record(pid: Int32.max)))
        // kill(0, 0) would signal our own process group and "succeed": never alive.
        #expect(!MCPEndpointFile.isAlive(record(pid: 0)))
    }

    // MARK: - The server publishes it

    @Test func theEndpointFileAppearsOnStartAndDisappearsOnStop() async throws {
        _ = MCPTestSupport.workspace()
        let url = tempEndpointFile()
        let server = MCPServer(options: .init(preferredPort: 0, endpointFileURL: url))
        defer { server.stop() }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try await server.start(reason: .session)

        let published = try #require(MCPEndpointFile.read(at: url))
        #expect(published.port == server.port && published.port != 0)
        #expect(published.pid == getpid())
        #expect(published.url.hasSuffix("/mcp") && published.url == server.endpointURL?.absoluteString)
        #expect(published.transport == "streamable-http-stateless")
        #expect(MCPEndpointFile.isAlive(published))

        server.stop()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aStartNotificationWhileRunningRewritesTheEndpointFile() async throws {
        _ = MCPTestSupport.workspace()
        let url = tempEndpointFile()
        let server = MCPServer(options: .init(preferredPort: 0, endpointFileURL: url))
        defer { server.stop() }
        try await server.start(reason: .settings)
        MCPEndpointFile.remove(at: url)
        server.refreshEndpointFile()
        #expect(MCPEndpointFile.read(at: url)?.port == server.port)
    }

    @Test func stopLeavesAnotherInstancesEndpointFileAlone() async throws {
        _ = MCPTestSupport.workspace()
        let url = tempEndpointFile()
        let server = MCPServer(options: .init(preferredPort: 0, endpointFileURL: url))
        defer { server.stop() }
        try await server.start(reason: .session)
        // A second Compositor started later and published its own endpoint here.
        try MCPEndpointFile.write(record(port: 1, pid: getpid() &+ 1), to: url)
        server.stop()
        #expect(MCPEndpointFile.read(at: url)?.port == 1, "stop() removed an endpoint file it did not write")
    }

    // MARK: - Stale files at launch

    @Test func launchCleanupRemovesAFileLeftByADeadProcess() throws {
        let url = tempEndpointFile()
        try MCPEndpointFile.write(record(pid: Int32.max), to: url)
        #expect(MCPEndpointFile.removeStale(at: url, currentPID: getpid(), isCompositor: { _ in true }))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func launchCleanupRemovesAFileNamingThisProcess() throws {
        // At launch this process has published nothing yet: a file naming its pid was
        // left by an earlier process that crashed and whose pid was reused.
        let url = tempEndpointFile()
        try MCPEndpointFile.write(record(pid: getpid()), to: url)
        #expect(MCPEndpointFile.removeStale(at: url, currentPID: getpid(), isCompositor: { _ in true }))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func launchCleanupRemovesAFileWhosePIDNowBelongsToAnotherProgram() throws {
        let other = try Self.liveOtherProcess()
        defer { other.terminate() }
        let url = tempEndpointFile()
        try MCPEndpointFile.write(record(pid: other.processIdentifier), to: url)
        #expect(MCPEndpointFile.removeStale(at: url, currentPID: getpid(), isCompositor: { _ in false }))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // The real check: `/bin/sleep` is no Compositor; this test host is one.
        try MCPEndpointFile.write(record(pid: other.processIdentifier), to: url)
        #expect(!MCPEndpointFile.isCompositorProcess(other.processIdentifier))
        #expect(MCPEndpointFile.isCompositorProcess(getpid()))
        #expect(MCPEndpointFile.removeStale(at: url, currentPID: getpid()))
    }

    @Test func launchCleanupKeepsTheFileOfAnotherRunningCompositor() throws {
        let other = try Self.liveOtherProcess()
        defer { other.terminate() }
        let pid = other.processIdentifier
        let url = tempEndpointFile()
        try MCPEndpointFile.write(record(pid: pid), to: url)
        #expect(!MCPEndpointFile.removeStale(at: url, currentPID: getpid(), isCompositor: { $0 == pid }))
        #expect(MCPEndpointFile.read(at: url)?.pid == pid)
    }

    @Test func launchCleanupRemovesAnUnreadableFileAndIgnoresAMissingOne() throws {
        let url = tempEndpointFile()
        #expect(!MCPEndpointFile.removeStale(at: url, currentPID: getpid()))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(MCPEndpointFile.removeStale(at: url, currentPID: getpid()))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aStartNotificationKeepsTheSettingsReasonWhenTheSwitchIsOn() {
        #expect(MCPServer.notificationStartReason(isEnabled: true) == .settings)
        #expect(MCPServer.notificationStartReason(isEnabled: false) == .session)
    }

    // MARK: - Stable port with fallback

    @Test func aFallbackServerLeavesALiveInstancesEndpointFileAlone() async throws {
        _ = MCPTestSupport.workspace()
        let first = MCPHTTPListener(handler: { _ in .accepted() }, onFailure: { _ in })
        let busy = try await first.start(port: 0)
        defer { first.stop() }
        // The instance holding the stable port published it; its pid is live (a child
        // process stands in for it).
        let other = try Self.liveOtherProcess()
        defer { other.terminate() }
        let url = tempEndpointFile()
        try MCPEndpointFile.write(record(port: busy, pid: other.processIdentifier), to: url)

        let server = MCPServer(options: .init(preferredPort: busy, endpointFileURL: url))
        defer { server.stop() }
        try await server.start(reason: .session)
        #expect(server.isRunning && server.portFellBack)
        #expect(MCPEndpointFile.read(at: url)?.port == busy, "A fallback server replaced a live instance's endpoint")
        server.refreshEndpointFile()
        #expect(MCPEndpointFile.read(at: url)?.pid == other.processIdentifier)
        server.stop()
        #expect(MCPEndpointFile.read(at: url)?.port == busy, "stop() removed a file this server never wrote")
    }

    @Test func aFallbackServerReplacesAFileNamingADeadProcess() async throws {
        _ = MCPTestSupport.workspace()
        let first = MCPHTTPListener(handler: { _ in .accepted() }, onFailure: { _ in })
        let busy = try await first.start(port: 0)
        defer { first.stop() }
        let url = tempEndpointFile()
        try MCPEndpointFile.write(record(port: busy, pid: Int32.max), to: url)

        let server = MCPServer(options: .init(preferredPort: busy, endpointFileURL: url))
        defer { server.stop() }
        try await server.start(reason: .session)
        #expect(server.portFellBack)
        #expect(MCPEndpointFile.read(at: url)?.port == server.port && MCPEndpointFile.read(at: url)?.pid == getpid())
    }

    @Test func aFreePreferredPortIsUsedAsIs() async throws {
        _ = MCPTestSupport.workspace()
        let port = try await Self.freeLoopbackPort()
        let server = MCPServer(options: .init(preferredPort: port, endpointFileURL: tempEndpointFile()))
        defer { server.stop() }
        try await server.start(reason: .session)
        #expect(server.port == port && !server.portFellBack)
    }

    @Test func aBusyPreferredPortFallsBackToAnEphemeralOne() async throws {
        _ = MCPTestSupport.workspace()
        // Something else — here a plain NWListener — already listens on the preferred port.
        let blocker = try await Self.bindLoopbackListener()
        defer { blocker.cancel() }
        let busy = try #require(blocker.port?.rawValue)

        let url = tempEndpointFile()
        let server = MCPServer(options: .init(preferredPort: busy, endpointFileURL: url))
        defer { server.stop() }
        try await server.start(reason: .settings)
        #expect(server.isRunning && server.portFellBack)
        #expect(server.port != 0 && server.port != busy)
        #expect(MCPEndpointFile.read(at: url)?.port == server.port, "The endpoint file must name the port actually bound")
        let answer = try await RawHTTP.post(port: server.port, body: #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#)
        #expect(answer.status == 200)
        server.stop()
        #expect(!server.portFellBack)
    }

    @Test func aPortHeldByAnotherCompositorFallsBackToo() async throws {
        _ = MCPTestSupport.workspace()
        // A second app instance binds with exactly the same listener parameters: address
        // reuse must not let both listen on one port.
        let first = MCPHTTPListener(handler: { _ in .accepted() }, onFailure: { _ in })
        let busy = try await first.start(port: 0)
        defer { first.stop() }

        let server = MCPServer(options: .init(preferredPort: busy, endpointFileURL: tempEndpointFile()))
        defer { server.stop() }
        try await server.start(reason: .session)
        #expect(server.isRunning && server.portFellBack && server.port != busy)
    }

    /// Another kind of server — a dev server from another toolchain — listening through a
    /// plain BSD socket, on loopback or on every interface.
    @Test(arguments: [INADDR_LOOPBACK, INADDR_ANY])
    func aPortHeldByABSDSocketFallsBack(address: in_addr_t) async throws {
        _ = MCPTestSupport.workspace()
        let blocker = try Self.bindBSDListener(address: address)
        defer { close(blocker.socket) }

        let server = MCPServer(options: .init(preferredPort: blocker.port, endpointFileURL: tempEndpointFile()))
        defer { server.stop() }
        try await server.start(reason: .session)
        #expect(server.isRunning && server.portFellBack && server.port != blocker.port)
    }

    @Test func changingThePreferredPortRestartsOnItAndKeepsTheReason() async throws {
        _ = MCPTestSupport.workspace()
        let url = tempEndpointFile()
        let server = MCPServer(options: .init(preferredPort: 0, endpointFileURL: url))
        defer { server.stop() }
        try await server.start(reason: .session)
        let port = try await Self.freeLoopbackPort()
        try await server.changePreferredPort(port)
        #expect(server.isRunning && server.port == port && !server.portFellBack)
        #expect(server.startReason == .session)
        #expect(server.options.preferredPort == port)
        #expect(MCPEndpointFile.read(at: url)?.port == port)

        // While stopped, the new port is only remembered for the next start.
        server.stop()
        try await server.changePreferredPort(0)
        #expect(!server.isRunning && server.options.preferredPort == 0)
    }

    // MARK: - Settings and launch

    @Test func thePortSettingFallsBackToTheDefaultUnlessValid() throws {
        let suite = "MCPEndpointFileTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(MCPSettings.defaultPort == 2667)
        #expect(MCPSettings.port(in: defaults) == 2667)
        for invalid in [0, 80, 1023, 65_536, -1] {
            defaults.set(invalid, forKey: MCPSettings.portKey)
            #expect(MCPSettings.port(in: defaults) == 2667, "\(invalid) must be ignored")
        }
        for valid in [1024, 8123, 65_535] {
            defaults.set(valid, forKey: MCPSettings.portKey)
            #expect(MCPSettings.port(in: defaults) == UInt16(valid))
        }
        MCPSettings.setPort(2667, in: defaults)
        #expect(defaults.object(forKey: MCPSettings.portKey) == nil, "Choosing the default clears the override")
        MCPSettings.setPort(9000, in: defaults)
        #expect(MCPSettings.port(in: defaults) == 9000)
        #expect(MCPSettings.isValidPort(1024) && MCPSettings.isValidPort(65_535))
        #expect(!MCPSettings.isValidPort(1023) && !MCPSettings.isValidPort(65_536))
    }

    @Test func settingsConstantsAreTheDocumentedOnes() {
        #expect(MCPSettings.portKey == "mcp.port")
        #expect(MCPSettings.launchArgument == "--mcp")
        #expect(MCPSettings.startNotification.rawValue == "com.wonderassembly.compositor.mcp.start")
        #expect(MCPSettings.maxTabs == 32 && MCPSettings.maxQueuedCalls == 64)
        let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support", isDirectory: true)
        #expect(MCPSettings.endpointFileURL(under: support).path
                == "/Users/someone/Library/Application Support/Compositor/mcp/endpoint.json")
        #expect(MCPSettings.agentRootURL(under: support).path
                == "/Users/someone/Library/Application Support/Compositor/Agent")
    }

    @Test func launchStartsForTheSettingsSwitchOrForASessionWithTheMCPArgument() {
        #expect(MCPServer.launchStartReason(isEnabled: true, arguments: ["/x/Compositor"]) == .settings)
        #expect(MCPServer.launchStartReason(isEnabled: true, arguments: ["/x/Compositor", "--mcp"]) == .settings)
        #expect(MCPServer.launchStartReason(isEnabled: false, arguments: ["/x/Compositor", "--mcp"]) == .session)
        #expect(MCPServer.launchStartReason(isEnabled: false, arguments: ["/x/Compositor"]) == nil)
        #expect(MCPServer.launchStartReason(isEnabled: false, arguments: ["/x/Compositor", "--mcpx"]) == nil)
    }

    // MARK: - Helpers

    /// A running process other than this one (`/bin/sleep`), for a live pid that isn't ours.
    /// Callers terminate it; the long sleep only has to outlast a starved main actor
    /// during a full parallel run.
    private static func liveOtherProcess() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["3600"]
        try process.run()
        return process
    }

    /// A plain loopback listener on an ephemeral port, ready to accept connections.
    private static func bindLoopbackListener() async throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        let ready = ReadyOnce()
        listener.newConnectionHandler = { $0.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: ready.fire { continuation.resume() }
                case .failed(let error), .waiting(let error): ready.fire { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "MCPEndpointFileTests.blocker"))
        }
        return listener
    }

    /// A listening IPv4 BSD socket on an ephemeral port of `address` (host byte order).
    private static func bindBSDListener(address: in_addr_t) throws -> (socket: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: address.bigEndian)
        addr.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, length) == 0 && listen(fd, 8) == 0
                    && getsockname(fd, sockaddrPointer, &length) == 0
            }
        }
        guard bound else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(fd)
            throw POSIXError(code)
        }
        return (fd, UInt16(bigEndian: addr.sin_port))
    }

    /// A loopback port that was free a moment ago (bound, then released).
    private static func freeLoopbackPort() async throws -> UInt16 {
        let listener = try await bindLoopbackListener()
        let port = try #require(listener.port?.rawValue)
        listener.cancel()
        try await Task.sleep(for: .milliseconds(50))
        return port
    }
}

/// Resumes a continuation at most once across listener state changes.
private nonisolated final class ReadyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire(_ body: () -> Void) {
        lock.lock()
        let first = !fired
        fired = true
        lock.unlock()
        if first { body() }
    }
}
