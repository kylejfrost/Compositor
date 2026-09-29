import Foundation
@testable import Compositor

/// A home folder in the temporary directory holding the protected roots asked for (every one by default, with
/// `/Volumes` inside it too), created on disk and removed again once the test lets go of it.
final class FakeHome {
    let url: URL
    let locations: [ProtectedRoot: URL]

    init(roots: [ProtectedRoot] = ProtectedRoot.allCases) {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderAccessTests-\(UUID().uuidString)", isDirectory: true)
        var locations: [ProtectedRoot: URL] = [:]
        for root in roots {
            let location = root == .removableVolumes
                ? url.appendingPathComponent("Volumes", isDirectory: true)
                : root.location(home: url)
            try? FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
            locations[root] = location
        }
        self.locations = locations
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    subscript(root: ProtectedRoot) -> URL { locations[root]! }
}

/// Stands in for the directory listing a probe runs: answers per folder (by name), records every folder it's asked
/// to list, and holds `hang` listings until `release()` — the way macOS holds a read while its consent prompt is up.
final class FakeLister: @unchecked Sendable {
    enum Answer {
        case folders([String])
        case failure(any Error)
        case hang
    }

    private let lock = NSLock()
    private var answers: [String: Answer]
    private var listedNames: [String] = []
    private let gate = DispatchSemaphore(value: 0)

    init(_ answers: [String: Answer] = [:]) {
        self.answers = answers
    }

    /// The names of the folders listed so far, in order.
    var listed: [String] { lock.withLock { listedNames } }

    /// Changes how `name` answers from now on, as if the owner changed Compositor's access in System Settings.
    func answer(_ name: String, _ answer: Answer) {
        lock.withLock { answers[name] = answer }
    }

    func list(_ directory: URL) throws -> [String] {
        let answer = lock.withLock {
            listedNames.append(directory.lastPathComponent)
            return answers[directory.lastPathComponent] ?? .folders([])
        }
        switch answer {
        case .folders(let names):
            return names
        case .failure(let error):
            throw error
        case .hang:
            gate.wait()
            gate.signal() // Let any other held listing through too.
            return []
        }
    }

    /// Lets every held listing finish, as if the owner answered "Allow".
    func release() {
        gate.signal()
    }
}

/// Stands in for reading a folder inside /Volumes or cloud storage as a symlink: reads the real link (tests only
/// make them in the temporary folder), records each read and whether it ran on the main thread, and holds reads of
/// `hanging` until `release()` — the way a network volume that stopped answering holds a look at its mount point.
final class LinkReader: @unchecked Sendable {
    struct Read: Equatable {
        let name: String
        let onMainThread: Bool
    }

    private let lock = NSLock()
    private let hanging: String?
    private var readsSoFar: [Read] = []
    private let gate = DispatchSemaphore(value: 0)

    init(hanging: String? = nil) {
        self.hanging = hanging
    }

    /// Every read so far, in order.
    var reads: [Read] { lock.withLock { readsSoFar } }

    func read(_ url: URL) -> String? {
        lock.withLock { readsSoFar.append(Read(name: url.lastPathComponent, onMainThread: Thread.isMainThread)) }
        if url.lastPathComponent == hanging {
            gate.wait()
            gate.signal()
        }
        return FolderAccess.Checker.symlinkTarget(of: url)
    }

    func release() {
        gate.signal()
    }
}

/// How long some main-actor work took, and how long the machine kept work like it waiting meanwhile.
///
/// Suites run in parallel, and in a full run others can hold the main actor, or keep background threads and timers
/// from running, for most of a minute; a timeout that has passed can then resume late through no fault of the code
/// under test. While `body` runs, a background thread keeps napping for a few milliseconds and then asking the main
/// queue to run an empty block, adding up how late it woke and how long each block waited: `stall` bounds how late
/// the work could have resumed because of others. Tests assert upper bounds as `elapsed < bound + stall`, which is
/// the plain bound on an idle machine.
@MainActor
func timed<T>(meter: StallMeter = StallMeter(), _ body: () async throws -> T) async rethrows -> (value: T, elapsed: Duration, stall: Duration) {
    // However `body` ends: a test that throws must not leave the meter's thread napping behind it.
    defer { _ = meter.stop() }
    let clock = ContinuousClock()
    let start = clock.now
    let value = try await body()
    let elapsed = start.duration(to: clock.now)
    return (value, elapsed, meter.stop())
}

/// Adds up how late a background thread wakes from short naps, and how long the main queue keeps its empty blocks
/// waiting, until `stop()` — which counts a nap or a wait still going on too.
final class StallMeter: @unchecked Sendable {
    private static let nap: Duration = .milliseconds(5)
    /// How late a nap may end without counting: a millisecond is ordinary.
    private static let slack: Duration = .milliseconds(1)

    private let lock = NSLock()
    private let clock = ContinuousClock()
    private var total: Duration = .zero
    /// The nap or wait going on now: when it began, and how long it may take without counting.
    private var current: (start: ContinuousClock.Instant, allowed: Duration)?
    private var running = true

    init() {
        Thread.detachNewThread { [self] in
            while begin(allowed: Self.nap + Self.slack) {
                Thread.sleep(forTimeInterval: 0.005)
                guard end(), begin(allowed: .zero) else { return }
                DispatchQueue.main.sync {}
                guard end() else { return }
            }
        }
    }

    /// Starts timing a nap or wait; false once stopped.
    private func begin(allowed: Duration) -> Bool {
        lock.withLock {
            current = (clock.now, allowed)
            return running
        }
    }

    /// Adds what the nap or wait took beyond what it's allowed; false once stopped.
    private func end() -> Bool {
        lock.withLock {
            settle()
            return running
        }
    }

    private func settle() {
        guard let current else { return }
        total += max(.zero, current.start.duration(to: clock.now) - current.allowed)
        self.current = nil
    }

    /// Whether its thread is still measuring.
    var isRunning: Bool { lock.withLock { running } }

    /// Stops measuring and returns the total so far.
    func stop() -> Duration {
        lock.withLock {
            running = false
            settle()
            return total
        }
    }
}
