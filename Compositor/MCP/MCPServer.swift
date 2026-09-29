import Foundation
import MCP
import Observation
import os
import Synchronization

/// Owns the embedded MCP server: one SDK `Server` on a `StatelessHTTPServerTransport`,
/// the loopback HTTP listener in front of it, and the queue that runs tool calls one
/// at a time so one document mutation is never interleaved with another.
///
/// Multi-client: any number of agents (Claude Code and Codex at once, or one that
/// restarts) talk to the same server. Stateless mode has no sessions; every POST is
/// answered on its own, `initialize` included — the SDK's default `initialize`
/// handler refuses a second client, so `start` replaces it (see `configureHandlers`).
/// JSON-RPC ids are made unique per HTTP request by `MCPRequestRouter`.
///
/// Security: the server is opt-in (`MCPSettings.isEnabled`, off by default) or
/// started for an explicit session, listens on the loopback interface only, refuses
/// any request carrying an `Origin` header (browsers) and any `Host` other than
/// loopback with the bound port (DNS rebinding), and sends no CORS headers. By default
/// every request must also carry the access token (`MCPAccessToken`), which only this
/// user can read: loopback alone lets in other accounts on this Mac and sandboxed apps,
/// which would act with Compositor's file access. The token is checked from the request
/// head, before the body is read (`MCPAccessGate`).
@MainActor
@Observable
final class MCPServer {
    enum StartReason { case settings, session }

    struct Options: Sendable {
        /// Port to bind; 0 picks a free ephemeral port. When a nonzero port is taken,
        /// the server falls back to an ephemeral one and sets `portFellBack`.
        var preferredPort: UInt16
        /// Where the running endpoint is published for agents (`MCPEndpointFile`):
        /// written once the server is running, removed when it stops. nil publishes nothing.
        var endpointFileURL: URL?
        /// Where the access token is kept (`MCPAccessToken.loadOrCreate`), named in the endpoint file for the bridge.
        /// nil keeps the token in memory, for this server only.
        var tokenFileURL: URL? = nil
        /// Whether every request must carry the access token. Off unless set: tests opt in, the app follows
        /// `MCPSettings.requiresToken` (on by default).
        var requiresToken = false
        /// Tool calls that may be queued or running at once.
        var maxQueuedCalls = MCPSettings.maxQueuedCalls
        /// Where this server's starts, stops, requests, refusals and tool calls are logged: the app's log unless a
        /// test gives its own.
        var log: CompositorLog = .shared

        /// The app's server: the stable port, the token setting and the real endpoint and token files.
        static var production: Options {
            production(defaults: .standard, applicationSupport: MCPSettings.applicationSupportBaseURL)
        }

        /// The app's server for these defaults and this `Application Support` folder: the port and token setting
        /// they hold (the token is required unless turned off), and the endpoint and token files under the folder.
        static func production(defaults: UserDefaults, applicationSupport: URL) -> Options {
            Options(preferredPort: MCPSettings.port(in: defaults),
                    endpointFileURL: MCPSettings.endpointFileURL(under: applicationSupport),
                    tokenFileURL: MCPSettings.tokenFileURL(under: applicationSupport),
                    requiresToken: MCPSettings.requiresToken(in: defaults))
        }
    }

    /// Why the app starts the server at launch, if at all: the Settings switch wins;
    /// otherwise `--mcp` among the launch arguments starts it for this session only.
    nonisolated static func launchStartReason(isEnabled: Bool, arguments: [String]) -> StartReason? {
        if isEnabled { return .settings }
        return arguments.contains(MCPSettings.launchArgument) ? .session : nil
    }

    /// Why a start request from outside (the distributed start notification, typically
    /// from the `compositor-mcp` bridge) starts the server: for this session only, unless
    /// the Settings switch is on — a server the switch wants must never be recorded as
    /// session-only.
    nonisolated static func notificationStartReason(isEnabled: Bool) -> StartReason {
        isEnabled ? .settings : .session
    }

    /// Logs the live endpoint so agents and support can discover the port.
    private static let log = Logger(subsystem: "com.wonderassembly.compositor", category: "mcp")

    /// The document workspace tools operate on.
    weak var workspace: ProjectWorkspace?

    private(set) var isRunning = false
    private(set) var port: UInt16 = 0
    private(set) var lastError: String?
    private(set) var startReason: StartReason?
    /// True when `preferredPort` was taken and an ephemeral port was bound instead.
    private(set) var portFellBack = false

    var endpointURL: URL? {
        guard isRunning, port != 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/mcp")
    }

    /// `preferredPort` changes through `changePreferredPort`; the rest is fixed at init.
    private(set) var options: Options
    /// Runs this server's calls one at a time. Each start makes a fresh one, so a call from an earlier start that
    /// never returns (a read stuck on a dead volume, say) can't hold up the calls of the next. Internal (not private)
    /// so tests can hold the queue busy.
    @ObservationIgnored private(set) var toolQueue: MCPToolQueue
    /// Listeners this server has bound and not yet stopped: 1 while running, else 0.
    @ObservationIgnored let liveListeners = MCPListenerCounter()
    @ObservationIgnored private var server: Server?
    @ObservationIgnored private var httpListener: MCPHTTPListener?
    /// The start in progress, shared by every caller that overlaps it.
    @ObservationIgnored private var startTask: Task<Void, any Error>?
    /// Bumped by every `stop`, so a start that was waiting on the listener notices,
    /// and a failure reported by a stopped listener is ignored.
    @ObservationIgnored private var generation = 0
    /// The reason of a start still in progress (`.settings` if any caller asked for it).
    @ObservationIgnored private var startingReason: StartReason?
    /// When the running server started, for the endpoint file.
    @ObservationIgnored private var startedAt: Date?
    /// The endpoint file this server wrote, so `stop` removes only its own.
    @ObservationIgnored private var publishedEndpoint: MCPEndpointRecord?
    /// The token requests must carry while one is required (nil otherwise); every listener checks it.
    @ObservationIgnored let accessGate = MCPAccessGate()
    /// The token when there's no token file to keep it in.
    @ObservationIgnored private var memoryToken: String?
    /// The client each connection's `initialize` named (filled by the router), for the tool calls' log events.
    @ObservationIgnored private let clients = MCPClientDirectory()

    /// Tests pass their own options (port 0, a temporary or no endpoint file).
    init(options: Options) {
        self.options = options
        self.toolQueue = MCPToolQueue(limit: options.maxQueuedCalls)
    }

    /// The app's server (`Options.production`). Not a default argument: those are
    /// evaluated outside the main actor, where `MCPSettings` can't be read.
    convenience init() {
        self.init(options: .production)
    }

    private static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }

    /// Starts listening and returns once the endpoint accepts connections.
    ///
    /// Callers that overlap an in-progress start (the Settings switch and a session
    /// start at launch, or a switch flipped on, off and on again) all await the same
    /// start and return only once the server is running. `startReason` becomes
    /// `.settings` if any caller asked for it; a `.session` start never downgrades it.
    /// Throws — and records `lastError` — when it cannot bind; throws
    /// `CancellationError` when `stop()` supersedes the start it was waiting for.
    func start(reason: StartReason) async throws {
        if !isRunning {
            startingReason = startingReason == .settings ? .settings : reason
            let task: Task<Void, any Error>
            if let startTask {
                task = startTask
            } else {
                let generation = self.generation
                task = Task { try await self.bringUp(reason: reason, generation: generation) }
                startTask = task
            }
            try await task.value
            // Stopped again after that start finished (and nothing restarted it).
            guard isRunning else { throw CancellationError() }
        }
        if reason == .settings || startReason == nil { startReason = reason }
    }

    private func bringUp(reason: StartReason, generation: Int) async throws {
        defer {
            if self.generation == generation {
                startTask = nil
                startingReason = nil
            }
        }
        let preferredPort = options.preferredPort
        // A `stop()` can land after `start` queued this task but before it ran: then
        // bind nothing at all.
        try checkNotStopped(since: generation)

        // Requests that arrive between the listener becoming ready and the transport
        // existing (the transport's Host check needs the bound port) get a 503.
        let slot = MCPRouterSlot()
        let listener = MCPHTTPListener(
            counter: liveListeners,
            gate: accessGate,
            log: options.log,
            handler: { request in
                guard let router = slot.router else {
                    return .error(statusCode: 503, .internalError("Compositor's MCP server is starting"))
                }
                return await router.handle(request)
            },
            onFailure: { [weak self] message in
                Task { @MainActor [weak self] in self?.listenerFailed(message, generation: generation) }
            }
        )
        // Still the current generation here (nothing has been awaited since the check),
        // so `stop()` will find and close this listener from now on.
        httpListener = listener

        do {
            // Before anything can connect: no request is ever served without the token it needs. A token that can't
            // be read or made fails the start rather than serving without one.
            accessGate.requiredToken = options.requiresToken ? try storedToken() : nil
            var fellBack = false
            let boundPort: UInt16
            do {
                boundPort = try await listener.start(port: preferredPort)
            } catch where preferredPort != 0 && MCPHTTPListener.isAddressInUse(error) && self.generation == generation {
                // The stable port is taken (another app, or a second Compositor): serve on
                // an ephemeral one rather than not at all, and say so in Settings.
                boundPort = try await listener.start(port: 0)
                fellBack = true
            }
            try checkNotStopped(since: generation)

            let transport = StatelessHTTPServerTransport(
                validationPipeline: MCPRequestRouter.validationPipeline(port: boundPort))
            let server = Server(
                name: "Compositor",
                version: Self.appVersion,
                instructions: MCPToolRegistry.instructions,
                capabilities: Server.Capabilities(tools: .init(listChanged: false))
            )
            try await server.start(transport: transport)
            await configureHandlers(on: server, generation: generation)
            guard self.generation == generation else {
                await server.stop()
                throw CancellationError()
            }
            slot.install(MCPRequestRouter(transport: transport, log: options.log, clients: clients))

            self.server = server
            toolQueue = MCPToolQueue(limit: options.maxQueuedCalls)
            port = boundPort
            portFellBack = fellBack
            startReason = reason
            lastError = nil
            isRunning = true
            startedAt = Date()
            writeEndpointFile()
            // Printed and logged for agents and support; harmless in the Finder-launched GUI case (stdout is /dev/null).
            print("Compositor MCP server: http://127.0.0.1:\(boundPort)/mcp")
            Self.log.info("mcp endpoint http://127.0.0.1:\(boundPort, privacy: .public)/mcp")
            MCPServerLog.started(self, reason: reason, log: options.log)
        } catch {
            // Always close this start's own listener: when a `stop()` superseded it,
            // `httpListener` may already belong to a newer start and `stop()` below is
            // skipped, so nothing else would ever unbind it.
            listener.stop()
            if self.generation == generation {
                if !(error is CancellationError) { MCPServerLog.startFailed(error, preferredPort: preferredPort, log: options.log) }
                lastError = error.localizedDescription
                stop(reason: .startFailed)
            }
            throw error
        }
    }

    /// Stops the server, or abandons a start in progress (its callers get
    /// `CancellationError`); the next `start` begins afresh. `reason` is for the log.
    func stop(reason: MCPServerStopReason = .requested) {
        if isRunning || startTask != nil { MCPServerLog.stopped(reason, port: port, log: options.log) }
        generation += 1
        startTask?.cancel()
        startTask = nil
        httpListener?.stop()
        httpListener = nil
        removeEndpointFile()
        startingReason = nil
        startedAt = nil
        let server = self.server
        self.server = nil
        port = 0
        portFellBack = false
        startReason = nil
        isRunning = false
        if let server {
            // Terminates the transport: requests still waiting are answered with an error.
            Task { await server.stop() }
        }
    }

    /// Moves the server to `port` (0: any free port). A running (or starting) server
    /// restarts on it at once, keeping its start reason — clients must then use the new
    /// endpoint. A stopped server just remembers it for the next start. Re-applying the
    /// same port retries it after a fallback.
    func changePreferredPort(_ port: UInt16) async throws {
        let unchanged = port == options.preferredPort && !portFellBack
        options.preferredPort = port
        guard !unchanged, let reason = isRunning ? startReason : startingReason else { return }
        stop(reason: .portChanged)
        try await start(reason: reason)
    }

    /// Turns the token requirement on or off; a running server applies it to the next request and republishes the
    /// endpoint file. When the token can't be read or made, a running server stops (it must not go on without the
    /// token it was asked to require) and the error is thrown and shown as `lastError`.
    func setRequiresToken(_ required: Bool) throws {
        options.requiresToken = required
        do {
            accessGate.requiredToken = required ? try storedToken() : nil
        } catch {
            MCPServerLog.tokenRequirementChanged(required, error: error, log: options.log)
            if isRunning || startTask != nil {
                stop(reason: .tokenUnavailable)
                lastError = error.localizedDescription
            }
            throw error
        }
        MCPServerLog.tokenRequirementChanged(required, error: nil, log: options.log)
        refreshEndpointFile()
    }

    /// Replaces the token with a new one, which the running server requires from the next request on: clients set
    /// up with the old one get 401 until they are given the new one (the bridge reads it from the token file).
    @discardableResult
    func regenerateToken() throws -> String {
        let token: String
        if let url = options.tokenFileURL {
            token = try MCPAccessToken.regenerate(at: url)
        } else {
            token = try MCPAccessToken.generate()
            memoryToken = token
        }
        if accessGate.requiredToken != nil { accessGate.requiredToken = token }
        MCPServerLog.tokenRegenerated(log: options.log)
        return token
    }

    /// The token clients must send: the one the server is checking, else the stored one (made now if there's none).
    func currentToken() throws -> String {
        try accessGate.requiredToken ?? storedToken()
    }

    /// The token in the token file, made there if needed (which also tightens the file's permissions), or kept in
    /// memory when there's no token file.
    private func storedToken() throws -> String {
        if let url = options.tokenFileURL { return try MCPAccessToken.loadOrCreate(at: url) }
        if let memoryToken { return memoryToken }
        let token = try MCPAccessToken.generate()
        memoryToken = token
        return token
    }

    /// Rewrites the endpoint file for the running server (a start request arrived while
    /// it was already running: the file may have been removed or overwritten since).
    func refreshEndpointFile() {
        guard isRunning else { return }
        writeEndpointFile()
    }

    private func writeEndpointFile() {
        guard let url = options.endpointFileURL, let endpoint = endpointURL else { return }
        // On a fallback port, another live instance most likely holds the stable port and
        // published it: clients configured for the stable port reach that one, so keep its
        // file rather than pointing the bridge somewhere else.
        if portFellBack, let current = MCPEndpointFile.read(at: url),
           current.pid != getpid(), MCPEndpointFile.isAlive(current) {
            Self.log.info("fallback port \(self.port, privacy: .public) not published: the endpoint file names live process \(current.pid, privacy: .public)")
            return
        }
        let bearer = accessGate.requiredToken != nil
        let record = MCPEndpointRecord(
            url: endpoint.absoluteString,
            port: port,
            pid: getpid(),
            app_version: Self.appVersion,
            protocol: Version.latest,
            transport: MCPEndpointRecord.statelessTransport,
            started_at: startedAt ?? Date(),
            auth: bearer ? MCPEndpointRecord.bearerAuth : MCPEndpointRecord.noAuth,
            token_file: bearer ? options.tokenFileURL?.path : nil
        )
        do {
            try MCPEndpointFile.write(record, to: url)
            publishedEndpoint = record
        } catch {
            // Not fatal: clients configured with the URL still connect.
            Self.log.error("could not write the mcp endpoint file: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes the endpoint file this server wrote, unless another process (a second
    /// Compositor that started later) has since replaced it with its own.
    private func removeEndpointFile() {
        guard let published = publishedEndpoint, let url = options.endpointFileURL else { return }
        publishedEndpoint = nil
        if let current = MCPEndpointFile.read(at: url),
           current.pid != published.pid || current.port != published.port {
            return
        }
        MCPEndpointFile.remove(at: url)
    }

    /// The listener died after it was running (it reports this on its own queue).
    /// Ignored when it belongs to a server that was already stopped or replaced.
    private func listenerFailed(_ message: String, generation: Int) {
        guard generation == self.generation else { return }
        stop(reason: .listenerFailed)
        lastError = message
    }

    private func checkNotStopped(since generation: Int) throws {
        guard self.generation == generation else { throw CancellationError() }
    }

    private func configureHandlers(on server: Server, generation: Int) async {
        // Replaces the SDK's default `initialize` handler, which answers only the first
        // client and refuses every later one with "Server is already initialized".
        // Stateless mode keeps no per-client state, so every client gets the same answer.
        let serverInfo = Server.Info(name: "Compositor", version: Self.appVersion)
        let instructions = MCPToolRegistry.instructions
        await server.withMethodHandler(Initialize.self) { params in
            Initialize.Result(
                protocolVersion: Version.supported.contains(params.protocolVersion) ? params.protocolVersion : Version.latest,
                capabilities: .init(tools: .init(listChanged: false)),
                serverInfo: serverInfo,
                instructions: instructions
            )
        }
        // The SDK invokes method handlers on its own executor, so hop to MainActor
        // for the tool registry (everything in the app defaults to MainActor).
        await server.withMethodHandler(ListTools.self) { _ in
            await MainActor.run { ListTools.Result(tools: MCPToolRegistry.tools) }
        }
        let (clients, log) = (self.clients, options.log)
        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self else {
                return await MainActor.run { MCPToolRegistry.failure("Compositor's MCP server is unavailable.") }
            }
            // Which connection and client the call came from, and its own id, for its log event.
            let origin = MCPCallOrigin(request: Server.currentHandlerContext?.httpContext, clients: clients)
            return await CompositorLog.$taskLog.withValue(log) {
                await MCPCallOrigin.$current.withValue(origin) { await self.invokeTool(params, generation: generation) }
            }
        }
    }

    /// Runs one tool call through the shared queue: in arrival order, one at a time,
    /// whichever client sent it. `generation` is that of the server the call arrived
    /// on (the current one when nil); internal (not private) so tests can call it.
    func invokeTool(_ params: CallTool.Parameters, generation: Int? = nil) async -> CallTool.Result {
        let generation = generation ?? self.generation
        do {
            return try await toolQueue.run { [weak self] in
                // A call still queued when its server stopped must not touch the document,
                // even if a new server started in the meantime.
                guard let self, self.isRunning, self.generation == generation else {
                    return MCPToolRegistry.failure("Compositor's MCP server stopped before this call ran.")
                }
                guard let workspace = self.workspace else {
                    return MCPToolRegistry.failure("Compositor's document workspace is unavailable.")
                }
                return await MCPToolRegistry.call(params.name, params.arguments ?? [:], workspace: workspace)
            }
        } catch {
            let refusal = MCPToolError.from(error)
            MCPServerLog.callRefused(params.name, refusal, log: CompositorLog.active)
            return MCPToolRegistry.failure(refusal)
        }
    }
}

/// The router the listener forwards to, installed once the transport exists.
/// Read from the listener's connections off the main actor, hence the lock.
private nonisolated final class MCPRouterSlot: Sendable {
    private let state = Mutex<MCPRequestRouter?>(nil)

    var router: MCPRequestRouter? { state.withLock { $0 } }

    func install(_ router: MCPRequestRouter) {
        state.withLock { $0 = router }
    }
}
