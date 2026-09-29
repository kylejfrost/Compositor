import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Compositor

/// Smart objects written to PSD (Task 4.8): each layer's placed-layer blocks (`PlLd`, `SoLd`) and one document `lnk2`
/// block holding every embedded object's contents and the entries no layer names, where the file had its linked-layer
/// blocks. Untouched contents are written back byte for byte; the placement follows the layer.
@MainActor
@Suite(.serialized)
struct PSDSmartObjectWriterTests {
    private let quad = [CGPoint(x: 18, y: 14), CGPoint(x: 46, y: 14), CGPoint(x: 46, y: 42), CGPoint(x: 18, y: 42)]
    private let placedID = "8f2c1a55-placed"

    // MARK: Fixtures

    private func raster(width: Int, height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func png(width: Int = 10, height: Int = 8) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PSDSmartObjectWriterTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    /// The contents entry the file names: an open-file descriptor, a child ID, a time and a lock, and two things import
    /// used to lose — a file name stored with a second NUL, and bytes after the fields Photoshop documents.
    private func usedEntry(_ contents: Data, trailing: Data = Data([0xAB, 0xCD, 0xEF])) -> Data {
        var entry = PSDFixture.LinkedEntry(uuid: "u", fileName: "Logo.png\0", data: contents)
        entry.openFile = PSDDescriptor(classID: "null", items: [(key: "compInfo", value: .integer(1))])
        entry.childID = "child-7"
        entry.modTime = 12.5
        entry.lockState = 1
        return PSDFixture.linkedEntry(entry) + trailing
    }

    private let spareEntry = PSDFixture.linkedEntry(PSDFixture.LinkedEntry(uuid: "spare", fileName: "Spare.bin",
                                                                           data: Data("spare".utf8)))

    /// A Photoshop file with one smart object ("Logo": 10×8 contents placed on `quad`, pixels at 20,16 24×24) between
    /// a `Patt` and an `FMsk` document block (unless `neighbours` is false), its `lnk2` holding the contents and an
    /// entry no layer names; opened as the app opens one.
    private func openedSmartObject(extraLayers: [PSDRecord] = [], entries: [Data]? = nil,
                                   neighbours: Bool = true) throws -> (session: EditorSession, id: UUID) {
        var record = PSDRecord(id: UUID(), name: "Logo")
        record.bounds = CGRect(x: 20, y: 16, width: 24, height: 24)
        record.image = try raster(width: 24, height: 24)
        record.extras = PSDLayerExtras(blocks: PSDFixture.smartObjectBlocks(uuid: "u", size: CGSize(width: 10, height: 8),
                                                                           quad: quad, placedID: placedID))
        let standard = [usedEntry(try png()), spareEntry]
        let linked = PSDTaggedBlock(key: "lnk2", data: PSDBlockFile.encode(linkedEntries: entries ?? standard))
        let globalBlocks = neighbours ? [PSDTaggedBlock(key: "Patt", data: Data([1, 2, 3, 4])), linked,
                                         PSDTaggedBlock(key: "FMsk", data: Data([0, 0, 0, 50]))] : [linked]
        let document = PSDDocument(width: 64, height: 64, resolution: 72, layers: extraLayers + [record],
                                   extras: PSDDocumentExtras(globalBlocks: globalBlocks))
        let data = try PSDFixture.data(document, composite: try raster(width: 64, height: 64))
        let session = EditorSession()
        try session.insertPhotoshop(try PSDDocumentBuilder.makeImport(try PSDReader.read(data)), named: "Smart")
        let id = try #require(session.document?.layers.first { $0.name == "Logo" }?.id)
        session.activeLayerID = id
        session.history.reset()
        return (session, id)
    }

    private func written(_ session: EditorSession, _ options: PSDWriteOptions = .init()) throws -> (data: Data, report: PSDWriteReport) {
        try PSDWriter.data(for: try #require(session.psdWriteRequest()), options: options)
    }

    /// The document-level tagged blocks of a written PSD, the linked-layer block included.
    private func documentBlocks(_ data: Data) throws -> [PSDTaggedBlock] {
        func u32(_ at: Int) -> Int { Int(data[at]) << 24 | Int(data[at + 1]) << 16 | Int(data[at + 2]) << 8 | Int(data[at + 3]) }
        var offset = 26
        offset += 4 + u32(offset)                            // color mode data
        offset += 4 + u32(offset)                            // image resources
        let sectionEnd = offset + 4 + u32(offset)
        offset += 4
        offset += 4 + u32(offset)                            // layer info
        offset += 4 + u32(offset)                            // global layer mask info
        return PSDBlockFile.scanBlocks(data, from: offset, to: sectionEnd)
    }

    private func linkedEntries(_ data: Data) throws -> [Data] {
        let blocks = try documentBlocks(data).filter { PSDSmartObjects.linkedBlockKeys.contains($0.key) }
        #expect(blocks.map(\.key) == ["lnk2"])
        return try PSDBlockFile.decodeLinkedEntries(try #require(blocks.first).data, limit: .max)
    }

    /// Each written layer's tagged blocks, bottom to top.
    private func layerBlocks(_ data: Data) throws -> [String: [PSDTaggedBlock]] {
        let document = try PSDReader.read(data)
        return Dictionary(document.layers.map { ($0.name, $0.extras?.blocks ?? []) }, uniquingKeysWith: { first, _ in first })
    }

    private func block(_ key: String, in blocks: [PSDTaggedBlock]?) throws -> Data {
        try #require(blocks?.first { $0.key == key }?.data)
    }

    private func descriptor(_ soLd: Data) throws -> PSDDescriptor {
        #expect(soLd.prefix(8) == Data("soLD".utf8) + be32(4))
        var offset = 8
        return try PSDDescriptorReader.readBlock(soLd, at: &offset)
    }

    private func numbers(_ points: [CGPoint]) -> PSDDescriptorValue {
        .list(points.flatMap { [PSDDescriptorValue.double(Double($0.x)), .double(Double($0.y))] })
    }

    private func moved(_ points: [CGPoint], by dx: CGFloat, _ dy: CGFloat, scale: CGFloat = 1) -> [CGPoint] {
        points.map { CGPoint(x: $0.x * scale + dx, y: $0.y * scale + dy) }
    }

    /// The eight numbers of a `Trnf`-style list, when it is one.
    private func values(_ value: PSDDescriptorValue?) -> [Double]? {
        guard case .list(let items)? = value else { return nil }
        let doubles = items.compactMap { item -> Double? in
            guard case .double(let number) = item else { return nil }
            return number
        }
        return doubles.count == 8 && items.count == 8 ? doubles : nil
    }

    private func close(_ values: [Double]?, _ corners: [CGPoint]) -> Bool {
        let expected = corners.flatMap { [Double($0.x), Double($0.y)] }
        return values.map { $0.count == 8 && zip($0, expected).allSatisfy { abs($0 - $1) < 1e-9 } } ?? false
    }

    /// `descriptor` with its `Trnf` and `nonAffineTransform` checked against `corners` (to 1e-9 px) and then set to the
    /// numbers `written` holds there, so comparing whole blocks checks every other byte exactly.
    private func placing(_ descriptor: PSDDescriptor, on corners: [CGPoint], asIn written: PSDDescriptor,
                         sourceLocation: SourceLocation = #_sourceLocation) -> PSDDescriptor {
        var result = descriptor
        for index in result.items.indices where ["Trnf", "nonAffineTransform"].contains(result.items[index].key.id) {
            let key = result.items[index].key.id
            #expect(close(values(written[key]), corners), "\(key)", sourceLocation: sourceLocation)
            result.items[index].value = written[key] ?? result.items[index].value
        }
        return result
    }

    /// `PlLd` bytes with the corners after `start` checked against `corners` (to 1e-9 px) and replaced by `expected`'s
    /// bytes there, so the rest can be compared exactly.
    private func expectPlLd(_ written: Data, _ expected: Data, corners: [CGPoint], start: Int,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        guard written.count == expected.count, written.count >= start + 64 else {
            Issue.record("PlLd is \(written.count) bytes, expected \(expected.count)", sourceLocation: sourceLocation)
            return
        }
        let bytes = Data(written)
        let numbers = (0..<8).map { index -> Double in
            let at = start + index * 8
            return Double(bitPattern: bytes[at ..< at + 8].reduce(0) { $0 << 8 | UInt64($1) })
        }
        #expect(close(numbers, corners), "\(numbers)", sourceLocation: sourceLocation)
        var masked = bytes
        masked.replaceSubrange(start ..< start + 64, with: Data(expected)[start ..< start + 64])
        #expect(masked == expected, sourceLocation: sourceLocation)
    }

    /// The warp Photoshop writes for an unwarped placement of `size` contents.
    private func warp(_ size: CGSize) -> PSDDescriptor {
        PSDDescriptor(classID: PSDKey("warp", explicitLength: true), items: [
            (key: "warpStyle", value: .enumerated(type: "warpStyle", value: "warpNone")),
            (key: "warpValue", value: .double(0)),
            (key: "warpPerspective", value: .double(0)),
            (key: "warpPerspectiveOther", value: .double(0)),
            (key: "warpRotate", value: .enumerated(type: "Ornt", value: "Hrzn")),
            (key: "bounds", value: .object(PSDDescriptor(classID: "classFloatRect", items: [
                (key: "Top ", value: .double(0)), (key: "Left", value: .double(0)),
                (key: "Btom", value: .double(Double(size.height))), (key: "Rght", value: .double(Double(size.width))),
            ]))),
            (key: "uOrder", value: .integer(4)),
            (key: "vOrder", value: .integer(4)),
        ])
    }

    private func fraction() -> PSDDescriptorValue {
        .object(PSDDescriptor(classID: "null", items: [(key: "numerator", value: .integer(0)),
                                                      (key: "denominator", value: .integer(600))]))
    }

    // MARK: New contents

    /// The one-PNG smart object: `PlLd` and `SoLd` laid out as the brief gives them, and a version 7 `liFD` entry
    /// (Photoshop 2026 refuses to open a version 8 entry laid out as psd-tools reads one).
    @Test func aPlacedPNGIsWrittenAsAnEmbeddedSmartObject() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = try png()
        let url = root.appendingPathComponent("Logo.png")
        try contents.write(to: url)
        let session = EditorSession()
        session.createDocument(width: 64, height: 48, emptyLayer: true)
        let id = try await session.placeSmartObject(from: url)
        let info = try #require(session.document?.layers.first { $0.id == id }?.smartObject?.info)
        let corners = [CGPoint(x: 27, y: 20), CGPoint(x: 37, y: 20), CGPoint(x: 37, y: 28), CGPoint(x: 27, y: 28)]

        let (data, report) = try written(session)
        #expect(report.warnings.isEmpty)
        let blocks = try layerBlocks(data)["Logo"]
        #expect(blocks?.prefix(2).map(\.key) == ["PlLd", "SoLd"])
        let soLd = try block("SoLd", in: blocks)
        let expected = placing(PSDDescriptor(classID: "null", items: [
            (key: "Idnt", value: .string(info.uniqueID)),
            (key: "placed", value: .string(info.placedID)),
            (key: "PgNm", value: .integer(1)),
            (key: "totalPages", value: .integer(1)),
            (key: "Crop", value: .integer(1)),
            (key: "frameStep", value: fraction()),
            (key: "duration", value: fraction()),
            (key: "frameCount", value: .integer(1)),
            (key: "Annt", value: .integer(16)),
            (key: "Type", value: .integer(2)),
            (key: "Trnf", value: numbers(corners)),
            (key: "nonAffineTransform", value: numbers(corners)),
            (key: PSDKey("warp", explicitLength: true), value: .object(warp(CGSize(width: 10, height: 8)))),
            (key: "Sz  ", value: .object(PSDDescriptor(classID: "Pnt ", items: [(key: "Wdth", value: .double(10)),
                                                                              (key: "Hght", value: .double(8))]))),
            (key: "Rslt", value: .unitFloat(unit: "#Rsl", value: 72)),
        ]), on: corners, asIn: try descriptor(soLd))
        // Padded to 4, as Photoshop (and psd-tools) write it.
        var expectedSoLd = Data("soLD".utf8) + be32(4) + PSDDescriptorWriter.block(expected)
        while expectedSoLd.count % 4 != 0 { expectedSoLd.append(0) }
        #expect(soLd == expectedSoLd)
        var plLd = Data("plcL".utf8) + be32(3) + Data([UInt8(info.uniqueID.utf8.count)]) + Data(info.uniqueID.utf8)
        plLd += be32(1) + be32(1) + be32(16) + be32(2)
        let start = plLd.count
        for corner in corners { plLd += be64(Double(corner.x).bitPattern) + be64(Double(corner.y).bitPattern) }
        plLd += PSDDescriptorWriter.block2(warp(CGSize(width: 10, height: 8)), version: 0)
        while plLd.count % 4 != 0 { plLd.append(0) }
        expectPlLd(try block("PlLd", in: blocks), plLd, corners: corners, start: start)

        // `liFD` version 7: uuid, file name with its NUL counted, type, creator, size, no open-file descriptor, the
        // contents, an empty child ID, time 0, unlocked.
        var entry = Data("liFD".utf8) + be32(7) + Data([UInt8(info.uniqueID.utf8.count)]) + Data(info.uniqueID.utf8)
        entry += utf16("Logo.png\0") + Data("png ".utf8) + Data(count: 4) + be64(UInt64(contents.count)) + Data([0])
        entry += contents + be32(0) + be64(0) + Data([0])
        #expect(try linkedEntries(data) == [entry])

        let reread = try PSDReader.read(data)
        let smartObject = try #require(reread.layers.first { $0.name == "Logo" }?.smartObject)
        #expect(smartObject.info.uniqueID == info.uniqueID && smartObject.info.placedID == info.placedID)
        #expect(smartObject.info.fileType == "png " && smartObject.info.fileName == "Logo.png" && smartObject.info.isEmbedded)
        #expect(smartObject.payload?.sha256 == SmartObjectPayload.digest(contents))
        #expect(smartObject.info.link?.version == 7)
    }

    /// A Photoshop document's own smart object, and the entry no layer names, come back exactly as they were read: the
    /// placed-layer blocks, every entry byte, and the `lnk2` block between the same neighbours.
    @Test func untouchedSmartObjectsAreWrittenBackByteForByte() throws {
        let contents = try png()
        let (session, _) = try openedSmartObject()
        let (data, report) = try written(session)
        #expect(report.warnings.isEmpty)
        #expect(try documentBlocks(data).map(\.key) == ["Patt", "lnk2", "FMsk"])
        #expect(try linkedEntries(data) == [usedEntry(contents), spareEntry])
        let original = PSDFixture.smartObjectBlocks(uuid: "u", size: CGSize(width: 10, height: 8), quad: quad, placedID: placedID)
        let blocks = try layerBlocks(data)["Logo"]
        #expect(try block("PlLd", in: blocks) == original[0].data)
        #expect(try block("SoLd", in: blocks) == original[1].data)
    }

    /// Moving, scaling or resizing the document moves the placement: `Trnf`, `nonAffineTransform` and `PlLd`'s corners
    /// are rewritten (only past 0.01 px) and everything else stays as read, the contents entry included.
    @Test func aMovedOrResizedSmartObjectIsPlacedWhereItNowIs() async throws {
        let contents = try png()
        let original = PSDFixture.smartObjectBlocks(uuid: "u", size: CGSize(width: 10, height: 8), quad: quad, placedID: placedID)
        let storedSoLd = try descriptor(original[1].data)
        func expectPlaced(_ session: EditorSession, on corners: [CGPoint], sourceLocation: SourceLocation = #_sourceLocation) throws {
            let data = try written(session).data
            let blocks = try layerBlocks(data)["Logo"]
            let soLd = try block("SoLd", in: blocks)
            let expected = placing(storedSoLd, on: corners, asIn: try descriptor(soLd), sourceLocation: sourceLocation)
            #expect(soLd == Data("soLD".utf8) + be32(4) + PSDDescriptorWriter.block(expected), sourceLocation: sourceLocation)
            // `plcL`, version, the uuid "u", page, pages, anti-alias and type come before the corners.
            expectPlLd(try block("PlLd", in: blocks), original[0].data, corners: corners, start: 4 + 4 + 2 + 16,
                       sourceLocation: sourceLocation)
            #expect(try linkedEntries(data) == [usedEntry(contents), spareEntry], sourceLocation: sourceLocation)
        }

        let (session, id) = try openedSmartObject()
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document!.layers[index].transform.origin.x += 10
        session.document!.layers[index].transform.origin.y += 5
        try expectPlaced(session, on: moved(quad, by: 10, 5))

        // Within 0.01 px of what the file says, the block is Photoshop's own.
        session.document!.layers[index].transform.origin.x -= 9.996
        session.document!.layers[index].transform.origin.y -= 5
        let data = try written(session).data
        #expect(try block("SoLd", in: try layerBlocks(data)["Logo"]) == original[1].data)

        // Image Size keeps the contents (it isn't a replacement) and scales the placement.
        let (resizedSession, _) = try openedSmartObject()
        resizedSession.applyImageSize(try await ImageResizer.shared.resize(try #require(resizedSession.projectSnapshot()),
            to: ImageSizeOptions(width: 32, height: 32, resolution: 72)))
        try expectPlaced(resizedSession, on: moved(quad, by: 0, 0, scale: 0.5))
    }

    /// Replaced contents are a new smart object: new `PlLd` and `SoLd` where the old ones were, and a version 7 `liFD`
    /// entry instead of the old contents' (which no layer holds any more).
    @Test func replacedContentsAreWrittenAsANewEntry() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replacement = try png(width: 20, height: 10)
        let url = root.appendingPathComponent("Banner.png")
        try replacement.write(to: url)
        let (session, id) = try openedSmartObject()
        let before = try #require(session.document?.layers.first { $0.id == id }?.psdExtras?.blocks.map(\.key))
        try await session.replaceSmartObjectContents(id, with: url, fitting: .stretch)
        let info = try #require(session.document?.layers.first { $0.id == id }?.smartObject?.info)

        let data = try written(session).data
        let blocks = try #require(try layerBlocks(data)["Logo"])
        // The file's blocks, in their order (the writer adds lyid).
        #expect(blocks.map(\.key).filter { $0 != "lyid" } == before.filter { $0 != "lyid" })
        let soLd = try descriptor(try block("SoLd", in: blocks))
        #expect(soLd.items.map(\.key.id) == ["Idnt", "placed", "PgNm", "totalPages", "Crop", "frameStep", "duration",
                                             "frameCount", "Annt", "Type", "Trnf", "nonAffineTransform", "warp", "Sz  ", "Rslt"])
        #expect(soLd.string("Idnt") == info.uniqueID && soLd.string("placed") == info.placedID)
        #expect(close(values(soLd["Trnf"]), quad) && close(values(soLd["nonAffineTransform"]), quad))
        #expect(soLd["Sz  "] == .object(PSDDescriptor(classID: "Pnt ", items: [(key: "Wdth", value: .double(20)),
                                                                              (key: "Hght", value: .double(10))])))
        let entries = try linkedEntries(data)
        #expect(entries.count == 2 && entries.last == spareEntry)
        let entry = try PSDSmartObjects.parseEntry(try #require(entries.first))
        #expect(entry.uniqueID == info.uniqueID && entry.fileName == "Banner.png" && entry.fileType == "png ")
        #expect(entry.link.kind == "liFD" && entry.link.version == 7 && entry.link.creator == "\0\0\0\0")
        #expect(entry.link.openFileDescriptor == nil && entry.link.childID == "" && entry.link.modTime == 0)
        #expect(entry.link.lockState == 0 && entry.link.fileNameNULCount == nil && entry.link.trailingBytes == nil)
        #expect(entry.data == replacement)
    }

    /// Duplicates share one entry, as in Photoshop, and each gets its own placement ID.
    @Test func duplicatesShareOneEntryAndHaveTheirOwnPlacedIDs() throws {
        let contents = try png()
        let (session, _) = try openedSmartObject()
        session.duplicateActiveLayer()
        let data = try written(session).data
        let document = try PSDReader.read(data)
        let placements = document.layers.compactMap { $0.smartObject?.info }
        #expect(placements.count == 2 && placements.allSatisfy { $0.uniqueID == "u" })
        #expect(placements[0].placedID == placedID)
        #expect(placements[1].placedID != placedID && UUID(uuidString: placements[1].placedID) != nil)
        #expect(placements[1].placedID == placements[1].placedID.lowercased())
        #expect(try linkedEntries(data) == [usedEntry(contents), spareEntry])
    }

    // MARK: Smart objects written as pixels

    /// A smart object made plain pixels (Rasterize, a paint stroke, a baked clip) loses its placed-layer blocks and its
    /// entry. A placement Compositor couldn't read stays as Photoshop wrote it, its entry among the others.
    @Test func smartObjectsThatBecamePixelsAreWrittenAsPixels() throws {
        var broken = PSDRecord(id: UUID(), name: "Broken")
        broken.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        broken.image = try raster(width: 8, height: 8)
        let garbage = Data("soLD\0\0\0\u{4}garbage".utf8)
        broken.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "SoLd", data: garbage)])
        let brokenEntry = PSDFixture.linkedEntry(PSDFixture.LinkedEntry(uuid: "broken", fileName: "B.png", data: Data([1])))
        let (session, id) = try openedSmartObject(extraLayers: [broken],
                                                  entries: [usedEntry(try png()), spareEntry, brokenEntry])
        session.rasterizeSmartObject(id)
        let (data, report) = try written(session)
        #expect(report.warnings.isEmpty)
        let blocks = try layerBlocks(data)
        #expect(blocks["Logo"]?.contains { ["PlLd", "SoLd", "SoLE"].contains($0.key) } == false)
        #expect(try block("SoLd", in: blocks["Broken"]) == garbage)
        #expect(try linkedEntries(data) == [spareEntry, brokenEntry])
        #expect(try PSDReader.read(data).layers.first { $0.name == "Logo" }?.kind != .smartObject)
    }

    /// A smart object whose clip the writer applies to its pixels (its base isn't directly below it) is written as
    /// those pixels: Photoshop would draw the contents again, unclipped, on its first update.
    @Test func aSmartObjectWithABakedClipIsWrittenAsPixels() throws {
        var base = PSDRecord(id: UUID(), name: "Base")
        base.bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
        base.image = try raster(width: 64, height: 64)
        var spacer = PSDRecord(id: UUID(), name: "Spacer")
        spacer.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        spacer.image = try raster(width: 2, height: 2)
        let (session, id) = try openedSmartObject(extraLayers: [base, spacer])
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        let baseID = try #require(session.document?.layers.first { $0.name == "Base" }?.id)
        session.document?.layers[index].maskSourceID = baseID
        let (data, report) = try written(session)
        #expect(report.warnings.map(\.layerName) == ["Logo"] && report.warnings.map(\.lossy) == [true])
        #expect(try layerBlocks(data)["Logo"]?.contains { ["PlLd", "SoLd", "SoLE"].contains($0.key) } == false)
        #expect(try linkedEntries(data) == [spareEntry])
        #expect(try PSDReader.read(data).layers.first { $0.name == "Logo" }?.kind != .smartObject)
    }

    /// Projects saved before smart objects were kept turned smart objects into pixels that could have been painted
    /// since; loading one makes them smart objects again, but nothing says their pixels still show the contents, so a
    /// Photoshop save writes them as pixels and says so. Replaced contents are written as a smart object again.
    @Test func smartObjectsFromProjectsSavedBeforeTheyWereKeptAreWrittenAsPixels() async throws {
        let contents = try png()
        let session = EditorSession()
        session.createDocument(width: 64, height: 64, emptyLayer: true)
        session.document?.layers[0].transform = LayerTransform(origin: CGPoint(x: 20, y: 16), size: CGSize(width: 24, height: 24))
        session.document?.layers[0].psdExtras = PSDLayerExtras(
            blocks: PSDFixture.smartObjectBlocks(uuid: "legacy", size: CGSize(width: 10, height: 8), quad: quad))
        session.document?.psdExtras = PSDDocumentExtras(globalBlocks: [
            PSDTaggedBlock(key: "Patt", data: Data([1, 2, 3, 4])),
            PSDFixture.linkedLayersBlock(entries: [PSDFixture.LinkedEntry(uuid: "legacy", fileName: "Logo.png", data: contents)]),
        ])
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Legacy.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let reopened = EditorSession()
        reopened.installProject(try await ProjectStore.shared.load(from: url), from: url)
        let layer = try #require(reopened.document?.layers.first)
        #expect(layer.smartObject?.payload?.data == contents && layer.psdExtras?.importedSmartObject == nil)
        #expect(reopened.document?.psdExtras?.linkedBlockIndex == 1)

        let (data, report) = try written(reopened)
        #expect(report.warnings.map(\.layerName) == [layer.name])
        #expect(report.warnings.first?.message.contains("pixels") == true)
        #expect(try layerBlocks(data)[layer.name]?.contains { ["PlLd", "SoLd"].contains($0.key) } == false)
        #expect(try documentBlocks(data).map(\.key) == ["Patt"])

        let replacement = root.appendingPathComponent("New.png")
        let newContents = try png(width: 4, height: 4)
        try newContents.write(to: replacement)
        reopened.activeLayerID = layer.id
        try await reopened.replaceSmartObjectContents(layer.id, with: replacement)
        let (again, againReport) = try written(reopened)
        #expect(againReport.warnings.isEmpty)
        let rewritten = try PSDReader.read(again).layers.first?.smartObject
        #expect(rewritten?.payload?.data == newContents && rewritten?.info.fileName == "New.png")
    }

    // MARK: Entries and projects

    /// Every kind and version of entry the reader takes apart is put back together field for field (psd-tools'
    /// `LinkedLayer.read` order).
    @Test func entriesAreWrittenBackFieldForField() throws {
        var external = PSDFixture.LinkedEntry(kind: "liFE", uuid: "ext", fileName: "Linked.png", data: Data([1, 2, 3]))
        external.openFile = PSDDescriptor(classID: "null", items: [(key: "compInfo", value: .integer(1))])
        external.externalFileSize = 4_096
        external.childID = "child\0"
        external.modTime = 3.25
        external.lockState = 1
        var old = PSDFixture.LinkedEntry(kind: "liFE", version: 2, uuid: "old", fileName: "Old.png", data: Data([5, 6]))
        old.externalFileSize = 2
        let alias = PSDFixture.LinkedEntry(kind: "liFA", uuid: "alias", fileName: "Alias.psd", fileType: "8BPS", creator: "8BIM")
        let four = PSDFixture.LinkedEntry(version: 4, uuid: "four", fileName: "", data: Data([9]))
        let raws = [usedEntry(try png()), spareEntry, PSDFixture.linkedEntry(external), PSDFixture.linkedEntry(old),
                    PSDFixture.linkedEntry(alias), PSDFixture.linkedEntry(four)]
        for raw in raws {
            let parsed = try PSDSmartObjects.parseEntry(raw)
            var info = SmartObjectInfo(uniqueID: parsed.uniqueID, placedID: "p", fileType: parsed.fileType,
                                       fileName: parsed.fileName, naturalSize: CGSize(width: 1, height: 1), resolution: 72,
                                       quad: .unitSquare, placedType: 2, isEmbedded: parsed.link.kind == "liFD")
            info.link = parsed.link
            #expect(PSDSmartObjectWriter.entry(info, payload: parsed.data.map { SmartObjectPayload(data: $0) }).data == raw,
                    "\(parsed.uniqueID)")
        }
        let used = try PSDSmartObjects.parseEntry(usedEntry(try png()))
        #expect(used.fileName == "Logo.png" && used.link.fileNameNULCount == 2 && used.link.trailingBytes == Data([0xAB, 0xCD, 0xEF]))
        #expect(try PSDSmartObjects.parseEntry(spareEntry).link.fileNameNULCount == nil)
        // Unknown bytes beyond what a project keeps inline are left out rather than refusing the smart object.
        let long = try PSDSmartObjects.parseEntry(spareEntry + Data(count: LinkedEntryInfo.maximumDescriptorBytes + 1))
        #expect(long.link.trailingBytes == nil && long.link.isValid)
    }

    /// A project keeps what an untouched entry needs to be written back byte for byte, and where the file had its
    /// linked-layer blocks.
    @Test func aProjectKeepsWhatWritingTheEntriesBackNeeds() async throws {
        let contents = try png()
        let (session, id) = try openedSmartObject()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Smart.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let manifest = try String(contentsOf: url.appendingPathComponent("manifest.json"), encoding: .utf8)
        #expect(manifest.contains("\"fileNameNULCount\"") && manifest.contains("\"trailingBytes\"")
                && manifest.contains("\"linkedBlockIndex\""))
        let reopened = EditorSession()
        reopened.installProject(try await ProjectStore.shared.load(from: url), from: url)
        let link = try #require(reopened.document?.layers.first { $0.id == id }?.smartObject?.info.link)
        #expect(link.fileNameNULCount == 2 && link.trailingBytes == Data([0xAB, 0xCD, 0xEF]))
        #expect(reopened.document?.psdExtras?.linkedBlockIndex == 1)
        #expect(reopened.document?.psdExtras == session.document?.psdExtras)
        let data = try written(reopened).data
        #expect(try documentBlocks(data).map(\.key) == ["Patt", "lnk2", "FMsk"])
        #expect(try linkedEntries(data) == [usedEntry(contents), spareEntry])
    }

    // MARK: psd-tools (opt-in)

    /// psd-tools 1.19 reads the smart objects written, and writing its own parse of each entry back gives the bytes
    /// Compositor wrote (so the field order is psd-tools' `LinkedLayer.read`). Opt-in, since it needs Python with
    /// psd-tools: `TEST_RUNNER_COMPOSITOR_PSD_TOOLS_PYTHON=<python> xcodebuild test …`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["COMPOSITOR_PSD_TOOLS_PYTHON"] != nil), .timeLimit(.minutes(1)))
    func psdToolsReadsTheSmartObjectsWritten() async throws {
        let python = try #require(ProcessInfo.processInfo.environment["COMPOSITOR_PSD_TOOLS_PYTHON"])
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = try png()
        let placedContents = try png(width: 6, height: 6)
        let placedURL = root.appendingPathComponent("Dot.png")
        try placedContents.write(to: placedURL)
        // psd-tools keeps no bytes beyond the fields it knows, and reads the other document blocks: none of those here.
        let (session, id) = try openedSmartObject(entries: [usedEntry(contents, trailing: Data()), spareEntry], neighbours: false)
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document!.layers[index].transform.origin.x += 3
        let dotID = try await session.placeSmartObject(from: placedURL)
        let placed = try #require(session.document?.layers.first { $0.id == dotID }?.smartObject?.info)
        let (data, _) = try written(session)
        let file = root.appendingPathComponent("SmartObjects.psd")
        try data.write(to: file)

        let script = """
        import hashlib, io, json, logging, sys
        from psd_tools import PSDImage
        from psd_tools.constants import Tag
        messages = []
        class Keep(logging.Handler):
            def emit(self, record):
                messages.append(record.getMessage())
        logging.getLogger("psd_tools").addHandler(Keep(level=logging.WARNING))
        psd = PSDImage.open(sys.argv[1])
        layers = []
        for layer in psd.descendants():
            if layer.kind == "smartobject":
                so = layer.smart_object
                layers.append({"unique_id": so.unique_id, "kind": so.kind, "filetype": so.filetype,
                               "filename": so.filename, "sha256": hashlib.sha256(so.data).hexdigest(),
                               "box": list(so.transform_box)})
        blocks = psd._record.layer_and_mask_information.tagged_blocks
        entries = []
        for key in (Tag.LINKED_LAYER1, Tag.LINKED_LAYER2, Tag.LINKED_LAYER3, Tag.LINKED_LAYER_EXTERNAL):
            if key in blocks:
                for item in blocks.get_data(key):
                    buffer = io.BytesIO()
                    item.write(buffer)
                    entries.append({"uuid": item.uuid, "version": item.version,
                                    "sha256": hashlib.sha256(buffer.getvalue()).hexdigest()})
        print(json.dumps({"layers": layers, "entries": entries, "messages": messages}))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", script, file.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let json = try #require(try JSONSerialization.jsonObject(with: stdout) as? [String: Any])
        let messages = json["messages"] as? [String]
        #expect(messages?.isEmpty == true, "\(messages ?? [])")
        let layers = try #require(json["layers"] as? [[String: Any]])
        let logo = try #require(layers.first { $0["unique_id"] as? String == "u" })
        #expect(logo["kind"] as? String == "data" && logo["filetype"] as? String == "png")
        #expect(logo["filename"] as? String == "Logo.png" && logo["sha256"] as? String == SmartObjectPayload.digest(contents))
        #expect(close(logo["box"] as? [Double], moved(quad, by: 3, 0)))
        let dot = try #require(layers.first { $0["unique_id"] as? String == placed.uniqueID })
        #expect(dot["kind"] as? String == "data" && dot["filetype"] as? String == "png" && dot["filename"] as? String == "Dot.png")
        #expect(dot["sha256"] as? String == SmartObjectPayload.digest(placedContents))
        let written = try linkedEntries(data)
        let entries = try #require(json["entries"] as? [[String: Any]])
        #expect(entries.compactMap { $0["sha256"] as? String } == written.map(SmartObjectPayload.digest))
        #expect(entries.compactMap { $0["version"] as? Int } == [7, 7, 7])
    }
}

// MARK: Bytes

private func be32(_ value: UInt32) -> Data {
    Data([UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
}

private func be64(_ value: UInt64) -> Data {
    be32(UInt32(value >> 32)) + be32(UInt32(value & 0xFFFF_FFFF))
}

/// `u32` UTF-16 count, then the units big-endian.
private func utf16(_ string: String) -> Data {
    string.utf16.reduce(be32(UInt32(string.utf16.count))) { $0 + Data([UInt8($1 >> 8), UInt8($1 & 0xFF)]) }
}
