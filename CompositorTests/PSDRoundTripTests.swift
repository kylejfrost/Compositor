import Foundation
import CoreGraphics
import UniformTypeIdentifiers
import Testing
@testable import Compositor

@MainActor
@Suite(.serialized)
struct PSDRoundTripTests {
    private func colorImage(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func grayImage(width: Int, height: Int, value: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: value, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func header(version: UInt16 = 1, width: UInt32 = 8, height: UInt32 = 8, depth: UInt16 = 8, mode: UInt16 = 3) -> Data {
        var data = Data("8BPS".utf8)
        func append(_ value: UInt16) {
            data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value))
        }
        func append32(_ value: UInt32) {
            data.append(UInt8(truncatingIfNeeded: value >> 24))
            data.append(UInt8(truncatingIfNeeded: value >> 16))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value))
        }
        append(version)
        data.append(Data(count: 6))
        append(3)
        append32(height)
        append32(width)
        append(depth)
        append(mode)
        return data
    }

    @Test func roundTripLayersOrderVisibilityOpacityAndBlend() throws {
        let red = try colorImage(width: 2, height: 2, red: 1, green: 0, blue: 0)
        let blue = try colorImage(width: 2, height: 2, red: 0, green: 0, blue: 1)
        let composite = try colorImage(width: 4, height: 4, red: 0, green: 0, blue: 0, alpha: 0)
        var bottom = PSDRecord(id: UUID(), name: "Red")
        bottom.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        bottom.image = red
        bottom.opacity = 0.5
        bottom.blendKey = "mul "
        var top = PSDRecord(id: UUID(), name: "Blue")
        top.bounds = CGRect(x: 2, y: 0, width: 2, height: 2)
        top.image = blue
        top.isVisible = false
        let data = try PSDFixture.data(PSDDocument(width: 4, height: 4, resolution: 144, layers: [bottom, top]), composite: composite)
        #expect(data.prefix(4) == Data("8BPS".utf8))
        let document = try PSDReader.read(data)
        #expect(document.width == 4 && document.height == 4)
        #expect(document.resolution == 144)
        #expect(document.layers.map(\.name) == ["Red", "Blue"])
        #expect(document.layers[0].isVisible)
        #expect(!document.layers[1].isVisible)
        #expect(abs(document.layers[0].opacity - 0.5) < 0.01)
        #expect(document.layers[0].blendKey == "mul ")
        #expect(document.layers[0].image?.width == 2)
        let imported = try PSDDocumentBuilder.makeImport(document)
        #expect(imported.conversions.isEmpty)
        #expect(imported.layers.map(\.name) == ["Red", "Blue"])
        #expect(imported.layers[0].blendMode == .multiply)
        #expect(imported.layers[1].isVisible == false)
    }

    @Test func roundTripGroupsMasksAndClipping() throws {
        let fill = try colorImage(width: 2, height: 2, red: 0, green: 1, blue: 0)
        let clipped = try colorImage(width: 2, height: 2, red: 1, green: 1, blue: 0)
        let mask = try grayImage(width: 2, height: 2, value: 1)
        let composite = try colorImage(width: 4, height: 4, red: 0, green: 0, blue: 0, alpha: 0)
        let groupID = UUID()
        var group = PSDRecord(id: groupID, name: "Stack")
        group.isGroup = true
        group.blendKey = "pass"
        var base = PSDRecord(id: UUID(), parentID: groupID, name: "Base")
        base.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        base.image = fill
        base.mask = mask
        var child = PSDRecord(id: UUID(), parentID: groupID, name: "Clipped")
        child.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        child.image = clipped
        child.clipping = true
        let data = try PSDFixture.data(PSDDocument(width: 4, height: 4, resolution: 72, layers: [group, base, child]), composite: composite)
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        #expect(imported.conversions.isEmpty)
        #expect(imported.layers.contains { $0.isGroup && $0.name == "Stack" })
        let folder = try #require(imported.layers.first { $0.isGroup })
        let importedBase = try #require(imported.layers.first { $0.name == "Base" })
        let importedChild = try #require(imported.layers.first { $0.name == "Clipped" })
        #expect(importedBase.parentID == folder.id)
        #expect(importedChild.parentID == folder.id)
        #expect(importedBase.mask != nil)
        #expect(importedChild.maskSourceID == importedBase.id)
    }

    @Test func importedGroupsFollowPhotoshopLsctOrder() throws {
        let fill = try colorImage(width: 2, height: 2, red: 0, green: 1, blue: 0)
        let composite = try colorImage(width: 4, height: 4, red: 0, green: 0, blue: 0, alpha: 0)
        let groupID = UUID()
        var group = PSDRecord(id: groupID, name: "Stack")
        group.isGroup = true
        var child = PSDRecord(id: UUID(), parentID: groupID, name: "Base")
        child.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        child.image = fill
        let data = try PSDFixture.data(PSDDocument(width: 4, height: 4, resolution: 72, layers: [group, child]), composite: composite)
        #expect(lsctTypes(in: data) == [3, 1])
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        let folder = try #require(imported.layers.first { $0.isGroup })
        #expect(folder.name == "Stack")
        #expect(imported.layers.first { $0.name == "Base" }?.parentID == folder.id)
    }

    @Test func oversizedLayerBoundsAreRejected() throws {
        #expect(throws: ImageImportError.tooLarge) {
            try PSDReader.read(oversizedLayerFile(width: 8, height: 8, layerWidth: 30_000, layerHeight: 30_000), remainingPixels: 50)
        }
        let fill = try colorImage(width: 20, height: 20, red: 1, green: 0, blue: 0)
        var layer = PSDRecord(id: UUID(), name: "Huge")
        layer.bounds = CGRect(x: 0, y: 0, width: 20, height: 20)
        layer.image = fill
        let data = try PSDFixture.data(PSDDocument(width: 20, height: 20, resolution: 72, layers: [layer]), composite: fill)
        #expect(throws: ImageImportError.tooLarge) {
            try PSDReader.read(data, remainingPixels: 50)
        }
    }

    @Test func unusedSpotChannelsAreSkippedBeforeDecode() throws {
        let pixels = Data(repeating: 255, count: 4)
        var channels: [(id: Int16, payload: Data)] = []
        for id: Int16 in [-1, 0, 1, 2] {
            channels.append((id, rawChannel(pixels)))
        }
        // Compression 99 would throw if these planes were unpacked. 52 extras fill the 56-channel cap.
        let bogus = Data([0, 99, 0, 0])
        for id in Int16(3)...Int16(54) {
            channels.append((id, bogus))
        }
        let document = try PSDReader.read(layerFile(layerWidth: 2, layerHeight: 2, channels: channels))
        #expect(document.layers.count == 1)
        #expect(document.layers[0].image?.width == 2)
        #expect(document.layers[0].image?.height == 2)
    }

    @Test func unsupportedCompressionOnColorChannelsIsStillRejected() {
        let pixels = Data(repeating: 255, count: 4)
        let channels: [(id: Int16, payload: Data)] = [
            (-1, rawChannel(pixels)),
            (0, Data([0, 99, 0, 0])),
            (1, rawChannel(pixels)),
            (2, rawChannel(pixels)),
        ]
        #expect(throws: PSDError.unsupportedCompression) {
            try PSDReader.read(layerFile(layerWidth: 2, layerHeight: 2, channels: channels))
        }
    }

    @Test func matchesRequiresPhotoshopMagic() throws {
        let jpeg = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).psd")
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: jpeg)
        defer { try? FileManager.default.removeItem(at: jpeg) }
        #expect(!PSDReader.matches(jpeg))
        let psd = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).bin")
        try Data("8BPS".utf8).write(to: psd)
        defer { try? FileManager.default.removeItem(at: psd) }
        #expect(PSDReader.matches(psd))
    }

    /// Was unknownBlendProducesConversionReport with "vLit". Vivid Light is supported now, so an
    /// unsupported key has to be one Photoshop has and Compositor doesn't: Dissolve scatters pixels
    /// by opacity rather than blending, and comes in as Normal.
    @Test func unsupportedBlendProducesConversionReport() throws {
        let fill = try colorImage(width: 2, height: 2, red: 1, green: 0, blue: 0)
        var layer = PSDRecord(id: UUID(), name: "Dissolved")
        layer.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        layer.image = fill
        layer.blendKey = "diss"
        let data = try PSDFixture.data(PSDDocument(width: 2, height: 2, resolution: 72, layers: [layer]), composite: fill)
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        #expect(!imported.conversions.isEmpty)
        #expect(imported.conversions.contains { $0.layerName == "Dissolved" && $0.message.contains("diss") })
        #expect(imported.layers.first?.blendMode == .normal)
    }

    @Test func softLightImportsWithoutConversion() throws {
        let fill = try colorImage(width: 2, height: 2, red: 1, green: 0, blue: 0)
        var layer = PSDRecord(id: UUID(), name: "Soft")
        layer.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        layer.image = fill
        layer.blendKey = "sLit"
        let data = try PSDFixture.data(PSDDocument(width: 2, height: 2, resolution: 72, layers: [layer]), composite: fill)
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        #expect(imported.conversions.isEmpty)
        #expect(imported.layers.first?.blendMode == .softLight)
    }

    /// Was folderOpacityIsReportedBecauseProjectsCannotStoreIt, which asserted the folder came in
    /// fully opaque with a conversion note. Folders took an opacity of their own in 1.1.6.
    @Test func folderOpacityImportsOntoTheFolder() throws {
        let fill = try colorImage(width: 2, height: 2, red: 0, green: 1, blue: 0)
        let groupID = UUID()
        var group = PSDRecord(id: groupID, name: "Stack")
        group.isGroup = true
        group.opacity = 0.5
        var child = PSDRecord(id: UUID(), parentID: groupID, name: "Base")
        child.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        child.image = fill
        let data = try PSDFixture.data(PSDDocument(width: 4, height: 4, resolution: 72, layers: [group, child]), composite: fill)
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        let folder = try #require(imported.layers.first { $0.isGroup })
        // Photoshop stores opacity in one byte, so a half-opaque group comes back as 128/255.
        #expect(abs(folder.opacity - 0.5) < 0.01)
        #expect(!imported.conversions.contains { $0.layerName == "Stack" && $0.message.contains("opacity") })
    }

    @Test func unsupportedHeadersAreRejected() throws {
        #expect(throws: PSDError.unsupportedVersion) { try PSDReader.read(header(version: 3)) }
        #expect(throws: PSDError.unsupportedColorMode) { try PSDReader.read(header(mode: 4)) }
        #expect(throws: PSDError.unsupportedDepth) { try PSDReader.read(header(depth: 16)) }
        #expect(throws: ImageImportError.tooLarge) { try PSDReader.read(header(width: 30_001, height: 10)) }
    }

    @Test func importCreatesDocumentAndExistingCanvasGetsAGroup() async throws {
        let fill = try colorImage(width: 4, height: 2, red: 0, green: 0, blue: 1)
        var layer = PSDRecord(id: UUID(), name: "Sky")
        layer.bounds = CGRect(x: 0, y: 0, width: 4, height: 2)
        layer.image = fill
        let data = try PSDFixture.data(PSDDocument(width: 4, height: 2, resolution: 72, layers: [layer]), composite: fill)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).psd")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        session.confirmConversions = { _ in true }
        await session.importImages([url])
        #expect(session.document?.size == CGSize(width: 4, height: 2))
        #expect(session.document?.layers.map(\.name) == ["Sky"])
        #expect(session.importError == nil)
        await session.importImages([url])
        #expect(session.document?.layers.contains { $0.isGroup && $0.name == url.deletingPathExtension().lastPathComponent } == true)
        #expect(session.document?.layers.filter { $0.name == "Sky" }.count == 2)
    }

    @Test func cancelledConversionLeavesTheDocumentUnchanged() async throws {
        let fill = try colorImage(width: 2, height: 2, red: 1, green: 0, blue: 0)
        var layer = PSDRecord(id: UUID(), name: "Dissolved")
        layer.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        layer.image = fill
        layer.blendKey = "diss"
        let data = try PSDFixture.data(PSDDocument(width: 2, height: 2, resolution: 72, layers: [layer]), composite: fill)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).psd")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        session.confirmConversions = { _ in false }
        await session.importImages([url])
        #expect(session.document == nil)
        #expect(!session.isImporting)
    }

    /// An adjustment Compositor can't apply (Brightness/Contrast) stays in the document as a hidden layer that
    /// keeps its Photoshop data, so nothing is lost and the layer count matches Photoshop's.
    @Test func unsupportedAdjustmentBecomesAHiddenPlaceholder() throws {
        let fill = try colorImage(width: 2, height: 2, red: 1, green: 0, blue: 0)
        var base = PSDRecord(id: UUID(), name: "Base")
        base.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        base.image = fill
        let brit = PSDTaggedBlock(key: "brit", data: Data([0, 20, 0, 10, 0, 127, 0, 0]))
        var brightness = PSDRecord(id: UUID(), name: "Brightness/Contrast 1")
        brightness.opacity = 0.5
        brightness.extras = PSDLayerExtras(blocks: [brit])
        let data = try PSDFixture.data(PSDDocument(width: 2, height: 2, resolution: 72, layers: [base, brightness]), composite: fill)
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        #expect(imported.layers.count == 2)
        let placeholder = try #require(imported.layers.last)
        #expect(placeholder.name == "Brightness/Contrast 1")
        #expect(placeholder.isVisible == false)
        #expect(placeholder.asset == nil && placeholder.adjustment == nil && !placeholder.isGroup)
        #expect(placeholder.psdExtras?.placeholder == "adjustment:brit")
        #expect(placeholder.psdExtras?.importedVisible == true)
        #expect(placeholder.psdExtras?.blocks.contains(brit) == true)
        #expect(placeholder.isPhotoshopPlaceholder)
        #expect(abs(placeholder.opacity - 0.5) < 0.01)
        #expect(imported.conversions.contains { $0.layerName == "Brightness/Contrast 1" && $0.message.contains("hidden") })
        #expect(MCPValues.kind(of: placeholder) == "placeholder")

        // Showing it draws nothing, and it can't be painted on.
        let session = EditorSession()
        session.document = CanvasDocument(width: 2, height: 2, layers: imported.layers)
        session.activeLayerID = imported.layers[0].id
        #expect(session.canPaint)
        session.document?.layers[1].isVisible = true
        session.activeLayerID = placeholder.id
        #expect(!session.canPaint)
    }

    /// Standalone `SoCo` fills become editable full-canvas shapes; unsupported gradient/pattern fills and `clrL`
    /// adjustments remain hidden placeholders, while a vector shape keeps its own fill and outline.
    @Test func solidFillLayersBecomeEditableAndOtherFillLayersStayPlaceholders() throws {
        let fill = try colorImage(width: 2, height: 2, red: 1, green: 0, blue: 0)
        var base = PSDRecord(id: UUID(), name: "Base")
        base.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        base.image = fill
        var records = [base]
        for key in ["SoCo", "GdFl", "PtFl", "clrL"] {
            var record = PSDRecord(id: UUID(), name: key)
            let block = key == "SoCo" ? solidColor(red: 0, green: 0, blue: 255) : Data(count: 8)
            record.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: key, data: block)])
            records.append(record)
        }
        var shape = PSDRecord(id: UUID(), name: "Shape")
        shape.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "SoCo", data: solidColor(red: 0, green: 0, blue: 255)),
                                               PSDTaggedBlock(key: "vmsk", data: vectorMask(canvas: CGSize(width: 8, height: 8), corners: [
                                                   CGPoint(x: 1, y: 1), CGPoint(x: 6, y: 1), CGPoint(x: 6, y: 6), CGPoint(x: 1, y: 6)]))])
        records.append(shape)
        let data = try PSDFixture.data(PSDDocument(width: 8, height: 8, resolution: 72, layers: records), composite: fill)
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        #expect(imported.layers.map(\.name) == ["Base", "SoCo", "GdFl", "PtFl", "clrL", "Shape"])
        #expect(imported.layers.map { $0.psdExtras?.placeholder } == [nil, nil, "fill:GdFl", "fill:PtFl", "adjustment:clrL", nil])
        let solidFill = try #require(imported.layers[1].liveShape)
        #expect(solidFill.style.kind == .rectangle && solidFill.style.blue == 1)
        #expect(imported.layers[1].transform == LayerTransform(origin: .zero, size: CGSize(width: 8, height: 8)))
        #expect(imported.layers.filter(\.isPhotoshopPlaceholder).allSatisfy { !$0.isVisible && $0.asset == nil })
        #expect(imported.layers.last?.asset != nil)

        // Opening makes the topmost layer that shows active, not a hidden placeholder.
        let session = EditorSession()
        try session.insertPhotoshop(imported, named: "Fills")
        #expect(session.activeLayerID == imported.layers.last?.id)
        let placeholdersOnTop = EditorSession()
        try placeholdersOnTop.insertPhotoshop(PSDImport(width: 8, height: 8, resolution: 72,
                                                        layers: Array(imported.layers.dropLast()), conversions: []), named: "Fills")
        #expect(placeholdersOnTop.activeLayerID == imported.layers[1].id)
    }

    /// Merging never takes a placeholder with it: Merge Down onto or from one, a selection holding one, or a
    /// folder containing one is refused.
    @Test func mergesLeavePlaceholdersAlone() throws {
        let asset = try LiveMaskTests().asset([255, 0, 0, 255])
        let session = EditorSession()
        session.createDocument(width: 4, height: 4)
        let folder = UUID()
        var group = ImageLayer(id: folder, asset: nil, name: "Folder", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 4, height: 4)), isGroup: true)
        group.parentID = nil
        var bottom = ImageLayer(asset: asset, origin: .zero)
        bottom.parentID = folder
        var placeholder = ImageLayer(id: UUID(), asset: nil, name: "Brightness", isVisible: false,
                                     transform: LayerTransform(origin: .zero, size: CGSize(width: 4, height: 4)), parentID: folder,
                                     psdExtras: PSDLayerExtras(importedVisible: true, placeholder: "adjustment:brit"))
        placeholder.parentID = folder
        var top = ImageLayer(asset: asset, origin: .zero)
        top.parentID = folder
        session.document?.layers = [group, bottom, placeholder, top]
        session.activeLayerID = top.id          // Merge Down onto the placeholder
        #expect(!session.canMergeLayers)
        session.activeLayerID = placeholder.id  // Merge Down from it
        #expect(!session.canMergeLayers)
        session.activeLayerID = folder          // Merge Group with it inside
        #expect(!session.canMergeLayers)
        session.activeLayerID = top.id
        session.selectedLayerIDs = [top.id, placeholder.id, bottom.id]
        #expect(!session.canMergeLayers)
        session.mergeLayers()
        #expect(session.document?.layers.count == 4)
        // Without the placeholder in the way, merging works as before.
        session.document?.layers.removeAll { $0.id == placeholder.id }
        session.activeLayerID = top.id
        #expect(session.canMergeLayers)
    }

    /// A placeholder saves to a project and comes back with its Photoshop data and tag.
    @Test func placeholdersSurviveAProjectRoundTrip() async throws {
        let fill = try colorImage(width: 2, height: 2, red: 1, green: 0, blue: 0)
        var base = PSDRecord(id: UUID(), name: "Base")
        base.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        base.image = fill
        var brightness = PSDRecord(id: UUID(), name: "Brightness")
        brightness.isVisible = false
        brightness.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "brit", data: Data([0, 20, 0, 10, 0, 127, 0, 0]))])
        let data = try PSDFixture.data(PSDDocument(width: 2, height: 2, resolution: 72, layers: [base, brightness]), composite: fill)
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        let session = EditorSession()
        try session.insertPhotoshop(imported, named: "Placeholder")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PSDRoundTripTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Placeholder.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let reopened = EditorSession()
        reopened.installProject(try await ProjectStore.shared.load(from: url), from: url)
        let restored = try #require(reopened.document?.layers.last)
        let original = try #require(session.document?.layers.last)
        #expect(restored.id == original.id && restored.name == "Brightness")
        #expect(restored.isPhotoshopPlaceholder && !restored.isVisible && restored.asset == nil)
        #expect(restored.psdExtras == original.psdExtras)
        #expect(restored.psdExtras?.placeholder == "adjustment:brit")
        #expect(restored.psdExtras?.importedVisible == false)
    }

    /// Layer effects and text are kept now (their blocks travel with the layer), so import no longer warns
    /// that they were discarded or flattened.
    @Test func effectsAndTextNoLongerReportLosses() throws {
        let fill = try colorImage(width: 2, height: 2, red: 1, green: 0, blue: 0)
        var effects = PSDRecord(id: UUID(), name: "Glow")
        effects.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        effects.image = fill
        effects.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "lrFX", data: Data([0, 0, 0, 0]))])
        var text = PSDRecord(id: UUID(), name: "Title")
        text.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        text.image = fill
        text.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "tySh", data: Data([0, 1]))])
        let data = try PSDFixture.data(PSDDocument(width: 2, height: 2, resolution: 72, layers: [effects, text]), composite: fill)
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        #expect(imported.layers.count == 2)
        #expect(!imported.conversions.contains { $0.message.contains("discarded") || $0.message.contains("retyped") })
    }

    @Test func vectorMaskIsRasterizedWithFillAndStroke() throws {
        let canvas = CGSize(width: 200, height: 200)
        var extra: [String: Data] = [:]
        extra["vmsk"] = vectorMask(canvas: canvas, corners: [
            CGPoint(x: 120, y: 30), CGPoint(x: 120, y: 80), CGPoint(x: 20, y: 80), CGPoint(x: 20, y: 30)
        ])
        extra["SoCo"] = solidColor(red: 0, green: 110, blue: 255)
        extra["vstk"] = strokeStyle(fill: true, stroke: false, width: 1, red: 255, green: 255, blue: 0)
        let raster = try #require(try PSDVector.raster(extra: extra, canvas: canvas))
        #expect(raster.bounds.width >= 99 && raster.bounds.height >= 49)
        #expect(raster.image.width >= 99 && raster.image.height >= 49)
        extra["vstk"] = strokeStyle(fill: true, stroke: true, width: 10, red: 255, green: 255, blue: 0)
        extra["SoCo"] = solidColor(red: 0, green: 0, blue: 0)
        let stroked = try #require(try PSDVector.raster(extra: extra, canvas: canvas))
        #expect(stroked.bounds.width > raster.bounds.width)
        #expect(stroked.bounds.height > raster.bounds.height)
    }

    @Test func photoshopShapeExtrasRasterizeInPlace() throws {
        let circle = try #require(try PSDVector.raster(extra: PSDVectorFixtures.circle(), canvas: PSDVectorFixtures.canvas))
        #expect(abs(circle.bounds.midX - 618) < 8)
        #expect(abs(circle.bounds.midY - 677) < 8)
        #expect(abs(circle.bounds.width - 328) < 12)
        #expect(abs(circle.bounds.height - 328) < 12)
        let rectangle = try #require(try PSDVector.raster(extra: PSDVectorFixtures.rectangle(), canvas: PSDVectorFixtures.canvas))
        #expect(rectangle.bounds.width > 640)
        #expect(rectangle.bounds.height > 170)
        #expect(abs(rectangle.bounds.midX - 1268) < 20)
        #expect(abs(rectangle.bounds.midY - 244) < 20)
    }

    @Test func fillEllipseImportsAsALiveShape() throws {
        var extra = PSDVectorFixtures.circle()
        extra["vogk"] = originationData(type: 5, rect: CGRect(x: 454, y: 513, width: 328, height: 328))
        let live = try #require(try PSDVector.live(extra: extra, canvas: PSDVectorFixtures.canvas))
        #expect(live.style.kind == .ellipse)
        #expect(abs(live.style.green - 110 / 255) < 0.01)
        #expect(abs(live.style.blue - 1) < 0.01)
        #expect(live.notes.isEmpty)
        // Its stroke is switched off in Photoshop: kept, but it neither draws nor widens the layer.
        #expect(live.style.stroke?.enabled == false && live.style.stroke?.alignment == .center)
        #expect(abs(live.bounds.minX - 454) < 1 && abs(live.bounds.width - 328) < 1)
        var record = PSDRecord(id: UUID(), name: "cercle-bleu")
        record.kind = .vector
        record.image = live.image
        record.bounds = live.bounds
        record.shape = live.style
        let imported = try PSDDocumentBuilder.makeImport(PSDDocument(width: 1920, height: 1080, resolution: 72, layers: [record]))
        #expect(imported.layers.first?.liveShape?.style.kind == .ellipse)
        #expect(imported.conversions.isEmpty)
        #expect(imported.layers.first?.liveShape?.image === imported.layers.first?.asset?.image)
    }

    /// Photoshop's yellow 9.87 px centered stroke comes along live, drawn around the rectangle, with nothing to report.
    @Test func strokedRectangleImportsAsALiveShapeWithItsStroke() throws {
        var extra = PSDVectorFixtures.rectangle()
        extra["vogk"] = originationData(type: 2, rect: CGRect(x: 945, y: 153, width: 646, height: 182), radii: [0, 0, 0, 0])
        let live = try #require(try PSDVector.live(extra: extra, canvas: PSDVectorFixtures.canvas))
        #expect(live.style.kind == .rectangle)
        #expect(live.style.cornerRadius == 0)
        let stroke = try #require(live.style.stroke)
        #expect(stroke.enabled && stroke.alignment == .center && abs(stroke.width - 9.869) < 0.001)
        #expect(stroke.color == PaletteColor(red: 1, green: 1, blue: 0))
        #expect(live.bounds == CGRect(x: 940, y: 148, width: 656, height: 192))
        #expect(live.notes.isEmpty)
        var record = PSDRecord(id: UUID(), name: "rectangle-contour-jaune")
        record.kind = .vector
        record.image = live.image
        record.bounds = live.bounds
        record.shape = live.style
        record.shapeNotes = live.notes
        let imported = try PSDDocumentBuilder.makeImport(PSDDocument(width: 1920, height: 1080, resolution: 72, layers: [record]))
        #expect(imported.layers.first?.liveShape?.style == live.style)
        #expect(imported.conversions.isEmpty)
    }

    @Test func fourSharpCornersInferARectangleWithoutOrigination() throws {
        var extra: [String: Data] = [:]
        extra["vmsk"] = vectorMask(canvas: CGSize(width: 200, height: 200), corners: [
            CGPoint(x: 120, y: 30), CGPoint(x: 120, y: 80), CGPoint(x: 20, y: 80), CGPoint(x: 20, y: 30)
        ])
        extra["SoCo"] = solidColor(red: 0, green: 110, blue: 255)
        extra["vstk"] = strokeStyle(fill: true, stroke: false, width: 1, red: 255, green: 255, blue: 0)
        let live = try #require(try PSDVector.live(extra: extra, canvas: CGSize(width: 200, height: 200)))
        #expect(live.style.kind == .rectangle)
        #expect(live.notes.isEmpty)
        #expect(live.bounds.width >= 99 && live.bounds.height >= 49)
    }

    @Test func hugeOriginationSizeIsRejectedWithoutTrapping() throws {
        var extra: [String: Data] = [:]
        let huge = CGRect(x: 0, y: 0, width: 40_000, height: 40_000)
        extra["vogk"] = originationData(type: 5, rect: huge)
        extra["vmsk"] = PSDFixture.vectorPathBlock(canvas: PSDVectorFixtures.canvas,
                                                   subpaths: [PSDFixture.turnedCorners(of: huge, degrees: 0)])
        extra["SoCo"] = solidColor(red: 0, green: 110, blue: 255)
        extra["vstk"] = strokeStyle(fill: true, stroke: false, width: 1, red: 255, green: 255, blue: 0)
        #expect(throws: PSDVector.TooLargeToDraw.self) {
            try PSDVector.live(extra: extra, canvas: PSDVectorFixtures.canvas)
        }
        // A description far beyond anything its path draws isn't the layer's shape: its pixels stay.
        extra["vogk"] = originationData(type: 5, rect: CGRect(x: 0, y: 0, width: 1e20, height: 1e20))
        #expect(try PSDVector.live(extra: extra, canvas: PSDVectorFixtures.canvas) == nil)
    }

    @Test func nonFiniteOriginationSizeIsIgnored() throws {
        var extra: [String: Data] = [:]
        extra["vogk"] = originationData(type: 5, rect: CGRect(x: 10, y: 10, width: CGFloat.infinity, height: 100))
        extra["SoCo"] = solidColor(red: 0, green: 110, blue: 255)
        extra["vstk"] = strokeStyle(fill: true, stroke: false, width: 1, red: 255, green: 255, blue: 0)
        #expect(try PSDVector.live(extra: extra, canvas: PSDVectorFixtures.canvas) == nil)
    }

    @Test func hugeStrokeWidthIsRejectedWithoutTrapping() throws {
        var extra: [String: Data] = [:]
        extra["vmsk"] = vectorMask(canvas: CGSize(width: 200, height: 200), corners: [
            CGPoint(x: 120, y: 30), CGPoint(x: 120, y: 80), CGPoint(x: 20, y: 80), CGPoint(x: 20, y: 30)
        ])
        extra["SoCo"] = solidColor(red: 0, green: 0, blue: 0)
        extra["vstk"] = strokeStyle(fill: true, stroke: true, width: 1e20, red: 255, green: 255, blue: 0)
        #expect(throws: ImageImportError.tooLarge) {
            try PSDVector.raster(extra: extra, canvas: CGSize(width: 200, height: 200))
        }
    }

    /// Photoshop keeps a shape's fill in `vscg` rather than `SoCo`: read from a file, the rounded rectangle is live,
    /// its style is what import recorded, and every vector block is kept to be written back.
    @Test func vscgOnlyRectangleImportsAsALiveShape() throws {
        let rect = CGRect(x: 20, y: 30, width: 100, height: 50)
        var record = PSDRecord(id: UUID(), name: "Button")
        record.image = try colorImage(width: 100, height: 50, red: 1, green: 0, blue: 0)
        record.bounds = rect
        record.extras = PSDLayerExtras(blocks: [
            PSDTaggedBlock(key: "vscg", data: PSDFixture.vectorContentBlock(red: 255, green: 0, blue: 0)),
            PSDTaggedBlock(key: "vsms", data: vectorMask(canvas: CGSize(width: 200, height: 120), corners: [
                CGPoint(x: 120, y: 30), CGPoint(x: 120, y: 80), CGPoint(x: 20, y: 80), CGPoint(x: 20, y: 30)])),
            PSDTaggedBlock(key: "vogk", data: PSDFixture.originationBlock([
                PSDFixture.rectangleOrigination(type: 2, rect: rect, radii: [8, 8, 8, 8])])),
            PSDTaggedBlock(key: "vstk", data: PSDFixture.shapeStrokeBlock(enabled: false, width: 3, color: (0, 0, 255))),
        ])
        let data = try PSDFixture.data(PSDDocument(width: 200, height: 120, resolution: 72, layers: [record]),
                                       composite: try colorImage(width: 200, height: 120, red: 1, green: 1, blue: 1))
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        let layer = try #require(imported.layers.first)
        let shape = try #require(layer.liveShape)
        #expect(shape.style.kind == .rectangle && shape.style.cornerRadius == 8)
        #expect(shape.style.color == PaletteColor(red: 1, green: 0, blue: 0))
        #expect(layer.transform.origin == rect.origin && layer.transform.size == rect.size)
        #expect(layer.psdExtras?.importedShape == shape.style)
        #expect(layer.psdExtras?.blocks.map(\.key).filter { $0.hasPrefix("v") } == ["vscg", "vsms", "vogk", "vstk"])
        #expect(imported.conversions.isEmpty)
        // A gradient fill has no single color, so that shape stays Photoshop's pixels.
        var extra: [String: Data] = [:]
        extra["vogk"] = PSDFixture.originationBlock([PSDFixture.rectangleOrigination(type: 1, rect: rect)])
        extra["vscg"] = PSDFixture.vectorContentBlock(key: "GdFl", red: 255, green: 0, blue: 0)
        #expect(try PSDVector.live(extra: extra, canvas: CGSize(width: 200, height: 120)) == nil)
    }

    /// Radii that can't be a corner (infinite, not a number, negative) make no live shape: the layer keeps
    /// Photoshop's pixels, and the document still saves as a project (an infinite radius can't be encoded).
    @Test func aRoundedRectangleWithoutUsableRadiiStaysPixels() async throws {
        let rect = CGRect(x: 20, y: 30, width: 100, height: 50), canvas = CGSize(width: 200, height: 120)
        func blocks(_ radius: Double) -> [PSDTaggedBlock] {
            [PSDTaggedBlock(key: "vscg", data: PSDFixture.vectorContentBlock(red: 255, green: 0, blue: 0)),
             PSDTaggedBlock(key: "vsms", data: vectorMask(canvas: canvas, corners: [
                CGPoint(x: 120, y: 30), CGPoint(x: 120, y: 80), CGPoint(x: 20, y: 80), CGPoint(x: 20, y: 30)])),
             PSDTaggedBlock(key: "vogk", data: PSDFixture.originationBlock([
                PSDFixture.rectangleOrigination(type: 2, rect: rect, radii: Array(repeating: radius, count: 4))]))]
        }
        for radius in [Double.infinity, .nan, -4] {
            let extra = Dictionary(uniqueKeysWithValues: blocks(radius).map { ($0.key, $0.data) })
            #expect(try PSDVector.live(extra: extra, canvas: canvas) == nil, "radius \(radius)")
        }
        var record = PSDRecord(id: UUID(), name: "Button")
        record.image = try colorImage(width: 100, height: 50, red: 1, green: 0, blue: 0)
        record.bounds = rect
        record.extras = PSDLayerExtras(blocks: blocks(.infinity))
        let data = try PSDFixture.data(PSDDocument(width: Int(canvas.width), height: Int(canvas.height), resolution: 72, layers: [record]),
                                       composite: try colorImage(width: Int(canvas.width), height: Int(canvas.height), red: 1, green: 1, blue: 1))
        let session = EditorSession()
        try session.insertPhotoshop(try PSDDocumentBuilder.makeImport(try PSDReader.read(data)), named: "Button")
        #expect(session.document?.layers.first?.liveShape == nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PSDRoundTripTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: root.appendingPathComponent("Button.comp"))
    }

    @Test func photoshopLineImportsAsALiveLineWithItsEndsAndWeight() throws {
        let start = CGPoint(x: 10, y: 20), end = CGPoint(x: 110, y: 70)
        var extra: [String: Data] = [:]
        extra["vogk"] = PSDFixture.originationBlock([PSDFixture.lineOrigination(start: start, end: end, weight: 6)])
        extra["vscg"] = PSDFixture.vectorContentBlock(red: 0, green: 0, blue: 255)
        extra["vsms"] = PSDFixture.vectorPathBlock(canvas: CGSize(width: 200, height: 120),
                                                   subpaths: [PSDFixture.lineOutline(start: start, end: end, weight: 6)])
        let live = try #require(try PSDVector.live(extra: extra, canvas: CGSize(width: 200, height: 120)))
        #expect(live.style.kind == .line && live.style.lineWidth == 6)
        #expect(live.style.color == PaletteColor(red: 0, green: 0, blue: 1))
        // The layer is the ends' box with room for the weight; the ends are fractions of it.
        #expect(live.bounds == CGRect(x: 7, y: 17, width: 106, height: 56))
        func placed(_ unit: CGPoint?) throws -> CGPoint {
            let unit = try #require(unit)
            return CGPoint(x: live.bounds.minX + unit.x * live.bounds.width, y: live.bounds.minY + unit.y * live.bounds.height)
        }
        let placedStart = try placed(live.style.start), placedEnd = try placed(live.style.end)
        #expect(hypot(placedStart.x - start.x, placedStart.y - start.y) < 1e-9)
        #expect(hypot(placedEnd.x - end.x, placedEnd.y - end.y) < 1e-9)
        #expect(live.notes.isEmpty)
        // Drawn between them: its middle is blue, a corner of its box is clear.
        #expect(try rgba(live.image, x: 53, y: 28) == [0, 0, 255, 255])
        #expect(try rgba(live.image, x: 100, y: 5)[3] == 0)
    }

    /// Photoshop draws a line's stroke around the line; in the line's own color that is simply a wider line. A
    /// stroke of another color isn't something a Compositor line draws, so that line keeps its pixels.
    @Test func aSameColorStrokeWidensALine() throws {
        var extra: [String: Data] = [:]
        extra["vogk"] = PSDFixture.originationBlock([
            PSDFixture.lineOrigination(start: CGPoint(x: 10, y: 20), end: CGPoint(x: 110, y: 70), weight: 6)])
        extra["vscg"] = PSDFixture.vectorContentBlock(red: 0, green: 0, blue: 255)
        extra["vsms"] = PSDFixture.vectorPathBlock(canvas: CGSize(width: 200, height: 120), subpaths: [
            PSDFixture.lineOutline(start: CGPoint(x: 10, y: 20), end: CGPoint(x: 110, y: 70), weight: 6)])
        extra["vstk"] = PSDFixture.shapeStrokeBlock(enabled: true, width: 4, color: (0, 0, 255))
        let live = try #require(try PSDVector.live(extra: extra, canvas: CGSize(width: 200, height: 120)))
        #expect(live.style.lineWidth == 6 && live.style.stroke?.enabled == true && live.style.stroke?.width == 4)
        #expect(live.bounds == CGRect(x: 5, y: 15, width: 110, height: 60))
        // 5 px either side of the line's middle is covered (the 6 px weight plus 2 px of stroke on each side), so a
        // pixel about 4 px across from it is solid where the bare line would leave it clear.
        let length: CGFloat = hypot(100, 50)
        let middle = CGPoint(x: 55, y: 30), across = CGPoint(x: -50 / length, y: 100 / length)
        let edge = CGPoint(x: middle.x + across.x * 4, y: middle.y + across.y * 4)
        #expect(try rgba(live.image, x: Int(edge.x), y: Int(edge.y)) == [0, 0, 255, 255])
        extra["vstk"] = PSDFixture.shapeStrokeBlock(enabled: true, width: 4, color: (255, 0, 0))
        #expect(try PSDVector.live(extra: extra, canvas: CGSize(width: 200, height: 120)) == nil)
    }

    /// Live shapes take exactly one origination item that Photoshop still stands by: two lines on one layer, an
    /// invalidated shape and a line with arrowheads stay Photoshop's pixels (with their blocks), even where the path
    /// alone would look like a rectangle.
    @Test func twoItemOriginationInvalidatedShapesAndArrowsRasterize() throws {
        let canvas = CGSize(width: 200, height: 120)
        let fill = PSDFixture.vectorContentBlock(red: 0, green: 0, blue: 255)
        let lines = PSDFixture.originationBlock([
            PSDFixture.lineOrigination(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 100, y: 10), weight: 2),
            PSDFixture.lineOrigination(start: CGPoint(x: 10, y: 40), end: CGPoint(x: 100, y: 40), weight: 2)])
        #expect(try PSDVector.live(extra: ["vogk": lines, "vscg": fill], canvas: canvas) == nil)
        let rectangle = vectorMask(canvas: canvas, corners: [
            CGPoint(x: 120, y: 30), CGPoint(x: 120, y: 80), CGPoint(x: 20, y: 80), CGPoint(x: 20, y: 30)])
        let invalidated = PSDFixture.originationBlock([
            PSDFixture.rectangleOrigination(type: 1, rect: CGRect(x: 20, y: 30, width: 100, height: 50), invalidated: true)])
        #expect(try PSDVector.live(extra: ["vogk": invalidated, "vscg": fill, "vmsk": rectangle], canvas: canvas) == nil)
        let arrow = PSDFixture.originationBlock([
            PSDFixture.lineOrigination(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 100, y: 50), weight: 2, arrowEnd: true)])
        #expect(try PSDVector.live(extra: ["vogk": arrow, "vscg": fill], canvas: canvas) == nil)

        var records: [PSDRecord] = []
        for (name, origination) in [("Two lines", lines), ("Arrow", arrow)] {
            var record = PSDRecord(id: UUID(), name: name)
            record.image = try colorImage(width: 90, height: 40, red: 0, green: 0, blue: 1)
            record.bounds = CGRect(x: 10, y: 10, width: 90, height: 40)
            record.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "vscg", data: fill),
                                                    PSDTaggedBlock(key: "vogk", data: origination)])
            records.append(record)
        }
        let data = try PSDFixture.data(PSDDocument(width: 200, height: 120, resolution: 72, layers: records),
                                       composite: try colorImage(width: 200, height: 120, red: 1, green: 1, blue: 1))
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        #expect(imported.layers.map { $0.liveShape == nil } == [true, true])
        #expect(imported.layers.map { $0.asset?.image.width } == [90, 90])
        #expect(imported.layers.map { $0.psdExtras?.blocks.map(\.key).contains("vogk") } == [true, true])
        #expect(imported.conversions.contains { $0.layerName == "Two lines" && $0.message.contains("rasterized") })
        #expect(imported.conversions.contains { $0.layerName == "Arrow" && $0.message.contains("rrowhead") })
    }

    /// A live shape turned 30° with Free Transform: its path is turned, and `Trnf` and `keyOriginBoxCorners` may
    /// record the turn, while `keyOriginShapeBBox` can only hold an axis-aligned box. Whichever of those shows the
    /// turn, the shape stays Photoshop's pixels instead of coming back unturned; a shape that was only moved is live.
    @Test func rotatedRectanglesAndEllipsesStayPixels() throws {
        let canvas = CGSize(width: 200, height: 120)
        let rect = CGRect(x: 60, y: 40, width: 80, height: 40)
        let fill = PSDFixture.vectorContentBlock(red: 0, green: 0, blue: 255)
        let boxCorners = PSDFixture.turnedCorners(of: rect, degrees: 0)
        let turnedCorners = PSDFixture.turnedCorners(of: rect, degrees: 30)
        let boxPath = PSDFixture.vectorPathBlock(canvas: canvas, subpaths: [boxCorners])
        let turnedPath = PSDFixture.vectorPathBlock(canvas: canvas, subpaths: [turnedCorners])
        let turn = CGAffineTransform(translationX: rect.midX, y: rect.midY).rotated(by: .pi / 6)
            .translatedBy(x: -rect.midX, y: -rect.midY)
        func shape(type: Int32 = 1, transform: CGAffineTransform? = nil, corners: [CGPoint]? = nil,
                   path: Data?) -> [String: Data] {
            var extra = ["vscg": fill, "vogk": PSDFixture.originationBlock([PSDFixture.transformedOrigination(
                PSDFixture.rectangleOrigination(type: type, rect: rect), transform: transform, corners: corners)])]
            extra["vsms"] = path
            return extra
        }
        // As Photoshop leaves it: path, `Trnf` and box corners all turned.
        for type: Int32 in [1, 2, 5] {
            #expect(try PSDVector.live(extra: shape(type: type, transform: turn, corners: turnedCorners, path: turnedPath),
                                       canvas: canvas) == nil)
        }
        // Each record of the turn is enough on its own.
        #expect(try PSDVector.live(extra: shape(transform: turn, path: boxPath), canvas: canvas) == nil)
        #expect(try PSDVector.live(extra: shape(type: 5, transform: turn, path: boxPath), canvas: canvas) == nil)
        #expect(try PSDVector.live(extra: shape(corners: turnedCorners, path: boxPath), canvas: canvas) == nil)
        #expect(try PSDVector.live(extra: shape(path: turnedPath), canvas: canvas) == nil)
        #expect(try PSDVector.live(extra: shape(type: 5, path: turnedPath), canvas: canvas) == nil)
        // Nor is the description trusted without a path to check it against, or against a path that is more than
        // the one shape (a second subpath, as a hole cut into it) or that fills something else (inverted, disabled).
        #expect(try PSDVector.live(extra: shape(path: nil), canvas: canvas) == nil)
        let hole = PSDFixture.turnedCorners(of: rect.insetBy(dx: 20, dy: 10), degrees: 0)
        #expect(try PSDVector.live(extra: shape(path: PSDFixture.vectorPathBlock(canvas: canvas, subpaths: [boxCorners, hole])),
                                   canvas: canvas) == nil)
        for flags: UInt32 in [1, 4] {
            #expect(try PSDVector.live(extra: shape(path: PSDFixture.vectorPathBlock(canvas: canvas, subpaths: [boxCorners],
                                                                                     flags: flags)), canvas: canvas) == nil)
        }
        // A path of four sharp corners is only a rectangle when they are its box's corners, vogk or not.
        #expect(try PSDVector.live(extra: ["vscg": fill, "vsms": turnedPath], canvas: canvas) == nil)
        #expect(try PSDVector.live(extra: ["vscg": fill, "vsms": boxPath], canvas: canvas)?.style.kind == .rectangle)
        // Moved only: a translation in `Trnf`, the box corners at the box, and the path drawing the box.
        let moved = try #require(try PSDVector.live(extra: shape(transform: CGAffineTransform(translationX: 12, y: -7),
                                                                 corners: boxCorners, path: boxPath), canvas: canvas))
        #expect(moved.style.kind == .rectangle && moved.bounds == rect)
        let ellipse = try #require(try PSDVector.live(extra: shape(type: 5, transform: .identity, corners: boxCorners,
                                                                   path: boxPath), canvas: canvas))
        #expect(ellipse.style.kind == .ellipse && ellipse.bounds == rect)

        // Read from a file, the turned rectangle keeps Photoshop's pixels and every vector block.
        var record = PSDRecord(id: UUID(), name: "Turned")
        record.image = try colorImage(width: 90, height: 75, red: 0, green: 0, blue: 1)
        record.bounds = CGRect(x: 55, y: 23, width: 90, height: 75)
        record.extras = PSDLayerExtras(blocks: shape(transform: turn, corners: turnedCorners, path: turnedPath)
            .sorted { $0.key < $1.key }.map { PSDTaggedBlock(key: $0.key, data: $0.value) })
        let data = try PSDFixture.data(PSDDocument(width: 200, height: 120, resolution: 72, layers: [record]),
                                       composite: try colorImage(width: 200, height: 120, red: 1, green: 1, blue: 1))
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        let layer = try #require(imported.layers.first)
        #expect(layer.liveShape == nil && layer.psdExtras?.importedShape == nil)
        #expect(layer.asset?.image.width == 90 && layer.asset?.image.height == 75)
        #expect(layer.psdExtras?.blocks.map(\.key).filter { $0.hasPrefix("v") } == ["vogk", "vscg", "vsms"])
        #expect(imported.conversions.contains { $0.layerName == "Turned" && $0.message.contains("rasterized") })
    }

    /// Scaled with Free Transform, a live shape's box and box corners move to where it now is and `Trnf` records the
    /// scale, as in a real file's rectangle stretched by under 1%. Upright, an ellipse or a rectangle with square
    /// corners is still that shape and stays live; rounded corners (whose radii may not have been scaled), a flip,
    /// or a path that isn't the box leave it as pixels.
    @Test func scaledSquareRectanglesAndEllipsesStayLive() throws {
        let canvas = CGSize(width: 200, height: 120)
        let rect = CGRect(x: 60, y: 40, width: 80, height: 40)
        let fill = PSDFixture.vectorContentBlock(red: 0, green: 0, blue: 255)
        let boxCorners = PSDFixture.turnedCorners(of: rect, degrees: 0)
        let boxPath = PSDFixture.vectorPathBlock(canvas: canvas, subpaths: [boxCorners])
        let stretch = CGAffineTransform(a: 1.007, b: 0, c: 0, d: 1.0061, tx: -5.03, ty: -6.57)
        func shape(type: Int32 = 1, radii: [Double] = [], transform: CGAffineTransform, path: Data) -> [String: Data] {
            ["vscg": fill, "vsms": path, "vogk": PSDFixture.originationBlock([PSDFixture.transformedOrigination(
                PSDFixture.rectangleOrigination(type: type, rect: rect, radii: radii), transform: transform, corners: boxCorners)])]
        }
        let rectangle = try #require(try PSDVector.live(extra: shape(transform: stretch, path: boxPath), canvas: canvas))
        #expect(rectangle.style.kind == .rectangle && rectangle.bounds == rect)
        let ellipse = try #require(try PSDVector.live(extra: shape(type: 5, transform: stretch, path: boxPath), canvas: canvas))
        #expect(ellipse.style.kind == .ellipse && ellipse.bounds == rect)
        #expect(try PSDVector.live(extra: shape(transform: CGAffineTransform(scaleX: 2, y: 0.5), path: boxPath),
                                   canvas: canvas)?.style.kind == .rectangle)
        // Radii of 0 are square corners.
        #expect(try PSDVector.live(extra: shape(radii: [0, 0, 0, 0], transform: stretch, path: boxPath), canvas: canvas) != nil)
        // Rounded corners stay live when only moved, as before, and become pixels once scaled.
        for type: Int32 in [1, 2] {
            #expect(try PSDVector.live(extra: shape(type: type, radii: [8, 8, 8, 8], transform: stretch, path: boxPath),
                                       canvas: canvas) == nil)
            #expect(try PSDVector.live(extra: shape(type: type, radii: [8, 8, 8, 8], transform: CGAffineTransform(translationX: 3, y: 2),
                                                    path: boxPath), canvas: canvas)?.style.cornerRadius == 8)
        }
        // Flipped, or scaled somewhere the path isn't: pixels.
        #expect(try PSDVector.live(extra: shape(transform: CGAffineTransform(scaleX: -1, y: 1), path: boxPath), canvas: canvas) == nil)
        #expect(try PSDVector.live(extra: shape(type: 5, transform: CGAffineTransform(scaleX: 1, y: -1), path: boxPath), canvas: canvas) == nil)
        let elsewhere = PSDFixture.vectorPathBlock(canvas: canvas, subpaths: [PSDFixture.turnedCorners(of: rect.offsetBy(dx: 10, dy: 0), degrees: 0)])
        #expect(try PSDVector.live(extra: shape(transform: stretch, path: elsewhere), canvas: canvas) == nil)
    }

    /// A line's `vogk` keeps the ends it was drawn with. Its path must run between them within half its weight;
    /// turned about its middle, or mirrored into the same box, it stays pixels.
    @Test func linesWhosePathRunsElsewhereStayPixels() throws {
        let canvas = CGSize(width: 200, height: 120)
        let fill = PSDFixture.vectorContentBlock(red: 0, green: 0, blue: 255)
        func line(from start: CGPoint, to end: CGPoint, path: [CGPoint], open: Bool = false) -> [String: Data] {
            ["vscg": fill,
             "vogk": PSDFixture.originationBlock([PSDFixture.lineOrigination(start: start, end: end, weight: 4)]),
             "vsms": PSDFixture.vectorPathBlock(canvas: canvas, subpaths: [path], open: open)]
        }
        let start = CGPoint(x: 40, y: 60), end = CGPoint(x: 160, y: 60)
        let turn = CGAffineTransform(translationX: 100, y: 60).rotated(by: .pi / 6).translatedBy(x: -100, y: -60)
        let turned = PSDFixture.lineOutline(start: start.applying(turn), end: end.applying(turn), weight: 4)
        #expect(try PSDVector.live(extra: line(from: start, to: end, path: turned), canvas: canvas) == nil)
        let a = CGPoint(x: 20, y: 20), b = CGPoint(x: 100, y: 100)
        let mirrored = PSDFixture.lineOutline(start: CGPoint(x: 100, y: 20), end: CGPoint(x: 20, y: 100), weight: 4)
        #expect(try PSDVector.live(extra: line(from: a, to: b, path: mirrored), canvas: canvas) == nil)
        // Shorter than its ends, or bent away from the line between them.
        let short = PSDFixture.lineOutline(start: start, end: CGPoint(x: 100, y: 60), weight: 4)
        #expect(try PSDVector.live(extra: line(from: start, to: end, path: short), canvas: canvas) == nil)
        #expect(try PSDVector.live(extra: line(from: a, to: b, path: [a, CGPoint(x: 100, y: 20), b], open: true),
                                   canvas: canvas) == nil)
        // Its own outline, or an open path along it, is the line.
        let outlined = try #require(try PSDVector.live(
            extra: line(from: start, to: end, path: PSDFixture.lineOutline(start: start, end: end, weight: 4)), canvas: canvas))
        #expect(outlined.style.kind == .line && outlined.bounds == CGRect(x: 38, y: 58, width: 124, height: 4))
        let open = try #require(try PSDVector.live(extra: line(from: a, to: b, path: [a, b], open: true), canvas: canvas))
        #expect(open.style.kind == .line && open.bounds == CGRect(x: 18, y: 18, width: 84, height: 84))
    }

    /// A closed subpath ends with the curve from its last knot back to its first, so a rasterized circle is round
    /// in every quarter rather than cut straight across the last one.
    @Test func rasterizedClosedPathsCloseWithTheirLastCurve() throws {
        var extra = PSDVectorFixtures.circle()
        extra["vogk"] = nil
        let circle = try #require(try PSDVector.raster(extra: extra, canvas: PSDVectorFixtures.canvas))
        // The circle is 328 px across, centered on (618, 677). 110 px along each diagonal from its center is inside
        // it, and some 40 px beyond the straight chord between the two anchors of that quarter.
        let center = CGPoint(x: 618, y: 677)
        #expect(abs(circle.bounds.midX - center.x) < 1 && abs(circle.bounds.midY - center.y) < 1)
        for dx: CGFloat in [-110, 110] {
            for dy: CGFloat in [-110, 110] {
                let x = Int(center.x + dx - circle.bounds.minX), y = Int(center.y + dy - circle.bounds.minY)
                #expect(try rgba(circle.image, x: x, y: y)[3] == 255, "quarter \(dx), \(dy)")
            }
        }
    }

    @Test func disabledShapeStrokeIsStoredAndNotDrawn() throws {
        let live = try #require(try PSDVector.live(extra: strokedRectangle(enabled: false), canvas: CGSize(width: 200, height: 120)))
        #expect(live.style.stroke == ShapeStroke(enabled: false, width: 10, red: 1, green: 1, blue: 0, alignment: .center))
        #expect(live.bounds == CGRect(x: 20, y: 30, width: 100, height: 50))
        #expect(try rgba(live.image, x: 0, y: 25) == [0, 0, 255, 255])
        #expect(try rgba(live.image, x: 50, y: 0) == [0, 0, 255, 255])
        #expect(live.notes.isEmpty)
    }

    /// A centered stroke reaches half its width beyond the shape, so the layer grows by its width; an outside
    /// stroke grows it by twice that, an inside one not at all.
    @Test func enabledCenterStrokeGrowsTheBoxByItsWidth() throws {
        let canvas = CGSize(width: 200, height: 120)
        let live = try #require(try PSDVector.live(extra: strokedRectangle(enabled: true), canvas: canvas))
        #expect(live.style.stroke == ShapeStroke(enabled: true, width: 10, red: 1, green: 1, blue: 0, alignment: .center))
        #expect(live.bounds == CGRect(x: 15, y: 25, width: 110, height: 60))
        #expect(try rgba(live.image, x: 1, y: 30) == [255, 255, 0, 255])
        #expect(try rgba(live.image, x: 9, y: 30) == [255, 255, 0, 255])
        #expect(try rgba(live.image, x: 11, y: 30) == [0, 0, 255, 255])
        #expect(try rgba(live.image, x: 55, y: 30) == [0, 0, 255, 255])
        #expect(live.notes.isEmpty)
        let outside = try #require(try PSDVector.live(extra: strokedRectangle(enabled: true, alignment: "strokeStyleAlignOutside"), canvas: canvas))
        #expect(outside.style.stroke?.alignment == .outside && outside.bounds == CGRect(x: 10, y: 20, width: 120, height: 70))
        let inside = try #require(try PSDVector.live(extra: strokedRectangle(enabled: true, alignment: "strokeStyleAlignInside"), canvas: canvas))
        #expect(inside.style.stroke?.alignment == .inside && inside.bounds == CGRect(x: 20, y: 30, width: 100, height: 50))
        #expect(try rgba(inside.image, x: 9, y: 25) == [255, 255, 0, 255])
        #expect(try rgba(inside.image, x: 11, y: 25) == [0, 0, 255, 255])
        // A stroke Compositor can't draw as Photoshop does (dashed, see-through) leaves the shape as pixels.
        #expect(try PSDVector.live(extra: strokedRectangle(enabled: true, dashes: [2, 1]), canvas: canvas) == nil)
        #expect(try PSDVector.live(extra: strokedRectangle(enabled: true, opacity: 50), canvas: canvas) == nil)
    }

    /// A mask Photoshop stores in a rectangle of its own lies there on the document, not stretched over its layer.
    /// Inside the layer, it is padded with its default color to cover the layer, so it keeps covering it.
    @Test func aMaskOffsetFromItsLayerImportsWhereItLies() async throws {
        // White with a black 4 × 4 center, so what lies outside the mask shows.
        let mask = try centeredMask(size: 8, edge: 1, center: 0)
        var offset = PSDRecord(id: UUID(), name: "Offset")
        offset.bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
        offset.image = try colorImage(width: 40, height: 40, red: 1, green: 0, blue: 0)
        offset.mask = mask
        var covering = PSDRecord(id: UUID(), name: "Covering")
        covering.bounds = CGRect(x: 50, y: 0, width: 8, height: 8)
        covering.image = try colorImage(width: 8, height: 8, red: 0, green: 1, blue: 0)
        covering.mask = mask
        let composite = try colorImage(width: 80, height: 40, red: 0, green: 0, blue: 0, alpha: 0)
        var data = try PSDFixture.data(PSDDocument(width: 80, height: 40, resolution: 72, layers: [offset, covering]), composite: composite)
        // The fixture stores each mask at its layer's top-left; Photoshop's rectangle is 10 right and 20 down of it.
        data = try movingMask(in: data, at: CGRect(x: 0, y: 0, width: 8, height: 8), by: CGPoint(x: 10, y: 20))
        let document = try PSDReader.read(data)
        #expect(document.layers.map(\.maskBounds) == [CGRect(x: 10, y: 20, width: 8, height: 8), CGRect(x: 50, y: 0, width: 8, height: 8)])
        let imported = try PSDDocumentBuilder.makeImport(document)
        // Padded with the default color (white here) to the layer's 40 × 40, it covers the layer; the rectangle
        // Photoshop stored is kept, and crops back to exactly the stored pixels.
        let padded = try #require(imported.layers[0].mask)
        #expect(padded.placement == nil)
        #expect(padded.asset.image.width == 40 && padded.asset.image.height == 40)
        let stored = CGRect(x: 10, y: 20, width: 8, height: 8)
        #expect(imported.layers[0].psdExtras?.importedMaskRect == stored)
        #expect(try maskBytes(#require(padded.asset.image.cropping(to: stored))) == maskBytes(mask))
        #expect(try maskBytes(padded.asset.image)[0] == 255)
        // A mask in its layer's own rectangle is the stored pixels, covering the layer as before.
        #expect(imported.layers[1].mask?.placement == nil && imported.layers[1].mask?.asset.image.width == 8)
        #expect(imported.layers[1].psdExtras?.importedMaskRect == nil)

        let session = EditorSession()
        try session.insertPhotoshop(imported, named: "Masks")
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        // Coverage: outside the mask's rectangle the layer shows (the default is white); its black center hides.
        let alphas = try [(5, 5), (13, 23), (25, 25), (50, 0), (53, 3)].map { try rgba(image, x: $0.0, y: $0.1)[3] }
        #expect(alphas == [255, 0, 255, 255, 0])
        let reopened = try await reopened(imported)
        #expect(reopened.map { $0.mask?.placement } == [nil, nil])
        #expect(reopened.map { $0.psdExtras?.importedMaskRect } == [stored, nil])

        // Saved as a PSD, the padded mask goes back to the rectangle and the pixels Photoshop stored.
        let saved = try PSDReader.read(try PSDWriter.data(for: try #require(session.psdWriteRequest()), options: PSDWriteOptions()).data)
        #expect(saved.layers.map(\.maskBounds) == [stored, CGRect(x: 50, y: 0, width: 8, height: 8)])
        #expect(try maskBytes(#require(saved.layers[0].mask)) == maskBytes(mask))
    }

    /// Photoshop shows a mask's default color beyond its rectangle: a mask made from a selection (default black,
    /// white inside the selection's rectangle) reveals only that rectangle, and it can be painted anywhere on the layer.
    @Test func aMaskShowsItsDefaultColorBeyondItsRectangle() async throws {
        var layer = PSDRecord(id: UUID(), name: "Revealed")
        layer.bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
        layer.image = try colorImage(width: 40, height: 40, red: 1, green: 0, blue: 0)
        layer.mask = try centeredMask(size: 8, edge: 1, center: 1)
        layer.extras = PSDLayerExtras(maskDefaultColor: 0)
        let composite = try colorImage(width: 40, height: 40, red: 0, green: 0, blue: 0, alpha: 0)
        var data = try PSDFixture.data(PSDDocument(width: 40, height: 40, resolution: 72, layers: [layer]), composite: composite)
        data = try movingMask(in: data, at: CGRect(x: 0, y: 0, width: 8, height: 8), by: CGPoint(x: 10, y: 20))
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        let mask = try #require(imported.layers.first?.mask)
        #expect(mask.placement == nil && mask.asset.image.width == 40)
        #expect(try maskBytes(mask.asset.image)[0] == 0)

        let session = EditorSession()
        try session.insertPhotoshop(imported, named: "Revealed")
        func alphas() async throws -> [Int] {
            let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
            return try [(5, 5), (13, 23), (17, 27), (25, 25), (30, 5)].map { try rgba(image, x: $0.0, y: $0.1)[3] }
        }
        #expect(try await alphas() == [0, 255, 255, 0, 0])
        // Painting white beyond Photoshop's rectangle reveals the layer there too.
        let id = try #require(session.document?.layers.first?.id)
        session.selectLayerTarget(id, mask: true)
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 6, hardness: 1, red: 1, green: 1, blue: 1)
        session.maskPaintWhite = true
        session.beginBrush(at: CGPoint(x: 30, y: 5))
        session.continueBrush(at: CGPoint(x: 31, y: 5))
        await session.finishBrush()
        #expect(session.isMaskSelected)
        #expect(try await alphas() == [0, 255, 255, 0, 255])
    }

    /// A mask reaching past its layer is padded over both and sits there; the layer draws through it where they meet.
    @Test func aMaskReachingPastItsLayerSitsOverBoth() async throws {
        var layer = PSDRecord(id: UUID(), name: "Reaching")
        layer.bounds = CGRect(x: 10, y: 10, width: 20, height: 20)
        layer.image = try colorImage(width: 20, height: 20, red: 1, green: 0, blue: 0)
        layer.mask = try centeredMask(size: 8, edge: 1, center: 0)
        let composite = try colorImage(width: 40, height: 40, red: 0, green: 0, blue: 0, alpha: 0)
        var data = try PSDFixture.data(PSDDocument(width: 40, height: 40, resolution: 72, layers: [layer]), composite: composite)
        // Stored at (25, 5): past the layer's right edge and above its top.
        data = try movingMask(in: data, at: CGRect(x: 10, y: 10, width: 8, height: 8), by: CGPoint(x: 15, y: -5))
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        let mask = try #require(imported.layers.first?.mask)
        let placement = LayerTransform(origin: CGPoint(x: 10, y: 5), size: CGSize(width: 23, height: 25))
        #expect(mask.placement == placement)
        #expect(imported.layers.first?.psdExtras?.importedMaskRect == CGRect(x: 15, y: 0, width: 8, height: 8))

        let session = EditorSession()
        try session.insertPhotoshop(imported, named: "Reaching")
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        // The default (white) over the layer; the mask's black center (27…31, 7…11) where it overlaps the layer.
        let alphas = try [(12, 12), (20, 25), (28, 10), (26, 11), (32, 10)].map { try rgba(image, x: $0.0, y: $0.1)[3] }
        #expect(alphas == [255, 255, 0, 255, 0])
        #expect(try await reopened(imported).first?.mask?.placement == placement)
    }

    /// A file dropped onto an open canvas at a point moves there with its masks, placed ones included.
    @Test func aFileDroppedAtAPointMovesItsPlacedMasksWithItsLayers() async throws {
        var layer = PSDRecord(id: UUID(), name: "Reaching")
        layer.bounds = CGRect(x: 10, y: 10, width: 20, height: 20)
        layer.image = try colorImage(width: 20, height: 20, red: 1, green: 0, blue: 0)
        layer.mask = try centeredMask(size: 8, edge: 1, center: 0)
        let composite = try colorImage(width: 40, height: 40, red: 0, green: 0, blue: 0, alpha: 0)
        var data = try PSDFixture.data(PSDDocument(width: 40, height: 40, resolution: 72, layers: [layer]), composite: composite)
        data = try movingMask(in: data, at: CGRect(x: 10, y: 10, width: 8, height: 8), by: CGPoint(x: 15, y: -5))
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        let placement = LayerTransform(origin: CGPoint(x: 10, y: 5), size: CGSize(width: 23, height: 25))
        #expect(imported.layers.first?.mask?.placement == placement)

        let session = EditorSession()
        session.createDocument(width: 80, height: 80)
        // The layers' box is 10…30 on both axes; dropped centered at (50, 60), everything moves by (30, 40).
        try session.insertPhotoshop(imported, named: "Dropped", centeredAt: CGPoint(x: 50, y: 60))
        let moved = try #require(session.document?.layers.first { $0.name == "Reaching" })
        #expect(moved.transform.origin == CGPoint(x: 40, y: 50))
        #expect(moved.mask?.placement == LayerTransform(origin: CGPoint(x: 40, y: 45), size: placement.size))
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        // As before, 30 right and 40 down: white over the layer, the mask's black center where it overlaps it.
        let alphas = try [(42, 52), (50, 65), (58, 50), (56, 51)].map { try rgba(image, x: $0.0, y: $0.1)[3] }
        #expect(alphas == [255, 255, 0, 255])
    }

    /// A folder's or adjustment layer's mask covers the canvas, padded with its default color, and clips where
    /// Photoshop's rectangle put it.
    @Test func folderAndAdjustmentMasksArePaddedOverTheCanvas() async throws {
        let size = 40
        var base = PSDRecord(id: UUID(), name: "Base")
        base.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        base.image = try colorImage(width: size, height: size, red: 1, green: 1, blue: 1)
        var folder = PSDRecord(id: UUID(), name: "Folder")
        folder.isGroup = true
        folder.blendKey = "pass"
        folder.mask = try centeredMask(size: 8, edge: 1, center: 1)
        folder.extras = PSDLayerExtras(maskDefaultColor: 0)
        var red = PSDRecord(id: UUID(), parentID: folder.id, name: "Red")
        red.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        red.image = try colorImage(width: size, height: size, red: 1, green: 0, blue: 0)
        // Levels with a white output of 0: everything it reaches turns black.
        var levl = Data([0, 2])
        for channel in 0..<29 {
            for value: UInt16 in [0, 255, 0, channel == 0 ? 0 : 255, 100] { levl.append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xff)]) }
        }
        var levels = PSDRecord(id: UUID(), name: "Levels")
        levels.mask = try centeredMask(size: 6, edge: 1, center: 1)
        levels.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "levl", data: levl)], maskDefaultColor: 0)
        let composite = try colorImage(width: size, height: size, red: 1, green: 1, blue: 1)
        var data = try PSDFixture.data(PSDDocument(width: size, height: size, resolution: 72, layers: [base, folder, red, levels]),
                                       composite: composite)
        data = try movingMask(in: data, at: CGRect(x: 0, y: 0, width: 8, height: 8), by: CGPoint(x: 10, y: 20))
        data = try movingMask(in: data, at: CGRect(x: 0, y: 0, width: 6, height: 6), by: CGPoint(x: 30, y: 5))
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        let masked = imported.layers.filter { $0.mask != nil }
        #expect(masked.map(\.name) == ["Folder", "Levels"])
        #expect(masked.allSatisfy { $0.mask?.placement == nil && $0.mask?.asset.image.width == size && $0.mask?.asset.image.height == size })
        #expect(masked.map { $0.psdExtras?.importedMaskRect } == [CGRect(x: 10, y: 20, width: 8, height: 8), CGRect(x: 30, y: 5, width: 6, height: 6)])

        let session = EditorSession()
        try session.insertPhotoshop(imported, named: "Folders")
        let exported = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let context = try BrushRaster.context(width: size, height: size, mask: false)
        session.drawLiveComposite(try #require(session.document), in: context)
        let live = try #require(context.makeImage())
        for image in [exported, live] {
            // Red only inside the folder mask's rectangle; black only inside the adjustment mask's.
            let points = [(14, 24), (5, 5), (25, 30), (32, 7)]
            let colors = try points.map { try rgba(image, x: $0.0, y: $0.1) }
            #expect(colors[0][0] > 200 && colors[0][1] < 80, "folder rectangle shows \(colors[0])")
            #expect(colors[1][0] > 240 && colors[1][1] > 240, "outside both shows \(colors[1])")
            #expect(colors[2][0] > 240 && colors[2][1] > 240, "outside the folder rectangle shows \(colors[2])")
            #expect(colors[3][0] < 20 && colors[3][1] < 20, "adjustment rectangle shows \(colors[3])")
        }
    }

    /// Padding that would take the document's masks past what a project holds leaves a mask in Photoshop's rectangle.
    /// The budget is what padding may add: 40 × 40 padded less the 8 × 8 stored is 1,536 pixels.
    @Test func aMaskTooLargeToPadKeepsItsRectangle() throws {
        let mask = try centeredMask(size: 8, edge: 1, center: 0)
        let layer = LayerTransform(origin: .zero, size: CGSize(width: 40, height: 40))
        let bounds = CGRect(x: 10, y: 20, width: 8, height: 8)
        let padded = PSDDocumentBuilder.layerMask(mask, bounds: bounds, defaultColor: 0, layer: layer, budget: 1_536)
        #expect(padded.placement == nil && padded.image.width == 40 && padded.stored == bounds && !padded.unpadded)
        let kept = PSDDocumentBuilder.layerMask(mask, bounds: bounds, defaultColor: 0, layer: layer, budget: 1_535)
        #expect(kept.image === mask && kept.stored == nil && kept.unpadded)
        #expect(kept.placement == LayerTransform(origin: bounds.origin, size: bounds.size))
        // In its layer's own rectangle there is nothing to pad, whatever the budget.
        let own = PSDDocumentBuilder.layerMask(mask, bounds: CGRect(x: 0, y: 0, width: 8, height: 8), defaultColor: 0,
                                               layer: LayerTransform(origin: .zero, size: CGSize(width: 8, height: 8)), budget: 0)
        #expect(own.image === mask && own.placement == nil && own.stored == nil && !own.unpadded)
    }

    /// Padding is charged only what it adds, after every mask as Photoshop stored it: a mask that isn't padded still
    /// fits, and the import saves. Five adjustment masks stored as 3,000 × 2,000 rectangles inside a 6,000 × 4,000
    /// canvas are 30M pixels; padding one to the canvas adds 18M, so three fit in the 70M left and two keep their
    /// rectangles (84M in all). Charging whole padded masks in layer order padded four (96M), and the fifth's 6M
    /// took the project past the 100M it holds, so it couldn't be saved.
    @Test func paddingLeavesRoomForEveryStoredMask() async throws {
        let stored = CGRect(x: 1_000, y: 1_000, width: 3_000, height: 2_000)
        let mask = try grayImage(width: Int(stored.width), height: Int(stored.height), value: 1)
        let records = (1...5).map { index in
            var record = PSDRecord(id: UUID(), name: "Invert \(index)")
            record.adjustment = LayerAdjustment(kind: .invert)
            record.mask = mask
            record.maskBounds = stored
            record.extras = PSDLayerExtras(maskDefaultColor: 0)
            return record
        }
        // A budget of 100 million mask pixels, whatever this Mac's (`DocumentLimits.documentPixelBudget`).
        let imported = try PSDDocumentBuilder.makeImport(PSDDocument(width: 6_000, height: 4_000, resolution: 72, layers: records,
                                                                     maskPixelBudget: 100_000_000))
        let masks = imported.layers.compactMap(\.mask)
        let pixels = masks.map { $0.asset.image.width * $0.asset.image.height }
        #expect(pixels == [24_000_000, 24_000_000, 24_000_000, 6_000_000, 6_000_000])
        #expect(pixels.reduce(0, +) <= 100_000_000)
        let own = LayerTransform(origin: stored.origin, size: stored.size)
        #expect(masks.map(\.placement) == [nil, nil, nil, own, own])
        #expect(imported.layers.map { $0.psdExtras?.importedMaskRect } == [stored, stored, stored, nil, nil])
        #expect(imported.conversions.filter { $0.message.contains("keeps Photoshop’s rectangle") }.map(\.layerName) == ["Invert 4", "Invert 5"])
        // It saves (and opens again) as a project.
        let reopened = try await reopened(imported)
        #expect(reopened.compactMap { $0.mask.map { $0.asset.image.width * $0.asset.image.height } } == pixels)
        #expect(reopened.map { $0.mask?.placement } == [nil, nil, nil, own, own])
    }

    /// A `size` × `size` mask of `edge` gray with a centered square of `center` gray half as wide.
    private func centeredMask(size: Int, edge: CGFloat, center: CGFloat) throws -> CGImage {
        let context = try BrushRaster.context(width: size, height: size, mask: true)
        context.setFillColor(gray: edge, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(gray: center, alpha: 1)
        context.fill(CGRect(x: size / 4, y: size / 4, width: size / 2, height: size / 2))
        return try #require(context.makeImage())
    }

    /// A gray image's values, row by row.
    private func maskBytes(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                         count: image.width * image.height))
    }

    /// Photoshop's Background as the corpus stores it: no transparency channel, `lnsr` `bgnd` and `lspf` 13.
    @Test func photoshopsBackgroundLayerIsMarkedAsTheBackground() async throws {
        func file(nameSource: String, channels: [Int16]) -> Data {
            PSDFixture.singleLayerFile(width: 4, height: 4, name: "Background", color: [200, 100, 50], channels: channels, blocks: [
                PSDTaggedBlock(key: "lspf", data: Data([0, 0, 0, 13])), PSDTaggedBlock(key: "lnsr", data: Data(nameSource.utf8)),
            ])
        }
        let document = try PSDReader.read(file(nameSource: "bgnd", channels: [0, 1, 2]))
        let background = try #require(document.layers.first)
        #expect(background.extras?.isBackground == true)
        #expect(background.extras?.nameSource == "bgnd")
        #expect(background.locks == LayerLocks(rawValue: 13))
        #expect(try rgba(#require(background.image), x: 1, y: 1) == [200, 100, 50, 255])
        // Called the Background but with a transparency channel, or opaque but named as any other layer: not it.
        #expect(try PSDReader.read(file(nameSource: "bgnd", channels: [-1, 0, 1, 2])).layers.first?.extras?.isBackground == false)
        #expect(try PSDReader.read(file(nameSource: "layr", channels: [0, 1, 2])).layers.first?.extras?.isBackground == false)
        let imported = try PSDDocumentBuilder.makeImport(document)
        #expect(imported.layers.first?.psdExtras?.isBackground == true)
        #expect(try await reopened(imported).first?.psdExtras?.isBackground == true)
    }

    /// A type layer keeps its `TySh` text index (which of the document's `Txt2` texts is its own), even when the rest
    /// of its type data can't be read.
    @Test func typeLayersKeepTheirTextIndex() async throws {
        let fill = try colorImage(width: 2, height: 2, red: 0, green: 0, blue: 0)
        let base = PSDFixture.typeToolBlock(text: "Title")
        let broken = try PSDFixture.typeToolBlock(base, settingEngineData: "EngineDict.StyleRun.RunLengthArray", to: .array([.integer(1000)]))
        let blocks: [(String, Data?)] = [("Readable", try PSDFixture.typeToolBlock(base, textIndex: 3)),
                                         ("Unreadable", try PSDFixture.typeToolBlock(broken, textIndex: 5)), ("Plain", nil)]
        let records = blocks.map { name, block in
            var record = PSDRecord(id: UUID(), name: name)
            record.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
            record.image = fill
            record.extras = block.map { PSDLayerExtras(blocks: [PSDTaggedBlock(key: "TySh", data: $0)]) }
            return record
        }
        let document = try PSDReader.read(try PSDFixture.data(PSDDocument(width: 2, height: 2, resolution: 72, layers: records), composite: fill))
        #expect(document.layers.map { $0.extras?.textIndex } == [3, 5, nil])
        #expect(document.layers[0].typeLayer?.textIndex == 3)
        #expect(document.layers[1].typeLayer == nil)
        let restored = try await reopened(try PSDDocumentBuilder.makeImport(document))
        #expect(restored.map { $0.psdExtras?.textIndex } == [3, 5, nil])
    }

    /// `imported` opened as a document, saved as a project and opened again: its layers as they come back.
    private func reopened(_ imported: PSDImport) async throws -> [ImageLayer] {
        let session = EditorSession()
        try session.insertPhotoshop(imported, named: "Reopened")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PSDRoundTripTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Reopened.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let reopened = EditorSession()
        reopened.installProject(try await ProjectStore.shared.load(from: url), from: url)
        return try #require(reopened.document?.layers)
    }

    /// `data` with the one mask rectangle `PSDFixture` stored as `rect` (its layer's top-left, the mask's size) moved by
    /// `offset`: its mask data length (20: 18 bytes and the fixture's two parameter bytes) and top, left, bottom, right.
    private func movingMask(in data: Data, at rect: CGRect, by offset: CGPoint) throws -> Data {
        func fields(_ rect: CGRect) -> Data {
            [rect.minY, rect.minX, rect.maxY, rect.maxX].reduce(into: Data()) { data, value in
                let bits = UInt32(bitPattern: Int32(value))
                data.append(contentsOf: [UInt8(bits >> 24), UInt8(bits >> 16 & 0xff), UInt8(bits >> 8 & 0xff), UInt8(bits & 0xff)])
            }
        }
        let stored = Data([0, 0, 0, 20]) + fields(rect)
        let found = try #require(data.range(of: stored))
        #expect(data.range(of: stored, in: found.upperBound ..< data.endIndex) == nil)
        var moved = data
        moved.replaceSubrange(found.lowerBound + 4 ..< found.upperBound, with: fields(rect.offsetBy(dx: offset.x, dy: offset.y)))
        return moved
    }

    /// A 100 × 50 blue rectangle at (20, 30), filled through `vscg`, with a 10 px yellow `vstk` stroke.
    private func strokedRectangle(enabled: Bool, alignment: String = "strokeStyleAlignCenter", dashes: [Double] = [],
                                  opacity: Double = 100) -> [String: Data] {
        let rect = CGRect(x: 20, y: 30, width: 100, height: 50)
        return [
            "vogk": PSDFixture.originationBlock([PSDFixture.rectangleOrigination(type: 1, rect: rect)]),
            "vsms": PSDFixture.vectorPathBlock(canvas: CGSize(width: 200, height: 120),
                                               subpaths: [PSDFixture.turnedCorners(of: rect, degrees: 0)]),
            "vscg": PSDFixture.vectorContentBlock(red: 0, green: 0, blue: 255),
            "vstk": PSDFixture.shapeStrokeBlock(enabled: enabled, width: 10, color: (255, 255, 0), alignment: alignment,
                                                dashes: dashes, opacity: opacity),
        ]
    }

    /// One pixel's red, green, blue and alpha (premultiplied, 0–255).
    private func rgba(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let index = (y * image.width + x) * 4
        return (0..<4).map { Int(bytes[index + $0]) }
    }

    /// A Photoshop-shaped `vogk` block: `u32 1` + descriptor with one `keyDescriptorList` item.
    private func originationData(type: Int32, rect: CGRect, radii: [Double] = []) -> Data {
        func pixels(_ value: CGFloat) -> PSDDescriptorValue { .unitFloat(unit: "#Pxl", value: Double(value)) }
        var item = PSDDescriptor(classID: "null", items: [
            ("keyOriginType", .integer(type)),
            ("keyOriginResolution", .double(72)),
            ("keyOriginShapeBBox", .object(PSDDescriptor(classID: "unitRect", items: [
                ("unitValueQuadVersion", .integer(1)),
                ("Top ", pixels(rect.minY)), ("Left", pixels(rect.minX)),
                ("Btom", pixels(rect.maxY)), ("Rght", pixels(rect.maxX))
            ])))
        ])
        if radii.count == 4 {
            let corners = zip(["topLeft", "topRight", "bottomRight", "bottomLeft"], radii).map {
                (key: PSDKey($0), value: pixels(CGFloat($1)))
            }
            item.items.append(("keyOriginRRectRadii", .object(PSDDescriptor(classID: "radii", items:
                [("unitValueQuadVersion", .integer(1))] + corners))))
        }
        let root = PSDDescriptor(classID: "null", items: [("keyDescriptorList", .list([.object(item)]))])
        return PSDDescriptorWriter.block2(root, version: 1)
    }

    private func vectorMask(canvas: CGSize, corners: [CGPoint]) -> Data {
        var data = Data()
        func append32(_ value: UInt32) {
            data.append(UInt8(truncatingIfNeeded: value >> 24))
            data.append(UInt8(truncatingIfNeeded: value >> 16))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value))
        }
        func append16(_ value: Int16) {
            let raw = UInt16(bitPattern: value)
            data.append(UInt8(truncatingIfNeeded: raw >> 8))
            data.append(UInt8(truncatingIfNeeded: raw))
        }
        func appendPoint(_ point: CGPoint) {
            let y = Int32((Double(point.y) / Double(canvas.height)) * 0x1000000)
            let x = Int32((Double(point.x) / Double(canvas.width)) * 0x1000000)
            append32(UInt32(bitPattern: y))
            append32(UInt32(bitPattern: x))
        }
        func padRecord() { data.append(Data(count: 24)) }
        append32(3); append32(0)
        append16(6); padRecord()
        append16(8); padRecord()
        append16(0)
        append16(Int16(corners.count))
        data.append(Data(count: 22))
        for corner in corners {
            append16(1)
            appendPoint(corner)
            appendPoint(corner)
            appendPoint(corner)
        }
        return data
    }

    private func solidColor(red: Double, green: Double, blue: Double) -> Data {
        PSDDescriptorWriter.block(PSDDescriptor(classID: "null", items: [
            ("Clr ", .object(colorDescriptor(red: red, green: green, blue: blue)))
        ]))
    }

    private func colorDescriptor(red: Double, green: Double, blue: Double) -> PSDDescriptor {
        PSDDescriptor(classID: "RGBC", items: [("Rd  ", .double(red)), ("Grn ", .double(green)), ("Bl  ", .double(blue))])
    }

    private func strokeStyle(fill: Bool, stroke: Bool, width: Double, red: Double, green: Double, blue: Double) -> Data {
        PSDDescriptorWriter.block(PSDDescriptor(classID: "strokeStyle", items: [
            ("strokeStyleVersion", .integer(2)),
            ("strokeEnabled", .bool(stroke)),
            ("fillEnabled", .bool(fill)),
            ("strokeStyleLineWidth", .unitFloat(unit: "#Pxl", value: width)),
            ("strokeStyleContent", .object(PSDDescriptor(classID: "solidColorLayer", items: [
                ("Clr ", .object(colorDescriptor(red: red, green: green, blue: blue)))
            ])))
        ]))
    }

    private func lsctTypes(in data: Data) -> [UInt32] {
        var types: [UInt32] = []
        var search = data.startIndex
        let needle = Data("lsct".utf8)
        while let range = data.range(of: needle, in: search..<data.endIndex), range.upperBound + 8 <= data.endIndex {
            let typeAt = range.upperBound + 4
            types.append(UInt32(data[typeAt]) << 24 | UInt32(data[typeAt + 1]) << 16 | UInt32(data[typeAt + 2]) << 8 | UInt32(data[typeAt + 3]))
            search = range.upperBound
        }
        return types
    }

    private func rawChannel(_ plane: Data) -> Data {
        var data = Data([0, 0])
        data.append(plane)
        return data
    }

    private func oversizedLayerFile(width: UInt32, height: UInt32, layerWidth: Int32, layerHeight: Int32) -> Data {
        layerFile(canvasWidth: width, canvasHeight: height, layerWidth: layerWidth, layerHeight: layerHeight, channels: [
            (-1, Data([0, 0])), (0, Data([0, 0])), (1, Data([0, 0])), (2, Data([0, 0])),
        ])
    }

    private func layerFile(
        canvasWidth: UInt32 = 8,
        canvasHeight: UInt32 = 8,
        layerWidth: Int32,
        layerHeight: Int32,
        channels: [(id: Int16, payload: Data)]
    ) -> Data {
        var data = header(width: canvasWidth, height: canvasHeight)
        func append32(_ value: UInt32) {
            data.append(UInt8(truncatingIfNeeded: value >> 24))
            data.append(UInt8(truncatingIfNeeded: value >> 16))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value))
        }
        append32(0)
        append32(0)
        var records = Data()
        func rec16(_ value: UInt16) {
            records.append(UInt8(truncatingIfNeeded: value >> 8))
            records.append(UInt8(truncatingIfNeeded: value))
        }
        func rec32(_ value: UInt32) {
            records.append(UInt8(truncatingIfNeeded: value >> 24))
            records.append(UInt8(truncatingIfNeeded: value >> 16))
            records.append(UInt8(truncatingIfNeeded: value >> 8))
            records.append(UInt8(truncatingIfNeeded: value))
        }
        func recI16(_ value: Int16) { rec16(UInt16(bitPattern: value)) }
        func recI32(_ value: Int32) { rec32(UInt32(bitPattern: value)) }
        recI16(1)
        recI32(0)
        recI32(0)
        recI32(layerHeight)
        recI32(layerWidth)
        rec16(UInt16(channels.count))
        var payloads = Data()
        for channel in channels {
            recI16(channel.id)
            rec32(UInt32(channel.payload.count))
            payloads.append(channel.payload)
        }
        records.append(contentsOf: Array("8BIMnorm".utf8))
        records.append(contentsOf: [255, 0, 0, 0])
        rec32(12)
        rec32(0)
        rec32(0)
        records.append(3)
        records.append(contentsOf: Array("Big".utf8))
        var info = Data()
        func info32(_ value: UInt32) {
            info.append(UInt8(truncatingIfNeeded: value >> 24))
            info.append(UInt8(truncatingIfNeeded: value >> 16))
            info.append(UInt8(truncatingIfNeeded: value >> 8))
            info.append(UInt8(truncatingIfNeeded: value))
        }
        info32(UInt32(records.count + payloads.count))
        info.append(records)
        info.append(payloads)
        info32(0)
        append32(UInt32(info.count))
        data.append(info)
        return data
    }
}
