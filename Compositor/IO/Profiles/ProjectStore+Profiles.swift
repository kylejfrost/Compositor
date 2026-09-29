import Foundation

/// The `profiles/` sidecars of a project: each profile a Profile layer uses, byte for byte, as `<digest>.xmp`, so the
/// project renders the same on a Mac without the profile installed.
extension ProjectStore {
    static let maximumProfileSidecars = 256
    /// Total bytes of every sidecar under `profiles/`.
    static let maximumProfileSidecarBytes = 64 * 1024 * 1024

    /// Distinct profile references of the manifest's Profile adjustments, sorted by digest (first reference's name kept).
    nonisolated static func referencedProfiles(_ manifest: ProjectManifest) -> [ProfileReference] {
        var references: [ProfileDigest: ProfileReference] = [:]
        for layer in manifest.layers {
            guard let adjustment = layer.adjustment, adjustment.kind == .profile,
                  let reference = adjustment.profileSettings?.reference, references[reference.digest] == nil else { continue }
            references[reference.digest] = reference
        }
        return references.values.sorted { $0.digest < $1.digest }
    }

    /// "<digest>.xmp" → exact bytes from ProfileRegistry. Throws ProfileError.notLoaded(name:) for a digest the registry
    /// lacks; ProjectError.tooLarge over the caps.
    func profileSidecars(_ manifest: ProjectManifest) throws -> [String: Data] {
        let references = Self.referencedProfiles(manifest)
        guard references.count <= Self.maximumProfileSidecars else { throw ProjectError.tooLarge }
        var files: [String: Data] = [:]
        var total = 0
        for reference in references {
            guard let loaded = ProfileRegistry.shared.profile(reference.digest) else {
                throw ProfileError.notLoaded(name: reference.name)
            }
            total += loaded.data.count
            guard total <= Self.maximumProfileSidecarBytes else { throw ProjectError.tooLarge }
            files["\(reference.digest.hex).xmp"] = loaded.data
        }
        return files
    }

    /// Verifies every referenced `profiles/<digest>.xmp` and registers it. Throws ProjectError.invalid / .tooLarge.
    /// Files nothing references are ignored.
    func loadProfileSidecars(_ manifest: ProjectManifest, from package: URL) throws {
        let references = Self.referencedProfiles(manifest)
        guard references.count <= Self.maximumProfileSidecars else { throw ProjectError.tooLarge }
        var total = 0
        for reference in references {
            let file = package.appendingPathComponent("profiles").appendingPathComponent("\(reference.digest.hex).xmp")
            guard FileManager.default.fileExists(atPath: file.path) else { throw ProjectError.invalid }
            try checkFile(file, inside: package, maximumBytes: AdobeProfileParser.maximumFileBytes)
            let data = try Data(contentsOf: file)
            total += data.count
            guard total <= Self.maximumProfileSidecarBytes else { throw ProjectError.tooLarge }
            guard ProfileDigest(of: data) == reference.digest else { throw ProjectError.invalid }
            do { try ProfileRegistry.shared.register(data) } catch { throw ProjectError.invalid }
        }
    }
}
