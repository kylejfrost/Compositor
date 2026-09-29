import Foundation
import Synchronization

extension ProfileUsability {
    /// The error that explains why a profile can't be applied; nil when usable.
    nonisolated var error: ProfileError? {
        switch self {
        case .usable: nil
        case .rawOnly: .rawOnly
        case .cameraSpecific(let model): .cameraSpecific(model)
        case .unsupported(let reason): .unsupported(reason)
        }
    }
}

/// Every profile a document or preview can render, keyed by file digest, for the life of the process. Never evicts.
///
/// Invariant: every path that puts a digest into a document registers the profile first, so rendering, saving and
/// undo can always find the bytes by digest.
nonisolated final class ProfileRegistry: Sendable {
    static let shared = ProfileRegistry()

    private let profiles = Mutex<[ProfileDigest: LoadedProfile]>([:])

    init() {}

    /// Size-checks (4 MiB → .tooLarge), parses fully, requires `.usable`, and keeps it. Idempotent: registering the
    /// same bytes again returns the instance already kept.
    @discardableResult func register(_ data: Data) throws -> LoadedProfile {
        guard data.count <= AdobeProfileParser.maximumFileBytes else { throw ProfileError.tooLarge }
        if let kept = profile(ProfileDigest(of: data)) { return kept }
        return try register(LoadedProfile(data: data))
    }

    /// Requires `.usable` and keeps it, unless the same bytes are already kept, in which case that instance is returned.
    @discardableResult func register(_ loaded: LoadedProfile) throws -> LoadedProfile {
        if let error = loaded.profile.usability.error { throw error }
        return profiles.withLock { profiles in
            if let kept = profiles[loaded.digest] { return kept }
            profiles[loaded.digest] = loaded
            return loaded
        }
    }

    func profile(_ digest: ProfileDigest) -> LoadedProfile? {
        profiles.withLock { $0[digest] }
    }

    var count: Int { profiles.withLock { $0.count } }
}
