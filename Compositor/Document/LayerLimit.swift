import Foundation

/// A file or an edit that would give a document more than `maximum` layers (folders count too), the most Compositor
/// holds. Opening a file says so with this, rather than as a pixel budget.
nonisolated struct LayerLimitError: LocalizedError, Equatable, Sendable {
    static let maximum = 10_000

    var errorDescription: String? {
        "This document would have more than 10,000 layers (folders included), the most Compositor supports."
    }
}
