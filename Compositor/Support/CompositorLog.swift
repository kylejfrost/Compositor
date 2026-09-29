import Foundation
import os
import Synchronization

/// Compositor's diagnostic log: what the app, its MCP server and the documents it opens and saves did, as JSON Lines
/// in `~/Library/Logs/Compositor/compositor-YYYY-MM-DD.jsonl`, so a problem met while using the app (or while an
/// agent drives it) can be looked into afterwards. docs/logging.md describes the events, the files and the privacy
/// rules; `scripts/collect-logs.sh` gathers them.
///
/// One object per line: `ts` (UTC, milliseconds), `level`, `cat`, `event`, then the event's fields
/// (`LogEncoding` applies the privacy rules: no access token, no image data, text cut short). Each event is also sent
/// to the unified log (subsystem `com.wonderassembly.compositor`, the event's category), at a level `log show` keeps.
///
/// Logging never slows the caller: `log` only checks the switches and queues the event; encoding, the unified-log
/// copy and the file writes happen on the log's own serial queue. At most `Configuration.maxPending` events wait there;
/// past that they are counted and dropped (a `log_dropped` event says how many), and a failed write is counted, never
/// thrown.
///
/// `shared` writes nothing until the app configures it at launch (`CompositorLogSettings.startAppLog`), so the unit
/// tests the app hosts never touch the real log folder. Tests make their own logs in temporary folders and route
/// events to them with `taskLog`.
nonisolated final class CompositorLog: Sendable {
    enum Level: String, Sendable, Comparable, CaseIterable {
        case debug, info, notice, warning, error

        private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rank < rhs.rank }

        /// The unified-log level: info and above as notice or error, which `log show` keeps without extra flags.
        var osLogType: OSLogType {
            switch self {
            case .debug: .debug
            case .info, .notice: .default
            case .warning, .error: .error
            }
        }
    }

    enum Category: String, Sendable, CaseIterable {
        case mcp, http, bridge, document, psd, profile, folderAccess = "folder_access", app, update
    }

    struct Configuration: Sendable {
        /// Where the files go; nil writes none.
        var directory: URL?
        var isEnabled: Bool
        /// Adds `debug` events (argument summaries of read-only tools, render timings).
        var isVerbose = false
        /// Copies each event to the unified log. The app's log does; tests' logs don't.
        var mirrorsToUnifiedLog = false
        var limits = LogFileLimits()
        /// Events waiting for the queue past which new ones are dropped (and counted); at least 1, so a drop always
        /// has a write in flight to report it.
        var maxPending = CompositorLog.defaultMaxPending
        /// Names each day's file.
        var timeZone: TimeZone = .current
        /// Stamps events; tests inject their own.
        var now: @Sendable () -> Date = { Date() }
    }

    /// What `get_app_info` and Settings report about a log.
    struct Status: Equatable, Sendable {
        var isEnabled: Bool
        var isVerbose: Bool
        var directory: URL?
    }

    static let subsystem = "com.wonderassembly.compositor"
    /// The app's `Configuration.maxPending`.
    static let defaultMaxPending = 10_000

    /// The app's log: silent until configured at launch.
    static let shared = CompositorLog(Configuration(directory: nil, isEnabled: false))

    /// A log for the current task and the tasks it starts, used in place of `shared`: tests route one call's events
    /// to a log of their own without touching the app's, and an `MCPServer` built with its own log routes its calls'.
    @TaskLocal static var taskLog: CompositorLog?

    /// The log in effect: the task's, else the app's.
    static var active: CompositorLog { taskLog ?? shared }

    private struct Event {
        let date: Date
        let level: Level
        let category: Category
        let name: String
        let fields: [String: LogValue]
    }

    private struct State {
        var configuration: Configuration
        var pending: [Event] = []
        var dropped = 0
        var draining = false
        var failedWrites = 0

        func accepts(_ level: Level) -> Bool {
            configuration.isEnabled && (configuration.directory != nil || configuration.mirrorsToUnifiedLog)
                && (level > .debug || configuration.isVerbose)
        }
    }

    private let state: Mutex<State>
    private let queue = DispatchQueue(label: "com.wonderassembly.compositor.log", qos: .utility)
    private let sink = LogFileSink()

    private static let unifiedLoggers: [Category: Logger] = Dictionary(uniqueKeysWithValues: Category.allCases.map {
        ($0, Logger(subsystem: subsystem, category: $0.rawValue))
    })

    init(_ configuration: Configuration) {
        state = Mutex(State(configuration: configuration))
    }

    // MARK: Switches

    /// Replaces the configuration; events already queued are written under the new one.
    func configure(_ configuration: Configuration) {
        state.withLock { $0.configuration = configuration }
        queue.async { self.sink.close() }
    }

    func setEnabled(_ enabled: Bool) {
        state.withLock { $0.configuration.isEnabled = enabled }
        if !enabled { queue.async { self.sink.close() } }
    }

    func setVerbose(_ verbose: Bool) {
        state.withLock { $0.configuration.isVerbose = verbose }
    }

    var status: Status {
        state.withLock { Status(isEnabled: $0.configuration.isEnabled, isVerbose: $0.configuration.isVerbose,
                                directory: $0.configuration.directory) }
    }

    /// Whether `debug` events are being kept: callers skip work that only verbose logging needs.
    var isVerbose: Bool { state.withLock { $0.accepts(.debug) } }

    /// Whether `info` and higher events are being kept: callers skip work (measuring a file) that only the log needs.
    var isRecording: Bool { state.withLock { $0.accepts(.info) } }

    /// Lines that could not be written since this log was made.
    var failedWrites: Int { state.withLock { $0.failedWrites } }

    // MARK: Logging

    /// Queues an event. `fields` is only evaluated when the event will be kept.
    func log(_ level: Level, _ category: Category, _ event: String, _ fields: @autoclosure () -> [String: LogValue] = [:]) {
        guard let now = state.withLock({ $0.accepts(level) ? $0.configuration.now : nil }) else { return }
        let item = Event(date: now(), level: level, category: category, name: event, fields: fields())
        let schedules = state.withLock { state -> Bool in
            guard state.pending.count < max(1, state.configuration.maxPending) else {
                state.dropped += 1
                return false
            }
            state.pending.append(item)
            guard !state.draining else { return false }
            state.draining = true
            return true
        }
        if schedules { queue.async { self.drain() } }
    }

    func debug(_ category: Category, _ event: String, _ fields: @autoclosure () -> [String: LogValue] = [:]) {
        log(.debug, category, event, fields())
    }

    func info(_ category: Category, _ event: String, _ fields: @autoclosure () -> [String: LogValue] = [:]) {
        log(.info, category, event, fields())
    }

    func notice(_ category: Category, _ event: String, _ fields: @autoclosure () -> [String: LogValue] = [:]) {
        log(.notice, category, event, fields())
    }

    func warning(_ category: Category, _ event: String, _ fields: @autoclosure () -> [String: LogValue] = [:]) {
        log(.warning, category, event, fields())
    }

    func error(_ category: Category, _ event: String, _ fields: @autoclosure () -> [String: LogValue] = [:]) {
        log(.error, category, event, fields())
    }

    /// Waits until every event queued so far is written: before the app quits, and in tests before reading the
    /// files. Never call it from the log's own queue.
    func flush() {
        queue.sync {}
    }

    /// Runs `body` while the log's queue is held, once everything queued before has been written: events `body` logs
    /// wait unwritten until it returns. Tests use it to fill the queue past `maxPending` and to show `log` never
    /// waits for a write. Never call it from the log's own queue.
    func holdingQueue(_ body: () throws -> Void) rethrows {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        queue.async {
            started.signal()
            release.wait()
        }
        started.wait()
        defer { release.signal() }
        try body()
    }

    // MARK: Writing (on `queue`)

    private func drain() {
        while true {
            let (events, dropped, configuration) = state.withLock { state in
                let taken = (state.pending, state.dropped, state.configuration)
                state.pending = []
                state.dropped = 0
                if taken.0.isEmpty, taken.1 == 0 { state.draining = false }
                return taken
            }
            guard !events.isEmpty || dropped > 0 else { return }
            var lines: [(day: String, text: String)] = []
            lines.reserveCapacity(events.count + 1)
            if dropped > 0 {
                let date = configuration.now()
                let text = LogEncoding.line(date: date, level: Level.warning.rawValue, category: Category.app.rawValue,
                                            event: "log_dropped", fields: ["count": .int(dropped)])
                lines.append((LogFileSink.day(of: date, in: configuration.timeZone), text))
            }
            for event in events {
                let text = LogEncoding.line(date: event.date, level: event.level.rawValue, category: event.category.rawValue,
                                            event: event.name, fields: event.fields)
                if configuration.mirrorsToUnifiedLog, let logger = Self.unifiedLoggers[event.category] {
                    logger.log(level: event.level.osLogType, "\(text, privacy: .public)")
                }
                lines.append((LogFileSink.day(of: event.date, in: configuration.timeZone), text))
            }
            guard let directory = configuration.directory else { continue }
            let failures = sink.write(lines, to: directory, limits: configuration.limits,
                                      now: configuration.now(), timeZone: configuration.timeZone)
            if failures > 0 { state.withLock { $0.failedWrites += failures } }
        }
    }
}

/// The diagnostic log's settings (Compositor › Settings…, Diagnostic logs) and where the app's log lives.
enum CompositorLogSettings {
    static let enabledKey = "log.enabled"
    static let verboseKey = "log.verbose"

    /// On unless turned off in Settings.
    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Off unless turned on in Settings.
    static func isVerbose(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: verboseKey)
    }

    /// `~/Library/Logs/Compositor`. A pure path computation: nothing is created by reading it.
    static var directoryURL: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return library.appendingPathComponent("Logs/Compositor", isDirectory: true)
    }

    /// Starts the app's log (`CompositorLog.shared`) as `defaults` say: in `~/Library/Logs/Compositor`, copied to the
    /// unified log. Only the app does this at launch, never a test host (`LaunchTasks.writesLogs`).
    static func startAppLog(defaults: UserDefaults = .standard) {
        CompositorLog.shared.configure(CompositorLog.Configuration(
            directory: directoryURL, isEnabled: isEnabled(in: defaults), isVerbose: isVerbose(in: defaults),
            mirrorsToUnifiedLog: true))
    }

    /// Turns the app's log on or off, remembering the choice.
    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard, log: CompositorLog = .shared) {
        defaults.set(enabled, forKey: enabledKey)
        log.setEnabled(enabled)
    }

    /// Turns verbose logging on or off, remembering the choice.
    static func setVerbose(_ verbose: Bool, in defaults: UserDefaults = .standard, log: CompositorLog = .shared) {
        defaults.set(verbose, forKey: verboseKey)
        log.setVerbose(verbose)
    }
}
