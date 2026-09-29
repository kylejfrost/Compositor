import CoreGraphics
import Foundation

/// Rasterizes Photoshop vector masks (`vmsk`/`vsms`) and maps filled rectangles, ellipses and lines onto live shape
/// layers, from Adobe’s 2019 Photoshop File Formats Specification (additional layer information: `vmsk`, `vogk`,
/// `SoCo`, `vscg`, `vstk`).
nonisolated enum PSDVector {
    struct Raster {
        var image: CGImage
        var bounds: CGRect
    }

    struct Live {
        var style: LayerShapeStyle
        var bounds: CGRect
        var image: CGImage
        var notes: [String]
    }

    /// A shape too large to draw: over 30,000 pixels a side, or more pixels than the document has left. The layer keeps
    /// what Photoshop stored instead.
    struct TooLargeToDraw: Error {}

    /// The shape as a live Compositor shape: a solid fill (`SoCo`, else `vscg`), the one shape `vogk` describes (or,
    /// in files without it, a path that is an axis-aligned box of four sharp corners) and the `vstk` stroke. Nil when
    /// the layer has to stay pixels, which includes a `vogk` shape the layer's path doesn't draw.
    static func live(extra: [String: Data], canvas: CGSize, remainingPixels: Int = DocumentLimits.documentPixelBudget) throws -> Live? {
        guard let shape = liveShape(extra: extra, canvas: canvas),
              let size = try pixelSize(shape.bounds.size, remainingPixels: remainingPixels) else { return nil }
        let bounds = CGRect(origin: shape.bounds.origin, size: CGSize(width: size.width, height: size.height))
        let image = try EditorSession.shapeImage(shape.style, size: bounds.size)
        return Live(style: shape.style, bounds: bounds, image: image, notes: [])
    }

    /// The live shape `live` makes of a layer and the layer's box, without drawing it or checking its size: what the
    /// writer compares a layer with to tell whether the file's shape blocks still describe it.
    static func liveShape(extra: [String: Data], canvas: CGSize) -> (style: LayerShapeStyle, bounds: CGRect)? {
        let strokeStyle = descriptorBlock(extra["vstk"])
        guard strokeStyle?.bool("fillEnabled") ?? true, let fill = fillColor(extra) else { return nil }
        let (stroke, drawable) = shapeStroke(strokeStyle)
        guard drawable else { return nil }
        let pathData = extra["vmsk"] ?? extra["vsms"]
        // A standalone Photoshop Solid Color Fill layer has a `SoCo` block and no vector path: Photoshop paints it
        // across the canvas. Model that as an editable, full-canvas rectangle so it remains visible in Compositor.
        if pathData == nil {
            guard extra["SoCo"] != nil, extra["vogk"] == nil, canvas.width >= 1, canvas.height >= 1 else { return nil }
            let style = LayerShapeStyle(kind: .rectangle, red: fill.r, green: fill.g, blue: fill.b, cornerRadius: 0)
            guard style.isValid else { return nil }
            return (style, CGRect(origin: .zero, size: canvas))
        }
        // An inverted mask fills around its path and a disabled one fills the whole layer: neither is the shape.
        if let pathData, pathData.count >= 8, UInt32(bitPattern: i32(pathData, 4)) & (maskInverted | maskDisabled) != 0 {
            return nil
        }
        // Photoshop's own description decides whenever the layer has one, as long as the path Photoshop draws is that
        // shape: a live shape turned or skewed with Free Transform draws a turned path, while `keyOriginShapeBBox` can
        // only hold an axis-aligned box. Only older files are read from the path alone.
        let origin: Origination
        if let root = originationRoot(extra["vogk"]) {
            guard let described = origination(root), let pathData,
                  draws(described, path: subpaths(from: pathData, canvas: canvas)) else { return nil }
            origin = described
        } else {
            guard let inferred = sharpRect(from: pathData, canvas: canvas) else { return nil }
            origin = inferred
        }
        let outset = stroke?.outset ?? 0
        var box: CGRect
        if let line = origin.line {
            // Photoshop strokes the line's outline; in the line's own color that draws a wider line, in another it
            // is something a Compositor line can't draw.
            if let stroke, stroke.enabled, stroke.width > 0,
               max(abs(stroke.red - fill.r), abs(stroke.green - fill.g), abs(stroke.blue - fill.b)) > 0.5 / 255 {
                return nil
            }
            let thickness = line.weight + 2 * outset
            box = origin.bounds.insetBy(dx: -thickness / 2, dy: -thickness / 2)
        } else {
            box = origin.bounds.insetBy(dx: -outset, dy: -outset)
        }
        box = box.integral
        guard box.origin.x.isFinite, box.origin.y.isFinite else { return nil }
        var style = LayerShapeStyle(kind: origin.kind, red: fill.r, green: fill.g, blue: fill.b,
                                    cornerRadius: origin.cornerRadius, stroke: stroke)
        if let line = origin.line {
            // The ends as fractions of the layer's box, as the Shape tool stores them.
            func unit(_ point: CGPoint) -> CGPoint {
                CGPoint(x: (point.x - box.minX) / box.width, y: (point.y - box.minY) / box.height)
            }
            style.lineWidth = line.weight
            style.start = unit(line.start)
            style.end = unit(line.end)
        }
        // Only a shape Compositor can hold (and save) is live.
        guard style.isValid else { return nil }
        return (style, box)
    }

    /// Why a vector layer `live` leaves as pixels, when there is more to say than that it was rasterized.
    static func rasterNote(extra: [String: Data]) -> String? {
        guard let root = originationRoot(extra["vogk"]), let items = root.list("keyDescriptorList"), items.count == 1,
              case .object(let item) = items[0], item.int("keyOriginType") == 4,
              item.bool("keyOriginLineArrowSt") == true || item.bool("keyOriginLineArrowEnd") == true else { return nil }
        return "Arrowheads on Photoshop lines aren’t supported, so this line was rasterized to pixels. Its shape data is kept."
    }

    static func raster(extra: [String: Data], canvas: CGSize, remainingPixels: Int = DocumentLimits.documentPixelBudget) throws -> Raster? {
        guard let mask = extra["vmsk"] ?? extra["vsms"],
              let path = path(from: mask, canvas: canvas) else { return nil }
        let fill = fillColor(extra)
        let stroke = descriptorBlock(extra["vstk"])
        let fillEnabled = stroke?.bool("fillEnabled") ?? (fill != nil)
        let strokeEnabled = stroke?.bool("strokeEnabled") ?? false
        let strokeColor = stroke?.object("strokeStyleContent").flatMap(color)
        let strokeWidth = stroke?.unit("strokeStyleLineWidth")?.value ?? 1
        guard fillEnabled && fill != nil || strokeEnabled && strokeColor != nil else { return nil }
        guard CGFloat(strokeWidth).isFinite else { return nil }
        if strokeEnabled {
            guard (0...DocumentLimits.maxSideExtent).contains(strokeWidth) else { throw ImageImportError.tooLarge }
        }
        var box = path.boundingBoxOfPath
        if strokeEnabled { box = box.insetBy(dx: -ceil(strokeWidth / 2 + 1), dy: -ceil(strokeWidth / 2 + 1)) }
        box = box.integral
        guard box.origin.x.isFinite, box.origin.y.isFinite else { return nil }
        guard let size = try pixelSize(box.size, remainingPixels: remainingPixels) else { return nil }
        let width = size.width, height = size.height
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.setShouldAntialias(true)
        context.addPath(path)
        if fillEnabled, let fill {
            context.setFillColor(CGColor(red: fill.r, green: fill.g, blue: fill.b, alpha: 1))
            if strokeEnabled, strokeColor != nil { context.fillPath(using: .winding) }
            else { context.drawPath(using: .fill) }
        }
        if strokeEnabled, let strokeColor {
            if fillEnabled { context.addPath(path) }
            context.setStrokeColor(CGColor(red: strokeColor.r, green: strokeColor.g, blue: strokeColor.b, alpha: 1))
            context.setLineWidth(strokeWidth)
            context.setLineJoin(.miter)
            context.setMiterLimit(10)
            context.setLineCap(.butt)
            context.drawPath(using: .stroke)
        }
        guard let image = context.makeImage() else { return nil }
        return Raster(image: image, bounds: CGRect(x: box.minX, y: box.minY, width: CGFloat(width), height: CGFloat(height)))
    }

    /// Rejects sizes that would trap on `Int(...)`, and throws `TooLargeToDraw` past 30,000 px a side or the
    /// remaining-pixel budget.
    private static func pixelSize(_ size: CGSize, remainingPixels: Int) throws -> (width: Int, height: Int)? {
        guard size.width.isFinite, size.height.isFinite else { return nil }
        let maxDimension: CGFloat = DocumentLimits.maxSideExtent
        guard abs(size.width) <= maxDimension, abs(size.height) <= maxDimension else { throw TooLargeToDraw() }
        let budget = min(EditorSession.maxShapePixels, max(0, remainingPixels))
        guard size.width * size.height <= CGFloat(budget) else { throw TooLargeToDraw() }
        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))
        guard width * height <= budget else { throw TooLargeToDraw() }
        return (width, height)
    }

    private struct Origination {
        var kind: ShapeKind
        /// The shape's box; for a line, the box of its two ends.
        var bounds: CGRect
        var cornerRadius: CGFloat = 0
        /// A line's ends in document pixels and its weight (thickness).
        var line: (start: CGPoint, end: CGPoint, weight: CGFloat)? = nil
    }

    /// One subpath of a `vmsk`/`vsms` path: its knots (an anchor with its incoming and outgoing control points) in
    /// document pixels, and whether it closes back to the first.
    private struct Subpath {
        var closed: Bool
        var knots: [(incoming: CGPoint, anchor: CGPoint, outgoing: CGPoint)]
    }

    /// `vmsk`/`vsms` flag bits (after the `u32` version): the path is inverted, or the mask is switched off.
    private static let maskInverted: UInt32 = 1, maskDisabled: UInt32 = 4

    /// How far, in document pixels, the path Photoshop draws may stray from the shape its `vogk` describes.
    private static let pathTolerance: CGFloat = 1

    /// Photoshop's `vogk` origination (`u32 version` + descriptor block), nil when it can't be read.
    private static func originationRoot(_ data: Data?) -> PSDDescriptor? {
        guard let data, data.count >= 4 else { return nil }
        var offset = 4
        return try? PSDDescriptorReader.readBlock(data, at: &offset)
    }

    /// The shape a `vogk` describes: its `keyDescriptorList` must hold exactly one item Photoshop hasn't invalidated
    /// (`keyShapeInvalidated`). `keyOriginType` 1/2 is a rectangle (2 is rounded, with every corner alike), 5 an
    /// ellipse, 4 a line without arrowheads. Anything else stays pixels, however simple its path. A rectangle or
    /// ellipse must also be upright: its `Trnf`, if any, no more than a move — or, for an ellipse or a rectangle with
    /// square corners, a move and a scale along the axes — and its `keyOriginBoxCorners`, if any, the corners of its
    /// `keyOriginShapeBBox`; otherwise the box can't say where Photoshop draws it.
    private static func origination(_ root: PSDDescriptor) -> Origination? {
        guard root.bool("keyShapeInvalidated") != true, let items = root.list("keyDescriptorList"), items.count == 1,
              case .object(let item) = items[0], item.bool("keyShapeInvalidated") != true,
              let type = item.int("keyOriginType") else { return nil }
        let kind: ShapeKind
        switch type {
        case 1, 2: kind = .rectangle
        case 4: return line(item)
        case 5: kind = .ellipse
        default: return nil
        }
        guard let box = item.object("keyOriginShapeBBox"),
              let left = box.unit("Left")?.value,
              let top = box.unit("Top ")?.value,
              let right = box.unit("Rght")?.value,
              let bottom = box.unit("Btom")?.value else { return nil }
        let bounds = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        guard bounds.width >= 1, bounds.height >= 1,
              bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.size.width.isFinite, bounds.size.height.isFinite else { return nil }
        if let corners = item.object("keyOriginBoxCorners") {
            let points = ["rectangleCornerA", "rectangleCornerB", "rectangleCornerC", "rectangleCornerD"]
                .compactMap { pixelPoint(corners.object($0)) }
            guard areCorners(points, of: bounds) else { return nil }
        }
        var origin = Origination(kind: kind, bounds: bounds)
        if kind == .rectangle, let corners = item.object("keyOriginRRectRadii") {
            let keys = ["topLeft", "topRight", "bottomRight", "bottomLeft"]
            let radii = keys.compactMap { corners.unit($0)?.value }
            // A radius that can't be a corner (infinite, not a number, negative) isn't Photoshop's own.
            guard radii.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
            if radii.count == 4 {
                let lo = radii.min() ?? 0, hi = radii.max() ?? 0
                if hi - lo > 0.5 { return nil }
                origin.cornerRadius = CGFloat(hi)
            }
        }
        // Photoshop scaling a live shape with Free Transform updates its box and box corners and records the scale in
        // `Trnf` (seen in real files: a rectangle stretched by under 1%, its box, corners and path all agreeing). An
        // upright box scaled along the axes is still that box, so a square-cornered rectangle or an ellipse stays
        // live; the path check then confirms where it is. Rounded corners stay pixels, since the radii may not have
        // been scaled with the box.
        let transform = item.object("Trnf")
        guard onlyMoves(transform) || origin.cornerRadius == 0 && scalesAlongAxes(transform) else { return nil }
        return origin
    }

    /// A `keyOriginType` 4 line: `keyOriginLineStart`/`End` points and `keyOriginLineWeight`. Arrowheads can't be drawn.
    /// Whether the ends are where Photoshop draws the line is left to the path (`draws`), which pins it down exactly.
    private static func line(_ item: PSDDescriptor) -> Origination? {
        guard item.bool("keyOriginLineArrowSt") != true, item.bool("keyOriginLineArrowEnd") != true,
              let start = pixelPoint(item.object("keyOriginLineStart")),
              let end = pixelPoint(item.object("keyOriginLineEnd")),
              let weight = number(item["keyOriginLineWeight"]), weight.isFinite, weight > 0 else { return nil }
        let bounds = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                            width: abs(end.x - start.x), height: abs(end.y - start.y))
        guard bounds.width.isFinite, bounds.height.isFinite else { return nil }
        return Origination(kind: .line, bounds: bounds, line: (start, end, CGFloat(weight)))
    }

    /// A `Pnt ` descriptor's `Hrzn`/`Vrtc` in document pixels.
    private static func pixelPoint(_ point: PSDDescriptor?) -> CGPoint? {
        guard let point, let x = number(point["Hrzn"]), let y = number(point["Vrtc"]), x.isFinite, y.isFinite else {
            return nil
        }
        return CGPoint(x: x, y: y)
    }

    /// Whether a `vogk` item's `Trnf` (`xx xy yx yy tx ty`) is absent or only moves the shape. A rotation, skew or
    /// flip there is something the axis-aligned `keyOriginShapeBBox` can't show, so that shape stays pixels; a scale
    /// only rounded corners can't follow (see `scalesAlongAxes`). A move is left to the path check, which sees where
    /// the shape really is.
    private static func onlyMoves(_ transform: PSDDescriptor?) -> Bool {
        guard let transform else { return true }
        guard let xx = number(transform["xx"]), let xy = number(transform["xy"]),
              let yx = number(transform["yx"]), let yy = number(transform["yy"]) else { return false }
        let tolerance = 1e-4
        return abs(xx - 1) <= tolerance && abs(yy - 1) <= tolerance && abs(xy) <= tolerance && abs(yx) <= tolerance
    }

    /// Whether a `vogk` item's `Trnf` only moves and scales the shape along the axes, without turning, skewing or
    /// flipping it (both scales positive).
    private static func scalesAlongAxes(_ transform: PSDDescriptor?) -> Bool {
        guard let transform else { return true }
        guard let xx = number(transform["xx"]), let xy = number(transform["xy"]),
              let yx = number(transform["yx"]), let yy = number(transform["yy"]) else { return false }
        let tolerance = 1e-4
        return xx.isFinite && yy.isFinite && xx > tolerance && yy > tolerance && abs(xy) <= tolerance && abs(yx) <= tolerance
    }

    /// Whether `points` are the four corners of `box`, in any order, each within `pathTolerance`.
    private static func areCorners(_ points: [CGPoint], of box: CGRect) -> Bool {
        let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                       CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        func near(_ a: CGPoint, _ b: CGPoint) -> Bool {
            abs(a.x - b.x) <= pathTolerance && abs(a.y - b.y) <= pathTolerance
        }
        return points.count == 4 && corners.allSatisfy { corner in points.contains { near($0, corner) } }
            && points.allSatisfy { point in corners.contains { near(point, $0) } }
    }

    /// Whether the layer's path is the one shape `origin` describes, within `pathTolerance`: a single subpath that
    /// fills the box of a rectangle or ellipse, or for a line one whose every anchor lies on the line (within half its
    /// weight) and which reaches both ends. A shape Photoshop has rotated, reshaped or combined with another path
    /// since drawing it draws something else, and stays pixels.
    private static func draws(_ origin: Origination, path subpaths: [Subpath]) -> Bool {
        guard subpaths.count == 1, let knots = subpaths.first?.knots,
              let bounds = cgPath(subpaths)?.boundingBoxOfPath else { return false }
        guard let line = origin.line else {
            let box = origin.bounds
            return abs(bounds.minX - box.minX) <= pathTolerance && abs(bounds.maxX - box.maxX) <= pathTolerance
                && abs(bounds.minY - box.minY) <= pathTolerance && abs(bounds.maxY - box.maxY) <= pathTolerance
        }
        let reach = line.weight / 2 + pathTolerance
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        /// The distance from `point` to the segment between the line's ends.
        func offLine(_ point: CGPoint) -> CGFloat {
            let dx = line.end.x - line.start.x, dy = line.end.y - line.start.y
            let lengthSquared = dx * dx + dy * dy
            let along = lengthSquared > 0
                ? min(1, max(0, ((point.x - line.start.x) * dx + (point.y - line.start.y) * dy) / lengthSquared)) : 0
            return distance(point, CGPoint(x: line.start.x + along * dx, y: line.start.y + along * dy))
        }
        return origin.bounds.insetBy(dx: -reach, dy: -reach).contains(bounds)
            && knots.allSatisfy { offLine($0.anchor) <= reach }
            && [line.start, line.end].allSatisfy { end in knots.contains { distance($0.anchor, end) <= reach } }
    }

    /// A number however Photoshop stored it: a unit value (pixels), a double or an integer.
    private static func number(_ value: PSDDescriptorValue?) -> Double? {
        switch value {
        case .unitFloat(_, let value)?: value
        case .double(let value)?: value
        case .integer(let value)?: Double(value)
        default: nil
        }
    }

    /// A path of four sharp anchors at the corners of their axis-aligned box, read as a rectangle.
    private static func sharpRect(from data: Data?, canvas: CGSize) -> Origination? {
        guard let data else { return nil }
        let subpaths = subpaths(from: data, canvas: canvas)
        guard subpaths.count == 1, let knots = subpaths.first?.knots, knots.count == 4,
              let box = cgPath(subpaths)?.boundingBoxOfPath else { return nil }
        let sharp = knots.allSatisfy {
            hypot($0.incoming.x - $0.anchor.x, $0.incoming.y - $0.anchor.y) <= 0.5
                && hypot($0.outgoing.x - $0.anchor.x, $0.outgoing.y - $0.anchor.y) <= 0.5
        }
        guard sharp, box.width >= 1, box.height >= 1, areCorners(knots.map { $0.anchor }, of: box) else { return nil }
        return Origination(kind: .rectangle, bounds: box)
    }

    static func path(from data: Data, canvas: CGSize) -> CGPath? {
        cgPath(subpaths(from: data, canvas: canvas))
    }

    /// The subpaths as one path: each knot joined to the next by a cubic through their control points, a closed
    /// subpath back to its first knot the same way.
    private static func cgPath(_ subpaths: [Subpath]) -> CGPath? {
        let path = CGMutablePath()
        for subpath in subpaths {
            guard let first = subpath.knots.first, let last = subpath.knots.last else { continue }
            path.move(to: first.anchor)
            for (previous, knot) in zip(subpath.knots, subpath.knots.dropFirst()) {
                path.addCurve(to: knot.anchor, control1: previous.outgoing, control2: knot.incoming)
            }
            if subpath.closed {
                path.addCurve(to: first.anchor, control1: last.outgoing, control2: first.incoming)
                path.closeSubpath()
            }
        }
        return path.isEmpty ? nil : path
    }

    /// The path records of a `vmsk`/`vsms` payload (`u32` version, `u32` flags, then 26-byte records): each length
    /// record (0 closed, 3 open) starts a subpath that takes that many knot records (1, 2, 4, 5), points scaled from
    /// fractions of the canvas to document pixels. Subpaths without knots are left out.
    private static func subpaths(from data: Data, canvas: CGSize) -> [Subpath] {
        guard data.count >= 8, canvas.width > 0, canvas.height > 0 else { return [] }
        var subpaths: [Subpath] = []
        var offset = 8
        var remaining = 0
        while offset + 26 <= data.count {
            let type = Int(i16(data, offset))
            let body = data.subdata(in: offset + 2 ..< offset + 26)
            offset += 26
            switch type {
            case 0, 3:
                remaining = Int(i16(body, 0))
                subpaths.append(Subpath(closed: type == 0, knots: []))
            case 1, 2, 4, 5:
                guard remaining > 0, !subpaths.isEmpty else { continue }
                remaining -= 1
                subpaths[subpaths.count - 1].knots.append((incoming: point(body, 0, canvas: canvas),
                                                           anchor: point(body, 8, canvas: canvas),
                                                           outgoing: point(body, 16, canvas: canvas)))
            default:
                continue
            }
        }
        return subpaths.filter { !$0.knots.isEmpty }
    }

    /// A `SoCo`-style block (`u32 16` + descriptor) parsed structurally; malformed data is
    /// treated as absent so the layer falls back to its pixels instead of failing the import.
    private static func descriptorBlock(_ data: Data?) -> PSDDescriptor? {
        guard let data else { return nil }
        var offset = 0
        return try? PSDDescriptorReader.readBlock(data, at: &offset)
    }

    /// The shape's fill color as 0…1 components: `Clr` of its `SoCo` solid-color descriptor, else of its `vscg`
    /// (`key(4)` + `u32 16` + descriptor, where Photoshop keeps a shape's fill) when that is a solid color too.
    private static func fillColor(_ extra: [String: Data]) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        if let color = descriptorBlock(extra["SoCo"]).flatMap(color) { return color }
        guard let data = extra["vscg"], data.count >= 8, data.prefix(4).elementsEqual("SoCo".utf8) else { return nil }
        var offset = 4
        return (try? PSDDescriptorReader.readBlock(data, at: &offset)).flatMap(color)
    }

    /// `vstk` as a shape stroke: `stroke` is nil when there is none to keep (no block, or one switched off that isn't
    /// a solid color within 0…500 px). `drawable` is false for an enabled stroke Compositor can't draw as Photoshop
    /// does (not one solid color, dashed, partly transparent, or wider than a shape holds): that shape stays pixels.
    private static func shapeStroke(_ style: PSDDescriptor?) -> (stroke: ShapeStroke?, drawable: Bool) {
        guard let style else { return (nil, true) }
        let enabled = style.bool("strokeEnabled") ?? false
        let alignment: ShapeStroke.Alignment = switch style.enumValue("strokeStyleLineAlignment") {
        case "strokeStyleAlignInside": .inside
        case "strokeStyleAlignOutside": .outside
        default: .center
        }
        var stroke: ShapeStroke?
        if let color = style.object("strokeStyleContent").flatMap(color), let width = style.unit("strokeStyleLineWidth")?.value {
            let candidate = ShapeStroke(enabled: enabled, width: CGFloat(width), red: color.r, green: color.g, blue: color.b,
                                        alignment: alignment)
            if candidate.isValid { stroke = candidate }
        }
        guard enabled else { return (stroke, true) }
        let dashed = !(style.list("strokeStyleLineDashSet") ?? []).isEmpty
        let opaque = abs((style.unit("strokeStyleOpacity")?.value ?? 100) - 100) < 0.5
        return (stroke, stroke != nil && !dashed && opaque)
    }

    /// `Clr` of a solid-color descriptor, as 0…1 components.
    private static func color(_ descriptor: PSDDescriptor) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        guard let rgb = descriptor.rgb("Clr ") else { return nil }
        return (rgb.r / 255, rgb.g / 255, rgb.b / 255)
    }

    private static func point(_ bytes: Data, _ at: Int, canvas: CGSize) -> CGPoint {
        let y = Double(i32(bytes, at)) / 0x1000000
        let x = Double(i32(bytes, at + 4)) / 0x1000000
        return CGPoint(x: x * canvas.width, y: y * canvas.height)
    }

    private static func i32(_ bytes: Data, _ at: Int) -> Int32 {
        var value: Int32 = 0
        _ = withUnsafeMutableBytes(of: &value) { bytes.copyBytes(to: $0, from: at ..< at + 4) }
        return Int32(bigEndian: value)
    }

    private static func i16(_ bytes: Data, _ at: Int) -> Int16 {
        var value: Int16 = 0
        _ = withUnsafeMutableBytes(of: &value) { bytes.copyBytes(to: $0, from: at ..< at + 2) }
        return Int16(bigEndian: value)
    }
}
