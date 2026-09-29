import Foundation
import Testing
@testable import Compositor

/// `ProfileRegistry.shared` is process-global and tests run in parallel, so every fixture here has its own UUID and
/// name, and the tests look profiles up by digest instead of counting them.
struct ProfileRegistryTests {
    static func uniqueUUID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") }

    static func profile(outputReferred: Bool = true, cameraModel: String? = nil, presetType: String = "Look",
                        embedTables: Bool = true) -> Data {
        let uuid = uniqueUUID()
        return ProfileFixture.xmp(name: "Registry \(uuid)", uuid: uuid, presetType: presetType,
                                  outputReferred: outputReferred, cameraModel: cameraModel,
                                  rgb: ProfileFixture.rgbTable(divisions: 5), embedTables: embedTables)
    }

    @Test func registerIsIdempotent() throws {
        let data = Self.profile()
        let first = try ProfileRegistry.shared.register(data)
        let second = try ProfileRegistry.shared.register(data)
        #expect(second === first)
        #expect(first.digest == ProfileDigest(of: data))
        #expect(first.data == data)
        #expect(ProfileRegistry.shared.profile(first.digest) === first)
        // A separately loaded copy of the same bytes resolves to the instance already kept.
        #expect(try ProfileRegistry.shared.register(LoadedProfile(data: data)) === first)
    }

    @Test func registerRejectsWhatCannotBeApplied() throws {
        var padded = Self.profile()
        padded.append(Data(repeating: 0x20, count: AdobeProfileParser.maximumFileBytes + 1 - padded.count))
        let cases: [(Data, ProfileError)] = [
            (Self.profile(outputReferred: false), .rawOnly),
            (Self.profile(cameraModel: "Nikon Z 8"), .cameraSpecific("Nikon Z 8")),
            (Self.profile(embedTables: false), .unsupported("a table it names isn't in the file")),
            (Self.profile(presetType: "Normal"), .notAProfile(presetType: "Normal")),
            (padded, .tooLarge),
        ]
        #expect(padded.count == AdobeProfileParser.maximumFileBytes + 1)
        for (data, error) in cases {
            #expect(throws: error) { try ProfileRegistry.shared.register(data) }
            #expect(ProfileRegistry.shared.profile(ProfileDigest(of: data)) == nil)
        }
        let rawOnly = try LoadedProfile(data: Self.profile(outputReferred: false))
        #expect(throws: ProfileError.rawOnly) { try ProfileRegistry.shared.register(rawOnly) }
        #expect(ProfileRegistry.shared.profile(rawOnly.digest) == nil)
    }

    @Test func usabilityNamesTheErrorThatRejectsIt() {
        #expect(ProfileUsability.usable.error == nil)
        #expect(ProfileUsability.rawOnly.error == .rawOnly)
        #expect(ProfileUsability.cameraSpecific("Nikon Z 8").error == .cameraSpecific("Nikon Z 8"))
        #expect(ProfileUsability.unsupported("why").error == .unsupported("why"))
    }

    @Test func concurrentRegistrationKeepsOneInstance() async throws {
        let data = Self.profile()
        let tasks = (0 ..< 8).map { _ in Task.detached { try ProfileRegistry.shared.register(data) } }
        var instances: [LoadedProfile] = []
        for task in tasks { instances.append(try await task.value) }
        let first = try #require(instances.first)
        #expect(instances.allSatisfy { $0 === first })
        #expect(ProfileRegistry.shared.profile(first.digest) === first)
    }
}
