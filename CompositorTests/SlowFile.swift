import Darwin
import Foundation
import Synchronization
import Testing

/// A named pipe in a temporary folder that makes whoever opens it wait, as a cloud-only file makes a reader wait
/// for its download: the first open returns once `expectMainActorStaysFree` lets it (or after `delay` at the latest)
/// and reads `bytes`; opens after that read an empty file. The pipe is served for ten seconds from then, then removed
/// with its folder.
nonisolated final class SlowFile: Sendable {
    let url: URL
    private struct Hold {
        /// The file may be read now.
        var released = false
        /// `delay` passed before anything released the file.
        var ranOut = false
    }
    private let hold = Mutex(Hold())

    init(named name: String, delay: Duration, bytes: Data = Data("SLOW".utf8)) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("compositor-slow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent(name)
        let path = url.path
        guard mkfifo(path, 0o600) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let wait = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        Thread.detachNewThread { [self] in
            let deadline = Date().addingTimeInterval(wait)
            while !hold.withLock({ hold in
                if !hold.released, Date() >= deadline { hold.ranOut = true }
                return hold.released || hold.ranOut
            }) {
                usleep(10_000)
            }
            let end = Date().addingTimeInterval(10)
            var first = true
            while Date() < end {
                // Succeeds only while a reader is waiting in open(2); that reader then reads what is written.
                let pipe = open(path, O_WRONLY | O_NONBLOCK)
                if pipe >= 0 {
                    if first { bytes.withUnsafeBytes { _ = write(pipe, $0.baseAddress, $0.count) } }
                    first = false
                    close(pipe)
                } else {
                    usleep(10_000)
                }
            }
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

extension SlowFile {
    /// Expects the main actor to stay free while `work` waits for this file: a probe that sleeps 100 ms on the main
    /// actor gets it back while the file is still held, then lets the file be read. Had `work` waited for the file on
    /// the main actor, the probe could run only once `delay` had run out. `work` is started first, so it has had its
    /// turn on the main actor. How long the probe waits for the main actor doesn't count against `work`: in a full
    /// parallel run nearly every test's turn there is queued at once and the probe's return waits behind them, for most
    /// of the run (40 s and more), so `delay` must outlast the whole run.
    @MainActor func expectMainActorStaysFree(_ work: @escaping @MainActor () async -> Void,
                                             sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let running = Task { @MainActor in await work() }
        let start = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(100))
        let ranOut = hold.withLock { hold in
            hold.released = true
            return hold.ranOut
        }
        #expect(!ranOut, "the main actor was busy until the file was read, for \(start.duration(to: .now))",
                sourceLocation: sourceLocation)
        await running.value
    }
}
