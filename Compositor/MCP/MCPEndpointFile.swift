import AppKit
import Darwin
import Foundation

/// What the running server publishes about itself so agents (and the `compositor-mcp`
/// bridge) can find it without being told the port. Field names are the file's JSON
/// keys, snake_case as documented for clients.
nonisolated struct MCPEndpointRecord: Codable, Sendable, Equatable {
    /// The full endpoint, e.g. `http://127.0.0.1:2667/mcp`.
    var url: String
    var port: UInt16
    /// The Compositor process serving it; see `MCPEndpointFile.isAlive`.
    var pid: Int32
    var app_version: String
    /// The newest MCP protocol version the server speaks.
    var `protocol`: String
    /// Always `"streamable-http-stateless"`.
    var transport: String
    var started_at: Date
    /// `"bearer"` when every request must carry `Authorization: Bearer <token>`, `"none"` when the server takes any
    /// request. Absent from files written before the token existed, which means `"none"`.
    var auth: String? = nil
    /// With `auth` `"bearer"`: the absolute path of the file holding the token, for the bridge to read. Never the token.
    var token_file: String? = nil

    static let statelessTransport = "streamable-http-stateless"
    static let bearerAuth = "bearer"
    static let noAuth = "none"
}

/// Reads and writes the endpoint file (`MCPSettings.endpointFileURL` in production).
///
/// Written atomically, so a reader never sees half a file; the parent folder is created
/// as needed. Only its owner can read or write it (0600): the `compositor-mcp` bridge
/// refuses a file that other users could change. The file is only a hint: a crashed app
/// leaves a stale one behind, which `isAlive` detects.
nonisolated enum MCPEndpointFile {
    static func write(_ record: MCPEndpointRecord, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: url, options: .atomic)
        // Whatever the umask made of it.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Removes the file; a missing file is not an error.
    static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// The record at `url`, or nil when there is none or it can't be decoded.
    static func read(at url: URL) -> MCPEndpointRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MCPEndpointRecord.self, from: data)
    }

    /// Whether the process that wrote `record` is still running.
    static func isAlive(_ record: MCPEndpointRecord) -> Bool {
        // pid 0 (or negative) would address a whole process group, not one process.
        guard record.pid > 0 else { return false }
        return kill(record.pid, 0) == 0
    }

    /// The bundle identifier every Compositor build shares.
    static let appBundleIdentifier = "com.wonderassembly.compositor"

    /// Whether `pid` is a running Compositor (any copy: a Debug build, `/Applications`).
    static func isCompositorProcess(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == appBundleIdentifier
    }

    /// Called at launch, before this process starts a server: removes the file at `url`
    /// unless it describes another Compositor that is still running. A crash leaves the
    /// file behind, and its pid may since have been reused, so it is stale when it can't
    /// be decoded, names `currentPID` (this process has published nothing yet), names a
    /// process that is gone, or names one that isn't Compositor. The file of a second,
    /// live Compositor stays: it may be serving the stable port right now.
    /// Returns whether a file was removed.
    @discardableResult
    static func removeStale(at url: URL, currentPID: Int32,
                            isCompositor: (Int32) -> Bool = isCompositorProcess) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if let record = read(at: url), record.pid != currentPID, isAlive(record), isCompositor(record.pid) {
            return false
        }
        remove(at: url)
        return true
    }
}
