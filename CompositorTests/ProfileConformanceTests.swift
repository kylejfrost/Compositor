import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Compositor's renderer against the Python reference on every usable profile installed with Lightroom or Camera Raw.
/// The references are Adobe-derived, so they live outside the repository: make them with
/// `scripts/profiles/conformance.py --out DIR`, then run with `TEST_RUNNER_COMPOSITOR_PROFILE_REFERENCE=DIR`.
struct ProfileConformanceTests {
    static let reference = ProcessInfo.processInfo.environment["COMPOSITOR_PROFILE_REFERENCE"]
    static let library = "/Library/Application Support/Adobe/CameraRaw/Settings/"

    struct Entry: Decodable {
        let digest: String
        let path: String
        let name: String
        let percent: Int
    }

    @Test(.enabled(if: reference != nil)) func installedProfilesMatchTheReference() throws {
        let folder = URL(fileURLWithPath: try #require(Self.reference), isDirectory: true)
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: folder.appendingPathComponent("index.json")))
        #expect(!entries.isEmpty)
        let probe = try ProfileFixtureFiles.probe()
        var matching = 0
        for entry in entries {
            try #require(entry.path.hasPrefix(Self.library), "\(entry.path) is outside the Camera Raw library")
            let data = try Data(contentsOf: URL(fileURLWithPath: entry.path))
            #expect(ProfileDigest(of: data).hex == entry.digest, "\(entry.name) changed since the reference was made")
            let profile = try LoadedProfile(data: data)
            let output = try ProfileRenderer.apply(probe, profile: profile, percent: entry.percent)
            let rendered = try ProfileFixtureFiles.rgb(of: output)
            let expected = try ProfileFixtureFiles.rgb(folder.appendingPathComponent("\(entry.digest)__\(entry.percent).png")).rgb
            try #require(rendered.count == expected.count)
            let difference = ProfileFixtureFiles.difference(rendered, expected)
            print("\(entry.digest.prefix(12)) \(entry.percent)%: max \(difference.maximum), mean \(difference.mean)")
            let matches = difference.maximum <= 1 && Double(difference.differing) <= 0.005 * Double(rendered.count)
            #expect(matches, "\(entry.name) at \(entry.percent) %: max \(difference.maximum), \(difference.differing) channels differ")
            if matches { matching += 1 }
        }
        print("Profile conformance: \(matching) of \(entries.count) renders match")
    }
}
