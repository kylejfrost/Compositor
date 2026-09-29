@testable import Compositor
import Foundation

/// The profile library every test in the process shares, so no test reads the real Adobe folders.
enum ProfileTestSupport {
    /// Installed once per test process as `ProfileLibrary.Locations.override`: a temporary root whose `system/` holds
    /// copies of every `CompositorTests/Fixtures/Profiles/profile-*.xmp` plus one raw-only synthetic profile, with
    /// empty `user/` and a not-yet-created `imported/`. Later tasks (MCP) use the same folders.
    ///
    /// Tests run in parallel against these folders. A test that adds a file must give it a unique name and uuid, add
    /// only usable profiles (so `hidden.rawOnly` stays 1), and call `index(refresh: true)` before relying on it.
    static let locations: ProfileLibrary.Locations = {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("CompositorProfileTests-\(UUID().uuidString)", isDirectory: true)
        let system = root.appendingPathComponent("system", isDirectory: true)
        let user = root.appendingPathComponent("user", isDirectory: true)
        do {
            try manager.createDirectory(at: system, withIntermediateDirectories: true)
            try manager.createDirectory(at: user, withIntermediateDirectories: true)
            let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/Profiles", isDirectory: true)
            for name in try manager.contentsOfDirectory(atPath: fixtures.path)
            where name.hasPrefix("profile-") && name.hasSuffix(".xmp") {
                try manager.copyItem(at: fixtures.appendingPathComponent(name), to: system.appendingPathComponent(name))
            }
            try ProfileFixture.xmp(name: "Raw Only", uuid: "0000000000000000000000000000FFFF", outputReferred: false,
                                   rgb: ProfileFixture.rgbTable(divisions: 5))
                .write(to: system.appendingPathComponent("Raw Only.xmp"))
        } catch {
            fatalError("The temporary profile library couldn't be made: \(error)")
        }
        let locations = ProfileLibrary.Locations(adobeSystem: system, adobeUser: user,
                                                 imported: root.appendingPathComponent("imported", isDirectory: true))
        ProfileLibrary.Locations.override = locations
        return locations
    }()
}
