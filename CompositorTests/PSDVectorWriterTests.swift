import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Shape layers written as Photoshop vector shapes (Task 4.6): `vscg` fill, `vmsk` path, `vogk` origination and
/// `vstk` stroke for new and edited live shapes, the file's own blocks for untouched ones, and pixels for shapes that
/// were rasterized or can't be a Photoshop shape.
@MainActor
@Suite(.serialized)
struct PSDVectorWriterTests {
    // MARK: Fixtures

    private func shapeLayer(_ name: String, _ style: LayerShapeStyle, _ rect: CGRect, rotation: CGFloat = 0,
                            effects: LayerEffects? = nil) throws -> ImageLayer {
        let size = CGSize(width: max(1, rect.width.rounded()), height: max(1, rect.height.rounded()))
        let image = try EditorSession.shapeImage(style, size: size)
        return ImageLayer(id: UUID(), asset: ImportedImage(image: image, thumbnail: image, name: name), name: name,
                          isVisible: true, transform: LayerTransform(origin: rect.origin, size: rect.size, rotation: rotation),
                          shape: LayerShape(style: style, image: image), effects: effects)
    }

    private func style(_ kind: ShapeKind, _ rgb: (CGFloat, CGFloat, CGFloat), radius: CGFloat = 0,
                       stroke: ShapeStroke? = nil) -> LayerShapeStyle {
        LayerShapeStyle(kind: kind, red: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, cornerRadius: radius,
                        stroke: stroke)
    }

    /// A line from `start` to `end` (document pixels) `width` thick, on a layer boxing its ends with room for the
    /// line and its stroke, as the Shape tool makes one.
    private func lineLayer(_ name: String, from start: CGPoint, to end: CGPoint, width: CGFloat,
                           _ rgb: (CGFloat, CGFloat, CGFloat), stroke: ShapeStroke? = nil) throws -> ImageLayer {
        let reach = width / 2 + (stroke?.outset ?? 0)
        let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x),
                         height: abs(end.y - start.y)).insetBy(dx: -reach, dy: -reach)
        func unit(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - box.minX) / box.width, y: (point.y - box.minY) / box.height)
        }
        var line = style(.line, rgb, stroke: stroke)
        line.lineWidth = width
        line.start = unit(start)
        line.end = unit(end)
        return try shapeLayer(name, line, box)
    }

    private func session(_ width: Int, _ height: Int, _ layers: [ImageLayer], resolution: Double = 72) -> EditorSession {
        let session = EditorSession()
        session.document = CanvasDocument(width: width, height: height, layers: layers, resolution: resolution)
        session.activeLayerID = layers.last?.id
        return session
    }

    private func planned(_ session: EditorSession, _ options: PSDWriteOptions = .init()) throws -> PSDLayerRecordWriter.Plan {
        try PSDLayerRecordWriter.plan(try #require(session.psdWriteRequest()), options: options)
    }

    private func record(_ name: String, in plan: PSDLayerRecordWriter.Plan) throws -> PSDLayerRecord {
        try #require(plan.records.first { $0.name == name })
    }

    private func block(_ record: PSDLayerRecord, _ key: String) -> Data? {
        record.blocks.first { $0.key == key }?.data
    }

    /// The file written for `session`, read back.
    private func reread(_ session: EditorSession) throws -> PSDDocument {
        try PSDReader.read(try PSDWriter.data(for: try #require(session.psdWriteRequest())).data)
    }

    /// A `vmsk` payload's records after its version and flags: each one's selector and 24-byte body.
    private func pathRecords(_ vmsk: Data) -> [(selector: Int16, body: Data)] {
        let data = Data(vmsk)
        var records: [(selector: Int16, body: Data)] = []
        var offset = 8
        while offset + 26 <= data.count {
            records.append((Int16(bitPattern: UInt16(data[offset]) << 8 | UInt16(data[offset + 1])),
                            data.subdata(in: offset + 2 ..< offset + 26)))
            offset += 26
        }
        return records
    }

    /// A knot record's six numbers: incoming y and x, anchor y and x, outgoing y and x, as 8.24 fractions of the canvas.
    private func numbers(_ body: Data) -> [Int32] {
        (0..<6).map { index in
            Int32(bitPattern: body.subdata(in: index * 4 ..< index * 4 + 4).reduce(0) { $0 << 8 | UInt32($1) })
        }
    }

    /// The anchors of a `vmsk` path in document pixels.
    private func anchors(_ vmsk: Data, canvas: CGSize) -> [CGPoint] {
        pathRecords(vmsk).filter { [1, 2, 4, 5].contains($0.selector) }.map { knot in
            let values = numbers(knot.body)
            return CGPoint(x: Double(values[3]) / 0x1000000 * canvas.width, y: Double(values[2]) / 0x1000000 * canvas.height)
        }
    }

    /// The one item of a `vogk` payload's `keyDescriptorList`.
    private func originItem(_ vogk: Data?) throws -> PSDDescriptor {
        let data = try #require(vogk)
        #expect(data.prefix(4) == Data([0, 0, 0, 1]))
        var offset = 4
        let root = try PSDDescriptorReader.readBlock(data, at: &offset)
        #expect(root.items.map(\.key.id) == ["keyDescriptorList"])
        let items = try #require(root.list("keyDescriptorList"))
        #expect(items.count == 1)
        guard case .object(let item)? = items.first else { throw PSDError.truncated }
        return item
    }

    private func number(_ value: PSDDescriptorValue?) -> Double? {
        switch value {
        case .unitFloat(_, let value)?, .double(let value)?: value
        case .integer(let value)?: Double(value)
        default: nil
        }
    }

    private func box(_ item: PSDDescriptor) throws -> CGRect {
        let box = try #require(item.object("keyOriginShapeBBox"))
        #expect(box.classID.id == "unitRect")
        #expect(box.items.map(\.key.id) == ["unitValueQuadVersion", "Top ", "Left", "Btom", "Rght"])
        #expect(["Top ", "Left", "Btom", "Rght"].allSatisfy { box.unit($0)?.unit == "#Pxl" })
        let left = try #require(number(box["Left"])), top = try #require(number(box["Top "]))
        let right = try #require(number(box["Rght"])), bottom = try #require(number(box["Btom"]))
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private func point(_ descriptor: PSDDescriptor?) throws -> CGPoint {
        let point = try #require(descriptor)
        #expect(point.classID.id == "Pnt ")
        return CGPoint(x: try #require(number(point["Hrzn"])), y: try #require(number(point["Vrtc"])))
    }

    private func near(_ a: CGRect, _ b: CGRect, within tolerance: CGFloat = 1e-6) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }

    private func near(_ a: CGPoint, _ b: CGPoint, within tolerance: CGFloat = 1e-6) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    private func descriptor(_ block: Data?) throws -> PSDDescriptor {
        var offset = 0
        return try PSDDescriptorReader.readBlock(try #require(block), at: &offset)
    }

    /// `vscg`'s fill color, 0–255.
    private func fillColor(_ vscg: Data?) throws -> [CGFloat] {
        let data = try #require(vscg)
        #expect(data.prefix(4) == Data("SoCo".utf8))
        var offset = 4
        let rgb = try #require(try PSDDescriptorReader.readBlock(data, at: &offset).rgb("Clr "))
        return [rgb.r, rgb.g, rgb.b]
    }

    private func luni(_ name: String) -> PSDTaggedBlock {
        var data = Data([0, 0, 0, UInt8(name.utf16.count)])
        for unit in name.utf16 { data.append(contentsOf: [UInt8(unit >> 8), UInt8(unit & 0xFF)]) }
        return PSDTaggedBlock(key: "luni", data: data)
    }

    /// A stroke as Photoshop stores one, joined round (which Compositor doesn't model).
    private func roundJoinedStroke(width: Double, color: (Double, Double, Double), alignment: String) throws -> Data {
        var stroke = try descriptor(PSDFixture.shapeStrokeBlock(enabled: true, width: width, color: color, alignment: alignment))
        let join = try #require(stroke.items.firstIndex { $0.key.id == "strokeStyleLineJoinType" })
        stroke.items[join].value = .enumerated(type: "strokeStyleLineJoinType", value: "strokeStyleRoundJoin")
        return PSDDescriptorWriter.block(stroke)
    }

    private static let photoshopCanvas = CGSize(width: 200, height: 120)
    /// Where Photoshop drew the rectangle `photoshopShape` holds, and the stroke around it.
    private static let photoshopRect = CGRect(x: 20, y: 30, width: 100, height: 50)

    /// A 100 × 50 rectangle at (20, 30) on a 200 × 120 canvas as Photoshop 2026 stores a shape layer (`vscg vsms vowv
    /// vogk luni lyid lspf lclr vstk`, flags 0x18), blue with a 10 px round-joined yellow stroke centered on its edge.
    /// `soCo` adds the older fill block, which import reads first.
    private func photoshopShape(soCo: Bool = false) throws -> PSDRecord {
        let rect = Self.photoshopRect
        var blocks = [PSDTaggedBlock(key: "vscg", data: PSDFixture.vectorContentBlock(red: 0, green: 0, blue: 255))]
        if soCo {
            blocks.append(PSDTaggedBlock(key: "SoCo", data: PSDDescriptorWriter.block(PSDDescriptor(classID: "null", items: [
                (key: "Clr ", value: .object(PSDDescriptor(classID: "RGBC", items: [
                    (key: "Rd  ", value: .double(0)), (key: "Grn ", value: .double(0)), (key: "Bl  ", value: .double(255)),
                ]))),
            ]))))
        }
        blocks += [
            PSDTaggedBlock(key: "vsms", data: PSDFixture.vectorPathBlock(canvas: Self.photoshopCanvas,
                                                                         subpaths: [PSDFixture.turnedCorners(of: rect, degrees: 0)])),
            PSDTaggedBlock(key: "vowv", data: Data([0, 0, 0, 2])),
            PSDTaggedBlock(key: "vogk", data: PSDFixture.originationBlock([PSDFixture.rectangleOrigination(type: 1, rect: rect)])),
            luni("Box"),
            PSDTaggedBlock(key: "lyid", data: Data([0, 0, 0, 5])),
            PSDTaggedBlock(key: "lspf", data: Data(count: 4)),
            PSDTaggedBlock(key: "lclr", data: Data(count: 8)),
            PSDTaggedBlock(key: "vstk", data: try roundJoinedStroke(width: 10, color: (255, 255, 0), alignment: "strokeStyleAlignCenter")),
        ]
        var record = PSDRecord(id: UUID(), name: "Box")
        record.bounds = rect.insetBy(dx: -5, dy: -5)
        let context = try BrushRaster.context(width: 110, height: 60, mask: false)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 110, height: 60))
        record.image = context.makeImage()
        record.extras = PSDLayerExtras(blocks: blocks, flags: 0x18, layerID: 5, importedName: "Box")
        return record
    }

    /// The Photoshop shape, opened as the app opens a PSD; `file` is the fixture's bytes.
    private func openedPhotoshopShape(soCo: Bool = false) throws -> (session: EditorSession, file: Data) {
        let document = PSDDocument(width: Int(Self.photoshopCanvas.width), height: Int(Self.photoshopCanvas.height),
                                   resolution: 72, layers: [try photoshopShape(soCo: soCo)])
        let context = try BrushRaster.context(width: 200, height: 120, mask: false)
        guard let composite = context.makeImage() else { throw ExportError.render }
        let data = try PSDFixture.data(document, composite: composite)
        let session = EditorSession()
        try session.insertPhotoshop(try PSDDocumentBuilder.makeImport(try PSDReader.read(data)), named: "Fixture")
        return (session, data)
    }

    /// The layer's shape drawn again at its size in `style`, as a style edit leaves it.
    private func restyle(_ session: EditorSession, _ index: Int, _ style: LayerShapeStyle) throws {
        let layer = try #require(session.document?.layers[index])
        let image = try EditorSession.shapeImage(style, size: layer.transform.size)
        session.document?.layers[index].asset = ImportedImage(image: image, thumbnail: image, name: layer.name)
        session.document?.layers[index].shape = LayerShape(style: style, image: image)
    }

    // MARK: Photoshop's own shapes

    /// `stroke` with Photoshop's older spelling of its Normal blend, `Nrml`, as 2026 spells it, `normal`.
    private func withNormalBlend(_ stroke: PSDDescriptor) -> PSDDescriptor {
        var stroke = stroke
        if let blend = stroke.items.firstIndex(where: { $0.key.id == "strokeStyleBlendMode" }),
           stroke.items[blend].value == .enumerated(type: "BlnM", value: "Nrml") {
            stroke.items[blend].value = .enumerated(type: "BlnM", value: PSDKey("normal"))
        }
        return stroke
    }

    /// Photoshop's blue circle from before 2026 (`PSDVectorFixtures.circle`), drawn in Compositor at the same place:
    /// its path has Photoshop's four anchors to within one 8.24 step (Photoshop 2026 starts its ellipses at the top and
    /// sets their control points at 0.5523 of the radius, where this one started at the bottom with 0.553), its fill
    /// byte for byte, and its switched-off stroke, which keeps the shape's path in `vsms` and fill in `vscg`, key for key.
    @Test func theFixtureCircleIsWrittenAsPhotoshopWroteIt() throws {
        let fixture = PSDVectorFixtures.circle()
        let stroke = ShapeStroke(enabled: false, width: 9.869200977592921, red: 1, green: 1, blue: 0, alignment: .center)
        let circle = try shapeLayer("Circle", style(.ellipse, (0, 110, 255), stroke: stroke),
                                    CGRect(x: 454, y: 513, width: 328, height: 328))
        let plan = try planned(session(1920, 1080, [circle]))
        let written = try record("Circle", in: plan)
        #expect(block(written, "vmsk") == nil && block(written, "SoCo") == nil)
        let vsms = try #require(block(written, "vsms")), expected = try #require(fixture["vmsk"])
        #expect(vsms.count == expected.count)
        #expect(vsms.prefix(8) == expected.prefix(8))
        let mine = pathRecords(vsms), photoshops = pathRecords(expected)
        #expect(mine.map(\.selector) == [6, 8, 0, 1, 1, 1, 1])
        #expect(zip(mine, photoshops).prefix(3).allSatisfy { $0.body == $1.body })
        let ourAnchors = mine.dropFirst(3).map { Array(numbers($0.body)[2...3]) }
        let theirAnchors = photoshops.dropFirst(3).map { Array(numbers($0.body)[2...3]) }
        #expect(theirAnchors.allSatisfy { theirs in
            ourAnchors.contains { ours in zip(ours, theirs).allSatisfy { abs(Int($0) - Int($1)) <= 1 } }
        }, "\(ourAnchors) vs \(theirAnchors)")
        #expect(vsms.suffix(2) == Data([0, 0]))
        #expect(try descriptor(block(written, "vstk")) == withNormalBlend(try descriptor(fixture["vstk"])))
        #expect(block(written, "vscg") == Data("SoCo".utf8) + (fixture["SoCo"] ?? Data()))
        #expect(plan.warnings.isEmpty)
    }

    /// Photoshop's black rectangle with its yellow 9.87 px centered stroke: the path has Photoshop's four corners in
    /// its clockwise order (starting, as Photoshop 2026's rectangles do, at the top-left one where this older one
    /// started at the top-right), with sharp (unlinked) corners, and the stroke is Photoshop's key for key. The layer's
    /// box holds the stroke, so the path is the box inset by half the stroke.
    @Test func theFixtureRectangleIsWrittenAsPhotoshopWroteIt() throws {
        let fixture = PSDVectorFixtures.rectangle()
        let width = 9.869200977592921
        let stroke = ShapeStroke(enabled: true, width: width, red: 1, green: 1, blue: 0, alignment: .center)
        let rectangle = try shapeLayer("Rectangle", style(.rectangle, (0, 0, 0), stroke: stroke),
                                       CGRect(x: 945, y: 153, width: 646, height: 182).insetBy(dx: -width / 2, dy: -width / 2))
        let written = try record("Rectangle", in: try planned(session(1920, 1080, [rectangle])))
        let vsms = try #require(block(written, "vsms")), expected = try #require(fixture["vmsk"])
        #expect(vsms.count == expected.count)
        let mine = pathRecords(vsms), photoshops = pathRecords(expected)
        #expect(mine.map(\.selector) == [6, 8, 0, 2, 2, 2, 2])
        // Photoshop's knots top-right, bottom-right, bottom-left, top-left; ours from the top-left.
        let theirKnots = Array(photoshops[3...]), ours = Array(mine[3...])
        for (index, knot) in ours.enumerated() {
            let theirs = theirKnots[(index + 3) % 4]
            #expect(zip(numbers(knot.body), numbers(theirs.body)).allSatisfy { abs(Int($0) - Int($1)) <= 1 },
                    "\(numbers(knot.body)) vs \(numbers(theirs.body))")
        }
        #expect(mine[2].body == photoshops[2].body)
        #expect(try descriptor(block(written, "vstk")) == withNormalBlend(try descriptor(fixture["vstk"])))
        #expect(block(written, "vscg") == Data("SoCo".utf8) + (fixture["SoCo"] ?? Data()))
    }

    // MARK: Origination

    /// `vogk` holds one item describing the shape as Photoshop does and import reads it back: its type, the
    /// document's resolution, the box of its path, the corners of that box (a line's band; none on an ellipse), an
    /// identity `Trnf`, index 0, never `keyShapeInvalidated`.
    @Test func theOriginationDescribesEachShapeAsImportChecksIt() throws {
        let plain = try shapeLayer("Plain", style(.rectangle, (255, 0, 0)), CGRect(x: 10, y: 20, width: 80, height: 40))
        let rounded = try shapeLayer("Rounded", style(.rectangle, (0, 255, 0), radius: 12,
                                     stroke: ShapeStroke(enabled: true, width: 4, red: 0, green: 0, blue: 0, alignment: .outside)),
                                     CGRect(x: 100, y: 20, width: 98, height: 58))
        let pill = try shapeLayer("Pill", style(.rectangle, (0, 255, 0), radius: 80), CGRect(x: 10, y: 150, width: 90, height: 30))
        let oval = try shapeLayer("Oval", style(.ellipse, (0, 0, 255)), CGRect(x: 210, y: 20, width: 70, height: 50))
        let line = try lineLayer("Line", from: CGPoint(x: 30, y: 100), to: CGPoint(x: 130, y: 120), width: 6, (9, 9, 9))
        let plan = try planned(session(300, 200, [plain, rounded, pill, oval, line], resolution: 300))

        let common = ["keyOriginType", "keyOriginResolution", "keyOriginShapeBBox", "keyOriginBoxCorners", "Trnf", "keyOriginIndex"]
        func cornersOf(_ box: CGRect) -> [CGPoint] {
            [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY),
             CGPoint(x: box.minX, y: box.maxY)]
        }
        /// `corners` nil: the corners of the box; empty: none written.
        func check(_ name: String, type: Int, box expected: CGRect, keys: [String] = common,
                   corners: [CGPoint]? = nil) throws -> PSDDescriptor {
            let item = try originItem(block(try record(name, in: plan), "vogk"))
            #expect(item.classID.id == "null")
            #expect(item.items.map(\.key.id) == keys, "\(name)")
            #expect(item.int("keyOriginType") == type, "\(name)")
            #expect(item.double("keyOriginResolution") == 300)
            #expect(item.int("keyOriginIndex") == 0)
            #expect(item["keyShapeInvalidated"] == nil)
            let bbox = try box(item)
            #expect(near(bbox, expected), "\(name): \(bbox) vs \(expected)")
            let expectedCorners = corners ?? cornersOf(bbox)
            if expectedCorners.isEmpty {
                #expect(item["keyOriginBoxCorners"] == nil, "\(name)")
            } else {
                let written = try #require(item.object("keyOriginBoxCorners"))
                #expect(written.items.map(\.key.id) == ["rectangleCornerA", "rectangleCornerB", "rectangleCornerC", "rectangleCornerD"])
                let points = try written.items.map { try point(written.object($0.key.id)) }
                #expect(points.count == 4 && zip(points, expectedCorners).allSatisfy { near($0, $1) }, "\(name): \(points)")
            }
            let transform = try #require(item.object("Trnf"))
            #expect(transform.classID.id == "Trnf" && transform.name == "Transform")
            #expect(transform.items.map(\.key.id) == ["xx", "xy", "yx", "yy", "tx", "ty"])
            #expect(transform.items.map { number($0.value) } == [1, 0, 0, 1, 0, 0])
            // The path is the shape the origination describes.
            let written = try record(name, in: plan)
            let vmsk = try #require(block(written, "vmsk") ?? block(written, "vsms"))
            let path = try #require(PSDVector.path(from: vmsk, canvas: CGSize(width: 300, height: 200)))
            #expect(near(path.boundingBoxOfPath, bbox, within: 0.001), "\(name)")
            return item
        }
        _ = try check("Plain", type: 1, box: CGRect(x: 10, y: 20, width: 80, height: 40))
        let radiusKeys = ["keyOriginType", "keyOriginResolution", "keyOriginRRectRadii", "keyOriginShapeBBox",
                          "keyOriginBoxCorners", "Trnf", "keyOriginIndex"]
        let roundedItem = try check("Rounded", type: 2, box: CGRect(x: 104, y: 24, width: 90, height: 50), keys: radiusKeys)
        let radii = try #require(roundedItem.object("keyOriginRRectRadii"))
        #expect(radii.classID.id == "radii")
        #expect(radii.items.map(\.key.id) == ["unitValueQuadVersion", "topRight", "topLeft", "bottomLeft", "bottomRight"])
        #expect(radii.int("unitValueQuadVersion") == 1)
        #expect(["topRight", "topLeft", "bottomLeft", "bottomRight"].map { radii.unit($0)?.unit } == Array(repeating: "#Pxl", count: 4))
        #expect(["topRight", "topLeft", "bottomLeft", "bottomRight"].map { radii.unit($0)?.value } == Array(repeating: 12, count: 4))
        // A radius past half the shorter side draws a pill, and is written as the radius drawn.
        let pillItem = try check("Pill", type: 2, box: CGRect(x: 10, y: 150, width: 90, height: 30), keys: radiusKeys)
        #expect(pillItem.object("keyOriginRRectRadii")?.unit("topLeft")?.value == 15)
        _ = try check("Oval", type: 5, box: CGRect(x: 210, y: 20, width: 70, height: 50),
                      keys: ["keyOriginType", "keyOriginResolution", "keyOriginShapeBBox", "Trnf", "keyOriginIndex"], corners: [])

        let lineKeys = ["keyOriginType", "keyOriginResolution", "keyOriginShapeBBox", "Trnf", "keyOriginLineEnd",
                        "keyOriginLineStart", "keyOriginLineWeight", "keyOriginLineArrowSt", "keyOriginLineArrowEnd",
                        "keyOriginLineArrWdth", "keyOriginLineArrLngth", "keyOriginLineArrConc",
                        "keyOriginLineWidthArrowUnitPixels", "keyOriginLineLengthArrowUnitPixels", "keyOriginBoxCorners",
                        "keyOriginIndex"]
        // The path is the 6 px band from one end to the other, as Photoshop draws it: from the start's right-hand
        // corner (A is the start's left-hand one), across to the end and back. Its box is the band's.
        let start = CGPoint(x: 30, y: 100), end = CGPoint(x: 130, y: 120)
        let length = hypot(CGFloat(100), CGFloat(20))
        let across = CGPoint(x: -20 / length * 3, y: 100 / length * 3)
        let band = [CGPoint(x: start.x - across.x, y: start.y - across.y), CGPoint(x: end.x - across.x, y: end.y - across.y),
                    CGPoint(x: end.x + across.x, y: end.y + across.y), CGPoint(x: start.x + across.x, y: start.y + across.y)]
        let bandBox = CGRect(x: 30 + across.x, y: 100 - across.y, width: 100 - 2 * across.x, height: 20 + 2 * across.y)
        let lineItem = try check("Line", type: 4, box: bandBox, keys: lineKeys, corners: band)
        #expect(lineItem.object("keyOriginLineStart")?.items.map(\.value) == [.double(30), .double(100)])
        #expect(lineItem.object("keyOriginLineEnd")?.items.map(\.value) == [.double(130), .double(120)])
        #expect(lineItem["keyOriginLineWeight"] == .double(6) && lineItem["keyOriginLineArrWdth"] == .double(6))
        #expect(lineItem["keyOriginLineArrLngth"] == .double(0) && lineItem["keyOriginLineArrConc"] == .integer(0))
        #expect(lineItem.bool("keyOriginLineArrowSt") == false && lineItem.bool("keyOriginLineArrowEnd") == false)
        #expect(lineItem.bool("keyOriginLineWidthArrowUnitPixels") == true)
        #expect(lineItem.bool("keyOriginLineLengthArrowUnitPixels") == true)
        let lineAnchors = anchors(try #require(block(try record("Line", in: plan), "vmsk")), canvas: CGSize(width: 300, height: 200))
        #expect(lineAnchors.count == 4 && zip(lineAnchors, [band[3], band[0], band[1], band[2]]).allSatisfy { near($0, $1, within: 0.001) })
    }

    // MARK: Photoshop's encoding

    /// Each kind of shape, drawn in Compositor where Photoshop 2026 drew its own (`PSDVectorFixtures`), is written as
    /// Photoshop wrote it: the same blocks (a shape without a stroke has `SoCo` and `vmsk`, one with a stroke `vscg`,
    /// `vsms` and `vstk`), the same origination (descriptor names, classes, keys in order, value types, and numbers to
    /// 1e-9), the same path to within one 8.24 step, and the same fill and stroke.
    @Test func eachKindIsWrittenAsPhotoshopWritesIt() throws {
        let black = (CGFloat(0), CGFloat(0), CGFloat(0))
        func stroke(_ width: CGFloat, _ rgb: (CGFloat, CGFloat, CGFloat), _ alignment: ShapeStroke.Alignment) -> ShapeStroke {
            ShapeStroke(enabled: true, width: width, red: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, alignment: alignment)
        }
        let layers = [
            ("Diagonal", PSDVectorFixtures.photoshopLine(),
             try lineLayer("Diagonal", from: CGPoint(x: 140, y: 110), to: CGPoint(x: 240, y: 190), width: 8, (240, 120, 0))),
            ("Widened", PSDVectorFixtures.photoshopStrokedLine(),
             try lineLayer("Widened", from: CGPoint(x: 20, y: 210), to: CGPoint(x: 200, y: 210), width: 4, black,
                           stroke: stroke(4, black, .center))),
            ("Rect", PSDVectorFixtures.photoshopRectangle(),
             try shapeLayer("Rect", style(.rectangle, (220, 30, 30)), CGRect(x: 20, y: 20, width: 100, height: 60))),
            ("Rounded", PSDVectorFixtures.photoshopRoundedRectangle(),
             try shapeLayer("Rounded", style(.rectangle, (40, 180, 60), radius: 16, stroke: stroke(6, black, .outside)),
                            CGRect(x: 140, y: 14, width: 112, height: 72))),
            ("Ellipse", PSDVectorFixtures.photoshopEllipse(),
             try shapeLayer("Ellipse", style(.ellipse, (30, 90, 220), stroke: stroke(8, (255, 216.75, 0), .center)),
                            CGRect(x: 270, y: 16, width: 90, height: 90))),
        ]
        let canvas = PSDVectorFixtures.photoshopCanvas
        let plan = try planned(session(Int(canvas.width), Int(canvas.height), layers.map(\.2)))
        for (name, photoshop, _) in layers {
            let written = try record(name, in: plan)
            let theirs = try #require(photoshop["vogk"])
            let ours = try #require(block(written, "vogk"))
            #expect(ours.prefix(4) == theirs.prefix(4))
            var offset = 4, other = 4
            let mine = try PSDDescriptorReader.readBlock(ours, at: &offset)
            let reference = try PSDDescriptorReader.readBlock(theirs, at: &other)
            #expect(differences(mine, reference).isEmpty, "\(name): \(differences(mine, reference))")

            #expect(Set(written.blocks.map(\.key)).intersection(PSDVectorWriter.shapeKeys) == Set(photoshop.keys), "\(name)")
            let pathKey = photoshop["vmsk"] != nil ? "vmsk" : "vsms"
            let path = try #require(photoshop[pathKey])
            let vmsk = try #require(block(written, pathKey), "\(name)")
            #expect(vmsk.count == path.count, "\(name)")
            #expect(vmsk.prefix(8) == path.prefix(8))
            let mineRecords = pathRecords(vmsk), theirRecords = pathRecords(path)
            #expect(mineRecords.map(\.selector) == theirRecords.map(\.selector), "\(name)")
            for (a, b) in zip(mineRecords, theirRecords) where [1, 2].contains(a.selector) {
                #expect(zip(numbers(a.body), numbers(b.body)).allSatisfy { abs(Int($0) - Int($1)) <= 1 },
                        "\(name): \(numbers(a.body)) vs \(numbers(b.body))")
            }
            for (a, b) in zip(mineRecords, theirRecords) where ![1, 2].contains(a.selector) { #expect(a.body == b.body, "\(name)") }

            // The fill (`vscg` after its "SoCo" key), and the stroke.
            let fillKey = photoshop["vscg"] != nil ? "vscg" : "SoCo"
            let skip = fillKey == "vscg" ? 4 : 0
            let ourFill = try #require(block(written, fillKey), "\(name)"), theirFill = try #require(photoshop[fillKey])
            #expect(ourFill.prefix(skip) == theirFill.prefix(skip))
            let ourColor = try descriptor(Data(ourFill.dropFirst(skip))), theirColor = try descriptor(Data(theirFill.dropFirst(skip)))
            #expect(differences(ourColor, theirColor).isEmpty, "\(name): \(differences(ourColor, theirColor))")
            if let theirStroke = photoshop["vstk"] {
                let reference = try descriptor(theirStroke)
                let ourStroke = try descriptor(block(written, "vstk"))
                #expect(differences(ourStroke, reference).isEmpty, "\(name): \(differences(ourStroke, reference))")
            } else {
                #expect(block(written, "vstk") == nil)
            }
        }
    }

    /// Where two descriptors differ: names, class IDs, keys and their order, value types, and numbers beyond 1e-9 or
    /// 1e-6 of the value (Photoshop keeps some colors as 32-bit floats).
    private func differences(_ a: PSDDescriptor, _ b: PSDDescriptor, at path: String = "") -> [String] {
        var found: [String] = []
        if a.name != b.name { found.append("\(path) name \(a.name) vs \(b.name)") }
        if a.classID != b.classID { found.append("\(path) class \(a.classID) vs \(b.classID)") }
        if a.items.map(\.key) != b.items.map(\.key) {
            return found + ["\(path) keys \(a.items.map(\.key.id)) vs \(b.items.map(\.key.id))"]
        }
        for (x, y) in zip(a.items, b.items) {
            found += differences(x.value, y.value, at: path + "." + x.key.id)
        }
        return found
    }

    private func differences(_ a: PSDDescriptorValue, _ b: PSDDescriptorValue, at path: String) -> [String] {
        func close(_ x: Double, _ y: Double) -> Bool { abs(x - y) <= max(1e-9, abs(y) * 1e-7) }
        switch (a, b) {
        case (.object(let x), .object(let y)): return differences(x, y, at: path)
        case (.list(let x), .list(let y)):
            guard x.count == y.count else { return ["\(path) count \(x.count) vs \(y.count)"] }
            return zip(x, y).enumerated().flatMap { differences($1.0, $1.1, at: "\(path)[\($0)]") }
        case (.double(let x), .double(let y)): return close(x, y) ? [] : ["\(path) \(x) vs \(y)"]
        case (.unitFloat(let u, let x), .unitFloat(let v, let y)): return u == v && close(x, y) ? [] : ["\(path) \(u) \(x) vs \(v) \(y)"]
        default: return a == b ? [] : ["\(path) \(a) vs \(b)"]
        }
    }

    // MARK: Reading back

    /// Every kind of shape, filled and stroked, opens again as the same live shape in the same place.
    @Test func writtenShapesOpenAgainAsTheSameLiveShapes() throws {
        func stroke(_ width: CGFloat, _ alignment: ShapeStroke.Alignment, _ rgb: (CGFloat, CGFloat, CGFloat) = (1, 1, 0)) -> ShapeStroke {
            ShapeStroke(enabled: true, width: width, red: rgb.0, green: rgb.1, blue: rgb.2, alignment: alignment)
        }
        let layers = [
            try shapeLayer("Plain", style(.rectangle, (255, 0, 0)), CGRect(x: 20, y: 20, width: 80, height: 50)),
            try shapeLayer("Rounded", style(.rectangle, (0, 200, 0), radius: 14, stroke: stroke(4, .outside)),
                           CGRect(x: 120, y: 20, width: 98, height: 68)),
            try shapeLayer("Oval", style(.ellipse, (0, 0, 255), stroke: stroke(6, .center)), CGRect(x: 20, y: 100, width: 76, height: 96)),
            try shapeLayer("Inside", style(.rectangle, (10, 20, 30), stroke: stroke(5, .inside)), CGRect(x: 240, y: 20, width: 60, height: 60)),
            try shapeLayer("Off", style(.ellipse, (40, 50, 60), stroke: ShapeStroke(enabled: false, width: 8, red: 0, green: 0, blue: 0,
                                                                                      alignment: .outside)),
                           CGRect(x: 320, y: 20, width: 60, height: 40)),
            try lineLayer("Diagonal", from: CGPoint(x: 230, y: 150), to: CGPoint(x: 330, y: 250), width: 6, (200, 100, 0)),
            try lineLayer("Widened", from: CGPoint(x: 60, y: 250), to: CGPoint(x: 160, y: 250), width: 4, (0, 0, 0),
                          stroke: stroke(2, .center, (0, 0, 0))),
        ]
        let document = try reread(session(400, 300, layers))
        for layer in layers {
            let read = try #require(document.layers.first { $0.name == layer.name })
            let original = try #require(layer.shape?.style)
            let shape = try #require(read.shape, "\(layer.name) came back as pixels")
            #expect(read.kind == .vector)
            #expect(shape.kind == original.kind, "\(layer.name)")
            #expect(shape.color == original.color, "\(layer.name)")
            #expect(shape.stroke == original.stroke, "\(layer.name)")
            #expect(abs(shape.cornerRadius - original.cornerRadius) < 1e-9, "\(layer.name)")
            #expect(read.bounds == CGRect(origin: layer.transform.origin, size: layer.transform.size), "\(layer.name): \(read.bounds)")
            if original.kind == .line {
                #expect(abs((shape.lineWidth ?? 0) - (original.lineWidth ?? 0)) < 1e-9)
                let ends = [shape.start, shape.end, original.start, original.end].compactMap { $0 }
                #expect(ends.count == 4)
                #expect(ends.count == 4 && near(ends[0], ends[2]) && near(ends[1], ends[3]), "\(layer.name): \(ends)")
            }
        }
    }

    /// Compositor draws a line's stroke in the line's own color, widening it, so that is the stroke written; and a
    /// line's round ends can't be written, so saving one says so.
    @Test func linesAreWrittenAsCompositorDrawsThemWithAWarningAboutTheirEnds() throws {
        let blue = ShapeStroke(enabled: true, width: 2, red: 0, green: 0, blue: 1, alignment: .center)
        let line = try lineLayer("Line", from: CGPoint(x: 20, y: 40), to: CGPoint(x: 120, y: 40), width: 2, (255, 0, 0), stroke: blue)
        let plan = try planned(session(160, 80, [line]))
        let stroke = try descriptor(block(try record("Line", in: plan), "vstk"))
        #expect(stroke.object("strokeStyleContent")?.rgb("Clr ").map { [$0.r, $0.g, $0.b] } == [255, 0, 0])
        #expect(plan.warnings.map(\.layerName) == ["Line"])
        #expect(plan.warnings.first?.message.contains("flat") == true)
        let read = try #require(try reread(session(160, 80, [line])).layers.first)
        #expect(read.shape?.kind == .line)
        #expect(read.shape?.stroke?.color == PaletteColor(red: 1, green: 0, blue: 0))
        #expect(read.bounds == CGRect(origin: line.transform.origin, size: line.transform.size))
    }

    // MARK: New layers

    /// A new shape layer gets Photoshop's shape blocks in Photoshop's order around the blocks every layer has, and
    /// the flag Photoshop sets on shape layers: with a stroke, `vscg`, `vsms` and `vstk`; without, `SoCo` and `vmsk`.
    @Test func aNewShapeLayerHasPhotoshopsBlocksInPhotoshopsOrder() throws {
        let stroked = try shapeLayer("Stroked", style(.rectangle, (1, 2, 3),
                                     stroke: ShapeStroke(enabled: true, width: 2, red: 0, green: 0, blue: 0, alignment: .inside)),
                                     CGRect(x: 4, y: 4, width: 30, height: 20), effects: LayerEffects(stroke: StrokeEffect()))
        let plain = try shapeLayer("Plain", style(.ellipse, (1, 2, 3)), CGRect(x: 40, y: 4, width: 20, height: 20))
        let plan = try planned(session(80, 40, [stroked, plain]))
        let first = try record("Stroked", in: plan), second = try record("Plain", in: plan)
        #expect(first.blocks.map(\.key) == ["vscg", "lfx2", "vsms", "vogk", "luni", "lyid", "clbl", "infx", "knko", "lspf", "lclr",
                                             "vstk", "fxrp"])
        #expect(second.blocks.map(\.key) == ["SoCo", "vmsk", "vogk", "luni", "lyid", "clbl", "infx", "knko", "lspf", "lclr", "fxrp"])
        #expect(first.flags == 0x18 && second.flags == 0x18)
        // Photoshop's blocks keep their payloads to whole 4-byte words.
        #expect([first, second].flatMap(\.blocks).filter { PSDVectorWriter.shapeKeys.contains($0.key) }
                    .allSatisfy { $0.data.count % 4 == 0 })
        #expect(plan.warnings.isEmpty)
    }

    // MARK: Imported shapes

    /// An imported shape nobody touched is written back exactly as Photoshop stored it.
    @Test func anUntouchedImportedShapeKeepsItsBlocksByteForByte() throws {
        let (session, file) = try openedPhotoshopShape()
        #expect(session.document?.layers.first?.liveShape != nil)
        let original = try #require(try PSDReader.read(file).layers.first?.extras)
        let written = try record("Box", in: try planned(session))
        #expect(written.blocks == original.blocks)
        #expect(written.flags == original.flags)
    }

    /// A moved imported shape gets its path and origination written where it now is, in the file's own blocks (its
    /// `vsms` stays a `vsms`), while the stroke, untouched, keeps its bytes.
    @Test func aMovedImportedShapeIsRewrittenInItsOwnBlocks() throws {
        let (session, file) = try openedPhotoshopShape()
        let original = try #require(try PSDReader.read(file).layers.first?.extras)
        session.document?.layers[0].transform.origin.x += 10
        session.document?.layers[0].transform.origin.y += 5
        let written = try record("Box", in: try planned(session))
        #expect(written.blocks.map(\.key) == original.blocks.map(\.key))
        #expect(block(written, "vstk") == original.block("vstk"))
        #expect(block(written, "vowv") == original.block("vowv"))
        let moved = Self.photoshopRect.offsetBy(dx: 10, dy: 5)
        #expect(near(try box(try originItem(block(written, "vogk"))), moved))
        let vsms = try #require(block(written, "vsms"))
        let path = try #require(PSDVector.path(from: vsms, canvas: Self.photoshopCanvas))
        #expect(near(path.boundingBoxOfPath, moved, within: 0.001))
        #expect(try fillColor(block(written, "vscg")) == [0, 0, 255])
        let read = try #require(try reread(session).layers.first)
        #expect(read.shape == session.document?.layers.first?.shape?.style)
        #expect(read.bounds == Self.photoshopRect.insetBy(dx: -5, dy: -5).offsetBy(dx: 10, dy: 5))
    }

    /// A restyled imported shape gets its new fill in `vscg` (a stroked shape's, so the older `SoCo`, which import would
    /// read first, goes), and its new stroke written into the file's own `vstk`, which keeps what Compositor doesn't
    /// model (the round join).
    @Test func aRestyledImportedShapeKeepsWhatCompositorDoesntModel() throws {
        let (session, _) = try openedPhotoshopShape(soCo: true)
        var restyled = try #require(session.document?.layers.first?.shape?.style)
        restyled.red = 1
        restyled.blue = 0
        restyled.stroke = ShapeStroke(enabled: true, width: 6, red: 0, green: 1, blue: 0, alignment: .inside)
        try restyle(session, 0, restyled)
        let written = try record("Box", in: try planned(session))
        #expect(try fillColor(block(written, "vscg")) == [255, 0, 0])
        #expect(block(written, "SoCo") == nil)
        let stroke = try descriptor(block(written, "vstk"))
        #expect(stroke.items.count == 16)
        #expect(stroke.bool("strokeEnabled") == true && stroke.bool("fillEnabled") == true)
        #expect(stroke.unit("strokeStyleLineWidth")?.unit == "#Pxl" && stroke.unit("strokeStyleLineWidth")?.value == 6)
        #expect(stroke.enumValue("strokeStyleLineAlignment") == "strokeStyleAlignInside")
        #expect(stroke.object("strokeStyleContent")?.rgb("Clr ").map { [$0.r, $0.g, $0.b] } == [0, 255, 0])
        #expect(stroke.enumValue("strokeStyleLineJoinType") == "strokeStyleRoundJoin")
        // The stroke no longer reaches outside, so the shape is the whole layer box.
        #expect(near(try box(try originItem(block(written, "vogk"))), Self.photoshopRect.insetBy(dx: -5, dy: -5)))
        let read = try #require(try reread(session).layers.first)
        #expect(read.shape == restyled)
    }

    /// A shape rasterized (or painted) in Compositor is plain pixels: its fill and vector blocks are left out, and so
    /// is the flag that says Photoshop draws the layer from them.
    @Test func aRasterizedShapeIsWrittenAsPixelsWithoutItsVectorBlocks() throws {
        let (session, _) = try openedPhotoshopShape(soCo: true)
        try session.rasterizeLayer(try #require(session.document?.layers.first?.id))
        #expect(session.document?.layers.first?.psdExtras?.importedShape != nil)
        let plan = try planned(session)
        let written = try record("Box", in: plan)
        #expect(written.blocks.map(\.key) == ["luni", "lyid", "lspf", "lclr"])
        #expect(written.flags & 0x10 == 0)
        #expect(plan.warnings.isEmpty)
        let read = try #require(try reread(session).layers.first)
        #expect(read.kind == .raster && read.shape == nil)
    }

    /// Without the Photoshop data, an imported shape is written as a new one.
    @Test func withoutPhotoshopDataAnImportedShapeIsWrittenFresh() throws {
        let (session, _) = try openedPhotoshopShape()
        let written = try record("Box", in: try planned(session, PSDWriteOptions(preserveExtras: false)))
        #expect(written.blocks.map(\.key) == ["vscg", "vsms", "vogk", "luni", "lyid", "clbl", "infx", "knko", "lspf", "lclr",
                                              "vstk", "fxrp"])
        #expect(try descriptor(block(written, "vstk")).enumValue("strokeStyleLineJoinType") == "strokeStyleMiterJoin")
    }

    /// A shape whose clip the writer bakes into its pixels (its base isn't directly below it) is written as those
    /// pixels, since Photoshop draws a shape layer from its vector blocks and would leave the clip out. A shape clipped
    /// to the layer directly below stays a shape.
    @Test func aShapeWhoseClipIsBakedIsWrittenAsItsPixels() throws {
        func pixels(_ name: String, _ rect: CGRect) throws -> ImageLayer {
            let context = try BrushRaster.context(width: Int(rect.width), height: Int(rect.height), mask: false)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: rect.size))
            guard let image = context.makeImage() else { throw ExportError.render }
            return ImageLayer(id: UUID(), asset: ImportedImage(image: image, thumbnail: image, name: name), name: name,
                              isVisible: true, transform: LayerTransform(origin: rect.origin, size: rect.size))
        }
        let base = try pixels("Base", CGRect(x: 0, y: 0, width: 20, height: 20))
        let spacer = try pixels("Spacer", CGRect(x: 30, y: 30, width: 8, height: 8))
        var adjacent = try shapeLayer("Adjacent", style(.ellipse, (0, 0, 255)), CGRect(x: 28, y: 28, width: 12, height: 12))
        adjacent.maskSourceID = spacer.id
        var apart = try shapeLayer("Apart", style(.rectangle, (255, 0, 0)), CGRect(x: 0, y: 0, width: 30, height: 30))
        apart.maskSourceID = base.id
        let plan = try planned(session(40, 40, [base, spacer, adjacent, apart]))
        let baked = try record("Apart", in: plan), clipped = try record("Adjacent", in: plan)
        #expect(!baked.blocks.contains { PSDVectorWriter.shapeKeys.contains($0.key) })
        #expect(baked.flags & 0x10 == 0)
        #expect(plan.warnings.map(\.layerName) == ["Apart"])
        #expect(clipped.clipping == 1)
        #expect(clipped.blocks.map(\.key).prefix(3) == ["SoCo", "vmsk", "vogk"])
    }

    // MARK: Turned and degenerate shapes

    /// A quarter-turned shape is still upright, so its origination holds its turned box. A line turns with its ends.
    /// Any other angle can't be a live Photoshop shape that Compositor reads back: it is written as its turned path
    /// without an origination, with a warning, and opens again as pixels.
    @Test func turnedShapesAreWrittenAsTheirTurnedPaths() throws {
        let quarter = try shapeLayer("Quarter", style(.rectangle, (255, 0, 0)), CGRect(x: 100, y: 100, width: 60, height: 20),
                                     rotation: 90)
        let turned = try shapeLayer("Turned", style(.rectangle, (0, 0, 255)), CGRect(x: 100, y: 40, width: 80, height: 40),
                                    rotation: 30)
        var line = try lineLayer("Line", from: CGPoint(x: 20, y: 150), to: CGPoint(x: 80, y: 150), width: 4, (0, 0, 0))
        line.transform.rotation = 90
        let canvas = CGSize(width: 240, height: 200)
        let plan = try planned(session(240, 200, [quarter, turned, line]))

        #expect(near(try box(try originItem(block(try record("Quarter", in: plan), "vogk"))),
                     CGRect(x: 120, y: 80, width: 20, height: 60)))
        let lineItem = try originItem(block(try record("Line", in: plan), "vogk"))
        #expect(near(try point(lineItem.object("keyOriginLineStart")), CGPoint(x: 50, y: 120), within: 1e-6))
        #expect(near(try point(lineItem.object("keyOriginLineEnd")), CGPoint(x: 50, y: 180), within: 1e-6))

        let written = try record("Turned", in: plan)
        #expect(block(written, "vogk") == nil)
        #expect(written.blocks.map(\.key).prefix(2) == ["SoCo", "vmsk"])
        let expected = PSDFixture.turnedCorners(of: CGRect(x: 100, y: 40, width: 80, height: 40), degrees: 30)
        let found = anchors(try #require(block(written, "vmsk")), canvas: canvas)
        #expect(found.count == 4)
        #expect(expected.allSatisfy { corner in found.contains { near($0, corner, within: 0.001) } })
        #expect(plan.warnings.map(\.layerName).sorted() == ["Line", "Turned"])
        // A turned shape opens in Photoshop as a plain path, no longer a live shape: a lossy change. Flat ends are a note.
        #expect(plan.warnings.first { $0.layerName == "Turned" }?.lossy == true)
        #expect(plan.warnings.first { $0.layerName == "Line" }?.lossy == false)

        let read = try reread(session(240, 200, [quarter, turned, line]))
        #expect(read.layers.first { $0.name == "Turned" }?.shape == nil)
        #expect(read.layers.first { $0.name == "Quarter" }?.shape?.kind == .rectangle)
        #expect(read.layers.first { $0.name == "Quarter" }?.bounds == CGRect(x: 120, y: 80, width: 20, height: 60))
        #expect(read.layers.first { $0.name == "Line" }?.shape?.kind == .line)
    }

    /// A line whose ends meet has no direction to be a Photoshop line in, so it is written as pixels, with a warning.
    @Test func aLineWithoutLengthIsWrittenAsPixels() throws {
        let dot = try lineLayer("Dot", from: CGPoint(x: 20, y: 20), to: CGPoint(x: 20, y: 20), width: 6, (0, 0, 0))
        let plan = try planned(session(40, 40, [dot]))
        let written = try record("Dot", in: plan)
        #expect(!written.blocks.contains { PSDVectorWriter.shapeKeys.contains($0.key) })
        #expect(written.flags & 0x10 == 0)
        #expect(written.image != nil)
        #expect(plan.warnings.map(\.layerName) == ["Dot"])
        // No longer a shape in Photoshop: a lossy change, asked about before saving.
        #expect(plan.warnings.map(\.lossy) == [true])
    }

    // MARK: Shapes kept as pixels

    /// Photoshop's circle (a path Compositor keeps as pixels, with its fill, path and stroke blocks) on its 1920 × 1080
    /// canvas, opened as the app opens a PSD.
    private func openedPixelShape() throws -> EditorSession {
        let canvas = PSDVectorFixtures.canvas
        var record = PSDRecord(id: UUID(), name: "Circle")
        record.bounds = CGRect(x: 800, y: 380, width: 320, height: 320)
        let context = try BrushRaster.context(width: 320, height: 320, mask: false)
        context.setFillColor(CGColor(red: 0, green: 0.43, blue: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 0, y: 0, width: 320, height: 320))
        record.image = context.makeImage()
        record.extras = PSDLayerExtras(blocks: PSDVectorFixtures.circle().sorted { $0.key < $1.key }
            .map { PSDTaggedBlock(key: $0.key, data: $0.value) }, flags: 0x18, importedName: "Circle")
        let document = PSDDocument(width: Int(canvas.width), height: Int(canvas.height), resolution: 72, layers: [record])
        let composite = try BrushRaster.context(width: Int(canvas.width), height: Int(canvas.height), mask: false).makeImage()
        let data = try PSDFixture.data(document, composite: try #require(composite))
        let session = EditorSession()
        try session.insertPhotoshop(try PSDDocumentBuilder.makeImport(try PSDReader.read(data)), named: "Fixture")
        #expect(session.document?.layers.first?.liveShape == nil)
        return session
    }

    /// Photoshop draws a shape layer from its fill and vector blocks, which hold canvas fractions: a shape Compositor
    /// keeps as pixels keeps them only while the layer is where import put it, unpainted, on the same canvas. Moved or
    /// painted it is written as its pixels, without them, and the save says so (lossy: the shape goes).
    @Test func aShapeKeptAsPixelsKeepsItsBlocksOnlyWhileTheyStillDescribeIt() throws {
        let session = try openedPixelShape()
        let circle = PSDVectorFixtures.circle()
        func check(_ session: EditorSession, keeps: Bool, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let plan = try planned(session)
            let written = try record("Circle", in: plan)
            if keeps {
                #expect(written.blocks.filter { circle[$0.key] != nil }.map(\.data) == written.blocks.filter { circle[$0.key] != nil }
                    .map { circle[$0.key]! }, sourceLocation: sourceLocation)
                #expect(written.blocks.filter { circle[$0.key] != nil }.count == 3, sourceLocation: sourceLocation)
                #expect(written.flags & 0x10 != 0 && plan.warnings.isEmpty, sourceLocation: sourceLocation)
            } else {
                #expect(!written.blocks.contains { PSDVectorWriter.shapeKeys.contains($0.key) }, sourceLocation: sourceLocation)
                #expect(written.flags & 0x10 == 0, sourceLocation: sourceLocation)
                #expect(plan.warnings.map(\.layerName) == ["Circle"] && plan.warnings.map(\.lossy) == [true],
                        sourceLocation: sourceLocation)
            }
        }
        try check(session, keeps: true)
        let id = try #require(session.document?.layers.first?.id)
        session.translateLayers([id], by: CGPoint(x: 300, y: 100))
        try check(session, keeps: false)
        session.translateLayers([id], by: CGPoint(x: -300, y: -100))
        try check(session, keeps: true)

        let painted = try #require(session.document?.layers.first)
        session.document?.layers[0] = painted.replacingPixels(painted.asset, transform: painted.transform, mask: painted.mask)
        try check(session, keeps: false)
    }

    /// The canvas the blocks' fractions are of has to be the document's: after Canvas Size (the layer where it was)
    /// the shape is written as pixels. What import recorded survives a project round trip.
    @Test func aShapeKeptAsPixelsIsWrittenAsPixelsOnAnotherCanvas() async throws {
        let session = try openedPixelShape()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PSDVectorWriterTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Circle.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let reopened = EditorSession()
        reopened.installProject(try await ProjectStore.shared.load(from: url), from: url)
        #expect(try record("Circle", in: try planned(reopened)).blocks.contains { $0.key == "vmsk" })

        let snapshot = try #require(reopened.projectSnapshot())
        let resized = try await CanvasResizer.shared.resize(snapshot, to: CanvasSizeOptions(width: 2000, height: 1080, anchor: 0))
        reopened.applyDocumentSize(resized, actionName: "Canvas Size")
        #expect(reopened.document?.layers.first?.transform.origin == CGPoint(x: 800, y: 380))
        let plan = try planned(reopened)
        #expect(!(try record("Circle", in: plan)).blocks.contains { PSDVectorWriter.shapeKeys.contains($0.key) })
        #expect(plan.warnings.map(\.lossy) == [true])
    }

    // MARK: Import

    /// A shape with both fill blocks takes its color from `SoCo`, the older one.
    @Test func soCoTakesPrecedenceOverVscgOnImport() throws {
        let rect = CGRect(x: 20, y: 30, width: 100, height: 50)
        let extra: [String: Data] = [
            "vogk": PSDFixture.originationBlock([PSDFixture.rectangleOrigination(type: 1, rect: rect)]),
            "vsms": PSDFixture.vectorPathBlock(canvas: Self.photoshopCanvas, subpaths: [PSDFixture.turnedCorners(of: rect, degrees: 0)]),
            "vscg": PSDFixture.vectorContentBlock(red: 0, green: 0, blue: 255),
            "SoCo": try #require(PSDVectorFixtures.circle()["SoCo"]),
        ]
        let live = try #require(try PSDVector.live(extra: extra, canvas: Self.photoshopCanvas))
        #expect(live.style.color == PaletteColor(red: 0, green: 110.0 / 255, blue: 1))
    }
}
