import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Compositor

/// Layered PSD files written from a document (Task 4.2): taken apart field by field by `Layout`, which reads the
/// bytes independently of the app's reader, and read back through `PSDReader` and `PSDDocumentBuilder`.
@MainActor
@Suite(.serialized)
struct PSDWriterRoundTripTests {
    // MARK: Fixtures

    /// Premultiplied RGBA pixels, top row first.
    private func rgba(_ width: Int, _ height: Int, _ bytes: [UInt8]) throws -> CGImage {
        try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func solid(_ width: Int, _ height: Int, _ pixel: [UInt8]) throws -> CGImage {
        try rgba(width, height, Array(Array(repeating: pixel, count: width * height).joined()))
    }

    private func gray(_ width: Int, _ height: Int, _ bytes: [UInt8]) throws -> CGImage {
        try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixelLayer(_ name: String, _ image: CGImage, at origin: CGPoint = .zero, id: UUID = UUID(),
                            parent: UUID? = nil) -> ImageLayer {
        ImageLayer(id: id, asset: ImportedImage(image: image, thumbnail: image, name: name), name: name, isVisible: true,
                   transform: LayerTransform(origin: origin, size: CGSize(width: image.width, height: image.height)),
                   parentID: parent)
    }

    private func folder(_ name: String, id: UUID, canvas: CGSize, parent: UUID? = nil) -> ImageLayer {
        ImageLayer(id: id, asset: nil, name: name, isVisible: true, transform: LayerTransform(origin: .zero, size: canvas),
                   parentID: parent, isGroup: true)
    }

    private func mask(_ image: CGImage, enabled: Bool = true, linked: Bool = true, placement: LayerTransform? = nil) -> LayerMask {
        LayerMask(asset: ImportedImage(image: image, thumbnail: image, name: "Layer Mask"), isEnabled: enabled,
                  placement: placement, isLinked: linked)
    }

    private func session(_ width: Int, _ height: Int, _ layers: [ImageLayer], active: UUID? = nil) -> EditorSession {
        let session = EditorSession()
        session.document = CanvasDocument(width: width, height: height, layers: layers)
        session.activeLayerID = active ?? layers.last?.id
        return session
    }

    private func written(_ session: EditorSession, _ options: PSDWriteOptions = .init()) throws
        -> (layout: Layout, data: Data, report: PSDWriteReport) {
        let request = try #require(session.psdWriteRequest())
        let result = try PSDWriter.data(for: request, options: options)
        return (try Layout(result.data), result.data, result.report)
    }

    /// A session holding `document` as Photoshop wrote it (through `PSDFixture`), opened as the app opens a PSD.
    private func opened(_ document: PSDDocument, into target: EditorSession? = nil) throws -> (session: EditorSession, file: Data) {
        let composite = try solid(document.width, document.height, [0, 0, 0, 0])
        let data = try PSDFixture.data(document, composite: composite)
        let session = target ?? EditorSession()
        try session.insertPhotoshop(try PSDDocumentBuilder.makeImport(try PSDReader.read(data)), named: "Fixture")
        return (session, data)
    }

    private func luni(_ name: String) -> PSDTaggedBlock {
        var data = u32Data(UInt32(name.utf16.count))
        for unit in name.utf16 { data.append(contentsOf: [UInt8(unit >> 8), UInt8(unit & 0xFF)]) }
        return PSDTaggedBlock(key: "luni", data: data)
    }

    private func u32Data(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    /// Premultiplied RGBA bytes of `image`, top row first.
    private func premultiplied(_ image: CGImage) throws -> [UInt8] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<image.height).flatMap { y in (0..<image.width * 4).map { bytes[y * context.bytesPerRow + $0] } }
    }

    // MARK: Blend keys

    @Test func blendKeysAreTheInverseOfImport() {
        for mode in LayerBlendMode.allCases { #expect(LayerBlendMode.fromPSD(mode.psdKey) == mode) }
        #expect(LayerBlendMode.multiply.psdKey == "mul " && LayerBlendMode.exclusion.psdKey == "smud"
                && LayerBlendMode.linearDodge.psdKey == "lddg" && LayerBlendMode.luminosity.psdKey == "lum ")
    }

    // MARK: Layers

    @Test func layersKeepOrderVisibilityOpacityBlendAndPixels() throws {
        var red = pixelLayer("Red", try rgba(2, 1, [255, 0, 0, 255, 10, 20, 30, 255]))
        red.opacity = 0.5
        red.blendMode = .multiply
        var blue = pixelLayer("Blue", try solid(2, 3, [0, 0, 255, 255]), at: CGPoint(x: 3, y: 1))
        blue.isVisible = false
        let green = pixelLayer("Grün", try solid(1, 1, [0, 255, 0, 255]), at: CGPoint(x: 5, y: 5))
        let (layout, data, report) = try written(session(8, 8, [red, blue, green]))
        #expect(report.layerRecordCount == 3 && report.byteCount == data.count && report.warnings.isEmpty)
        #expect(layout.records.map(\.name) == ["Red", "Blue", "Grün"])
        #expect(layout.records.map(\.blendKey) == ["mul ", "norm", "norm"])
        #expect(layout.records.map(\.opacity) == [128, 255, 255])
        #expect(layout.records.map { $0.flags & 0x1B } == [0x08, 0x0A, 0x08])
        #expect(layout.records.map(\.rect) == [CGRect(x: 0, y: 0, width: 2, height: 1), CGRect(x: 3, y: 1, width: 2, height: 3),
                                               CGRect(x: 5, y: 5, width: 1, height: 1)])
        #expect(layout.records[0].channelIDs == [-1, 0, 1, 2])
        #expect(layout.records[0].blendingRanges == Data(Array(repeating: [0, 0, 0xFF, 0xFF, 0, 0, 0xFF, 0xFF] as [UInt8], count: 5).joined()))
        #expect(layout.records[2].keys == ["luni", "lyid", "clbl", "infx", "knko", "lspf", "lclr", "fxrp"])
        #expect(layout.records[2].block("luni") == luni("Grün").data)
        // An upright layer at its own size is written as its pixels, unchanged.
        #expect(try layout.records[0].plane(0) == [255, 10] && layout.records[0].plane(1) == [0, 20]
                && layout.records[0].plane(2) == [0, 30] && layout.records[0].plane(-1) == [255, 255])
        let document = try PSDReader.read(data)
        #expect(document.layers.map(\.name) == ["Red", "Blue", "Grün"])
        #expect(document.layers.map(\.isVisible) == [true, false, true])
        #expect(document.layers[0].blendKey == "mul " && abs(document.layers[0].opacity - 128.0 / 255) < 0.0001)
        #expect(document.layers[1].bounds == CGRect(x: 3, y: 1, width: 2, height: 3))
        let imported = try PSDDocumentBuilder.makeImport(document)
        #expect(imported.conversions.isEmpty)
        #expect(imported.layers.map(\.name) == ["Red", "Blue", "Grün"])
        #expect(imported.layers[0].blendMode == .multiply)
    }

    @Test func groupsWriteTheirDividerThenChildrenThenTheFolderOpenOrClosed() throws {
        let canvas = CGSize(width: 8, height: 8)
        let open = UUID(), closed = UUID()
        var outer = folder("Open", id: open, canvas: canvas)
        outer.opacity = 0.5
        let inner = folder("Closed", id: closed, canvas: canvas, parent: open)
        let a = pixelLayer("A", try solid(2, 2, [255, 0, 0, 255]), parent: closed)
        let b = pixelLayer("B", try solid(2, 2, [0, 255, 0, 255]), parent: open)
        let c = pixelLayer("C", try solid(2, 2, [0, 0, 255, 255]))
        let (layout, data, report) = try written(session(8, 8, [outer, inner, a, b, c]),
                                                 PSDWriteOptions(collapsedGroupIDs: [closed]))
        #expect(report.layerRecordCount == 7)
        #expect(layout.records.map(\.name) == ["</Layer group>", "</Layer group>", "A", "Closed", "B", "Open", "C"])
        #expect(layout.records.map { $0.block("lsct").map { Array($0) } } == [
            [0, 0, 0, 3] + Array("8BIMpass".utf8), [0, 0, 0, 3] + Array("8BIMpass".utf8), nil,
            [0, 0, 0, 2] + Array("8BIMpass".utf8), nil, [0, 0, 0, 1] + Array("8BIMpass".utf8), nil
        ])
        let folderRecord = layout.records[5]
        #expect(folderRecord.blendKey == "pass" && folderRecord.opacity == 128 && folderRecord.rect == .zero)
        #expect(folderRecord.flags & 0x18 == 0x18 && layout.records[0].flags & 0x18 == 0x18)
        #expect(folderRecord.channels.map(\.id) == [-1, 0, 1, 2] && folderRecord.channels.allSatisfy { $0.data == Data([0, 0]) })
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        let names = Dictionary(uniqueKeysWithValues: imported.layers.map { ($0.id, $0.name) })
        #expect(imported.layers.map(\.name) == ["A", "Closed", "B", "Open", "C"])
        #expect(imported.layers.map { $0.parentID.flatMap { names[$0] } } == ["Closed", "Open", "Open", nil, nil])
        #expect(imported.layers.filter(\.isGroup).map(\.name) == ["Closed", "Open"])
        #expect(abs(imported.layers[3].opacity - 128.0 / 255) < 0.0001)
    }

    // MARK: Masks

    @Test func masksCoverTheLayerSitAtTheirOwnRectOrAreResampledIntoTheLayer() throws {
        let values: [UInt8] = [0, 64, 128, 255, 255, 128, 64, 0, 10, 20, 30, 40, 50, 60, 70, 80]
        var covering = pixelLayer("Covering", try solid(4, 4, [255, 0, 0, 255]), at: CGPoint(x: 2, y: 2))
        covering.mask = mask(try gray(4, 4, values), enabled: false, linked: false)
        var placed = pixelLayer("Placed", try solid(6, 6, [0, 255, 0, 255]), at: CGPoint(x: 1, y: 1))
        placed.mask = mask(try gray(3, 2, [255, 200, 255, 255, 100, 255]),
                           placement: LayerTransform(origin: CGPoint(x: 3, y: 4), size: CGSize(width: 3, height: 2)))
        var turned = pixelLayer("Turned", try solid(8, 8, [0, 0, 255, 255]))
        var center = [UInt8](repeating: 0, count: 16)
        for i in [5, 6, 9, 10] { center[i] = 255 }
        turned.mask = mask(try gray(4, 4, center),
                           placement: LayerTransform(origin: CGPoint(x: 2, y: 2), size: CGSize(width: 4, height: 4), rotation: 45))
        let (layout, data, _) = try written(session(12, 12, [covering, placed, turned]))

        let first = layout.records[0]
        #expect(first.channelIDs == [-1, 0, 1, 2, -2])
        #expect(first.maskRect == CGRect(x: 2, y: 2, width: 4, height: 4))
        #expect(try first.plane(-2) == values)
        #expect(first.maskFlags == 3)
        let second = layout.records[1]
        #expect(second.maskRect == CGRect(x: 3, y: 4, width: 3, height: 2))
        #expect(try second.plane(-2) == [255, 200, 255, 255, 100, 255])
        #expect(second.maskDefault == 255 && second.maskFlags == 0)
        let third = layout.records[2]
        #expect(third.maskRect == CGRect(x: 0, y: 0, width: 8, height: 8))
        #expect(third.maskDefault == 0)
        let plane = try third.plane(-2)
        #expect(plane[0] == 0 && plane[7] == 0 && plane[63] == 0)
        #expect(plane[3 * 8 + 3] > 128 && plane[4 * 8 + 4] > 128)

        let document = try PSDReader.read(data)
        #expect(document.layers[0].mask?.width == 4 && document.layers[0].maskEnabled == false && document.layers[0].maskLinked == false)
        #expect(document.layers[1].mask?.width == 3 && document.layers[1].mask?.height == 2)
        #expect(document.layers[2].mask?.width == 8)
    }

    /// A mask import padded to cover its layer is written back in the rectangle Photoshop stored it in, while that
    /// loses nothing: it still sits one pixel to a document pixel, the rectangle lies inside its pixels, and every
    /// pixel outside the rectangle is still the default color. Otherwise the whole mask is written.
    @Test func aPaddedMaskIsCroppedBackToItsStoredRectangleOnlyWhenNothingIsLost() throws {
        let stored = CGRect(x: 3, y: 4, width: 2, height: 2)
        func padded(_ values: [UInt8], defaultColor: UInt8 = 255, rect: CGRect = stored) throws -> ImageLayer {
            var layer = pixelLayer("Padded", try solid(8, 8, [255, 0, 0, 255]), at: CGPoint(x: 2, y: 2))
            layer.mask = mask(try gray(8, 8, values))
            layer.psdExtras = PSDLayerExtras(maskDefaultColor: defaultColor, importedMaskRect: rect)
            return layer
        }
        // White padding around a black 2 × 2 at the stored rectangle.
        var values = [UInt8](repeating: 255, count: 64)
        for (x, y) in [(3, 4), (4, 4), (3, 5), (4, 5)] { values[y * 8 + x] = 0 }
        let cropped = try #require(written(session(12, 12, [try padded(values)])).layout.records.first)
        #expect(cropped.maskRect == CGRect(x: 5, y: 6, width: 2, height: 2))
        #expect(try cropped.plane(-2) == [0, 0, 0, 0] && cropped.maskDefault == 255)

        // Black padding around white works the same way, with a black default.
        let inverted = values.map { 255 - $0 }
        let black = try #require(written(session(12, 12, [try padded(inverted, defaultColor: 0)])).layout.records.first)
        #expect(black.maskRect == CGRect(x: 5, y: 6, width: 2, height: 2))
        #expect(try black.plane(-2) == [255, 255, 255, 255] && black.maskDefault == 0)

        // Painted outside the rectangle since: the whole mask.
        var painted = values
        painted[0] = 128
        let whole = try #require(written(session(12, 12, [try padded(painted)])).layout.records.first)
        #expect(whole.maskRect == CGRect(x: 2, y: 2, width: 8, height: 8))
        #expect(try whole.plane(-2) == painted)

        // A rectangle reaching past the mask's pixels (the mask was cropped since): the whole mask.
        let past = try #require(written(session(12, 12, [try padded(values, rect: CGRect(x: 6, y: 6, width: 4, height: 4))]))
            .layout.records.first)
        #expect(past.maskRect == CGRect(x: 2, y: 2, width: 8, height: 8))

        // Scaled, the mask is resampled into the layer, not one pixel to a document pixel: the whole mask.
        var scaled = try padded(values)
        scaled.transform.size = CGSize(width: 16, height: 16)
        let resampled = try #require(written(session(20, 20, [scaled])).layout.records.first)
        #expect(resampled.maskRect == CGRect(x: 2, y: 2, width: 16, height: 16))
    }

    // MARK: Clipping

    @Test func adjacentClippingIsWrittenAndOtherLiveMasksAreBakedWithAWarning() throws {
        let base = pixelLayer("Base", try solid(2, 2, [255, 255, 255, 255]))
        var first = pixelLayer("First", try solid(4, 4, [255, 0, 0, 255]))
        first.maskSourceID = base.id
        var second = pixelLayer("Second", try solid(4, 4, [0, 255, 0, 255]))
        second.maskSourceID = base.id
        let other = pixelLayer("Other", try solid(2, 2, [0, 0, 0, 255]), at: CGPoint(x: 2, y: 2))
        let spacer = pixelLayer("Spacer", try solid(1, 1, [0, 0, 255, 255]), at: CGPoint(x: 3, y: 0))
        var apart = pixelLayer("Apart", try solid(4, 4, [255, 255, 0, 255]))
        apart.maskSourceID = other.id
        var layers = [base, first, second, other, spacer, apart]
        for index in layers.indices { layers[index].transform.sampling = .nearest }
        let (layout, data, report) = try written(session(4, 4, layers))
        #expect(layout.records.map(\.clipping) == [0, 1, 1, 0, 0, 0])
        #expect(report.warnings.map(\.layerName) == ["Apart"])
        // Photoshop's file holds the clipping as pixels: a lossy save the app asks about first.
        #expect(report.warnings.map(\.lossy) == [true])
        // Baked: only where the base below it has pixels.
        let alpha = try layout.records[5].plane(-1)
        #expect(alpha == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 0, 0, 255, 255])
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        #expect(imported.layers[1].maskSourceID == imported.layers[0].id && imported.layers[2].maskSourceID == imported.layers[0].id)
        #expect(imported.layers[5].maskSourceID == nil)
    }

    /// A clip the writer can neither write nor apply (a layer without pixels, clipped to a layer that isn't directly
    /// below it) is left out, which changes what Photoshop shows: a lossy change, asked about before saving.
    @Test func aClippingLeftOutIsALossyChange() throws {
        let base = pixelLayer("Base", try solid(2, 2, [255, 255, 255, 255]))
        let spacer = pixelLayer("Spacer", try solid(1, 1, [0, 0, 255, 255]), at: CGPoint(x: 3, y: 0))
        var empty = ImageLayer(id: UUID(), asset: nil, name: "Empty", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 4, height: 4)))
        empty.maskSourceID = base.id
        let report = try written(session(4, 4, [base, spacer, empty])).report
        #expect(report.warnings.map(\.layerName) == ["Empty"])
        #expect(report.warnings.first?.message.contains("left out") == true)
        #expect(report.warnings.map(\.lossy) == [true])
    }

    // MARK: Geometry

    @Test func aRotatedLayerIsBakedToItsBoundsAndMatchesTheComposite() async throws {
        var pixels: [UInt8] = []
        for y in 0..<8 { for x in 0..<12 { pixels += [UInt8(x * 20), UInt8(y * 30), 128, 255] } }
        var tilted = pixelLayer("Tilted", try rgba(12, 8, pixels), at: CGPoint(x: 10, y: 12))
        tilted.transform.rotation = 30
        let session = session(40, 40, [tilted])
        let (layout, data, _) = try written(session)
        let png = try await ImageExporter.shared.pngData(try #require(session.projectSnapshot()))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let composite = try premultiplied(try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        var bounds = CGRect.null
        for y in 0..<40 { for x in 0..<40 where composite[(y * 40 + x) * 4 + 3] > 0 {
            bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        let record = layout.records[0]
        #expect(record.rect == bounds)
        let layer = try premultiplied(try #require(try PSDReader.read(data).layers[0].image))
        let width = Int(record.rect.width), height = Int(record.rect.height)
        var largest = 0
        for y in 0..<height { for x in 0..<width { for channel in 0..<4 {
            let written = Int(layer[(y * width + x) * 4 + channel])
            let expected = Int(composite[((y + Int(record.rect.minY)) * 40 + x + Int(record.rect.minX)) * 4 + channel])
            largest = max(largest, abs(written - expected))
        } } }
        #expect(largest <= 2)
    }

    @Test func anOversizedLayerKeepsItsPartOnTheCanvasWithAWarning() throws {
        var wide = pixelLayer("Wide", try solid(2, 1, [255, 0, 0, 255]))
        wide.transform = LayerTransform(origin: CGPoint(x: -20_000, y: 0), size: CGSize(width: 40_000, height: 2))
        let (layout, _, report) = try written(session(4, 4, [wide]))
        #expect(layout.records[0].rect == CGRect(x: 0, y: 0, width: 4, height: 2))
        #expect(report.warnings.map(\.layerName) == ["Wide"])
    }

    @Test func effectsAreDrawnIntoTheCompositeOnly() throws {
        var outlined = pixelLayer("Outlined", try solid(2, 2, [255, 0, 0, 255]), at: CGPoint(x: 3, y: 3))
        outlined.effects = LayerEffects(stroke: StrokeEffect(size: 2))
        let (layout, _, _) = try written(session(8, 8, [outlined]))
        #expect(layout.records[0].rect == CGRect(x: 3, y: 3, width: 2, height: 2))
        #expect(try layout.records[0].plane(-1) == [255, 255, 255, 255])
        #expect(layout.composite[3][3 * 8 + 2] > 0)
    }

    // MARK: Composite

    @Test func aTransparentCompositeWritesFourChannelsAndANegativeCount() throws {
        let (layout, _, report) = try written(session(4, 4, [pixelLayer("Dot", try solid(2, 2, [255, 0, 0, 255]))]))
        #expect(layout.channels == 4 && layout.layerCount == -1 && report.wroteTransparencyChannel)
        #expect(layout.composite.count == 4)
        #expect(layout.composite.map { $0[0] } == [255, 0, 0, 255])
        // Transparency is stored over white, as Photoshop stores it.
        #expect(layout.composite.map { $0[15] } == [255, 255, 255, 0])
    }

    @Test func anOpaqueCompositeWritesThreeChannelsAndAPositiveCount() throws {
        let (layout, _, report) = try written(session(4, 4, [pixelLayer("Fill", try solid(4, 4, [0, 0, 255, 255]))]))
        #expect(layout.channels == 3 && layout.layerCount == 1 && !report.wroteTransparencyChannel)
        #expect(layout.composite.count == 3 && layout.composite[2].allSatisfy { $0 == 255 })
    }

    // MARK: Photoshop data

    @Test func everyKindReimportsWithTheSameNamesKindsAndBounds() throws {
        let width = 192, height = 108
        var records: [PSDRecord] = []
        func record(_ name: String, image: CGImage? = nil, at origin: CGPoint = .zero, blocks: [String: Data] = [:],
                    parent: UUID? = nil) {
            var record = PSDRecord(id: UUID(), parentID: parent, name: name)
            record.image = image
            if let image { record.bounds = CGRect(origin: origin, size: CGSize(width: image.width, height: image.height)) }
            if !blocks.isEmpty {
                record.extras = PSDLayerExtras(blocks: blocks.keys.sorted().map { PSDTaggedBlock(key: $0, data: blocks[$0]!) })
            }
            records.append(record)
        }
        let pixels = try solid(12, 6, [200, 100, 50, 255])
        var levels = Data([0, 2])
        for _ in 0..<29 { levels.append(contentsOf: [0, 0, 0, 255, 0, 0, 0, 255, 1, 0]) }
        var folderRecord = PSDRecord(id: UUID(), name: "Folder")
        folderRecord.isGroup = true
        records.append(folderRecord)
        record("Inside", image: pixels, at: CGPoint(x: 30, y: 20), parent: folderRecord.id)
        record("Raster", image: pixels, at: CGPoint(x: 4, y: 4))
        record("Levels", blocks: ["levl": levels])
        record("Brightness", blocks: ["brit": Data(count: 12)])
        record("Solid", blocks: ["SoCo": try #require(PSDVectorFixtures.rectangle()["SoCo"])])
        record("Title", image: pixels, at: CGPoint(x: 50, y: 40), blocks: ["TySh": PSDFixture.typeToolBlock(text: "Hi")])
        record("Placed", image: pixels, at: CGPoint(x: 60, y: 60), blocks: ["SoLd": Data(Array("soLD".utf8) + [0, 0, 0, 4])])
        record("Glow", image: pixels, at: CGPoint(x: 70, y: 70), blocks: ["lfx2": Data([0, 0, 0, 0, 0, 0, 0, 16])])
        record("Box", image: pixels, blocks: PSDVectorFixtures.rectangle())
        let original = PSDDocument(width: width, height: height, resolution: 72, layers: records)
        let (session, file) = try opened(original)
        let before = try PSDReader.read(file)
        let (_, data, _) = try written(session)
        let after = try PSDReader.read(data)
        #expect(after.layers.map(\.name) == before.layers.map(\.name))
        #expect(after.layers.map(\.kind) == before.layers.map(\.kind))
        #expect(after.layers.map(\.bounds) == before.layers.map(\.bounds))
        #expect(Set(after.layers.map(\.kind)) == [.group, .raster, .adjustment, .text, .smartObject, .effects, .vector])
        let again = try PSDDocumentBuilder.makeImport(after)
        let layers = try #require(session.document?.layers)
        #expect(again.layers.map(\.name) == layers.map(\.name))
        #expect(again.layers.map(\.isPhotoshopPlaceholder) == layers.map(\.isPhotoshopPlaceholder))
        #expect(after.layers.map(\.isVisible) == before.layers.map(\.isVisible))
    }

    @Test func importedBlocksAreWrittenBackExactlyAndLuniFollowsARename() throws {
        var photo = PSDRecord(id: UUID(), name: "Photo")
        photo.bounds = CGRect(x: 1, y: 1, width: 2, height: 2)
        photo.image = try solid(2, 2, [9, 8, 7, 255])
        // Photoshop's own `luni` here ends in a NUL, which a regenerated one wouldn't.
        photo.extras = PSDLayerExtras(blocks: [luni("Photo\u{0}"), PSDTaggedBlock(key: "lyid", data: u32Data(7)),
                                               PSDTaggedBlock(key: "shmd", data: Data(0..<12)),
                                               PSDTaggedBlock(key: "zzzz", data: Data([1, 2, 3]))],
                                      blendingRanges: Data(repeating: 0xAB, count: 40), flags: 0x08, layerID: 7,
                                      importedName: "Photo", trailingBytes: Data([0, 0]))
        let (session, file) = try opened(PSDDocument(width: 4, height: 4, resolution: 72, layers: [photo]))
        let original = try Layout(file).records[0]
        let unchanged = try written(session).layout.records[0]
        #expect(unchanged.blocks == original.blocks)
        #expect(unchanged.trailing == original.trailing)
        #expect(unchanged.blendingRanges == Data(repeating: 0xAB, count: 40))
        session.document?.layers[0].name = "Portrait"
        let renamed = try written(session).layout.records[0]
        #expect(renamed.keys == original.keys)
        #expect(renamed.block("luni") == luni("Portrait").data)
        #expect(renamed.blocks.filter { $0.key != "luni" } == original.blocks.filter { $0.key != "luni" })
        #expect(try PSDReader.read(try written(session).data).layers[0].name == "Portrait")
        #expect(try written(session, PSDWriteOptions(preserveExtras: false)).layout.records[0].keys
                    == ["luni", "lyid", "clbl", "infx", "knko", "lspf", "lclr", "fxrp"])
    }

    @Test func sectionBlocksLeaveLayersThatAreNoLongerFoldersAndDividersComeBackFromTheFolder() throws {
        let groupID = UUID()
        var group = PSDRecord(id: groupID, name: "Group")
        group.isGroup = true
        let divider = PSDLayerExtras(blocks: [luni("</Layer group>"), PSDTaggedBlock(key: "lsct", data: u32Data(3)),
                                              PSDTaggedBlock(key: "lyid", data: u32Data(42)),
                                              PSDTaggedBlock(key: "lclr", data: Data([0, 2, 0, 0, 0, 0, 0, 0]))],
                                     blendKey: "norm", flags: 0x18, layerID: 42, importedName: "</Layer group>")
        group.extras = PSDLayerExtras(blocks: [luni("Group"), PSDTaggedBlock(key: "lyid", data: u32Data(41)),
                                               PSDTaggedBlock(key: "lsct", data: u32Data(1) + Data("8BIMpass".utf8))],
                                      blendKey: "pass", flags: 0x18, layerID: 41, importedName: "Group",
                                      sectionDividerExtras: divider)
        var child = PSDRecord(id: UUID(), parentID: groupID, name: "Child")
        child.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        child.image = try solid(2, 2, [1, 2, 3, 255])
        let (session, file) = try opened(PSDDocument(width: 4, height: 4, resolution: 72, layers: [group, child]))
        let original = try Layout(file)
        let layout = try written(session).layout
        #expect(layout.records.map(\.name) == ["</Layer group>", "Child", "Group"])
        #expect(layout.records[0].blocks == original.records[0].blocks)
        #expect(layout.records[2].blocks == original.records[2].blocks)

        var former = pixelLayer("Former folder", try solid(2, 2, [5, 5, 5, 255]))
        former.psdExtras = PSDLayerExtras(blocks: [luni("Former folder"), PSDTaggedBlock(key: "lsct", data: u32Data(1)),
                                                   PSDTaggedBlock(key: "lsdk", data: u32Data(1)),
                                                   PSDTaggedBlock(key: "shmd", data: Data(count: 4))],
                                          importedName: "Former folder", sectionDividerExtras: divider)
        let flattened = try written(self.session(4, 4, [former]))
        #expect(flattened.layout.records.map(\.name) == ["Former folder"])
        #expect(flattened.layout.records[0].keys == ["luni", "lyid", "shmd"])
        #expect(try PSDReader.read(flattened.data).layers.map(\.isGroup) == [false])
    }

    @Test func aPhotoshopBackgroundLayerHasNoTransparencyChannel() throws {
        var background = pixelLayer("Background", try solid(4, 4, [255, 255, 255, 255]))
        background.psdExtras = PSDLayerExtras(blocks: [luni("Background"), PSDTaggedBlock(key: "lnsr", data: Data("bgnd".utf8))],
                                              flags: 0x09, nameSource: "bgnd", isBackground: true, importedName: "Background")
        let dot = pixelLayer("Dot", try solid(1, 1, [255, 0, 0, 255]), at: CGPoint(x: 1, y: 1))
        let (layout, data, _) = try written(session(4, 4, [background, dot]))
        #expect(layout.records[0].channelIDs == [0, 1, 2] && layout.records[1].channelIDs == [-1, 0, 1, 2])
        #expect(layout.records[0].flags & 1 == 1)
        #expect(layout.channels == 3 && layout.layerCount == 2)
        #expect(try PSDReader.read(data).layers[0].image?.width == 4)

        // Given transparency, it keeps a transparency channel.
        var erased = background
        erased.asset = ImportedImage(image: try rgba(2, 1, [255, 255, 255, 255, 0, 0, 0, 0]),
                                     thumbnail: try solid(1, 1, [0, 0, 0, 0]), name: "Background")
        erased.transform.size = CGSize(width: 2, height: 1)
        #expect(try written(session(2, 1, [erased])).layout.records[0].channelIDs == [-1, 0, 1, 2])
    }

    /// The layer import marked as Photoshop's Background is written as one; a layer named by the Background's source
    /// that had transparency in the file isn't. A copy keeps the mark, but only the bottom layer can be the Background.
    @Test func atMostOneBackgroundIsWrittenFromTheImportedMark() throws {
        var background = pixelLayer("Background", try solid(4, 4, [255, 255, 255, 255]))
        background.psdExtras = PSDLayerExtras(blocks: [luni("Background"), PSDTaggedBlock(key: "lnsr", data: Data("bgnd".utf8))],
                                              flags: 0x09, nameSource: "bgnd", isBackground: true, importedName: "Background")
        let copy = background.copy(as: UUID())
        #expect(copy.psdExtras?.isBackground == true)
        let layout = try written(session(4, 4, [background, copy])).layout
        #expect(layout.records.map(\.channelIDs) == [[0, 1, 2], [-1, 0, 1, 2]])
        #expect(layout.records.map { $0.flags & 1 } == [1, 0])

        var named = background
        named.psdExtras?.isBackground = false
        #expect(try written(session(4, 4, [named])).layout.records[0].channelIDs == [-1, 0, 1, 2])
    }

    @Test func layerIDsArePreservedOrAllocatedPastTheLargest() throws {
        var kept = pixelLayer("Kept", try solid(1, 1, [1, 1, 1, 255]))
        kept.psdExtras = PSDLayerExtras(blocks: [luni("Kept"), PSDTaggedBlock(key: "lyid", data: u32Data(5))], layerID: 5,
                                        importedName: "Kept")
        let fresh = pixelLayer("Fresh", try solid(1, 1, [2, 2, 2, 255]))
        var high = pixelLayer("High", try solid(1, 1, [3, 3, 3, 255]))
        high.psdExtras = PSDLayerExtras(blocks: [luni("High"), PSDTaggedBlock(key: "lyid", data: u32Data(9))], layerID: 9,
                                        importedName: "High")
        let copy = kept.copy(as: UUID())
        let (layout, _, _) = try written(session(2, 2, [kept, fresh, high, copy]))
        #expect(layout.records.map { $0.block("lyid") } == [u32Data(5), u32Data(10), u32Data(9), u32Data(11)])
        #expect(layout.records[3].keys == ["luni", "lyid"])
    }

    @Test func rawRecordBytesStayWhileTheModelMatchesThem() throws {
        var base = PSDRecord(id: UUID(), name: "Base")
        base.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        base.image = try solid(2, 2, [255, 255, 255, 255])
        var clipped = PSDRecord(id: UUID(), name: "Clipped")
        clipped.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        clipped.image = try solid(2, 2, [255, 0, 0, 255])
        clipped.clipping = true
        clipped.blendKey = "diss"
        clipped.extras = PSDLayerExtras(blocks: [luni("Clipped")], blendKey: "diss", flags: 0x08, clippingByte: 2,
                                        fillerByte: 7, importedName: "Clipped")
        let (session, _) = try opened(PSDDocument(width: 2, height: 2, resolution: 72, layers: [base, clipped]))
        let record = try written(session).layout.records[1]
        #expect(record.blendKey == "diss" && record.clipping == 2 && record.filler == 7)
        session.document?.layers[1].blendMode = .screen
        session.document?.layers[1].maskSourceID = nil
        let edited = try written(session).layout.records[1]
        #expect(edited.blendKey == "scrn" && edited.clipping == 0 && edited.filler == 7)
    }

    /// A 2×2 record with pixels, clipped or not, for `PSDFixture`.
    private func raster(_ name: String, parent: UUID? = nil, clipped: Bool = false) throws -> PSDRecord {
        var record = PSDRecord(id: UUID(), parentID: parent, name: name)
        record.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        record.image = try solid(2, 2, [200, 100, 50, 255])
        record.clipping = clipped
        return record
    }

    /// A Levels adjustment record for `PSDFixture`.
    private func levelsRecord(_ name: String) -> PSDRecord {
        var record = PSDRecord(id: UUID(), name: name)
        var settings = Data([0, 2])
        for _ in 0..<29 { settings.append(contentsOf: [0, 0, 0, 255, 0, 0, 0, 255, 1, 0]) }
        record.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "levl", data: settings)])
        return record
    }

    @Test func aLayerClippedToAFolderKeepsItsClipping() throws {
        var folderRecord = PSDRecord(id: UUID(), name: "Folder")
        folderRecord.isGroup = true
        let (session, file) = try opened(PSDDocument(width: 4, height: 4, resolution: 72, layers: [
            folderRecord, try raster("Inside", parent: folderRecord.id), try raster("Clipped", clipped: true),
            try raster("Also clipped", clipped: true), try raster("Plain"), try raster("On plain", clipped: true)
        ]))
        // The importer can't clip to a folder: those two come in unclipped.
        #expect(session.document?.layers.filter { $0.maskSourceID != nil }.map(\.name) == ["On plain"])
        let original = try Layout(file)
        let (layout, data, report) = try written(session)
        #expect(layout.records.map(\.name) == ["</Layer group>", "Inside", "Folder", "Clipped", "Also clipped", "Plain", "On plain"])
        #expect(layout.records.map(\.clipping) == original.records.map(\.clipping))
        #expect(layout.records.map(\.clipping) == [0, 0, 0, 1, 1, 0, 1])
        #expect(report.warnings.isEmpty)
        #expect(try PSDReader.read(data).layers.map(\.clipping) == [false, false, true, true, false, true])
    }

    /// Compositor can't clip a folder, so a folder clipped to the layer below it comes in unclipped (a note says so),
    /// and the file's clipping byte stays with it: the document stays valid, and a save writes the folder clipped.
    @Test func aFolderClippedToALayerComesInUnclippedAndIsWrittenClipped() throws {
        var folderRecord = PSDRecord(id: UUID(), name: "Folder")
        folderRecord.isGroup = true
        folderRecord.clipping = true
        let psd = PSDDocument(width: 4, height: 4, resolution: 72, layers: [
            try raster("Base"), folderRecord, try raster("Inside", parent: folderRecord.id)
        ])
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(try PSDFixture.data(psd, composite: try solid(4, 4, [0, 0, 0, 0]))))
        let folder = try #require(imported.layers.first { $0.name == "Folder" })
        #expect(folder.isGroup && folder.maskSourceID == nil && folder.psdExtras?.clippingByte == 1)
        #expect(imported.conversions.contains { $0.layerName == "Folder" })
        #expect(imported.layers.allSatisfy { $0.maskSourceID == nil })

        let (session, file) = try opened(psd)
        let manifest = try #require(session.projectSnapshot()).manifest
        #expect(throws: Never.self) { try LiveMaskGraph.validate(manifest.layers) }
        let (layout, data, report) = try written(session)
        #expect(layout.records.map(\.name) == ["Base", "</Layer group>", "Inside", "Folder"])
        #expect(layout.records.map(\.clipping) == (try Layout(file)).records.map(\.clipping))
        #expect(layout.records.map(\.clipping) == [0, 0, 0, 1])
        #expect(report.warnings.isEmpty)
        #expect(try PSDReader.read(data).layers.first { $0.name == "Folder" }?.clipping == true)
    }

    @Test func aLayerClippedToAFillOrAdjustmentLayerKeepsItsClippingUntilItsBaseChanges() throws {
        var fill = PSDRecord(id: UUID(), name: "Solid")
        fill.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "SoCo", data: try #require(PSDVectorFixtures.rectangle()["SoCo"]))])
        let (session, file) = try opened(PSDDocument(width: 4, height: 4, resolution: 72, layers: [
            fill, try raster("Over fill", clipped: true), levelsRecord("Levels"), try raster("Over levels", clipped: true)
        ]))
        let layers = try #require(session.document?.layers)
        #expect(layers.map(\.name) == ["Solid", "Over fill", "Levels", "Over levels"])
        #expect(layers[0].psdExtras?.placeholder == "fill:SoCo" && layers[2].adjustment != nil)
        #expect(layers.allSatisfy { $0.maskSourceID == nil })
        let original = try Layout(file)
        let (layout, _, report) = try written(session)
        #expect(layout.records.map(\.clipping) == original.records.map(\.clipping))
        #expect(layout.records.map(\.clipping) == [0, 1, 0, 1])
        // The fill is drawn by Photoshop only, so the merged image leaves it out.
        #expect(report.warnings.map(\.layerName) == ["Solid"])
        // Photoshop draws it from the layer: a note, not a lossy change.
        #expect(report.warnings.map(\.lossy) == [false])

        // Without the fill below it, the layer has nothing to clip to and is written unclipped.
        session.document?.layers.removeAll { $0.name == "Solid" }
        #expect(try written(session).layout.records.map(\.clipping) == [0, 0, 1])
    }

    /// A placeholder Photoshop wouldn't draw anyway, inside a hidden folder, costs the merged image nothing, so it
    /// gets no note; shown again with its folder, it does.
    @Test func aPlaceholderInAHiddenFolderGetsNoMergedImageNote() throws {
        let folderID = UUID()
        var folderRecord = PSDRecord(id: folderID, name: "Folder")
        folderRecord.isGroup = true
        folderRecord.isVisible = false
        var fill = PSDRecord(id: UUID(), parentID: folderID, name: "Solid")
        fill.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "SoCo", data: try #require(PSDVectorFixtures.rectangle()["SoCo"]))])
        let (session, _) = try opened(PSDDocument(width: 4, height: 4, resolution: 72, layers: [folderRecord, fill]))
        #expect(session.document?.layers.first { $0.name == "Solid" }?.psdExtras?.placeholder == "fill:SoCo")
        #expect(try written(session).report.warnings.isEmpty)
        let index = try #require(session.document?.layers.firstIndex { $0.name == "Folder" })
        session.document?.layers[index].isVisible = true
        #expect(try written(session).report.warnings.map(\.layerName) == ["Solid"])
    }

    /// Releasing a clip Compositor modeled (a drag out of the clipping group, deleting the base, Release Clipping
    /// Mask) clears the file's clipping byte too: otherwise a layer left on a folder or an adjustment would be saved
    /// clipped to it, which Compositor doesn't show.
    @Test func aReleasedClipIsWrittenUnclippedWhateverNowLiesBelowIt() throws {
        var folderRecord = PSDRecord(id: UUID(), name: "Folder")
        folderRecord.isGroup = true
        let document = PSDDocument(width: 4, height: 4, resolution: 72, layers: [
            folderRecord, try raster("Inside", parent: folderRecord.id), levelsRecord("Levels"), try raster("P"),
            try raster("C", clipped: true)
        ])
        func layer(_ name: String, in session: EditorSession) throws -> ImageLayer {
            try #require(session.document?.layers.first { $0.name == name })
        }
        func clipping(_ session: EditorSession) throws -> [String] {
            let (layout, _, report) = try written(session)
            #expect(report.warnings.isEmpty)
            return layout.records.map { "\($0.name) \($0.clipping)" }
        }
        let unedited = ["</Layer group> 0", "Inside 0", "Folder 0", "Levels 0", "P 0", "C 1"]

        // Dragged directly above the folder: Compositor releases the clip, and so does the file.
        let dragged = try opened(document).session
        let imported = try layer("C", in: dragged)
        #expect(try imported.maskSourceID == layer("P", in: dragged).id && imported.psdExtras?.clippingByte == 1)
        #expect(try clipping(dragged) == unedited)
        #expect(dragged.placeLayer(try layer("C", in: dragged).id, in: nil, above: try layer("Folder", in: dragged).id))
        #expect(try layer("C", in: dragged).maskSourceID == nil)
        #expect(try clipping(dragged) == ["</Layer group> 0", "Inside 0", "Folder 0", "C 0", "Levels 0", "P 0"])
        dragged.undo()
        #expect(try clipping(dragged) == unedited)

        // Dragged directly above the adjustment layer.
        #expect(dragged.placeLayer(try layer("C", in: dragged).id, in: nil, above: try layer("Levels", in: dragged).id))
        #expect(try layer("C", in: dragged).maskSourceID == nil)
        #expect(try clipping(dragged) == ["</Layer group> 0", "Inside 0", "Folder 0", "Levels 0", "C 0", "P 0"])

        // Its base deleted, with the link removed, which leaves it on the adjustment layer.
        let orphaned = try opened(document).session
        orphaned.finishDeletingLayer(try layer("P", in: orphaned).id, baked: [:])
        #expect(try layer("C", in: orphaned).maskSourceID == nil)
        #expect(try clipping(orphaned) == ["</Layer group> 0", "Inside 0", "Folder 0", "Levels 0", "C 0"])

        // Released with Release Clipping Mask, then moved onto the folder.
        let released = try opened(document).session
        released.removeLiveMask(from: try layer("C", in: released).id)
        #expect(try clipping(released) == ["</Layer group> 0", "Inside 0", "Folder 0", "Levels 0", "P 0", "C 0"])
        #expect(released.placeLayer(try layer("C", in: released).id, in: nil, above: try layer("Folder", in: released).id))
        #expect(try clipping(released) == ["</Layer group> 0", "Inside 0", "Folder 0", "C 0", "Levels 0", "P 0"])
    }

    /// A clipped layer copied into another project has its clipping baked into its pixels, so it lands unclipped,
    /// even on a folder.
    @Test func aClippedLayerCopiedIntoAnotherProjectIsWrittenUnclipped() async throws {
        let workspace = ProjectWorkspace()
        let source = workspace.current.session
        _ = try opened(PSDDocument(width: 4, height: 4, resolution: 72, layers: [try raster("P"), try raster("C", clipped: true)]),
                       into: source)
        let clipped = try #require(source.document?.layers.first { $0.name == "C" })
        #expect(clipped.maskSourceID != nil && clipped.psdExtras?.clippingByte == 1)
        let target = workspace.addTab()
        target.session.createDocument(width: 4, height: 4)
        target.session.document?.layers = [folder("Folder", id: UUID(), canvas: CGSize(width: 4, height: 4))]
        await workspace.copyLayer(clipped.id, into: target.id)
        let copied = try #require(target.session.document?.layers.last)
        #expect(copied.name == "C" && copied.maskSourceID == nil)
        let (layout, _, report) = try written(target.session)
        #expect(layout.records.map(\.name) == ["</Layer group>", "Folder", "C"])
        #expect(layout.records.map(\.clipping) == [0, 0, 0])
        #expect(report.warnings.isEmpty)
    }

    @Test func aClippedFolderKeepsItsClippingAndTheGroupAboveItsBaseStays() throws {
        let baseID = UUID(), folderID = UUID()
        let base = pixelLayer("Base", try solid(2, 2, [255, 255, 255, 255]), id: baseID)
        var group = folder("Folder", id: folderID, canvas: CGSize(width: 2, height: 2))
        group.psdExtras = PSDLayerExtras(blocks: [luni("Folder"), PSDTaggedBlock(key: "lsct", data: u32Data(1) + Data("8BIMpass".utf8))],
                                         blendKey: "pass", flags: 0x18, clippingByte: 1, importedName: "Folder")
        let inside = pixelLayer("Inside", try solid(2, 2, [0, 0, 255, 255]), parent: folderID)
        var above = pixelLayer("Above", try solid(2, 2, [255, 0, 0, 255]))
        above.maskSourceID = baseID
        let (layout, data, report) = try written(session(2, 2, [base, group, inside, above]))
        #expect(layout.records.map(\.name) == ["Base", "</Layer group>", "Inside", "Folder", "Above"])
        #expect(layout.records.map(\.clipping) == [0, 0, 0, 1, 1])
        #expect(report.warnings.isEmpty)
        #expect(try PSDReader.read(data).layers.map(\.clipping) == [false, false, true, true])
    }

    @Test func locksAndFillAreWrittenForNewLayers() throws {
        var layer = pixelLayer("Locked", try solid(1, 1, [1, 2, 3, 255]))
        layer.locks = [.transparency, .position]
        layer.fillOpacity = 0.5
        let (layout, data, _) = try written(session(1, 1, [layer]))
        let record = layout.records[0]
        #expect(record.block("lspf") == u32Data(5) && record.block("iOpa") == Data([128, 0, 0, 0]))
        #expect(record.keys.last == "iOpa" && record.flags & 1 == 1)
        let document = try PSDReader.read(data)
        #expect(document.layers[0].locks == [.transparency, .position] && abs(document.layers[0].fillOpacity - 128.0 / 255) < 0.0001)
    }

    // MARK: Locks, labels, fill and guides

    @Test func locksAreTheModelsWithNestingAndUnknownBitsOnlyFromTheFile() throws {
        // A Photoshop Background's locks (transparency, position, artboard nesting) and a bit Compositor doesn't know.
        var photo = try raster("Photo")
        photo.locks = LayerLocks(rawValue: 0x10D)
        let (session, file) = try opened(PSDDocument(width: 2, height: 2, resolution: 72, layers: [photo]))
        let original = try Layout(file).records[0]
        #expect(try written(session).layout.records[0].block("lspf") == original.block("lspf"))
        // Unlocking position and locking all, as `set_layer_locks` does: nesting and the unknown bit stay.
        session.document?.layers[0].locks.remove(.position)
        session.document?.layers[0].locks.insert(.all)
        let edited = try written(session)
        #expect(edited.layout.records[0].block("lspf") == u32Data(0x8000_0109))
        #expect(edited.layout.records[0].keys.filter { $0 == "lspf" }.count == 1 && edited.layout.records[0].flags & 0x01 == 0x01)
        #expect(try PSDReader.read(edited.data).layers[0].locks == LayerLocks(rawValue: 0x8000_0109))
        // Written without the file's Photoshop data, only the locks Compositor models remain.
        let plain = try written(session, PSDWriteOptions(preserveExtras: false))
        #expect(plain.layout.records[0].block("lspf") == u32Data(0x8000_0001))
        #expect(try PSDReader.read(plain.data).layers[0].locks == [.transparency, .all])
        // The same for a layer Photoshop never saw.
        var fresh = pixelLayer("Fresh", try solid(1, 1, [1, 2, 3, 255]))
        fresh.locks = LayerLocks(rawValue: 0x40).union([.pixels, .artboardNesting, .all])
        let new = try written(self.session(1, 1, [fresh]))
        #expect(new.layout.records[0].block("lspf") == u32Data(0x8000_0002))
        #expect(new.layout.records[0].flags & 0x01 == 0x01)
        #expect(try PSDReader.read(new.data).layers[0].locks == [.pixels, .all])
    }

    @Test func colorLabelsAreWrittenAsLclrAndLabelsCompositorDoesntKnowStay() throws {
        var records = try LayerColorLabel.allCases.map { label in
            var record = try raster("\(label)")
            record.extras = PSDLayerExtras(colorLabel: label, importedName: "\(label)")
            return record
        }
        // A color Photoshop may add later: read as no label, written back as the file had it.
        let future = Data([0, 9, 0, 0, 0, 0, 0, 0])
        var later = try raster("Later")
        later.extras = PSDLayerExtras(blocks: [luni("Later"), PSDTaggedBlock(key: "lclr", data: future)], importedName: "Later")
        records.append(later)
        let (session, file) = try opened(PSDDocument(width: 2, height: 2, resolution: 72, layers: records))
        let original = try Layout(file)
        let (layout, data, _) = try written(session)
        #expect(layout.records.map { $0.block("lclr") } == original.records.map { $0.block("lclr") })
        #expect(layout.records.last?.block("lclr") == future)
        #expect(try PSDReader.read(data).layers.map { $0.extras?.colorLabel } == LayerColorLabel.allCases + [LayerColorLabel.none])

        // A label given where the file had none is added last; one changed is rewritten in place.
        session.document?.layers[0].psdExtras?.colorLabel = .blue
        session.document?.layers[records.count - 1].psdExtras?.colorLabel = .red
        let edited = try written(session)
        #expect(edited.layout.records[0].keys.last == "lclr")
        #expect(edited.layout.records[0].block("lclr") == Data([0, 5, 0, 0, 0, 0, 0, 0]))
        #expect(edited.layout.records.last?.block("lclr") == Data([0, 1, 0, 0, 0, 0, 0, 0]))
        #expect(edited.layout.records.last?.keys == ["luni", "lyid", "lclr"])
        let reread = try PSDReader.read(edited.data).layers
        #expect(reread.first?.extras?.colorLabel == .blue && reread.last?.extras?.colorLabel == .red)
        // A layer Photoshop never saw has no label.
        let fresh = try written(self.session(1, 1, [pixelLayer("Fresh", try solid(1, 1, [1, 2, 3, 255]))]))
        #expect(fresh.layout.records[0].block("lclr") == Data(count: 8))
    }

    @Test func fillIsWrittenAsIOpaApartFromOpacityAndReadBack() throws {
        var half = pixelLayer("Half", try solid(1, 1, [1, 2, 3, 255]))
        half.fillOpacity = 0.5
        half.opacity = 0.25
        var empty = pixelLayer("Empty", try solid(1, 1, [1, 2, 3, 255]))
        empty.fillOpacity = 0
        let full = pixelLayer("Full", try solid(1, 1, [1, 2, 3, 255]))
        let (layout, data, _) = try written(session(1, 1, [half, empty, full]))
        #expect(layout.records.map { $0.block("iOpa") } == [Data([128, 0, 0, 0]), Data([0, 0, 0, 0]), nil])
        #expect(layout.records.map(\.opacity) == [64, 255, 255])
        let document = try PSDReader.read(data)
        #expect(document.layers.map(\.fillOpacity) == [128.0 / 255, 0, 1] && document.layers[0].opacity == 64.0 / 255)

        // The file's Fill stays while the layer matches it, and is rewritten in place once it doesn't.
        var faded = try raster("Faded")
        faded.fillOpacity = 0.2
        let (session, file) = try opened(PSDDocument(width: 2, height: 2, resolution: 72, layers: [faded]))
        #expect(try Layout(file).records[0].keys == ["luni", "iOpa"])
        #expect(try written(session).layout.records[0].block("iOpa") == Data([51, 0, 0, 0]))
        session.document?.layers[0].fillOpacity = 1
        let edited = try written(session)
        #expect(edited.layout.records[0].keys == ["luni", "lyid", "iOpa"])
        #expect(edited.layout.records[0].block("iOpa") == Data([255, 0, 0, 0]))
        #expect(try PSDReader.read(edited.data).layers[0].fillOpacity == 1)
    }

    @Test func guidesAreWrittenInThirtySecondsOfAPixelOnPhotoshopsDefaultGrid() throws {
        let session = session(4, 4, [pixelLayer("Layer", try solid(4, 4, [1, 2, 3, 255]))])
        session.document?.guides = [CanvasGuide(id: UUID(), axis: .vertical, position: 10.5),
                                    CanvasGuide(id: UUID(), axis: .horizontal, position: 1.0 / 64),
                                    CanvasGuide(id: UUID(), axis: .horizontal, position: -2.25),
                                    CanvasGuide(id: UUID(), axis: .vertical, position: 3.3),
                                    CanvasGuide(id: UUID(), axis: .vertical, position: 2_000_000)]
        let (layout, data, _) = try written(session)
        // Half a thirty-second rounds away from zero; a guide beyond what the reader keeps is left out.
        #expect(layout.resources.first { $0.id == 1032 }?.data == guidesResource([(336, 0), (1, 1), (-72, 1), (106, 0)]))
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        #expect(imported.guides.map(\.axis) == [.vertical, .horizontal, .horizontal, .vertical])
        #expect(imported.guides.map(\.position) == [10.5, 1.0 / 32, -2.25, 106.0 / 32])
    }

    // MARK: Pass-through

    /// Resource 1032: version 1, the grid cycle, then each guide as a position in 1/32 px and a direction.
    private func guidesResource(grid: UInt32 = 576, _ guides: [(position: Int32, direction: UInt8)]) -> Data {
        var data = u32Data(1) + u32Data(grid) + u32Data(grid) + u32Data(UInt32(guides.count))
        for guide in guides { data += u32Data(UInt32(bitPattern: guide.position)) + Data([guide.direction]) }
        return data
    }

    @Test func resourcesKeepTheFilesOrderWithTheModeledOnesRegeneratedInPlace() throws {
        let bottom = pixelLayer("Bottom", try solid(2, 2, [255, 0, 0, 255]))
        let middle = pixelLayer("Middle", try solid(1, 1, [0, 255, 0, 255]))
        let top = pixelLayer("Top", try solid(1, 1, [0, 0, 255, 255]))
        let session = session(2, 2, [bottom, middle, top], active: middle.id)
        session.document?.resolution = 144
        session.document?.guides = [CanvasGuide(id: UUID(), axis: .vertical, position: 10.5),
                                    CanvasGuide(id: UUID(), axis: .horizontal, position: 3)]
        let stale = Data([0xEE, 0xEE])
        let own = [PSDImageResource(id: 1061, name: "", data: Data([1, 2, 3, 4])),
                   PSDImageResource(id: 1037, name: "", data: u32Data(30)),
                   PSDImageResource(id: 4000, name: "Plugin", data: Data([1, 2, 3])),
                   PSDImageResource(id: 1058, name: "", data: Data([5, 6]))]
        var extras = PSDDocumentExtras()
        extras.resources = [own[0], PSDImageResource(id: 1005, name: "", data: stale), own[1], own[2],
                            PSDImageResource(id: 1024, name: "", data: stale), PSDImageResource(id: 1026, name: "", data: stale),
                            PSDImageResource(id: 1072, name: "", data: stale), PSDImageResource(id: 1069, name: "", data: stale),
                            PSDImageResource(id: 1032, name: "", data: guidesResource([(64, 1)])),
                            PSDImageResource(id: 1036, name: "", data: Data(count: 28)),
                            PSDImageResource(id: 1057, name: "", data: stale), own[3]]
        session.document?.psdExtras = extras
        let (layout, data, _) = try written(session)
        #expect(layout.resources.map(\.id) == [1061, 1005, 1037, 4000, 1024, 1026, 1072, 1069, 1032, 1057, 1058])
        #expect(layout.resources.filter { [1061, 1037, 4000, 1058].contains($0.id) } == own)
        func resource(_ id: UInt16) throws -> Data { try #require(layout.resources.first { $0.id == id }).data }
        #expect(try resource(1005) == u32Data(144 << 16) + Data([0, 1, 0, 1]) + u32Data(144 << 16) + Data([0, 1, 0, 1]))
        #expect(try resource(1024) == Data([0, 1]))
        #expect(try resource(1026) == Data(count: 6) && resource(1072) == Data([1, 1, 1]))
        #expect(try resource(1069) == Data([0, 1]) + (layout.records[1].block("lyid") ?? Data()))
        #expect(try resource(1032) == guidesResource([(336, 0), (96, 1)]))
        #expect(try resource(1057).prefix(5) == Data([0, 0, 0, 1, 1]))
        let reread = try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
        #expect(reread.guides.map(\.axis) == [.vertical, .horizontal] && reread.guides.map(\.position) == [10.5, 3])

        // Regenerated resources the file lacks go where Photoshop writes them.
        session.document?.psdExtras?.resources = [own[1], own[2]]
        #expect(try written(session).layout.resources.map(\.id) == [1005, 1037, 4000, 1024, 1026, 1072, 1069, 1032, 1057])
        #expect(try written(session, PSDWriteOptions(preserveExtras: false)).layout.resources.map(\.id)
                    == [1005, 1024, 1026, 1072, 1069, 1032, 1057])
    }

    @Test func guidesAreWrittenFromTheDocumentOnTheFilesGrid() throws {
        let session = session(4, 4, [pixelLayer("Layer", try solid(4, 4, [1, 2, 3, 255]))])
        session.document?.guides = [CanvasGuide(id: UUID(), axis: .horizontal, position: 2.25)]
        var extras = PSDDocumentExtras()
        extras.resources = [PSDImageResource(id: 1032, name: "", data: guidesResource(grid: 288, [(32, 0), (64, 0)]))]
        session.document?.psdExtras = extras
        func guides() throws -> Data? { try written(session).layout.resources.first { $0.id == 1032 }?.data }
        #expect(try guides() == guidesResource(grid: 288, [(72, 1)]))
        // With every guide removed, the file keeps its grid and lists none; a document that never had any writes none.
        session.document?.guides = []
        #expect(try guides() == guidesResource(grid: 288, []))
        session.document?.psdExtras = nil
        #expect(try guides() == nil)
    }

    // MARK: Canvas-relative resources

    /// A saved path (resource 2000): one closed subpath of `anchors`, given in document pixels of a `canvas`-sized file,
    /// each knot's control points at its anchor, then its clipboard record. Records are 26 bytes; points are 8.24
    /// fractions of the canvas, `y` first.
    private func savedPath(_ anchors: [CGPoint], canvas: CGSize) -> Data {
        func fixed(_ value: CGFloat) -> [UInt8] {
            let raw = UInt32(bitPattern: Int32((value * 0x1000000).rounded()))
            return [UInt8(raw >> 24), UInt8(raw >> 16 & 0xFF), UInt8(raw >> 8 & 0xFF), UInt8(raw & 0xFF)]
        }
        var data = Data([0, 6] + Array(repeating: 0, count: 24))
        data += Data([0, 0, 0, UInt8(anchors.count)] + Array(repeating: 0, count: 22))
        for anchor in anchors {
            let point = fixed(anchor.y / canvas.height) + fixed(anchor.x / canvas.width)
            data += Data([0, 2] + point + point + point)
        }
        let xs = anchors.map(\.x), ys = anchors.map(\.y)
        data += Data([0, 7] + fixed(ys.min()! / canvas.height) + fixed(xs.min()! / canvas.width)
                     + fixed(ys.max()! / canvas.height) + fixed(xs.max()! / canvas.width) + fixed(1) + [0, 0, 0, 0])
        return data
    }

    /// The anchors of a saved path's knots, in document pixels of a `canvas`-sized file.
    private func anchors(_ path: Data, canvas: CGSize) -> [CGPoint] {
        stride(from: 0, to: path.count - 25, by: 26).compactMap { start -> CGPoint? in
            let selector = Int(path[start]) << 8 | Int(path[start + 1])
            guard [1, 2, 4, 5].contains(selector) else { return nil }
            func fraction(_ at: Int) -> CGFloat {
                CGFloat(Int32(bitPattern: path[at ..< at + 4].reduce(0) { $0 << 8 | UInt32($1) })) / 0x1000000
            }
            return CGPoint(x: (fraction(start + 14) * canvas.width).rounded(), y: (fraction(start + 10) * canvas.height).rounded())
        }
    }

    /// A saved path's clipboard record (selector 7): its bounds (top +2, left +6, bottom +10, right +14) in document
    /// pixels of a `canvas`-sized file, and its resolution field (+18).
    private func clipboard(_ path: Data, canvas: CGSize) -> (bounds: CGRect, resolution: CGFloat)? {
        guard let start = stride(from: 0, to: path.count - 25, by: 26).first(where: { Int(path[$0]) << 8 | Int(path[$0 + 1]) == 7 })
        else { return nil }
        func fraction(_ at: Int) -> CGFloat {
            CGFloat(Int32(bitPattern: path[at ..< at + 4].reduce(0) { $0 << 8 | UInt32($1) })) / 0x1000000
        }
        let top = fraction(start + 2) * canvas.height, left = fraction(start + 6) * canvas.width
        let bottom = fraction(start + 10) * canvas.height, right = fraction(start + 14) * canvas.width
        return (CGRect(x: left.rounded(), y: top.rounded(), width: (right - left).rounded(), height: (bottom - top).rounded()),
                fraction(start + 18))
    }

    /// Saved paths hold fractions of the file's canvas: written back as they were while it is the document's, and
    /// placed where Crop, Image Size and Flip Canvas took the canvas's pixels otherwise, as guides are: every knot, and
    /// the clipboard record's bounds (its resolution untouched). The slices resource, pixels on the old canvas, is left
    /// out once the canvas changed.
    @Test func savedPathsFollowTheCanvas() async throws {
        let canvas = CGSize(width: 40, height: 20)
        let corners = [CGPoint(x: 6, y: 4), CGPoint(x: 22, y: 4), CGPoint(x: 22, y: 16), CGPoint(x: 6, y: 16)]
        let path = savedPath(corners, canvas: canvas)
        let slices = PSDImageResource(id: 1050, name: "", data: Data(count: 24))
        var layer = PSDRecord(id: UUID(), name: "Layer")
        layer.bounds = CGRect(origin: .zero, size: canvas)
        layer.image = try solid(40, 20, [200, 100, 50, 255])
        let document = PSDDocument(width: 40, height: 20, resolution: 72, layers: [layer], extras: PSDDocumentExtras(
            resources: [PSDImageResource(id: 2000, name: "Outline", data: path), slices]))
        func written(_ session: EditorSession) throws -> (path: Data?, slices: Bool) {
            let resources = try self.written(session).layout.resources
            return (resources.first { $0.id == 2000 }?.data, resources.contains { $0.id == 1050 })
        }

        let (untouched, _) = try opened(document)
        #expect(try written(untouched).path == path && written(untouched).slices)

        let (cropped, _) = try opened(document)
        let crop = try await CanvasResizer.shared.resize(try #require(cropped.projectSnapshot()),
            to: CanvasSizeOptions(width: 30, height: 20, contentOffset: CGPoint(x: -5, y: 0)))
        cropped.applyDocumentSize(crop, actionName: "Crop")
        let moved = try written(cropped)
        #expect(anchors(try #require(moved.path), canvas: CGSize(width: 30, height: 20)) == corners.map { CGPoint(x: $0.x - 5, y: $0.y) })
        let movedClipboard = clipboard(try #require(moved.path), canvas: CGSize(width: 30, height: 20))
        #expect(movedClipboard?.bounds == CGRect(x: 1, y: 4, width: 16, height: 12) && movedClipboard?.resolution == 1)
        #expect(!moved.slices)

        let (resized, _) = try opened(document)
        let half = try await ImageResizer.shared.resize(try #require(resized.projectSnapshot()),
                                                        to: ImageSizeOptions(width: 20, height: 10, resolution: 72))
        resized.applyImageSize(half)
        let scaled = try #require(try written(resized).path)
        #expect(anchors(scaled, canvas: CGSize(width: 20, height: 10)) == corners.map { CGPoint(x: $0.x / 2, y: $0.y / 2) })
        let scaledClipboard = clipboard(scaled, canvas: CGSize(width: 20, height: 10))
        #expect(scaledClipboard?.bounds == CGRect(x: 3, y: 2, width: 8, height: 6) && scaledClipboard?.resolution == 1)

        let (flipped, _) = try opened(document)
        flipped.flipCanvas(horizontally: true)
        let mirrored = try #require(try written(flipped).path)
        #expect(Set(anchors(mirrored, canvas: canvas)) == Set(corners.map { CGPoint(x: 40 - $0.x, y: $0.y) }))
        let mirroredClipboard = clipboard(mirrored, canvas: canvas)
        #expect(mirroredClipboard?.bounds == CGRect(x: 18, y: 4, width: 16, height: 12) && mirroredClipboard?.resolution == 1)
    }

    /// Alpha and spot channels (saved selections) aren't kept: the file opens with a note, and a save warns (lossy:
    /// they are gone from the file) and leaves out the resources that describe them, so the file it writes describes
    /// only the channels it has.
    @Test func alphaChannelsAreNotedAndTheResourcesDescribingThemLeftOut() throws {
        let extras = PSDDocumentExtras(resources: [PSDFixture.alphaChannelNamesResource(["Alpha 1"]),
                                                   PSDFixture.unicodeAlphaChannelNamesResource(["Alpha 1"]),
                                                   PSDImageResource(id: 1053, name: "", data: Data([0, 0, 0, 7])),
                                                   PSDImageResource(id: 1077, name: "", data: Data(count: 20)),
                                                   PSDImageResource(id: 4000, name: "Plug-in", data: Data([1, 2]))])
        let document = PSDDocument(width: 2, height: 2, resolution: 72, layers: [try raster("Layer")], extras: extras)
        let file = try PSDFixture.data(document, composite: try solid(2, 2, [0, 0, 0, 255]))
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(file))
        #expect(imported.conversions.map(\.message).filter { $0.contains("alpha or spot channel") }.count == 1)

        let (session, _) = try opened(document)
        let (layout, _, report) = try written(session)
        let warning = try #require(report.warnings.first { $0.message.contains("alpha or spot channel") })
        #expect(warning.lossy && warning.message.hasSuffix("doesn’t keep it."))
        #expect(!layout.resources.contains { [1006, 1045, 1053, 1077].contains($0.id) })
        #expect(layout.resources.contains { $0.id == 4000 })
    }

    @Test func theGlobalMaskInfoDocumentBlocksAndOrphanedLinkedEntriesAreWrittenBack() throws {
        let session = session(2, 2, [pixelLayer("Layer", try solid(2, 2, [1, 2, 3, 255]))])
        var extras = PSDDocumentExtras()
        extras.globalLayerMaskInfo = Data([0, 0, 0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0x64, 0x80, 0])
        extras.globalBlocks = [PSDTaggedBlock(key: "Patt", data: Data([1, 2, 3, 4, 5])),
                               PSDTaggedBlock(key: "Txt2", data: Data("text".utf8))]
        extras.orphanLinkedEntries = [Data([9, 9, 9]), Data(0..<8)]
        // As read from a file without type layers: its `Txt2` describes none, so it still holds.
        extras.importedTextIndices = []
        session.document?.psdExtras = extras
        let (layout, data, _) = try written(session)
        #expect(layout.globalMaskInfo == extras.globalLayerMaskInfo)
        let linked = PSDTaggedBlock(key: "lnk2", data: PSDBlockFile.encode(linkedEntries: extras.orphanLinkedEntries))
        #expect(layout.globalBlocks == [linked] + extras.globalBlocks)
        #expect(try PSDReader.read(data).extras?.globalLayerMaskInfo == extras.globalLayerMaskInfo)
        let plain = try written(session, PSDWriteOptions(preserveExtras: false)).layout
        #expect(plain.globalMaskInfo.isEmpty && plain.globalBlocks.isEmpty)
    }

    @Test func aNegativeLayerCountStaysNegativeWhenTheCompositeIsOpaque() throws {
        let session = session(2, 2, [pixelLayer("Opaque", try solid(2, 2, [10, 20, 30, 255]))])
        session.document?.psdExtras = PSDDocumentExtras(layerCountNegative: true)
        let (layout, data, report) = try written(session)
        #expect(layout.channels == 4 && layout.layerCount == -1 && report.wroteTransparencyChannel)
        #expect(layout.composite.map { $0[0] } == [10, 20, 30, 255] && layout.composite[3].allSatisfy { $0 == 255 })
        #expect(try PSDReader.read(data).extras?.layerCountNegative == true)
        #expect(try written(session, PSDWriteOptions(preserveExtras: false)).layout.layerCount == 1)
    }

    @Test func maskFlagsAndParametersAreWrittenBack() throws {
        // User mask density 200 and feather 2.5 px.
        let parameters = Data([0x03, 200]) + withUnsafeBytes(of: (2.5).bitPattern.bigEndian) { Data($0) }
        let realMask = Data([0x00, 255]) + Data(count: 16)
        func masked(_ name: String, flags: UInt8, tail: Data) throws -> PSDRecord {
            var record = try raster(name)
            record.mask = try gray(2, 2, [255, 0, 0, 255])
            record.extras = PSDLayerExtras(blocks: [luni(name)], flags: 0x08, maskFlags: flags, maskDefaultColor: 0,
                                           maskParameters: tail, importedName: name)
            return record
        }
        let records = [try masked("Parameters", flags: 0x34, tail: parameters),
                       try masked("Real and parameters", flags: 0x10, tail: realMask + parameters + Data(count: 2)),
                       try masked("Real only", flags: 0x00, tail: realMask)]
        let (session, _) = try opened(PSDDocument(width: 2, height: 2, resolution: 72, layers: records))
        let (layout, data, _) = try written(session)
        // Invert (0x04) and the undocumented bits stay; the real user mask, whose channel isn't written, doesn't.
        #expect(layout.records.map(\.maskFlags) == [0x34, 0x10, 0x00])
        #expect(layout.records.map(\.maskTail) == [parameters, parameters, Data(count: 2)])
        #expect(layout.records.map(\.maskLength) == [28, 28, 20])
        let reread = try PSDReader.read(data)
        #expect(reread.layers[0].extras?.maskFlags == 0x34 && reread.layers[0].extras?.maskParameters == parameters)
        #expect(reread.layers[0].mask != nil && reread.layers[0].maskEnabled)

        session.document?.layers[0].mask?.isEnabled = false
        session.document?.layers[0].mask?.isLinked = false
        let edited = try written(session).layout.records[0]
        #expect(edited.maskFlags == 0x37 && edited.maskTail == parameters)
    }

    @Test func modeledBlocksAreRewrittenWhereTheFileHadThem() throws {
        var photo = try raster("Photo")
        let keys = ["luni", "lnsr", "lyid", "clbl", "infx", "knko", "lspf", "iOpa", "lclr", "shmd", "fxrp"]
        let payloads: [String: Data] = ["luni": luni("Photo").data, "lnsr": Data("layr".utf8), "lyid": u32Data(12),
                                        "clbl": Data([1, 0, 0, 0]), "infx": Data(count: 4), "knko": Data(count: 4),
                                        "lspf": u32Data(0), "iOpa": Data([255, 0, 0, 0]),
                                        "lclr": Data(count: 8), "shmd": Data(0..<16), "fxrp": Data(count: 16)]
        photo.extras = PSDLayerExtras(blocks: keys.map { PSDTaggedBlock(key: $0, data: payloads[$0]!) },
                                      blendingRanges: Data(repeating: 0xCD, count: 40), flags: 0x18, layerID: 12,
                                      nameSource: "layr", importedName: "Photo")
        let (session, file) = try opened(PSDDocument(width: 2, height: 2, resolution: 72, layers: [photo]))
        let original = try Layout(file).records[0]
        #expect(try written(session).layout.records[0].blocks == original.blocks)
        session.document?.layers[0].locks = [.position]
        session.document?.layers[0].fillOpacity = 0.5
        session.document?.layers[0].psdExtras?.colorLabel = .green
        let edited = try written(session).layout.records[0]
        #expect(edited.keys == keys)
        #expect(edited.block("lspf") == u32Data(LayerLocks.position.rawValue) && edited.block("iOpa") == Data([128, 0, 0, 0]))
        #expect(edited.block("lclr")?.prefix(2) == Data([0, UInt8(LayerColorLabel.green.rawValue)]))
        #expect(edited.blocks.filter { !["lspf", "iOpa", "lclr"].contains($0.key) }
                    == original.blocks.filter { !["lspf", "iOpa", "lclr"].contains($0.key) })
        #expect(edited.blendingRanges == Data(repeating: 0xCD, count: 40) && edited.flags == 0x18)
    }

    // MARK: Refusals

    @Test func adjustmentLayersPhotoshopLacksAreRefused() throws {
        let adjustment = ImageLayer(id: UUID(), asset: nil, name: "Grain", isVisible: true,
                                    transform: LayerTransform(origin: .zero, size: CGSize(width: 2, height: 2)),
                                    adjustment: LayerAdjustment(kind: .grain))
        let request = try #require(session(2, 2, [pixelLayer("Pixels", try solid(2, 2, [1, 1, 1, 255])), adjustment]).psdWriteRequest())
        #expect(throws: PSDWriteError.unsupportedAdjustment(layerName: "Grain", kind: .grain)) {
            try PSDWriter.data(for: request)
        }
    }

    // MARK: Request and files

    @Test func theWriteRequestCarriesTheLiveSessionsPhotoshopData() throws {
        var layer = pixelLayer("Layer", try solid(1, 1, [1, 1, 1, 255]))
        layer.locks = [.position]
        layer.fillOpacity = 0.25
        layer.psdExtras = PSDLayerExtras(layerID: 3)
        let session = session(1, 1, [layer])
        session.document?.resolution = 300
        session.document?.guides = [CanvasGuide(id: UUID(), axis: .vertical, position: 0.5)]
        session.document?.psdExtras = PSDDocumentExtras(channelCount: 4)
        let request = try #require(session.psdWriteRequest())
        let sidecar = try #require(request.sidecars[layer.id])
        #expect(sidecar.locks == [.position] && sidecar.fillOpacity == 0.25 && sidecar.extras?.layerID == 3)
        #expect(request.document.resolution == 300 && request.document.guides.count == 1)
        #expect(request.document.activeLayerID == layer.id && request.document.extras?.channelCount == 4)
        #expect(request.snapshot.manifest.layers.map(\.id) == [layer.id])
        #expect(EditorSession().psdWriteRequest() == nil)
    }

    @Test func writingAFileMatchesTheBytesAndReplacesTheDestination() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PSDWriterTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Out.psd")
        try Data("old".utf8).write(to: url)
        let request = try #require(session(3, 3, [pixelLayer("Layer", try solid(2, 2, [9, 9, 9, 255]))]).psdWriteRequest())
        let report = try PSDWriter.write(request, to: url)
        let bytes = try Data(contentsOf: url)
        let expected = try PSDWriter.data(for: request).data
        #expect(bytes == expected && report.byteCount == bytes.count)
        let exported = folder.appendingPathComponent("Exported.psd")
        _ = try await PSDExporter.shared.export(request, to: exported, options: PSDWriteOptions())
        #expect(try Data(contentsOf: exported) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["Exported.psd", "Out.psd"])
        let missing = folder.appendingPathComponent("Missing/Out.psd")
        #expect(throws: PSDWriteError.self) { try PSDWriter.write(request, to: missing) }
    }

    /// A save checked first (its warnings) is written from that plan, not planned again: the file is the document as
    /// it was planned, whatever happened to the session since.
    @Test func aPlannedSaveIsWrittenAsPlanned() async throws {
        let session = session(3, 3, [pixelLayer("Planned", try solid(2, 2, [9, 9, 9, 255]))])
        let plan = try await PSDExporter.shared.plan(try #require(session.psdWriteRequest()), options: PSDWriteOptions())
        session.document?.layers[0].name = "Renamed"
        let written = try PSDWriter.data(for: plan)
        #expect(try PSDReader.read(written.data).layers.map(\.name) == ["Planned"])
        #expect(written.report.warnings == plan.warnings)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PSDWriterTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Planned.psd")
        _ = try await PSDExporter.shared.export(plan, to: url)
        #expect(try Data(contentsOf: url) == written.data)
    }

    /// The merged image is rendered last, once every layer record and the document's blocks are written, so its
    /// planes are never in memory beside the layers'; the header's channel count and the layer count's sign, which
    /// depend on it, are filled in then.
    @Test func theMergedImageIsRenderedAfterTheLayers() throws {
        final class Sink: PSDByteSink {
            var data = Data()
            var count: Int { data.count }
            func append(_ bytes: Data) { data.append(bytes) }
            func overwrite(_ bytes: Data, at offset: Int) { data.replaceSubrange(offset ..< offset + bytes.count, with: bytes) }
        }
        for (pixel, transparent) in [([9, 9, 9, 255] as [UInt8], false), ([9, 9, 9, 128], true)] {
            let request = try #require(session(3, 3, [pixelLayer("Layer", try solid(3, 3, pixel))]).psdWriteRequest())
            let sink = Sink()
            var writer = PSDByteWriter(sink: sink)
            var renderedAt = -1
            let report = try PSDWriter.write(try PSDWritePlan(request), into: &writer) { snapshot in
                renderedAt = sink.count
                return try PSDCompositeWriter.render(snapshot)
            }
            let layout = try Layout(sink.data)
            // Everything before the image data section was written when it was rendered.
            #expect(renderedAt == layout.compositeStart)
            #expect(report.wroteTransparencyChannel == transparent)
            #expect(layout.channels == (transparent ? 4 : 3) && layout.layerCount == (transparent ? -1 : 1))
            #expect(sink.data == (try PSDWriter.data(for: request)).data)
        }
    }
}

/// A PSD taken apart field by field, independently of `PSDReader`.
private struct Layout {
    struct Record {
        var rect = CGRect.zero
        var channels: [(id: Int, data: Data)] = []
        var blendKey = ""
        var opacity: UInt8 = 0, clipping: UInt8 = 0, flags: UInt8 = 0, filler: UInt8 = 0
        var maskRect: CGRect?
        var maskDefault: UInt8 = 0, maskFlags: UInt8 = 0
        /// The mask data's length, and its bytes after the flags (parameters, padding).
        var maskLength = 0
        var maskTail = Data()
        var blendingRanges = Data()
        var name = ""
        var blocks: [PSDTaggedBlock] = []
        var trailing = Data()

        var channelIDs: [Int] { channels.map(\.id) }
        var keys: [String] { blocks.map(\.key) }
        func block(_ key: String) -> Data? { blocks.first { $0.key == key }?.data }

        /// Channel `id`, decoded over the layer's rect (the mask's for -2).
        func plane(_ id: Int) throws -> [UInt8] {
            let data = try #require(channels.first { $0.id == id }?.data)
            let area = id == -2 ? try #require(maskRect) : rect
            let compression = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
            return try PSDChannelCoder.decode(compression: compression, width: Int(area.width), height: Int(area.height),
                                              data: Data(data.dropFirst(2)))
        }
    }

    var channels = 0, width = 0, height = 0
    var resources: [PSDImageResource] = []
    var layerCount = 0
    var records: [Record] = []
    var globalMaskInfo = Data()
    var globalBlocks: [PSDTaggedBlock] = []
    /// The merged image's channels, decoded.
    var composite: [[UInt8]] = []
    /// Where the image data section (the merged image) starts.
    var compositeStart = 0

    init(_ data: Data) throws {
        var cursor = Cursor(data: data)
        guard try cursor.code() == "8BPS", try cursor.u16() == 1 else { throw PSDError.truncated }
        cursor.offset += 6
        channels = Int(try cursor.u16())
        height = Int(try cursor.u32())
        width = Int(try cursor.u32())
        guard try cursor.u16() == 8, try cursor.u16() == 3 else { throw PSDError.truncated }
        cursor.offset += Int(try cursor.u32())
        let resourcesLength = Int(try cursor.u32())
        resources = try PSDBlockFile.decodeResources(try cursor.bytes(resourcesLength), limit: .max)
        let sectionLength = Int(try cursor.u32())
        let sectionEnd = cursor.offset + sectionLength
        let infoLength = Int(try cursor.u32())
        let infoEnd = cursor.offset + infoLength
        if infoLength > 0 {
            layerCount = Int(try cursor.i16())
            var lengths: [[Int]] = []
            for _ in 0..<abs(layerCount) {
                var record = Record()
                let top = Int(try cursor.i32()), left = Int(try cursor.i32())
                let bottom = Int(try cursor.i32()), right = Int(try cursor.i32())
                record.rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                var channelLengths: [Int] = []
                for _ in 0..<Int(try cursor.u16()) {
                    record.channels.append((Int(try cursor.i16()), Data()))
                    channelLengths.append(Int(try cursor.u32()))
                }
                lengths.append(channelLengths)
                guard try cursor.code() == "8BIM" else { throw PSDError.truncated }
                record.blendKey = try cursor.code()
                record.opacity = try cursor.u8()
                record.clipping = try cursor.u8()
                record.flags = try cursor.u8()
                record.filler = try cursor.u8()
                let extraEnd = Int(try cursor.u32()) + cursor.offset
                let maskLength = Int(try cursor.u32())
                let maskEnd = cursor.offset + maskLength
                if maskLength >= 20 {
                    let top = Int(try cursor.i32()), left = Int(try cursor.i32())
                    let bottom = Int(try cursor.i32()), right = Int(try cursor.i32())
                    record.maskRect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                    record.maskDefault = try cursor.u8()
                    record.maskFlags = try cursor.u8()
                    record.maskLength = maskLength
                    record.maskTail = try cursor.bytes(maskEnd - cursor.offset)
                }
                cursor.offset = maskEnd
                record.blendingRanges = try cursor.bytes(Int(try cursor.u32()))
                let nameLength = Int(try cursor.u8())
                record.name = String(data: try cursor.bytes(nameLength), encoding: .macOSRoman) ?? ""
                cursor.offset += (4 - (nameLength + 1) % 4) % 4
                (record.blocks, record.trailing) = PSDBlockFile.scanBlocksAndTail(data, from: cursor.offset, to: extraEnd)
                cursor.offset = extraEnd
                records.append(record)
            }
            for index in records.indices {
                for (channel, length) in lengths[index].enumerated() {
                    records[index].channels[channel].data = try cursor.bytes(length)
                }
            }
        }
        cursor.offset = infoEnd
        globalMaskInfo = try cursor.bytes(Int(try cursor.u32()))
        globalBlocks = try PSDBlockFile.decodeBlocks(try cursor.bytes(sectionEnd - cursor.offset), limit: .max, alignment: 4)
        compositeStart = cursor.offset
        guard try cursor.u16() == 1 else { throw PSDError.unsupportedCompression }
        let counts = try cursor.bytes(channels * height * 2)
        for channel in 0..<channels {
            let rows = counts.subdata(in: counts.startIndex + channel * height * 2 ..< counts.startIndex + (channel + 1) * height * 2)
            var total = 0
            for row in 0..<height { total += Int(rows[rows.startIndex + row * 2]) << 8 | Int(rows[rows.startIndex + row * 2 + 1]) }
            composite.append(try PSDChannelCoder.decode(compression: 1, width: width, height: height, data: rows + (try cursor.bytes(total))))
        }
        guard cursor.offset == data.count else { throw PSDError.truncated }
    }

    private struct Cursor {
        let data: Data
        var offset = 0

        mutating func bytes(_ count: Int) throws -> Data {
            guard count >= 0, offset + count <= data.count else { throw PSDError.truncated }
            defer { offset += count }
            return data.subdata(in: offset ..< offset + count)
        }
        mutating func u8() throws -> UInt8 { try bytes(1)[0] }
        mutating func u16() throws -> UInt16 { let b = try bytes(2); return UInt16(b[0]) << 8 | UInt16(b[1]) }
        mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
        mutating func u32() throws -> UInt32 { let b = try bytes(4); return b.reduce(0) { $0 << 8 | UInt32($1) } }
        mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
        mutating func code() throws -> String { String(try bytes(4).map { Character(Unicode.Scalar($0)) }) }
    }
}
