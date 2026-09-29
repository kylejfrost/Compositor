import CoreGraphics
import Foundation
import Synchronization

/// The profile browser's card images: each profile applied at 100 % to the small composite below the layer.
///
/// One serial worker renders them, newest request first, so the cards just scrolled into view come before the ones
/// scrolled past. A profile is read from its file (or, for one only a document has, taken from the registry) and never
/// registered: browsing must not keep every profile in memory.
@Observable final class ProfileThumbnailStore {
    nonisolated private struct Job: Sendable {
        let summary: ProfileSummary
        let source: CGImage
        let generation: Int
    }

    private(set) var images: [ProfileDigest: CGImage] = [:]
    /// Profiles whose picture couldn't be made (the file changed or can't be read since it was listed). They show a
    /// symbol and aren't read and rendered again each time their card appears.
    private(set) var failed: Set<ProfileDigest> = []
    /// Digests waiting or being rendered.
    @ObservationIgnored private var queued: Set<ProfileDigest> = []
    /// Bumped by `cancelAll`, so results that land afterwards are dropped.
    @ObservationIgnored private var generation = 0
    /// Pending jobs, taken from the end (last in, first out).
    nonisolated private let pending = Mutex<[Job]>([])
    nonisolated private static let worker = DispatchQueue(label: "ProfileThumbnails", qos: .userInitiated)

    func image(for summary: ProfileSummary) -> CGImage? { images[summary.digest] }

    func hasFailed(_ summary: ProfileSummary) -> Bool { failed.contains(summary.digest) }

    /// Renders a card image unless it is cached, queued or failed, or the profile can't be applied. Returns whether it
    /// queued a render.
    @discardableResult
    func request(_ summary: ProfileSummary, source: CGImage) -> Bool {
        guard summary.usability == .usable, images[summary.digest] == nil, !failed.contains(summary.digest),
              queued.insert(summary.digest).inserted else { return false }
        let job = Job(summary: summary, source: source, generation: generation)
        pending.withLock { $0.append(job) }
        // One block per job; each takes whichever job is newest when it runs.
        Self.worker.async { [weak self] in
            guard let self, let job = self.pending.withLock({ $0.popLast() }) else { return }
            let image = autoreleasepool { Self.render(job) }
            Task { @MainActor [weak self] in self?.finish(job, image: image) }
        }
        return true
    }

    /// Drops every pending request; renders already running are discarded when they finish.
    func cancelAll() {
        pending.withLock { $0.removeAll() }
        queued.removeAll()
        generation += 1
    }

    private func finish(_ job: Job, image: CGImage?) {
        guard job.generation == generation else { return }
        queued.remove(job.summary.digest)
        if let image { images[job.summary.digest] = image } else { failed.insert(job.summary.digest) }
    }

    nonisolated private static func render(_ job: Job) -> CGImage? {
        let summary = job.summary
        let loaded: LoadedProfile?
        if summary.source == .document {
            loaded = ProfileRegistry.shared.profile(summary.digest)
        } else if let path = summary.path, summary.fileSize <= AdobeProfileParser.maximumFileBytes,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            // Parsed privately: a thumbnail never registers its profile.
            loaded = try? LoadedProfile(data: data)
        } else {
            loaded = nil
        }
        // A file that changed since it was listed shows no picture rather than the wrong one.
        guard let loaded, loaded.digest == summary.digest, loaded.profile.usability == .usable else { return nil }
        return try? ProfileRenderer.apply(job.source, profile: loaded, percent: 100)
    }
}
