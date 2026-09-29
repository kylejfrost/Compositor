import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Import keeps every Photoshop block, resource and flag so the file can be written back whole (Task 2.3).
@MainActor
@Suite(.serialized)
struct PSDExtrasTests {
    private func colorImage(width: Int = 2, height: Int = 2, red: CGFloat = 1, green: CGFloat = 0, blue: CGFloat = 0) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func grayImage(width: Int = 2, height: Int = 2) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func layer(_ name: String, x: CGFloat = 0) throws -> PSDRecord {
        var record = PSDRecord(id: UUID(), name: name)
        record.bounds = CGRect(x: x, y: 0, width: 2, height: 2)
        record.image = try colorImage()
        return record
    }

    private func file(_ layers: [PSDRecord], extras: PSDDocumentExtras? = nil, resolution: Double = 72) throws -> Data {
        try PSDFixture.data(PSDDocument(width: 4, height: 2, resolution: resolution, layers: layers, extras: extras),
                            composite: try colorImage(width: 4, height: 2))
    }

    /// A `luni` payload.
    private func unicode(_ name: String) -> Data {
        var data = u32(UInt32(name.utf16.count))
        for unit in name.utf16 { data.append(contentsOf: [UInt8(unit >> 8), UInt8(unit & 0xff)]) }
        return data
    }

    /// A PSD with no layer records: header, empty color mode data and resources, then `layerSection` as given.
    private func bareFile(layerSection: Data) -> Data {
        var data = Data("8BPS".utf8) + Data([0, 1]) + Data(count: 6) + Data([0, 3])
        data += u32(2) + u32(4) + Data([0, 8, 0, 3]) + u32(0) + u32(0)
        return data + u32(UInt32(layerSection.count)) + layerSection
    }

    private func u32(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    @Test func unknownBlocksSurviveInFileOrder() throws {
        let zzzz = PSDTaggedBlock(key: "zzzz", data: Data([1, 2, 3]))
        let shmd = PSDTaggedBlock(key: "shmd", data: Data([0, 0, 0, 0, 9, 8, 7, 6]))
        var record = try layer("Kept")
        record.extras = PSDLayerExtras(blocks: [zzzz, shmd])
        let document = try PSDReader.read(try file([record]))
        let extras = try #require(document.layers.first?.extras)
        // luni stays in its place, so an untouched layer's blocks write back in the same order.
        let luni = PSDTaggedBlock(key: "luni", data: unicode("Kept"))
        #expect(extras.blocks == [luni, zzzz, shmd])
        #expect(extras.importedName == "Kept")
        #expect(extras.block("shmd") == shmd.data)
        #expect(extras.trailingBytes.isEmpty)
        let imported = try PSDDocumentBuilder.makeImport(document)
        #expect(imported.layers.first?.psdExtras?.blocks == [luni, zzzz, shmd])
    }

    @Test func lspfThirteenLocksTransparencyPositionAndNesting() throws {
        var record = try layer("Background")
        record.locks = LayerLocks(rawValue: 13)
        let document = try PSDReader.read(try file([record]))
        let locks = try #require(document.layers.first?.locks)
        #expect(locks == [.transparency, .position, .artboardNesting])
        #expect(locks.locksPosition && locks.locksTransparency && !locks.locksPixels)
        #expect(document.layers.first?.extras?.block("lspf") == u32(13))
        let imported = try PSDDocumentBuilder.makeImport(document)
        #expect(imported.layers.first?.locks == [.transparency, .position, .artboardNesting])
        let all = LayerLocks.all
        #expect(all.locksPosition && all.locksPixels && all.locksTransparency)
    }

    @Test func fillOpacityStaysApartFromOpacity() throws {
        var plain = try layer("Half fill")
        plain.fillOpacity = 128.0 / 255
        var effected = try layer("Half fill with effects", x: 2)
        effected.fillOpacity = 128.0 / 255
        effected.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "lfx2", data: Data([0, 0, 0, 0]))])
        let document = try PSDReader.read(try file([plain, effected]))
        #expect(document.layers[0].opacity == 1)
        #expect(abs(document.layers[0].fillOpacity - 0.5) < 0.01)
        let imported = try PSDDocumentBuilder.makeImport(document)
        #expect(imported.layers[0].opacity == 1)
        #expect(abs(imported.layers[0].fillOpacity - 0.5) < 0.01)
        #expect(abs(imported.layers[1].fillOpacity - 0.5) < 0.01)
        // Fill fades each layer's own pixels, with effects or without; the effects (drawn at `effectiveOpacity`)
        // keep the layer's opacity.
        let canvas = CanvasDocument(width: 4, height: 2, layers: imported.layers)
        let opacities = canvas.effectiveOpacities
        let byID = Dictionary(uniqueKeysWithValues: canvas.layers.map { ($0.id, $0) })
        for layer in canvas.layers {
            #expect(opacities[layer.id] == 1)
            #expect(abs(layer.pixelOpacity(in: byID) - 0.5) < 0.01)
        }
        let records = Dictionary(uniqueKeysWithValues: imported.layers.map { ($0.id, ProjectLayerRecord(layer: $0)) })
        #expect(abs((records[imported.layers[0].id]?.pixelOpacity(in: records) ?? 0) - 0.5) < 0.01)
        #expect(records[imported.layers[1].id]?.effectiveOpacity(in: records) == 1)
    }

    @Test func recordFieldsLabelIDAndNameSourceSurvive() throws {
        var record = try layer("Masked")
        record.mask = try grayImage()
        let ranges = Data((0..<40).map { UInt8($0) })
        record.extras = PSDLayerExtras(
            blocks: [PSDTaggedBlock(key: "lyid", data: u32(7)), PSDTaggedBlock(key: "lnsr", data: Data("layr".utf8))],
            blendingRanges: ranges, flags: 0x18, maskFlags: 0x10, maskDefaultColor: 255,
            maskParameters: Data([0x01, 0xC8, 0, 0]), colorLabel: .green)
        let document = try PSDReader.read(try file([record]))
        let extras = try #require(document.layers.first?.extras)
        #expect(extras.blendingRanges == ranges)
        #expect(extras.flags == 0x18)
        #expect(extras.blendKey == "norm")
        #expect(extras.maskFlags == 0x10)
        #expect(extras.maskDefaultColor == 255)
        #expect(extras.maskParameters == Data([0x01, 0xC8, 0, 0]))
        #expect(extras.layerID == 7)
        #expect(extras.nameSource == "layr")
        #expect(extras.colorLabel == .green)
        #expect(extras.blocks.map(\.key) == ["luni", "lclr", "lyid", "lnsr"])
        #expect(document.layers.first?.mask != nil)
    }

    @Test func resourcesKeepTheirIDsInOrder() throws {
        var icc = Data(count: 128)
        let text = Data("Test RGB".utf8)
        icc.append(u32(1))
        icc.append(Data("desc".utf8)); icc.append(u32(144)); icc.append(u32(UInt32(12 + text.count)))
        icc.append(Data("desc".utf8)); icc.append(Data(count: 4)); icc.append(u32(UInt32(text.count))); icc.append(text)
        let resources = [
            PSDImageResource(id: 4000, name: "Plug-in", data: Data([1, 2, 3])),
            PSDImageResource(id: 1037, name: "", data: u32(120)),
            PSDImageResource(id: 1049, name: "", data: u32(30)),
            PSDImageResource(id: 1039, name: "", data: icc),
            PSDImageResource(id: 1045, name: "", data: u32(2) + Data([0, 0x41, 0, 0x6C]))
        ]
        let data = try file([try layer("Layer")], extras: PSDDocumentExtras(resources: resources), resolution: 144)
        let document = try PSDReader.read(data)
        let extras = try #require(document.extras)
        #expect(extras.resources.map(\.id) == [1005, 4000, 1037, 1049, 1039, 1045])
        #expect(Array(extras.resources.dropFirst()) == resources)
        #expect(document.resolution == 144)
        #expect(extras.globalLightAngle == 120)
        #expect(extras.globalLightAltitude == 30)
        #expect(extras.iccProfileDescription == "Test RGB")
        #expect(extras.alphaChannelNames == ["Al"])
        #expect(extras.channelCount == 4)
        let decoded: [PSDImageResource] = try PSDBlockFile.decodeResources(PSDBlockFile.encode(extras.resources), limit: 1 << 20)
        #expect(decoded == extras.resources)
    }

    @Test func globalBlocksRoundTripThroughBlockFile() throws {
        let blocks = [PSDTaggedBlock(key: "Patt", data: Data([1, 2, 3, 4, 5])),
                      PSDTaggedBlock(key: "Txt2", data: Data("text engine".utf8)),
                      PSDTaggedBlock(signature: "8B64", key: "zzzz", data: Data())]
        let maskInfo = Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x80, 0])
        let extras = PSDDocumentExtras(globalBlocks: blocks, globalLayerMaskInfo: maskInfo)
        let document = try PSDReader.read(try file([try layer("Layer")], extras: extras))
        #expect(document.extras?.globalBlocks == blocks)
        #expect(document.extras?.globalLayerMaskInfo == maskInfo)
        #expect(document.layers.count == 1)
        for alignment in [2, 4] {
            let encoded = PSDBlockFile.encode(blocks, alignment: alignment)
            let decoded: [PSDTaggedBlock] = try PSDBlockFile.decodeBlocks(encoded, limit: 1 << 20, alignment: alignment)
            #expect(decoded == blocks)
        }
        let encoded = PSDBlockFile.encode(blocks)
        // A length past the end, a bad signature, trailing bytes and an oversized file are all rejected.
        var long = encoded
        long.replaceSubrange(8..<12, with: u32(1_000))
        #expect(throws: PSDError.truncated) { let _: [PSDTaggedBlock] = try PSDBlockFile.decodeBlocks(long, limit: 1 << 20) }
        var signature = encoded
        signature.replaceSubrange(0..<4, with: Data("XXXX".utf8))
        #expect(throws: PSDError.truncated) { let _: [PSDTaggedBlock] = try PSDBlockFile.decodeBlocks(signature, limit: 1 << 20) }
        #expect(throws: PSDError.truncated) { let _: [PSDTaggedBlock] = try PSDBlockFile.decodeBlocks(encoded + Data([1]), limit: 1 << 20) }
        #expect(throws: ImageImportError.tooLarge) { let _: [PSDTaggedBlock] = try PSDBlockFile.decodeBlocks(encoded, limit: 8) }
    }

    @Test func malformedBlocksNeverCostALayer() throws {
        var broken = try layer("Broken")
        broken.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "lspf", data: Data([0, 4])),
                                                PSDTaggedBlock(key: "zzzz", data: Data([1, 2, 3, 4]))])
        let intact = try layer("Intact", x: 2)
        var data = try file([broken, intact])
        // zzzz claims far more bytes than its layer record holds.
        let at = try #require(data.range(of: Data("8BIMzzzz".utf8)))
        data.replaceSubrange(at.upperBound ..< at.upperBound + 4, with: u32(0x7FFF_FFFF))
        let document = try PSDReader.read(data)
        #expect(document.layers.map(\.name) == ["Broken", "Intact"])
        let extras = try #require(document.layers.first?.extras)
        #expect(extras.blocks.map(\.key) == ["luni", "lspf", "zzzz"])
        #expect(extras.block("lspf") == Data([0, 4]))
        #expect(extras.block("zzzz")?.prefix(4) == Data([1, 2, 3, 4]))
        #expect(document.layers[0].locks == [])
        #expect(document.layers[1].image?.width == 2)
    }

    @Test func documentExtrasNameTheSourceFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).psd")
        try file([try layer("Layer")]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try PSDReader.read(from: url)
        #expect(document.extras?.sourceFileName == url.lastPathComponent)
        #expect(document.extras?.resources.map(\.id) == [1005])
    }

    @Test func editsAndCopiesKeepPhotoshopData() throws {
        let extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "lyid", data: u32(7)), PSDTaggedBlock(key: "shmd", data: Data([1]))],
                                    layerID: 7, colorLabel: .red)
        let layer = ImageLayer(id: UUID(), asset: nil, name: "Photoshop", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 4, height: 2)),
                               locks: [.position], fillOpacity: 0.5, psdExtras: extras)
        // A duplicate is a new Photoshop layer: it keeps the blocks but not the layer ID.
        let copy = layer.copy(as: UUID())
        #expect(copy.psdExtras?.layerID == nil)
        #expect(copy.psdExtras?.blocks.map(\.key) == ["shmd"])
        #expect(copy.psdExtras?.colorLabel == .red)
        #expect(copy.locks == [.position] && copy.fillOpacity == 0.5)
        let edited = layer.replacingPixels(nil, transform: layer.transform, mask: nil)
        #expect(edited.psdExtras == extras && edited.locks == [.position] && edited.fillOpacity == 0.5)
        // Canvas Size, Crop and Image Size rebuild layers from records, in memory.
        let record = ProjectLayerRecord(layer: layer).translated(by: CGPoint(x: 3, y: 1))
        let manifest = ProjectManifest(documentID: UUID(), width: 4, height: 2, activeLayerID: nil, layers: [record])
        let rebuilt = ImageLayer(record: record, snapshot: ProjectSnapshot(manifest: manifest, images: [:]))
        #expect(rebuilt.psdExtras == extras && rebuilt.locks == [.position] && rebuilt.fillOpacity == 0.5)
        // Project format 10 stores them: locks and fill inline, the Photoshop data as a `psd` record whose blocks
        // go to a sidecar.
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        #expect(json.contains("fillOpacity") && json.contains("locks") && json.contains("\"psd\""))
        #expect(json.contains("\(layer.id.uuidString).blocks") && !json.contains("psdExtras"))
    }

    @Test func documentSizeChangesKeepDocumentExtras() throws {
        let session = EditorSession()
        var document = CanvasDocument(width: 4, height: 2, layers: [
            ImageLayer(id: UUID(), asset: nil, name: "Layer", isVisible: true,
                       transform: LayerTransform(origin: .zero, size: CGSize(width: 4, height: 2)),
                       fillOpacity: 0.25, psdExtras: PSDLayerExtras(layerID: 3))
        ])
        document.psdExtras = PSDDocumentExtras(resources: [PSDImageResource(id: 4000, name: "", data: Data([1]))])
        session.document = document
        let snapshot = try #require(session.projectSnapshot())
        session.applyDocumentSize(snapshot, actionName: "Canvas Size")
        #expect(session.document?.psdExtras == document.psdExtras)
        #expect(session.document?.layers.first?.fillOpacity == 0.25)
        #expect(session.document?.layers.first?.psdExtras?.layerID == 3)
    }

    @Test func foldersKeepTheirOwnAndTheirDividersRecords() throws {
        let groupID = UUID()
        var group = PSDRecord(id: groupID, name: "Folder")
        group.isGroup = true
        group.blendKey = "pass"
        // Closed (type 2) and Normal rather than Pass Through, as Photoshop stores it in the folder's lsct.
        let lsct = PSDTaggedBlock(key: "lsct", data: Data([0, 0, 0, 2]) + Data("8BIMnorm".utf8))
        let luni = PSDTaggedBlock(key: "luni", data: unicode("Folder"))
        let lyid = PSDTaggedBlock(key: "lyid", data: u32(10))
        group.extras = PSDLayerExtras(blocks: [luni, lsct, lyid],
                                      sectionDividerExtras: PSDLayerExtras(blocks: [PSDTaggedBlock(key: "lyid", data: u32(11))],
                                                                           colorLabel: .blue))
        var child = try layer("Child")
        child.parentID = groupID
        let document = try PSDReader.read(try file([group, child]))
        let folder = try #require(document.layers.first { $0.isGroup })
        let extras = try #require(folder.extras)
        #expect(extras.blocks == [luni, lsct, lyid])
        #expect(extras.layerID == 10)
        #expect(folder.blendKey == "pass")
        let divider = try #require(extras.sectionDividerExtras)
        #expect(divider.layerID == 11)
        #expect(divider.colorLabel == .blue)
        #expect(divider.importedName == "</Layer group>")
        #expect(divider.blocks.map(\.key) == ["luni", "lsct", "lclr", "lyid"])
        #expect(divider.block("lsct")?.prefix(4) == Data([0, 0, 0, 3]))
        #expect(document.layers.map(\.name) == ["Child", "Folder"])
        // The divider data travels with the folder layer, and a copy drops both layer IDs.
        let imported = try PSDDocumentBuilder.makeImport(document)
        let importedFolder = try #require(imported.layers.first { $0.isGroup })
        #expect(importedFolder.psdExtras == extras)
        let copy = importedFolder.copy(as: UUID())
        #expect(copy.psdExtras?.layerID == nil && copy.psdExtras?.sectionDividerExtras?.layerID == nil)
        #expect(copy.psdExtras?.sectionDividerExtras?.blocks.map(\.key) == ["luni", "lsct", "lclr"])
        #expect(copy.psdExtras?.blocks == [luni, lsct])
    }

    @Test func anOddBlockWithoutPaddingKeepsTheNextBlock() throws {
        let region = Data("8BIMzzzz".utf8) + u32(3) + Data([1, 2, 3]) + Data("8BIMshmd".utf8) + u32(2) + Data([4, 5])
        let blocks = PSDBlockFile.scanBlocks(region, from: 0, to: region.count)
        #expect(blocks == [PSDTaggedBlock(key: "zzzz", data: Data([1, 2, 3])), PSDTaggedBlock(key: "shmd", data: Data([4, 5]))])
        // Padded the same blocks still read, and zero padding at the end is the tail.
        let padded = Data("8BIMzzzz".utf8) + u32(3) + Data([1, 2, 3, 0]) + Data("8BIMshmd".utf8) + u32(2) + Data([4, 5, 0, 0])
        let scanned = PSDBlockFile.scanBlocksAndTail(padded, from: 0, to: padded.count)
        #expect(scanned.blocks == blocks)
        #expect(scanned.tail == Data([0, 0]))
    }

    @Test func globalInfoIsFoundAfterAnUnpaddedOddLayerInfo() throws {
        let maskInfo = Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x80, 0])
        let blocks = [PSDTaggedBlock(key: "Patt", data: Data([1, 2, 3, 4]))]
        // Layer info of three bytes (a zero layer count and one stray byte) with no pad byte after it.
        let section = u32(3) + Data([0, 0, 0xEE]) + u32(UInt32(maskInfo.count)) + maskInfo + PSDBlockFile.encode(blocks, alignment: 4)
        let document = try PSDReader.read(bareFile(layerSection: section))
        #expect(document.layers.isEmpty)
        #expect(document.extras?.globalLayerMaskInfo == maskInfo)
        #expect(document.extras?.globalBlocks == blocks)
    }

    @Test func globalInfoIsKeptWithoutLayerInfo() throws {
        let maskInfo = Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x80, 0])
        let blocks = [PSDTaggedBlock(key: "Txt2", data: Data("engine".utf8))]
        let section = u32(0) + u32(UInt32(maskInfo.count)) + maskInfo + PSDBlockFile.encode(blocks, alignment: 4)
        let document = try PSDReader.read(bareFile(layerSection: section))
        #expect(document.layers.isEmpty)
        #expect(document.extras?.globalLayerMaskInfo == maskInfo)
        #expect(document.extras?.globalBlocks == blocks)
    }

    @Test func clippingFillerBytesAndANegativeLayerCountAreRecorded() throws {
        var base = try layer("Base")
        base.extras = PSDLayerExtras(fillerByte: 7)
        var clipped = try layer("Clipped")
        clipped.clipping = true
        let document = try PSDReader.read(try file([base, clipped], extras: PSDDocumentExtras(layerCountNegative: true)))
        #expect(document.extras?.layerCountNegative == true)
        #expect(document.layers[0].extras?.fillerByte == 7)
        #expect(document.layers[0].extras?.clippingByte == 0)
        #expect(document.layers[1].extras?.clippingByte == 1)
        #expect(document.layers[1].clipping)
        let positive = try PSDReader.read(try file([base]))
        #expect(positive.extras?.layerCountNegative == false)
    }

    @Test func aThirtySixByteMaskKeepsTheRealUserMaskFields() throws {
        var record = try layer("Masked")
        record.mask = try grayImage()
        // Real flags, real background, then the real user mask rectangle (top, left, bottom, right).
        let real = Data([0x02, 0xFF]) + u32(0) + u32(0) + u32(2) + u32(2)
        record.extras = PSDLayerExtras(maskFlags: 0, maskDefaultColor: 0, maskParameters: real)
        let data = try file([record])
        #expect(data.range(of: u32(36) + u32(0) + u32(0)) != nil)
        let extras = try #require(try PSDReader.read(data).layers.first?.extras)
        #expect(extras.maskParameters == real)
        #expect(extras.maskDefaultColor == 0)
        #expect(extras.maskFlags == 0)
    }

    @Test func eightBSixtyFourBlocksReadAtLayerLevel() throws {
        let wide = PSDTaggedBlock(signature: "8B64", key: "FXid", data: Data([1, 2, 3, 4, 5, 6]))
        let after = PSDTaggedBlock(key: "shmd", data: Data([9, 9]))
        var record = try layer("Wide")
        record.extras = PSDLayerExtras(blocks: [wide, after])
        let extras = try #require(try PSDReader.read(try file([record])).layers.first?.extras)
        #expect(Array(extras.blocks.dropFirst()) == [wide, after])
    }

    @Test func bytesAfterAnUnframeableBlockAreKept() throws {
        var record = try layer("Odd")
        record.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "shmd", data: Data([1, 2])),
                                                PSDTaggedBlock(key: "qqqq", data: Data([3, 4]))])
        var data = try file([record])
        let at = try #require(data.range(of: Data("8BIMqqqq".utf8)))
        data.replaceSubrange(at.lowerBound ..< at.lowerBound + 4, with: Data("XXXX".utf8))
        let document = try PSDReader.read(data)
        let extras = try #require(document.layers.first?.extras)
        #expect(extras.blocks.map(\.key) == ["luni", "shmd"])
        #expect(extras.trailingBytes == Data("XXXXqqqq".utf8) + u32(2) + Data([3, 4]))
        #expect(document.layers.first?.image?.width == 2)
    }

    @Test func aPhotoshopImportSurvivesAProjectRoundTrip() async throws {
        let groupID = UUID()
        var group = PSDRecord(id: groupID, name: "Folder")
        group.isGroup = true
        group.blendKey = "pass"
        group.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "lyid", data: u32(10))],
                                      sectionDividerExtras: PSDLayerExtras(blocks: [PSDTaggedBlock(key: "lyid", data: u32(11))],
                                                                           colorLabel: .blue))
        var child = try layer("Child")
        child.parentID = groupID
        child.fillOpacity = 128.0 / 255
        child.locks = LayerLocks(rawValue: 13)
        child.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "shmd", data: Data([0, 0, 0, 1, 2])),
                                               PSDTaggedBlock(signature: "8B64", key: "FXid", data: Data([1, 2, 3]))],
                                      blendingRanges: Data((0..<40).map { UInt8($0) }), flags: 0x08, layerID: 5,
                                      colorLabel: .green)
        var top = try layer("Top", x: 2)
        top.extras = PSDLayerExtras(fillerByte: 7)
        let extras = PSDDocumentExtras(
            resources: [PSDImageResource(id: 4000, name: "Plug-in", data: Data([1, 2, 3])),
                        PSDImageResource(id: 1037, name: "", data: u32(120))],
            globalBlocks: [PSDTaggedBlock(key: "Patt", data: Data([1, 2, 3, 4, 5])), PSDTaggedBlock(key: "Txt2", data: Data("engine".utf8))],
            globalLayerMaskInfo: Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x80, 0]), layerCountNegative: true)
        let document = try PSDReader.read(try file([group, child, top], extras: extras))
        let imported = try PSDDocumentBuilder.makeImport(document)
        #expect(imported.layers.allSatisfy { $0.psdExtras != nil })

        let session = EditorSession()
        var canvas = CanvasDocument(width: imported.width, height: imported.height, layers: imported.layers,
                                    resolution: imported.resolution)
        canvas.psdExtras = document.extras
        session.document = canvas
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PSDExtrasTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Imported.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let reopened = EditorSession()
        reopened.installProject(try await ProjectStore.shared.load(from: url), from: url)
        let restored = try #require(reopened.document)
        #expect(restored.psdExtras == document.extras)
        #expect(restored.layers.map(\.id) == canvas.layers.map(\.id))
        #expect(restored.layers.map(\.psdExtras) == canvas.layers.map(\.psdExtras))
        #expect(restored.layers.map(\.locks) == canvas.layers.map(\.locks))
        #expect(restored.layers.map(\.fillOpacity) == canvas.layers.map(\.fillOpacity))
        let folder = try #require(restored.layers.first { $0.isGroup })
        #expect(folder.psdExtras?.sectionDividerExtras?.layerID == 11)
        #expect(folder.psdExtras?.sectionDividerExtras?.blocks.map(\.key) == ["luni", "lsct", "lclr", "lyid"])
    }

    /// The document's Photoshop data comes along when an import creates the document, and stays out of a
    /// document the file is placed into.
    @Test func insertingAPhotoshopFileKeepsItsDocumentData() throws {
        let extras = PSDDocumentExtras(resources: [PSDImageResource(id: 4000, name: "Plug-in", data: Data([1, 2, 3]))],
                                       globalBlocks: [PSDTaggedBlock(key: "Patt", data: Data([1, 2, 3, 4]))])
        let document = try PSDReader.read(try file([try layer("Only")], extras: extras))
        let imported = try PSDDocumentBuilder.makeImport(document)
        #expect(imported.extras == document.extras)
        #expect(imported.extras?.globalBlocks.map(\.key) == ["Patt"])
        let session = EditorSession()
        try session.insertPhotoshop(imported, named: "Only")
        #expect(session.document?.psdExtras == document.extras)
        let other = EditorSession()
        other.createDocument(width: 8, height: 8)
        try other.insertPhotoshop(imported, named: "Only")
        #expect(other.document?.psdExtras == nil)
    }

    /// Whatever a Photoshop file holds, the import can be saved as a project: fields beyond the project's inline
    /// limits are dropped with a note (the layer stays), and a blend key that isn't ASCII is kept as its bytes.
    @Test func anOversizedOrOddImportStillSavesAsAProject() async throws {
        var tail = try layer("Tail")
        tail.extras = PSDLayerExtras(blendingRanges: Data(repeating: 1, count: 5_000),
                                     trailingBytes: Data(repeating: 0xAB, count: 70_000))
        var odd = try layer("Odd", x: 2)
        odd.blendKey = "Qzzz"
        let extras = PSDDocumentExtras(globalLayerMaskInfo: Data(repeating: 0, count: 70_000))
        var data = try file([tail, odd], extras: extras)
        let at = try #require(data.range(of: Data("8BIMQzzz".utf8)))
        data[at.lowerBound + 4] = 0xE9
        let document = try PSDReader.read(data)
        #expect(document.layers.map(\.extras?.trailingBytes.count) == [70_000, 0])
        #expect(document.layers.last?.extras?.blendKey == "\u{E9}zzz")

        let imported = try PSDDocumentBuilder.makeImport(document)
        #expect(imported.layers.map(\.name) == ["Tail", "Odd"])
        let kept = try #require(imported.layers.first?.psdExtras)
        #expect(kept.trailingBytes.isEmpty && kept.blendingRanges.isEmpty)
        #expect(imported.layers.last?.psdExtras?.blendKey == "\u{E9}zzz")
        #expect(imported.layers.last?.blendMode == .normal)
        #expect(imported.extras?.globalLayerMaskInfo.isEmpty == true)
        #expect(imported.conversions.contains { $0.layerName == "Tail" && $0.message.contains("too large") })
        #expect(imported.conversions.filter { $0.layerName == "Tail" }.count == 1)
        #expect(imported.conversions.contains { $0.message.contains("global layer mask") })

        let session = EditorSession()
        try session.insertPhotoshop(imported, named: "Odd")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PSDExtrasTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Odd.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let reopened = EditorSession()
        reopened.installProject(try await ProjectStore.shared.load(from: url), from: url)
        #expect(reopened.document?.layers.map(\.psdExtras) == session.document?.layers.map(\.psdExtras))
        #expect(reopened.document?.psdExtras == session.document?.psdExtras)
    }

    /// Photoshop data beyond the project's limits that reaches a save anyway is reported as too large, not as a
    /// damaged project.
    @Test func photoshopDataOverTheLimitsIsTooLargeToSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PSDExtrasTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for oversized in [PSDLayerExtras(trailingBytes: Data(count: 70_000)),
                          PSDLayerExtras(blendingRanges: Data(count: 5_000)),
                          PSDLayerExtras(sectionDividerExtras: PSDLayerExtras(maskParameters: Data(count: 5_000)))] {
            let session = EditorSession()
            session.createDocument(width: 4, height: 4, emptyLayer: true)
            session.document?.layers[0].psdExtras = oversized
            let snapshot = try #require(session.projectSnapshot())
            do {
                try await ProjectStore.shared.save(snapshot, to: root.appendingPathComponent("\(UUID()).comp"))
                Issue.record("Saved over-limit Photoshop data")
            } catch ProjectError.tooLarge {
            } catch { Issue.record("Expected tooLarge, got \(error)") }
        }
        let session = EditorSession()
        session.createDocument(width: 4, height: 4, emptyLayer: true)
        session.document?.psdExtras = PSDDocumentExtras(colorModeData: Data(count: 70_000))
        let snapshot = try #require(session.projectSnapshot())
        do {
            try await ProjectStore.shared.save(snapshot, to: root.appendingPathComponent("Document.comp"))
            Issue.record("Saved over-limit document Photoshop data")
        } catch ProjectError.tooLarge {
        } catch { Issue.record("Expected tooLarge, got \(error)") }
        #expect(ProjectError.tooLarge.errorDescription?.contains("Photoshop") == true)
    }

    /// `importedMaskRect` saves only when set, comes back as saved, and a rectangle that can't be one is refused.
    @Test func theImportedMaskRectangleSavesAndMustBeARectangle() throws {
        let stored = CGRect(x: 10, y: 20, width: 8, height: 6)
        let data = try JSONEncoder().encode(PSDLayerExtrasRecord(PSDLayerExtras(importedMaskRect: stored), layerID: UUID()))
        #expect(try JSONDecoder().decode(PSDLayerExtrasRecord.self, from: data).extras.importedMaskRect == stored)
        let plain = try JSONEncoder().encode(PSDLayerExtrasRecord(PSDLayerExtras(), layerID: UUID()))
        #expect(!String(decoding: plain, as: UTF8.self).contains("importedMaskRect"))
        #expect(try JSONDecoder().decode(PSDLayerExtrasRecord.self, from: plain).extras.importedMaskRect == nil)
        for bad in ["[[0,0],[-1,4]]", "[[-2,0],[4,4]]"] {
            let json = Data(#"{"blendKey":"norm","importedMaskRect":\#(bad)}"#.utf8)
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(PSDLayerExtrasRecord.self, from: json) }
        }
    }
}
