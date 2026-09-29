import CoreGraphics
import Foundation
import MCP

// MARK: - Selection

extension MCPToolRegistry {
    static let selectionTools: [MCPToolEntry] = [
        tool("select_rect", title: "Select rectangle",
             description: "Selects a rectangle (Rectangular Marquee), combined with the current selection by mode and clipped to the canvas.",
             properties: [
                 "rect": MCPSchema.rect("The rectangle to select, in document pixels."),
                 "mode": selectionModeSchema,
                 "antialiased": antialiasedSchema,
             ],
             required: ["rect"], effect: .additive(idempotent: false), handler: selectRect),
        tool("select_ellipse", title: "Select ellipse",
             description: "Selects the ellipse filling a rectangle (Elliptical Marquee), combined with the current selection by mode and clipped to the canvas.",
             properties: [
                 "rect": MCPSchema.rect("The rectangle the ellipse fills, in document pixels."),
                 "mode": selectionModeSchema,
                 "antialiased": antialiasedSchema,
             ],
             required: ["rect"], effect: .additive(idempotent: false), handler: selectEllipse),
        tool("select_polygon", title: "Select polygon",
             description: "Selects the polygon through 3 or more points (Polygonal Lasso), combined with the current selection by mode and clipped to the canvas.",
             properties: [
                 "points": MCPSchema.arr("The corners in order, in document pixels; the outline closes itself.",
                                         items: MCPSchema.point("A corner."), minItems: 3, maxItems: maxPolygonPoints),
                 "mode": selectionModeSchema,
                 "antialiased": antialiasedSchema,
             ],
             required: ["points"], effect: .additive(idempotent: false), handler: selectPolygon),
        tool("select_all", title: "Select all",
             description: "Selects the whole canvas.",
             effect: .additive(idempotent: true), handler: selectAll),
        tool("select_none", title: "Deselect",
             description: "Removes the selection, so edits apply to whole layers again.",
             effect: .additive(idempotent: true), handler: selectNone),
        tool("invert_selection", title: "Invert selection",
             description: "Selects everything on the canvas outside the current selection; needs a selection.",
             effect: .additive(idempotent: false), handler: invertSelection),
        tool("select_by_color", title: "Select by color",
             description: "Selects pixels similar in color to the one at (x, y) (Magic Wand), read from the active layer or with sample_all_layers from the composite. The app's Magic Wand settings are left alone.",
             properties: [
                 "x": MCPSchema.num("x of the pixel to match, in document pixels."),
                 "y": MCPSchema.num("y of the pixel to match, in document pixels."),
                 "tolerance": MCPSchema.int("How far each channel may differ.", min: 0, max: 255, default: 32),
                 "contiguous": MCPSchema.bool("Only pixels connected to (x, y).", default: true),
                 "sample_all_layers": MCPSchema.bool("Read the composite, not the active layer.", default: false),
                 "sample_size": MCPSchema.enumString("Area averaged into the sample.", ["point", "3x3", "5x5"], default: "point"),
                 "mode": selectionModeSchema,
             ],
             required: ["x", "y"], effect: .additive(idempotent: false), handler: selectByColor),
        tool("select_object", title: "Select object",
             description: "Selects the object Vision finds under (x, y) (Object Selection); nothing found leaves no selection in replace mode.",
             properties: [
                 "x": MCPSchema.num("x of a point on the object, in document pixels."),
                 "y": MCPSchema.num("y of a point on the object, in document pixels."),
                 "sample_all_layers": MCPSchema.bool("Read the composite, not the active layer.", default: true),
                 "edge_offset": MCPSchema.int("Pixels to shrink (positive) or grow the outline.", min: -10, max: 10, default: 0),
                 "mode": selectionModeSchema,
             ],
             required: ["x", "y"], effect: .additive(idempotent: false), handler: selectObject),
        tool("select_subject", title: "Select subject",
             description: "Selects the main subject Vision finds in the composite; when none is found the selection stays and found is false.",
             properties: ["mode": selectionModeSchema],
             effect: .additive(idempotent: false), handler: selectSubject),
        tool("load_layer_selection", title: "Load layer selection",
             description: "Selects a layer's pixels that are at least 50% opaque, ignoring its mask, or with source mask the white (revealed) areas of its mask.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "source": MCPSchema.enumString("The layer's opaque pixels, or its mask's white areas.", ["pixels", "mask"], default: "pixels"),
                 "mode": selectionModeSchema,
             ],
             required: ["layer"], effect: .additive(idempotent: false), handler: loadLayerSelection),
        tool("modify_selection", title: "Modify selection",
             description: "Expands, contracts or feathers the selection by 'amount' pixels (feather up to 250).",
             properties: [
                 "operation": MCPSchema.enumString("The change.", ["expand", "contract", "feather"]),
                 "amount": MCPSchema.int("Pixels (feather up to 250).", min: 1, max: 500),
             ],
             required: ["operation", "amount"], effect: .additive(idempotent: false), handler: modifySelection),
        tool("transform_selection", title: "Transform selection",
             description: "Scales the selection outline about 'around' (default its center) and moves it by dx, dy; pixels stay put.",
             properties: [
                 "dx": MCPSchema.num("Horizontal offset.", default: 0),
                 "dy": MCPSchema.num("Vertical offset.", default: 0),
                 "scale_x": MCPSchema.num("Horizontal scale.", min: minSelectionScale, max: maxSelectionScale, default: 1),
                 "scale_y": MCPSchema.num("Vertical scale.", min: minSelectionScale, max: maxSelectionScale, default: 1),
                 "around": MCPSchema.point("Fixed point while scaling (default the center)."),
             ],
             effect: .additive(idempotent: false), handler: transformSelection),
        tool("move_selected_pixels", title: "Move selected pixels",
             description: "Moves a layer's selected pixels by whole pixels, leaving transparency behind (or with duplicate a copy), and moves the outline with them.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "dx": MCPSchema.num("Horizontal offset, rounded to whole pixels."),
                 "dy": MCPSchema.num("Vertical offset, rounded to whole pixels."),
                 "duplicate": MCPSchema.bool("Move a copy, keeping the original.", default: false),
             ],
             required: ["layer", "dx", "dy"], effect: .destructive(idempotent: false), handler: moveSelectedPixels),
        tool("get_selection", title: "Get selection",
             description: "Reports the selection: whether it exists or is empty, bounds, feather, antialiasing, and with include_path its outline as SVG path data (up to 256 KiB, then path_truncated).",
             properties: ["include_path": MCPSchema.bool("Also return the outline as SVG path data.", default: false)],
             effect: .readOnly, handler: getSelection),
    ]

    static let maxPolygonPoints = 10_000
    static let minSelectionScale = 0.01
    static let maxSelectionScale = 100.0
    static let maxSelectionOffset = 1_000_000.0

    static let selectionModeSchema = MCPSchema.enumString(
        "How it combines with the current selection.",
        ["replace", "add", "subtract"], default: "replace")

    static let antialiasedSchema = MCPSchema.bool("Smooth edges.", default: true)

    // MARK: Shapes

    static func selectRect(_ ctx: MCPCallContext) throws -> CallTool.Result {
        try select(CGPath(rect: try selectionRect(ctx), transform: nil), name: "Rectangular Marquee", ctx: ctx)
    }

    static func selectEllipse(_ ctx: MCPCallContext) throws -> CallTool.Result {
        try select(CGPath(ellipseIn: try selectionRect(ctx), transform: nil), name: "Elliptical Marquee", ctx: ctx)
    }

    static func selectPolygon(_ ctx: MCPCallContext) throws -> CallTool.Result {
        guard let list = ctx.args["points"]?.arrayValue else {
            throw MCPToolError.invalidArgument("Missing 'points': an array of at least 3 points {x, y}.")
        }
        guard (3...maxPolygonPoints).contains(list.count) else {
            throw MCPToolError.invalidArgument("'points' has \(list.count) points; a polygon takes 3–\(maxPolygonPoints).")
        }
        let points = try list.enumerated().map { index, value in
            guard let point = MCPValues.point(from: value) else {
                throw MCPToolError.invalidArgument("'points[\(index)]' must be a point {x, y} of finite numbers.")
            }
            return point
        }
        guard !collinear(points) else {
            throw MCPToolError.invalidArgument("The points lie on one line, so they enclose no area.",
                                               hint: "Give at least 3 corners that don't all lie on a line.")
        }
        let outline = CGMutablePath()
        outline.addLines(between: points)
        outline.closeSubpath()
        return try select(outline, name: "Polygonal Lasso", ctx: ctx)
    }

    /// Whether every point lies on one line (or on one spot): a polygon through them encloses nothing.
    static func collinear(_ points: [CGPoint]) -> Bool {
        guard let first = points.first, let second = points.first(where: { $0 != first }) else { return true }
        let dx = second.x - first.x, dy = second.y - first.y
        let scale = max(abs(dx), abs(dy))
        return points.allSatisfy { point in
            let cross = dx * (point.y - first.y) - dy * (point.x - first.x)
            return abs(cross) <= 1e-9 * scale * max(scale, abs(point.x - first.x), abs(point.y - first.y))
        }
    }

    /// Combines `shape` with the selection by the call's `mode`, antialiased as its `antialiased` says, in one undo step.
    private static func select(_ shape: CGPath, name: String, ctx: MCPCallContext) throws -> CallTool.Result {
        let mode = try selectionMode(ctx.args)
        let antialiased = try ctx.args.bool("antialiased", default: true)
        let document = try selectionDocument(ctx)
        let overlap = shape.boundingBoxOfPath.intersection(CGRect(origin: .zero, size: document.size))
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else {
            throw MCPToolError.invalidArgument("That shape lies outside the \(document.width)×\(document.height) canvas.",
                                               hint: "Coordinates are document pixels from the top-left corner.")
        }
        ctx.session.applySelection(shape, mode: mode, name: name, antialiased: antialiased)
        return selectionResult(ctx)
    }

    private static func selectionRect(_ ctx: MCPCallContext) throws -> CGRect {
        guard let value = ctx.args["rect"] else {
            throw MCPToolError.invalidArgument("Missing 'rect': {x, y, width, height} in document pixels.")
        }
        guard let rect = MCPValues.rect(from: value), rect.width > 0, rect.height > 0 else {
            throw MCPToolError.invalidArgument("'rect' must be {x, y, width, height} of finite numbers, with a positive width and height.")
        }
        return rect
    }

    // MARK: All, none, inverse

    static func selectAll(_ ctx: MCPCallContext) throws -> CallTool.Result {
        _ = try selectionDocument(ctx)
        ctx.session.selectAll()
        return selectionResult(ctx)
    }

    static func selectNone(_ ctx: MCPCallContext) throws -> CallTool.Result {
        _ = try selectionDocument(ctx)
        ctx.session.deselect()
        return selectionResult(ctx)
    }

    static func invertSelection(_ ctx: MCPCallContext) throws -> CallTool.Result {
        _ = try selectionDocument(ctx)
        guard ctx.session.selection != nil else { throw noSelection("There is no selection to invert.") }
        ctx.session.invertSelection()
        return selectionResult(ctx)
    }

    // MARK: Magic Wand, Object Selection, Subject

    static func selectByColor(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let document = try selectionDocument(ctx)
        let point = try canvasPoint(ctx, in: document)
        var settings = WandSettings()
        settings.tolerance = try ctx.args.int("tolerance", default: 32)
        guard (0...255).contains(settings.tolerance) else {
            throw MCPToolError.invalidArgument("'tolerance' is \(settings.tolerance); it must be 0–255.")
        }
        settings.contiguous = try ctx.args.bool("contiguous", default: true)
        settings.sampleAllLayers = try ctx.args.bool("sample_all_layers", default: false)
        settings.sampleSize = try sampleSize(ctx.args)
        let mode = try selectionMode(ctx.args)
        let session = ctx.session
        try await MCPGuards.captureAsyncBrushError(session) { await session.magicWand(at: point, mode: mode, settings: settings) }
        return selectionResult(ctx)
    }

    static func selectObject(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let document = try selectionDocument(ctx)
        let point = try canvasPoint(ctx, in: document)
        var settings = ObjectSelectionSettings()
        settings.sampleAllLayers = try ctx.args.bool("sample_all_layers", default: true)
        settings.edgeOffset = try ctx.args.int("edge_offset", default: 0)
        guard (-10...10).contains(settings.edgeOffset) else {
            throw MCPToolError.invalidArgument("'edge_offset' is \(settings.edgeOffset); it must be -10–10 (positive shrinks the outline, negative grows it).")
        }
        let mode = try selectionMode(ctx.args)
        let session = ctx.session
        try await MCPGuards.captureAsyncBrushError(session) { await session.selectObject(at: point, mode: mode, settings: settings) }
        return selectionResult(ctx)
    }

    static func selectSubject(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let mode = try selectionMode(ctx.args)
        _ = try selectionDocument(ctx)
        let session = ctx.session
        guard session.canSelectSubject else {
            throw MCPToolError(.preconditionFailed, MCPGuards.blockingReason(session) ?? "Select Subject isn't available right now.",
                               hint: "Commit or cancel what is in progress with settle_pending_edits (or finish it in Compositor), then retry.", guard: "can_select_subject")
        }
        let outcome = try await MCPGuards.captureAsyncBrushError(session) {
            await session.selectSubject(mode: mode, reportingNothingFound: false)
        }
        guard outcome != .failed else {
            throw MCPToolError(.preconditionFailed, MCPGuards.blockingReason(session) ?? "Select Subject couldn't run on this document.",
                               hint: "Retry once the document is idle.", guard: "can_select_subject")
        }
        return selectionResult(ctx, ["found": .bool(outcome == .selected)])
    }

    /// The call's `x`, `y`: a point on the canvas.
    private static func canvasPoint(_ ctx: MCPCallContext, in document: CanvasDocument) throws -> CGPoint {
        let x = try ctx.args.double("x")
        let y = try ctx.args.double("y")
        guard x >= 0, y >= 0, x < Double(document.width), y < Double(document.height) else {
            throw MCPToolError.invalidArgument("(\(x), \(y)) is outside the \(document.width)×\(document.height) canvas.",
                                               hint: "x must be at least 0 and less than the width, y at least 0 and less than the height.")
        }
        return CGPoint(x: x, y: y)
    }

    private static func sampleSize(_ args: Args) throws -> WandSampleSize {
        guard let name = try args.optionalString("sample_size") else { return .point }
        switch normalized(name) {
        case "point", "pointsample": return .point
        case "3x3", "3by3", "3by3average": return .threeByThree
        case "5x5", "5by5", "5by5average": return .fiveByFive
        default: throw MCPToolError.invalidArgument("'sample_size' must be point, 3x3 or 5x5.")
        }
    }

    // MARK: Layer and mask loads

    static func loadLayerSelection(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let document = try selectionDocument(ctx)
        let layer = try ctx.layer(in: document)
        let source = normalized(try ctx.args.string("source", default: "pixels"))
        guard source == "pixels" || source == "mask" else { throw MCPToolError.invalidArgument("'source' must be pixels or mask.") }
        let mode = try selectionMode(ctx.args)
        let outline: CGPath
        if source == "mask" {
            // A placeholder keeps its Photoshop mask, and loading it is fine.
            guard layer.mask != nil else {
                throw MCPToolError(.preconditionFailed, "'\(layer.name)' has no layer mask.", hint: "Use source: pixels.", guard: "has_mask")
            }
            // Photoshop's Cmd-click on a mask loads what it reveals.
            guard let traced = layer.maskWhiteAreasOutline() else {
                throw MCPToolError(.preconditionFailed, "The mask of '\(layer.name)' has no white (revealed) areas to select.",
                                   hint: "It hides the whole layer: paint some of it white first, or use source: pixels.",
                                   guard: "mask_white_areas")
            }
            outline = traced
        } else {
            // Named first: import keeps a placeholder without pixels, so the other checks' hints can't help.
            try MCPGuards.requireNotPlaceholder(layer)
            try MCPGuards.requirePixels(layer)
            guard let traced = layer.opaquePixelsOutline() else {
                throw MCPToolError(.preconditionFailed, "'\(layer.name)' has no pixels at least 50% opaque to select.",
                                   hint: "Paint or fill it first, or pick a layer with opaque pixels.", guard: "has_pixels")
            }
            outline = traced
        }
        ctx.session.applySelection(outline, mode: mode, name: source == "mask" ? "Load Mask Selection" : "Load Layer Selection")
        return selectionResult(ctx)
    }

    // MARK: Modify and transform

    static func modifySelection(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let name = try ctx.args.string("operation")
        let operation: EditorSession.SelectionAmountOperation
        switch normalized(name) {
        case "expand": operation = .expand
        case "contract": operation = .contract
        case "feather": operation = .feather
        default: throw MCPToolError.invalidArgument("'operation' must be expand, contract or feather.")
        }
        let amount = try ctx.args.int("amount")
        let limit = operation == .feather ? 250 : 500
        guard (1...limit).contains(amount) else {
            throw MCPToolError.invalidArgument("'amount' is \(amount); to \(normalized(name)) it must be 1–\(limit) pixels.")
        }
        _ = try selectionDocument(ctx)
        _ = try requireSelection(ctx.session)
        switch operation {
        case .expand: ctx.session.expandSelection(by: amount)
        case .contract: ctx.session.contractSelection(by: amount)
        case .feather: ctx.session.featherSelection(by: amount)
        }
        return selectionResult(ctx)
    }

    static func transformSelection(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let dx = try ctx.args.double("dx", default: 0)
        let dy = try ctx.args.double("dy", default: 0)
        guard abs(dx) <= maxSelectionOffset, abs(dy) <= maxSelectionOffset else {
            throw MCPToolError.invalidArgument("'dx' and 'dy' must be within ±1,000,000 pixels.")
        }
        let scaleX = try ctx.args.double("scale_x", default: 1)
        let scaleY = try ctx.args.double("scale_y", default: 1)
        let scales = minSelectionScale...maxSelectionScale
        guard scales.contains(scaleX), scales.contains(scaleY) else {
            throw MCPToolError.invalidArgument("'scale_x' and 'scale_y' must be \(minSelectionScale)–\(Int(maxSelectionScale)); 1 keeps the size.")
        }
        var around: CGPoint?
        if let value = ctx.args["around"] {
            guard let point = MCPValues.point(from: value) else { throw MCPToolError.invalidArgument("'around' must be a point {x, y}.") }
            // Bounded like dx and dy: scaling about a point far enough out moves the outline's bounds past what a
            // double holds, and the result could no longer be encoded.
            guard abs(point.x) <= maxSelectionOffset, abs(point.y) <= maxSelectionOffset else {
                throw MCPToolError.invalidArgument("'around' must be within ±1,000,000 pixels.")
            }
            around = point
        }
        _ = try selectionDocument(ctx)
        let selection = try requireSelection(ctx.session)
        let scaling = scaleX != 1 || scaleY != 1
        guard scaling || dx != 0 || dy != 0 else { return selectionResult(ctx) }
        let bounds = selection.path.boundingBoxOfPath
        let fixed = around ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let affine = CGAffineTransform(translationX: -fixed.x, y: -fixed.y)
            .concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
            .concatenating(CGAffineTransform(translationX: fixed.x + dx, y: fixed.y + dy))
        ctx.session.transformSelectionOutline(affine, name: scaling ? "Transform Selection" : "Move Selection")
        return selectionResult(ctx)
    }

    // MARK: Moving pixels

    static func moveSelectedPixels(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let document = try selectionDocument(ctx)
        let layer = try ctx.layer(in: document)
        let dx = try ctx.args.double("dx").rounded()
        let dy = try ctx.args.double("dy").rounded()
        guard abs(dx) <= maxSelectionOffset, abs(dy) <= maxSelectionOffset else {
            throw MCPToolError.invalidArgument("'dx' and 'dy' must be within ±1,000,000 pixels.")
        }
        let duplicate = try ctx.args.bool("duplicate", default: false)
        let session = ctx.session
        // A placeholder is named first: import keeps one hidden and without pixels, and no other check's hint can help.
        try MCPGuards.requireNotPlaceholder(layer)
        try MCPGuards.requirePixels(layer)
        try MCPGuards.requireUnlocked(layer, in: document, .pixels)
        _ = try requireSelection(session)
        guard layer.asset != nil else {
            throw MCPToolError(.preconditionFailed, "'\(layer.name)' has no pixels to move.",
                               hint: "Paint or fill it first, or pick a layer with pixels.", guard: "has_pixels")
        }
        // The `canPaint` checks that need no layer switch, so they fail before the user's layers are touched.
        guard document.effectiveVisibleIDs.contains(layer.id) else {
            throw MCPToolError(.preconditionFailed, "'\(layer.name)' is hidden, or inside a hidden folder.",
                               hint: "Show it first with set_layer_visibility.", guard: "can_paint")
        }
        // Pixel moves act on the active layer's pixels, so the layer becomes active. When the move then fails, the
        // user's layer selection, mask target and selected effect are put back, so later '@active' calls still act
        // on the layer they did before.
        let before = (selected: session.selectedLayerIDs, active: session.activeLayerID,
                      mask: session.isMaskSelected, effect: session.effectSelection)
        do {
            session.selectLayer(layer.id)
            session.isMaskSelected = false
            guard session.activeLayerID == layer.id, session.canPaint else {
                throw MCPToolError(.preconditionFailed, "'\(layer.name)' can't be edited right now.",
                                   hint: "Commit or cancel what is in progress with settle_pending_edits (or finish it in Compositor), then retry.", guard: "can_paint")
            }
            defer { if session.pixelMove != nil { session.cancelPixelMove() } }
            let moved = try await MCPGuards.captureAsyncBrushError(session) { () async -> Bool in
                guard session.beginPixelMove(duplicate: duplicate) else { return false }
                session.movePixels(by: CGSize(width: dx, height: dy))
                await session.finishPixelMove()
                return true
            }
            guard moved else {
                throw MCPToolError(.preconditionFailed, "None of the pixels of '\(layer.name)' lie inside the selection.",
                                   hint: "Select an area the layer covers (get_layer_bounds shows where it is).", guard: "has_pixels")
            }
        } catch {
            session.selectLayers(before.selected, primary: before.active)
            session.isMaskSelected = before.mask
            session.effectSelection = before.effect
            throw error
        }
        return selectionResult(ctx, ["layer_id": .string(layer.id.uuidString), "dx": .double(dx), "dy": .double(dy)])
    }

    // MARK: Reading

    static func getSelection(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let includePath = try ctx.args.bool("include_path", default: false)
        _ = try ctx.document()
        return ok(MCPValues.selectionState(ctx.session.selection, includePath: includePath).objectValue ?? [:])
    }

    // MARK: Helpers

    /// The call's `mode`: replace (the default, also "new"), add or subtract.
    static func selectionMode(_ args: Args) throws -> SelectionMode {
        guard let name = try args.optionalString("mode") else { return .replace }
        switch normalized(name) {
        case "replace", "new": return .replace
        case "add": return .add
        case "subtract": return .subtract
        default: throw MCPToolError.invalidArgument("'mode' must be replace, add or subtract.")
        }
    }

    /// The tab's document, once its selection may change: layer edits are allowed and no outline is being drawn or
    /// dragged in the app.
    private static func selectionDocument(_ ctx: MCPCallContext) throws -> CanvasDocument {
        let document = try ctx.editableDocument()
        guard ctx.session.lassoDraft == nil, ctx.session.selectionMoveOrigin == nil else {
            throw MCPToolError(.preconditionFailed, "A selection is being drawn or moved in the app.",
                               hint: "Finish it in Compositor, then retry.", guard: "can_edit_selection")
        }
        return document
    }

    /// The session's selection, when it selects something.
    private static func requireSelection(_ session: EditorSession) throws -> DocumentSelection {
        guard let selection = session.selection else { throw noSelection("There is no selection.") }
        guard !selection.isEmpty else { throw noSelection("The selection is empty: it selects nothing.") }
        return selection
    }

    private static func noSelection(_ message: String) -> MCPToolError {
        MCPToolError(.preconditionFailed, message, hint: "Make one first, e.g. with select_rect or select_all.", guard: "selection")
    }

    /// A mutating selection tool's result: `fields`, the resulting `selection`, and the undo entry.
    private static func selectionResult(_ ctx: MCPCallContext, _ fields: [String: Value] = [:]) -> CallTool.Result {
        var out = fields
        out["selection"] = MCPValues.selectionState(ctx.session.selection)
        return ctx.mutated(out)
    }
}
