import Foundation
import Testing
@testable import Compositor

/// Parses every profile installed with Lightroom or Camera Raw. The library is Adobe's, so this only runs on request
/// (`TEST_RUNNER_COMPOSITOR_ADOBE_LIBRARY=1`), asserts invariants rather than counts, and prints counts only.
struct ProfileCorpusTests {
    static let isEnabled = ProcessInfo.processInfo.environment["COMPOSITOR_ADOBE_LIBRARY"] == "1"
    static let library = URL(fileURLWithPath: "/Library/Application Support/Adobe/CameraRaw/Settings", isDirectory: true)

    @Test(.enabled(if: isEnabled)) func installedProfilesParse() throws {
        let enumerator = try #require(FileManager.default.enumerator(at: Self.library, includingPropertiesForKeys: nil))
        var profiles = 0, presets = 0, exact = 0, approximate = 0
        var usability: [String: Int] = [:]
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "xmp" {
            let data = try Data(contentsOf: url)
            let file = url.lastPathComponent
            if String(decoding: data.prefix(8192), as: UTF8.self).contains("PresetType=\"Look\"") {
                profiles += 1
                let profile: AdobeProfile
                do {
                    profile = try AdobeProfileParser.profile(from: data)
                } catch {
                    Issue.record("\(file): \(error)")
                    continue
                }
                for (fingerprint, decoded) in [(profile.lookTableFingerprint, profile.lookTable != nil),
                                               (profile.rgbTableFingerprint, profile.rgbTable != nil)] {
                    if let fingerprint, profile.embeddedTables.contains(fingerprint) {
                        #expect(decoded, "\(file): an embedded table was not decoded")
                    }
                }
                switch profile.usability {
                case .usable:
                    usability["usable", default: 0] += 1
                    #expect(profile.support.contains(.outputReferred), "\(file)")
                    #expect(profile.cameraModelRestriction == nil, "\(file)")
                    if profile.fidelity == .exact { exact += 1 } else { approximate += 1 }
                case .rawOnly: usability["raw only", default: 0] += 1
                case .cameraSpecific: usability["camera specific", default: 0] += 1
                case .unsupported(let reason): usability["unsupported: \(reason)", default: 0] += 1
                }
            } else if String(decoding: data, as: UTF8.self).contains("PresetType=\"Normal\"") {
                presets += 1
                #expect(throws: ProfileError.notAProfile(presetType: "Normal"), "\(file)") {
                    try AdobeProfileParser.profile(from: data)
                }
            }
        }
        print("Profile corpus: \(profiles) profiles, \(usability["usable", default: 0]) usable (\(exact) exact, "
              + "\(approximate) approximate), \(presets) presets")
        for (label, count) in usability.sorted(by: { $0.key < $1.key }) { print("  \(label): \(count)") }
        #expect(usability["usable", default: 0] > 0)
    }
}
