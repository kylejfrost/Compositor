import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// What a Photoshop import keeps within what a Compositor project can save, and what it does with the rest: masks
/// within the project's mask pixels, guides within its guide count, and notes for what only a Photoshop file can hold.
@MainActor
@Suite(.serialized)
struct PSDImportLimitsTests {
    private func colorImage(width: Int, height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// A gray mask of one value, cheap to store: its rows pack into a few bytes each.
    private func grayImage(width: Int, height: Int, value: UInt8 = 255) throws -> CGImage {
        try PSDChannelCoder.maskImage(width: width, height: height,
                                      gray: [UInt8](repeating: value, count: width * height))
    }

    /// A layer without pixels carrying `mask` at the canvas origin.
    private func maskedLayer(_ name: String, mask: CGImage) -> PSDRecord {
        var record = PSDRecord(id: UUID(), name: name)
        record.mask = mask
        return record
    }

    private func file(_ layers: [PSDRecord], width: Int = 16, height: Int = 16, extras: PSDDocumentExtras? = nil) throws -> Data {
        try PSDFixture.data(PSDDocument(width: width, height: height, resolution: 72, layers: layers, extras: extras),
                            composite: try colorImage(width: width, height: height))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PSDImportLimitsTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    // MARK: Masks

    /// Masks count toward a budget of their own, as a project counts them: once the file's masks reach it, the rest
    /// are left out, unread, each with a note, so the file opens without holding more than that in mask planes.
    @Test func masksPastTheBudgetAreLeftOutUnread() throws {
        let mask = try grayImage(width: 4, height: 4, value: 0)
        let data = try file([maskedLayer("One", mask: mask), maskedLayer("Two", mask: mask), maskedLayer("Three", mask: mask)])
        let document = try PSDReader.read(data, remainingMaskPixels: 40)
        #expect(document.layers.map { $0.mask != nil } == [true, true, false])
        #expect(document.layers.map(\.maskOverBudget) == [false, false, true])
        let imported = try PSDDocumentBuilder.makeImport(document)
        #expect(imported.layers.map { $0.mask != nil } == [true, true, false])
        let notes = imported.conversions.filter { $0.message.contains("mask was left out") }
        #expect(notes.map(\.layerName) == ["Three"])
    }

    /// The reader's mask budget is the project's (`LayerMask.maximumProjectPixels`, the document pixel budget), and a
    /// file whose masks don't fit it as stored is first cropped to the canvas: a small mask and one reaching far past
    /// the canvas both open, the second cropped with a note, and the document saves as a project.
    @Test func aFileWhoseMasksExceedTheBudgetOpensCroppedAndStillSaves() async throws {
        #expect(LayerMask.maximumProjectPixels == DocumentLimits.documentPixelBudget)
        #expect(try PSDReader.read(maskFile([("First", 4, 4)])).maskPixelBudget == LayerMask.maximumProjectPixels)
        let data = maskFile([("First", 4, 4), ("Second", 64, 64)])
        let document = try PSDReader.read(data, remainingMaskPixels: 300)
        #expect(document.layers.map { $0.mask.map { CGSize(width: $0.width, height: $0.height) } }
                == [CGSize(width: 4, height: 4), CGSize(width: 16, height: 16)])
        #expect(document.layers.map(\.croppedToCanvas) == [false, true])
        let imported = try PSDDocumentBuilder.makeImport(document)
        #expect(imported.layers.map { $0.mask != nil } == [true, true])
        #expect(imported.conversions.filter { $0.message.contains("Cropped to the canvas") }.map(\.layerName) == ["Second"])

        let session = EditorSession()
        try session.insertPhotoshop(imported, named: "Masks")
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: root.appendingPathComponent("Masks.comp"))
    }

    /// A mask larger than the whole budget, even cropped to the canvas, is never decoded: the file opens without it,
    /// rather than failing (or, in a file made to, taking gigabytes of mask planes).
    @Test func aMaskLargerThanTheBudgetIsNotRead() throws {
        let document = try PSDReader.read(maskFile([("Huge", 16, 16)]), remainingMaskPixels: 100)
        #expect(document.layers.map { $0.mask == nil } == [true])
        #expect(document.layers.map(\.maskOverBudget) == [true])
    }

    /// A white mask of exactly the whole mask budget (`LayerMask.maximumProjectPixels`, up to 800 MP) that costs
    /// nothing to hold: its bytes come from a callback only if something reads them, and its thumbnail is one pixel.
    /// A document counts its masks by their size alone, so this stands in for masks that fill the budget.
    private func wholeBudgetMask() throws -> LayerMask {
        let budget = LayerMask.maximumProjectPixels
        let height = try #require(stride(from: Int(Double(budget).squareRoot()), through: 1, by: -1).first { budget % $0 == 0 })
        let width = budget / height
        var callbacks = CGDataProviderDirectCallbacks(version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { _, buffer, _, count in
                memset(buffer, 255, count)
                return count
            }, releaseInfo: nil)
        let provider = try #require(CGDataProvider(directInfo: nil, size: off_t(budget), callbacks: &callbacks))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let thumbnail = try #require(LayerMask.solid(revealing: true)).asset.image
        return LayerMask(asset: ImportedImage(image: image, thumbnail: thumbnail, name: "Layer Mask"))
    }

    /// Placing a file into a document counts the document's own masks first, apart from its layers' pixels: what is
    /// left is the budget less every mask's pixels, and once the document's masks hold the whole budget, a placed
    /// Photoshop file comes in without its mask, with a note, rather than holding more than a project saves.
    @Test func placingAFileCountsTheDocumentsMasks() async throws {
        let session = EditorSession()
        #expect(session.remainingImportPixels() == (DocumentLimits.documentPixelBudget, LayerMask.maximumProjectPixels))
        session.createDocument(width: 16, height: 16, emptyLayer: true)
        let mask = try grayImage(width: 100, height: 50)
        session.document?.layers[0].mask = LayerMask(asset: try LayerMask.asset(from: mask))
        let pixels = try colorImage(width: 8, height: 4)
        session.document?.layers[0].asset = ImportedImage(image: pixels, thumbnail: try PixelAdjust.thumbnail(of: pixels), name: "Pixels")
        let remaining = session.remainingImportPixels()
        #expect(remaining.pixels == DocumentLimits.documentPixelBudget - 32)
        #expect(remaining.maskPixels == LayerMask.maximumProjectPixels - 5_000)

        // The whole budget, in a mask the document holds as it holds any other.
        session.document?.layers[0].mask = try wholeBudgetMask()
        #expect(session.remainingImportPixels().maskPixels == 0)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Import.psd")
        try maskFile([("Masked", 4, 4)]).write(to: url)
        var notes: [PSDConversion] = []
        session.confirmConversions = { conversions in
            notes += conversions
            return true
        }
        await session.importImages([url])
        #expect(session.importError == nil)
        #expect(session.document?.layers.first { $0.name == "Masked" }.map { $0.mask == nil } == true)
        #expect(notes.contains { $0.layerName == "Masked" && $0.message.contains("mask was left out") })
    }

    // MARK: Guides

    /// A project saves at most 1,000 guides: a file with more (a baseline grid of 1,250) opens with the first 1,000,
    /// in file order, and a note, and saves as a project.
    @Test func guidesBeyondWhatAProjectSavesAreLeftOutWithANote() async throws {
        let positions = (0 ..< 1_250).map { Double($0) * 8 }
        let extras = PSDDocumentExtras(resources: [PSDFixture.guidesResource(horizontal: positions)], sourceFileName: "Grid.psd")
        var layer = PSDRecord(id: UUID(), name: "Layer")
        layer.bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        layer.image = try colorImage(width: 16, height: 16)
        var document = try PSDReader.read(try file([layer], extras: extras))
        document.extras?.sourceFileName = "Grid.psd"
        let imported = try PSDDocumentBuilder.makeImport(document)
        #expect(imported.guides.count == 1_000)
        #expect(imported.guides.map(\.position) == Array(positions.prefix(1_000)))
        #expect(imported.conversions.contains { $0.layerName == "Grid.psd" && $0.message.contains("guides were left out") })

        let session = EditorSession()
        try session.insertPhotoshop(imported, named: "Grid")
        #expect(session.document?.guides.count == 1_000)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: root.appendingPathComponent("Grid.comp"))
    }

    /// However many guides a resource claims, only the ones a project can hold are made.
    @Test func aGuideResourceIsReadNoFurtherThanTheLimit() {
        let resource = PSDFixture.guidesResource(vertical: (0 ..< 5_000).map(Double.init))
        let read = PSDResources.guides(resource.data, limit: 1_000)
        #expect(read.guides.count == 1_000 && read.total == 5_000)
    }

    // MARK: Shapes

    /// Photoshop's red rectangle (20, 20)–(120, 80) on a 480 × 320 canvas over a Background, its stored pixels
    /// `stored` at the shape's corner, as a file whose layers take every pixel of `remainingPixels` but `spare`.
    private func shapeFile(stored: CGSize, spare: Int = 0) throws -> (data: Data, remainingPixels: Int) {
        let canvas = PSDVectorFixtures.photoshopCanvas
        var background = PSDRecord(id: UUID(), name: "Background")
        background.bounds = CGRect(origin: .zero, size: canvas)
        background.image = try colorImage(width: Int(canvas.width), height: Int(canvas.height))
        var shape = PSDRecord(id: UUID(), name: "Rectangle")
        shape.bounds = CGRect(origin: CGPoint(x: 20, y: 20), size: stored)
        shape.image = try colorImage(width: Int(stored.width), height: Int(stored.height))
        shape.extras = PSDLayerExtras(blocks: PSDVectorFixtures.photoshopRectangle().sorted { $0.key < $1.key }
            .map { PSDTaggedBlock(key: $0.key, data: $0.value) })
        let data = try file([background, shape], width: Int(canvas.width), height: Int(canvas.height))
        return (data, Int(canvas.width * canvas.height + stored.width * stored.height) + spare)
    }

    /// A live shape's pixels replace the ones Photoshop stored, so drawing it takes only what those gave back: a file
    /// whose layers fill the pixel budget still opens with its shape live.
    @Test func aLiveShapeIsDrawnInThePixelsItReplaces() throws {
        let file = try shapeFile(stored: CGSize(width: 100, height: 60))
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(file.data, remainingPixels: file.remainingPixels))
        #expect(imported.layers.last?.liveShape?.style.kind == .rectangle)
    }

    /// A shape that can't be drawn within the budget keeps the pixels Photoshop stored, with a note, rather than
    /// failing the file.
    @Test func aShapeTooLargeToDrawKeepsPhotoshopsPixels() throws {
        let file = try shapeFile(stored: CGSize(width: 10, height: 10))
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(file.data, remainingPixels: file.remainingPixels))
        let layer = try #require(imported.layers.last)
        #expect(layer.liveShape == nil && layer.asset?.image.width == 10)
        #expect(imported.conversions.contains { $0.layerName == "Rectangle" && $0.message.contains("too large to draw") })
    }

    // MARK: What only a Photoshop file holds

    /// Photoshop data a project can't save (here a layer's blocks past the 64 MB a project stores per layer) opens
    /// with a note naming the way to keep it: saving as a Photoshop file.
    @Test func layerDataBeyondWhatAProjectHoldsIsNoted() throws {
        var heavy = PSDRecord(id: UUID(), name: "Heavy")
        heavy.bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
        heavy.image = try colorImage(width: 4, height: 4)
        heavy.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "zzzz", data: Data(count: PSDLayerExtrasRecord.maximumBlocksFileBytes))])
        var light = PSDRecord(id: UUID(), name: "Light")
        light.bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
        light.image = try colorImage(width: 4, height: 4)
        light.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "zzzz", data: Data(count: 1_024))])
        let document = PSDDocument(width: 4, height: 4, resolution: 72, layers: [heavy, light],
                                   extras: PSDDocumentExtras(sourceFileName: "Heavy.psd"))
        let notes = try PSDDocumentBuilder.makeImport(document).conversions.filter { $0.message.contains("as a Photoshop file") }
        #expect(notes.map(\.layerName) == ["Heavy"])
    }

    /// A smart object's contents, and the document's own Photoshop data, past what a project stores are noted too.
    @Test func contentsAndDocumentDataBeyondWhatAProjectHoldsAreNoted() throws {
        let uuid = "5d1c0e5e-0000-4a3b-9c1d-1f2e3d4c5b6a"
        var placed = PSDRecord(id: UUID(), name: "Placed")
        placed.bounds = CGRect(x: 4, y: 4, width: 8, height: 8)
        placed.image = try colorImage(width: 8, height: 8)
        placed.extras = PSDLayerExtras(blocks: PSDFixture.smartObjectBlocks(
            uuid: uuid, size: CGSize(width: 8, height: 8),
            quad: [CGPoint(x: 4, y: 4), CGPoint(x: 12, y: 4), CGPoint(x: 12, y: 12), CGPoint(x: 4, y: 12)]))
        let entry = PSDFixture.LinkedEntry(uuid: uuid, fileName: "Logo.png", data: Data(repeating: 7, count: 4_096),
                                           childID: "child-7", modTime: 12.5, lockState: 0)
        let extras = PSDDocumentExtras(resources: [PSDImageResource(id: 4000, name: "", data: Data(count: 512))],
                                       globalBlocks: [PSDFixture.linkedLayersBlock(entries: [entry])])
        var document = try PSDReader.read(try file([placed], extras: extras))
        document.extras?.sourceFileName = "Placed.psd"
        #expect(document.layers.first?.smartObject?.payload?.data.count == 4_096)
        var limits = PSDProjectLimits()
        limits.smartObjectBytes = 1_024
        limits.resourcesBytes = 256
        let notes = try PSDDocumentBuilder.makeImport(document, limits: limits).conversions
            .filter { $0.message.contains("as a Photoshop file") }
        #expect(notes.map(\.layerName) == ["Placed", "Placed.psd"])
        #expect(notes.last?.message.contains("image resources") == true)
        // At a project's own limits, the same file has nothing to note.
        #expect(try PSDDocumentBuilder.makeImport(document).conversions.allSatisfy { !$0.message.contains("as a Photoshop file") })
    }

    /// A Photoshop file of layers without pixels, each with a white mask of the given size at the canvas origin, its
    /// rows packed (so a large mask is a small file); a 16 × 16 canvas.
    private func maskFile(_ masks: [(name: String, width: Int, height: Int)]) -> Data {
        var file = Data()
        func u8(_ value: UInt8) { file.append(value) }
        func u16(_ value: Int) { file.append(contentsOf: [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]) }
        func u32(_ value: Int) { file.append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]) }
        func row(_ width: Int) -> Data {
            var bytes = Data()
            var left = width
            while left > 0 {
                let run = min(128, left)
                bytes.append(contentsOf: [UInt8(bitPattern: Int8(1 - run)), 0xFF])
                left -= run
            }
            return bytes
        }
        file.append(Data("8BPS".utf8)); u16(1); file.append(Data(count: 6)); u16(3); u32(16); u32(16); u16(8); u16(3)
        u32(0); u32(0)
        var records = Data(), channels = Data()
        for mask in masks {
            let packed = row(mask.width)
            var channel = Data([0, 1])
            for _ in 0 ..< mask.height { channel.append(contentsOf: [UInt8(packed.count >> 8), UInt8(packed.count & 0xFF)]) }
            for _ in 0 ..< mask.height { channel.append(packed) }
            let saved = file
            file = Data()
            u32(0); u32(0); u32(0); u32(0); u16(5)
            for id in [-1, 0, 1, 2] { u16(Int(UInt16(bitPattern: Int16(id)))); u32(2) }
            u16(Int(UInt16(bitPattern: -2))); u32(channel.count)
            file.append(Data("8BIMnorm".utf8)); u8(255); u8(0); u8(0); u8(0)
            let name = Data(mask.name.utf8)
            let nameLength = (1 + name.count + 3) / 4 * 4
            u32(4 + 20 + 4 + nameLength)
            u32(20); u32(0); u32(0); u32(mask.height); u32(mask.width); u8(255); u8(0); u16(0)
            u32(0)
            u8(UInt8(name.count)); file.append(name); file.append(Data(count: nameLength - 1 - name.count))
            records.append(file)
            file = saved
            channels.append(Data(repeating: 0, count: 8))
            channels.append(channel)
        }
        var info = Data([UInt8(masks.count >> 8), UInt8(masks.count & 0xFF)]) + records + channels
        if info.count % 2 == 1 { info.append(0) }
        u32(4 + info.count + 4); u32(info.count); file.append(info); u32(0)
        u16(0); file.append(Data(repeating: 128, count: 16 * 16 * 3))
        return file
    }
}
