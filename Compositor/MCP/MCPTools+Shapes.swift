import CoreGraphics
import Foundation
import MCP

// MARK: - Shapes

extension MCPToolRegistry {
    static let shapeTools: [MCPToolEntry] = [
        tool("add_solid_fill", title: "Add solid fill",
             description: "Adds an editable solid-color fill across the whole canvas. It is a live rectangle shape, so set_shape_style can change its color; masks, opacity, blending and effects work as for other layers.",
             properties: [
                 "color": colorSchema("The fill color. Defaults to the foreground color."),
                 "name": MCPSchema.str("Layer name. Defaults to 'Solid Color Fill N'."),
             ],
             effect: .additive(idempotent: false), handler: addSolidFill),
        tool("add_shape", title: "Add shape",
             description: "Adds a live shape layer: a rectangle or ellipse filling rect, or a line from start to end, in color (default the foreground). corner_radius rounds a rectangle, line_width sets a line's thickness, and stroke outlines a rectangle or ellipse, growing the layer's box. Returns the id, transform and shape.",
             properties: [
                 "kind": MCPSchema.enumString("The shape.", ["rectangle", "ellipse", "line"]),
                 "rect": MCPSchema.rect("The box a rectangle or ellipse fills."),
                 "start": MCPSchema.point("A line's start."),
                 "end": MCPSchema.point("A line's end."),
                 "color": colorSchema("The fill color (a line's color). Defaults to the foreground color."),
                 "corner_radius": MCPSchema.num("A rectangle's corner radius.", min: 0, max: maxShapeSize, default: 0),
                 "line_width": MCPSchema.num("A line's thickness.", min: 1, max: maxShapeSize, default: 4),
                 "stroke": strokeSchema,
                 "name": MCPSchema.str("Layer name."),
             ],
             required: ["kind"], effect: .additive(idempotent: false), handler: addShape),
        tool("set_shape_style", title: "Set shape style",
             description: "Changes a live shape layer's color, corner_radius, line_width or stroke (patched; null removes it). The shape keeps its size and place; the layer's box grows or shrinks around a changed stroke.",
             properties: [
                 "layer": MCPSchema.layerSelector("The shape layer"),
                 "color": colorSchema("The fill color (a line's color)."),
                 "corner_radius": MCPSchema.num("A rectangle's corner radius.", min: 0, max: maxShapeSize),
                 "line_width": MCPSchema.num("A line's thickness.", min: 1, max: maxShapeSize),
                 "stroke": MCPSchema.nullable(strokeSchema),
             ],
             required: ["layer"], effect: .additive(idempotent: true), handler: setShapeStyle),
    ]

    /// The largest corner radius or line thickness the shape tools take, as the Shape tool's own fields do.
    static let maxShapeSize: Double = 5000

    // MARK: Handlers

    static func addSolidFill(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let session = ctx.session
        let document = try ctx.editableDocument()
        let color = try ctx.args["color"].map { try colorArgument($0, field: "color", session: session) } ?? session.foregroundColor
        let name = try ctx.args.optionalString("name") ?? nextSolidFillName(in: document)
        let id = try addLayerInOneStep(ctx, document: document, editName: "Solid Color Fill", name: name) {
            try shapeFailures {
                try session.addShapeLayer(.rectangle, rect: CGRect(origin: .zero, size: document.size), color: color,
                                          cornerRadius: 0, lineWidth: 4, ends: nil)
            }
        }
        return try shapeLayerResult(id, ctx)
    }

    private static func nextSolidFillName(in document: CanvasDocument) -> String {
        let names = Set(document.layers.map(\.name))
        var number = 1
        while names.contains("Solid Color Fill \(number)") { number += 1 }
        return "Solid Color Fill \(number)"
    }

    static func addShape(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let kind = try shapeKind(ctx)
        let session = ctx.session
        var rect = CGRect.zero
        var ends: (start: CGPoint, end: CGPoint)?
        if kind == .line {
            if ctx.args.has("rect") { throw MCPToolError.invalidArgument("A line runs from 'start' to 'end'; it takes no 'rect'.") }
            guard let start = ctx.args["start"], let end = ctx.args["end"] else {
                throw MCPToolError.invalidArgument("A line needs 'start' and 'end', each a point {x, y}.")
            }
            ends = (try pointArgument(start, "start"), try pointArgument(end, "end"))
        } else {
            if ctx.args.has("start") || ctx.args.has("end") {
                throw MCPToolError.invalidArgument("'start' and 'end' place a line; a rectangle or ellipse fills 'rect'.")
            }
            guard let value = ctx.args["rect"] else {
                throw MCPToolError.invalidArgument("Missing 'rect': the box {x, y, width, height} the \(kind.rawValue.lowercased()) fills.")
            }
            guard let given = MCPValues.rect(from: value) else {
                throw MCPToolError.invalidArgument("'rect' must be {x, y, width, height} in document pixels.")
            }
            guard given.width >= 1, given.height >= 1 else {
                throw MCPToolError.invalidArgument("'rect' must be at least 1 pixel wide and tall.")
            }
            rect = given
        }
        let color = try ctx.args["color"].map { try colorArgument($0, field: "color", session: session) } ?? session.foregroundColor
        let cornerRadius = try sizeArgument("corner_radius", ctx, kind: kind)
        let lineWidth = try sizeArgument("line_width", ctx, kind: kind)
        let name = try ctx.args.optionalString("name")
        // The stroke is checked before anything is drawn: a style like the one added, with the stroke patched in.
        var drawn = LayerShapeStyle(kind: kind, red: color.red, green: color.green, blue: color.blue,
                                    cornerRadius: CGFloat(cornerRadius ?? 0), lineWidth: kind == .line ? CGFloat(lineWidth ?? 4) : nil)
        if let stroke = ctx.args["stroke"] {
            drawn = try shapeStyle(drawn, patching: ["stroke": try strokePatch(stroke, kind: kind, session: session)])
        }
        let document = try ctx.editableDocument()
        let id = try addLayerInOneStep(ctx, document: document, editName: kind.rawValue, name: name) {
            let id = try shapeFailures {
                try session.addShapeLayer(kind, rect: rect, color: color, cornerRadius: drawn.cornerRadius, lineWidth: drawn.lineWidth ?? 4,
                                          ends: ends)
            }
            if let stroke = drawn.stroke { try shapeFailures { try session.updateShapeStyle(id) { $0.stroke = stroke } } }
            return id
        }
        guard let layer = session.document?.layers.first(where: { $0.id == id }) else {
            throw MCPToolError(.internalError, "Could not add the shape layer.")
        }
        return try shapeLayerResult(id, ctx, fields: ["name": .string(layer.name)])
    }

    static func setShapeStyle(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        try MCPGuards.requireNotPlaceholder(layer)
        guard let shape = layer.liveShape else {
            let hint = layer.shape != nil
                ? "Its pixels were changed after its shape was drawn, so it is pixels now. add_shape adds a new shape."
                : "add_shape adds a shape layer."
            throw MCPToolError(.preconditionFailed, "'\(layer.name)' is not a shape layer.", hint: hint, guard: "is_shape")
        }
        try MCPGuards.requireUnlocked(layer, in: document, .all)
        let kind = shape.style.kind
        // `stroke: null` removes the stroke, so it counts as given.
        guard ["color", "corner_radius", "line_width"].contains(where: ctx.args.has) || ctx.args.values["stroke"] != nil else {
            throw MCPToolError.invalidArgument("Pass what to change: color, corner_radius, line_width or stroke.")
        }
        var patch: [String: Value] = [:]
        if let value = ctx.args["color"] {
            let color = try colorArgument(value, field: "color", session: ctx.session)
            patch["red"] = .double(Double(color.red))
            patch["green"] = .double(Double(color.green))
            patch["blue"] = .double(Double(color.blue))
        }
        if let radius = try sizeArgument("corner_radius", ctx, kind: kind) { patch["corner_radius"] = .double(radius) }
        if let width = try sizeArgument("line_width", ctx, kind: kind) { patch["line_width"] = .double(width) }
        if let stroke = ctx.args.values["stroke"] { patch["stroke"] = try strokePatch(stroke, kind: kind, session: ctx.session) }
        var style = try shapeStyle(shape.style, patching: patch)
        // A line's drawn stroke (an imported one: lines take none here) widens it in the line's own color, which import
        // requires of it, so it follows a new color. One that is off or 0 wide keeps its own, as Photoshop stores it.
        if kind == .line, let stroke = style.stroke, stroke.enabled, stroke.width > 0,
           (style.red, style.green, style.blue) != (shape.style.red, shape.style.green, shape.style.blue) {
            style.stroke?.red = style.red
            style.stroke?.green = style.green
            style.stroke?.blue = style.blue
        }
        try shapeFailures { try ctx.session.updateShapeStyle(layer.id) { $0 = style } }
        return try shapeLayerResult(layer.id, ctx)
    }

    // MARK: Arguments

    private static func shapeKind(_ ctx: MCPCallContext) throws -> ShapeKind {
        let name = try ctx.args.string("kind")
        guard let kind = ShapeKind.allCases.first(where: { normalized($0.rawValue) == normalized(name) }) else {
            throw MCPToolError.invalidArgument("kind must be rectangle, ellipse or line.")
        }
        return kind
    }

    private static func pointArgument(_ value: Value, _ key: String) throws -> CGPoint {
        guard let point = MCPValues.point(from: value) else { throw MCPToolError.invalidArgument("'\(key)' must be a point {x, y}.") }
        return point
    }

    /// `corner_radius` (rectangles, 0–5000) or `line_width` (lines, 1–5000), when given; either on another kind fails.
    private static func sizeArgument(_ key: String, _ ctx: MCPCallContext, kind: ShapeKind) throws -> Double? {
        guard let value = try ctx.args.optionalDouble(key) else { return nil }
        let isRadius = key == "corner_radius"
        guard kind == (isRadius ? .rectangle : .line) else {
            let message = isRadius
                ? "corner_radius rounds a rectangle's corners; \(kind == .line ? "a line" : "an ellipse") has none."
                : "line_width is a line's thickness; a \(kind.rawValue.lowercased()) is outlined with stroke instead."
            throw MCPToolError(.invalidArgument, message, details: ["field": .string(key)])
        }
        try requireArgumentRange(value, (isRadius ? 0 : 1)...maxShapeSize, field: key)
        return value
    }

    /// The `stroke` argument as `decodeMerged` patches a style's stroke: an object of the fields to change, its `color`
    /// taken as `colorArgument` takes one, or null to remove it. Lines take none (null removes an imported line's).
    private static func strokePatch(_ value: Value, kind: ShapeKind, session: EditorSession) throws -> Value {
        if value == .null { return .null }
        guard kind != .line else {
            throw MCPToolError(.invalidArgument, "A line takes no stroke: its thickness is line_width.",
                               hint: "Set line_width to make the line thicker.", details: ["field": .string("stroke")])
        }
        guard var fields = value.objectValue else {
            throw MCPToolError(.invalidArgument, "'stroke' must be an object of the stroke's fields, or null to remove it.",
                               details: ["field": .string("stroke")])
        }
        if let color = fields.removeValue(forKey: "color") {
            if let channel = ["red", "green", "blue"].first(where: { fields[$0] != nil }) {
                throw MCPToolError(.invalidArgument, "'stroke.color' and 'stroke.\(channel)' both set the color; give one of them.",
                                   details: ["field": .string("stroke.color")])
            }
            let rgb = try colorArgument(color, field: "stroke.color", session: session)
            fields["red"] = .double(Double(rgb.red))
            fields["green"] = .double(Double(rgb.green))
            fields["blue"] = .double(Double(rgb.blue))
        }
        return .object(fields)
    }

    /// `current` with `patch` (snake_case fields, as `MCPValues.shapeStyle` reports them) merged in by
    /// `MCPCodable.decodeMerged`. A stroke the patch adds starts from Photoshop's: enabled, 1 pixel, black, inside.
    private static func shapeStyle(_ current: LayerShapeStyle, patching patch: [String: Value]) throws -> LayerShapeStyle {
        var template = current
        template.stroke = ShapeStroke(enabled: true, width: 1, red: 0, green: 0, blue: 0, alignment: .inside)
        return try MCPCodable.decodeMerged(current, .object(patch), template: template)
    }

    // MARK: Results

    /// A shape edit's result: the layer's id, transform and shape, plus `fields`.
    private static func shapeLayerResult(_ id: UUID, _ ctx: MCPCallContext, fields: [String: Value] = [:]) throws -> CallTool.Result {
        guard let layer = ctx.session.document?.layers.first(where: { $0.id == id }), let shape = layer.liveShape else {
            throw MCPToolError(.internalError, "The shape layer is gone.")
        }
        var out = fields
        out["layer_id"] = .string(id.uuidString)
        out["transform"] = MCPValues.transform(layer.transform)
        out["shape"] = MCPValues.shapeStyle(shape.style)
        return ctx.mutated(out)
    }

    /// Runs a shape command, turning its failures into tool errors.
    private static func shapeFailures<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as ShapeLayerError {
            switch error {
            case .notEditable:
                throw MCPToolError(.preconditionFailed, "The document can't be edited right now.",
                                   hint: "Finish or cancel what the app is doing, then retry.", guard: "can_edit_layers")
            case .notShape:
                throw MCPToolError(.preconditionFailed, "That layer is not a live shape.", hint: "add_shape adds one.", guard: "is_shape")
            case .empty, .tooLarge, .outOfBounds:
                throw MCPToolError.invalidArgument(error.localizedDescription)
            }
        } catch ProjectError.invalid {
            throw MCPToolError.invalidArgument("The shape style is outside what Compositor supports.")
        }
    }

    // MARK: Schemas

    private static func colorSchema(_ description: String) -> Value {
        MCPSchema.anyOf([
            MCPSchema.rgbObject,
            MCPSchema.hexColor,
            .object(["type": .string("string"), "enum": .array([.string("foreground"), .string("background")])]),
        ], description: description + " {r, g, b} in 0–1, \"#rrggbb\", \"foreground\" or \"background\".")
    }

    private static var strokeSchema: Value {
        MCPSchema.object([
            "enabled": MCPSchema.bool("Draw it (off keeps its settings)."),
            "width": MCPSchema.num("Width in pixels.", min: 0, max: Double(ShapeStroke.maxWidth)),
            "color": colorSchema("The stroke's color."),
            "alignment": MCPSchema.enumString("Where it lies against the edge.",
                                              ["center", "inside", "outside"]),
        ], description: "Stroke around a rectangle or ellipse; fields left out keep their values (new: 1 px, black, inside).")
    }
}

// MARK: - Patching

nonisolated extension LayerShapeStyle: MCPPatchable {
    static let mcpFieldRanges: [String: ClosedRange<Double>] = [
        "red": 0...1, "green": 0...1, "blue": 0...1,
        "stroke.width": 0...Double(ShapeStroke.maxWidth), "stroke.red": 0...1, "stroke.green": 0...1, "stroke.blue": 0...1,
    ]

    static let mcpEnumMembers: [String: [String]] = [
        "kind": ShapeKind.allCases.map(\.rawValue),
        "stroke.alignment": ShapeStroke.Alignment.allCases.map(\.rawValue),
    ]

    var mcpInvalidReason: String? {
        "A shape's corner_radius must be 0 or more and a line's line_width above 0."
    }
}
