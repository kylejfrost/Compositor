import Foundation

/// Where the bridge sends lines: the URL, and the file holding the access token it
/// sends with each (nil when the server takes no token).
struct Endpoint: Sendable, Equatable {
    let url: URL
    let tokenFile: URL?
}

/// Finds a Compositor MCP endpoint that answers right now.
///
/// The endpoint file is only a hint: a crashed app leaves it behind and its pid can be
/// reused, so a record counts only when its process is alive *and* its URL answers a
/// JSON-RPC `ping`. Nor is it followed blindly: it must belong to this user with no one
/// else able to change it, and its URL must be plain HTTP to this Mac's loopback
/// address, so a rewritten file can't send the bridge's traffic anywhere else. When it
/// says the server requires its access token (`"auth": "bearer"`), the ping carries the
/// token from the file it names (`token_file`), which must be this user's alone.
struct EndpointDiscovery: Sendable {
    enum Source: Sendable {
        /// `--endpoint`: this URL, nothing else.
        case url(URL)
        /// The file the app publishes (or `--endpoint-file`).
        case file(URL)
    }

    enum Lookup: Sendable {
        case found(Endpoint)
        /// Nothing usable; the reason is shown to the client's user.
        case absent(String)
        /// A server is there, but the bridge can't use its access token (unreadable, open to other users, or
        /// refused). Starting Compositor wouldn't help: the reason is shown to the client's user at once.
        case unusable(String)
    }

    /// What the app writes; other keys in the file are ignored.
    struct Record: Decodable {
        let url: String
        let pid: Int32
        /// `"bearer"` when requests need the token in `token_file`; absent (older apps) or `"none"` otherwise.
        let auth: String?
        let token_file: String?
    }

    /// `~/Library/Application Support/Compositor/mcp/endpoint.json`, where the app
    /// publishes its endpoint (`MCPSettings.endpointFileURL` in the app).
    static var defaultEndpointFile: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Compositor/mcp/endpoint.json")
    }

    /// How long a probe waits: the server answers a ping at once when it's there.
    static let probeTimeout: TimeInterval = 2

    let source: Source
    /// `--token-file`: the token to send whatever the endpoint file says.
    var tokenFile: URL? = nil
    let http: HTTPPoster

    func lookup() async -> Lookup {
        switch source {
        case .url(let url):
            return await probe(Endpoint(url: url, tokenFile: tokenFile))
        case .file(let file):
            var info = stat()
            guard stat(file.path, &info) == 0 else {
                return .absent("no Compositor MCP server is running (no endpoint file at \(file.path))")
            }
            if let distrust = Self.distrust(owner: info.st_uid, mode: info.st_mode) {
                return .absent("the endpoint file at \(file.path) \(distrust), so it isn't used")
            }
            guard let data = try? Data(contentsOf: file) else {
                return .absent("no Compositor MCP server is running (no endpoint file at \(file.path))")
            }
            guard let record = try? JSONDecoder().decode(Record.self, from: data),
                  let url = URL(string: record.url) else {
                return .absent("the endpoint file at \(file.path) is unreadable")
            }
            guard Self.isLoopbackHTTP(url) else {
                return .absent("the endpoint file at \(file.path) names \(record.url), which isn't this Mac's loopback address, so it isn't used")
            }
            // pid 0 (or negative) would address a whole process group.
            guard record.pid > 0, kill(record.pid, 0) == 0 else {
                return .absent("Compositor (pid \(record.pid)) is no longer running")
            }
            let named = Self.tokenFile(of: record)
            if tokenFile == nil, named == nil, record.auth == Self.bearerAuth {
                return .unusable("the endpoint file at \(file.path) asks for an access token but doesn't say where it is")
            }
            return await probe(Endpoint(url: url, tokenFile: tokenFile ?? named))
        }
    }

    static let bearerAuth = "bearer"

    /// The token file a record names when its server requires the token (an absolute path), else nil.
    static func tokenFile(of record: Record) -> URL? {
        guard record.auth == bearerAuth, let path = record.token_file, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Why an endpoint file with this owner and mode can't be trusted, or nil when it can: it must be the current
    /// user's, and no one else may write it (the app writes it owner-only).
    static func distrust(owner: uid_t, mode: mode_t) -> String? {
        if owner != getuid() { return "belongs to another user" }
        if mode & (S_IWGRP | S_IWOTH) != 0 { return "is one other users can change" }
        return nil
    }

    /// Hosts the app writes into the endpoint file (it binds 127.0.0.1), and the other names of that address.
    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    /// Whether `url` is plain HTTP to one of `loopbackHosts`.
    static func isLoopbackHTTP(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "http" && url.host.map { loopbackHosts.contains($0.lowercased()) } == true
    }

    /// `endpoint` when its URL answers a JSON-RPC `ping` with a JSON-RPC result — an MCP
    /// server, not merely some process that now owns a reused pid or port. The ping carries
    /// the endpoint's token; a token that can't be read is never sent, and one the server
    /// refuses makes the endpoint unusable.
    func probe(_ endpoint: Endpoint) async -> Lookup {
        let token: String?
        do {
            token = try endpoint.tokenFile.map(AccessToken.read)
        } catch {
            return .unusable((error as? AccessToken.Problem)?.message ?? error.localizedDescription)
        }
        let ping = Data(#"{"jsonrpc":"2.0","id":"compositor-mcp-probe","method":"ping"}"#.utf8)
        let silent = Lookup.absent("nothing answers at \(endpoint.url.absoluteString)")
        guard let response = try? await http.post(ping, to: endpoint.url, token: token, protocolVersion: nil,
                                                  timeout: Self.probeTimeout) else { return silent }
        if response.status == 401 {
            return .unusable("Compositor at \(endpoint.url.absoluteString) refused the request (HTTP 401): \(AccessToken.refusedHint)")
        }
        guard response.status == 200, Bridge.messages(in: response).contains(where: { message in
            ((try? JSONSerialization.jsonObject(with: message)) as? [String: Any])?["result"] != nil
        }) else { return silent }
        return .found(endpoint)
    }
}

/// The endpoint lines are sent to, found once and shared by every line in flight, so
/// a burst of requests triggers at most one launch.
actor EndpointResolver {
    private let discovery: EndpointDiscovery
    private let launcher: AppLauncher?
    private let timeout: TimeInterval
    private var current: Endpoint?
    private var pending: Task<Endpoint, any Error>?

    /// How often the endpoint is looked up again while Compositor starts.
    static let pollInterval: Duration = .milliseconds(250)
    /// How often the start request is repeated to a Compositor that's already running
    /// (one that was still launching may have missed the first).
    static let renotifyInterval: TimeInterval = 2

    init(discovery: EndpointDiscovery, launcher: AppLauncher?, timeout: TimeInterval) {
        self.discovery = discovery
        self.launcher = launcher
        self.timeout = timeout
    }

    /// A live endpoint; throws `UnreachableError` when there's none and none appears, and
    /// `AccessToken.Problem` when there is one whose token can't be used.
    func endpoint() async throws -> Endpoint {
        if let current { return current }
        if let pending { return try await pending.value }
        let task = Task { try await self.discover() }
        pending = task
        defer { pending = nil }
        let endpoint = try await task.value
        current = endpoint
        return endpoint
    }

    /// Forgets `endpoint` after it stopped answering or refused the token; the next line looks again.
    func invalidate(_ endpoint: Endpoint) {
        if current == endpoint { current = nil }
    }

    private func discover() async throws -> Endpoint {
        let reason: String
        let started = ContinuousClock.now
        switch await discovery.lookup() {
        case .found(let endpoint):
            Log.info("using \(endpoint.url.absoluteString)")
            BridgeLog.shared.info("endpoint_found", ["url": endpoint.url.absoluteString, "launched": false,
                                                     "waited_ms": BridgeLog.milliseconds(since: started)])
            return endpoint
        case .absent(let why):
            reason = why
        case .unusable(let why):
            BridgeLog.shared.warning("endpoint_unusable", ["reason": why])
            throw AccessToken.Problem(message: why)
        }
        BridgeLog.shared.notice("endpoint_absent", ["reason": reason, "launches": launcher != nil])
        guard let launcher else {
            throw UnreachableError(reason: "\(reason) (--no-launch)")
        }
        Log.info("\(reason); asking Compositor to start its MCP server")
        try await launcher.requestServer()

        let start = Date()
        var lastRequest = start
        while Date().timeIntervalSince(start) < timeout {
            try await Task.sleep(for: Self.pollInterval)
            switch await discovery.lookup() {
            case .found(let endpoint):
                Log.info("using \(endpoint.url.absoluteString)")
                BridgeLog.shared.info("endpoint_found", ["url": endpoint.url.absoluteString, "launched": true,
                                                         "waited_ms": BridgeLog.milliseconds(since: started)])
                return endpoint
            case .unusable(let why):
                BridgeLog.shared.warning("endpoint_unusable", ["reason": why])
                throw AccessToken.Problem(message: why)
            case .absent:
                break
            }
            if Date().timeIntervalSince(lastRequest) >= Self.renotifyInterval {
                launcher.renotifyIfRunning()
                lastRequest = Date()
            }
        }
        let seconds = timeout.rounded() == timeout ? String(Int(timeout)) : String(timeout)
        BridgeLog.shared.warning("launch_timed_out", ["waited_ms": BridgeLog.milliseconds(since: started)])
        throw UnreachableError(reason: "Compositor did not start its MCP server within \(seconds) s")
    }
}
