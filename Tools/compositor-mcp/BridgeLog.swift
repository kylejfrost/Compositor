import Foundation
import Synchronization

/// The bridge's diagnostic log: one JSON object per line, in the app's format (`ts`, `level`, `cat`, `event`, then
/// the event's fields; docs/logging.md), in `~/Library/Logs/Compositor/bridge.jsonl`. It records the bridge's start,
/// how it found (or launched) Compositor, each line it forwarded (method, id, tool, HTTP status, JSON-RPC error code,
/// duration and sizes, never the arguments or the answer), 401 retries, connection failures, and why it exited.
/// The access token never reaches it.
///
/// A small implementation of its own, as the bridge shares no code with the app: at 20 MB `bridge.jsonl` becomes
/// `bridge.1.jsonl` (replacing the previous one), so it holds at most about 40 MB. Every bridge a client starts
/// appends to the same file, each line in one write and carrying its `pid`. The folder is 0700 and the file 0600.
/// Writing is best effort: a failure never reaches the client. stderr is unchanged (`Log`).
final class BridgeLog: Sendable {
    static let shared = BridgeLog()

    /// Where the log goes, from the command line.
    enum Destination: Sendable {
        /// `~/Library/Logs/Compositor/bridge.jsonl`, unless Compositor's Settings turned diagnostic logs off.
        case standard
        /// `--log-file`.
        case file(URL)
        /// `--no-log`.
        case off
    }

    static let maxFileBytes = 20 * 1024 * 1024
    /// Strings are cut to this many characters.
    static let textLimit = 300

    private struct State {
        var url: URL?
        var descriptor: Int32 = -1
        var size = 0
    }

    private let state = Mutex(State())

    /// `~/Library/Logs/Compositor/bridge.jsonl`.
    static var standardURL: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return library.appendingPathComponent("Logs/Compositor/bridge.jsonl")
    }

    /// Whether Compositor's Settings leave diagnostic logs on (`log.enabled`, on unless turned off there).
    static var isEnabledInSettings: Bool {
        let value = CFPreferencesCopyAppValue("log.enabled" as CFString, AppLauncher.appBundleIdentifier as CFString)
        return (value as? Bool) ?? true
    }

    /// Opens the log `destination` names, rolling a full file over first. Nothing is logged before this.
    func start(_ destination: Destination) {
        let url: URL
        switch destination {
        case .off: return
        case .file(let file): url = file
        case .standard:
            guard Self.isEnabledInSettings else { return }
            url = Self.standardURL
        }
        state.withLock { state in
            state.url = url
            Self.open(&state)
        }
    }

    func info(_ event: String, _ fields: [String: Any] = [:]) { write("info", event, fields) }
    func notice(_ event: String, _ fields: [String: Any] = [:]) { write("notice", event, fields) }
    func warning(_ event: String, _ fields: [String: Any] = [:]) { write("warning", event, fields) }

    /// Appends one event: `fields` hold JSON values (strings, numbers, booleans, arrays and objects of them).
    func write(_ level: String, _ event: String, _ fields: [String: Any]) {
        var fields = fields.mapValues(Self.shortened)
        fields["pid"] = Int(getpid())
        let body = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0.dropFirst(), as: UTF8.self) } ?? "}"
        // Time, level, category and event first, as the app writes them, so a plain text comparison filters by time.
        let line = "{\"ts\":\"\(Self.timestamp(Date()))\",\"level\":\"\(level)\",\"cat\":\"bridge\",\"event\":\"\(event)\","
            + body + "\n"
        let data = Data(line.utf8)
        state.withLock { state in
            guard state.url != nil else { return }
            if state.descriptor < 0 || state.size + data.count > Self.maxFileBytes { Self.open(&state) }
            guard state.descriptor >= 0 else { return }
            if writeAll(data, to: state.descriptor) {
                state.size += data.count
            } else {
                close(state.descriptor)
                state.descriptor = -1
            }
        }
    }

    /// (Re)opens `state.url`, first rolling it over to `bridge.1.jsonl` when it's full.
    private static func open(_ state: inout State) {
        if state.descriptor >= 0 { close(state.descriptor) }
        state.descriptor = -1
        guard let url = state.url else { return }
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        var info = stat()
        if stat(url.path, &info) == 0, Int(info.st_size) >= maxFileBytes {
            let rolled = url.deletingPathExtension().appendingPathExtension("1").appendingPathExtension(url.pathExtension)
            _ = rename(url.path, rolled.path)
        }
        let descriptor = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        fchmod(descriptor, 0o600)
        state.descriptor = descriptor
        state.size = stat(url.path, &info) == 0 ? Int(info.st_size) : 0
    }

    /// Strings cut to `textLimit`, inside arrays and objects too.
    private static func shortened(_ value: Any) -> Any {
        switch value {
        case let text as String: text.count > textLimit ? String(text.prefix(textLimit)) + "…" : text
        case let items as [Any]: items.map(shortened)
        case let members as [String: Any]: members.mapValues(shortened)
        default: value
        }
    }

    /// ISO 8601 in UTC with milliseconds, as the app writes it.
    static func timestamp(_ date: Date) -> String {
        let total = Int64((date.timeIntervalSince1970 * 1000).rounded())
        var seconds = time_t(total / 1000)
        var parts = tm()
        gmtime_r(&seconds, &parts)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", Int(parts.tm_year) + 1900, Int(parts.tm_mon) + 1,
                      Int(parts.tm_mday), Int(parts.tm_hour), Int(parts.tm_min), Int(parts.tm_sec), Int(total % 1000))
    }

    /// Milliseconds since `start`, to a tenth.
    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        ((ContinuousClock.now - start) / .microseconds(100)).rounded() / 10
    }

    // MARK: Events

    /// A forwarded line and how it was answered. The JSON-RPC error code is read from a small answer only: a tool's
    /// result, often an image, is never parsed again for the log.
    func forwarded(_ message: JSONRPCLine, bytes: Int, response: HTTPPoster.Response, startedAt started: ContinuousClock.Instant) {
        var fields = Self.describe(message)
        fields["status"] = response.status
        fields["duration_ms"] = Self.milliseconds(since: started)
        fields["request_bytes"] = bytes
        fields["response_bytes"] = response.body.count
        if response.body.count < 16 * 1024,
           let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
           let code = (object["error"] as? [String: Any])?["code"] as? Int {
            fields["rpc_error"] = code
        }
        write((200..<300).contains(response.status) ? "info" : "notice", "forward", fields)
    }

    /// A line that couldn't be delivered: Compositor wasn't reachable, or its token couldn't be used.
    func unreachable(_ message: JSONRPCLine, reason: String, startedAt started: ContinuousClock.Instant) {
        var fields = Self.describe(message)
        fields["reason"] = reason
        fields["duration_ms"] = Self.milliseconds(since: started)
        warning("unreachable", fields)
    }

    /// The method, id(s) and tool of a line, as strings.
    private static func describe(_ message: JSONRPCLine) -> [String: Any] {
        var fields: [String: Any] = ["method": message.method ?? (message.isBatch ? "batch" : "message")]
        if message.isBatch {
            fields["ids"] = message.requestIDs.map { "\($0)" }
        } else if let id = message.requestIDs.first {
            fields["id"] = "\(id)"
        }
        if let tool = message.toolName { fields["tool"] = tool }
        return fields
    }
}
