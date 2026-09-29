import CoreGraphics
import Foundation
import MCP

// MARK: - Pixels and painting

extension MCPToolRegistry {
    static let paintTools: [MCPToolEntry] = [
        tool("fill_selection", title: "Fill selection",
             description: "Fills the selection (the whole layer without one) on a layer's pixels, or its mask with target mask, with a color, the foreground or the background. A text layer filled whole takes the color and stays editable. On a mask, colors paint as gray and foreground and background are the app's mask colors.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "with": MCPSchema.enumString("Fill source (default color when given, else foreground).",
                                              ["color", "foreground", "background"]),
                 "color": MCPSchema.color("Fill color."),
                 "target": pixelTargetSchema,
             ],
             required: ["layer"], effect: .destructive(idempotent: false), handler: fillSelection),
        tool("clear_selection", title: "Clear selection",
             description: "Clears a layer's selected pixels to transparency; on its mask (target mask) the selection fills with the app's mask background, white unless swapped. Needs a selection.",
             properties: ["layer": MCPSchema.layerSelector(), "target": pixelTargetSchema],
             required: ["layer"], effect: .destructive(idempotent: false), handler: clearSelection),
        tool("invert_pixels", title: "Invert pixels",
             description: "Inverts a layer's colors, keeping transparency, or its mask with target mask, inside the selection when there is one.",
             properties: ["layer": MCPSchema.layerSelector(), "target": pixelTargetSchema],
             required: ["layer"], effect: .destructive(idempotent: false), handler: invertPixels),
        tool("stroke_path", title: "Stroke path",
             description: "Paints one brush stroke through 'points' on a layer's pixels, or its mask with target mask, with this call's brush and no smoothing, inside the selection when there is one. mode: paint (brush.color, default the foreground, or on a mask the app's mask foreground), erase, heal (heal_mode), clone (from clone.source), blur, smudge or liquify; masks take paint and blur.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "points": MCPSchema.arr("The path; one point paints a dab.",
                                         items: MCPSchema.point("A point on the stroke."), minItems: 1, maxItems: maxStrokePoints),
                 "mode": MCPSchema.enumString("What it does.", ["paint", "erase", "heal", "clone", "blur", "smudge", "liquify"],
                                              default: "paint"),
                 "brush": MCPSchema.object([
                     "diameter": MCPSchema.num("Tip diameter.", min: 1, max: 2000, default: 40),
                     "hardness": MCPSchema.num("0 soft to 1 hard.", min: 0, max: 1, default: 1),
                     "opacity": MCPSchema.num("Most coverage.", min: 0.01, max: 1,
                                              default: 1),
                     "color": MCPSchema.color("Paint color (default the foreground)."),
                 ], description: "The brush tip."),
                 "target": pixelTargetSchema,
                 "heal_mode": MCPSchema.enumString("How heal rebuilds.", ["content_aware", "create_texture", "proximity_match"],
                                                   default: "content_aware"),
                 "clone": MCPSchema.object([
                     "source": MCPSchema.point("Where the first point copies from."),
                     "sample_all_layers": MCPSchema.bool("Copy from the composite.", default: false),
                     "aligned": MCPSchema.bool("Photoshop's Aligned (one stroke per call).",
                                               default: true),
                 ], required: ["source"], description: "For clone: where to copy from."),
             ],
             required: ["layer", "points"], effect: .destructive(idempotent: false), handler: strokePath),
        tool("draw_gradient", title: "Draw gradient",
             description: "Draws a linear or radial gradient from start to end on a layer's pixels, or its mask with target mask, inside the selection when there is one. Its ends are colors {from, to}, each a color or \"transparent\", or a palette style; a radial one centers on start. On a mask, colors paint as gray.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "start": MCPSchema.point("Start (a radial one's center)."),
                 "end": MCPSchema.point("End (on a radial one's rim)."),
                 "shape": MCPSchema.enumString("Shape.", ["linear", "radial"], default: "linear"),
                 "colors": MCPSchema.object([
                     "from": MCPSchema.anyOf([MCPSchema.color("A color."), MCPSchema.enumString("No color.", ["transparent"])],
                                             description: "Start color or \"transparent\"."),
                     "to": MCPSchema.anyOf([MCPSchema.color("A color."), MCPSchema.enumString("No color.", ["transparent"])],
                                           description: "End color or \"transparent\"."),
                 ], required: ["from", "to"], description: "End colors (or give style)."),
                 "style": MCPSchema.enumString("Palette ends; foreground_to_transparent when neither this nor colors is given.",
                                               ["foreground_to_background", "foreground_to_transparent"]),
                 "reversed": MCPSchema.bool("Swap the ends.", default: false),
                 "opacity": MCPSchema.num("Coverage.", min: 0.01, max: 1, default: 1),
                 "target": pixelTargetSchema,
             ],
             required: ["layer", "start", "end"], effect: .destructive(idempotent: false), handler: drawGradient),
        tool("get_layer_pixels", title: "Get layer pixels",
             description: "Returns a layer's own pixels (before opacity, mask, effects and blending), or with target mask its mask as gray, as a PNG image scaled down to max_size, then JSON with the sizes and transform. Hidden layers are read too; save_to also writes the full-size PNG.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "target": pixelTargetSchema,
                 "max_size": MCPSchema.int("Longest side of the returned image; larger rasters scale down.",
                                           min: MCPRenderOptions.maxSizeRange.lowerBound, max: MCPRenderOptions.maxSizeRange.upperBound,
                                           default: MCPRenderOptions.defaultMaxSize),
                 "save_to": MCPSchema.str("A .png path for the full-size pixels."),
                 "overwrite": MCPSchema.bool("Replace a file at save_to.", default: false),
             ],
             required: ["layer"], effect: .additive(idempotent: true), handler: getLayerPixels),
        tool("set_layer_pixels", title: "Set layer pixels",
             description: "Replaces a layer's pixels with an image file, placed by 'placement'. keep_bounds stretches it over the layer's box, keep_origin puts it at its own size at the box's top-left, natural at its own size, upright, centered where the layer was. Text and shape layers become pixels.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "path": MCPSchema.str("Image file."),
                 "placement": MCPSchema.enumString("Where the pixels go.", ["keep_bounds", "keep_origin", "natural"], default: "keep_bounds"),
             ],
             required: ["layer", "path"], effect: .destructive(idempotent: false), handler: setLayerPixels),
        tool("paste_image_into_layer", title: "Paste image into layer",
             description: "Draws an image file into a layer's pixels with its top-left at (x, y), one image pixel per document pixel, inside the canvas and the selection: over draws it on top, replace swaps in its pixels.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "path": MCPSchema.str("Image file."),
                 "x": MCPSchema.num("Left edge."),
                 "y": MCPSchema.num("Top edge."),
                 "mode": MCPSchema.enumString("over or replace.", ["over", "replace"],
                                              default: "over"),
             ],
             required: ["layer", "path", "x", "y"], effect: .destructive(idempotent: false), handler: pasteImageIntoLayer),
        tool("copy_pixels", title: "Copy pixels",
             description: "Copies a layer's selected pixels (all of them without a selection), or with merged the visible composite (the canvas without a selection), to Compositor's clipboard and the system pasteboard. It returns the region copied.",
             properties: [
                 "layer": MCPSchema.layerSelector("The layer to copy from (default the active layer; not with merged)"),
                 "merged": MCPSchema.bool("Copy the composite.", default: false),
             ],
             effect: .additive(idempotent: true), handler: copyPixels),
        tool("paste_pixels", title: "Paste pixels",
             description: "Pastes the clipboard as a new layer above the active layer: pixels copied in Compositor go back where they came from, other images are centered, or x and y place the top-left. The selection is dropped.",
             properties: [
                 "x": MCPSchema.num("Left edge (with y)."),
                 "y": MCPSchema.num("Top edge (with x)."),
             ],
             effect: .additive(idempotent: false), handler: pastePixels),
    ]

    static let maxStrokePoints = 10_000
    static let maxPaintOffset = 1_000_000.0

    static let pixelTargetSchema = MCPSchema.enumString("The layer's pixels, or its mask.", ["pixels", "mask"],
                                                   default: "pixels")


    // MARK: Fill, clear, invert

    static func fillSelection(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let mask = try pixelTargetIsMask(ctx.args)
        let source = try fillSource(ctx.args)
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        let session = ctx.session
        try requireEditablePixels(layer, mask: mask, in: document, session: session)
        try await withPixelTarget(ctx, layer, mask: mask) {
            guard session.canEditPixels else { throw cannotEditPixels(layer, session, guard: "can_paint") }
            try await MCPGuards.captureAsyncBrushError(session) { await session.fillSelection(with: source) }
        }
        return ctx.mutated(["layer_id": .string(layer.id.uuidString), "target": pixelTargetName(mask)])
    }

    static func clearSelection(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let mask = try pixelTargetIsMask(ctx.args)
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        let session = ctx.session
        try requireEditablePixels(layer, mask: mask, in: document, session: session)
        guard session.selection != nil else {
            throw MCPToolError(.preconditionFailed, "There is no selection to clear.",
                               hint: "Select the area first, e.g. with select_rect; fill_selection changes a whole layer.", guard: "selection")
        }
        try await withPixelTarget(ctx, layer, mask: mask) {
            guard session.canEditPixels else { throw cannotEditPixels(layer, session, guard: "can_paint") }
            try await MCPGuards.captureAsyncBrushError(session) { await session.clearSelectedPixels() }
        }
        return ctx.mutated(["layer_id": .string(layer.id.uuidString), "target": pixelTargetName(mask)])
    }

    static func invertPixels(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let mask = try pixelTargetIsMask(ctx.args)
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        let session = ctx.session
        try requireEditablePixels(layer, mask: mask, in: document, session: session, guard: "can_invert", needsRaster: !mask)
        try await withPixelTarget(ctx, layer, mask: mask) {
            guard session.canInvert else { throw cannotEditPixels(layer, session, guard: "can_invert") }
            try await MCPGuards.captureAsyncBrushError(session) { await session.invertPixels() }
        }
        return ctx.mutated(["layer_id": .string(layer.id.uuidString), "target": pixelTargetName(mask)])
    }

    /// The call's `with` and `color`: a color (implied by `color` alone), the foreground or the background.
    static func fillSource(_ args: Args) throws -> EditorSession.FillSource {
        let color = try args.color("color")
        let name = try args.optionalString("with").map(normalized) ?? (color == nil ? "foreground" : "color")
        switch name {
        case "color":
            guard let color else {
                throw MCPToolError.invalidArgument("with: color needs 'color': {r, g, b} in 0–1, or \"#rrggbb\".")
            }
            return .color(PaletteColor(red: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue)))
        case "foreground", "foregroundcolor", "background", "backgroundcolor":
            guard color == nil else {
                throw MCPToolError.invalidArgument("'color' is only used with with: color.", hint: "Leave out 'with', or leave out 'color'.")
            }
            return name.hasPrefix("foreground") ? .foreground : .background
        default:
            throw MCPToolError.invalidArgument("'with' must be color, foreground or background.")
        }
    }

    // MARK: Strokes

    static func strokePath(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let mask = try pixelTargetIsMask(ctx.args)
        let points = try pointArray(ctx.args, "points", count: 1...maxStrokePoints)
        let (mode, modeName) = try strokeMode(ctx.args, mask: mask)
        let brush = try brushTip(ctx.args)
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        let session = ctx.session
        try requireEditablePixels(layer, mask: mask, in: document, session: session)
        var settings = BrushSettings()
        settings.diameter = brush.diameter
        settings.hardness = brush.hardness
        settings.opacity = brush.opacity
        let color = brush.color ?? paintPalette(session, background: false, mask: mask)
        if mask {
            let gray = color.maskGray
            (settings.red, settings.green, settings.blue) = (gray, gray, gray)
        } else {
            (settings.red, settings.green, settings.blue) = (color.red, color.green, color.blue)
        }
        try await withPixelTarget(ctx, layer, mask: mask) {
            try await runHeadlessEdit {
                try MCPGuards.captureBrushError(session) {
                    try session.paintStroke(points, on: layer.id, mask: mask, settings: settings, mode: mode)
                }
            }
        }
        return ctx.mutated(["layer_id": .string(layer.id.uuidString), "target": pixelTargetName(mask), "mode": .string(modeName),
                            "points": .int(points.count)])
    }

    /// The call's `mode` (with `heal_mode` and `clone`), and its name. Masks take paint and blur only.
    static func strokeMode(_ args: Args, mask: Bool) throws -> (StrokeMode, String) {
        let mode: StrokeMode, label: String
        switch normalized(try args.string("mode", default: "paint")) {
        case "paint", "brush": (mode, label) = (.paint, "paint")
        case "erase", "eraser": (mode, label) = (.erase, "erase")
        case "heal", "spothealing": (mode, label) = (.heal(try healMode(args)), "heal")
        case "clone", "clonestamp": (mode, label) = (try cloneMode(args), "clone")
        case "blur": (mode, label) = (.blur, "blur")
        case "smudge": (mode, label) = (.smudge, "smudge")
        case "liquify": (mode, label) = (.liquify, "liquify")
        default: throw MCPToolError.invalidArgument("'mode' must be paint, erase, heal, clone, blur, smudge or liquify.")
        }
        if args.has("heal_mode"), label != "heal" { throw MCPToolError.invalidArgument("'heal_mode' is only used with mode heal.") }
        if args.has("clone"), label != "clone" { throw MCPToolError.invalidArgument("'clone' is only used with mode clone.") }
        if mask, mode != .paint, mode != .blur {
            throw MCPToolError.invalidArgument("On a mask, stroke_path paints or blurs; \(label) works on a layer's pixels.",
                                               hint: "To hide part of the layer paint its mask black, to reveal it paint white.")
        }
        return (mode, label)
    }

    private static func healMode(_ args: Args) throws -> SpotHealingMode {
        guard let name = try args.optionalString("heal_mode") else { return .contentAware }
        guard let mode = SpotHealingMode.allCases.first(where: { normalized($0.rawValue) == normalized(name) }) else {
            throw MCPToolError.invalidArgument("'heal_mode' must be content_aware, create_texture or proximity_match.")
        }
        return mode
    }

    private static func cloneMode(_ args: Args) throws -> StrokeMode {
        guard let clone = try args.object("clone") else {
            throw MCPToolError.invalidArgument("mode clone needs 'clone': {\"source\": {\"x\", \"y\"}}, where the stroke copies from.")
        }
        if let key = clone.keys.sorted().first(where: { !["source", "sample_all_layers", "aligned"].contains($0) }) {
            throw MCPToolError(.invalidArgument, "Unknown clone setting '\(key)'.", hint: "'clone' takes source, sample_all_layers and aligned.",
                               details: ["field": .string("clone." + key)])
        }
        guard let value = clone["source"], let source = MCPValues.point(from: value),
              abs(source.x) <= maxPaintOffset, abs(source.y) <= maxPaintOffset else {
            throw MCPToolError.invalidArgument("'clone.source' must be a point {x, y} in document pixels.")
        }
        func flag(_ key: String, _ fallback: Bool) throws -> Bool {
            guard let value = clone[key], value != .null else { return fallback }
            guard let bool = value.boolValue else { throw MCPToolError.invalidArgument("'clone.\(key)' must be true or false.") }
            return bool
        }
        _ = try flag("aligned", true)
        return .clone(source: source, sampleAll: try flag("sample_all_layers", false))
    }

    /// The call's `brush`: diameter, hardness and opacity, and its color when it gives one.
    static func brushTip(_ args: Args) throws -> (diameter: CGFloat, hardness: CGFloat, opacity: CGFloat, color: PaletteColor?) {
        let brush = try args.object("brush") ?? [:]
        if let key = brush.keys.sorted().first(where: { !["diameter", "hardness", "opacity", "color"].contains($0) }) {
            throw MCPToolError(.invalidArgument, "Unknown brush setting '\(key)'.", hint: "The brush takes diameter, hardness, opacity and color.",
                               details: ["field": .string("brush." + key)])
        }
        func number(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>, _ text: String) throws -> CGFloat {
            guard let value = brush[key], value != .null else { return CGFloat(fallback) }
            guard let number = MCPValues.number(value), range.contains(number) else {
                throw MCPToolError(.invalidArgument, "'brush.\(key)' must be a number \(text).", details: ["field": .string("brush." + key)])
            }
            return CGFloat(number)
        }
        let diameter = try number("diameter", 40, 1...2000, "from 1 to 2000 pixels")
        let hardness = try number("hardness", 1, 0...1, "from 0 to 1")
        let opacity = try number("opacity", 1, 0.01...1, "from 0.01 to 1")
        var color: PaletteColor?
        if let value = brush["color"], value != .null {
            guard let rgb = MCPValues.color(from: value) else {
                throw MCPToolError(.invalidArgument, "'brush.color' must be a color: {\"r\", \"g\", \"b\"} in 0–1, or \"#rrggbb\".",
                                   details: ["field": .string("brush.color")])
            }
            color = PaletteColor(red: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue))
        }
        return (diameter, hardness, opacity, color)
    }

    // MARK: Gradients

    /// A gradient's two ends: explicit colors (nil for transparent), or a palette style.
    enum GradientEnds {
        case colors(from: PaletteColor?, to: PaletteColor?)
        case style(GradientStyle)
    }

    static func drawGradient(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let mask = try pixelTargetIsMask(ctx.args)
        let start = try pointArgument(ctx.args, "start")
        let end = try pointArgument(ctx.args, "end")
        guard hypot(end.x - start.x, end.y - start.y) >= 0.5 else {
            throw MCPToolError.invalidArgument("'start' and 'end' must be at least half a pixel apart.")
        }
        let shape: GradientShape
        switch normalized(try ctx.args.string("shape", default: "linear")) {
        case "linear": shape = .linear
        case "radial": shape = .radial
        default: throw MCPToolError.invalidArgument("'shape' must be linear or radial.")
        }
        let reversed = try ctx.args.bool("reversed", default: false)
        let opacity = try ctx.args.double("opacity", default: 1)
        guard (0.01...1).contains(opacity) else { throw MCPToolError.invalidArgument("'opacity' must be from 0.01 to 1.") }
        let ends = try gradientEnds(ctx.args)
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        let session = ctx.session
        try requireEditablePixels(layer, mask: mask, in: document, session: session)
        var from: PaletteColor?, to: PaletteColor?
        switch ends {
        case .colors(let first, let second):
            (from, to) = (first, second)
        case .style(let style):
            from = paintPalette(session, background: false, mask: mask)
            to = style == .foregroundToBackground ? paintPalette(session, background: true, mask: mask) : nil
        }
        if reversed { (from, to) = (to, from) }
        let colors = gradientEndColors(from: from, to: to, mask: mask)
        try await withPixelTarget(ctx, layer, mask: mask) {
            try await runHeadlessEdit {
                try await MCPGuards.captureAsyncBrushError(session) {
                    try await session.applyGradient(on: layer.id, mask: mask, shape: shape, from: start, to: end, colors: colors,
                                                    opacity: CGFloat(opacity))
                }
            }
        }
        return ctx.mutated(["layer_id": .string(layer.id.uuidString), "target": pixelTargetName(mask)])
    }

    private static func gradientEnds(_ args: Args) throws -> GradientEnds {
        let colors = try args.object("colors")
        let style = try args.optionalString("style")
        if colors != nil, style != nil { throw MCPToolError.invalidArgument("Give 'colors' or 'style', not both.") }
        if let colors {
            if let key = colors.keys.sorted().first(where: { $0 != "from" && $0 != "to" }) {
                throw MCPToolError(.invalidArgument, "Unknown field 'colors.\(key)'; 'colors' takes from and to.",
                                   details: ["field": .string("colors." + key)])
            }
            func color(_ key: String) throws -> PaletteColor? {
                guard let value = colors[key], value != .null else {
                    throw MCPToolError.invalidArgument("'colors.\(key)' is required: a color, or \"transparent\".")
                }
                if let text = value.stringValue, normalized(text) == "transparent" { return nil }
                guard let rgb = MCPValues.color(from: value) else {
                    throw MCPToolError.invalidArgument("'colors.\(key)' must be a color ({\"r\", \"g\", \"b\"} in 0–1, or \"#rrggbb\"), or \"transparent\".")
                }
                return PaletteColor(red: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue))
            }
            return .colors(from: try color("from"), to: try color("to"))
        }
        switch normalized(style ?? "foreground_to_transparent") {
        case "foregroundtobackground": return .style(.foregroundToBackground)
        case "foregroundtotransparent": return .style(.foregroundToTransparent)
        default: throw MCPToolError.invalidArgument("'style' must be foreground_to_background or foreground_to_transparent.")
        }
    }

    /// The two ends as colors a gradient draws with: sRGB, or gray on a mask. A transparent end takes the other end's
    /// color at no opacity, so the blend never passes through black.
    static func gradientEndColors(from: PaletteColor?, to: PaletteColor?, mask: Bool) -> [CGColor] {
        let space = mask ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        func color(_ value: PaletteColor, alpha: CGFloat) -> CGColor {
            CGColor(colorSpace: space, components: mask ? [value.maskGray, alpha] : [value.red, value.green, value.blue, alpha])!
        }
        let first = from ?? to ?? .black, second = to ?? from ?? .black
        return [color(first, alpha: from == nil ? 0 : 1), color(second, alpha: to == nil ? 0 : 1)]
    }

    /// A palette color as the app paints it on the layer's pixels, or on a mask (its black and white).
    static func paintPalette(_ session: EditorSession, background: Bool, mask: Bool) -> PaletteColor {
        guard mask else { return background ? session.backgroundColor : session.foregroundColor }
        return background != session.maskPaintWhite ? .white : .black
    }

    // MARK: Reading and replacing pixels

    static func getLayerPixels(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let mask = try pixelTargetIsMask(ctx.args)
        let maxSize = try ctx.args.int("max_size", default: MCPRenderOptions.defaultMaxSize)
        try MCPRenderOptions.checkMaxSize(maxSize)
        let overwrite = try ctx.args.bool("overwrite", default: false)
        let destination = try await pixelsDestination(ctx.args)
        let document = try ctx.document()
        let layer = try ctx.layer(in: document)
        let source: ImportedImage
        let placement: LayerTransform
        if mask {
            // A placeholder keeps its Photoshop mask, and reading it is fine.
            guard let owned = layer.mask else { throw noLayerMask(layer) }
            source = owned.asset
            placement = layer.maskTransform
        } else {
            // Named first: import keeps a placeholder without pixels, so the pixel checks' hints can't help.
            try MCPGuards.requireNotPlaceholder(layer)
            try MCPGuards.requirePixels(layer)
            source = try requireLayerRaster(layer)
            placement = layer.transform
        }
        if let destination { try await MCPPaths.prepareForWriting(destination, overwrite: overwrite) }
        let preview = try await Task.detached(priority: .userInitiated) {
            let image = source.image
            let (scaled, scale) = try MCPRender.downscaled(image, maxSize: maxSize)
            let data = try MCPRender.encode(scaled, format: .png, quality: 1, background: .transparent)
            if let destination {
                let full = scale == 1 ? data : try MCPRender.encode(image, format: .png, quality: 1, background: .transparent)
                try await ImageExporter.shared.write(full, to: destination)
            }
            return MCPRender.Preview(data: data, width: scaled.width, height: scaled.height, scale: Double(scale),
                                     sourceWidth: image.width, sourceHeight: image.height)
        }.value
        var out: [String: Value] = [
            "layer_id": .string(layer.id.uuidString),
            "target": pixelTargetName(mask),
            "width": .int(preview.width),
            "height": .int(preview.height),
            "scale": .double(preview.scale),
            "pixel_width": .int(source.image.width),
            "pixel_height": .int(source.image.height),
            "transform": MCPValues.transform(placement),
            "bytes": .int(preview.data.count),
        ]
        if let destination { out["path"] = .string(destination.path) }
        return imageResult(MCPRender.imageContent(preview.data, format: .png), out)
    }

    /// The call's `save_to`, as a .png file URL (the extension added when it has none), or nil without one.
    private static func pixelsDestination(_ args: Args) async throws -> URL? {
        guard let raw = try args.optionalString("save_to") else { return nil }
        var url = try await MCPPaths.resolveReachable(raw)
        switch url.pathExtension.lowercased() {
        case "": url.appendPathExtension("png")
        case "png": break
        default: throw MCPToolError.invalidArgument("'save_to' must be a .png path; layer pixels are saved as PNG.")
        }
        return url
    }

    static func setLayerPixels(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let url = try await MCPPaths.resolveReachable(try ctx.args.string("path"), mustExist: true)
        let placement: PixelPlacement
        switch normalized(try ctx.args.string("placement", default: "keep_bounds")) {
        case "keepbounds": placement = .keepBounds
        case "keeporigin": placement = .keepOrigin
        case "natural": placement = .natural
        default: throw MCPToolError.invalidArgument("'placement' must be keep_bounds, keep_origin or natural.")
        }
        let document = try ctx.editableDocument()
        let requested = try ctx.layer(in: document)
        try MCPGuards.requireNotPlaceholder(requested)
        try MCPGuards.requirePixels(requested)
        try requireNotSmartObject(requested)
        try MCPGuards.requireUnlocked(requested, in: document, .pixels)
        let asset = try await decodeImageFile(url)
        // Reading the file took a while; work from the document as it is now.
        let layer = try layerAfterReading(requested, ctx)
        let session = ctx.session
        try await withPixelTarget(ctx, layer, mask: false) {
            try await runHeadlessEdit { try session.replaceLayerPixels(layer.id, with: asset, placement: placement) }
        }
        let transform = session.document?.layers.first { $0.id == layer.id }?.transform
        return ctx.mutated([
            "layer_id": .string(layer.id.uuidString),
            "transform": transform.map(MCPValues.transform) ?? .null,
            "pixel_width": .int(asset.image.width),
            "pixel_height": .int(asset.image.height),
        ])
    }

    static func pasteImageIntoLayer(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let url = try await MCPPaths.resolveReachable(try ctx.args.string("path"), mustExist: true)
        let x = try ctx.args.double("x"), y = try ctx.args.double("y")
        guard abs(x) <= maxPaintOffset, abs(y) <= maxPaintOffset else {
            throw MCPToolError.invalidArgument("'x' and 'y' must be within ±1,000,000 pixels.")
        }
        let replacing: Bool
        switch normalized(try ctx.args.string("mode", default: "over")) {
        case "over": replacing = false
        case "replace": replacing = true
        default: throw MCPToolError.invalidArgument("'mode' must be over or replace.")
        }
        let document = try ctx.editableDocument()
        let requested = try ctx.layer(in: document)
        let session = ctx.session
        try requireEditablePixels(requested, mask: false, in: document, session: session)
        let asset = try await decodeImageFile(url)
        let layer = try layerAfterReading(requested, ctx)
        try await withPixelTarget(ctx, layer, mask: false) {
            try await runHeadlessEdit {
                try MCPGuards.captureBrushError(session) {
                    try session.pasteImage(asset.image, into: layer.id, at: CGPoint(x: x, y: y), replacing: replacing)
                }
            }
        }
        return ctx.mutated([
            "layer_id": .string(layer.id.uuidString),
            "rect": MCPValues.rect(CGRect(x: x, y: y, width: Double(asset.image.width), height: Double(asset.image.height))),
            "mode": .string(replacing ? "replace" : "over"),
        ])
    }

    // MARK: Clipboard

    static func copyPixels(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let merged = try ctx.args.bool("merged", default: false)
        if merged, ctx.args.has("layer") {
            throw MCPToolError.invalidArgument("'layer' isn't used with merged: true, which copies every visible layer.")
        }
        let document = try ctx.editableDocument()
        let session = ctx.session
        if session.selection?.isEmpty == true { throw emptySelectionError() }
        let before = session.pixelClipboard?.changeCount
        var fields: [String: Value] = ["merged": .bool(merged)]
        if merged {
            guard session.canCopyMerged else {
                throw MCPToolError(.preconditionFailed, "No visible layer has pixels to copy.",
                                   hint: "Show a layer that has pixels, or paint one first.", guard: "has_pixels")
            }
            try MCPGuards.captureBrushError(session) { session.copyMergedSelection() }
            guard session.pixelClipboard?.changeCount != before else { throw nothingCopied() }
        } else {
            let layer = try ctx.optionalLayer("layer", in: document)
                ?? MCPSelectors.layer(.string(MCPSelectors.active), in: document, active: session.activeLayerID)
            try MCPGuards.requireNotPlaceholder(layer)
            try MCPGuards.requirePixels(layer)
            _ = try requireLayerRaster(layer)
            try await withPixelTarget(ctx, layer, mask: false) {
                guard session.canCopyPixels else { throw cannotEditPixels(layer, session, guard: "can_copy_pixels") }
                try MCPGuards.captureBrushError(session) { session.copySelection() }
                guard session.pixelClipboard?.changeCount != before else { throw nothingCopied() }
            }
            fields["layer_id"] = .string(layer.id.uuidString)
        }
        guard let clip = session.pixelClipboard else { throw nothingCopied() }
        fields["region"] = MCPValues.rect(CGRect(origin: clip.origin, size: CGSize(width: clip.image.width, height: clip.image.height)))
        return ok(fields)
    }

    static func pastePixels(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let x = try ctx.args.optionalDouble("x"), y = try ctx.args.optionalDouble("y")
        var position: CGPoint?
        if let x, let y {
            guard abs(x) <= maxPaintOffset, abs(y) <= maxPaintOffset else {
                throw MCPToolError.invalidArgument("'x' and 'y' must be within ±1,000,000 pixels.")
            }
            position = CGPoint(x: x, y: y)
        } else if x != nil || y != nil {
            throw MCPToolError.invalidArgument("Give both 'x' and 'y', or neither.")
        }
        let document = try ctx.editableDocument()
        let session = ctx.session
        try MCPGuards.requireLayerCapacity(document)
        guard session.canPaste else {
            throw MCPToolError(.preconditionFailed, "The clipboard holds no image to paste.", hint: "Copy pixels first with copy_pixels.",
                               guard: "clipboard")
        }
        let before = session.activeLayerID
        asOneStep(session, "Paste") {
            session.paste(at: position)
            if let id = session.activeLayerID, id != before { placeOutsideLockAllFolders(id, session: session) }
        }
        guard let id = session.activeLayerID, id != before, let layer = session.document?.layers.first(where: { $0.id == id }) else {
            throw MCPToolError(.preconditionFailed, "The clipboard's image couldn't be pasted.",
                               hint: "Copy the pixels again with copy_pixels, then retry.", guard: "clipboard")
        }
        return ctx.mutated(["layer_id": .string(id.uuidString), "name": .string(layer.name), "transform": MCPValues.transform(layer.transform)])
    }

    // MARK: Helpers

    /// The call's `target`: false for the layer's own pixels (the default), true for its mask.
    static func pixelTargetIsMask(_ args: Args) throws -> Bool {
        guard let name = try args.optionalString("target") else { return false }
        switch normalized(name) {
        case "pixels", "pixel", "layer": return false
        case "mask", "layermask": return true
        default: throw MCPToolError.invalidArgument("'target' must be pixels or mask.")
        }
    }

    static func pixelTargetName(_ mask: Bool) -> Value { .string(mask ? "mask" : "pixels") }

    /// The checks the app's pixel-edit guards (`canPaint`, `canInvert`, `canAdjustColors`, named by `guardName`) make
    /// that don't need the layer to be active, so a refused call fails before the user's layer selection is touched:
    /// not a Photoshop placeholder (checked first: import keeps one hidden and without pixels, and no other check's
    /// hint can help); pixels (or an enabled mask) of its own, and with `needsRaster` pixels already there; not
    /// locked, not hidden; and a selection, if there is one, that selects something. The lock that holds the edit is
    /// `lock`, by default Lock Pixels for the layer's pixels and Lock All for its mask: as in Photoshop and the app
    /// (`checkUnlocked(_:mask:)`), a pixel lock leaves the mask editable.
    static func requireEditablePixels(_ layer: ImageLayer, mask: Bool, in document: CanvasDocument, session: EditorSession,
                                      guard guardName: String = "can_paint", needsRaster: Bool = false, lock: LayerLocks? = nil) throws {
        try MCPGuards.requireNotPlaceholder(layer)
        if mask {
            guard let owned = layer.mask else { throw noLayerMask(layer) }
            guard owned.isEnabled else {
                throw MCPToolError(.preconditionFailed, "The mask of '\(layer.name)' is disabled.", hint: "Enable the mask first.", guard: guardName)
            }
        } else {
            try MCPGuards.requirePixels(layer)
            try requireNotSmartObject(layer)
            if needsRaster { _ = try requireLayerRaster(layer) }
        }
        try MCPGuards.requireUnlocked(layer, in: document, lock ?? (mask ? .all : .pixels))
        guard document.effectiveVisibleIDs.contains(layer.id) else {
            throw MCPToolError(.preconditionFailed, "'\(layer.name)' is hidden, or inside a hidden folder.",
                               hint: "Show it first with set_layer_visibility.", guard: guardName)
        }
        if session.selection?.isEmpty == true { throw emptySelectionError() }
    }

    /// The layer isn't a smart object: editing its pixels would turn it into plain pixels and drop its embedded file
    /// (and there is no undoing that once the history lets the entry go). Photoshop refuses too. Fails with
    /// `guard: "not_smart_object"`. Its mask can still be edited.
    static func requireNotSmartObject(_ layer: ImageLayer) throws {
        guard layer.smartObject != nil else { return }
        throw MCPToolError(.preconditionFailed,
                           "'\(layer.name)' is a smart object: editing its pixels would turn it into plain pixels and drop its embedded file.",
                           hint: "Rasterize it first with rasterize_layer, or change its contents with export_smart_object_contents and replace_smart_object_contents.",
                           guard: "not_smart_object")
    }

    /// The layer's pixels, when it has any yet (a new blank layer has none until something is painted).
    static func requireLayerRaster(_ layer: ImageLayer) throws -> ImportedImage {
        guard let asset = layer.asset else {
            throw MCPToolError(.preconditionFailed, "'\(layer.name)' has no pixels yet.", hint: "Paint or fill it first.", guard: "has_pixels")
        }
        return asset
    }

    static func noLayerMask(_ layer: ImageLayer) -> MCPToolError {
        MCPToolError(.preconditionFailed, "'\(layer.name)' has no layer mask.", hint: "Use target: pixels, or add a mask first.", guard: "has_mask")
    }

    static func emptySelectionError() -> MCPToolError {
        MCPToolError(.preconditionFailed, "The selection is empty: it selects nothing, so nothing can change.",
                     hint: "Select something, or remove the selection with select_none.", guard: "selection")
    }

    private static func nothingCopied() -> MCPToolError {
        MCPToolError(.preconditionFailed, "Nothing inside the selection could be copied.", hint: "Select an area the layer covers.",
                     guard: "selection")
    }

    static func cannotEditPixels(_ layer: ImageLayer, _ session: EditorSession, guard guardName: String) -> MCPToolError {
        MCPToolError(.preconditionFailed, MCPGuards.blockingReason(session) ?? "'\(layer.name)' can't be edited right now.",
                     hint: "Commit or cancel what is in progress with settle_pending_edits (or finish it in Compositor), then retry.",
                     guard: guardName)
    }

    /// Runs `body` with `layer` as the active layer and its pixels or mask targeted, as the app's own commands expect.
    /// When `body` fails, the user's layer selection, mask target and selected effect are put back, so later '@active'
    /// calls act on the layer they did before.
    static func withPixelTarget<T>(_ ctx: MCPCallContext, _ layer: ImageLayer, mask: Bool, _ body: () async throws -> T) async throws -> T {
        let session = ctx.session
        let before = (selected: session.selectedLayerIDs, active: session.activeLayerID, mask: session.isMaskSelected,
                      effect: session.effectSelection)
        do {
            session.selectLayer(layer.id)
            session.isMaskSelected = mask
            guard session.activeLayerID == layer.id else { throw cannotEditPixels(layer, session, guard: "can_edit_layers") }
            return try await body()
        } catch {
            session.selectLayers(before.selected, primary: before.active)
            session.isMaskSelected = before.mask
            session.effectSelection = before.effect
            throw error
        }
    }

    /// Runs a runHeadlessEdit session pixel edit, turning its refusal into `precondition_failed`.
    static func runHeadlessEdit<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as PixelEditError {
            throw MCPToolError(.preconditionFailed, error.message,
                               hint: "Check the layer with get_layer (visible, with pixels or an enabled mask) and that the selection isn't empty, then retry.",
                               guard: "can_paint")
        }
    }

    /// `layer` as the document holds it now, after an `await`; fails when it was deleted or edits are blocked meanwhile.
    static func layerAfterReading(_ layer: ImageLayer, _ ctx: MCPCallContext) throws -> ImageLayer {
        let document = try ctx.editableDocument()
        guard let current = document.layers.first(where: { $0.id == layer.id }) else {
            throw MCPToolError.notFound("'\(layer.name)' was deleted while the image was read.")
        }
        return current
    }

    /// An image file's pixels, with the importer's failures as tool errors.
    static func decodeImageFile(_ url: URL) async throws -> ImportedImage {
        do {
            return try await ImageImporter.shared.decode(url)
        } catch let error as ImageImportError {
            let path: [String: Value] = ["path": .string(url.path)]
            switch error {
            case .unreadable:
                throw MCPToolError(.ioError, "\(url.lastPathComponent) couldn't be read as an image.", details: path)
            case .unsupported:
                throw MCPToolError(.unsupported, "\(url.lastPathComponent) isn't a PNG, JPEG, HEIC or TIFF image.", details: path)
            case .tooLarge:
                throw MCPToolError(.preconditionFailed, error.localizedDescription,
                                   hint: "Use an image of at most \(DocumentLimits.maxSurfaceMegapixels) megapixels and \(DocumentLimits.maxSide.formatted()) pixels a side.",
                                   guard: "pixel_budget")
            }
        }
    }

    /// The call's `key` points: `count` of them, each `{x, y}` within a million pixels of the origin.
    static func pointArray(_ args: Args, _ key: String, count: ClosedRange<Int>) throws -> [CGPoint] {
        guard let value = args[key] else { throw MCPToolError.invalidArgument("Missing '\(key)': an array of points {x, y}.") }
        guard let list = value.arrayValue else { throw MCPToolError.invalidArgument("'\(key)' must be an array of points {x, y}.") }
        guard count.contains(list.count) else {
            throw MCPToolError.invalidArgument("'\(key)' has \(list.count) points; it takes \(count.lowerBound)–\(count.upperBound).")
        }
        return try list.enumerated().map { index, value in
            guard let point = MCPValues.point(from: value), abs(point.x) <= maxPaintOffset, abs(point.y) <= maxPaintOffset else {
                throw MCPToolError.invalidArgument("'\(key)[\(index)]' must be a point {x, y} of numbers within ±1,000,000.")
            }
            return point
        }
    }

    static func pointArgument(_ args: Args, _ key: String) throws -> CGPoint {
        guard let value = args[key] else { throw MCPToolError.invalidArgument("Missing '\(key)': a point {x, y} in document pixels.") }
        guard let point = MCPValues.point(from: value), abs(point.x) <= maxPaintOffset, abs(point.y) <= maxPaintOffset else {
            throw MCPToolError.invalidArgument("'\(key)' must be a point {x, y} of numbers within ±1,000,000.")
        }
        return point
    }
}
