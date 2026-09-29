import AppKit

nonisolated enum ShapeKind: String, CaseIterable, Codable, Sendable {
    case rectangle = "Rectangle"
    case ellipse = "Ellipse"
    case line = "Line"
    /// The shape filling `rect`. A rectangle's corners round by `cornerRadius`, at most half its shorter
    /// side (so a large radius makes a pill); ellipses ignore it. A line runs corner to corner and is stroked,
    /// not filled (see `linePath`).
    func path(in rect: CGRect, cornerRadius: CGFloat = 0) -> CGPath {
        if self == .ellipse { return CGPath(ellipseIn: rect, transform: nil) }
        let radius = min(max(0, cornerRadius), rect.width / 2, rect.height / 2)
        guard radius > 0 else { return CGPath(rect: rect, transform: nil) }
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}

/// What a shape layer draws, kept so the shape can be drawn again at a new size.
nonisolated struct LayerShapeStyle: Codable, Equatable, Sendable {
    var kind: ShapeKind
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    /// Document pixels, whatever size the shape is scaled to.
    var cornerRadius: CGFloat
    /// A line's thickness, and its two ends as fractions of the layer's box (0–1), so the line lands on exactly the
    /// points it was dragged between and still redraws correctly at another size. Nil on other shapes.
    var lineWidth: CGFloat? = nil
    var start: CGPoint? = nil
    var end: CGPoint? = nil
    /// Photoshop's shape stroke, drawn inside the layer's box: the box is the shape grown by how far the stroke
    /// reaches past its edge (`ShapeStroke.outset`). Nil on shapes without one.
    var stroke: ShapeStroke? = nil
    var color: PaletteColor { PaletteColor(red: red, green: green, blue: blue) }
    /// Colors within 0–1, a corner radius of 0 or more, a line of some thickness (it is drawn at least 1 pixel thick),
    /// line ends at finite places, and a stroke a shape can hold.
    var isValid: Bool {
        [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
            && cornerRadius.isFinite && cornerRadius >= 0
            && (lineWidth.map { $0.isFinite && $0 > 0 } ?? true)
            && [start, end].allSatisfy { point in point.map { $0.x.isFinite && $0.y.isFinite } ?? true }
            && (stroke?.isValid ?? true)
    }
    /// How far the layer's box reaches past the shape itself on every side: the stroke's outset, and on a line half
    /// the thickness it is drawn with as well.
    var boxMargin: CGFloat {
        let outset = stroke?.outset ?? 0
        return kind == .line ? (max(1, lineWidth ?? 0) + 2 * outset) / 2 : outset
    }
    /// Whether drawing the shape again at another size differs from stretching its pixels: a rounded corner, a line's
    /// thickness and a drawn stroke keep their size in document pixels.
    var redrawsWhenScaled: Bool {
        kind == .line || (kind == .rectangle && cornerRadius > 0) || (stroke.map { $0.enabled && $0.width > 0 } ?? false)
    }
}

/// A shape's outline, as Photoshop strokes a shape layer: `width` document pixels of one color, centered on the
/// shape's edge or just inside or outside it. A disabled stroke keeps its settings but isn't drawn. On a line the
/// stroke is the line's own color, so it draws the line wider (import keeps any other line as pixels).
nonisolated struct ShapeStroke: Codable, Equatable, Sendable {
    nonisolated enum Alignment: String, CaseIterable, Codable, Sendable {
        case center, inside, outside
    }
    /// The widest stroke a shape holds, in document pixels.
    static let maxWidth: CGFloat = 500
    var enabled: Bool
    var width: CGFloat
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alignment: Alignment
    var color: PaletteColor { PaletteColor(red: red, green: green, blue: blue) }
    /// How far the drawn stroke reaches past the shape's edge: half its width centered, all of it outside, none inside
    /// or while it is off.
    var outset: CGFloat {
        guard enabled else { return 0 }
        switch alignment {
        case .center: return width / 2
        case .outside: return width
        case .inside: return 0
        }
    }
    var isValid: Bool {
        width.isFinite && (0...Self.maxWidth).contains(width)
            && [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

/// A layer made with the Shape tool. Its pixels are an ordinary raster, so it clips, masks, blends and filters like
/// any layer; `image` is the raster the shape drew. Once anything else changes those pixels (painting, a filter),
/// the layer's image is no longer this one and the layer is plain pixels from then on.
nonisolated struct LayerShape: Equatable, @unchecked Sendable {
    var style: LayerShapeStyle
    let image: CGImage
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.style == rhs.style && lhs.image === rhs.image }
    static func loaded(_ style: LayerShapeStyle?, image: CGImage?) -> LayerShape? {
        guard let style, let image else { return nil }
        return LayerShape(style: style, image: image)
    }
}

extension ImageLayer {
    /// The shape this layer still is: nil once its pixels were edited some other way.
    var liveShape: LayerShape? {
        guard let shape, let image = asset?.image, image === shape.image else { return nil }
        return shape
    }
}

/// Why a shape layer couldn't be added or changed.
nonisolated enum ShapeLayerError: LocalizedError, Equatable {
    /// Layer edits aren't allowed right now: another edit (text being typed, say) holds the document.
    case notEditable
    /// The layer isn't a live shape: not a shape at all, or one whose pixels have been changed since it was drawn.
    case notShape
    /// The shape is less than a pixel wide or tall, so there is nothing to draw.
    case empty
    /// The shape would cover more than `EditorSession.maxShapePixels`.
    case tooLarge
    /// The shape's box lies beyond the limits on a layer's position or size (`LayerTransform.isValid`).
    case outOfBounds

    var errorDescription: String? {
        switch self {
        case .notEditable: "The document can't be edited right now."
        case .notShape: "That layer isn't a live shape."
        case .empty: "That shape is less than a pixel wide or tall."
        case .tooLarge: "That shape is too large. A shape can cover up to \(DocumentLimits.maxSurfaceMegapixels) megapixels."
        case .outOfBounds: "That shape lies beyond the ±1,000,000-pixel limit on a layer's position or the 300,000-pixel limit on its sides."
        }
    }
}

/// A shape being dragged out with the Shape tool, in whole document pixels.
struct ShapeDraft: Equatable {
    let kind: ShapeKind
    let anchor: CGPoint
    var rect: CGRect
    /// Where a line is being dragged to, so its ends stay exactly where they were put.
    var end: CGPoint? = nil
    /// Document pixels, fixed when the drag starts; rectangles only.
    var cornerRadius: CGFloat = 0
}

extension EditorSession {
    /// Pixels one shape layer may hold, the same budget as an import.
    nonisolated static let maxShapePixels = DocumentLimits.maxSurfacePixels

    func beginShape(at point: CGPoint) {
        guard tool == .shape, canEditLayers, point.x.isFinite, point.y.isFinite else { return }
        let anchor = CGPoint(x: point.x.rounded(), y: point.y.rounded())
        shapeDraft = ShapeDraft(kind: shapeKind, anchor: anchor, rect: CGRect(origin: anchor, size: .zero),
                                cornerRadius: shapeKind == .rectangle ? CGFloat(shapeCornerRadius) : 0)
    }

    /// The line being dragged, from where it began to where the pointer is, in document pixels.
    var shapeLineEnds: (start: CGPoint, end: CGPoint)? {
        guard let draft = shapeDraft, draft.kind == .line, let end = draft.end else { return nil }
        return (draft.anchor, end)
    }

    /// Shift makes a square or circle; Option grows the shape from its center, as in Photoshop.
    func dragShape(to point: CGPoint, square: Bool, fromCenter: Bool) {
        guard var draft = shapeDraft, point.x.isFinite, point.y.isFinite else { return }
        // Shift on a line snaps its angle to eighths of a turn — flat, upright, or 45° — rather than squaring a box.
        if draft.kind == .line, square {
            let dx = point.x - draft.anchor.x, dy = point.y - draft.anchor.y
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            let snapped = CGPoint(x: draft.anchor.x + cos(angle) * length, y: draft.anchor.y + sin(angle) * length)
            draft.end = snapped
            draft.rect = DragBox.rect(from: draft.anchor, to: snapped, square: false, fromCenter: fromCenter)
            shapeDraft = draft
            return
        }
        if draft.kind == .line { draft.end = point }
        draft.rect = DragBox.rect(from: draft.anchor, to: point, square: square, fromCenter: fromCenter)
        shapeDraft = draft
    }

    func cancelShape() {
        if shapeDraft != nil { shapeDraft = nil }
    }

    /// Shift-U (and Tab): the Shape tool steps through Rectangle, Ellipse and Line.
    func toggleShapeKind() {
        cancelShape()
        let kinds = ShapeKind.allCases
        shapeKind = kinds[((kinds.firstIndex(of: shapeKind) ?? 0) + 1) % kinds.count]
    }

    /// Fills the dragged shape with the foreground color on a new layer above the active one,
    /// in one undo step. A click without a drag makes nothing; the selection is left alone.
    func finishShape() {
        guard let draft = shapeDraft else { return }
        shapeDraft = nil
        // A line keeps the two points it was dragged between.
        let ends = draft.kind == .line ? (start: draft.anchor, end: draft.end ?? draft.anchor) : nil
        do {
            _ = try addShapeLayer(draft.kind, rect: draft.rect, color: foregroundColor, cornerRadius: draft.cornerRadius,
                                  lineWidth: CGFloat(shapeLineWidth), ends: ends)
        } catch ShapeLayerError.notEditable, ShapeLayerError.empty {
            // Nothing to draw, or nothing may be drawn now.
        } catch { brushError = error.localizedDescription }
    }

    /// Adds a live shape layer in `color` above the active layer (at the top of it when it is a folder), makes it
    /// active and returns its id, as one undo step named after the kind; the selection is left alone. A rectangle or
    /// ellipse fills `rect` (its size rounded to whole pixels); a rectangle's corners round by `cornerRadius`. A line
    /// runs `lineWidth` thick, with round ends, between `ends`, on a layer that is their box with room for that
    /// thickness around them; without `ends` it runs corner to corner of `rect`. The Shape tool's own settings are left
    /// as they are.
    func addShapeLayer(_ kind: ShapeKind, rect: CGRect, color: PaletteColor, cornerRadius: CGFloat, lineWidth: CGFloat,
                       ends: (start: CGPoint, end: CGPoint)?) throws -> UUID {
        guard canEditLayers, document != nil else { throw ShapeLayerError.notEditable }
        let ends = kind == .line ? ends : nil
        var box = rect.standardized
        if let ends {
            let from = ends.start, to = ends.end
            box = CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y))
                .insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        }
        guard box.width >= 1, box.height >= 1 else { throw ShapeLayerError.empty }
        // Whole pixels: a line's box rounds up so its round ends still fit.
        let rule: FloatingPointRoundingRule = kind == .line ? .up : .toNearestOrAwayFromZero
        box.size = CGSize(width: box.width.rounded(rule), height: box.height.rounded(rule))
        guard LayerTransform(origin: box.origin, size: box.size).isValid else { throw ShapeLayerError.outOfBounds }
        guard box.width * box.height <= CGFloat(Self.maxShapePixels) else { throw ShapeLayerError.tooLarge }
        // The ends as fractions of the box, so a scaled line still runs between the same two places.
        func unit(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - box.minX) / box.width, y: (point.y - box.minY) / box.height)
        }
        let style = LayerShapeStyle(kind: kind, red: color.red, green: color.green, blue: color.blue,
                                    cornerRadius: kind == .rectangle ? cornerRadius : 0, lineWidth: kind == .line ? lineWidth : nil,
                                    start: ends.map { unit($0.start) }, end: ends.map { unit($0.end) })
        guard style.isValid else { throw ProjectError.invalid }
        let image = try Self.shapeImage(style, size: box.size)
        let before = activeLayerID
        addPixelLayer(image, at: box.origin, name: nextShapeName(kind), editName: kind.rawValue, dropsSelection: false,
                      shape: LayerShape(style: style, image: image))
        guard let id = activeLayerID, id != before, document?.layers.contains(where: { $0.id == id }) == true else {
            throw ExportError.render
        }
        return id
    }

    /// Changes a live shape layer's style with `change` and draws it again, as one "Edit Shape" undo step (none when
    /// nothing changes). The layer's box reaches past the shape by its `boxMargin` (a stroke's outset, a line's
    /// thickness), so when that changes the box grows or shrinks by as much on every side, around its center: the
    /// shape itself keeps its size and place, a line its ends. Otherwise it is drawn again at its current pixel size.
    /// The Shape tool's own settings are left as they are.
    func updateShapeStyle(_ id: UUID, _ change: (inout LayerShapeStyle) -> Void) throws {
        guard canEditLayers else { throw ShapeLayerError.notEditable }
        guard let index = document?.layers.firstIndex(where: { $0.id == id }), let layer = document?.layers[index],
              let shape = layer.liveShape, let asset = layer.asset else { throw ShapeLayerError.notShape }
        var style = shape.style
        change(&style)
        guard style.isValid else { throw ProjectError.invalid }
        guard style != shape.style else { return }
        var transform = layer.transform
        var size = CGSize(width: shape.image.width, height: shape.image.height)
        let grow = style.boxMargin - shape.style.boxMargin
        if grow != 0 {
            let center = transform.center
            transform.size = CGSize(width: max(1, transform.size.width + 2 * grow), height: max(1, transform.size.height + 2 * grow))
            transform.origin = CGPoint(x: center.x - transform.size.width / 2, y: center.y - transform.size.height / 2)
            size = CGSize(width: max(1, transform.size.width.rounded()), height: max(1, transform.size.height.rounded()))
            // A line's ends stay where they are: as far in from the grown box's edges as they were, plus the growth.
            func moved(_ unit: CGPoint?) -> CGPoint? {
                unit.map { CGPoint(x: ($0.x * layer.transform.size.width + grow) / transform.size.width,
                                   y: ($0.y * layer.transform.size.height + grow) / transform.size.height) }
            }
            style.start = moved(style.start)
            style.end = moved(style.end)
        }
        guard transform.isValid else { throw ShapeLayerError.outOfBounds }
        guard size.width * size.height <= CGFloat(Self.maxShapePixels) else { throw ShapeLayerError.tooLarge }
        let image = try Self.shapeImage(style, size: size)
        let thumbnail = try PixelInvert.thumbnail(of: image)
        finishOpacityEdit()
        beginEdit("Edit Shape")
        // A mask that follows the layer's pixel grid stays exactly where it is while that grid changes.
        if grow != 0, let mask = layer.mask, mask.placement == nil { document?.layers[index].mask?.placement = layer.maskTransform }
        document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
        document?.layers[index].shape = LayerShape(style: style, image: image)
        document?.layers[index].transform = transform
        endEdit()
    }

    /// "Rectangle 1", "Ellipse 2", … skipping names already in the document.
    func nextShapeName(_ kind: ShapeKind) -> String {
        let names = Set(document?.layers.map(\.name) ?? [])
        var number = 1
        while names.contains("\(kind.rawValue) \(number)") { number += 1 }
        return "\(kind.rawValue) \(number)"
    }

    /// A shape layer scaled to a new size draws its shape again at that size, so a rounded corner keeps its radius
    /// instead of stretching. Part of the edit that changed the size.
    func redrawShape(at index: Int) {
        guard let layer = document?.layers[index], let shape = layer.liveShape, let asset = layer.asset else { return }
        let width = max(1, Int(layer.transform.size.width.rounded())), height = max(1, Int(layer.transform.size.height.rounded()))
        guard width != asset.image.width || height != asset.image.height, width * height <= Self.maxShapePixels,
              let image = try? Self.shapeImage(shape.style, size: CGSize(width: width, height: height)),
              let thumbnail = try? PixelInvert.thumbnail(of: image) else { return }
        // A mask that follows the layer's pixel grid stays exactly where it is while that grid changes size.
        if let mask = layer.mask, mask.placement == nil { document?.layers[index].mask?.placement = layer.maskTransform }
        document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
        document?.layers[index].shape = LayerShape(style: shape.style, image: image)
    }

    /// While a shape whose corners, stroke or line keep their size (`redrawsWhenScaled`) is being scaled, the shape drawn
    /// at the size it's being dragged to, so they keep it during the drag rather than only once it's applied. At most
    /// 2048 pixels across (those sizes scale down with it); nil for any other layer, which just stretches until the
    /// redraw at commit.
    func shapeTransformPreview(for layer: ImageLayer, transform: LayerTransform) -> CGImage? {
        guard transformEdit != nil, let shape = layer.liveShape, shape.style.redrawsWhenScaled else {
            if !shapeTransformPreviewCache.isEmpty, transformEdit == nil { shapeTransformPreviewCache = [:] }
            return nil
        }
        let size = transform.size
        guard size.width >= 1, size.height >= 1,
              abs(size.width - CGFloat(shape.image.width)) >= 0.5 || abs(size.height - CGFloat(shape.image.height)) >= 0.5 else { return nil }
        let factor = min(1, 2048 / max(size.width, size.height))
        let drawn = CGSize(width: max(1, (size.width * factor).rounded()), height: max(1, (size.height * factor).rounded()))
        if let cached = shapeTransformPreviewCache[layer.id], cached.size == drawn { return cached.image }
        guard let style = shape.style.scaled(by: factor), let image = try? Self.shapeImage(style, size: drawn) else { return nil }
        shapeTransformPreviewCache[layer.id] = (drawn, image)
        return image
    }

    /// The shape `style` describes, drawn at `size` (the layer's pixel size).
    nonisolated static func shapeImage(_ style: LayerShapeStyle, size: CGSize) throws -> CGImage {
        try shapeImage(style.kind, size: size, color: style.color, cornerRadius: style.cornerRadius,
                       lineWidth: style.lineWidth ?? 0, start: style.start, end: style.end, stroke: style.stroke)
    }

    /// The shape filling its box, anti-aliased where it curves. An enabled `stroke` is drawn within the box too: the
    /// shape sits inset by the stroke's `outset`, with the stroke around it.
    nonisolated static func shapeImage(_ kind: ShapeKind, size: CGSize, color: PaletteColor, cornerRadius: CGFloat = 0,
                           lineWidth: CGFloat = 0, start: CGPoint? = nil, end: CGPoint? = nil,
                           stroke: ShapeStroke? = nil) throws -> CGImage {
        let context = try BrushRaster.context(width: Int(size.width), height: Int(size.height), mask: false)
        let bounds = CGRect(origin: .zero, size: size)
        let outset = stroke?.outset ?? 0
        if kind == .line {
            // Corner to corner, inset by half the thickness so the stroke stays inside the layer. A stroke in the
            // line's color reaches `outset` past each side of it.
            let thickness = max(1, lineWidth) + 2 * outset
            context.setStrokeColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1))
            context.setLineWidth(thickness)
            context.setLineCap(.round)
            // The ends sit where they were dragged, as fractions of the box. Older lines (no ends stored) ran corner
            // to corner, inset by half their thickness.
            let inset = bounds.insetBy(dx: min(thickness, size.width) / 2, dy: min(thickness, size.height) / 2)
            let from = start.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) } ?? CGPoint(x: inset.minX, y: inset.minY)
            let to = end.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) } ?? CGPoint(x: inset.maxX, y: inset.maxY)
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()
            guard let image = context.makeImage() else { throw ExportError.render }
            return image
        }
        let inset = min(outset, size.width / 2, size.height / 2)
        let path = kind.path(in: bounds.insetBy(dx: inset, dy: inset), cornerRadius: cornerRadius)
        let fill = CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        guard let stroke, stroke.enabled, stroke.width > 0 else {
            context.setFillColor(fill)
            context.addPath(path)
            context.fillPath()
            guard let image = context.makeImage() else { throw ExportError.render }
            return image
        }
        // Outside: a doubled stroke under the fill leaves its outer half. Center: the stroke over the fill. Inside: a
        // doubled stroke over the fill, clipped to the shape, leaves its inner half.
        context.setStrokeColor(CGColor(srgbRed: stroke.red, green: stroke.green, blue: stroke.blue, alpha: 1))
        context.setLineWidth(stroke.alignment == .center ? stroke.width : stroke.width * 2)
        context.setLineJoin(.miter)
        context.setFillColor(fill)
        if stroke.alignment == .outside {
            context.addPath(path)
            context.strokePath()
        }
        context.addPath(path)
        context.fillPath()
        if stroke.alignment == .inside {
            context.addPath(path)
            context.clip()
        }
        if stroke.alignment != .outside {
            context.addPath(path)
            context.strokePath()
        }
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }
}
