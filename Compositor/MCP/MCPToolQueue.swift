import Foundation

/// Thrown by `MCPToolQueue.run` when the queue already holds its limit of calls.
nonisolated struct MCPQueueFull: LocalizedError {
    let limit: Int
    var errorDescription: String? {
        "Compositor is busy: \(limit) tool calls are already queued. Wait for them to finish, then retry."
    }
}

/// Runs tool calls one at a time, in arrival order, on the main actor, so one
/// document mutation is never interleaved with another — whichever client sent it.
///
/// Bounded: at most `limit` calls may be queued or running at once; a call beyond
/// that fails fast with `MCPQueueFull` instead of piling up behind a slow render.
@MainActor
final class MCPToolQueue {
    let limit: Int
    /// Calls queued or running right now.
    private(set) var depth = 0
    /// True while a call is running; later calls wait in `waiters`, oldest first.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int = MCPSettings.maxQueuedCalls) {
        self.limit = limit
    }

    func run<T: Sendable>(_ body: @MainActor @Sendable () async -> T) async throws -> T {
        guard depth < limit else { throw MCPQueueFull(limit: limit) }
        depth += 1
        defer { depth -= 1 }
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        // Hand the turn straight to the next waiter (busy stays true), or go idle.
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        return await body()
    }
}
