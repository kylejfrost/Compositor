import CoreGraphics
import Foundation
import ImageIO
import MCP
import Testing
import UniformTypeIdentifiers
@testable import Compositor

/// Photoshop smart objects import with their contents (from the document's linked-layer entries) and their
/// placement, keep showing Photoshop's pixels, and save in a project as `smartobjects/` files.
@MainActor
@Suite(.serialized)
struct PSDSmartObjectTests {
    private let quad = [CGPoint(x: 18, y: 14), CGPoint(x: 46, y: 14), CGPoint(x: 46, y: 42), CGPoint(x: 18, y: 42)]

    private func raster(width: Int, height: Int, red: CGFloat = 0.2) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(red: red, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 2, y: 2, width: width - 4, height: height - 4))
        return try #require(context.makeImage())
    }

    private func png(width: Int = 10, height: Int = 8) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try raster(width: width, height: height, red: 1), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func entry(_ uuid: String, data: Data, fileName: String = "Logo.png") -> PSDFixture.LinkedEntry {
        PSDFixture.LinkedEntry(uuid: uuid, fileName: fileName, data: data, childID: "child-7", modTime: 12.5, lockState: 0)
    }

    /// A smart-object layer: pixels (the trimmed raster) at `bounds`, placed by `quad` and naming `uuid`.
    private func smartLayer(_ name: String, uuid: String, bounds: CGRect = CGRect(x: 20, y: 16, width: 24, height: 24),
                            placement: [CGPoint]? = nil) throws -> PSDRecord {
        var record = PSDRecord(id: UUID(), name: name)
        record.bounds = bounds
        record.image = try raster(width: Int(bounds.width), height: Int(bounds.height))
        record.extras = PSDLayerExtras(blocks: PSDFixture.smartObjectBlocks(uuid: uuid, size: CGSize(width: 10, height: 8),
                                                                           quad: placement ?? quad))
        return record
    }

    private func read(_ layers: [PSDRecord], globalBlocks: [PSDTaggedBlock]) throws -> PSDDocument {
        var document = PSDDocument(width: 64, height: 64, resolution: 72, layers: layers)
        document.extras = PSDDocumentExtras(globalBlocks: globalBlocks)
        return try PSDReader.read(try PSDFixture.data(document, composite: try raster(width: 64, height: 64)))
    }

    private func close(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 0.0001 && abs(a.y - b.y) < 0.0001 }
    private func close(_ a: PlacementQuad, _ b: [CGPoint]) -> Bool { zip(a.corners, b).allSatisfy(close) && b.count == 4 }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PSDSmartObjectTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func opened(_ imported: PSDImport) throws -> EditorSession {
        let session = EditorSession()
        try session.insertPhotoshop(imported, named: "Smart")
        return session
    }

    // MARK: Import

    @Test func anEntryNamedByTheLayerGivesItsContentsAndPlacement() throws {
        let contents = try png()
        let uuid = "5d1c0e5e-0000-4a3b-9c1d-1f2e3d4c5b6a"
        let document = try read([try smartLayer("Logo", uuid: uuid)],
                                globalBlocks: [PSDTaggedBlock(key: "Patt", data: Data([1, 2, 3, 4])),
                                               PSDFixture.linkedLayersBlock(entries: [entry(uuid, data: contents)])])
        #expect(document.extras?.globalBlocks.map(\.key) == ["Patt"])
        #expect(document.extras?.orphanLinkedEntries.isEmpty == true)
        let imported = try PSDDocumentBuilder.makeImport(document)
        let layer = try #require(imported.layers.first)
        let smartObject = try #require(layer.smartObject)
        let info = smartObject.info
        #expect(info.uniqueID == uuid && info.placedID == "8f2c1a55-placed")
        #expect(info.fileName == "Logo.png" && info.fileType == "png " && info.fileExtension == "png")
        #expect(info.naturalSize == CGSize(width: 10, height: 8) && info.resolution == 72)
        #expect(info.placedType == 2 && info.pageNumber == 1 && info.pageCount == 1 && info.antiAlias == 16 && info.crop == 1)
        #expect(info.isEmbedded && info.contentsRevision == 0 && info.nonAffineQuad == nil)
        let link = try #require(info.link)
        #expect(link.kind == "liFD" && link.version == 7 && link.creator == "\0\0\0\0")
        #expect(link.childID == "child-7" && link.modTime == 12.5 && link.lockState == 0 && link.openFileDescriptor == nil)
        #expect(smartObject.payload?.data == contents)
        #expect(smartObject.payload?.sha256 == SmartObjectPayload.digest(contents))
        #expect(smartObject.payload?.sha256.count == 64)
        // The quad isn't the raster: it's kept in unit coordinates of the layer's own pixels.
        #expect(layer.transform.origin == CGPoint(x: 20, y: 16) && layer.transform.size == CGSize(width: 24, height: 24))
        #expect(close(info.quad.topLeft, CGPoint(x: -2.0 / 24, y: -2.0 / 24)))
        #expect(close(info.quad.documentQuad(for: layer.transform), quad))
        // Photoshop's pixels and blocks stay; import remembers what it read.
        #expect(layer.asset != nil)
        #expect(layer.psdExtras?.blocks.map(\.key).contains("SoLd") == true)
        #expect(layer.psdExtras?.importedSmartObject == info)
        #expect(!imported.conversions.contains { $0.layerName == "Logo" })
        #expect(MCPValues.kind(of: layer) == "smart_object")
    }

    /// The reader names a layer a smart object by the same placement blocks it reads the smart object from.
    @Test func eachPlacementBlockMakesTheLayerASmartObject() throws {
        for key in PSDSmartObjects.placementKeys {
            var record = PSDRecord(id: UUID(), name: key)
            record.bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
            record.image = try raster(width: 4, height: 4)
            record.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: key, data: Data([0, 0, 0, 0]))])
            #expect(try read([record], globalBlocks: []).layers.first?.kind == .smartObject, "\(key)")
        }
    }

    @Test func aLayerWhoseEntryIsMissingKeepsItsSettingsWithoutContents() throws {
        let document = try read([try smartLayer("Linked", uuid: "no-such-entry")], globalBlocks: [])
        let imported = try PSDDocumentBuilder.makeImport(document)
        let layer = try #require(imported.layers.first)
        let smartObject = try #require(layer.smartObject)
        #expect(smartObject.payload == nil)
        #expect(!smartObject.info.isEmbedded && smartObject.info.fileType.isEmpty && smartObject.info.link == nil)
        #expect(smartObject.info.uniqueID == "no-such-entry")
        #expect(layer.asset != nil)
        #expect(imported.conversions.contains { $0.layerName == "Linked" && $0.message.contains("contents aren’t stored") })
    }

    @Test func entriesNoLayerNamesAreKeptWholeAsOrphans() throws {
        let used = entry("used", data: try png())
        let unused = entry("unused", data: Data("spare".utf8), fileName: "Spare.bin")
        var external = PSDFixture.LinkedEntry(kind: "liFE", uuid: "external", fileName: "Linked.png", data: Data([9, 8, 7]))
        external.externalFileSize = 3
        let document = try read([try smartLayer("Logo", uuid: "used")],
                                globalBlocks: [PSDFixture.linkedLayersBlock(entries: [used, unused]),
                                               PSDTaggedBlock(key: "Txt2", data: Data("engine".utf8)),
                                               PSDFixture.linkedLayersBlock(entries: [external], key: "lnkE")])
        let extras = try #require(document.extras)
        #expect(extras.globalBlocks.map(\.key) == ["Txt2"])
        #expect(extras.orphanLinkedEntries == [PSDFixture.linkedEntry(unused), PSDFixture.linkedEntry(external)])
        #expect(document.layers.first?.smartObject?.payload != nil)
        // A project keeps the orphans, as a `lnk2` payload.
        let imported = try PSDDocumentBuilder.makeImport(document)
        #expect(imported.extras?.orphanLinkedEntries == extras.orphanLinkedEntries)
    }

    /// A PSD save writes smart objects' contents back and keeps the entries no layer names (see
    /// PSDSmartObjectWriterTests for the bytes).
    @Test func aPhotoshopSaveWritesContentsAndKeepsOrphanEntries() throws {
        let contents = try png()
        let unused = entry("unused", data: Data("spare".utf8), fileName: "Spare.bin")
        var plain = PSDRecord(id: UUID(), name: "Plain")
        plain.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        plain.image = try raster(width: 8, height: 8)
        let document = try read([plain, try smartLayer("Logo", uuid: "used")],
                                globalBlocks: [PSDFixture.linkedLayersBlock(entries: [entry("used", data: contents), unused])])
        let session = try opened(try PSDDocumentBuilder.makeImport(document))
        let (data, report) = try PSDWriter.data(for: try #require(session.psdWriteRequest()))
        #expect(report.warnings.isEmpty)
        let saved = try PSDReader.read(data)
        #expect(saved.extras?.orphanLinkedEntries == [PSDFixture.linkedEntry(unused)])
        #expect(saved.layers.last?.extras?.block("SoLd") != nil)
        #expect(saved.layers.last?.smartObject?.payload?.data == contents)
    }

    @Test func duplicatesOfOneSmartObjectShareItsContents() throws {
        let document = try read([try smartLayer("One", uuid: "shared"), try smartLayer("Two", uuid: "shared")],
                                globalBlocks: [PSDFixture.linkedLayersBlock(entries: [entry("shared", data: try png())])])
        let imported = try PSDDocumentBuilder.makeImport(document)
        let payloads = imported.layers.map { $0.smartObject?.payload }
        #expect(payloads.count == 2 && payloads.allSatisfy { $0 != nil })
        #expect(payloads[0] === payloads[1])
    }

    @Test func linkedFileAndAliasEntriesParse() throws {
        var external = PSDFixture.LinkedEntry(kind: "liFE", uuid: "ext", fileName: "Linked.png", data: Data([1, 2, 3]))
        external.openFile = PSDDescriptor(classID: "null", items: [(key: "compInfo", value: .integer(1))])
        external.externalFileSize = 4_096
        external.childID = "child"
        external.modTime = 3.25
        external.lockState = 1
        let parsed = try PSDSmartObjects.parseEntry(PSDFixture.linkedEntry(external))
        #expect(parsed.uniqueID == "ext" && parsed.fileName == "Linked.png" && parsed.fileType == "png ")
        #expect(parsed.data == Data([1, 2, 3]))
        #expect(parsed.link.kind == "liFE" && parsed.link.externalFileSize == 4_096)
        #expect(parsed.link.openFileDescriptor == PSDDescriptorWriter.block(try #require(external.openFile)))
        #expect(parsed.link.externalDescriptor == PSDDescriptorWriter.block(external.external))
        #expect(parsed.link.timestamp == external.timestamp)
        #expect(parsed.link.childID == "child" && parsed.link.modTime == 3.25 && parsed.link.lockState == 1)

        let alias = try PSDSmartObjects.parseEntry(PSDFixture.linkedEntry(
            PSDFixture.LinkedEntry(kind: "liFA", uuid: "alias", fileName: "Alias.psd", fileType: "8BPS")))
        #expect(alias.data == nil && alias.link.kind == "liFA" && alias.fileType == "8BPS")

        // Version 2 linked files keep their data last, with no child ID, time or lock.
        var old = PSDFixture.LinkedEntry(kind: "liFE", version: 2, uuid: "old", fileName: "Old.png", data: Data([5, 6]))
        old.externalFileSize = 2
        let parsedOld = try PSDSmartObjects.parseEntry(PSDFixture.linkedEntry(old))
        #expect(parsedOld.data == Data([5, 6]) && parsedOld.link.timestamp == nil && parsedOld.link.childID == nil)

        #expect(throws: (any Error).self) { try PSDSmartObjects.parseEntry(Data("liFD".utf8)) }
    }

    @Test func unreadableSettingsImportAsPixelsWithANote() throws {
        var record = try smartLayer("Broken", uuid: "broken")
        record.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "SoLd", data: Data("soLD\0\0\0\u{4}garbage".utf8))])
        let broken = entry("broken", data: try png())
        let document = try read([record], globalBlocks: [PSDFixture.linkedLayersBlock(entries: [broken])])
        #expect(document.extras?.orphanLinkedEntries == [PSDFixture.linkedEntry(broken)])
        let imported = try PSDDocumentBuilder.makeImport(document)
        #expect(imported.layers.first?.smartObject == nil)
        #expect(imported.layers.first?.asset != nil)
        #expect(imported.conversions.contains { $0.layerName == "Broken" && $0.message.contains("couldn’t be read") })
    }

    // MARK: Placement follows the layer

    @Test func movingTheLayerMovesItsDocumentQuad() throws {
        let document = try read([try smartLayer("Logo", uuid: "u")], globalBlocks: [])
        var layer = try #require(try PSDDocumentBuilder.makeImport(document).layers.first)
        let info = try #require(layer.smartObject?.info)
        layer.transform.origin.x += 5
        layer.transform.origin.y += 7
        #expect(close(info.quad.documentQuad(for: layer.transform), quad.map { CGPoint(x: $0.x + 5, y: $0.y + 7) }))
        // Its layer scaled to twice the size about the origin, the quad scales with it. (Image Size itself redraws
        // the layer on a new grid: SmartObjectEditingTests.imageSizeCarriesTheQuadOfAFlippedOrTurnedSmartObject.)
        let scaled = LayerTransform(origin: CGPoint(x: 40, y: 32), size: CGSize(width: 48, height: 48))
        #expect(close(info.quad.documentQuad(for: scaled), quad.map { CGPoint(x: $0.x * 2, y: $0.y * 2) }))
        // Flipped, its corners mirror across the layer's middle.
        var flipped = LayerTransform(origin: CGPoint(x: 20, y: 16), size: CGSize(width: 24, height: 24))
        flipped.flipX = true
        #expect(close(info.quad.documentQuad(for: flipped).topLeft, CGPoint(x: 46, y: 14)))
        let placed = LayerTransform(origin: CGPoint(x: 20, y: 16), size: CGSize(width: 24, height: 24))
        #expect(close(PlacementQuad.rect(CGRect(x: 20, y: 16, width: 24, height: 24), in: placed), PlacementQuad.unitSquare.corners))
    }

    @Test func copiesShareContentsAndPixelEditsDropTheSmartObject() throws {
        let document = try read([try smartLayer("Logo", uuid: "u")],
                                globalBlocks: [PSDFixture.linkedLayersBlock(entries: [entry("u", data: try png())])])
        let layer = try #require(try PSDDocumentBuilder.makeImport(document).layers.first)
        let copy = layer.copy(as: UUID())
        #expect(copy.smartObject == layer.smartObject)
        #expect(copy.smartObject?.payload === layer.smartObject?.payload)
        let edited = layer.replacingPixels(layer.asset, transform: layer.transform, mask: nil)
        #expect(edited.smartObject == nil)
        #expect(edited.psdExtras?.importedSmartObject == layer.smartObject?.info)
    }

    /// Baking a clip into a clipped smart object's pixels (its base deleted with Bake, or the layer copied into another
    /// project) leaves pixels that no longer show its contents, so it becomes a plain layer, as any pixel edit makes it.
    @Test func bakingAClipIntoASmartObjectMakesItPlainPixels() async throws {
        var base = PSDRecord(id: UUID(), name: "Base")
        base.bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
        base.image = try raster(width: 32, height: 32)
        var logo = try smartLayer("Logo", uuid: "u")
        logo.clipping = true
        let imported = try PSDDocumentBuilder.makeImport(try read([base, logo],
            globalBlocks: [PSDFixture.linkedLayersBlock(entries: [entry("u", data: try png())])]))
        func layer(_ name: String, in session: EditorSession) throws -> ImageLayer {
            try #require(session.document?.layers.first { $0.name == name })
        }

        let session = try opened(imported)
        let clipped = try layer("Logo", in: session)
        let info = try #require(clipped.smartObject?.info)
        #expect(clipped.maskSourceID == (try layer("Base", in: session)).id)
        let snapshot = try #require(session.projectSnapshot())
        let baked = try #require(try LiveMaskBaker.bake(snapshot, target: clipped.id))
        session.finishDeletingLayer(try layer("Base", in: session).id, baked: [clipped.id: baked])
        let deleted = try layer("Logo", in: session)
        #expect(deleted.maskSourceID == nil && deleted.asset?.image === baked.image)
        #expect(deleted.smartObject == nil && deleted.psdExtras?.importedSmartObject == info)

        let workspace = ProjectWorkspace()
        let sourceSession = workspace.current.session
        try sourceSession.insertPhotoshop(imported, named: "Smart")
        let source = try layer("Logo", in: sourceSession)
        #expect(source.smartObject != nil && source.maskSourceID != nil)
        let target = workspace.addTab()
        target.session.createDocument(width: 64, height: 64)
        await workspace.copyLayer(source.id, into: target.id)
        let copied = try #require(target.session.document?.layers.last)
        #expect(copied.name == "Logo" && copied.maskSourceID == nil && copied.smartObject == nil)
        // The layer copied from stays a smart object.
        #expect(try layer("Logo", in: sourceSession).smartObject != nil)
    }

    @Test func historyCountsContentsOnceByIdentity() throws {
        let contents = Data(count: 40_000)
        let document = try read([try smartLayer("Logo", uuid: "u")],
                                globalBlocks: [PSDFixture.linkedLayersBlock(entries: [entry("u", data: contents)])])
        let layer = try #require(try PSDDocumentBuilder.makeImport(document).layers.first)
        let history = DocumentHistory()
        var canvas = CanvasDocument(width: 64, height: 64, layers: [layer])
        for name in ["Rasterize", "Rename"] {
            history.begin(name, document: canvas, selection: nil)
            canvas.layers[0].smartObject = nil
            canvas.layers[0].name = name
            history.end(document: canvas, selection: nil)
        }
        // Only history holds the contents, once, however many snapshots share them; the image is still live.
        #expect(history.retainedBytes(current: canvas) == 40_000)
        var live = canvas
        live.layers[0].smartObject = layer.smartObject
        #expect(history.retainedBytes(current: live) == 0)
    }

    @Test func getLayerReportsTheSmartObject() async throws {
        let document = try read([try smartLayer("Logo", uuid: "u")],
                                globalBlocks: [PSDFixture.linkedLayersBlock(entries: [entry("u", data: try png())])])
        let imported = try PSDDocumentBuilder.makeImport(document)
        let layer = try #require(imported.layers.first)
        let value = MCPValues.layerDetail(layer, in: CanvasDocument(width: 64, height: 64, layers: imported.layers), full: true)
        #expect(value.objectValue?["kind"]?.stringValue == "smart_object")
        let smart = try #require(value.objectValue?["smart_object"]?.objectValue)
        #expect(smart["file_name"]?.stringValue == "Logo.png")
        #expect(smart["file_type"]?.stringValue == "png")
        #expect(MCPValues.number(smart["natural_size"]?.objectValue?["width"]) == 10)
        #expect(MCPValues.number(smart["natural_size"]?.objectValue?["height"]) == 8)
        #expect(smart["embedded"]?.boolValue == true)
        #expect(smart["contents_revision"]?.intValue == 0)
        let corners = try #require(smart["quad"]?.arrayValue).compactMap(MCPValues.point(from:))
        #expect(corners.count == 4 && zip(corners, quad).allSatisfy(close))

        // The tools report it too: get_layer, and get_document in full.
        let workspace = MCPTestSupport.workspace(width: 64, height: 64)
        try workspace.current.session.insertPhotoshop(imported, named: "Placed")
        let described = try await MCPTestSupport.call("get_layer", ["layer": .string(layer.id.uuidString)], in: workspace)
        #expect(described["layer"]?.objectValue?["smart_object"]?.objectValue?["file_name"]?.stringValue == "Logo.png")
        let full = try await MCPTestSupport.call("get_document", ["detail": "full"], in: workspace)
        let roots = try #require(full["document"]?.objectValue?["layers"]?.arrayValue).compactMap(\.objectValue)
        let placed = try #require(roots.first { $0["name"]?.stringValue == "Placed" }?["children"]?.arrayValue?.first?.objectValue)
        #expect(placed["kind"]?.stringValue == "smart_object")
        #expect(placed["smart_object"]?.objectValue?["file_name"]?.stringValue == "Logo.png")
    }

    // MARK: Projects

    @Test func aProjectSavesContentsAsFilesAndReloadsThemIntact() async throws {
        let contents = try png()
        let document = try read([try smartLayer("One", uuid: "shared"), try smartLayer("Two", uuid: "shared")],
                                globalBlocks: [PSDFixture.linkedLayersBlock(entries: [entry("shared", data: contents),
                                                                                       entry("orphan", data: Data([1]))])])
        let session = try opened(try PSDDocumentBuilder.makeImport(document))
        let layers = try #require(session.document?.layers)
        let first = try #require(layers.first)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Smart.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        // One file for the shared contents, named after the first layer holding them.
        let folder = url.appendingPathComponent("smartobjects")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["\(first.id.uuidString).png"])
        #expect(try Data(contentsOf: folder.appendingPathComponent("\(first.id.uuidString).png")) == contents)
        let manifest = try String(contentsOf: url.appendingPathComponent("manifest.json"), encoding: .utf8)
        #expect(manifest.contains("\"smartObjectFile\"") && manifest.contains(SmartObjectPayload.digest(contents)))
        #expect(manifest.contains("\"importedSmartObject\""))
        #expect(ProjectManifest.current == 13)

        let reopened = EditorSession()
        reopened.installProject(try await ProjectStore.shared.load(from: url), from: url)
        let restored = try #require(reopened.document)
        #expect(restored.layers.map(\.smartObject?.info) == layers.map(\.smartObject?.info))
        #expect(restored.layers.map(\.psdExtras) == layers.map(\.psdExtras))
        #expect(restored.layers.compactMap(\.smartObject?.payload?.sha256) == layers.compactMap(\.smartObject?.payload?.sha256))
        #expect(restored.layers.count == 2 && restored.layers[0].smartObject?.payload?.data == contents)
        #expect(restored.layers[0].smartObject?.payload === restored.layers[1].smartObject?.payload)
        #expect(restored.psdExtras == session.document?.psdExtras)
        #expect(restored.psdExtras?.orphanLinkedEntries.count == 1)
    }

    @Test func alteredOrMisnamedContentsAreRejected() async throws {
        let document = try read([try smartLayer("Logo", uuid: "u")],
                                globalBlocks: [PSDFixture.linkedLayersBlock(entries: [entry("u", data: try png())])])
        let session = try opened(try PSDDocumentBuilder.makeImport(document))
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Smart.comp")
        let snapshot = try #require(session.projectSnapshot())
        try await ProjectStore.shared.save(snapshot, to: url)
        let layer = try #require(session.document?.layers.first { $0.smartObject != nil })
        let file = url.appendingPathComponent("smartobjects/\(layer.id.uuidString).png")
        var altered = try Data(contentsOf: file)
        altered[altered.count - 1] ^= 0xFF
        try altered.write(to: file)
        await #expect(throws: ProjectError.self) { try await ProjectStore.shared.load(from: url) }

        // A contents file named after no layer, or outside `smartobjects/`, and a version 9 smart object are invalid.
        for name in ["\(UUID().uuidString).png", "../manifest.json", "\(layer.id.uuidString).p/g"] {
            var manifest = snapshot.manifest
            let index = try #require(manifest.layers.firstIndex { $0.id == layer.id })
            manifest.layers[index].smartObjectFile?.name = name
            let data = try JSONEncoder().encode(manifest)
            let bad = root.appendingPathComponent("\(UUID()).comp")
            try FileManager.default.copyItem(at: url, to: bad)
            try data.write(to: bad.appendingPathComponent("manifest.json"))
            await #expect(throws: ProjectError.self) { try await ProjectStore.shared.load(from: bad) }
        }
        var old = snapshot.manifest
        old.version = 9
        old.psd = nil
        for index in old.layers.indices { old.layers[index].psd = nil; old.layers[index].locks = nil; old.layers[index].fillOpacity = nil }
        let v9 = root.appendingPathComponent("Old.comp")
        try FileManager.default.copyItem(at: url, to: v9)
        try JSONEncoder().encode(old).write(to: v9.appendingPathComponent("manifest.json"))
        await #expect(throws: ProjectError.self) { try await ProjectStore.shared.load(from: v9) }
        for index in old.layers.indices { old.layers[index].smartObject = nil; old.layers[index].smartObjectFile = nil }
        try JSONEncoder().encode(old).write(to: v9.appendingPathComponent("manifest.json"))
        _ = try await ProjectStore.shared.load(from: v9)
    }

    /// Embedded contents are files of their own, not part of `psd/document.blocks` (256 MiB), so a document holding
    /// more than that still saves. The contents are a sparse file, mapped rather than read.
    @Test func contentsBeyondTheDocumentBlocksLimitStillSave() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Large.psb")
        let size = PSDDocumentExtrasRecord.maximumBlocksBytes + 4_096
        #expect(FileManager.default.createFile(atPath: source.path, contents: Data("8BPS\0\u{2}".utf8)))
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        let payload = SmartObjectPayload(data: try Data(contentsOf: source, options: .alwaysMapped))
        let info = SmartObjectInfo(uniqueID: "large", placedID: "p", fileType: "8BPB", fileName: "Large.psb",
                                   naturalSize: CGSize(width: 40_000, height: 40_000), resolution: 72,
                                   quad: .unitSquare, placedType: 2, isEmbedded: true)
        let session = EditorSession()
        session.createDocument(width: 8, height: 8, emptyLayer: true)
        session.document?.layers[0].smartObject = LayerSmartObject(info: info, payload: payload)
        session.document?.psdExtras = PSDDocumentExtras(globalBlocks: [PSDTaggedBlock(key: "Patt", data: Data([1, 2]))])
        let url = root.appendingPathComponent("Large.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let id = try #require(session.document?.layers[0].id)
        let saved = try FileManager.default.attributesOfItem(atPath: url.appendingPathComponent("smartobjects/\(id.uuidString).psb").path)
        #expect((saved[.size] as? Int) == size)
        let loaded = try await ProjectStore.shared.load(from: url)
        let file = try #require(loaded.manifest.layers.first?.smartObjectFile)
        #expect(file.payload?.data.count == size && file.sha256 == payload.sha256)

        // Each contents file is limited to 512 MiB.
        let huge = root.appendingPathComponent("Huge.psb")
        #expect(FileManager.default.createFile(atPath: huge.path, contents: nil))
        let hugeHandle = try FileHandle(forWritingTo: huge)
        try hugeHandle.truncate(atOffset: UInt64(SmartObjectFileRecord.maximumBytes + 1))
        try hugeHandle.close()
        session.document?.layers[0].smartObject = LayerSmartObject(
            info: info, payload: SmartObjectPayload(data: try Data(contentsOf: huge, options: .alwaysMapped)))
        await #expect(throws: ProjectError.self) {
            try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: root.appendingPathComponent("Huge.comp"))
        }
    }

    /// Version 10 projects saved before smart objects were modeled kept `lnk2` among the document's blocks; loading
    /// takes its entries out, giving each smart-object layer its contents and keeping the rest as orphans.
    @Test func projectsSavedBeforeSmartObjectsTakeTheirEntriesOutOnLoad() async throws {
        let contents = try png()
        let session = EditorSession()
        session.createDocument(width: 64, height: 64, emptyLayer: true)
        let placement = LayerTransform(origin: CGPoint(x: 20, y: 16), size: CGSize(width: 24, height: 24))
        session.document?.layers[0].transform = placement
        session.document?.layers[0].psdExtras = PSDLayerExtras(
            blocks: PSDFixture.smartObjectBlocks(uuid: "legacy", size: CGSize(width: 10, height: 8), quad: quad))
        let spare = entry("spare", data: Data([7, 7]))
        session.document?.psdExtras = PSDDocumentExtras(globalBlocks: [
            PSDTaggedBlock(key: "Patt", data: Data([1, 2, 3, 4])),
            PSDFixture.linkedLayersBlock(entries: [entry("legacy", data: contents), spare]),
        ])
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Legacy.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("smartobjects").path))

        let reopened = EditorSession()
        reopened.installProject(try await ProjectStore.shared.load(from: url), from: url)
        let layer = try #require(reopened.document?.layers.first)
        let smartObject = try #require(layer.smartObject)
        #expect(smartObject.payload?.data == contents && smartObject.info.fileName == "Logo.png")
        #expect(close(smartObject.info.quad.documentQuad(for: layer.transform), quad))
        // Import made pixels of it then (they may have been painted since), so a PSD save writes it as pixels.
        #expect(layer.psdExtras?.importedSmartObject == nil)
        #expect(reopened.document?.psdExtras?.globalBlocks.map(\.key) == ["Patt"])
        #expect(reopened.document?.psdExtras?.linkedBlockIndex == 1)
        #expect(reopened.document?.psdExtras?.orphanLinkedEntries == [PSDFixture.linkedEntry(spare)])

        // Saved again, the contents are a file and the blocks no longer hold them.
        let again = root.appendingPathComponent("Again.comp")
        try await ProjectStore.shared.save(try #require(reopened.projectSnapshot()), to: again)
        let blocks = try PSDBlockFile.decodeBlocks(try Data(contentsOf: again.appendingPathComponent("psd/document.blocks")),
                                                   limit: .max, alignment: 4)
        #expect(blocks.map(\.key) == ["Patt"])
        #expect(FileManager.default.fileExists(atPath: again.appendingPathComponent("smartobjects/\(layer.id.uuidString).png").path))
    }
}

/// Replacing and placing smart-object contents, each one undo step.
@MainActor
@Suite(.serialized)
struct SmartObjectEditingTests {
    private let quad = [CGPoint(x: 18, y: 14), CGPoint(x: 46, y: 14), CGPoint(x: 46, y: 42), CGPoint(x: 18, y: 42)]

    private func png(width: Int, height: Int, dpi: Double? = nil) throws -> Data {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try encoded(try #require(context.makeImage()), as: .png, dpi: dpi)
    }

    /// A `width` × `height` image in three even bands along its longer side, red, green and blue, as `type`.
    private func bands(width: Int, height: Int, as type: UTType = .png) throws -> Data {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let across = width >= height
        let third = CGFloat(across ? width : height) / 3
        for (index, (red, green, blue)) in [(1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0)].enumerated() {
            context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
            let start = CGFloat(index) * third
            context.fill(across ? CGRect(x: start, y: 0, width: third, height: CGFloat(height))
                                : CGRect(x: 0, y: start, width: CGFloat(width), height: third))
        }
        return try encoded(try #require(context.makeImage()), as: type)
    }

    private func encoded(_ image: CGImage, as type: UTType, dpi: Double? = nil) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
        if let dpi { properties[kCGImagePropertyDPIWidth] = dpi; properties[kCGImagePropertyDPIHeight] = dpi }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The image `data` holds, and its type.
    private func decoded(_ data: Data) throws -> (image: CGImage, type: UTType?) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return (try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)), CGImageSourceGetType(source).flatMap { UTType($0 as String) })
    }

    /// Whether `image` is green at its corners and middle.
    private func isGreen(_ image: CGImage) throws -> Bool {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let (w, h) = (image.width, image.height)
        return [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1), (w / 2, h / 2)].allSatisfy { x, y in
            let pixel = (0..<4).map { Int(bytes[(y * w + x) * 4 + $0]) }
            return pixel[0] < 40 && pixel[1] > 215 && pixel[2] < 40 && pixel[3] == 255
        }
    }

    /// `rect`'s corners, top-left, top-right, bottom-right, bottom-left.
    private func corners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY),
         CGPoint(x: rect.minX, y: rect.maxY)]
    }

    private func file(_ name: String, _ data: Data, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SmartObjectEditingTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    /// A document opened from a file with one smart object (10×8 contents, pixels at 20,16 24×24, placed on `quad`).
    private func openedSmartObject() throws -> (session: EditorSession, id: UUID) {
        let context = try BrushRaster.context(width: 24, height: 24, mask: false)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        var record = PSDRecord(id: UUID(), name: "Logo")
        record.bounds = CGRect(x: 20, y: 16, width: 24, height: 24)
        let blue = try #require(context.makeImage())
        record.image = blue
        record.extras = PSDLayerExtras(blocks: PSDFixture.smartObjectBlocks(uuid: "u", size: CGSize(width: 10, height: 8), quad: quad))
        let entry = PSDFixture.LinkedEntry(uuid: "u", fileName: "Logo.png", data: try png(width: 10, height: 8))
        var document = PSDDocument(width: 64, height: 64, resolution: 72, layers: [record])
        document.extras = PSDDocumentExtras(globalBlocks: [PSDFixture.linkedLayersBlock(entries: [entry])])
        let data = try PSDFixture.data(document, composite: blue)
        let session = EditorSession()
        try session.insertPhotoshop(try PSDDocumentBuilder.makeImport(try PSDReader.read(data)), named: "Smart")
        let id = try #require(session.document?.layers.first?.id)
        session.history.reset()
        return (session, id)
    }

    private func layer(_ session: EditorSession, _ id: UUID) throws -> ImageLayer {
        try #require(session.document?.layers.first { $0.id == id })
    }

    private func close(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 0.001 && abs(a.y - b.y) < 0.001 }
    private func close(_ a: PlacementQuad, _ b: [CGPoint]) -> Bool { b.count == 4 && zip(a.corners, b).allSatisfy(close) }

    @Test func stretchedContentsKeepTheQuadAndBumpTheRevision() async throws {
        let (session, id) = try openedSmartObject()
        let before = try layer(session, id)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = try png(width: 20, height: 10)
        try await session.replaceSmartObjectContents(id, with: try file("New.png", contents, in: root), fitting: .stretch)
        let after = try layer(session, id)
        let info = try #require(after.smartObject?.info)
        #expect(close(info.quad.documentQuad(for: after.transform), quad))
        #expect(info.contentsRevision == 1)
        #expect(info.uniqueID != "u" && info.uniqueID == info.uniqueID.lowercased() && UUID(uuidString: info.uniqueID) != nil)
        #expect(info.placedID != before.smartObject?.info.placedID && UUID(uuidString: info.placedID) != nil)
        #expect(info.fileType == "png " && info.fileName == "New.png" && info.naturalSize == CGSize(width: 20, height: 10))
        #expect(info.isEmbedded && info.link == nil && info.placedType == 2)
        #expect(after.smartObject?.payload?.data == contents)
        // New pixels drawn from the contents, filling the quad.
        #expect(after.asset?.image.width == 28 && after.asset?.image.height == 28)
        #expect(after.asset?.image !== before.asset?.image)
        #expect(after.psdExtras?.importedSmartObject == before.smartObject?.info)
        #expect(session.history.undoCount == 1 && session.history.undoName == "Replace Smart Object Contents")
    }

    @Test func fittedContentsKeepTheirAspect() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let wide = try file("Wide.png", try png(width: 20, height: 10), in: root)
        let (session, id) = try openedSmartObject()
        try await session.replaceSmartObjectContents(id, with: wide)
        var after = try layer(session, id)
        // Inside the 28 × 28 quad, 2:1 and centered.
        #expect(close(try #require(after.smartObject?.info.quad).documentQuad(for: after.transform),
                      [CGPoint(x: 18, y: 21), CGPoint(x: 46, y: 21), CGPoint(x: 46, y: 35), CGPoint(x: 18, y: 35)]))
        #expect(after.asset?.image.width == 28 && after.asset?.image.height == 14)
        // Filling it instead: cropped to its middle 10 × 10, the contents cover the quad and nothing past it.
        let (other, otherID) = try openedSmartObject()
        try await other.replaceSmartObjectContents(otherID, with: wide, fitting: .fill)
        after = try layer(other, otherID)
        #expect(close(try #require(after.smartObject?.info.quad).documentQuad(for: after.transform), quad))
        #expect(after.smartObject?.info.naturalSize == CGSize(width: 10, height: 10))
        #expect(after.asset?.image.width == 28 && after.asset?.image.height == 28)
        // Replacing again starts from the quad the contents now have.
        try await other.replaceSmartObjectContents(otherID, with: wide)
        after = try layer(other, otherID)
        #expect(close(try #require(after.smartObject?.info.quad).documentQuad(for: after.transform),
                      [CGPoint(x: 18, y: 21), CGPoint(x: 46, y: 21), CGPoint(x: 46, y: 35), CGPoint(x: 18, y: 35)]))
        #expect(after.smartObject?.info.contentsRevision == 2)
    }

    @Test func fillingCropsLandscapeContentsToAPortraitFrameAndKeepsTheLayerOnIt() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        session.createDocument(width: 100, height: 100, emptyLayer: true)
        let frame = CGRect(x: 10, y: 5, width: 30, height: 60)
        let id = try await session.placeSmartObject(from: try file("Portrait.png", try png(width: 30, height: 60), in: root),
                                                    fitting: .stretch, in: frame)
        // Its position locked and a mask on it: filling moves neither.
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].locks = [.position]
        session.document?.layers[index].mask = LayerMask.solid(revealing: false)
        session.history.reset()
        let before = try layer(session, id)

        // 90 × 30 in red, green and blue thirds: its middle 15 × 30, all green, is what fills the frame.
        let wide = try file("Wide.png", try bands(width: 90, height: 30), in: root)
        try await session.replaceSmartObjectContents(id, with: wide, fitting: .fill)
        let after = try layer(session, id)
        #expect(after.transform == before.transform && after.mask == before.mask)
        #expect(after.transform.origin == frame.origin && after.transform.size == frame.size)
        let info = try #require(after.smartObject?.info)
        #expect(close(info.quad.documentQuad(for: after.transform), corners(frame)))
        #expect(info.naturalSize == CGSize(width: 15, height: 30) && info.fileName == "Wide.png" && info.fileType == "png ")
        #expect(info.placedType == 2 && info.contentsRevision == 1)
        // The crop is what the smart object keeps, and all the layer shows.
        let payload = try decoded(try #require(after.smartObject?.payload?.data))
        #expect(payload.type == .png && payload.image.width == 15 && payload.image.height == 30)
        #expect(try isGreen(payload.image))
        let pixels = try #require(after.asset?.image)
        #expect(pixels.width == 30 && pixels.height == 60)
        #expect(try isGreen(pixels))
        #expect(session.history.undoCount == 1 && session.history.undoName == "Replace Smart Object Contents")
        session.undo()
        #expect(try layer(session, id) == before)
    }

    @Test func fillingCropsPortraitContentsToALandscapeFrameAndKeepsThemLossless() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        session.createDocument(width: 100, height: 100, emptyLayer: true)
        let frame = CGRect(x: 20, y: 30, width: 60, height: 30)
        let id = try await session.placeSmartObject(from: try file("Square.png", try png(width: 10, height: 10), in: root),
                                                    fitting: .stretch, in: frame)
        session.history.reset()
        func expectOnTheFrame(_ label: String) throws -> ImageLayer {
            let after = try layer(session, id)
            #expect(after.transform.origin == frame.origin && after.transform.size == frame.size, "\(label)")
            #expect(close(try #require(after.smartObject?.info).quad.documentQuad(for: after.transform), corners(frame)), "\(label)")
            #expect(after.asset?.image.width == 60 && after.asset?.image.height == 30, "\(label)")
            return after
        }

        // 30 × 96 in thirds top to bottom, as a JPEG: its middle 30 × 15 fills the frame, kept as a PNG.
        try await session.replaceSmartObjectContents(id, with: try file("Tall.jpg", try bands(width: 30, height: 96, as: .jpeg), in: root),
                                                     fitting: .fill)
        var after = try expectOnTheFrame("JPEG")
        var info = try #require(after.smartObject?.info)
        #expect(info.naturalSize == CGSize(width: 30, height: 15) && info.fileName == "Tall.png" && info.fileType == "png ")
        var payload = try decoded(try #require(after.smartObject?.payload?.data))
        #expect(payload.type == .png && payload.image.width == 30 && payload.image.height == 15)
        #expect(try isGreen(payload.image))

        // A TIFF stays a TIFF.
        try await session.replaceSmartObjectContents(id, with: try file("Tall.tif", try bands(width: 30, height: 96, as: .tiff), in: root),
                                                     fitting: .fill)
        after = try expectOnTheFrame("TIFF")
        info = try #require(after.smartObject?.info)
        #expect(info.naturalSize == CGSize(width: 30, height: 15) && info.fileName == "Tall.tif" && info.fileType == "TIFF")
        payload = try decoded(try #require(after.smartObject?.payload?.data))
        #expect(payload.type == .tiff && payload.image.width == 30 && payload.image.height == 15)
        #expect(try isGreen(payload.image))

        // Contents already of the frame's proportions are kept as they are.
        let exact = try bands(width: 40, height: 20)
        try await session.replaceSmartObjectContents(id, with: try file("Exact.png", exact, in: root), fitting: .fill)
        after = try expectOnTheFrame("Exact")
        #expect(after.smartObject?.payload?.data == exact && after.smartObject?.info.naturalSize == CGSize(width: 40, height: 20))
        #expect(session.history.undoCount == 3)
    }

    @Test func placingWithFillCropsTheContentsToTheRect() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        session.createDocument(width: 100, height: 100, emptyLayer: true)
        session.history.reset()
        // 90 × 30 in a square: its middle 30 × 30.
        let rect = CGRect(x: 10, y: 10, width: 50, height: 50)
        let id = try await session.placeSmartObject(from: try file("Wide.png", try bands(width: 90, height: 30), in: root),
                                                    fitting: .fill, in: rect)
        let placed = try layer(session, id)
        #expect(placed.transform.origin == rect.origin && placed.transform.size == rect.size)
        #expect(placed.smartObject?.info.quad == .unitSquare && placed.smartObject?.info.naturalSize == CGSize(width: 30, height: 30))
        let payload = try decoded(try #require(placed.smartObject?.payload?.data))
        #expect(payload.image.width == 30 && payload.image.height == 30)
        #expect(try isGreen(payload.image))
        let pixels = try #require(placed.asset?.image)
        #expect(pixels.width == 50 && pixels.height == 50)
        #expect(try isGreen(pixels))
        #expect(session.history.undoCount == 1 && session.history.undoName == "Place Smart Object")

        // Vector contents are drawn to be cropped, a pixel a point or as finely as the rect shows them: 200 × 100
        // points covering 60 × 120 pixels are drawn at 240 × 120, and their middle 60 × 120 kept as a PNG.
        let svg = Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><rect width="200" height="100" fill="#00ff00"/></svg>"##.utf8)
        let tall = CGRect(x: 0, y: 0, width: 60, height: 120)
        let logo = try layer(session, try await session.placeSmartObject(from: try file("Logo.svg", svg, in: root), fitting: .fill, in: tall))
        #expect(logo.transform.origin == tall.origin && logo.transform.size == tall.size)
        let info = try #require(logo.smartObject?.info)
        #expect(info.fileName == "Logo.png" && info.fileType == "png " && info.placedType == 2)
        #expect(info.naturalSize == CGSize(width: 60, height: 120) && abs(info.resolution - 86.4) < 0.001)
        let drawn = try decoded(try #require(logo.smartObject?.payload?.data))
        #expect(drawn.type == .png && drawn.image.width == 60 && drawn.image.height == 120)
        #expect(try isGreen(drawn.image))
    }

    /// Vector contents filling a very large frame are drawn at the one-surface cap (`DocumentLimits.maxSurfacePixels`).
    /// Rounding their drawn size up could land just past it (300 × 100 points into 11,000 × 11,000 pixels would draw
    /// at 24495 × 8165 = 200,001,675 pixels), and the fill was refused with an unrelated "too large" error; the drawn
    /// size rounds down, so the fill fits the cap. Checked on the size, since drawing at the cap takes 800 MB.
    @Test func aVectorFillIntoAHugeFrameStaysWithinThePixelCap() throws {
        let svg = Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="300" height="100"><rect width="300" height="100" fill="#00ff00"/></svg>"##.utf8)
        let contents = SmartObjectContents(payload: SmartObjectPayload(data: svg), kind: .svg, fileType: "SVG ",
                                           fileName: "Wide.svg", size: CGSize(width: 300, height: 100), resolution: nil)
        let drawn = contents.drawnSize(toFill: CGSize(width: 11_000, height: 11_000)).size
        #expect(drawn.width * drawn.height <= DocumentLimits.maxSurfaceExtent)
        #expect(drawn == CGSize(width: 24_494, height: 8_164))
    }

    @Test func undoRestoresTheContentsAndPixels() async throws {
        let (session, id) = try openedSmartObject()
        let before = try layer(session, id)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await session.replaceSmartObjectContents(id, with: try file("New.png", try png(width: 20, height: 10), in: root))
        let replaced = try layer(session, id)
        session.undo()
        let undone = try layer(session, id)
        #expect(undone.smartObject?.payload === before.smartObject?.payload)
        #expect(undone.smartObject?.info == before.smartObject?.info)
        #expect(undone.asset?.image === before.asset?.image && undone.transform == before.transform)
        session.redo()
        #expect(try layer(session, id).smartObject?.payload === replaced.smartObject?.payload)
    }

    @Test func contentsThatCantBeDrawnLeaveTheLayerAlone() async throws {
        let (session, id) = try openedSmartObject()
        let before = try layer(session, id)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let psb = try file("Big.psb", Data("8BPS\0\u{2}".utf8) + Data(count: 40), in: root)
        await #expect(throws: SmartObjectError.largeDocument) { try await session.replaceSmartObjectContents(id, with: psb) }
        #expect(try layer(session, id) == before)
        #expect(session.history.undoCount == 0)
        session.createDocument(width: 8, height: 8, emptyLayer: true)
        let plain = try #require(session.document?.layers.first?.id)
        await #expect(throws: SmartObjectError.notSmartObject) {
            try await session.replaceSmartObjectContents(plain, with: try file("New.png", try png(width: 2, height: 2), in: root))
        }
    }

    @Test func placedContentsAreSizedByResolutionCappedAndCentered() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        session.createDocument(width: 100, height: 80, emptyLayer: true)
        session.document?.resolution = 144
        session.history.reset()
        let small = try png(width: 30, height: 20, dpi: 72)
        let id = try await session.placeSmartObject(from: try file("Badge.png", small, in: root))
        let placed = try layer(session, id)
        // 30 × 20 at 72 ppi is 60 × 40 at 144, centered on the canvas.
        #expect(placed.transform.origin == CGPoint(x: 20, y: 20) && placed.transform.size == CGSize(width: 60, height: 40))
        #expect(placed.asset?.image.width == 60 && placed.asset?.image.height == 40)
        #expect(placed.name == "Badge" && session.activeLayerID == id)
        #expect(session.document?.layers.last?.id == id)
        let info = try #require(placed.smartObject?.info)
        #expect(info.quad == .unitSquare && info.fileName == "Badge.png" && info.fileType == "png " && info.isEmbedded)
        #expect(info.naturalSize == CGSize(width: 30, height: 20) && info.resolution == 72 && info.contentsRevision == 0)
        #expect(UUID(uuidString: info.uniqueID) != nil && info.uniqueID == info.uniqueID.lowercased())
        #expect(placed.smartObject?.payload?.data == small)
        #expect(session.history.undoCount == 1 && session.history.undoName == "Place Smart Object")

        // Wider than the canvas: capped to it, at a point.
        let wide = try await session.placeSmartObject(from: try file("Banner.png", try png(width: 400, height: 100, dpi: 72), in: root),
                                                      at: CGPoint(x: 40, y: 30))
        let banner = try layer(session, wide)
        #expect(banner.transform.size == CGSize(width: 100, height: 25))
        #expect(banner.transform.center == CGPoint(x: 40, y: 30))
        session.undo()
        #expect(session.document?.layers.contains { $0.id == wide } == false)
    }

    @Test func rasterizingKeepsThePixelsAndDropsTheSmartObject() throws {
        let (session, id) = try openedSmartObject()
        let before = try layer(session, id)
        session.rasterizeSmartObject(id)
        let after = try layer(session, id)
        #expect(after.smartObject == nil)
        #expect(after.asset?.image === before.asset?.image && after.transform == before.transform)
        #expect(session.history.undoName == "Rasterize Smart Object")
        session.undo()
        #expect(try layer(session, id).smartObject == before.smartObject)
        let uuid = EditorSession.newPhotoshopUUID()
        #expect(uuid.count == 36 && uuid == uuid.lowercased() && UUID(uuidString: uuid) != nil)
    }

    // MARK: Image Size

    /// Image Size of the 64 × 64 document to `width` × `height`, the smart object placed by `adjust` first and given a
    /// perspective: both quads land where the canvas scale takes their corners, whatever grid the layer is redrawn on.
    private func expectImageSizeCarriesTheQuads(width: Int, height: Int, _ adjust: (inout LayerTransform) -> Void) async throws {
        let (session, id) = try openedSmartObject()
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        adjust(&session.document!.layers[index].transform)
        let perspective = PlacementQuad(topLeft: CGPoint(x: -0.1, y: -0.05), topRight: CGPoint(x: 1.2, y: 0),
                                        bottomRight: CGPoint(x: 1, y: 1.1), bottomLeft: CGPoint(x: 0.05, y: 0.9))
        session.document!.layers[index].smartObject?.info.nonAffineQuad = perspective
        let before = try layer(session, id)
        let info = try #require(before.smartObject?.info)
        let sx = CGFloat(width) / 64, sy = CGFloat(height) / 64
        func scaled(_ quad: PlacementQuad) -> [CGPoint] {
            quad.documentQuad(for: before.transform).corners.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
        }
        let resized = try await ImageResizer.shared.resize(try #require(session.projectSnapshot()),
            to: ImageSizeOptions(width: width, height: height, resolution: 72))
        session.applyImageSize(resized)
        let after = try layer(session, id)
        let carried = try #require(after.smartObject?.info)
        #expect(close(carried.quad.documentQuad(for: after.transform), scaled(info.quad)))
        #expect(close(try #require(carried.nonAffineQuad).documentQuad(for: after.transform), scaled(perspective)))
        #expect(carried.isValid && after.smartObject?.payload === before.smartObject?.payload)
    }

    @Test func imageSizeCarriesTheQuadOfAFlippedOrTurnedSmartObject() async throws {
        // Flipped: the pixels are redrawn mirrored and upright, and the quad stays mirrored (its top-left on the right).
        try await expectImageSizeCarriesTheQuads(width: 32, height: 32) { $0.flipX = true }
        let (session, id) = try openedSmartObject()
        session.document!.layers[0].transform.flipX = true
        session.applyImageSize(try await ImageResizer.shared.resize(try #require(session.projectSnapshot()),
            to: ImageSizeOptions(width: 32, height: 32, resolution: 72)))
        let flipped = try layer(session, id)
        let corners = try #require(flipped.smartObject?.info.quad).documentQuad(for: flipped.transform)
        #expect(!flipped.transform.flipX && close(corners.topLeft, CGPoint(x: 23, y: 7)) && close(corners.topRight, CGPoint(x: 9, y: 7)))
        // Turned 30°: redrawn upright on the box around it, the quad keeps its turn.
        try await expectImageSizeCarriesTheQuads(width: 32, height: 32) { $0.rotation = 30 }
        try await expectImageSizeCarriesTheQuads(width: 96, height: 48) { $0.rotation = 30; $0.flipY = true }
        // Unturned at 33%: the grid grows to whole pixels, and the corners stay where the scale puts them.
        try await expectImageSizeCarriesTheQuads(width: 21, height: 21) { _ in }
    }

    // MARK: Limits and the edit protocol

    @Test func contentsThatWouldPlaceTheLayerBeyondADocumentAreRefused() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, id) = try openedSmartObject()
        // A quad 400,000 pixels wide: contents stretched over it would make a layer no project could save.
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        let transform = session.document!.layers[index].transform
        session.document!.layers[index].smartObject?.info.quad = .rect(CGRect(x: 18, y: 14, width: 400_000, height: 28), in: transform)
        let before = try layer(session, id)
        let badge = try file("Badge.png", try png(width: 10, height: 10), in: root)
        await #expect(throws: ImageImportError.tooLarge) {
            try await session.replaceSmartObjectContents(id, with: badge, fitting: .stretch)
        }
        #expect(try layer(session, id) == before)
        #expect(session.history.undoCount == 0 && !session.isProjectBusy)

        // A 20,000 × 1 divider filling a 28 × 28 quad is cropped to its middle pixel, so it stays on the quad.
        session.document!.layers[index].smartObject?.info.quad = .rect(CGRect(x: 18, y: 14, width: 28, height: 28), in: transform)
        let divider = try file("Divider.png", try png(width: 20_000, height: 1), in: root)
        try await session.replaceSmartObjectContents(id, with: divider, fitting: .fill)
        let filled = try layer(session, id)
        #expect(filled.transform.origin == CGPoint(x: 18, y: 14) && filled.transform.size == CGSize(width: 28, height: 28))
        #expect(filled.smartObject?.info.naturalSize == CGSize(width: 1, height: 1))
        // Fitted instead, it is a line across the quad, a pixel high.
        try await session.replaceSmartObjectContents(id, with: divider)
        let fitted = try layer(session, id)
        #expect(fitted.transform.isValid && fitted.transform.size == CGSize(width: 28, height: 1))

        // A point that isn't finite, or is that far out, is refused; so is one that would put the layer past the edge.
        for point in [CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 0, y: CGFloat.infinity), CGPoint(x: 2_000_000, y: 0),
                      CGPoint(x: -1_000_000, y: 0)] {
            await #expect(throws: SmartObjectError.invalidPlacement) { try await session.placeSmartObject(from: badge, at: point) }
        }
        #expect(session.document?.layers.count == 1 && session.history.undoCount == 2 && !session.isProjectBusy)
    }

    @Test func replacingAndPlacingHoldTheProjectAndStartOnlyWhenItIsFree() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let wide = try file("Wide.png", try png(width: 20, height: 10), in: root)
        let (session, id) = try openedSmartObject()
        let before = try layer(session, id)

        // Another edit holding the document: refused, nothing changed.
        session.isProjectBusy = true
        await #expect(throws: SmartObjectError.busy) { try await session.replaceSmartObjectContents(id, with: wide) }
        await #expect(throws: SmartObjectError.busy) { try await session.placeSmartObject(from: wide) }
        session.isProjectBusy = false
        #expect(try layer(session, id) == before && session.history.undoCount == 0)

        // A pending transform is committed first, and the contents fit the quad where it put the layer.
        session.selectLayer(id)
        session.beginTransform()
        var moved = before.transform
        moved.origin.x += 6
        session.previewTransform(moved)
        try await session.replaceSmartObjectContents(id, with: wide)
        var after = try layer(session, id)
        #expect(session.transformEdit == nil && session.history.undoCount == 2)
        #expect(close(try #require(after.smartObject?.info.quad).documentQuad(for: after.transform),
                      [CGPoint(x: 24, y: 21), CGPoint(x: 52, y: 21), CGPoint(x: 52, y: 35), CGPoint(x: 24, y: 35)]))

        // While the contents are read and drawn the project is busy: no transform or stroke starts on the layer.
        let square = try file("Square.png", try png(width: 10, height: 10), in: root)
        let replacing = Task { try await session.replaceSmartObjectContents(id, with: square) }
        try await waitUntilBusy(session)
        #expect(!session.canEditLayers)
        session.beginTransform()
        session.tool = .brush
        session.beginBrush(at: CGPoint(x: 38, y: 28))
        #expect(session.transformEdit == nil && session.brushStroke == nil)
        session.tool = .move
        try await replacing.value
        after = try layer(session, id)
        #expect(!session.isProjectBusy && session.history.undoName == "Replace Smart Object Contents")
        #expect(after.asset?.image.width == 14 && after.asset?.image.height == 14)
        #expect(after.smartObject?.info.fileName == "Square.png")

        // An edit that began meanwhile anyway (renaming the layer) stops the replacement when it is ready.
        let replaced = after
        let blocked = Task { try await session.replaceSmartObjectContents(id, with: wide) }
        try await waitUntilBusy(session)
        session.renamingLayerID = id
        await #expect(throws: SmartObjectError.busy) { try await blocked.value }
        #expect(try layer(session, id) == replaced && session.history.undoCount == 3 && !session.isProjectBusy)
        session.renamingLayerID = nil

        // Placing is busy the same way, and the new layer goes above the layer active when it is ready.
        let placing = Task { try await session.placeSmartObject(from: square) }
        try await waitUntilBusy(session)
        #expect(!session.canEditLayers)
        let placed = try await placing.value
        #expect(!session.isProjectBusy && session.activeLayerID == placed && session.document?.layers.last?.id == placed)
    }

    /// Yields until `session` is busy (a replace or place has reached its read), failing after a generous wait.
    private func waitUntilBusy(_ session: EditorSession) async throws {
        for _ in 0..<10_000 where !session.isProjectBusy { await Task.yield() }
        try #require(session.isProjectBusy)
    }
}
