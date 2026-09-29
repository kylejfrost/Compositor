import CryptoKit
import Foundation

/// SHA-256 of a profile file's bytes: which exact file a layer was made with.
nonisolated struct ProfileDigest: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    /// 64 lowercase hex characters.
    let hex: String

    init?(hex: String) {
        guard hex.utf8.count == 64,
              hex.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else { return nil }
        self.hex = hex
    }

    init(of data: Data) {
        hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var description: String { hex }

    static func < (lhs: ProfileDigest, rhs: ProfileDigest) -> Bool { lhs.hex < rhs.hex }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let digest = ProfileDigest(hex: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "A profile digest is 64 lowercase hex characters.")
        }
        self = digest
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// What makes two profile files the same profile for display and de-duplication, whatever their bytes.
nonisolated struct ProfileIdentity: Hashable, Codable, Sendable {
    /// crs:UUID, uppercase.
    let uuid: String
    /// Table fingerprints named by LookTable/RGBTable, uppercase, sorted.
    let tables: [String]
}

nonisolated enum CameraRawPresetType: String, Codable, Sendable {
    case look = "Look", normal = "Normal"
}

nonisolated struct ProfileSupport: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int
    static let amount = ProfileSupport(rawValue: 1 << 0)             // crs:SupportsAmount
    static let color = ProfileSupport(rawValue: 1 << 1)              // crs:SupportsColor
    static let monochrome = ProfileSupport(rawValue: 1 << 2)         // crs:SupportsMonochrome
    static let sceneReferred = ProfileSupport(rawValue: 1 << 3)      // crs:SupportsSceneReferred
    static let outputReferred = ProfileSupport(rawValue: 1 << 4)     // crs:SupportsOutputReferred
    static let highDynamicRange = ProfileSupport(rawValue: 1 << 5)   // crs:SupportsHighDynamicRange
    static let normalDynamicRange = ProfileSupport(rawValue: 1 << 6) // crs:SupportsNormalDynamicRange
}

/// A DNG LookTable (`dng_hue_sat_map`): hue shift, saturation scale and value scale on a hue × saturation × value grid.
nonisolated struct HueSatMap: Equatable, Sendable {
    nonisolated enum Encoding: UInt32, Sendable { case linear = 0, sRGB = 1 }
    var hueDivisions: Int
    var saturationDivisions: Int
    var valueDivisions: Int
    /// (hue shift in degrees, saturation scale, value scale) per node, flattened; node index ((v·H + h)·S + s), ×3.
    var entries: [Float]
    var encoding: Encoding
    var minimumAmount: Double
    var maximumAmount: Double
    var flags: UInt32?
    var isFixedAmount: Bool { minimumAmount == 1 && maximumAmount == 1 }
}

/// A Camera Raw RGB table (`dng_rgb_table`): a 1D or 3D lookup in a stated colour space and transfer function.
nonisolated struct RGBTable: Equatable, Sendable {
    nonisolated enum Primaries: UInt32, Sendable { case sRGB = 0, adobeRGB = 1, proPhoto = 2, displayP3 = 3, rec2020 = 4 }
    nonisolated enum Gamma: UInt32, Sendable { case linear = 0, sRGB = 1, gamma18 = 2, gamma22 = 3, rec2020 = 4 }
    nonisolated enum Gamut: UInt32, Sendable { case clip = 0, extend = 1 }
    var dimensions: Int
    var divisions: Int
    /// Absolute samples (identity already added), 0…65535, flattened ×3.
    /// 3D order r-major: ((r·D + g)·D + b)·3. 1D: i·3.
    var samples: [UInt16]
    var primaries: Primaries
    var gamma: Gamma
    var gamut: Gamut
    var minimumAmount: Double
    var maximumAmount: Double
    var flags: UInt32?
}

nonisolated enum AdobeTable: Equatable, Sendable {
    case look(HueSatMap)
    case rgb(RGBTable)
}

/// A tone curve point, 0…255 on both axes.
nonisolated struct ProfileCurvePoint: Hashable, Sendable {
    var x: Int
    var y: Int
}

/// The develop settings a profile carries besides its tables.
nonisolated struct ProfileDevelopSettings: Equatable, Sendable {
    /// Simple crs values that are not metadata, keyed by name without the prefix ("Clarity2012" → "+10").
    var values: [String: String] = [:]
    /// rdf:Seq point curves keyed by name without prefix ("ToneCurvePV2012", "ToneCurvePV2012Red", …).
    var toneCurves: [String: [ProfileCurvePoint]] = [:]
    /// Settings with struct, Seq-of-struct, Bag or Alt values, kept by name only ("PointColors").
    var structured: Set<String> = []

    /// The settings the renderer reproduces.
    static let implemented: Set<String> = [
        "ToneCurvePV2012", "ToneCurvePV2012Red", "ToneCurvePV2012Green", "ToneCurvePV2012Blue",
        "ConvertToGrayscale", "RGBTableAmount",
    ]

    /// Settings that only qualify a companion setting, so on their own they change nothing.
    private static let companions: Set<String> = [
        "ParametricShadowSplit", "ParametricMidtoneSplit", "ParametricHighlightSplit", "ColorGradeBlending",
        "SplitToningBalance", "CurveRefineSaturation", "PostCropVignetteMidpoint", "PostCropVignetteFeather",
        "PostCropVignetteRoundness", "PostCropVignetteStyle", "PostCropVignetteHighlightContrast",
    ]

    /// Whether ignoring this setting leaves the rendering exact (the reference's `neutral_value`). Numeric settings,
    /// GrayMixer*, HueAdjustment*, SaturationAdjustment* and LuminanceAdjustment* among them, are neutral at 0;
    /// companions and split-toning or colour-grading hues are neutral whatever their value.
    static func isNeutral(_ name: String, _ value: String) -> Bool {
        if companions.contains(name) { return true }
        if (name.hasPrefix("SplitToning") || name.hasPrefix("ColorGrade")) && name.hasSuffix("Hue") { return true }
        return Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) == 0
    }

    /// Every setting the renderer does not reproduce and that is not neutral, sorted.
    var ignored: [String] {
        var names = structured
        for (name, value) in values where !Self.implemented.contains(name) && !Self.isNeutral(name, value) {
            names.insert(name)
        }
        for name in toneCurves.keys where !Self.implemented.contains(name) { names.insert(name) }
        return names.sorted()
    }
}

nonisolated enum ProfileUsability: Codable, Equatable, Hashable, Sendable {
    case usable
    case rawOnly
    case cameraSpecific(String)
    case unsupported(String)
}

/// Whether Compositor reproduces everything the profile does; approximate profiles are shown with a badge.
nonisolated enum ProfileFidelity: Codable, Equatable, Hashable, Sendable {
    case exact
    case approximate(ignored: [String])
}

/// A Lightroom or Camera Raw profile (`crs:PresetType="Look"`), parsed.
nonisolated struct AdobeProfile: Equatable, Sendable {
    var presetType: CameraRawPresetType
    var uuid: String
    var name: String
    var group: String?
    var sortName: String?
    var shortName: String?
    /// crs:Description.
    var summary: String?
    var cluster: String?
    var version: String?
    var processVersion: String?
    var copyright: String?
    var support: ProfileSupport
    /// nil when absent or empty.
    var cameraModelRestriction: String?
    var cameraProfile: String?
    var requiresRGBTables: Bool
    var convertToGrayscale: Bool
    /// crs:RGBTableAmount; 1 when absent.
    var rgbTableAmount: Double
    /// Uppercase.
    var lookTableFingerprint: String?
    var rgbTableFingerprint: String?
    /// Fingerprints that have a crs:Table_<fp> in this file.
    var embeddedTables: Set<String>
    var tablesDecoded: Bool
    /// nil when absent or when parsed with decodeTables: false.
    var lookTable: HueSatMap?
    var rgbTable: RGBTable?
    var settings: ProfileDevelopSettings

    private var namedTables: [String] { [lookTableFingerprint, rgbTableFingerprint].compactMap { $0 } }

    var identity: ProfileIdentity { ProfileIdentity(uuid: uuid, tables: namedTables.sorted()) }

    var usability: ProfileUsability {
        if let cameraModelRestriction { return .cameraSpecific(cameraModelRestriction) }
        guard support.contains(.outputReferred) else { return .rawOnly }
        if !namedTables.allSatisfy(embeddedTables.contains) { return .unsupported("a table it names isn't in the file") }
        if requiresRGBTables { return .unsupported("it needs a raw file's RGB tables") }
        // Percentages for data embedded in raw and DNG files, not tables in the profile.
        for key in ["RGBTables", "ProfileGainTableMap", "ProfileToneCurve"] {
            if let value = settings.values[key], value != "0" { return .unsupported("it uses data stored in raw files (\(key))") }
        }
        return .usable
    }

    var fidelity: ProfileFidelity {
        let ignored = settings.ignored
        return ignored.isEmpty ? .exact : .approximate(ignored: ignored)
    }
}

/// A profile file held in memory with its digest, so it can be embedded byte for byte and re-parsed without the library.
nonisolated final class LoadedProfile: Sendable {
    let digest: ProfileDigest
    let data: Data
    let profile: AdobeProfile

    /// Parses fully (decodeTables: true); does not check usability.
    init(data: Data) throws {
        profile = try AdobeProfileParser.profile(from: data)
        digest = ProfileDigest(of: data)
        self.data = data
    }
}

nonisolated enum ProfileError: LocalizedError, Equatable, Sendable {
    case unreadable(String)
    case tooLarge
    case malformed(String)
    case notAProfile(presetType: String?)
    case rawOnly
    case cameraSpecific(String)
    case unsupported(String)
    case notLoaded(name: String)
    case digestMismatch
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let detail): "The profile couldn't be read: \(Self.clause(detail))."
        case .tooLarge: "The profile file is larger than 4 MB."
        case .malformed(let detail): "This isn't a valid Lightroom or Camera Raw profile (\(Self.clause(detail)))."
        case .notAProfile(let presetType):
            presetType == CameraRawPresetType.normal.rawValue
                ? "This is a Lightroom or Camera Raw preset, not a profile."
                : "This file isn't a Lightroom or Camera Raw profile."
        case .rawOnly: "This profile only works on raw photos. Compositor applies profiles to rendered images."
        case .cameraSpecific(let model): "This profile is made for raw photos from the \(model)."
        case .unsupported(let reason): "Compositor can't apply this profile: \(reason)."
        case .notLoaded(let name): "The profile “\(name)” isn't loaded."
        case .digestMismatch: "The profile file changed after it was listed. Refresh the list and try again."
        case .writeFailed(let detail): "The profile couldn't be copied into Compositor's profile library: \(Self.clause(detail))."
        }
    }

    /// A detail without its final period, since Cocoa's messages end in one and these descriptions add their own.
    private static func clause(_ detail: String) -> Substring {
        detail.hasSuffix(".") ? detail.dropLast() : Substring(detail)
    }
}
