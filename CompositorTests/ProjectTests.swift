import AppKit
import UniformTypeIdentifiers
import Testing
@testable import Compositor

@MainActor
struct ProjectTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorProjectTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Saving writes `ProjectManifest.current` and `load` rejects anything outside
    /// `ProjectManifest.supported`, so the two have to agree or the app cannot reopen its own
    /// documents. This checks that directly, without touching the disk.
    @Test func theCurrentFormatVersionIsOneTheReaderAccepts() {
        #expect(ProjectManifest.supported.contains(ProjectManifest.current))
    }

    @Test func projectRoundTripSurvivesSourceRemovalAndPackageMove() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try ImageImportTests().fixture(.png)
        let session = EditorSession()
        await session.importImages([source])
        try FileManager.default.removeItem(at: source)
        session.beginTransform()
        var transform = try #require(session.transformEdit?.draft)
        transform.origin = CGPoint(x: -27.5, y: 88.25)
        transform.size = CGSize(width: 123, height: 47)
        transform.rotation = 38
        transform.flipX = true
        transform.flipY = true
        transform.sampling = .nearest
        session.previewTransform(transform)
        session.commitTransform()
        let imageID = try #require(session.activeLayerID)
        session.renameLayer(imageID, to: "Paint & sky 🌤")
        session.toggleLayerVisibility(imageID)
        session.addBlankLayer()
        let before = try #require(session.projectSnapshot())
        let original = root.appendingPathComponent("Original.comp")
        let moved = root.appendingPathComponent("Moved.comp")
        try await ProjectStore.shared.save(before, to: original)
        try FileManager.default.moveItem(at: original, to: moved)
        let loaded = try await ProjectStore.shared.load(from: moved)
        let reopened = EditorSession()
        reopened.installProject(loaded, from: moved)
        // Reloading creates new CGImage identities; compare persisted metadata here,
        // and decoded source pixels below, instead of in-memory snapshot identity.
        #expect(reopened.document?.id == session.document?.id)
        #expect(reopened.document?.size == session.document?.size)
        #expect(reopened.document?.resolution == session.document?.resolution)
        #expect(reopened.document?.layers.map(\.id) == session.document?.layers.map(\.id))
        #expect(reopened.document?.layers.map(\.name) == session.document?.layers.map(\.name))
        #expect(reopened.document?.layers.map(\.isVisible) == session.document?.layers.map(\.isVisible))
        #expect(reopened.document?.layers.map(\.transform) == session.document?.layers.map(\.transform))
        #expect(reopened.activeLayerID == session.activeLayerID)
        #expect(reopened.document?.layers.last?.asset == nil)
        #expect(!reopened.isModified)
        #expect(!reopened.canUndo)
        let image = try #require(loaded.images[imageID]?.image)
        #expect(image.width == 64 && image.height == 32)
        let bitmap = NSBitmapImageRep(cgImage: image)
        #expect(try #require(bitmap.colorAt(x: 0, y: 0)).redComponent > 0.95)
        #expect(try #require(bitmap.colorAt(x: 63, y: 0)).alphaComponent == 0)
        reopened.renameLayer(imageID, to: "Edited")
        #expect(reopened.isModified)
        reopened.undo()
        #expect(!reopened.isModified)
    }

    /// Folders took an opacity of their own in 1.1.6, but project validation still demanded that
    /// every folder be fully opaque, so a document with a dimmed folder could not be saved at all.
    @Test func aDimmedFolderSavesAndReopens() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        await session.importImages([try ImageImportTests().fixture(.png)])
        let child = try #require(session.activeLayerID)
        session.selectLayers([child], primary: child)
        session.addGroup()
        let folder = try #require(session.activeLayerID)
        session.selectLayers([folder], primary: folder)
        session.setLayerOpacity(0.5)
        #expect(session.document?.layers.first { $0.id == folder }?.opacity == 0.5)

        let url = root.appendingPathComponent("Dimmed.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let saved = try #require(loaded.manifest.layers.first { $0.isGroup == true })
        #expect(saved.opacity == 0.5)
    }

    @Test func overwriteReplacesPackageAndDropsRemovedAssets() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        await session.importImages([source])
        let destination = root.appendingPathComponent("Overwrite.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: destination)
        session.deleteActiveLayer()
        session.addBlankLayer()
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: destination)
        let loaded = try await ProjectStore.shared.load(from: destination)
        #expect(loaded.images.isEmpty)
        #expect(loaded.manifest.layers.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.appendingPathComponent("images").path).isEmpty)
    }

    @Test func failedSavePreservesPreviouslySavedPackage() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        session.createDocument(width: 100, height: 80)
        session.addBlankLayer()
        let snapshot = try #require(session.projectSnapshot())
        let url = root.appendingPathComponent("Safe.comp")
        try await ProjectStore.shared.save(snapshot, to: url)
        let original = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        var invalid = snapshot.manifest
        invalid.version = 99
        do {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: invalid, images: [:]), to: url)
            Issue.record("Unsupported version was saved")
        } catch {}
        #expect(try Data(contentsOf: url.appendingPathComponent("manifest.json")) == original)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.layers.count == 1)
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: blocker)
        do {
            try await ProjectStore.shared.save(snapshot, to: blocker.appendingPathComponent("CannotSave.comp"))
            Issue.record("Writing through a regular file unexpectedly succeeded")
        } catch {}
        #expect(try Data(contentsOf: url.appendingPathComponent("manifest.json")) == original)
    }

    @Test func unsupportedCorruptAndUnsafeMetadataAreRejected() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        session.createDocument(width: 100, height: 80)
        session.addBlankLayer()
        let snapshot = try #require(session.projectSnapshot())
        let url = root.appendingPathComponent("Invalid.comp")
        try await ProjectStore.shared.save(snapshot, to: url)
        let metadata = url.appendingPathComponent("manifest.json")
        var future = snapshot.manifest
        future.version = 42
        try JSONEncoder().encode(future).write(to: metadata)
        do {
            _ = try await ProjectStore.shared.load(from: url)
            Issue.record("Future version opened")
        } catch ProjectError.version(let version) { #expect(version == 42) }
        let record = try #require(snapshot.manifest.layers.first)
        var unsafe = snapshot.manifest
        unsafe.layers = [ProjectLayerRecord(id: record.id, name: record.name, isVisible: true,
            transform: record.transform, imageFile: "../../outside.png")]
        try JSONEncoder().encode(unsafe).write(to: metadata)
        do { _ = try await ProjectStore.shared.load(from: url); Issue.record("Path traversal accepted") }
        catch {}
        try Data("not json".utf8).write(to: metadata)
        do { _ = try await ProjectStore.shared.load(from: url); Issue.record("Corrupt metadata accepted") }
        catch {}
        #expect(session.document?.layers.count == 1)
    }

    @Test func missingEmbeddedImageIsRejected() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        await session.importImages([source])
        let snapshot = try #require(session.projectSnapshot())
        let url = root.appendingPathComponent("Missing.comp")
        try await ProjectStore.shared.save(snapshot, to: url)
        let filename = try #require(snapshot.manifest.layers.first?.imageFile)
        try FileManager.default.removeItem(at: url.appendingPathComponent("images").appendingPathComponent(filename))
        do { _ = try await ProjectStore.shared.load(from: url); Issue.record("Missing image accepted") }
        catch {}
    }

    @Test func projectOperationsBlockEditsAndQueueImageImports() async throws {
        let source = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        session.createDocument(width: 100, height: 100)
        session.addBlankLayer()
        let before = session.document
        session.isProjectBusy = true
        session.deleteActiveLayer()
        session.createDocument(width: 400, height: 400)
        session.undo()
        #expect(session.document == before)
        let pending = Task { await session.importImages([source]) }
        await Task.yield()
        #expect(!session.isImporting)
        session.isProjectBusy = false
        await pending.value
        #expect(session.document?.layers.count == 2)
        session.clearProject()
        #expect(session.document == nil && session.projectURL == nil)
        #expect(!session.isModified && !session.canUndo)
    }

    @Test func projectRoundTripPreservesAllLayerEffects() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        await session.importImages([source])
        let id = try #require(session.activeLayerID)

        var effects = LayerEffects()
        effects.stroke = StrokeEffect(size: 8, red: 0.1, green: 0.8, blue: 0.2, opacity: 0.9, inside: false)
        effects.shadow = ShadowEffect(angle: 45, distance: 15, blur: 10, red: 0.2, green: 0.2, blue: 0.3, opacity: 0.75)
        effects.colorOverlay = ColorOverlayEffect(red: 0.9, green: 0.1, blue: 0.4, opacity: 0.65)
        effects.innerShadow = InnerShadowEffect(angle: 135, distance: 6, blur: 4, red: 0.05, green: 0.05, blue: 0.05, opacity: 0.5)
        session.setEffects(effects, on: id)

        #expect(session.activeLayer?.effects == effects)

        let snapshot = try #require(session.projectSnapshot())
        let record = try #require(snapshot.manifest.layers.first { $0.id == id })
        #expect(record.effects == effects)

        let fileURL = root.appendingPathComponent("EffectsProject.comp")
        try await ProjectStore.shared.save(snapshot, to: fileURL)

        let loaded = try await ProjectStore.shared.load(from: fileURL)
        let loadedRecord = try #require(loaded.manifest.layers.first { $0.id == id })
        #expect(loadedRecord.effects == effects)

        let reopened = EditorSession()
        reopened.installProject(loaded, from: fileURL)

        let restored = try #require(reopened.document?.layers.first { $0.id == id })
        #expect(restored.effects == effects)

        // Verify individual effect parameters survive round trip
        let stroke = try #require(restored.effects?.stroke)
        #expect(stroke.size == 8)
        #expect(!stroke.inside)
        #expect(stroke.opacity == 0.9)
        #expect(abs(stroke.red - 0.1) < 0.001 && abs(stroke.green - 0.8) < 0.001)

        let shadow = try #require(restored.effects?.shadow)
        #expect(shadow.angle == 45)
        #expect(shadow.distance == 15)
        #expect(shadow.blur == 10)
        #expect(shadow.opacity == 0.75)

        let colorOverlay = try #require(restored.effects?.colorOverlay)
        #expect(colorOverlay.opacity == 0.65)
        #expect(abs(colorOverlay.red - 0.9) < 0.001 && abs(colorOverlay.blue - 0.4) < 0.001)

        let innerShadow = try #require(restored.effects?.innerShadow)
        #expect(innerShadow.angle == 135)
        #expect(innerShadow.distance == 6)
        #expect(innerShadow.blur == 4)
        #expect(innerShadow.opacity == 0.5)
    }

    @Test func layerEffectsAreRenderedInExport() async throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8,
            bytesPerRow: 80, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let redImage = try #require(context.makeImage())

        let session = EditorSession()
        session.createDocument(width: 60, height: 60)
        session.insert(ImportedImage(image: redImage, thumbnail: redImage, name: "Square"))

        let id = try #require(session.activeLayerID)
        session.document?.layers[0].transform = LayerTransform(origin: CGPoint(x: 20, y: 20), size: CGSize(width: 20, height: 20))

        // Before adding effects, area outside the layer is transparent
        let unstyledSnapshot = try #require(session.projectSnapshot())
        let unstyledRaster = try await ImageExporter.shared.render(unstyledSnapshot)
        let unstyledBitmap = NSBitmapImageRep(cgImage: unstyledRaster.image)
        #expect(try #require(unstyledBitmap.colorAt(x: 15, y: 30)).alphaComponent == 0)
        #expect(try #require(unstyledBitmap.colorAt(x: 30, y: 30)).redComponent > 0.9)

        // Apply outside green stroke of width 6px
        var effects = LayerEffects()
        effects.stroke = StrokeEffect(size: 6, red: 0, green: 1, blue: 0, opacity: 1, inside: false)
        session.setEffects(effects, on: id)

        let styledSnapshot = try #require(session.projectSnapshot())
        #expect(styledSnapshot.manifest.layers.first?.effects != nil)

        let styledRaster = try await ImageExporter.shared.render(styledSnapshot)
        let styledBitmap = NSBitmapImageRep(cgImage: styledRaster.image)

        // Pixel at (15, 30) is 5px to the left of the layer (x=20..40), inside the 6px stroke
        let strokePixel = try #require(styledBitmap.colorAt(x: 15, y: 30))
        #expect(strokePixel.greenComponent > 0.9)
        #expect(strokePixel.alphaComponent > 0.9)

        // The layer itself at (30, 30) remains red
        let centerPixel = try #require(styledBitmap.colorAt(x: 30, y: 30))
        #expect(centerPixel.redComponent > 0.9)
    }

    @Test func projectSavedByThisBuildReopens() async throws {
        let session = EditorSession(); session.createNewProject(width: 8, height: 8)
        session.addAdjustment(.gaussianBlur)          // forces version 9 on save
        let snapshot = try #require(session.projectSnapshot())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)   // throws ProjectError.version(9) today
        #expect(loaded.manifest.version == ProjectManifest.current)
    }

    @Test func literalVersion9ManifestLoads() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        session.createDocument(width: 100, height: 80)
        session.addBlankLayer()
        let snapshot = try #require(session.projectSnapshot())
        let url = root.appendingPathComponent("LiteralV9.comp")
        try await ProjectStore.shared.save(snapshot, to: url)
        var manifest = snapshot.manifest
        manifest.version = 9
        try JSONEncoder().encode(manifest).write(to: url.appendingPathComponent("manifest.json"))
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.version == 9)
    }

    // MARK: Format 10: Photoshop data, locks and fill

    private func u32(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    /// A document with a Photoshop layer (two blocks, blending ranges, every record field, locks, fill 0.5) inside
    /// a folder whose section divider has blocks of its own, plus document resources, blocks and linked entries.
    private func photoshopSession() -> (session: EditorSession, layer: UUID, folder: UUID) {
        let folderID = UUID(), layerID = UUID()
        let size = LayerTransform(origin: .zero, size: CGSize(width: 8, height: 6))
        var text = LayerTextStyle()
        text.content = "Imported"
        let extras = PSDLayerExtras(
            blocks: [PSDTaggedBlock(key: "shmd", data: Data([0, 0, 0, 1, 9, 8, 7])),
                     PSDTaggedBlock(signature: "8B64", key: "zzzz", data: Data([1, 2, 3, 4]))],
            blendingRanges: Data((0..<40).map { UInt8($0) }), blendKey: "diss", flags: 0x18, clippingByte: 0,
            fillerByte: 7, maskFlags: 0x10, maskDefaultColor: 255, maskParameters: Data([0x01, 0xC8, 0, 0]),
            layerID: 42, colorLabel: .violet, nameSource: "layr", importedName: "Painted",
            importedText: text, importedTextAnchor: CGPoint(x: 0.25, y: 0.75), importedTextIsBox: true,
            importedEffects: LayerEffects(), importedVisible: false, placeholder: "adjustment:brit",
            trailingBytes: Data([0, 0, 0]))
        let divider = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "lsct", data: u32(3)), PSDTaggedBlock(key: "lyid", data: u32(11))],
                                     blendingRanges: Data(count: 8), layerID: 11, colorLabel: .blue, importedName: "</Layer group>")
        let folderExtras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "lsct", data: u32(2) + Data("8BIMnorm".utf8))],
                                          layerID: 10, sectionDividerExtras: divider)
        let session = EditorSession()
        var document = CanvasDocument(width: 8, height: 6, layers: [
            ImageLayer(id: layerID, asset: nil, name: "Painted", isVisible: true, transform: size, parentID: folderID,
                       locks: [.transparency, .position, .artboardNesting, .all], fillOpacity: 0.5, psdExtras: extras),
            ImageLayer(id: folderID, asset: nil, name: "Folder", isVisible: true, transform: size, isGroup: true,
                       locks: LayerLocks(rawValue: 0x4000_0000), psdExtras: folderExtras)
        ])
        document.psdExtras = PSDDocumentExtras(
            resources: [PSDImageResource(id: 1005, name: "", data: Data(count: 16)),
                        PSDImageResource(id: 4000, name: "Plug-in", data: Data([1, 2, 3])),
                        PSDImageResource(id: 2999, name: "", data: Data([7]), signature: "MeSa")],
            globalBlocks: [PSDTaggedBlock(key: "Patt", data: Data([1, 2, 3, 4, 5])), PSDTaggedBlock(key: "Txt2", data: Data("engine".utf8))],
            orphanLinkedEntries: [Data("liFD entry".utf8), Data([1, 2, 3])],
            globalLayerMaskInfo: Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x80, 0]), colorModeData: Data([5, 6]),
            channelCount: 4, alphaChannelNames: ["Alpha 1"], iccProfileDescription: "sRGB IEC61966-2.1",
            globalLightAngle: 120, globalLightAltitude: 30, sourceFileName: "Client.psd", layerCountNegative: true)
        session.document = document
        return (session, layerID, folderID)
    }

    private func savedPhotoshopProject(in root: URL) async throws -> (url: URL, session: EditorSession, layer: UUID, folder: UUID) {
        let (session, layer, folder) = photoshopSession()
        let url = root.appendingPathComponent("Photoshop.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        return (url, session, layer, folder)
    }

    /// Rewrites `manifest.json` through `edit` (on its JSON object).
    private func editManifest(_ url: URL, _ edit: (inout [String: Any]) throws -> Void) throws {
        let file = url.appendingPathComponent("manifest.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        try edit(&json)
        try JSONSerialization.data(withJSONObject: json).write(to: file)
    }

    private func editLayer(_ url: URL, _ id: UUID, _ edit: @escaping (inout [String: Any]) -> Void) throws {
        try editManifest(url) { json in
            var layers = try #require(json["layers"] as? [[String: Any]])
            let index = try #require(layers.firstIndex { $0["id"] as? String == id.uuidString })
            edit(&layers[index])
            json["layers"] = layers
        }
    }

    private func expectInvalid(_ url: URL, _ comment: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        do {
            _ = try await ProjectStore.shared.load(from: url)
            Issue.record("Accepted: \(comment)", sourceLocation: sourceLocation)
        } catch ProjectError.invalid {
        } catch {
            Issue.record("\(comment): expected ProjectError.invalid, got \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test func photoshopDataLocksAndFillRoundTrip() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let (url, session, layerID, folderID) = try await savedPhotoshopProject(in: root)
        let psd = url.appendingPathComponent("psd")
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: psd.path)) == [
            "\(layerID.uuidString).blocks", "\(folderID.uuidString).blocks", "\(folderID.uuidString).divider.blocks",
            "document.blocks", "document.resources", "document.linked"])
        // Sidecars are Photoshop's own wire format.
        let original = try #require(session.document)
        let blocks: [PSDTaggedBlock] = try PSDBlockFile.decodeBlocks(
            Data(contentsOf: psd.appendingPathComponent("\(layerID.uuidString).blocks")), limit: 1 << 20)
        #expect(blocks == original.layers[0].psdExtras?.blocks)
        let resources: [PSDImageResource] = try PSDBlockFile.decodeResources(
            Data(contentsOf: psd.appendingPathComponent("document.resources")), limit: 1 << 20)
        #expect(resources == original.psdExtras?.resources)

        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.version == ProjectManifest.current)
        let reopened = EditorSession()
        reopened.installProject(loaded, from: url)
        let document = try #require(reopened.document)
        #expect(document.psdExtras == original.psdExtras)
        #expect(document.layers.map(\.psdExtras) == original.layers.map(\.psdExtras))
        #expect(document.layers.map(\.locks) == original.layers.map(\.locks))
        #expect(document.layers.map(\.fillOpacity) == [0.5, 1])
        #expect(document.layers[1].psdExtras?.sectionDividerExtras?.blocks.count == 2)
        // Undo history carries everything too.
        reopened.renameLayer(layerID, to: "Renamed")
        reopened.undo()
        #expect(reopened.document == document)
        // The manifest holds the scalars; the divider is a nested record, not an array.
        let json = String(decoding: try Data(contentsOf: url.appendingPathComponent("manifest.json")), as: UTF8.self)
        #expect(json.contains("\"sectionDivider\" : {") && json.contains("\"fillOpacity\" : 0.5"))
        #expect(!json.contains("dividerStorage") && !json.contains("Patt"))
    }

    @Test func version9ManifestWithFormat10FieldsIsRejected() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        for field in ["locks", "fillOpacity", "psd", "document psd"] {
            let (url, _, layerID, _) = try await savedPhotoshopProject(in: root)
            defer { try? FileManager.default.removeItem(at: url) }
            try editManifest(url) { json in
                json["version"] = 9
                if field != "document psd" { json["psd"] = nil }
            }
            try editLayer(url, layerID) { layer in
                for key in ["locks", "fillOpacity", "psd"] where key != field { layer[key] = nil }
            }
            // The folder keeps its own fields unless we're testing them one at a time.
            try editManifest(url) { json in
                var layers = try #require(json["layers"] as? [[String: Any]])
                for i in layers.indices where layers[i]["id"] as? String != layerID.uuidString || field == "document psd" {
                    layers[i]["locks"] = nil; layers[i]["fillOpacity"] = nil; layers[i]["psd"] = nil
                }
                json["layers"] = layers
            }
            await expectInvalid(url, "version 9 with \(field)")
        }
        // Without them, version 9 still opens.
        let (url, _, _, _) = try await savedPhotoshopProject(in: root)
        try editManifest(url) { json in
            json["version"] = 9
            json["psd"] = nil
            var layers = try #require(json["layers"] as? [[String: Any]])
            for i in layers.indices { layers[i]["locks"] = nil; layers[i]["fillOpacity"] = nil; layers[i]["psd"] = nil }
            json["layers"] = layers
        }
        #expect(try await ProjectStore.shared.load(from: url).manifest.version == 9)
    }

    @Test func malformedPhotoshopSidecarsAreRejected() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        func fresh() async throws -> (url: URL, layer: UUID, folder: UUID) {
            let (url, _, layer, folder) = try await savedPhotoshopProject(in: root)
            return (url, layer, folder)
        }
        func sidecar(_ url: URL, _ name: String) -> URL { url.appendingPathComponent("psd").appendingPathComponent(name) }

        // A block whose length runs past the end of its sidecar.
        var (url, layer, folder) = try await fresh()
        var bad = try Data(contentsOf: sidecar(url, "\(layer.uuidString).blocks"))
        bad.replaceSubrange(8..<12, with: u32(1_000))
        try bad.write(to: sidecar(url, "\(layer.uuidString).blocks"))
        await expectInvalid(url, "a block with a bad length")

        // Trailing bytes, a missing sidecar, a truncated divider, bad resources and linked entries.
        // Layer sidecar names are filled in per fresh project (each has new layer IDs).
        for (pattern, change) in [("LAYER.blocks", "trailing"), ("FOLDER.divider.blocks", "missing"),
                                  ("FOLDER.divider.blocks", "truncated"), ("document.resources", "trailing"),
                                  ("document.blocks", "truncated"), ("document.linked", "truncated"), ("document.linked", "trailing")] {
            try FileManager.default.removeItem(at: url)
            (url, layer, folder) = try await fresh()
            let name = pattern.replacingOccurrences(of: "LAYER", with: layer.uuidString)
                .replacingOccurrences(of: "FOLDER", with: folder.uuidString)
            let file = sidecar(url, name)
            switch change {
            case "missing": try FileManager.default.removeItem(at: file)
            case "truncated": try Data(try Data(contentsOf: file).dropLast()).write(to: file)
            default: try (Data(contentsOf: file) + Data([0x38])).write(to: file)
            }
            await expectInvalid(url, "\(change) \(name)")
        }

        // File names other than `<layer UUID>.blocks` (path traversal, another layer's, the wrong extension).
        for name in ["../../outside.blocks", "\(folder.uuidString).blocks", "\(layer.uuidString).png", "/tmp/x.blocks"] {
            try FileManager.default.removeItem(at: url)
            (url, layer, folder) = try await fresh()
            try editLayer(url, layer) { record in
                var psd = record["psd"] as? [String: Any] ?? [:]
                psd["blocksFile"] = name
                record["psd"] = psd
            }
            await expectInvalid(url, "blocks file \(name)")
        }
        try FileManager.default.removeItem(at: url)
        (url, layer, folder) = try await fresh()
        try editManifest(url) { json in
            var psd = try #require(json["psd"] as? [String: Any])
            psd["resourcesFile"] = "../document.resources"
            json["psd"] = psd
        }
        await expectInvalid(url, "document resources file name")

        // Out-of-range values.
        let edits: [(String, (inout [String: Any]) -> Void)] = [
            ("fill above 1", { $0["fillOpacity"] = 1.5 }),
            ("negative fill", { $0["fillOpacity"] = -0.1 }),
            ("a five-character blend key", { var psd = $0["psd"] as? [String: Any] ?? [:]; psd["blendKey"] = "normal"; $0["psd"] = psd }),
            ("oversized blending ranges", { var psd = $0["psd"] as? [String: Any] ?? [:]
                psd["blendingRanges"] = Data(count: 5_000).base64EncodedString(); $0["psd"] = psd }),
            ("a divider inside a divider", { var psd = $0["psd"] as? [String: Any] ?? [:]
                psd["sectionDivider"] = ["blendKey": "norm", "sectionDivider": ["blendKey": "norm"]]; $0["psd"] = psd }),
            ("negative locks", { $0["locks"] = -1 })
        ]
        for (comment, edit) in edits {
            try FileManager.default.removeItem(at: url)
            (url, layer, folder) = try await fresh()
            try editLayer(url, layer, edit)
            await expectInvalid(url, comment)
        }
    }
}
