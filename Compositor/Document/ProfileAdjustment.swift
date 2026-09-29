import CoreGraphics
import Foundation

/// Which profile a Profile layer applies. The digest names the sidecar `profiles/<digest>.xmp`, which is authoritative;
/// the rest is for display and for matching an installed copy.
nonisolated struct ProfileReference: Codable, Equatable, Hashable, Sendable {
    var digest: ProfileDigest
    /// crs:UUID, 32 hex characters.
    var uuid: String?
    /// Display only.
    var name: String
    var group: String?

    init(digest: ProfileDigest, uuid: String?, name: String, group: String?) {
        self.digest = digest
        self.uuid = uuid
        self.name = name
        self.group = group
    }

    /// The profile's name, trimmed, and group, each shortened to `maximumTextBytes` for display (the digest names the
    /// profile), so every profile that parses makes a valid reference.
    init(_ loaded: LoadedProfile) {
        self.init(digest: loaded.digest, uuid: loaded.profile.uuid,
                  name: Self.shortened(loaded.profile.name.trimmingCharacters(in: .whitespacesAndNewlines)),
                  group: loaded.profile.group.map(Self.shortened))
    }

    static let maximumTextBytes = 1024

    /// `text` cut to at most `maximumTextBytes` UTF-8 bytes, at a character boundary.
    static func shortened(_ text: String) -> String {
        guard text.utf8.count > maximumTextBytes else { return text }
        var result = ""
        var bytes = 0
        for character in text {
            let count = String(character).utf8.count
            guard bytes + count <= maximumTextBytes else { break }
            result.append(character)
            bytes += count
        }
        return result
    }

    /// The name is non-empty after trimming and, like the group, at most 1024 UTF-8 bytes; a uuid is 32 hex characters.
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= Self.maximumTextBytes
            && (group?.utf8.count ?? 0) <= Self.maximumTextBytes
            && (uuid.map { $0.utf8.count == 32 && $0.allSatisfy { $0.isASCII && $0.isHexDigit } } ?? true)
    }
}

/// A Profile layer's settings: a Lightroom or Camera Raw creative profile at an Amount.
nonisolated struct ProfileAdjustmentSettings: Codable, Equatable, Sendable {
    static let amountRange: ClosedRange<Int> = 0...200
    /// nil is None: the layer passes its input through.
    var reference: ProfileReference?
    /// Percent, 100 as designed; always 100 for a profile without Amount.
    var amount: Int = 100

    init(reference: ProfileReference? = nil, amount: Int = 100) {
        self.reference = reference
        self.amount = amount
    }

    var isValid: Bool { Self.amountRange.contains(amount) && (reference?.isValid ?? true) }

    /// `image` itself without a reference; throws `ProfileError.notLoaded(name:)` when the registry lacks the digest.
    /// `tables` is what a large image does without a baked table (see `ProfileTablePolicy`).
    func apply(_ image: CGImage, tables: ProfileTablePolicy = .bakeNow) throws -> CGImage {
        guard let reference else { return image }
        guard let loaded = ProfileRegistry.shared.profile(reference.digest) else {
            throw ProfileError.notLoaded(name: reference.name)
        }
        return try ProfileRenderer.apply(image, profile: loaded, percent: amount, tables: tables)
    }
}

extension EditorSession {
    /// A configured Profile layer above the active layer as one undo step ("New Profile Adjustment"), named after the
    /// profile unless `name` is given, without opening an editor. Registers `loaded`; nil when it can't be applied or
    /// layers can't be edited. Amount is forced to 100 for a profile without Amount and clamped to 0…200 otherwise.
    @discardableResult func addProfileAdjustment(_ loaded: LoadedProfile, amount: Int = 100, name: String? = nil) -> UUID? {
        guard canEditLayers, let registered = try? ProfileRegistry.shared.register(loaded) else { return nil }
        let range = ProfileAdjustmentSettings.amountRange
        var adjustment = LayerAdjustment(kind: .profile)
        adjustment.profile = ProfileAdjustmentSettings(
            reference: ProfileReference(registered),
            amount: registered.profile.support.contains(.amount) ? min(max(amount, range.lowerBound), range.upperBound) : 100)
        guard adjustment.isValid else { return nil }
        let given = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return insertAdjustmentLayer(adjustment, name: given.flatMap { $0.isEmpty ? nil : $0 } ?? registered.profile.name)
    }
}
