import Foundation

/// UserDefaults-backed settings for the local MCP (Model Context Protocol) server.
///
/// Everything is off by default: the app never listens for a connection until the
/// switch in Settings is turned on, and the server binds 127.0.0.1 only. Once it runs,
/// it requires its access token unless that is turned off too.
enum MCPSettings {
    static let enabledKey = "mcp.enabled"
    static let agentFolderName = "Agent"
    /// Tool calls that may be queued or running at once, across every connected client;
    /// the next call fails fast with a "busy" tool error.
    nonisolated static let maxQueuedCalls = 64
    /// Documents (tabs) agents may have open at once.
    nonisolated static let maxTabs = 32

    /// The port the server tries first, so client configs stay valid across launches.
    /// Registered for this app in the machine's port registry (portclaim service
    /// `compositor-mcp`). When it's taken, the server falls back to an ephemeral port.
    nonisolated static let defaultPort: UInt16 = 2667
    /// UserDefaults key for a user-chosen port overriding `defaultPort`.
    static let portKey = "mcp.port"
    /// Launching with this argument starts the server for that session only, without
    /// turning the Settings switch on.
    nonisolated static let launchArgument = "--mcp"
    /// Posted to `DistributedNotificationCenter` (by the `compositor-mcp` bridge, or
    /// anything else on this Mac) to start the server for this session.
    nonisolated static let startNotification = Notification.Name("com.wonderassembly.compositor.mcp.start")

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// UserDefaults key for whether every request must carry the access token (`MCPAccessToken`).
    static let requireTokenKey = "mcp.requireToken"

    /// Whether the server requires the access token: on unless turned off in Settings.
    static func requiresToken(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: requireTokenKey) as? Bool ?? true
    }

    static func setRequiresToken(_ required: Bool, in defaults: UserDefaults) {
        defaults.set(required, forKey: requireTokenKey)
    }

    static var requiresToken: Bool {
        get { requiresToken(in: .standard) }
        set { setRequiresToken(newValue, in: .standard) }
    }

    /// Ports a user may choose: unprivileged, and a real TCP port.
    static func isValidPort(_ value: Int) -> Bool {
        (1024...65_535).contains(value)
    }

    /// The preferred port: the override in `defaults` when valid, else `defaultPort`.
    static func port(in defaults: UserDefaults) -> UInt16 {
        let stored = defaults.integer(forKey: portKey)
        return isValidPort(stored) ? UInt16(stored) : defaultPort
    }

    /// Stores `port` as the override; choosing `defaultPort` clears it, so a future
    /// change of default reaches users who never picked their own. Invalid values are ignored.
    static func setPort(_ port: Int, in defaults: UserDefaults) {
        guard isValidPort(port) else { return }
        if port == Int(defaultPort) {
            defaults.removeObject(forKey: portKey)
        } else {
            defaults.set(port, forKey: portKey)
        }
    }

    static var port: UInt16 {
        get { port(in: .standard) }
        set { setPort(Int(newValue), in: .standard) }
    }

    /// Where the running server publishes its endpoint under a given `Application Support`
    /// folder. A pure path computation: nothing is created on disk by calling this.
    static func endpointFileURL(under applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("Compositor", isDirectory: true)
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("endpoint.json")
    }

    /// `~/Library/Application Support/Compositor/mcp/endpoint.json`.
    static var endpointFileURL: URL { endpointFileURL(under: applicationSupportBaseURL) }

    /// Where the access token is kept under a given `Application Support` folder, beside the endpoint file. A pure
    /// path computation: nothing is created on disk by calling this.
    static func tokenFileURL(under applicationSupport: URL) -> URL {
        endpointFileURL(under: applicationSupport).deletingLastPathComponent().appendingPathComponent("token")
    }

    /// `~/Library/Application Support/Compositor/mcp/token`.
    static var tokenFileURL: URL { tokenFileURL(under: applicationSupportBaseURL) }

    /// The real `Application Support` folder for this user, with no side effects: unlike
    /// `agentRoot`, merely reading this never creates anything on disk.
    static var applicationSupportBaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }

    /// Where the Agent folder lives under a given `Application Support` folder. A pure path
    /// computation with no side effects — nothing is created on disk by calling this.
    static func agentRootURL(under applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("Compositor", isDirectory: true)
            .appendingPathComponent(agentFolderName, isDirectory: true)
    }

    /// Test seam: when set, `agentRootURL` (and therefore `agentRoot`, and every tool that
    /// reads or writes through `MCPPaths`) resolves here instead of the real
    /// `Application Support` folder. Always `nil` in production. Tests set this once, to a
    /// throwaway temporary directory, so calling MCP tools never touches the real user data
    /// folder at `~/Library/Application Support/Compositor/Agent`.
    ///
    /// `nonisolated(unsafe)`: global mutable state with no lock, which is sound only because
    /// it is a test-only seam written once, before any MCP code reads it.
    nonisolated(unsafe) static var agentRootOverride: URL?

    /// The real Agent root, with no side effects: nothing is created on disk by calling this.
    /// Honors `agentRootOverride` when a test has set one; `agentRootURL(under:)` — the pure,
    /// explicitly-based computation — does not, so callers that inject their own base (as
    /// `PreferencesMigration` does) are unaffected by the override.
    static var agentRootURL: URL { agentRootOverride ?? agentRootURL(under: applicationSupportBaseURL) }

    /// The folder agent tools read from and write to. This lives outside any container —
    /// there is no App Sandbox — at `Application Support/Compositor/Agent`, and is readable
    /// and writable by any process running as this user, including the MCP client, which is
    /// what lets an agent drop a source image in, or copy an exported one out. Unlike
    /// `agentRootURL`, reading this property creates the folder if it's missing.
    static var agentRoot: URL {
        let root = agentRootURL
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}