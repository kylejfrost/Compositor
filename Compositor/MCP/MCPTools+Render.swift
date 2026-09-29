import CoreGraphics
import Foundation
import MCP

// MARK: - Render & inspect

extension MCPToolRegistry {
    /// Output options every render tool takes.
    static let previewProperties: [String: Value] = [
        "max_size": MCPSchema.int("Longest side of the returned image; larger renders scale down.",
                                  min: MCPRenderOptions.maxSizeRange.lowerBound, max: MCPRenderOptions.maxSizeRange.upperBound,
                                  default: MCPRenderOptions.defaultMaxSize),
        "format": MCPSchema.enumString("Image format.", ["png", "jpeg"], default: "png"),
        "quality": MCPSchema.num("JPEG quality.", min: 0, max: 1, default: MCPRenderOptions.defaultQuality),
        "background": MCPSchema.enumString("Behind transparent pixels; default transparent (PNG) or white (JPEG).",
                                           MCPRender.Background.allCases.map(\.rawValue)),
    ]

    static let renderTools: [MCPToolEntry] = [
        tool("render_document", title: "Render document",
             description: "Renders the document's composite as export draws it and returns it as an image, then JSON: width, height, scale, document size, format and bytes. Nothing is written; export_image writes files.",
             properties: previewProperties,
             effect: .readOnly, handler: renderDocument),
        tool("render_region", title: "Render region",
             description: "Renders part of the composite at full detail, a rectangle or the selection's bounds, and returns it as an image, then JSON with the region rendered.",
             properties: previewProperties.merging([
                 "region": MCPSchema.anyOf([
                     MCPSchema.rect("A rectangle in document pixels."),
                     MCPSchema.enumString("The bounds of the current selection.", ["selection"]),
                 ], description: "A rectangle, or \"selection\" for its bounds; clamped to the canvas."),
                 "padding": MCPSchema.num("Pixels added around the region.", min: 0,
                                          max: Double(DocumentLimits.maxSide), default: 0),
             ]) { _, new in new },
             required: ["region"], effect: .readOnly, handler: renderRegion),
        tool("render_layer", title: "Render layer",
             description: "Renders one layer, or a folder's contents, by itself, even when hidden, with nothing below it and no clipping base, and returns it as an image. Adjustment layers show nothing alone and are unsupported.",
             properties: previewProperties.merging([
                 "layer": MCPSchema.layerSelector(),
                 "include_effects": MCPSchema.bool("Draw its effects.", default: true),
                 "include_mask": MCPSchema.bool("Apply its mask.", default: true),
                 "crop": MCPSchema.enumString("layer: the box it draws in, effects included; canvas: the whole canvas.", ["layer", "canvas"], default: "layer"),
             ]) { _, new in new },
             required: ["layer"], effect: .readOnly, handler: renderLayer),
        tool("get_layer_bounds", title: "Get layer bounds",
             description: "Reports where a layer sits in document pixels: transform, corners, upright bounds, effects_bounds, content_bounds around its visible pixels, mask placement, and text metrics. A folder reports the union of what it shows.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "content": MCPSchema.bool("Also scan pixels for content_bounds.", default: true),
             ],
             required: ["layer"], effect: .readOnly, handler: getLayerBounds),
        tool("get_pixel_color", title: "Get pixel color",
             description: "Reads one document pixel's color as {r, g, b, a} in 0–1 and hex, from the composite or (source layer) from the layer's own pixels. For several pixels, call sample_colors once.",
             properties: [
                 "x": MCPSchema.num("Column (floored)."),
                 "y": MCPSchema.num("Row (floored)."),
                 "source": MCPSchema.enumString("Where to read.", ["composite", "layer"], default: "composite"),
                 "layer": MCPSchema.layerSelector("For source 'layer', the layer to read (default the active layer)"),
             ],
             required: ["x", "y"], effect: .readOnly, handler: getPixelColor),
        tool("sample_colors", title: "Sample colors",
             description: "Reads up to \(MCPRenderOptions.maxSamplePoints) document pixels' colors at once, as get_pixel_color reports them, in the order given.",
             properties: [
                 "points": MCPSchema.arr("Points to read.", items: MCPSchema.point("A document pixel."),
                                         minItems: 1, maxItems: MCPRenderOptions.maxSamplePoints),
                 "source": MCPSchema.enumString("Where to read.", ["composite", "layer"], default: "composite"),
                 "layer": MCPSchema.layerSelector("For source 'layer', the layer to read (default the active layer)"),
             ],
             required: ["points"], effect: .readOnly, handler: sampleColors),
    ]

    // MARK: Rendering

    static func renderDocument(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let snapshot = try projectSnapshot(ctx)
        return try await preview(ctx, snapshot: snapshot, region: nil, isolating: nil)
    }

    static func renderRegion(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let document = try ctx.document()
        let area = try region(ctx, in: document)
        let snapshot = try projectSnapshot(ctx)
        return try await preview(ctx, snapshot: snapshot, region: area, isolating: nil, fields: ["region": MCPValues.rect(area)])
    }

    static func renderLayer(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let document = try ctx.document()
        let layer = try ctx.layer(in: document)
        if layer.adjustment != nil { throw MCPRender.adjustmentUnsupported(layer.name) }
        let includeEffects = try ctx.args.bool("include_effects", default: true)
        let includeMask = try ctx.args.bool("include_mask", default: true)
        let crop = try ctx.args.string("crop", default: "layer")
        guard crop == "layer" || crop == "canvas" else { throw MCPToolError.invalidArgument("crop must be 'layer' or 'canvas'.") }
        let snapshot = try projectSnapshot(ctx)
        let records = try MCPRender.isolated(layer.id, in: snapshot, includeEffects: includeEffects, includeMask: includeMask)
        guard let drawn = MCPRender.drawnBounds(records, images: snapshot.images).map(MCPRender.pixelAligned), drawn.width >= 1, drawn.height >= 1 else {
            throw MCPRender.nothingToDraw(layer.name)
        }
        let area = crop == "canvas" ? CGRect(x: 0, y: 0, width: document.width, height: document.height) : drawn
        return try await preview(ctx, snapshot: snapshot, region: area, isolating: layer.id,
                                 includeEffects: includeEffects, includeMask: includeMask,
                                 fields: ["region": MCPValues.rect(area), "layer_id": .string(layer.id.uuidString), "crop": .string(crop)])
    }

    /// Renders off the main actor, scales and encodes the image, and returns the image block followed by the
    /// JSON block. Nothing is written to disk: export_image does that.
    private static func preview(_ ctx: MCPCallContext, snapshot: ProjectSnapshot, region: CGRect?, isolating layer: UUID?,
                                includeEffects: Bool = true, includeMask: Bool = true,
                                fields: [String: Value] = [:]) async throws -> CallTool.Result {
        let options = try MCPRenderOptions(ctx.args)
        let maxSize = options.maxSize, format = options.format, quality = options.quality, background = options.background
        let started = ContinuousClock.now
        let rendered = try await Task.detached(priority: .userInitiated) {
            let image = try await MCPRender.composite(snapshot, region: region, isolating: layer,
                                                      includeEffects: includeEffects, includeMask: includeMask)
            let (scaled, scale) = try MCPRender.downscaled(image, maxSize: maxSize)
            let data = try MCPRender.encode(scaled, format: format, quality: quality, background: background)
            return MCPRender.Preview(data: data, width: scaled.width, height: scaled.height, scale: Double(scale),
                                     sourceWidth: image.width, sourceHeight: image.height)
        }.value
        DocumentLog.rendered(width: rendered.sourceWidth, height: rendered.sourceHeight, layers: snapshot.manifest.layers.count,
                             bytes: rendered.data.count, startedAt: started)
        var out = fields
        out["width"] = .int(rendered.width)
        out["height"] = .int(rendered.height)
        out["scale"] = .double(rendered.scale)
        out["scale_x"] = .double(rendered.scaleX)
        out["scale_y"] = .double(rendered.scaleY)
        out["document_width"] = .int(snapshot.manifest.width)
        out["document_height"] = .int(snapshot.manifest.height)
        out["format"] = .string(format.rawValue)
        out["bytes"] = .int(rendered.data.count)
        return imageResult(MCPRender.imageContent(rendered.data, format: format), out)
    }

    /// A success result whose content is `image` first, then the usual JSON text block.
    static func imageResult(_ image: Tool.Content, _ fields: [String: Value]) -> CallTool.Result {
        let json = ok(fields)
        return CallTool.Result(content: [image] + json.content, structuredContent: json.structuredContent, isError: json.isError)
    }

    /// The canvas area `render_region` covers: its `region` (a rectangle or the selection's bounds) grown by
    /// `padding`, rounded out to whole pixels and clamped to the canvas.
    private static func region(_ ctx: MCPCallContext, in document: CanvasDocument) throws -> CGRect {
        guard let value = ctx.args["region"] else {
            throw MCPToolError.invalidArgument("Missing 'region': a rectangle {x, y, width, height} or \"selection\".")
        }
        let padding = try ctx.args.double("padding", default: 0)
        guard (0...DocumentLimits.maxSideExtent).contains(padding) else { throw MCPToolError.invalidArgument("padding must be 0–\(DocumentLimits.maxSide).") }
        let rect: CGRect
        if let text = value.stringValue {
            guard text == "selection" else {
                throw MCPToolError.invalidArgument("'region' must be a rectangle {x, y, width, height} or \"selection\".")
            }
            guard let selection = document.selection, !selection.isEmpty else {
                throw MCPToolError(.preconditionFailed, "Nothing is selected.",
                                   hint: "Pass a rectangle as 'region' instead.", guard: "selection")
            }
            rect = selection.path.boundingBoxOfPath
        } else {
            guard let given = MCPValues.rect(from: value), given.width > 0, given.height > 0,
                  [given.minX, given.minY, given.maxX, given.maxY].allSatisfy({ abs($0) <= 1_000_000 }) else {
                throw MCPToolError.invalidArgument("'region' must be {x, y, width, height} with a positive width and height.")
            }
            rect = given
        }
        let canvas = CGRect(x: 0, y: 0, width: document.width, height: document.height)
        let area = rect.insetBy(dx: -padding, dy: -padding).integral.intersection(canvas)
        guard !area.isNull, area.width >= 1, area.height >= 1 else {
            throw MCPToolError.invalidArgument("The region lies outside the \(document.width)×\(document.height) canvas.")
        }
        return area
    }

    // MARK: Bounds

    static func getLayerBounds(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let document = try ctx.document()
        let layer = try ctx.layer(in: document)
        let scanContent = try ctx.args.bool("content", default: true)
        var out: [String: Value] = ["layer": MCPValues.candidate(layer, in: document)]

        // The layers whose pixels make up the box: the layer itself, or a folder's pixel layers.
        let parts: [ImageLayer]
        if layer.isGroup {
            // What render_layer draws: descendants visible within the folder (the folder itself counts as shown).
            let records = try MCPRender.isolated(layer.id, in: document.layers.map { ProjectLayerRecord(layer: $0) },
                                                 includeEffects: true, includeMask: true)
            let shown = Set(LayerHierarchy.visibleLayers(records).filter { $0.adjustment == nil }.map(\.id))
            parts = document.layers.filter { shown.contains($0.id) }
            out["layer_count"] = .int(parts.count)
        } else {
            parts = [layer]
            out["transform"] = MCPValues.transform(layer.transform)
            out["corners"] = .array(MCPRender.corners(of: layer.transform).map(MCPValues.point))
            if let image = layer.asset?.image {
                out["pixel_width"] = .int(image.width)
                out["pixel_height"] = .int(image.height)
            }
        }
        func union(_ rects: [CGRect]) -> Value {
            rects.dropFirst().reduce(rects.first) { $0?.union($1) }.map(MCPValues.rect) ?? .null
        }
        out["bounds"] = union(parts.map { MCPRender.box(of: $0.transform) })
        if parts.contains(where: { $0.effects.map { !$0.visible.isEmpty } == true }) {
            out["effects_bounds"] = union(parts.map { MCPRender.drawnBox($0.transform, image: $0.asset?.image, effects: $0.effects) })
        }

        if scanContent {
            let jobs = parts.compactMap { part in part.asset.map { (asset: $0, transform: part.transform) } }
            let found = try await Task.detached(priority: .userInitiated) {
                try jobs.map { try ContentBounds.pixelBounds(of: $0.asset.image) }
            }.value
            var boxes: [CGRect] = []
            for (job, pixels) in zip(jobs, found) {
                guard let pixels else { continue }
                boxes.append(MCPRender.documentBox(ofPixels: pixels, transform: job.transform,
                                                   width: job.asset.image.width, height: job.asset.image.height))
                if !layer.isGroup { out["pixel_content_bounds"] = MCPValues.rect(pixels) }
            }
            out["content_bounds"] = union(boxes)
            if !layer.isGroup, out["pixel_content_bounds"] == nil { out["pixel_content_bounds"] = .null }
        }

        if let mask = layer.mask {
            let placement = mask.placement ?? layer.transform
            out["mask"] = .object([
                "enabled": .bool(mask.isEnabled),
                "linked": .bool(mask.isLinked),
                "bounds": MCPValues.rect(MCPRender.box(of: placement)),
                "pixel_width": .int(mask.asset.image.width),
                "pixel_height": .int(mask.asset.image.height),
            ])
        }
        if let text = layer.liveText { out["text"] = textMetrics(text, transform: layer.transform) }
        return ok(out)
    }

    private static func textMetrics(_ text: LayerText, transform: LayerTransform) -> Value {
        let style = text.style
        var out: [String: Value] = [
            "content": .string(style.content),
            "font_name": .string(style.fontName),
            "font_size": .double(Double(style.fontSize)),
            "line_height": .double(Double(style.lineHeight)),
            "tracking": .double(Double(style.tracking)),
            "alignment": .string(style.alignment.rawValue.lowercased()),
            "line_count": .int(style.content.split(separator: "\n", omittingEmptySubsequences: false).count),
            "padding": .double(Double(LayerTextStyle.padding)),
            "scale_x": .double(Double(transform.size.width) / Double(max(1, text.image.width))),
            "scale_y": .double(Double(transform.size.height) / Double(max(1, text.image.height))),
        ]
        out["box"] = style.boxSize.map { .object(["width": .double(Double($0.width)), "height": .double(Double($0.height))]) } ?? .null
        return .object(out)
    }

    // MARK: Colors

    static func getPixelColor(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let x = try ctx.args.double("x"), y = try ctx.args.double("y")
        let sampled = try await colors(ctx, at: [try pixel(x, y)])
        var out = sampled.fields
        out.merge(sampled.colors[0]) { _, new in new }
        return ok(out)
    }

    static func sampleColors(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        guard let items = ctx.args["points"]?.arrayValue else {
            throw MCPToolError.invalidArgument("'points' must be an array of {x, y}.")
        }
        guard (1...MCPRenderOptions.maxSamplePoints).contains(items.count) else {
            throw MCPToolError.invalidArgument("'points' must hold 1–\(MCPRenderOptions.maxSamplePoints) points; got \(items.count).")
        }
        let points = try items.enumerated().map { index, item in
            guard let point = MCPValues.point(from: item) else {
                throw MCPToolError.invalidArgument("points[\(index)] must be {x, y} of numbers.")
            }
            return try pixel(point.x, point.y)
        }
        let sampled = try await colors(ctx, at: points)
        var out = sampled.fields
        out["colors"] = .array(sampled.colors.map { .object($0) })
        return ok(out)
    }

    /// A document pixel from coordinates, floored.
    private static func pixel(_ x: Double, _ y: Double) throws -> (x: Int, y: Int) {
        guard abs(x) <= 1_000_000, abs(y) <= 1_000_000 else {
            throw MCPToolError.invalidArgument("x and y must lie within ±1000000 document pixels.")
        }
        return (Int(x.rounded(.down)), Int(y.rounded(.down)))
    }

    /// Each point's color from the `source` argument, and the fields describing that source.
    private static func colors(_ ctx: MCPCallContext, at points: [(x: Int, y: Int)]) async throws
        -> (fields: [String: Value], colors: [[String: Value]]) {
        let document = try ctx.document()
        let source = try ctx.args.string("source", default: "composite")
        switch source {
        case "composite":
            if let outside = points.first(where: { !(0..<document.width).contains($0.x) || !(0..<document.height).contains($0.y) }) {
                throw MCPToolError.invalidArgument("(\(outside.x), \(outside.y)) is outside the \(document.width)×\(document.height) canvas.")
            }
            let snapshot = try projectSnapshot(ctx)
            let samples = try await Task.detached(priority: .userInitiated) {
                let image = try await MCPRender.composite(snapshot, region: nil, isolating: nil, includeEffects: true, includeMask: true)
                let pixels = try MCPRender.Pixels(image)
                return points.map { pixels.sample(x: $0.x, y: $0.y) ?? MCPRender.Sample() }
            }.value
            return (["source": .string(source)], zip(points, samples).map { color($1, x: $0.x, y: $0.y) })
        case "layer":
            let layer = try ctx.optionalLayer("layer", in: document)
                ?? MCPSelectors.layer(.string(MCPSelectors.active), in: document, active: ctx.session.activeLayerID)
            try MCPGuards.requirePixels(layer)
            let fields: [String: Value] = ["source": .string(source), "layer_id": .string(layer.id.uuidString)]
            let transform = layer.transform
            guard let asset = layer.asset else {
                // A blank layer holds no pixels yet: transparent wherever it is.
                return (fields, points.map { point in
                    var out = color(MCPRender.Sample(), x: point.x, y: point.y)
                    out["inside"] = .bool(transform.contains(CGPoint(x: CGFloat(point.x) + 0.5, y: CGFloat(point.y) + 0.5)))
                    return out
                })
            }
            let found = try await Task.detached(priority: .userInitiated) {
                let pixels = try MCPRender.Pixels(asset.image)
                return points.map { point -> (pixel: (x: Int, y: Int)?, sample: MCPRender.Sample) in
                    guard let pixel = MCPRender.layerPixel(x: point.x, y: point.y, transform: transform,
                                                           width: pixels.width, height: pixels.height) else {
                        return (nil, MCPRender.Sample())
                    }
                    return (pixel, pixels.sample(x: pixel.x, y: pixel.y) ?? MCPRender.Sample())
                }
            }.value
            return (fields, zip(points, found).map { point, found in
                var out = color(found.sample, x: point.x, y: point.y)
                out["inside"] = .bool(found.pixel != nil)
                if let pixel = found.pixel {
                    out["layer_x"] = .int(pixel.x)
                    out["layer_y"] = .int(pixel.y)
                }
                return out
            })
        default:
            throw MCPToolError.invalidArgument("source must be 'composite' or 'layer'.")
        }
    }

    private static func color(_ sample: MCPRender.Sample, x: Int, y: Int) -> [String: Value] {
        [
            "x": .int(x),
            "y": .int(y),
            "r": .double(Double(sample.red) / 255),
            "g": .double(Double(sample.green) / 255),
            "b": .double(Double(sample.blue) / 255),
            "a": .double(Double(sample.alpha) / 255),
            "hex": .string(sample.hex),
        ]
    }
}

/// The output options of a render tool (and export_image's scaling and background), read and checked before
/// anything is rendered.
@MainActor
struct MCPRenderOptions {
    static let maxSizeRange = 16...4096
    static let defaultMaxSize = 1024
    static let defaultQuality = 0.85
    static let maxSamplePoints = 256

    let maxSize: Int
    let format: MCPRender.Format
    let quality: Double
    let background: MCPRender.Background

    init(_ args: MCPToolRegistry.Args) throws {
        maxSize = try args.int("max_size", default: Self.defaultMaxSize)
        try Self.checkMaxSize(maxSize)
        quality = try args.double("quality", default: Self.defaultQuality)
        guard (0...1).contains(quality) else { throw MCPToolError.invalidArgument("quality must be 0–1.") }
        format = try args.optionalString("format").map { raw in
            guard let format = Self.format(raw) else { throw MCPToolError.invalidArgument("Unsupported format '\(raw)'; use png or jpeg.") }
            return format
        } ?? .png
        background = try Self.background(args, format: format)
    }

    static func checkMaxSize(_ maxSize: Int) throws {
        guard maxSizeRange.contains(maxSize) else {
            throw MCPToolError.invalidArgument("max_size must be \(maxSizeRange.lowerBound)–\(maxSizeRange.upperBound).")
        }
    }

    /// The `background` argument: transparent for PNG and white for JPEG by default; JPEG can't be transparent.
    static func background(_ args: MCPToolRegistry.Args, format: MCPRender.Format) throws -> MCPRender.Background {
        guard let name = try args.optionalString("background") else { return format == .jpeg ? .white : .transparent }
        guard let background = MCPRender.Background(rawValue: name.lowercased()) else {
            throw MCPToolError.invalidArgument("background must be one of \(MCPRender.Background.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        if format == .jpeg, background == .transparent {
            throw MCPToolError.invalidArgument("JPEG has no transparency; choose white, black or checkerboard, or use png.")
        }
        return background
    }

    static func format(_ name: String) -> MCPRender.Format? {
        switch name.lowercased() {
        case "png": .png
        case "jpg", "jpeg": .jpeg
        default: nil
        }
    }
}
