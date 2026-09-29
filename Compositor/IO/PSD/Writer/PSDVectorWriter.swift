import CoreGraphics
import Foundation

/// Writes a live shape layer as a Photoshop vector shape, the inverse of `PSDVector.live` (Adobe's *Photoshop File
/// Formats Specification*, additional layer information `vscg`, `vmsk`, `vogk` and `vstk`). Original implementation.
///
/// A shape is written as Photoshop 2026 writes one (the layouts, key order and value types of shapes Photoshop made
/// itself, `PSDVectorFixtures`): its fill, a solid color; its path, 8.24 fixed-point fractions of the canvas, clockwise;
/// its origination (`vogk`: one upright rectangle, rounded rectangle, ellipse or line, with an identity `Trnf`, box
/// corners and no `keyShapeInvalidated`, so it opens again as the same live shape); and the record flag Photoshop sets
/// on shape layers. As in Photoshop, a shape with a stroke, switched on or off, has its fill in `vscg` and its path in
/// `vsms` beside the stroke's `vstk`, and one without has its fill in `SoCo` and its path in `vmsk`. The layer's box
/// holds the stroke, so the shape is that box inset by the stroke's outset. A line is the band `lineWidth` wide between
/// its ends, flat at both ends where Compositor draws them round, and its stroke is written in the line's color, as
/// Compositor draws it. A shape turned by other than quarter turns has no upright origination: it is written as its
/// turned path alone. A shape with nothing to outline (a line whose ends meet, a box its stroke fills) is written as
/// its pixels.
///
/// A layer the document was opened with keeps its shape blocks byte for byte while it is still the shape import made
/// of them, in the same place. Once it isn't, the shape is written over the file's own blocks, in the layout above: the
/// path in place of its `vmsk` or `vsms` (keeping its flags), a fresh fill and origination, and a changed stroke into
/// its `vstk`, which keeps what Compositor doesn't model (joins, caps, blend). A shape rasterized or painted over in
/// Compositor, or one whose clip the writer applied to its pixels, is pixels: its fill and vector blocks are left out.
///
/// A layer whose shape (or vector mask) import kept only as its blocks, drawing its pixels, keeps them byte for byte
/// while they still describe it: where import put it (`importedShapeFrame`), unpainted, on a canvas the size of the
/// file's (`importedShapeCanvas`), since they hold fractions of that canvas. Otherwise it is written as its pixels.
///
/// An adjustment layer's vector mask (which Photoshop adds while a path is active) confines the adjustment to a place
/// on the file's canvas, whatever its layer box. It is kept byte for byte, with the record's flags, while the canvas
/// is the file's: until Crop, Canvas Size, Trim, Image Size or Flip Canvas, after which it is left out.
nonisolated enum PSDVectorWriter {
    /// A quarter ellipse's or rounded corner's control points lie this fraction of its radius from their anchors,
    /// 4(√2 − 1)/3, as in Photoshop 2026's live ellipses and rounded rectangles.
    static let curveControl: CGFloat = 4 * (2.0.squareRoot() - 1) / 3

    /// The blocks that make a layer a Photoshop shape (or fill) layer.
    static let shapeKeys: Set<String> = ["vscg", "SoCo", "GdFl", "PtFl", "vmsk", "vsms", "vogk", "vowv", "vstk"]

    /// Brings a pixel layer's record in line with its shape, or an adjustment layer's with its canvas (see
    /// `updateVectorMask`). `extras` is the layer's Photoshop data, nil when none is written back; `baked` says the
    /// record's pixels aren't the layer's own (a clip was applied to them), so they, not the shape, are what Photoshop
    /// must draw; `canvasMoved` says the document's canvas isn't the file's (`PSDDocumentExtras.canvasMoved`). Returns
    /// what the file holds differently from the document.
    static func update(_ record: inout PSDLayerRecord, for layer: ProjectLayerRecord, extras: PSDLayerExtras?,
                       canvas: CGSize, canvasMoved: Bool, resolution: Double, baked: Bool) -> [PSDWriteWarning] {
        if layer.adjustment != nil {
            return updateVectorMask(&record, layerName: layer.name, extras: extras, canvas: canvas, canvasMoved: canvasMoved)
        }
        guard let style = layer.shape, !baked else {
            let hasShapeBlocks = record.blocks.contains { shapeKeys.contains($0.key) }
            if extras?.importedShape != nil || layer.shape != nil || baked && hasShapeBlocks {
                writeAsPixels(&record)
            } else if hasShapeBlocks, !isWhereImportPutIt(layer.transform, extras: extras, canvas: canvas) {
                writeAsPixels(&record)
                return [PSDWriteWarning(layerName: layer.name, message: "Its Photoshop shape, which Compositor keeps as pixels, no longer describes the layer (moved, resized, painted or on another canvas since it was opened), so it was saved as pixels without its shape.", lossy: true)]
            }
            return []
        }
        if let extras, isUntouched(style, transform: layer.transform, extras: extras, canvas: canvas) { return [] }
        guard let outline = Outline(style, transform: layer.transform) else {
            writeAsPixels(&record)
            // No longer a shape in Photoshop: a lossy change, agreed to first.
            return [PSDWriteWarning(layerName: layer.name, message: "Its shape has no area for a Photoshop outline (a line whose ends meet, or a shape its stroke covers), so it was saved as pixels.", lossy: true)]
        }
        write(outline, style: style, imported: extras?.importedShape, into: &record.blocks, canvas: canvas,
              resolution: resolution)
        record.flags |= 0x10
        var warnings: [PSDWriteWarning] = []
        if style.kind == .line {
            warnings.append(PSDWriteWarning(layerName: layer.name, message: "Photoshop lines have flat ends, so its round ends are flat in Photoshop."))
        }
        if outline.origination == nil {
            // A plain path in Photoshop, no longer a live shape: a lossy change, agreed to first.
            warnings.append(PSDWriteWarning(layerName: layer.name, message: "Compositor writes live shapes upright only, so this turned shape was saved as a vector path without its shape settings. Photoshop draws it the same; opened again in Compositor, it is pixels.", lossy: true))
        }
        return warnings
    }

    /// An adjustment layer's vector mask (`vmsk` or `vsms`, with any `vogk`), which Compositor keeps without drawing:
    /// its fractions of the file's canvas confine the adjustment in Photoshop wherever the layer's box is, so it stays
    /// byte for byte while the canvas is the file's. After Crop, Canvas Size, Trim, Image Size or Flip Canvas
    /// (`canvasMoved`, or a canvas of another size than import recorded) it would confine the adjustment somewhere
    /// else: it is left out, a lossy change agreed to first. The record's flags stay as they are (an adjustment's 0x10
    /// says it has no pixels, not that it is a shape). Also used for placeholders, which Compositor can't apply. Only
    /// the vector mask's blocks are touched: a fill layer's `SoCo`, `GdFl` or `PtFl` (a `fill:` placeholder, which by
    /// definition has no vector mask) fills whatever canvas it is on, so it stays byte for byte. A layer from a project
    /// saved before import recorded its canvas keeps its mask unless `canvasMoved`.
    static func updateVectorMask(_ record: inout PSDLayerRecord, layerName: String, extras: PSDLayerExtras?,
                                 canvas: CGSize, canvasMoved: Bool) -> [PSDWriteWarning] {
        guard record.blocks.contains(where: { PSDReader.vectorKeys.contains($0.key) }),
              canvasMoved || extras?.importedShapeCanvas.map({ $0 != canvas }) == true else { return [] }
        record.blocks.removeAll { PSDReader.vectorKeys.contains($0.key) }
        return [PSDWriteWarning(layerName: layerName, message: "Its Photoshop vector mask is placed on the canvas the file was opened with, which has been cropped, resized or flipped since, so it was saved without it. Photoshop applies the adjustment without that mask.", lossy: true)]
    }

    /// Whether the layer is still the shape import made of the file's blocks, in the same place: then they describe it.
    private static func isUntouched(_ style: LayerShapeStyle, transform: LayerTransform, extras: PSDLayerExtras,
                                    canvas: CGSize) -> Bool {
        guard extras.importedShape == style, transform.rotation.truncatingRemainder(dividingBy: 360) == 0,
              !transform.flipX, !transform.flipY else { return false }
        // Import reads the last block of each key.
        let blocks = Dictionary(extras.blocks.map { ($0.key, $0.data) }, uniquingKeysWith: { _, last in last })
        guard let file = PSDVector.liveShape(extra: blocks, canvas: canvas) else { return false }
        return file.style == style && file.bounds == CGRect(origin: transform.origin, size: transform.size)
    }

    /// Whether a layer whose shape blocks import kept (drawing its pixels) is still where import put it, unpainted, on
    /// a canvas the size of the file's: then its blocks still describe it.
    private static func isWhereImportPutIt(_ transform: LayerTransform, extras: PSDLayerExtras?, canvas: CGSize) -> Bool {
        guard let extras, let frame = extras.importedShapeFrame, extras.importedShapeCanvas == canvas,
              transform.rotation.truncatingRemainder(dividingBy: 360) == 0, !transform.flipX, !transform.flipY else { return false }
        return CGRect(origin: transform.origin, size: transform.size) == frame
    }

    /// Pixels, whatever the file's blocks said: no fill or vector blocks, and no flag saying Photoshop draws the layer
    /// from them.
    private static func writeAsPixels(_ record: inout PSDLayerRecord) {
        record.blocks.removeAll { shapeKeys.contains($0.key) }
        record.flags &= ~0x10
    }

    // MARK: Geometry

    /// One knot of a path: its anchor and the control points of the curves into and out of it, in document pixels.
    private struct Knot {
        var incoming: CGPoint
        var anchor: CGPoint
        var outgoing: CGPoint

        init(_ incoming: CGPoint, _ anchor: CGPoint, _ outgoing: CGPoint) {
            self.incoming = incoming
            self.anchor = anchor
            self.outgoing = outgoing
        }

        /// A corner, both control points at the anchor.
        init(sharp point: CGPoint) { self.init(point, point, point) }

        func applying(_ transform: CGAffineTransform) -> Knot {
            Knot(incoming.applying(transform), anchor.applying(transform), outgoing.applying(transform))
        }
    }

    /// What Photoshop's origination says of a shape, in document pixels.
    private enum Origination {
        case rectangle(CGRect, radius: CGFloat)
        case ellipse(CGRect)
        /// `corners`: the band's, from the start's left-hand corner (going from start to end) round to its right-hand one.
        case line(start: CGPoint, end: CGPoint, weight: CGFloat, corners: [CGPoint])
    }

    /// A shape as Photoshop outlines it: one closed path, its knots linked (ellipses and rounded rectangles, whose
    /// curves run smoothly on) or not, and its upright origination, nil for a shape turned by other than quarter turns.
    private struct Outline {
        var knots: [Knot]
        var smooth: Bool
        var origination: Origination?

        /// Nil when the shape has nothing to outline.
        init?(_ style: LayerShapeStyle, transform: LayerTransform) {
            let size = transform.size
            guard size.width > 0, size.height > 0 else { return nil }
            // The layer's pixels (drawn at its size) to the document.
            let toDocument = CGAffineTransform(scaleX: 1 / size.width, y: 1 / size.height).concatenating(transform.unitToDocument)
            let outset = style.stroke?.outset ?? 0
            smooth = false
            if style.kind == .line {
                // Where `EditorSession.shapeImage` draws the line's ends: stored as fractions of the box, or (older
                // lines) corner to corner, inset by half the drawn thickness.
                let weight = max(1, style.lineWidth ?? 0)
                let drawn = weight + 2 * outset
                let inset = CGRect(origin: .zero, size: size).insetBy(dx: min(drawn, size.width) / 2, dy: min(drawn, size.height) / 2)
                func end(_ unit: CGPoint?, default point: CGPoint) -> CGPoint {
                    let local = unit.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) } ?? point
                    return PSDVectorWriter.snapped(local.applying(toDocument))
                }
                let start = end(style.start, default: CGPoint(x: inset.minX, y: inset.minY))
                let finish = end(style.end, default: CGPoint(x: inset.maxX, y: inset.maxY))
                let length = hypot(finish.x - start.x, finish.y - start.y)
                guard length > 0, length.isFinite else { return nil }
                // The band `weight` wide between the ends, as Photoshop outlines a line: its box corners run from the
                // start's left-hand corner (going from start to end), and its path from the start's right-hand one.
                let across = CGPoint(x: -(finish.y - start.y) / length * weight / 2, y: (finish.x - start.x) / length * weight / 2)
                let corners = [CGPoint(x: start.x - across.x, y: start.y - across.y), CGPoint(x: finish.x - across.x, y: finish.y - across.y),
                               CGPoint(x: finish.x + across.x, y: finish.y + across.y), CGPoint(x: start.x + across.x, y: start.y + across.y)]
                knots = [corners[3], corners[0], corners[1], corners[2]].map { Knot(sharp: $0) }
                origination = .line(start: start, end: finish, weight: weight, corners: corners)
                return
            }
            // The shape sits inside the stroke's outset, as `EditorSession.shapeImage` draws it.
            let inset = min(outset, size.width / 2, size.height / 2)
            let local = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            guard local.width >= 1, local.height >= 1 else { return nil }
            let radius = style.kind == .rectangle ? min(max(0, style.cornerRadius), local.width / 2, local.height / 2) : 0
            smooth = style.kind == .ellipse || radius > 0
            let quarters = transform.rotation / 90
            guard abs(quarters - quarters.rounded()) < 1e-6 else {
                knots = PSDVectorWriter.knots(style.kind, in: local, radius: radius).map { $0.applying(toDocument) }
                origination = nil
                return
            }
            let corners = [CGPoint(x: local.minX, y: local.minY), CGPoint(x: local.maxX, y: local.maxY)].map { $0.applying(toDocument) }
            let box = PSDVectorWriter.bounds(of: corners.map(PSDVectorWriter.snapped))
            knots = PSDVectorWriter.knots(style.kind, in: box, radius: radius)
            origination = style.kind == .ellipse ? .ellipse(box) : .rectangle(box, radius: radius)
        }
    }

    /// The knots Photoshop gives a shape, clockwise: a rectangle's from its top-left corner (a rounded one's from the
    /// top edge's left end), an ellipse's from its top.
    private static func knots(_ kind: ShapeKind, in box: CGRect, radius: CGFloat) -> [Knot] {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        let (left, top, right, bottom) = (box.minX, box.minY, box.maxX, box.maxY)
        if kind == .ellipse {
            let (x, y) = (box.midX, box.midY)
            let dx = box.width / 2 * curveControl, dy = box.height / 2 * curveControl
            return [Knot(point(x - dx, top), point(x, top), point(x + dx, top)),
                    Knot(point(right, y - dy), point(right, y), point(right, y + dy)),
                    Knot(point(x + dx, bottom), point(x, bottom), point(x - dx, bottom)),
                    Knot(point(left, y + dy), point(left, y), point(left, y - dy))]
        }
        guard radius > 0 else {
            return [point(left, top), point(right, top), point(right, bottom), point(left, bottom)].map { Knot(sharp: $0) }
        }
        let r = radius, c = radius * curveControl
        return [Knot(point(left + r - c, top), point(left + r, top), point(left + r, top)),
                Knot(point(right - r, top), point(right - r, top), point(right - r + c, top)),
                Knot(point(right, top + r - c), point(right, top + r), point(right, top + r)),
                Knot(point(right, bottom - r), point(right, bottom - r), point(right, bottom - r + c)),
                Knot(point(right - r + c, bottom), point(right - r, bottom), point(right - r, bottom)),
                Knot(point(left + r, bottom), point(left + r, bottom), point(left + r - c, bottom)),
                Knot(point(left, bottom - r + c), point(left, bottom - r), point(left, bottom - r)),
                Knot(point(left, top + r), point(left, top + r), point(left, top + r - c))]
    }

    private static func bounds(of points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        let left = xs.min() ?? 0, top = ys.min() ?? 0
        return CGRect(x: left, y: top, width: (xs.max() ?? 0) - left, height: (ys.max() ?? 0) - top)
    }

    /// `point` to 1/65536 px, so arithmetic noise can't move an edge the importer rounds out to whole pixels.
    private static func snapped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x * 65536).rounded() / 65536, y: (point.y * 65536).rounded() / 65536)
    }

    // MARK: Blocks

    /// The blocks laid out as Photoshop 2026 lays out a shape: with a stroke, switched on or off (Compositor's, or a
    /// `vstk` the file has), the fill in `vscg` and the path in `vsms` beside the `vstk`; without any, the fill in
    /// `SoCo` and the path in `vmsk`.
    private static func write(_ outline: Outline, style: LayerShapeStyle, imported: LayerShapeStyle?,
                              into blocks: inout [PSDTaggedBlock], canvas: CGSize, resolution: Double) {
        let stroke = drawnStroke(style)
        let stroked = stroke != nil || blocks.contains { $0.key == "vstk" }

        // Fill, first.
        let fill = PSDDescriptorWriter.block(PSDDescriptor(classID: "null", items: [
            (key: "Clr ", value: rgbc(style.red, style.green, style.blue)),
        ]))
        blocks.removeAll { $0.key == (stroked ? "SoCo" : "vscg") }
        if stroked {
            set("vscg", Data("SoCo".utf8) + fill, in: &blocks, insertingAt: 0)
        } else {
            set("SoCo", fill, in: &blocks, insertingAt: 0)
        }

        // Path: in place of the file's own (keeping its flags other than inverted and disabled), else before the name.
        let path = vectorMask(outline, canvas: canvas)
        let pathKey = stroked ? "vsms" : "vmsk"
        if let first = blocks.firstIndex(where: { $0.key == "vmsk" || $0.key == "vsms" }) {
            let old = Data(blocks[first].data)
            let flags = old.count >= 8 ? old.subdata(in: 4 ..< 8).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } & ~0x05 : 0
            var data = path
            data.replaceSubrange(4 ..< 8, with: [UInt8(flags >> 24), UInt8(flags >> 16 & 0xFF), UInt8(flags >> 8 & 0xFF), UInt8(flags & 0xFF)])
            blocks[first] = PSDTaggedBlock(signature: blocks[first].signature, key: pathKey, data: data)
            let others = blocks.indices.filter { $0 > first && (blocks[$0].key == "vmsk" || blocks[$0].key == "vsms") }
            for index in others.reversed() { blocks.remove(at: index) }
        } else {
            blocks.insert(PSDTaggedBlock(key: pathKey, data: path), at: blocks.firstIndex { $0.key == "luni" } ?? blocks.count)
        }

        // Origination, after the path.
        if let origination = outline.origination {
            let after = blocks.firstIndex { $0.key == pathKey }.map { $0 + 1 } ?? 0
            set("vogk", originationBlock(origination, resolution: resolution), in: &blocks, insertingAt: after)
        } else {
            blocks.removeAll { $0.key == "vogk" }
        }

        // Stroke: rewritten only when it isn't the one import read.
        let existing = blocks.firstIndex { $0.key == "vstk" }
        if existing != nil, let imported, drawnStroke(imported) == stroke { return }
        if let existing, let payload = rewrittenStroke(blocks[existing].data, stroke: stroke) {
            blocks[existing].data = payload
        } else if let stroke {
            let payload = PSDDescriptorWriter.block(strokeStyle(stroke, resolution: resolution))
            set("vstk", payload, in: &blocks, insertingAt: blocks.firstIndex { $0.key == "fxrp" } ?? blocks.count)
        }
    }

    /// The stroke Compositor draws: on a line, one in the line's own color that widens it.
    private static func drawnStroke(_ style: LayerShapeStyle) -> ShapeStroke? {
        guard var stroke = style.stroke else { return nil }
        if style.kind == .line, stroke.enabled, stroke.width > 0 {
            (stroke.red, stroke.green, stroke.blue) = (style.red, style.green, style.blue)
        }
        return stroke
    }

    /// `vmsk`/`vsms`: `u32 3`, `u32` flags (none), the path-fill and initial-fill records, then one closed subpath (its
    /// length record, then a record per knot: incoming, anchor and outgoing points, each `y` then `x`), padded to 4 bytes.
    private static func vectorMask(_ outline: Outline, canvas: CGSize) -> Data {
        var writer = PSDByteWriter()
        writer.u32(3)
        writer.u32(0)
        writer.u16(6)
        writer.bytes(Data(count: 24))
        writer.u16(8)
        writer.bytes(Data(count: 24))
        // Closed subpath: knot count, then Photoshop's operation (1) and the undocumented 1 it writes, then zeros
        // (the origination index is 0).
        writer.u16(0)
        writer.u16(UInt16(outline.knots.count))
        writer.i16(1)
        writer.u16(1)
        writer.bytes(Data(count: 18))
        for knot in outline.knots {
            writer.u16(outline.smooth ? 1 : 2)
            for point in [knot.incoming, knot.anchor, knot.outgoing] {
                writer.i32(fixed(point.y, of: canvas.height))
                writer.i32(fixed(point.x, of: canvas.width))
            }
        }
        writer.pad(to: 4)
        return writer.data
    }

    /// `value` as an 8.24 fraction of `length`, cut toward zero as Photoshop does.
    private static func fixed(_ value: CGFloat, of length: CGFloat) -> Int32 {
        let scaled = (Double(value) / Double(length) * 0x1000000).rounded(.towardZero)
        guard scaled.isFinite else { return 0 }
        return Int32(min(Double(Int32.max), max(Double(Int32.min), scaled)))
    }

    /// `vogk`: `u32 1` and a descriptor whose `keyDescriptorList` holds the one shape, keyed as Photoshop keys its own:
    /// a box in `#Pxl`, box corners (a rectangle's box, a line's band; none on an ellipse) and points as doubles, and an
    /// identity transform.
    private static func originationBlock(_ origination: Origination, resolution: Double) -> Data {
        func pixels(_ value: CGFloat) -> PSDDescriptorValue { .unitFloat(unit: "#Pxl", value: Double(value)) }
        func point(_ point: CGPoint) -> PSDDescriptorValue {
            .object(PSDDescriptor(classID: "Pnt ", items: [(key: "Hrzn", value: .double(Double(point.x))),
                                                            (key: "Vrtc", value: .double(Double(point.y)))]))
        }
        let type: Int32, box: CGRect, corners: [CGPoint]?
        switch origination {
        case .rectangle(let rect, let radius):
            (type, box) = (radius > 0 ? 2 : 1, rect)
            corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        case .ellipse(let rect):
            (type, box, corners) = (5, rect, nil)
        case .line(_, _, _, let band):
            (type, box, corners) = (4, bounds(of: band), band)
        }
        let identity = zip(["xx", "xy", "yx", "yy", "tx", "ty"], [1.0, 0, 0, 1, 0, 0]).map { key, value in
            (key: PSDKey(key), value: PSDDescriptorValue.double(value))
        }
        let transform = (key: PSDKey("Trnf"), value: PSDDescriptorValue.object(PSDDescriptor(name: "Transform", classID: "Trnf", items: identity)))
        var items: [(key: PSDKey, value: PSDDescriptorValue)] = [
            (key: "keyOriginType", value: .integer(type)),
            (key: "keyOriginResolution", value: .double(resolution)),
        ]
        if case .rectangle(_, let radius) = origination, radius > 0 {
            items.append((key: "keyOriginRRectRadii", value: .object(PSDDescriptor(classID: "radii", items:
                [(key: "unitValueQuadVersion", value: .integer(1))]
                + ["topRight", "topLeft", "bottomLeft", "bottomRight"].map { (key: PSDKey($0), value: pixels(radius)) }))))
        }
        items.append((key: "keyOriginShapeBBox", value: .object(PSDDescriptor(classID: "unitRect", items: [
            (key: "unitValueQuadVersion", value: .integer(1)),
            (key: "Top ", value: pixels(box.minY)), (key: "Left", value: pixels(box.minX)),
            (key: "Btom", value: pixels(box.maxY)), (key: "Rght", value: pixels(box.maxX)),
        ]))))
        // A line's own keys follow its transform, as in Photoshop's lines; arrowheads off, sized in pixels.
        if case .line(let start, let end, let weight, _) = origination {
            items += [
                transform,
                (key: "keyOriginLineEnd", value: point(end)),
                (key: "keyOriginLineStart", value: point(start)),
                (key: "keyOriginLineWeight", value: .double(Double(weight))),
                (key: "keyOriginLineArrowSt", value: .bool(false)),
                (key: "keyOriginLineArrowEnd", value: .bool(false)),
                (key: "keyOriginLineArrWdth", value: .double(Double(weight))),
                (key: "keyOriginLineArrLngth", value: .double(0)),
                (key: "keyOriginLineArrConc", value: .integer(0)),
                (key: "keyOriginLineWidthArrowUnitPixels", value: .bool(true)),
                (key: "keyOriginLineLengthArrowUnitPixels", value: .bool(true)),
            ]
        }
        if let corners {
            items.append((key: "keyOriginBoxCorners", value: .object(PSDDescriptor(classID: "null", items:
                zip(["A", "B", "C", "D"], corners).map { letter, corner in
                    (key: PSDKey("rectangleCorner" + letter), value: point(corner))
                }))))
        }
        if case .line = origination {} else { items.append(transform) }
        items.append((key: "keyOriginIndex", value: .integer(0)))
        let root = PSDDescriptor(classID: "null", items: [
            (key: "keyDescriptorList", value: .list([.object(PSDDescriptor(classID: "null", items: items))])),
        ])
        return padded(PSDDescriptorWriter.block2(root, version: 1))
    }

    /// `vstk`'s `strokeStyle`: Photoshop 2026's 16 keys in its order and its spelling (the blend mode `normal`, where
    /// older files have `Nrml`), a solid stroke `#Pxl` wide (the importer reads the width as pixels whatever its unit).
    private static func strokeStyle(_ stroke: ShapeStroke, resolution: Double) -> PSDDescriptor {
        func enumerated(_ type: String, _ value: String) -> PSDDescriptorValue {
            .enumerated(type: PSDKey(type), value: PSDKey(value))
        }
        return PSDDescriptor(classID: "strokeStyle", items: [
            (key: "strokeStyleVersion", value: .integer(2)),
            (key: "strokeEnabled", value: .bool(stroke.enabled)),
            (key: "fillEnabled", value: .bool(true)),
            (key: "strokeStyleLineWidth", value: .unitFloat(unit: "#Pxl", value: Double(stroke.width))),
            (key: "strokeStyleLineDashOffset", value: .unitFloat(unit: "#Pnt", value: 0)),
            (key: "strokeStyleMiterLimit", value: .double(100)),
            (key: "strokeStyleLineCapType", value: enumerated("strokeStyleLineCapType", "strokeStyleButtCap")),
            (key: "strokeStyleLineJoinType", value: enumerated("strokeStyleLineJoinType", "strokeStyleMiterJoin")),
            (key: "strokeStyleLineAlignment", value: enumerated("strokeStyleLineAlignment", alignment(stroke))),
            (key: "strokeStyleScaleLock", value: .bool(false)),
            (key: "strokeStyleStrokeAdjust", value: .bool(false)),
            (key: "strokeStyleLineDashSet", value: .list([])),
            (key: "strokeStyleBlendMode", value: enumerated("BlnM", "normal")),
            (key: "strokeStyleOpacity", value: .unitFloat(unit: "#Prc", value: 100)),
            (key: "strokeStyleContent", value: content(stroke)),
            (key: "strokeStyleResolution", value: .double(resolution)),
        ])
    }

    /// The file's `vstk` with Compositor's stroke written into it: on or off, and when there is one, its width,
    /// alignment and color, solid and whole (no dashes, full opacity) as Compositor draws it. Nil when it can't be read.
    private static func rewrittenStroke(_ vstk: Data, stroke: ShapeStroke?) -> Data? {
        var offset = 0
        guard var style = try? PSDDescriptorReader.readBlock(Data(vstk), at: &offset) else { return nil }
        set("strokeEnabled", .bool(stroke?.enabled ?? false), in: &style)
        set("fillEnabled", .bool(true), in: &style)
        if let stroke {
            set("strokeStyleLineWidth", .unitFloat(unit: "#Pxl", value: Double(stroke.width)), in: &style)
            set("strokeStyleLineAlignment", .enumerated(type: "strokeStyleLineAlignment", value: PSDKey(alignment(stroke))), in: &style)
            set("strokeStyleLineDashSet", .list([]), in: &style)
            set("strokeStyleOpacity", .unitFloat(unit: "#Prc", value: 100), in: &style)
            set("strokeStyleContent", content(stroke), in: &style)
        }
        return padded(PSDDescriptorWriter.block(style))
    }

    private static func alignment(_ stroke: ShapeStroke) -> String {
        switch stroke.alignment {
        case .center: "strokeStyleAlignCenter"
        case .inside: "strokeStyleAlignInside"
        case .outside: "strokeStyleAlignOutside"
        }
    }

    private static func content(_ stroke: ShapeStroke) -> PSDDescriptorValue {
        .object(PSDDescriptor(classID: "solidColorLayer", items: [(key: "Clr ", value: rgbc(stroke.red, stroke.green, stroke.blue))]))
    }

    /// An `RGBC` color, components 0–255.
    private static func rgbc(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> PSDDescriptorValue {
        .object(PSDDescriptor(classID: "RGBC", items: [
            (key: "Rd  ", value: .double(Double(red * 255))),
            (key: "Grn ", value: .double(Double(green * 255))),
            (key: "Bl  ", value: .double(Double(blue * 255))),
        ]))
    }

    /// Replaces `key`'s value, or appends it.
    private static func set(_ key: String, _ value: PSDDescriptorValue, in descriptor: inout PSDDescriptor) {
        if let index = descriptor.items.firstIndex(where: { $0.key.id == key }) {
            descriptor.items[index].value = value
        } else {
            descriptor.items.append((key: PSDKey(key), value: value))
        }
    }

    /// Replaces the payload of the first `key` block, or inserts the block at `index`.
    private static func set(_ key: String, _ payload: Data, in blocks: inout [PSDTaggedBlock], insertingAt index: Int) {
        let payload = padded(payload)
        if let existing = blocks.firstIndex(where: { $0.key == key }) {
            blocks[existing].data = payload
        } else {
            blocks.insert(PSDTaggedBlock(key: key, data: payload), at: min(max(0, index), blocks.count))
        }
    }

    /// `data` with zeros to a whole number of 4-byte words, as Photoshop stores these blocks.
    private static func padded(_ data: Data) -> Data {
        data + Data(count: (4 - data.count % 4) % 4)
    }
}
