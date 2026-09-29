import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Profile layers in `.comp` packages: each profile embedded once, byte for byte, as `profiles/<digest>.xmp`, and
/// every referenced sidecar verified and registered before a project opens.
@MainActor struct ProfileProjectTests {
    // MARK: Helpers

    static func packageURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ProfileProjectTests-\(UUID().uuidString).comp")
    }

    static func sidecar(_ url: URL, _ digest: ProfileDigest) -> URL {
        url.appendingPathComponent("profiles").appendingPathComponent("\(digest.hex).xmp")
    }

    /// A unique, usable profile that has never been registered.
    static func freshProfile(_ name: String, outputReferred: Bool = true) -> Data {
        ProfileFixture.xmp(name: name, uuid: ProfileAdjustmentTests.uniqueUUID(), outputReferred: outputReferred,
                           rgb: ProfileFixture.rgbTable(divisions: 3) { r, g, b in (g, b, r) })
    }

    /// Saves a document with one warm Profile layer (amount 140) over a gradient, returning where and the profile.
    func savedWarmProject() async throws -> (url: URL, warm: LoadedProfile) {
        let warm = try ProfileAdjustmentTests.registered("profile-warm-adobe.xmp")
        let (session, _) = try ProfileAdjustmentTests.session(size: 8)
        try #require(session.addProfileAdjustment(warm, amount: 140) != nil)
        let url = Self.packageURL()
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        return (url, warm)
    }

    /// Rewrites `manifest.json` through `edit` on its text.
    func editManifestText(_ url: URL, _ edit: (String) -> String) throws {
        let file = url.appendingPathComponent("manifest.json")
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        let edited = edit(text)
        #expect(edited != text, "The edit changes the manifest")
        try Data(edited.utf8).write(to: file)
    }

    /// Rewrites the Profile layer's record in `manifest.json` through `edit`.
    func editProfileLayer(_ url: URL, _ edit: (inout [String: Any]) -> Void) throws {
        let file = url.appendingPathComponent("manifest.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var layers = try #require(json["layers"] as? [[String: Any]])
        let index = try #require(layers.firstIndex { ($0["adjustment"] as? [String: Any])?["kind"] as? String == "Profile" })
        edit(&layers[index])
        json["layers"] = layers
        try JSONSerialization.data(withJSONObject: json).write(to: file)
    }

    enum Rejection { case invalid, tooLarge, any }

    func expectLoad(_ url: URL, fails rejection: Rejection, _ comment: String,
                    sourceLocation: SourceLocation = #_sourceLocation) async {
        do {
            _ = try await ProjectStore.shared.load(from: url)
            Issue.record("Accepted: \(comment)", sourceLocation: sourceLocation)
        } catch ProjectError.invalid where rejection == .invalid || rejection == .any {
        } catch ProjectError.tooLarge where rejection == .tooLarge || rejection == .any {
        } catch {
            if rejection != .any {
                Issue.record("\(comment): expected ProjectError.\(rejection), got \(error)", sourceLocation: sourceLocation)
            }
        }
    }

    // MARK: Round trips

    @Test func roundTripEmbedsEachProfileOnce() async throws {
        let warm = try ProfileAdjustmentTests.registered("profile-warm-adobe.xmp")
        let bw = try ProfileAdjustmentTests.registered("profile-bw-curve.xmp")
        let (session, _) = try ProfileAdjustmentTests.session(size: 8)
        try #require(session.addProfileAdjustment(warm, amount: 60) != nil)
        try #require(session.addProfileAdjustment(bw) != nil)
        try #require(session.addProfileAdjustment(warm, amount: 150) != nil)
        let snapshot = try #require(session.projectSnapshot())
        let url = Self.packageURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(snapshot, to: url)

        let files = try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("profiles").path)
        #expect(files.sorted() == ["\(warm.digest.hex).xmp", "\(bw.digest.hex).xmp"].sorted())
        #expect(try Data(contentsOf: Self.sidecar(url, warm.digest)) == ProfileFixtureFiles.data("profile-warm-adobe.xmp"))
        #expect(try Data(contentsOf: Self.sidecar(url, bw.digest)) == ProfileFixtureFiles.data("profile-bw-curve.xmp"))
        let manifest = String(decoding: try Data(contentsOf: url.appendingPathComponent("manifest.json")), as: UTF8.self)
        #expect(manifest.contains("\"kind\" : \"Profile\""))
        #expect(manifest.contains("\"profileSettings\""))

        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.version == ProjectManifest.current)
        #expect(loaded.manifest.layers.map(\.adjustment) == snapshot.manifest.layers.map(\.adjustment))
        let before = try await ImageExporter.shared.render(snapshot).image
        let after = try await ImageExporter.shared.render(loaded).image
        #expect(try ProfileFixtureFiles.rgb(of: before) == ProfileFixtureFiles.rgb(of: after))

        // Saving the loaded project again writes the same sidecars.
        let again = Self.packageURL()
        defer { try? FileManager.default.removeItem(at: again) }
        try await ProjectStore.shared.save(loaded, to: again)
        #expect(try FileManager.default.contentsOfDirectory(atPath: again.appendingPathComponent("profiles").path).sorted()
                    == files.sorted())
    }

    @Test func loadRegistersSidecarsItHasNeverSeen() async throws {
        let (url, warm) = try await savedWarmProject()
        defer { try? FileManager.default.removeItem(at: url) }
        let q = Self.freshProfile("Q")
        let digest = ProfileDigest(of: q)
        #expect(ProfileRegistry.shared.profile(digest) == nil)
        try q.write(to: Self.sidecar(url, digest))
        try editManifestText(url) { $0.replacingOccurrences(of: warm.digest.hex, with: digest.hex) }

        let loaded = try await ProjectStore.shared.load(from: url)
        let registered = try #require(ProfileRegistry.shared.profile(digest))
        #expect(registered.data == q)
        #expect(loaded.manifest.layers.compactMap { $0.adjustment?.profileSettings?.reference?.digest } == [digest])
    }

    @Test func noneLayerWritesNoProfilesFolder() async throws {
        let (session, _) = try ProfileAdjustmentTests.session(size: 8)
        session.addAdjustment(.profile)
        let snapshot = try #require(session.projectSnapshot())
        let url = Self.packageURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(snapshot, to: url)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("profiles").path))
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.layers.map(\.adjustment) == snapshot.manifest.layers.map(\.adjustment))
        #expect(loaded.manifest.layers.last?.adjustment?.kind == .profile)
    }

    @Test func unreferencedSidecarsAreIgnored() async throws {
        let (url, _) = try await savedWarmProject()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a profile".utf8).write(to: url.appendingPathComponent("profiles/junk.xmp"))
        _ = try await ProjectStore.shared.load(from: url)
    }

    // MARK: Refusals

    @Test func invalidSidecarsRejectTheProject() async throws {
        let bwData = try ProfileFixtureFiles.data("profile-bw-curve.xmp")
        var cases: [(String, Rejection, (URL, LoadedProfile) throws -> Void)] = [
            ("sidecar deleted", .invalid, { url, warm in
                try FileManager.default.removeItem(at: Self.sidecar(url, warm.digest))
            }),
            ("sidecar holds another profile", .invalid, { url, warm in
                try bwData.write(to: Self.sidecar(url, warm.digest))
            }),
            ("sidecar is a raw-only profile", .invalid, { url, warm in
                let raw = Self.freshProfile("Raw", outputReferred: false)
                let digest = ProfileDigest(of: raw)
                try FileManager.default.removeItem(at: Self.sidecar(url, warm.digest))
                try raw.write(to: Self.sidecar(url, digest))
                try self.editManifestText(url) { $0.replacingOccurrences(of: warm.digest.hex, with: digest.hex) }
            }),
            ("sidecar over 4 MiB", .tooLarge, { url, warm in
                var padded = warm.data
                padded.append(Data(repeating: 0x20, count: AdobeProfileParser.maximumFileBytes + 1 - padded.count))
                let digest = ProfileDigest(of: padded)
                try padded.write(to: Self.sidecar(url, digest))
                try self.editManifestText(url) { $0.replacingOccurrences(of: warm.digest.hex, with: digest.hex) }
            }),
            ("manifest version 9", .invalid, { url, _ in
                try self.editManifestText(url) { $0.replacingOccurrences(of: "\"version\" : \(ProjectManifest.current)", with: "\"version\" : 9") }
            }),
            ("profileSettings on a Levels layer", .invalid, { url, _ in
                try self.editProfileLayer(url) { layer in
                    var adjustment = layer["adjustment"] as? [String: Any] ?? [:]
                    adjustment["kind"] = "Levels"
                    layer["adjustment"] = adjustment
                }
            }),
            ("amount 250", .invalid, { url, _ in
                try self.editProfileLayer(url) { layer in
                    var adjustment = layer["adjustment"] as? [String: Any] ?? [:]
                    var settings = adjustment["profileSettings"] as? [String: Any] ?? [:]
                    settings["amount"] = 250
                    adjustment["profileSettings"] = settings
                    layer["adjustment"] = adjustment
                }
            }),
            ("digest abc", .invalid, { url, warm in
                try self.editManifestText(url) { $0.replacingOccurrences(of: warm.digest.hex, with: "abc") }
            }),
        ]
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileProjectTests-\(UUID().uuidString).xmp")
        defer { try? FileManager.default.removeItem(at: outside) }
        cases.append(("sidecar is a symbolic link", .any, { url, warm in
            try warm.data.write(to: outside)
            try FileManager.default.removeItem(at: Self.sidecar(url, warm.digest))
            try FileManager.default.createSymbolicLink(at: Self.sidecar(url, warm.digest), withDestinationURL: outside)
        }))

        for (comment, rejection, edit) in cases {
            let (url, warm) = try await savedWarmProject()
            defer { try? FileManager.default.removeItem(at: url) }
            // Each package loads before it is damaged.
            _ = try await ProjectStore.shared.load(from: url)
            try edit(url, warm)
            await expectLoad(url, fails: rejection, comment)
        }
    }

    @Test func versionNineWithoutProfilesStillLoads() async throws {
        // The control for "manifest version 9" above: only the Profile layer makes that project invalid.
        let (session, _) = try ProfileAdjustmentTests.session(size: 8)
        let url = Self.packageURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        try editManifestText(url) { $0.replacingOccurrences(of: "\"version\" : \(ProjectManifest.current)", with: "\"version\" : 9") }
        #expect(try await ProjectStore.shared.load(from: url).manifest.version == 9)
    }

    @Test func tooManyProfilesAreTooLarge() async throws {
        let transform = LayerTransform(origin: .zero, size: CGSize(width: 8, height: 8))
        let layers = (0 ... ProjectStore.maximumProfileSidecars).map { index -> ProjectLayerRecord in
            var adjustment = LayerAdjustment(kind: .profile)
            adjustment.profile = ProfileAdjustmentSettings(reference: ProfileReference(
                digest: ProfileAdjustmentTests.unregisteredDigest(), uuid: nil, name: "P\(index)", group: nil))
            return ProjectLayerRecord(id: UUID(), name: "P\(index)", isVisible: true, transform: transform, imageFile: nil,
                                      adjustment: adjustment)
        }
        let manifest = ProjectManifest(documentID: UUID(), width: 8, height: 8, activeLayerID: nil, layers: layers)
        #expect(ProjectStore.referencedProfiles(manifest).count == ProjectStore.maximumProfileSidecars + 1)

        let url = Self.packageURL()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: manifest, images: [:]), to: url)
            Issue.record("Saved 257 profiles")
        } catch ProjectError.tooLarge {
        } catch {
            Issue.record("Saving expected ProjectError.tooLarge, got \(error)")
        }

        try FileManager.default.createDirectory(at: url.appendingPathComponent("images"), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url.appendingPathComponent("manifest.json"))
        await expectLoad(url, fails: .tooLarge, "257 profiles")
    }

    @Test func referencedProfilesAreDistinctAndSorted() throws {
        let warm = try ProfileAdjustmentTests.registered("profile-warm-adobe.xmp")
        let bw = try ProfileAdjustmentTests.registered("profile-bw-curve.xmp")
        func layer(_ reference: ProfileReference?) -> ProjectLayerRecord {
            var adjustment = LayerAdjustment(kind: .profile)
            adjustment.profile = ProfileAdjustmentSettings(reference: reference)
            return ProjectLayerRecord(id: UUID(), name: "P", isVisible: true,
                                      transform: LayerTransform(origin: .zero, size: CGSize(width: 1, height: 1)),
                                      imageFile: nil, adjustment: adjustment)
        }
        var first = ProfileReference(warm)
        first.name = "First"
        var second = ProfileReference(warm)
        second.name = "Second"
        let manifest = ProjectManifest(documentID: UUID(), width: 1, height: 1, activeLayerID: nil,
                                       layers: [layer(first), layer(nil), layer(ProfileReference(bw)), layer(second)])
        let expected = [first, ProfileReference(bw)].sorted { $0.digest < $1.digest }
        #expect(ProjectStore.referencedProfiles(manifest) == expected)
    }

    @Test func savingAnUnloadedProfileFails() async throws {
        let (session, _) = try ProfileAdjustmentTests.session(size: 8)
        session.addAdjustment(.profile)
        session.adjustmentEditingID = nil   // No browser: the layer is set directly.
        let id = try #require(session.activeLayerID)
        var adjustment = LayerAdjustment(kind: .profile)
        adjustment.profile = ProfileAdjustmentSettings(reference: ProfileReference(
            digest: ProfileAdjustmentTests.unregisteredDigest(), uuid: nil, name: "Ghost", group: nil))
        session.setAdjustment(id, value: adjustment)
        let url = Self.packageURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: ProfileError.notLoaded(name: "Ghost")) {
            try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
