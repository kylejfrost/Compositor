import CoreGraphics
import Foundation
import MCP

// MARK: - Transforms

extension MCPToolRegistry {
    static let transformTools: [MCPToolEntry] = [
        tool("move_layer", title: "Move layer",
             description: "Moves a layer, or a folder with its contents, by dx, dy document pixels; a linked mask moves with it and an unlinked one stays put.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "dx": MCPSchema.num("Horizontal offset."),
                 "dy": MCPSchema.num("Vertical offset."),
             ],
             required: ["layer", "dx", "dy"], effect: .additive(idempotent: false), handler: moveLayer),
        tool("set_layer_transform", title: "Set layer transform",
             description: "Sets a layer's position, size, rotation and flips; omitted fields keep their values. x, y place the unrotated top-left, or with 'anchor' that point, which a new size or angle keeps in place. A folder can only move: x, y place the box around what it shows (returned as bounds). Returns the transform.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "x": MCPSchema.num("x of the anchor point, or of the unrotated top-left."),
                 "y": MCPSchema.num("y of the anchor point, or of the unrotated top-left."),
                 "width": MCPSchema.num("Width in pixels.", min: 1, max: 300_000),
                 "height": MCPSchema.num("Height in pixels.", min: 1, max: 300_000),
                 "rotation": MCPSchema.num("Clockwise degrees."),
                 "flip_x": MCPSchema.bool("Mirror horizontally."),
                 "flip_y": MCPSchema.bool("Mirror vertically."),
                 "anchor": MCPSchema.enumString("The point x, y place, kept in place by a resize or turn.",
                                                anchorNames),
             ],
             required: ["layer"], effect: .additive(idempotent: true), handler: setLayerTransform),
        tool("set_layer_scale", title: "Set layer scale",
             description: "Scales a layer to a percentage of its own pixels (100 is 1:1), keeping its angle and flips. A live shape draws itself again at the new size, so a later percentage starts from there.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "percent": MCPSchema.num("Percent of its pixel size.", min: 1, max: 10_000),
                 "keep_center": MCPSchema.bool("Keep its middle in place (false: its top-left).", default: true),
             ],
             required: ["layer", "percent"], effect: .additive(idempotent: true), handler: setLayerScale),
        tool("scale_layer_to_fit", title: "Scale layer to fit",
             description: "Scales and moves a layer so its upright box fits a rectangle: contain fits inside and cover fills it, keeping the aspect ratio, and stretch fills it exactly. 'anchor' places the result; angle and flips are kept.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "rect": MCPSchema.rect("The rectangle."),
                 "mode": MCPSchema.enumString("How to fit.", ["contain", "cover", "stretch"]),
                 "anchor": MCPSchema.enumString("Where it sits in the rectangle.", anchorNames, default: "center"),
             ],
             required: ["layer", "rect", "mode"], effect: .additive(idempotent: true), handler: scaleLayerToFit),
        tool("rotate_layer", title: "Rotate layer",
             description: "Turns a layer clockwise by 'degrees' (relative, the default) or to that angle, about its middle or 'around'.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "degrees": MCPSchema.num("Clockwise degrees."),
                 "relative": MCPSchema.bool("Add to the current angle.", default: true),
                 "around": MCPSchema.point("Point to turn about (default its middle)."),
             ],
             required: ["layer", "degrees"], effect: .additive(idempotent: false), handler: rotateLayer),
        tool("flip_layer", title: "Flip layers",
             description: "Mirrors layers horizontally or vertically: one about its own middle, several (or a folder's contents) about the middle of their box. Linked masks flip too; only shown layers with pixels flip.",
             properties: [
                 "layers": MCPSchema.layerSelectors("The layers or folders to flip"),
                 "axis": MCPSchema.enumString("Mirror axis.", ["horizontal", "vertical"]),
             ],
             required: ["layers", "axis"], effect: .additive(idempotent: false), handler: flipLayer),
        tool("distort_layer", title: "Distort layer",
             description: "Moves a layer's four corners (top-left, top-right, bottom-right, bottom-left) and resamples its pixels and linked mask into that shape. Text and shape layers become pixels; get_layer_bounds reports the current corners.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "corners": MCPSchema.arr("New corners: top-left, top-right, bottom-right, bottom-left.",
                                          items: MCPSchema.point("A corner."), minItems: 4, maxItems: 4),
             ],
             required: ["layer", "corners"], effect: .destructive(idempotent: false), handler: distortLayer),
        tool("align_layers", title: "Align layers",
             description: "Lines up the same edge or middle of layers with the canvas, the selection or their combined box. Layers are measured by their upright box, or with use_content_bounds by their visible pixels; a folder moves with its contents.",
             properties: [
                 "layers": MCPSchema.layerSelectors("The layers or folders to align"),
                 "edge": MCPSchema.enumString("Edge or middle to line up.", ["left", "center_x", "right", "top", "center_y", "bottom"]),
                 "to": MCPSchema.enumString("What to line up with.", ["selection", "canvas", "layers"]),
                 "use_content_bounds": MCPSchema.bool("Measure visible pixels, not whole boxes.", default: false),
             ],
             required: ["layers", "edge", "to"], effect: .additive(idempotent: true), handler: alignLayers),
        tool("distribute_layers", title: "Distribute layers",
             description: "Spaces three or more layers along an axis, in order of their middles: equal gaps with the first and last fixed, or gaps of 'spacing' pixels from the first.",
             properties: [
                 "layers": MCPSchema.layerSelectors("The layers or folders to distribute (at least three)"),
                 "axis": MCPSchema.enumString("Axis.", ["horizontal", "vertical"]),
                 "spacing": MCPSchema.num("Gap between boxes (default equal gaps)."),
             ],
             required: ["layers", "axis"], effect: .additive(idempotent: true), handler: distributeLayers),
    ]

    // MARK: Moving and placing

    static func moveLayer(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        let dx = try ctx.args.double("dx")
        let dy = try ctx.args.double("dy")
        let session = ctx.session
        try requireUnlocked(layer, withContentsIn: session, .position)
        try requireMovable(layer, by: CGPoint(x: dx, y: dy), in: session)
        session.translateLayers([layer.id], by: CGPoint(x: dx, y: dy))
        let current = session.document?.layers.first { $0.id == layer.id }?.transform ?? layer.transform
        return ctx.mutated(["layer_id": .string(layer.id.uuidString), "transform": MCPValues.transform(current)])
    }

    static func setLayerTransform(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let document = try ctx.editableDocument()
        let target = try ctx.layer(in: document)
        let session = ctx.session
        let x = try ctx.args.optionalDouble("x"), y = try ctx.args.optionalDouble("y")
        let width = try ctx.args.optionalDouble("width"), height = try ctx.args.optionalDouble("height")
        let rotation = try ctx.args.optionalDouble("rotation")
        let flipX = try ctx.args.optionalBool("flip_x"), flipY = try ctx.args.optionalBool("flip_y")
        let anchor = try anchorArgument(ctx)
        try requireUnlocked(target, withContentsIn: session, .position)
        session.commitTransform()
        guard let layer = session.document?.layers.first(where: { $0.id == target.id }) else {
            throw MCPToolError(.notFound, "The layer no longer exists.")
        }
        let old = layer.transform
        var new = old
        if let width { new.size.width = width }
        if let height { new.size.height = height }
        if let rotation { new.rotation = rotation }
        if let flipX { new.flipX = flipX }
        if let flipY { new.flipY = flipY }
        if layer.isGroup {
            guard new.size == old.size, new.rotation == old.rotation, new.flipX == old.flipX, new.flipY == old.flipY else {
                throw MCPToolError.invalidArgument("A folder can only be moved with x and y.",
                                                   hint: "Flip a folder's contents with flip_layer, or transform the layers inside it.")
            }
            return try placeFolder(layer, anchor: anchor ?? .zero, x: x, y: y, ctx)
        }
        if let anchor {
            // The anchor goes to x and y, or stays where it was.
            let from = old.point(anchor)
            new = placing(new, anchor, at: CGPoint(x: x ?? from.x, y: y ?? from.y))
        } else {
            if let x { new.origin.x = x }
            if let y { new.origin.y = y }
        }
        guard new.isValid else { throw MCPToolError.invalidArgument("Transform is invalid: sizes 1–300000, positions within ±1,000,000.") }
        return ctx.mutated(["layer_id": .string(layer.id.uuidString), "transform": applyTransform(layer.id, to: new, session: session)])
    }

    /// Moves a folder, with everything in it, so the point at `unit` of the box around the layers it shows lands on
    /// x and y (a coordinate left out stays where it is). The folder's own transform is only the canvas it was made on,
    /// so it measures nothing; this is the box `align_layers` and `get_layer_bounds` measure a folder by.
    private static func placeFolder(_ folder: ImageLayer, anchor unit: CGPoint, x: Double?, y: Double?,
                                    _ ctx: MCPCallContext) throws -> CallTool.Result {
        let session = ctx.session
        guard let contents = try? session.alignBounds(of: folder.id, contentOnly: false) else {
            // Nothing asked of a folder with nothing to measure is no change at all.
            if x == nil, y == nil {
                return ctx.mutated(["layer_id": .string(folder.id.uuidString), "transform": MCPValues.transform(folder.transform)])
            }
            throw MCPToolError(.preconditionFailed, "'\(folder.name)' shows no layers with pixels, so it has no box to place.",
                               hint: "A folder is placed by the box around the layers shown in it: show or add some first.",
                               guard: "has_pixels")
        }
        let from = CGPoint(x: contents.minX + contents.width * unit.x, y: contents.minY + contents.height * unit.y)
        var offset = CGPoint(x: (x ?? from.x) - from.x, y: (y ?? from.y) - from.y)
        // Less than a millionth of a pixel is rounding from measuring turned layers: placing it again moves nothing.
        if abs(offset.x) < 1e-6, abs(offset.y) < 1e-6 { offset = .zero }
        try requireMovable(folder, by: offset, in: session)
        session.translateLayers([folder.id], by: offset)
        let current = session.document?.layers.first { $0.id == folder.id }?.transform ?? folder.transform
        return ctx.mutated(["layer_id": .string(folder.id.uuidString), "transform": MCPValues.transform(current),
                            "bounds": MCPValues.rect(contents.offsetBy(dx: offset.x, dy: offset.y))])
    }

    // MARK: Scaling

    static func setLayerScale(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let document = try ctx.editableDocument()
        let target = try ctx.layer(in: document)
        let percent = try ctx.args.double("percent")
        guard (1...10_000).contains(percent) else { throw MCPToolError.invalidArgument("percent must be 1–10000.") }
        let keepCenter = try ctx.args.bool("keep_center", default: true)
        let layer = try transformableLayer(target, ctx)
        guard let image = layer.asset?.image else { throw noPixels(layer) }
        let old = layer.transform
        var new = old.scaled(toPercent: percent, pixelSize: CGSize(width: image.width, height: image.height))
        if !keepCenter { new = placing(new, .zero, at: old.point(.zero)) }
        guard new.isValid else { throw MCPToolError.invalidArgument("At that scale the layer would be under 1 or over 300,000 pixels across.") }
        return ctx.mutated(["layer_id": .string(layer.id.uuidString), "transform": applyTransform(layer.id, to: new, session: ctx.session)])
    }

    private enum FitMode { case contain, cover, stretch }

    static func scaleLayerToFit(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let document = try ctx.editableDocument()
        let target = try ctx.layer(in: document)
        guard let value = ctx.args["rect"] else { throw MCPToolError.invalidArgument("Missing 'rect' ({x, y, width, height}).") }
        guard let rect = MCPValues.rect(from: value), rect.width > 0, rect.height > 0 else {
            throw MCPToolError.invalidArgument("rect must be {x, y, width, height} with a positive width and height.")
        }
        let mode: FitMode
        switch normalized(try ctx.args.string("mode")) {
        case "contain", "fit": mode = .contain
        case "cover", "fill": mode = .cover
        case "stretch": mode = .stretch
        default: throw MCPToolError.invalidArgument("mode must be contain, cover or stretch.")
        }
        let anchor = try anchorArgument(ctx) ?? CGPoint(x: 0.5, y: 0.5)
        let layer = try transformableLayer(target, ctx)
        let old = layer.transform
        let box = MCPRender.box(of: old)
        var new = old
        let fitted: CGSize
        switch mode {
        case .contain, .cover:
            let across = rect.width / box.width, down = rect.height / box.height
            let factor = mode == .contain ? min(across, down) : max(across, down)
            new.size = CGSize(width: old.size.width * factor, height: old.size.height * factor)
            fitted = CGSize(width: box.width * factor, height: box.height * factor)
        case .stretch:
            let quarterTurns = old.rotation / 90
            if quarterTurns == quarterTurns.rounded() {
                // Square to the canvas: the sides take the rectangle's, swapped when it lies on its side.
                new.size = quarterTurns.truncatingRemainder(dividingBy: 2) == 0 ? rect.size : CGSize(width: rect.height, height: rect.width)
            } else {
                // At any other angle the layer keeps it and takes the sides whose turned box is the rectangle.
                guard let size = turnedSize(filling: rect.size, radians: old.radians) else {
                    throw cannotStretch(old, into: rect.size)
                }
                new.size = size
            }
            fitted = rect.size
        }
        let center = CGPoint(x: rect.minX + (rect.width - fitted.width) * anchor.x + fitted.width / 2,
                             y: rect.minY + (rect.height - fitted.height) * anchor.y + fitted.height / 2)
        new.origin = CGPoint(x: center.x - new.size.width / 2, y: center.y - new.size.height / 2)
        guard new.isValid else { throw MCPToolError.invalidArgument("Fitted, the layer would be under 1 or over 300,000 pixels across.") }
        return ctx.mutated(["layer_id": .string(layer.id.uuidString), "transform": applyTransform(layer.id, to: new, session: ctx.session)])
    }

    // MARK: Rotating, flipping, distorting

    static func rotateLayer(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let document = try ctx.editableDocument()
        let target = try ctx.layer(in: document)
        let degrees = try ctx.args.double("degrees")
        let relative = try ctx.args.bool("relative", default: true)
        let around = try ctx.args["around"].map { (value: Value) throws -> CGPoint in
            guard let point = MCPValues.point(from: value) else { throw MCPToolError.invalidArgument("around must be {x, y} in document pixels.") }
            return point
        }
        let layer = try transformableLayer(target, ctx)
        let old = layer.transform
        var new = old
        new.rotation = relative ? old.rotation + degrees : degrees
        if let around {
            // The middle swings about the point by the same turn.
            let turn = (new.rotation - old.rotation) * .pi / 180
            let dx = old.center.x - around.x, dy = old.center.y - around.y
            let center = CGPoint(x: around.x + dx * cos(turn) - dy * sin(turn), y: around.y + dx * sin(turn) + dy * cos(turn))
            new.origin = CGPoint(x: center.x - old.size.width / 2, y: center.y - old.size.height / 2)
        }
        guard new.isValid else { throw MCPToolError.invalidArgument("That turn takes the layer beyond ±1,000,000 pixels.") }
        return ctx.mutated(["layer_id": .string(layer.id.uuidString), "transform": applyTransform(layer.id, to: new, session: ctx.session)])
    }

    static func flipLayer(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let document = try ctx.editableDocument()
        let layers = try ctx.layers(in: document)
        let horizontally: Bool
        switch normalized(try ctx.args.string("axis")) {
        case "horizontal": horizontally = true
        case "vertical": horizontally = false
        default: throw MCPToolError.invalidArgument("axis must be horizontal or vertical.")
        }
        let session = ctx.session
        try requireUnlocked(layers, withContentsIn: session, .position)
        // The app flips what is selected; the selection is put back afterwards.
        let selected = session.selectedLayerIDs, active = session.activeLayerID, maskSelected = session.isMaskSelected
        defer {
            session.selectLayers(selected, primary: active)
            if session.activeLayerID == active { session.isMaskSelected = maskSelected }
        }
        session.selectLayers(Set(layers.map(\.id)), primary: layers.last?.id)
        guard session.canTransform else {
            throw MCPToolError(.preconditionFailed, "Nothing there can be flipped: only shown layers with pixels flip.",
                               hint: "Show hidden layers with set_layer_visibility first.", guard: "can_transform")
        }
        let before = Dictionary(document.layers.map { ($0.id, $0.transform) }, uniquingKeysWith: { first, _ in first })
        session.flipLayers(horizontally: horizontally)
        let flipped = (session.document?.layers ?? []).filter { layer in before[layer.id].map { $0 != layer.transform } == true }
        return ctx.mutated(["axis": .string(horizontally ? "horizontal" : "vertical"),
                            "layer_ids": .array(flipped.map { .string($0.id.uuidString) })])
    }

    static func distortLayer(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let document = try ctx.editableDocument()
        let target = try ctx.layer(in: document)
        guard let values = ctx.args["corners"]?.arrayValue, values.count == 4 else {
            throw MCPToolError.invalidArgument("corners must be four {x, y} points: top-left, top-right, bottom-right, bottom-left.")
        }
        let corners = try values.map { (value: Value) throws -> CGPoint in
            guard let point = MCPValues.point(from: value) else { throw MCPToolError.invalidArgument("Each corner must be {x, y} in document pixels.") }
            return point
        }
        guard DistortWarp.isUsable(corners) else {
            throw MCPToolError.invalidArgument("Those corners leave nothing to draw (or lie beyond ±1,000,000 pixels): each half of the shape needs some area.")
        }
        try MCPGuards.requireUnlocked(target, in: document, .pixels)
        let layer = try transformableLayer(target, ctx)
        let session = ctx.session
        let edit = TransformEdit(layerID: layer.id, draft: layer.transform, persistent: false, corners: corners)
        try MCPGuards.captureBrushError(session) { session.commitDistort(edit, corners: corners) }
        guard let result = session.document?.layers.first(where: { $0.id == layer.id }) else {
            throw MCPToolError(.notFound, "The layer no longer exists.")
        }
        return ctx.mutated(["layer_id": .string(layer.id.uuidString), "transform": MCPValues.transform(result.transform)])
    }

    // MARK: Aligning and distributing

    static func alignLayers(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let document = try ctx.editableDocument()
        let layers = try ctx.layers(in: document)
        let name = try ctx.args.string("edge")
        let edges: [AlignEdge] = [.left, .centerX, .right, .top, .centerY, .bottom]
        let aliases: [String: AlignEdge] = ["horizontalcenter": .centerX, "hcenter": .centerX, "verticalcenter": .centerY,
                                            "vcenter": .centerY, "middle": .centerY]
        guard let edge = aliases[normalized(name)] ?? edges.first(where: { normalized($0.rawValue) == normalized(name) }) else {
            throw MCPToolError.invalidArgument("edge must be left, center_x, right, top, center_y or bottom.")
        }
        let to = normalized(try ctx.args.string("to"))
        guard let target = [AlignTarget.selection, .canvas, .layers].first(where: { $0.rawValue == to }) else {
            throw MCPToolError.invalidArgument("to must be selection, canvas or layers.")
        }
        let byContent = try ctx.args.bool("use_content_bounds", default: false)
        let session = ctx.session
        try requireUnlocked(layers, withContentsIn: session, .position)
        try alignFailures { try session.alignLayers(layers.map(\.id), edge, to: target, useContentBounds: byContent) }
        return ctx.mutated(["layers": placements(of: layers, in: session)])
    }

    static func distributeLayers(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let document = try ctx.editableDocument()
        let layers = try ctx.layers(in: document)
        let axis: DistributeAxis
        switch normalized(try ctx.args.string("axis")) {
        case "horizontal": axis = .horizontal
        case "vertical": axis = .vertical
        default: throw MCPToolError.invalidArgument("axis must be horizontal or vertical.")
        }
        let spacing = try ctx.args.optionalDouble("spacing")
        let session = ctx.session
        try requireUnlocked(layers, withContentsIn: session, .position)
        try alignFailures { try session.distributeLayers(layers.map(\.id), axis: axis, spacing: spacing.map { CGFloat($0) }) }
        return ctx.mutated(["layers": placements(of: layers, in: session)])
    }

    // MARK: Helpers

    /// Anchor names, in the order of the 3 × 3 grid they name (row by row from the top-left).
    static let anchorNames = ["top_left", "top", "top_right", "left", "center", "right", "bottom_left", "bottom", "bottom_right"]

    /// The point of a layer's box an anchor name stands for, in unit coordinates (0…1, y down); nil for an unknown name.
    static func anchorUnit(_ name: String) -> CGPoint? {
        let aliases = ["topcenter": 1, "centerleft": 3, "middleleft": 3, "middle": 4, "centerright": 5, "middleright": 5, "bottomcenter": 7]
        let key = normalized(name)
        guard let index = anchorNames.firstIndex(where: { normalized($0) == key }) ?? aliases[key] else { return nil }
        return CGPoint(x: CGFloat(index % 3) / 2, y: CGFloat(index / 3) / 2)
    }

    /// The `anchor` argument as a unit point, or nil when absent.
    private static func anchorArgument(_ ctx: MCPCallContext) throws -> CGPoint? {
        guard let name = try ctx.args.optionalString("anchor") else { return nil }
        guard let unit = anchorUnit(name) else {
            throw MCPToolError.invalidArgument("anchor must be one of \(anchorNames.joined(separator: ", ")).")
        }
        return unit
    }

    /// `transform` moved so the point at `unit` of its box lands on `point`.
    static func placing(_ transform: LayerTransform, _ unit: CGPoint, at point: CGPoint) -> LayerTransform {
        let current = transform.point(unit)
        var result = transform
        result.origin.x += point.x - current.x
        result.origin.y += point.y - current.y
        return result
    }

    /// The layer `target` names, once it may be transformed: it has pixels of its own, isn't a Photoshop placeholder,
    /// and its position isn't locked (by its own lock or a folder's). An opacity edit left open is closed first, so the
    /// transform is an undo step of its own.
    private static func transformableLayer(_ target: ImageLayer, _ ctx: MCPCallContext) throws -> ImageLayer {
        try MCPGuards.requireNotPlaceholder(target)
        try MCPGuards.requirePixels(target)
        try requireUnlocked(target, withContentsIn: ctx.session, .position)
        ctx.session.commitTransform()
        guard let layer = ctx.session.document?.layers.first(where: { $0.id == target.id }) else {
            throw MCPToolError(.notFound, "The layer no longer exists.")
        }
        guard layer.asset != nil else { throw noPixels(layer) }
        return layer
    }

    /// The width and height a layer turned by `radians` needs for its upright box to be exactly `box`: the positive
    /// solution of w·|cos θ| + h·|sin θ| = W and w·|sin θ| + h·|cos θ| = H. Nil when there is none: turned θ, a box is
    /// at most max(|cos θ|, |sin θ|) / min(|cos θ|, |sin θ|) times as long one way as the other, so near 45° only a
    /// box close to square can be filled. At 45° exactly a square box is filled by every w + h = W / cos θ; the sides
    /// are then equal, as they are for a square box at every other angle.
    static func turnedSize(filling box: CGSize, radians: CGFloat) -> CGSize? {
        let c = abs(cos(radians)), s = abs(sin(radians))
        let determinant = c * c - s * s
        guard abs(determinant) >= 1e-9 else {
            guard abs(box.width - box.height) <= 1e-9 * max(box.width, box.height) else { return nil }
            let side = (box.width + box.height) / 2 / (c + s)
            return CGSize(width: side, height: side)
        }
        let width = (box.width * c - box.height * s) / determinant
        let height = (box.height * c - box.width * s) / determinant
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Why a layer at `transform`'s angle can't be stretched to fill a `size` rectangle, with the longest box it can fill.
    private static func cannotStretch(_ transform: LayerTransform, into size: CGSize) -> MCPToolError {
        let c = abs(cos(transform.radians)), s = abs(sin(transform.radians))
        let longest = max(c, s) / max(min(c, s), 1e-12)
        let turned = "Turned \(shortNumber(transform.rotation))°, the layer's upright box "
        let reach = longest < 1 + 1e-6 ? "is always square"
            : "is at most \(shortNumber(longest)) times as long one way as the other"
        return MCPToolError.invalidArgument(
            turned + reach + ", so no width and height make it exactly \(shortNumber(size.width))×\(shortNumber(size.height)).",
            hint: "Use contain or cover, pick a rectangle closer to square, or turn the layer to a multiple of 90° first.")
    }

    /// `value` with at most two decimals and no trailing zeros, for messages.
    private static func shortNumber(_ value: CGFloat) -> String {
        var text = String(format: "%.2f", Double(value))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Fails unless moving `layer`, and everything in it when it is a folder, by `offset` keeps each within
    /// ±1,000,000 pixels (`translateLayers` would otherwise move nothing).
    private static func requireMovable(_ layer: ImageLayer, by offset: CGPoint, in session: EditorSession) throws {
        let moved = session.descendantIDs(of: layer.id).union([layer.id])
        for other in session.document?.layers ?? [] where moved.contains(other.id) {
            var transform = other.transform
            transform.origin.x += offset.x
            transform.origin.y += offset.y
            guard transform.isValid else { throw MCPToolError.invalidArgument("That move takes the layer beyond ±1,000,000 pixels.") }
        }
    }

    private static func noPixels(_ layer: ImageLayer) -> MCPToolError {
        MCPToolError(.preconditionFailed, "'\(layer.name)' has no pixels to transform.",
                     hint: "Paint or fill it first; move_layer moves it (and a folder with its contents) as it is.", guard: "has_pixels")
    }

    /// Runs an align or distribute, turning why it could not into a tool error.
    private static func alignFailures(_ body: () throws -> Void) throws {
        do { try body() } catch let error as AlignError {
            switch error {
            case .noSelection:
                throw MCPToolError(.preconditionFailed, error.localizedDescription,
                                   hint: "Make a selection first, or align to the canvas or the layers.", guard: "selection")
            case .tooFewLayers:
                throw MCPToolError.invalidArgument(error.localizedDescription)
            case .noBounds:
                throw MCPToolError(.preconditionFailed, error.localizedDescription,
                                   hint: "Leave out layers with no pixels, or measure by the whole box (use_content_bounds: false).", guard: "has_pixels")
            case .tooFar:
                throw MCPToolError.invalidArgument(error.localizedDescription,
                                                   hint: "Bring the layers closer to the canvas first, or use a smaller spacing.")
            }
        }
    }

    /// `[{id, name, transform}]` for each of `layers` as they are now.
    private static func placements(of layers: [ImageLayer], in session: EditorSession) -> Value {
        .array(layers.compactMap { layer in
            session.document?.layers.first { $0.id == layer.id }.map { current -> Value in
                .object(["id": .string(current.id.uuidString), "name": .string(current.name), "transform": MCPValues.transform(current.transform)])
            }
        })
    }

    /// Sets one layer's transform as one undo step: the mask placement follows and a live shape draws itself again at
    /// its new size, as the app's transform does. A change under a millionth of a pixel or degree is rounding, and
    /// records nothing.
    static func applyTransform(_ id: UUID, to new: LayerTransform, session: EditorSession) -> Value {
        guard let document = session.document, let index = document.layers.firstIndex(where: { $0.id == id }) else {
            return .null
        }
        let layer = document.layers[index]
        let new = settled(new, from: layer.transform)
        guard layer.transform != new else { return MCPValues.transform(new) }
        session.beginEdit("Transform Layer")
        if let mask = layer.mask {
            session.document?.layers[index].mask?.placement = mask.placement(movingLayer: layer.transform, to: new)
        }
        session.document?.layers[index].transform = new
        session.redrawShape(at: index)
        session.endEdit()
        return MCPValues.transform(new)
    }

    /// `new`, or `old` when they differ by less than a millionth of a pixel or degree.
    private static func settled(_ new: LayerTransform, from old: LayerTransform) -> LayerTransform {
        let pairs = [(new.origin.x, old.origin.x), (new.origin.y, old.origin.y), (new.size.width, old.size.width),
                     (new.size.height, old.size.height), (new.rotation, old.rotation)]
        let same = new.flipX == old.flipX && new.flipY == old.flipY && new.sampling == old.sampling
            && pairs.allSatisfy { abs($0.0 - $0.1) < 1e-6 }
        return same ? old : new
    }
}
