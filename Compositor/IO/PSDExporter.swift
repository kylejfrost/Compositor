import Foundation

/// Writes PSD files off the main actor, as `ImageExporter` writes images.
actor PSDExporter {
    static let shared = PSDExporter()

    func export(_ request: PSDWriteRequest, to url: URL, options: PSDWriteOptions) throws -> PSDWriteReport {
        try PSDWriter.write(request, to: url, options: options)
    }

    /// Writes a save `plan(_:options:)` planned, without planning it again.
    func export(_ plan: PSDWritePlan, to url: URL) throws -> PSDWriteReport {
        try PSDWriter.write(plan, to: url)
    }

    /// Writing `request` with `options`, planned without writing anything (the writer's layer plan): its warnings,
    /// so a lossy save can be agreed to first, and what `export(_:to:)` then writes.
    func plan(_ request: PSDWriteRequest, options: PSDWriteOptions) throws -> PSDWritePlan {
        try PSDWritePlan(request, options: options)
    }
}
