import AppKit
import CoreGraphics
import Foundation
import MCP
import Testing
@testable import Compositor

/// The Profile adjustment kind: its settings, rendering through `ProfileRenderer`, `addProfileAdjustment` as one undo
/// step, export, the Photoshop writer's lossy rasterizing, and the generic MCP adjustment tools on a Profile layer.
@MainActor struct ProfileAdjustmentTests {
    // MARK: Helpers

    /// A digest no registered profile has.
    static func unregisteredDigest() -> ProfileDigest {
        ProfileDigest(of: Data("unregistered \(UUID().uuidString)".utf8))
    }

    static func registered(_ fixture: String) throws -> LoadedProfile {
        try ProfileRegistry.shared.register(ProfileFixtureFiles.data(fixture))
    }

    /// An opaque gradient: red across, green down, blue along the diagonal.
    static func gradient(width: Int, height: Int) throws -> CGImage {
        var rgb: [UInt8] = []
        for y in 0 ..< height {
            for x in 0 ..< width {
                rgb += [UInt8(x * 255 / max(width - 1, 1)), UInt8(y * 255 / max(height - 1, 1)), UInt8((x + y) * 37 % 256)]
            }
        }
        return try ProfileFixtureFiles.image(width: width, height: height, rgb: rgb)
    }

    /// A session with one opaque gradient pixel layer filling a `size`×`size` document.
    static func session(size: Int) throws -> (session: EditorSession, base: CGImage) {
        let base = try gradient(width: size, height: size)
        let session = EditorSession()
        session.createDocument(width: size, height: size)
        session.insert(ImportedImage(image: base, thumbnail: base, name: "Base"))
        return (session, base)
    }

    // MARK: Model

    @Test func kindBasics() {
        #expect(AdjustmentKind.allCases.last == .profile)
        #expect(AdjustmentKind.profile.rawValue == "Profile")
        #expect(AdjustmentKind.profile.symbol == "camera.filters")
        #expect(AdjustmentKind.profile.filterKind == nil)
        #expect(AdjustmentKind.profile.isEditable)
    }

    @Test func settingsValidation() throws {
        let digest = Self.unregisteredDigest()
        func settings(name: String = "Look", uuid: String? = nil, group: String? = nil) -> ProfileAdjustmentSettings {
            ProfileAdjustmentSettings(reference: ProfileReference(digest: digest, uuid: uuid, name: name, group: group))
        }
        #expect(ProfileAdjustmentSettings.amountRange == 0...200)
        for amount in [0, 100, 200] { #expect(ProfileAdjustmentSettings(amount: amount).isValid, "\(amount)") }
        for amount in [-1, 201] { #expect(!ProfileAdjustmentSettings(amount: amount).isValid, "\(amount)") }
        #expect(ProfileAdjustmentSettings().reference == nil && ProfileAdjustmentSettings().amount == 100)

        #expect(!settings(name: "").isValid)
        #expect(!settings(name: "  ").isValid)
        #expect(!settings(uuid: "XYZ").isValid)
        #expect(!settings(name: String(repeating: "a", count: 1025)).isValid)
        #expect(settings(name: String(repeating: "a", count: 1024)).isValid)
        #expect(!settings(group: String(repeating: "g", count: 1025)).isValid)
        #expect(settings(uuid: nil).isValid)
        #expect(settings(uuid: "0123456789abcdef0123456789ABCDEF").isValid)

        var invalid = LayerAdjustment(kind: .profile)
        #expect(invalid.isValid && invalid.profileSettings == nil && invalid.profile == ProfileAdjustmentSettings())
        invalid.profile.amount = 201
        #expect(!invalid.isValid)

        let levels = String(decoding: try JSONEncoder().encode(LayerAdjustment(kind: .levels)), as: UTF8.self)
        #expect(!levels.contains("profileSettings"))
        var layer = LayerAdjustment(kind: .profile)
        layer.profile = ProfileAdjustmentSettings(
            reference: ProfileReference(digest: digest, uuid: "0123456789ABCDEF0123456789ABCDEF", name: "Look", group: "G"),
            amount: 140)
        #expect(try JSONDecoder().decode(LayerAdjustment.self, from: JSONEncoder().encode(layer)) == layer)
    }

    /// Every profile that can be listed can be referenced: a name or group past 1024 bytes is shortened for display
    /// (the digest names the profile), so choosing it doesn't silently leave the layer at None.
    @Test func everyUsableProfileMakesAValidReference() throws {
        let long = String(repeating: "é", count: 700)
        let loaded = try LoadedProfile(data: ProfileFixture.xmp(name: "  \(long)  ", uuid: Self.uniqueUUID(),
                                                                 group: String(repeating: "g", count: 2000),
                                                                 rgb: ProfileFixture.rgbTable(divisions: 3)))
        #expect(loaded.profile.usability == .usable)
        let reference = ProfileReference(loaded)
        #expect(reference.isValid)
        #expect(reference.name.utf8.count <= 1024 && long.hasPrefix(reference.name) && !reference.name.isEmpty)
        #expect(reference.group?.utf8.count == 1024)
        let (session, _) = try Self.session(size: 8)
        #expect(session.addProfileAdjustment(loaded) != nil)
    }

    /// A Name that is only whitespace isn't a name: the file is malformed, as one without a Name is.
    @Test func aBlankProfileNameIsMalformed() {
        #expect(throws: ProfileError.malformed("Name")) {
            _ = try LoadedProfile(data: ProfileFixture.xmp(name: " \n\t ", uuid: Self.uniqueUUID(),
                                                           rgb: ProfileFixture.rgbTable(divisions: 3)))
        }
    }

    @Test func referenceTakesItsDetailsFromTheProfile() throws {
        let warm = try Self.registered("profile-warm-adobe.xmp")
        let reference = ProfileReference(warm)
        #expect(reference == ProfileReference(digest: warm.digest, uuid: "00000000000000000000000000000002",
                                              name: "Warm AdobeRGB", group: "Synthetic"))
        #expect(reference.isValid)
    }

    // MARK: Rendering

    /// The canvas never waits for a profile table: a Profile layer drawn over more than a megapixel with no table
    /// baked (as when an agent has just added it) is evaluated directly on the main thread, and its table is baked on
    /// another thread for the draws after it.
    @Test func canvasNeverBakesAProfileTableWhileDrawing() async throws {
        let (session, _) = try Self.session(size: 1100)
        let loaded = try ProfileRegistry.shared.register(LoadedProfile(data: ProfileFixture.xmp(
            name: "Canvas Draw", uuid: Self.uniqueUUID(), group: "Canvas",
            rgb: ProfileFixture.rgbTable(divisions: 5) { r, g, b in (min(1, r * 1.1), g, b * 0.9) })))
        try #require(session.addProfileAdjustment(loaded, amount: 70) != nil)
        let key = ProfileLUTCache.key(for: loaded, percent: 70, options: .standard)
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1300, height: 1300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        session.viewport.resize(to: view.bounds.size, backingScale: 1, documentSize: CGSize(width: 1100, height: 1100))
        view.synchronizeDisplay()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        #expect(ProfileLUTCache.mainThreadBakeCount(for: key) == 0)
        let deadline = Date().addingTimeInterval(20)
        while ProfileLUTCache.bakeCount(for: key) == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(ProfileLUTCache.bakeCount(for: key) == 1)
        #expect(ProfileLUTCache.mainThreadBakeCount(for: key) == 0)
    }

    @Test func applyPassesThroughOrRenders() throws {
        let image = try Self.gradient(width: 16, height: 16)
        #expect(try ProfileAdjustmentSettings().apply(image) === image)

        let missing = ProfileAdjustmentSettings(
            reference: ProfileReference(digest: Self.unregisteredDigest(), uuid: nil, name: "X", group: nil))
        #expect(throws: ProfileError.notLoaded(name: "X")) { try missing.apply(image) }

        let warm = try Self.registered("profile-warm-adobe.xmp")
        let settings = ProfileAdjustmentSettings(reference: ProfileReference(warm), amount: 150)
        let expected = try ProfileFixtureFiles.rgb(of: ProfileRenderer.apply(image, profile: warm, percent: 150))
        #expect(expected != (try ProfileFixtureFiles.rgb(of: image)), "The fixture changes the gradient")
        #expect(try ProfileFixtureFiles.rgb(of: settings.apply(image)) == expected)

        var adjustment = LayerAdjustment(kind: .profile)
        adjustment.profile = settings
        #expect(try ProfileFixtureFiles.rgb(of: adjustment.apply(image)) == expected)
    }

    @Test func exportMatchesDirectRendering() async throws {
        let (session, base) = try Self.session(size: 32)
        let warm = try Self.registered("profile-warm-adobe.xmp")
        let id = try #require(session.addProfileAdjustment(warm))

        let exported = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let direct = try ProfileRenderer.apply(base, profile: warm, percent: 100)
        #expect(try ProfileFixtureFiles.rgb(of: exported) == ProfileFixtureFiles.rgb(of: direct))

        session.toggleLayerVisibility(id)
        let hidden = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        #expect(try ProfileFixtureFiles.rgb(of: hidden) == ProfileFixtureFiles.rgb(of: base))
    }

    // MARK: Adding

    @Test func addProfileAdjustmentIsOneUndoStep() throws {
        let (session, _) = try Self.session(size: 4)
        let warm = try Self.registered("profile-warm-adobe.xmp")
        let layers = try #require(session.document?.layers.count)

        let id = try #require(session.addProfileAdjustment(warm, amount: 140))
        let layer = try #require(session.activeLayer)
        #expect(layer.id == id)
        #expect(layer.name == "Warm AdobeRGB")
        #expect(layer.adjustment?.kind == .profile)
        #expect(layer.adjustment?.profile.amount == 140)
        #expect(layer.adjustment?.profile.reference?.digest == warm.digest)
        #expect(session.adjustmentEditingID == nil)
        #expect(session.history.undoName == "New Profile Adjustment")

        session.undo()
        #expect(session.document?.layers.count == layers)
        #expect(session.document?.layers.contains { $0.id == id } == false)
        session.redo()
        #expect(session.document?.layers.first { $0.id == id }?.adjustment == layer.adjustment)

        let noAmount = try ProfileFixtureFiles.loaded("profile-no-amount.xmp")
        let fixed = try #require(session.addProfileAdjustment(noAmount, amount: 30))
        #expect(session.document?.layers.first { $0.id == fixed }?.adjustment?.profile.amount == 100)
        #expect(ProfileRegistry.shared.profile(noAmount.digest) != nil, "Adding registers the profile")

        let clamped = try #require(session.addProfileAdjustment(warm, amount: 900, name: "Strong"))
        let strong = try #require(session.document?.layers.first { $0.id == clamped })
        #expect(strong.name == "Strong" && strong.adjustment?.profile.amount == 200)

        let count = try #require(session.document?.layers.count)
        let rawOnly = try LoadedProfile(data: ProfileFixture.xmp(name: "Raw Only", uuid: Self.uniqueUUID(),
                                                                 outputReferred: false,
                                                                 rgb: ProfileFixture.rgbTable(divisions: 3)))
        #expect(session.addProfileAdjustment(rawOnly) == nil)
        #expect(session.document?.layers.count == count)
        #expect(ProfileRegistry.shared.profile(rawOnly.digest) == nil)
    }

    @Test func addAdjustmentMakesANoneLayerAndOpensItsBrowser() throws {
        let (session, base) = try Self.session(size: 4)
        session.addAdjustment(.profile)
        let layer = try #require(session.activeLayer)
        #expect(layer.name == "Profile")
        #expect(layer.adjustment?.kind == .profile)
        #expect(layer.adjustment?.profile.reference == nil)
        #expect(session.adjustmentEditingID == layer.id)
        // None passes its input through.
        #expect(try layer.adjustment?.apply(base) === base)
    }

    /// Photoshop has no Profile layer: a Photoshop save refuses one unless lossy output is allowed, and then writes it
    /// as the other kinds Photoshop lacks, a pixel layer of what Compositor draws for it, with a lossy warning.
    @Test func photoshopSaveRasterizesAProfileLayerOnlyWhenLossyIsAllowed() throws {
        let (session, base) = try Self.session(size: 4)
        let warm = try Self.registered("profile-warm-adobe.xmp")
        let id = try #require(session.addProfileAdjustment(warm))
        let request = try #require(session.psdWriteRequest())
        #expect(throws: PSDWriteError.unsupportedAdjustment(layerName: "Warm AdobeRGB", kind: .profile)) {
            try PSDWriter.data(for: request)
        }

        let written = try PSDWriter.data(for: request, options: PSDWriteOptions(allowLossy: true))
        #expect(written.report.warnings == [PSDWriteWarning(layerName: "Warm AdobeRGB",
            message: "Photoshop has no Profile adjustment, so it was saved as “Warm AdobeRGB (rasterized)”, a pixel layer of its result on the layers below.",
            lossy: true)])
        let plan = try PSDLayerRecordWriter.plan(request, options: PSDWriteOptions(allowLossy: true))
        #expect(plan.records.map(\.name) == ["Base", "Warm AdobeRGB (rasterized)"])
        let record = try #require(plan.records.last)
        #expect(record.sourceID == id && record.flags & 0x10 == 0)
        let direct = try ProfileRenderer.apply(base, profile: warm, percent: 100)
        #expect(try ProfileFixtureFiles.rgb(of: try #require(record.image)) == ProfileFixtureFiles.rgb(of: direct))
        let reopened = try PSDDocumentBuilder.makeImport(try PSDReader.read(written.data))
        let layer = try #require(reopened.layers.last)
        #expect(layer.name == "Warm AdobeRGB (rasterized)" && layer.adjustment == nil && layer.asset != nil)
    }

    static func uniqueUUID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") }

    // MARK: MCP

    private func field(_ result: [String: Value]) -> String? {
        result["error"]?.objectValue?["details"]?.objectValue?["field"]?.stringValue
    }

    private func adjustment(_ session: EditorSession, _ id: UUID) -> LayerAdjustment? {
        session.document?.layers.first { $0.id == id }?.adjustment
    }

    @Test func mcpAddsAndSetsProfileLayers() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let session = workspace.current.session
        let added = try await MCPTestSupport.call("add_adjustment_layer", ["kind": "profile"], in: workspace)
        #expect(added["kind"]?.stringValue == "profile")
        let shown = try #require(added["settings"]?.objectValue?["profile_settings"]?.objectValue)
        #expect(MCPValues.number(shown["amount"]) == 100)
        #expect(shown["reference"] == nil)
        let id = try #require(added["layer_id"]?.stringValue.flatMap(UUID.init(uuidString:)))

        let before = session.history.undoCount
        let set = try await MCPTestSupport.call("set_adjustment", ["layer": .string(id.uuidString), "settings": ["amount": 140]],
                                                in: workspace)
        #expect(session.history.undoCount == before + 1)
        #expect(set["undo"]?.objectValue?["recorded"]?.boolValue == true)
        #expect(adjustment(session, id)?.profile.amount == 140)
        #expect(MCPValues.number(set["settings"]?.objectValue?["profile_settings"]?.objectValue?["amount"]) == 140)
        try await MCPTestSupport.call("undo", in: workspace)
        #expect(adjustment(session, id)?.profile.amount == 100)
        try await MCPTestSupport.call("redo", in: workspace)

        try await MCPTestSupport.call("set_adjustment", ["layer": .string(id.uuidString), "settings": ["amount": 250]],
                                      in: workspace, expectError: "invalid_argument")
        #expect(adjustment(session, id)?.profile.amount == 140)

        let unknown = Self.unregisteredDigest().hex
        let missing = try await MCPTestSupport.call(
            "set_adjustment",
            ["layer": .string(id.uuidString),
             "settings": ["profile_settings": ["reference": ["digest": .string(unknown), "name": "X"]]]],
            in: workspace, expectError: "not_found")
        #expect(field(missing) == "profile_settings.reference")
        #expect(adjustment(session, id)?.profile.reference == nil)

        // A registered digest is accepted through the generic settings.
        let warm = try Self.registered("profile-warm-adobe.xmp")
        try await MCPTestSupport.call(
            "set_adjustment",
            ["layer": .string(id.uuidString),
             "settings": ["profile_settings": ["reference": ["digest": .string(warm.digest.hex), "name": "Warm AdobeRGB"]]]],
            in: workspace)
        #expect(adjustment(session, id)?.profile.reference?.digest == warm.digest)
        #expect(adjustment(session, id)?.profile.amount == 140)
    }

    @Test func mcpKeepsAProfileWithoutAmountAt100() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let session = workspace.current.session
        let noAmount = try ProfileFixtureFiles.loaded("profile-no-amount.xmp")
        let id = try #require(session.addProfileAdjustment(noAmount))
        let result = try await MCPTestSupport.call("set_adjustment", ["layer": .string(id.uuidString), "settings": ["amount": 150]],
                                                   in: workspace, expectError: "invalid_argument")
        #expect(field(result) == "amount")
        #expect(result["error"]?.objectValue?["message"]?.stringValue == "“No Amount” has no Amount; its amount stays 100.")
        #expect(adjustment(session, id)?.profile.amount == 100)
        try await MCPTestSupport.call("set_adjustment", ["layer": .string(id.uuidString), "settings": ["amount": 100]],
                                      in: workspace)
    }
}
