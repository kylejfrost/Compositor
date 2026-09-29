import AppKit
import Foundation
import MCP

// MARK: - Text and fonts

extension MCPToolRegistry {
    static let textTools: [MCPToolEntry] = [
        tool("add_text_layer", title: "Add text layer",
             description: "Adds a live text layer: point text as big as its text, or paragraph text wrapping in style.box_size, with its box's 'anchor' point at (x, y). The style defaults to 72 px Helvetica in the foreground color; max_width shrinks point text to fit. Returns the id, transform, style and metrics.",
             properties: [
                 "text": MCPSchema.str("The text; \\n breaks lines."),
                 "x": MCPSchema.num("x of the anchor point."),
                 "y": MCPSchema.num("y of the anchor point."),
                 "anchor": MCPSchema.enumString("The point of the text's box placed at (x, y).", anchorNames, default: "top_left"),
                 "style": textStyleSchema(withContent: false),
                 "max_width": MCPSchema.num("Shrink point text to at most this many document pixels wide.", min: 1),
                 "name": MCPSchema.str("Layer name. Defaults to the text's first words."),
             ],
             required: ["text", "x", "y"], effect: .additive(idempotent: false), handler: addTextLayer),
        tool("set_text", title: "Set text",
             description: "Replaces a text layer's text, keeping its style. Point text keeps its anchor (the left end, middle or right end of its first baseline, as aligned); paragraph text keeps its box's top-left.",
             properties: [
                 "layer": MCPSchema.layerSelector("The text layer"),
                 "text": MCPSchema.str("The new text; \\n breaks lines."),
             ],
             required: ["layer", "text"], effect: .additive(idempotent: true), handler: setText),
        tool("set_text_style", title: "Set text style",
             description: "Changes a text layer's style fields, in the form get_layer reports under text: font_name, font_size, color, alignment, tracking, leading, box_size (null makes point text), horizontal_scale, content. Point text keeps its anchor, paragraph text its box's top-left. An unknown or out-of-range field fails naming it.",
             properties: [
                 "layer": MCPSchema.layerSelector("The text layer"),
                 "style": textStyleSchema(withContent: true),
             ],
             required: ["layer", "style"], effect: .additive(idempotent: true), handler: setTextStyle),
        tool("fit_text", title: "Fit text to a width",
             description: "Shrinks a point-text layer's type (never grows it) to the largest size, in 0.1 px steps, whose text is at most max_width document pixels wide. It keeps its anchor; set leading and tracking shrink along. Paragraph text is refused.",
             properties: [
                 "layer": MCPSchema.layerSelector("The text layer"),
                 "max_width": MCPSchema.num("The widest the text may be, in document pixels.", min: 1),
             ],
             required: ["layer", "max_width"], effect: .additive(idempotent: true), handler: fitText),
        tool("get_text_metrics", title: "Get text metrics",
             description: "Measures a text layer, or 'text' in a 'style', as Compositor lays it out. Returns box, text width and height, lines [{text, width, baseline}], line height, ascent, descent, overflows, and the font used (font_available false for a substitute); for a layer, scale and bounds give document pixels.",
             properties: [
                 "layer": MCPSchema.layerSelector("The text layer to measure"),
                 "text": MCPSchema.str("Text to measure instead of a layer."),
                 "style": textStyleSchema(withContent: false),
             ],
             effect: .readOnly, handler: getTextMetrics),
        tool("list_fonts", title: "List fonts",
             description: "Lists installed fonts by family: postscript_name (what font_name takes), family, style, weight and italic, filtered by query; total and truncated say what limit left out.",
             properties: [
                 "query": MCPSchema.str("Text to look for."),
                 "limit": MCPSchema.int("Most fonts to return.", min: 1, max: 5000, default: 200),
             ],
             targetsDocument: false, effect: .readOnly, handler: listFonts),
        tool("check_fonts", title: "Check fonts",
             description: "Checks PostScript font names: whether each is available, or the substitute drawn instead (family_match when from the same family), and lists the document's text layers whose font is missing.",
             properties: [
                 "names": MCPSchema.arr("PostScript names.", items: .object(["type": .string("string")]), minItems: 1, maxItems: 200),
             ],
             effect: .readOnly, handler: checkFonts),
    ]

    // MARK: Handlers

    static func addTextLayer(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let text = try requiredText(ctx)
        let x = try ctx.args.double("x"), y = try ctx.args.double("y")
        let anchorName = try ctx.args.optionalString("anchor") ?? "top_left"
        guard let anchor = anchorUnit(anchorName) else {
            throw MCPToolError.invalidArgument("anchor must be one of \(anchorNames.joined(separator: ", ")).")
        }
        let patch = try styleArgument(ctx)
        let maxWidth = try ctx.args.optionalDouble("max_width")
        if let maxWidth, maxWidth <= 0 { throw MCPToolError.invalidArgument("max_width must be above 0.") }
        let name = try ctx.args.optionalString("name")
        let document = try ctx.editableDocument()
        let session = ctx.session
        var template = LayerTextStyle()
        template.content = text
        let foreground = session.foregroundColor
        template.red = foreground.red; template.green = foreground.green; template.blue = foreground.blue
        var style = try textStyle(template, patching: patch, session: session)
        if let maxWidth {
            guard style.boxSize == nil else {
                throw MCPToolError.invalidArgument("max_width fits point text; paragraph text wraps to its box_size instead.",
                                                   hint: "Leave out box_size, or max_width.")
            }
            style = try textFailures { try EditorSession.fittedTextStyle(style, maxWidth: CGFloat(maxWidth)) }
        }
        let size = EditorSession.textBoxSize(style)
        let origin = CGPoint(x: x - anchor.x * size.width, y: y - anchor.y * size.height)
        guard LayerTransform(origin: origin, size: size).isValid else {
            throw MCPToolError.invalidArgument("That puts the text beyond the ±1,000,000-pixel limit on a layer's position.")
        }
        let id = try addLayerInOneStep(ctx, document: document, editName: "New Text Layer", name: name) {
            try textFailures { try session.addTextLayer(style, at: origin) }
        }
        guard let layer = session.document?.layers.first(where: { $0.id == id }), let live = layer.liveText else {
            throw MCPToolError(.internalError, "Could not add the text layer.")
        }
        return ctx.mutated([
            "layer_id": .string(id.uuidString),
            "name": .string(layer.name),
            "transform": MCPValues.transform(layer.transform),
            "text": MCPValues.textStyle(live.style),
            "metrics": .object(textMetricsFields(live.style, layer: layer)),
        ])
    }

    static func setText(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let text = try requiredText(ctx)
        let layer = try editableTextLayer(ctx)
        try textFailures { try ctx.session.updateTextStyle(layer.id) { $0.content = text } }
        return try textLayerResult(layer.id, ctx)
    }

    static func setTextStyle(_ ctx: MCPCallContext) throws -> CallTool.Result {
        guard let patch = try ctx.args.object("style") else {
            throw MCPToolError.invalidArgument("Missing 'style' object.", hint: "Pass e.g. {\"font_size\": 48, \"color\": \"#ff0000\"}.")
        }
        let layer = try editableTextLayer(ctx)
        let current = try liveText(of: layer).style
        let style = try textStyle(current, patching: patch, session: ctx.session)
        guard !style.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPToolError(.invalidArgument, "'content' has nothing to show.", hint: "delete_layers removes a text layer.",
                               details: ["field": .string("content")])
        }
        try textFailures { try ctx.session.updateTextStyle(layer.id) { $0 = style } }
        return try textLayerResult(layer.id, ctx)
    }

    static func fitText(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let maxWidth = try ctx.args.double("max_width")
        guard maxWidth > 0 else { throw MCPToolError.invalidArgument("max_width must be above 0.") }
        let layer = try editableTextLayer(ctx)
        let text = try liveText(of: layer)
        // max_width is in document pixels; the text is measured in its own, which the layer may have scaled.
        let scale = layer.transform.size.width / CGFloat(max(1, text.image.width))
        let size = try textFailures(scale: scale) { try ctx.session.fitText(layer.id, maxWidth: CGFloat(maxWidth) / scale) }
        guard let fitted = ctx.session.document?.layers.first(where: { $0.id == layer.id }), let style = fitted.liveText?.style else {
            throw MCPToolError(.internalError, "The text could not be fitted.")
        }
        return try textLayerResult(layer.id, ctx, fields: [
            "font_size": .double(Double(size)),
            "previous_font_size": .double(Double(text.style.fontSize)),
            "metrics": .object(textMetricsFields(style, layer: fitted)),
        ])
    }

    static func getTextMetrics(_ ctx: MCPCallContext) throws -> CallTool.Result {
        if ctx.args.has("layer") {
            guard !ctx.args.has("text"), !ctx.args.has("style") else {
                throw MCPToolError.invalidArgument("Pass 'layer', or 'text' with a 'style', not both.")
            }
            let document = try ctx.document()
            let layer = try ctx.layer(in: document)
            return ok(textMetricsFields(try liveText(of: layer).style, layer: layer))
        }
        guard let text = try ctx.args.optionalString("text") else {
            throw MCPToolError.invalidArgument("Pass 'layer' (a text layer), or 'text' (with an optional 'style') to measure.")
        }
        var template = LayerTextStyle()
        template.content = text
        return ok(textMetricsFields(try textStyle(template, patching: try styleArgument(ctx), session: ctx.session), layer: nil))
    }

    static func listFonts(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let query = try ctx.args.optionalString("query").map(normalized)
        let limit = try ctx.args.int("limit", default: 200)
        guard (1...5000).contains(limit) else { throw MCPToolError.invalidArgument("limit must be 1–5000.") }
        let manager = NSFontManager.shared
        var fonts: [Value] = []
        var total = 0
        let families = manager.availableFontFamilies.filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        for family in families {
            for member in manager.availableMembers(ofFontFamily: family) ?? [] {
                guard member.count >= 4, let name = member[0] as? String, !name.hasPrefix(".") else { continue }
                let style = member[1] as? String ?? ""
                if let query, !normalized(name).contains(query), !normalized(family + style).contains(query) { continue }
                total += 1
                guard fonts.count < limit else { continue }
                let traits = NSFontTraitMask(rawValue: UInt(member[3] as? Int ?? 0))
                fonts.append(.object([
                    "postscript_name": .string(name),
                    "family": .string(family),
                    "style": .string(style),
                    "weight": .int(member[2] as? Int ?? 5),
                    "italic": .bool(traits.contains(.italicFontMask)),
                ]))
            }
        }
        return ok(["fonts": .array(fonts), "count": .int(fonts.count), "total": .int(total), "truncated": .bool(total > fonts.count)])
    }

    static func checkFonts(_ ctx: MCPCallContext) throws -> CallTool.Result {
        var names: [String] = []
        if let value = ctx.args["names"] {
            guard let items = value.arrayValue, (1...200).contains(items.count) else {
                throw MCPToolError.invalidArgument("'names' must list 1–200 PostScript font names.")
            }
            names = try items.map { item in
                guard let name = item.stringValue, !name.isEmpty else {
                    throw MCPToolError.invalidArgument("Every entry of 'names' must be a font's PostScript name.")
                }
                return name
            }
        } else if ctx.session.document == nil {
            throw MCPToolError.invalidArgument("Pass 'names', the fonts to check.", hint: "Open a document to check the fonts its text uses.")
        }
        let fonts: [Value] = names.map { name in
            let resolved = FontResolver.resolve(name, size: 12)
            return .object([
                "name": .string(name),
                "available": .bool(!resolved.isSubstitute),
                "substitute": resolved.isSubstitute ? .string(resolved.font.fontName) : .null,
                "family_match": .bool(resolved.isFamilyMatch),
            ])
        }
        var out: [String: Value] = ["fonts": .array(fonts)]
        if ctx.session.document != nil {
            out["document_missing"] = .array(ctx.session.missingFonts().map { missing in
                .object([
                    "layer_id": .string(missing.layerID.uuidString),
                    "layer_name": .string(missing.layerName),
                    "requested": .string(missing.requested),
                    "substitute": .string(FontResolver.resolve(missing.requested, size: 12).font.fontName),
                ])
            })
        }
        return ok(out)
    }

    // MARK: Layers

    /// The text layer the call names, once its text may change: live text, in a document that allows layer edits, and
    /// not held by Lock All (its own or a folder's). Photoshop's pixel and position locks leave type editable.
    static func editableTextLayer(_ ctx: MCPCallContext) throws -> ImageLayer {
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        _ = try liveText(of: layer)
        try MCPGuards.requireUnlocked(layer, in: document, .all)
        return layer
    }

    /// `layer`'s live text. A Photoshop placeholder is named first; a layer whose pixels were changed after its text
    /// was drawn is pixels now.
    static func liveText(of layer: ImageLayer) throws -> LayerText {
        try MCPGuards.requireNotPlaceholder(layer)
        guard let text = layer.liveText else {
            let hint = layer.text != nil
                ? "Its pixels were changed after its text was drawn, so it is pixels now. add_text_layer adds new text."
                : "add_text_layer adds a text layer."
            throw MCPToolError(.preconditionFailed, "'\(layer.name)' is not a text layer.", hint: hint, guard: "is_text")
        }
        return text
    }

    /// Adds a layer as one undo step named `editName` (`asOneStep`, which settles an opacity drag the app has open
    /// first), once `document` has room for it (`MCPGuards.requireLayerCapacity`). `add` adds the layer (above the
    /// active one) and returns its id; it is then named `name`, when given, and when it landed in a folder under Lock
    /// All it goes above the outermost such folder instead (`placeOutsideLockAllFolders`), as in Photoshop. When any
    /// part throws, the document, the active and selected layers and the folders' collapsed state are put back as they
    /// were, so the step records nothing.
    static func addLayerInOneStep(_ ctx: MCPCallContext, document: CanvasDocument, editName: String, name: String?,
                                  add: () throws -> UUID) throws -> UUID {
        try MCPGuards.requireLayerCapacity(document)
        let session = ctx.session
        return try asOneStep(session, editName) {
            let before = LayerAddSnapshot(session)
            do {
                return finishAdding(try add(), name: name, session: session)
            } catch {
                before.restore(session)
                throw error
            }
        }
    }

    /// `addLayerInOneStep` for an `add` that awaits, such as placing a file as a smart object: the step stays open
    /// across the await (`asOneAwaitingStep`), so the layer, its name and its move out of a locked folder are still one
    /// undo step.
    static func addLayerInOneStep(_ ctx: MCPCallContext, document: CanvasDocument, editName: String, name: String?,
                                  add: () async throws -> UUID) async throws -> UUID {
        try MCPGuards.requireLayerCapacity(document)
        let session = ctx.session
        return try await asOneAwaitingStep(session, editName) {
            let before = LayerAddSnapshot(session)
            do {
                return finishAdding(try await add(), name: name, session: session)
            } catch {
                before.restore(session)
                throw error
            }
        }
    }

    /// Names the new layer `id` and moves it out of a folder under Lock All. Where the layer landed decides: an add
    /// that awaits lands above whichever layer is active by then.
    private static func finishAdding(_ id: UUID, name: String?, session: EditorSession) -> UUID {
        if let name { session.renameLayer(id, to: name) }
        placeOutsideLockAllFolders(id, session: session)
        return id
    }

    /// What `addLayerInOneStep` puts back when adding fails: the document, the active and selected layers and the
    /// folders' collapsed state, taken as its step opens.
    private struct LayerAddSnapshot {
        let document: CanvasDocument?
        let active: UUID?
        let selected: Set<UUID>
        let collapsed: Set<UUID>

        init(_ session: EditorSession) {
            document = session.document
            active = session.activeLayerID
            selected = session.selectedLayerIDs
            collapsed = session.collapsedGroupIDs
        }

        /// Puts it all back, so the step records nothing. A document replaced or closed while an add awaited is left
        /// alone: that isn't this step's to undo.
        func restore(_ session: EditorSession) {
            guard session.document?.id == document?.id else { return }
            session.document = document
            // Setting the active layer selects it alone, so the selection goes back after it.
            session.activeLayerID = active
            session.selectedLayerIDs = selected
            session.collapsedGroupIDs = collapsed
        }
    }

    /// A text edit's result: the layer's id, style and transform, plus `fields`.
    static func textLayerResult(_ id: UUID, _ ctx: MCPCallContext, fields: [String: Value] = [:]) throws -> CallTool.Result {
        guard let layer = ctx.session.document?.layers.first(where: { $0.id == id }), let text = layer.liveText else {
            throw MCPToolError(.internalError, "The text layer is gone.")
        }
        var out = fields
        out["layer_id"] = .string(id.uuidString)
        out["text"] = MCPValues.textStyle(text.style)
        out["transform"] = MCPValues.transform(layer.transform)
        return ctx.mutated(out)
    }

    /// Runs a text command, turning its failures into tool errors. `scale` converts the text's own pixels to document
    /// pixels, to report a width that can't be fitted.
    static func textFailures<T>(scale: CGFloat = 1, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as TextLayerError {
            switch error {
            case .notEditable:
                throw MCPToolError(.preconditionFailed, "The document can't be edited right now.", hint: "Finish or cancel what the app is doing, then retry.",
                                   guard: "can_edit_layers")
            case .notText:
                throw MCPToolError(.preconditionFailed, "That layer is not a text layer.", hint: "add_text_layer adds one.", guard: "is_text")
            case .paragraphText:
                throw MCPToolError(.preconditionFailed, "Paragraph text wraps to its box, so only point text can be fitted to a width.",
                                   hint: "set_text_style with box_size: null makes it point text.", guard: "point_text")
            case .cannotFit(let width):
                throw MCPToolError.invalidArgument("max_width is too narrow: even 1-pixel type is \(Int((width * scale).rounded(.up))) pixels wide.")
            }
        } catch ProjectError.invalid {
            throw MCPToolError.invalidArgument("The text style is outside what Compositor supports.")
        }
    }

    // MARK: Styles

    /// The `text` argument: not empty or only spaces and line breaks, and within the 100,000 characters text holds.
    private static func requiredText(_ ctx: MCPCallContext) throws -> String {
        let text = try ctx.args.string("text")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPToolError.invalidArgument("'text' has nothing to show.", hint: "delete_layers removes a text layer.")
        }
        guard text.utf16.count <= 100_000 else { throw MCPToolError.invalidArgument("'text' is longer than 100,000 characters.") }
        return text
    }

    /// The `style` argument (empty when absent); the text itself comes in `text`.
    private static func styleArgument(_ ctx: MCPCallContext) throws -> [String: Value] {
        let style = try ctx.args.object("style") ?? [:]
        if style["content"] != nil {
            throw MCPToolError(.invalidArgument, "Give the text as 'text', not style.content.", details: ["field": .string("content")])
        }
        return style
    }

    /// `current` with `patch` merged in (see `MCPCodable.decodeMerged`): a text style in the form `MCPValues.textStyle`
    /// reports, where `color` stands for red/green/blue as {r, g, b} in 0–1, "#rrggbb", "foreground" or "background",
    /// and `box_size` is {width, height} (rounded to whole pixels) or null for point text. A value out of range fails
    /// naming the field.
    static func textStyle(_ current: LayerTextStyle, patching patch: [String: Value], session: EditorSession) throws -> LayerTextStyle {
        var fields = patch
        if let color = fields.removeValue(forKey: "color") {
            if let channel = ["red", "green", "blue"].first(where: { fields[$0] != nil }) {
                throw fieldError("color", "'color' and '\(channel)' both set the color; give one of them.")
            }
            let rgb = try colorArgument(color, field: "color", session: session)
            fields["red"] = .double(Double(rgb.red))
            fields["green"] = .double(Double(rgb.green))
            fields["blue"] = .double(Double(rgb.blue))
        }
        if let box = fields["box_size"], box != .null { fields["box_size"] = try boxSize(box) }
        return try MCPCodable.decodeMerged(current, .object(fields), template: LayerTextStyle())
    }

    private static let colorHint = "A color is {\"r\", \"g\", \"b\"} in 0–1, \"#rrggbb\", \"foreground\" or \"background\"."

    /// A color argument (`field` names it in errors): `"foreground"` or `"background"` (the palette's), `"#rrggbb"`, or
    /// `{r, g, b}` (or `red`, `green`, `blue`) in 0–1. Out of range is an error, not clamped. Text and shapes take colors
    /// this way.
    static func colorArgument(_ value: Value, field: String, session: EditorSession) throws -> PaletteColor {
        if let name = value.stringValue {
            switch normalized(name) {
            case "foreground": return session.foregroundColor
            case "background": return session.backgroundColor
            default:
                guard let rgb = MCPValues.color(from: value) else { throw fieldError(field, "'\(field)' isn't a color.", hint: colorHint) }
                return PaletteColor(red: rgb.red, green: rgb.green, blue: rgb.blue)
            }
        }
        guard let object = value.objectValue else { throw fieldError(field, "'\(field)' isn't a color.", hint: colorHint) }
        let known = ["r", "g", "b", "red", "green", "blue"]
        if let extra = object.keys.sorted().first(where: { !known.contains($0) }) {
            throw fieldError("\(field).\(extra)", "Unknown field '\(field).\(extra)'; a color has only r, g and b.", hint: colorHint)
        }
        var channels: [CGFloat] = []
        for (short, long) in [("r", "red"), ("g", "green"), ("b", "blue")] {
            guard object[short] == nil || object[long] == nil else {
                throw fieldError("\(field).\(short)", "'\(field)' gives \(short) twice, as \(short) and \(long).")
            }
            let key = object[short] != nil ? short : long
            guard let raw = object[key] else { throw fieldError("\(field).\(short)", "'\(field)' needs r, g and b.", hint: colorHint) }
            guard let number = MCPValues.number(raw) else {
                throw fieldError("\(field).\(key)", "'\(field).\(key)' must be a number from 0 to 1.")
            }
            try requireArgumentRange(number, 0...1, field: "\(field).\(key)")
            channels.append(CGFloat(number))
        }
        return PaletteColor(red: channels[0], green: channels[1], blue: channels[2])
    }

    /// A paragraph box, `{width, height}` of 16–30,000 pixels and at most one surface's pixels (`DocumentLimits`), as
    /// the `[width, height]` `LayerTextStyle` stores, in whole pixels.
    private static func boxSize(_ value: Value) throws -> Value {
        guard let object = value.objectValue else {
            throw fieldError("box_size", "'box_size' must be {\"width\", \"height\"} in pixels, or null for point text.")
        }
        if let extra = object.keys.sorted().first(where: { !["width", "height"].contains($0) }) {
            throw fieldError("box_size.\(extra)", "Unknown field 'box_size.\(extra)'; a box has only width and height.")
        }
        var sides: [Double] = []
        for side in ["width", "height"] {
            guard let number = MCPValues.number(object[side]) else {
                throw fieldError("box_size.\(side)", "'box_size.\(side)' must be a number of pixels.")
            }
            let whole = number.rounded()
            try requireArgumentRange(whole, 16...Double(DocumentLimits.maxSide), field: "box_size.\(side)")
            sides.append(whole)
        }
        guard sides[0] * sides[1] <= Double(DocumentLimits.maxSurfacePixels) else {
            throw fieldError("box_size", "'box_size' is more than \(DocumentLimits.maxSurfaceMegapixels) megapixels, the most a text box can be.")
        }
        return .array(sides.map { .double($0) })
    }

    /// Fails with `invalid_argument` naming `field`, its value and `range` when `number` is outside it.
    static func requireArgumentRange(_ number: Double, _ range: ClosedRange<Double>, field: String) throws {
        guard !range.contains(number) else { return }
        func format(_ value: Double) -> String { value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value) }
        var error = fieldError(field, "'\(field)' is \(format(number)), outside its range \(format(range.lowerBound))–\(format(range.upperBound)).")
        error.details["value"] = .double(number)
        error.details["min"] = .double(range.lowerBound)
        error.details["max"] = .double(range.upperBound)
        throw error
    }

    private static func fieldError(_ field: String, _ message: String, hint: String? = nil) -> MCPToolError {
        MCPToolError(.invalidArgument, message, hint: hint, details: ["field": .string(field)])
    }

    // MARK: Metrics

    /// `style` measured as it is laid out (see get_text_metrics); with `layer`, its id, its box in the document and the
    /// scale from the text's pixels to the document's.
    static func textMetricsFields(_ style: LayerTextStyle, layer: ImageLayer?) -> [String: Value] {
        let resolved = FontResolver.resolve(style.fontName, size: style.fontSize)
        let laidOut = EditorSession.textLayoutMetrics(style)
        let box = EditorSession.textBoxSize(style)
        func number(_ value: CGFloat) -> Value { .double(Double(value)) }
        var out: [String: Value] = [
            "font_name": .string(style.fontName),
            "font_used": .string(resolved.font.fontName),
            "font_available": .bool(!resolved.isSubstitute),
            "font_size": number(style.fontSize),
            "line_height": number(style.lineHeight),
            "ascent": number(resolved.font.ascender),
            "descent": number(-resolved.font.descender),
            "box": .object(["width": number(box.width), "height": number(box.height)]),
            "width": number(laidOut.size.width),
            "height": number(laidOut.size.height),
            "padding": number(LayerTextStyle.padding),
            "lines": .array(laidOut.lines.map { .object(["text": .string($0.text), "width": number($0.width), "baseline": number($0.baseline)]) }),
            "line_count": .int(laidOut.lines.count),
            "overflows": .bool(laidOut.overflows),
        ]
        if let layer {
            out["layer_id"] = .string(layer.id.uuidString)
            out["bounds"] = MCPValues.rect(MCPRender.box(of: layer.transform))
            let pixels = CGSize(width: layer.asset?.image.width ?? Int(box.width), height: layer.asset?.image.height ?? Int(box.height))
            out["scale"] = .object(["x": number(layer.transform.size.width / max(1, pixels.width)),
                                    "y": number(layer.transform.size.height / max(1, pixels.height))])
        }
        return out
    }

    // MARK: Schemas

    static func textStyleSchema(withContent: Bool) -> Value {
        var fields: [String: Value] = [
            "font_name": MCPSchema.str("PostScript name (list_fonts); a missing font draws with a substitute (check_fonts)."),
            "font_size": MCPSchema.num("Type size in pixels.", min: 1, max: 2000),
            "color": MCPSchema.anyOf([
                MCPSchema.rgbObject,
                MCPSchema.hexColor,
                .object(["type": .string("string"), "enum": .array([.string("foreground"), .string("background")])]),
            ], description: "Text color: {r, g, b}, \"#rrggbb\", \"foreground\" or \"background\"."),
            "alignment": MCPSchema.enumString("Line alignment.", ["left", "center", "right"]),
            "tracking": MCPSchema.num("Extra space after each letter.", min: -100, max: 1000),
            "leading": MCPSchema.num("Baseline to baseline in pixels; 0 is auto.", min: 0, max: 5000),
            "box_size": MCPSchema.nullable(MCPSchema.object(
                ["width": MCPSchema.num("Width.", min: 16, max: Double(DocumentLimits.maxSide)),
                 "height": MCPSchema.num("Height.", min: 16, max: Double(DocumentLimits.maxSide))],
                required: ["width", "height"],
                description: "Paragraph text: the box it wraps in, padding included. null: point text.")),
            "horizontal_scale": MCPSchema.nullable(MCPSchema.num("Width stretch; null is 1.", min: 0.1, max: 10)),
        ]
        if withContent { fields["content"] = MCPSchema.str("The text.") }
        return MCPSchema.object(fields, description: "Style fields; any left out keep their values.")
    }
}

// MARK: - Patching

nonisolated extension LayerTextStyle: MCPPatchable {
    static let mcpFieldRanges: [String: ClosedRange<Double>] = [
        "font_size": 1...2000, "red": 0...1, "green": 0...1, "blue": 0...1, "tracking": -100...1000, "leading": 0...5000,
        "horizontal_scale": 0.1...10, "box_size[]": 16...Double(DocumentLimits.maxSide),
    ]

    static let mcpEnumMembers: [String: [String]] = ["alignment": TextAlignment.allCases.map(\.rawValue)]

    var mcpInvalidReason: String? {
        if content.utf16.count > 100_000 { return "The text is longer than 100,000 characters." }
        if !boxIsValid {
            return "box_size must be 16–\(DocumentLimits.maxSide.formatted()) pixels a side and at most \(DocumentLimits.maxSurfaceMegapixels) megapixels."
        }
        return nil
    }
}
