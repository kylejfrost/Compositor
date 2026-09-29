import CoreGraphics
import Foundation
import MCP

// MARK: - Canvas and guides

extension MCPToolRegistry {
    static let canvasTools: [MCPToolEntry] = [
        tool("resize_canvas", title: "Resize canvas",
             description: "Changes the canvas size without scaling anything (Canvas Size): layers and guides move with the anchor. relative adds width and height to the current size; 'fill' paints the added border into a new bottom layer. Returns the size and offset, how far content moved.",
             properties: [
                 "width": MCPSchema.int("New width, or with relative the pixels to add.",
                                        min: -DocumentLimits.maxSide, max: DocumentLimits.maxSide),
                 "height": MCPSchema.int("New height, or with relative the pixels to add.",
                                         min: -DocumentLimits.maxSide, max: DocumentLimits.maxSide),
                 "anchor": MCPSchema.anyOf([
                     MCPSchema.int("Anchor index.", min: 0, max: 8, default: 4),
                     MCPSchema.enumString("Anchor name.", anchorNames),
                 ], description: "The point of the old canvas that stays put: 0–8 from top-left to bottom-right in rows (4 center, the default), or a name such as \"top_left\"."),
                 "relative": MCPSchema.bool("Add to the current size.", default: false),
                 "fill": MCPSchema.color("Color for the added border (default transparent)."),
             ],
             required: ["width", "height"], effect: .additive(idempotent: false), handler: resizeCanvas),
        tool("resize_image", title: "Resize image",
             description: "Scales the whole image, every layer and mask (Image Size), to width and height, one of them (keeping the aspect ratio) or percent. Live text and shapes stay editable; other pixels resample with 'sampling'. 'resolution' sets the stored pixels per inch.",
             properties: [
                 "width": MCPSchema.int("New width in pixels.", min: 1, max: DocumentLimits.maxSide),
                 "height": MCPSchema.int("New height in pixels.", min: 1, max: DocumentLimits.maxSide),
                 "percent": MCPSchema.num("Scale both sides by this percentage.", exclusiveMin: 0,
                                          max: 10_000),
                 "resolution": MCPSchema.num("Stored pixels per inch.", min: 1, max: 9600),
                 "sampling": MCPSchema.enumString("Resampling.", ["nearest", "smooth", "high"], default: "high"),
             ],
             effect: .additive(idempotent: false), handler: resizeImage),
        tool("set_resolution", title: "Set resolution",
             description: "Sets the pixels per inch stored with the document, changing no pixels.",
             properties: ["resolution": MCPSchema.num("Pixels per inch.", min: 1, max: 9600)],
             required: ["resolution"], effect: .additive(idempotent: true), handler: setResolution),
        tool("crop", title: "Crop",
             description: "Crops the canvas to a rectangle, rounded to whole pixels, as the Crop tool does: layers keep all their pixels, and a rectangle past the canvas extends it with transparency.",
             properties: ["rect": MCPSchema.rect("The area to keep.")],
             required: ["rect"], effect: .destructive(idempotent: false), handler: crop),
        tool("trim_canvas", title: "Trim canvas",
             description: "Crops the canvas to the box around pixels that aren't transparent, plus 'padding', measuring every shown layer or only 'layers'. Masks and effects aren't measured; fails when nothing is drawn.",
             properties: [
                 "padding": MCPSchema.int("Margin around the content.", min: 0, max: DocumentLimits.maxSide, default: 0),
                 "layers": MCPSchema.layerSelectors("Measure only these"),
             ],
             effect: .destructive(idempotent: false), handler: trimCanvas),
        tool("flip_canvas", title: "Flip canvas",
             description: "Mirrors the whole document horizontally or vertically: every layer and mask, the selection and the guides.",
             properties: ["axis": MCPSchema.enumString("Mirror axis.", ["horizontal", "vertical"])],
             required: ["axis"], effect: .additive(idempotent: false), handler: flipCanvas),
        tool("add_guide", title: "Add guide",
             description: "Adds a horizontal guide at a document y, or a vertical one at an x, and returns its id. Refused while guides are locked in the app, and past 1000 guides.",
             properties: [
                 "axis": MCPSchema.enumString("Which way it runs.", ["horizontal", "vertical"]),
                 "position": MCPSchema.num("y for a horizontal guide, x for a vertical one."),
             ],
             required: ["axis", "position"], effect: .additive(idempotent: false), handler: addGuide),
        tool("remove_guide", title: "Remove guide",
             description: "Removes one guide by its id; refused while guides are locked in the app.",
             properties: ["guide_id": MCPSchema.str("The guide id.")],
             required: ["guide_id"], effect: .destructive(idempotent: false), handler: removeGuide),
        tool("clear_guides", title: "Clear guides",
             description: "Removes every guide, even while guides are locked.",
             effect: .destructive(idempotent: false), handler: clearGuides),
        tool("list_guides", title: "List guides",
             description: "Lists the guides as {id, axis, position}, and whether guides are shown and locked in the app.",
             effect: .readOnly, handler: listGuides),
    ]

    // MARK: Canvas and image size

    static func resizeCanvas(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let document = try ctx.document()
        let relative = try ctx.args.bool("relative", default: false)
        // Bounded before adding, so a huge value can't overflow: no canvas side, or change to one, exceeds
        // DocumentLimits.maxSide.
        let givenWidth = try ctx.args.int("width"), givenHeight = try ctx.args.int("height")
        let side = -DocumentLimits.maxSide...DocumentLimits.maxSide
        guard side.contains(givenWidth), side.contains(givenHeight) else {
            throw MCPToolError.invalidArgument("width and height must be within ±\(DocumentLimits.maxSide) pixels (the canvas must end up 1–\(DocumentLimits.maxSide) on each side).")
        }
        let width = givenWidth + (relative ? document.width : 0)
        let height = givenHeight + (relative ? document.height : 0)
        guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height) else {
            throw MCPToolError.invalidArgument("The canvas must end up 1–\(DocumentLimits.maxSide) pixels on each side; that makes it \(width)×\(height).")
        }
        let anchor = try canvasAnchor(ctx)
        let fill = try ctx.args.color("fill").map { CanvasExtensionColor(red: $0.red, green: $0.green, blue: $0.blue) }
        // A colored border is a layer of its own.
        if fill != nil, width > document.width || height > document.height { try MCPGuards.requireLayerCapacity(document) }
        try requireSettledDocument(ctx.session)
        let options = CanvasSizeOptions(width: width, height: height, anchor: anchor, fill: fill)
        if width != document.width || height != document.height {
            try await resizeDocument(ctx, name: "Canvas Size") { try await CanvasResizer.shared.resize($0, to: options) }
        }
        return ctx.mutated(["width": .int(width), "height": .int(height),
                            "offset": MCPValues.point(options.offset(fromWidth: document.width, height: document.height))])
    }

    static func resizeImage(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let document = try ctx.document()
        let width = try ctx.args.optionalInt("width"), height = try ctx.args.optionalInt("height")
        let percent = try ctx.args.optionalDouble("percent")
        let resolution = try ctx.args.optionalDouble("resolution") ?? document.resolution
        let sampling = try samplingArgument(ctx)
        guard (1...9600).contains(resolution) else { throw MCPToolError.invalidArgument("resolution must be 1–9600 pixels per inch.") }
        for side in [width, height].compactMap({ $0 }) where !(1...DocumentLimits.maxSide).contains(side) {
            throw MCPToolError.invalidArgument("width and height must be 1–\(DocumentLimits.maxSide) pixels.")
        }
        func scaled(_ side: Int, _ factor: Double) -> Int { max(1, Int((Double(side) * factor).rounded())) }
        let size: (width: Int, height: Int)
        switch (width, height, percent) {
        case (nil, nil, let percent?):
            guard percent > 0, percent <= 10_000 else { throw MCPToolError.invalidArgument("percent must be above 0 and at most 10000.") }
            size = (scaled(document.width, percent / 100), scaled(document.height, percent / 100))
        case (_, _, _?):
            throw MCPToolError.invalidArgument("Give percent, or width and/or height, not both.")
        case let (width?, height?, nil):
            size = (width, height)
        case let (width?, nil, nil):
            size = (width, scaled(document.height, Double(width) / Double(document.width)))
        case let (nil, height?, nil):
            size = (scaled(document.width, Double(height) / Double(document.height)), height)
        case (nil, nil, nil):
            guard ctx.args.has("resolution") else {
                throw MCPToolError.invalidArgument("Give width, height, percent or resolution.")
            }
            size = (document.width, document.height)
        }
        guard (1...DocumentLimits.maxSide).contains(size.width), (1...DocumentLimits.maxSide).contains(size.height) else {
            throw MCPToolError.invalidArgument("The image must end up 1–\(DocumentLimits.maxSide) pixels on each side; that makes it \(size.width)×\(size.height).")
        }
        try requireSettledDocument(ctx.session)
        if size.width == document.width, size.height == document.height {
            setDocumentResolution(resolution, ctx.session)
        } else {
            let options = ImageSizeOptions(width: size.width, height: size.height, resolution: resolution, sampling: sampling)
            try await resizeDocument(ctx, name: "Image Size") { try await ImageResizer.shared.resize($0, to: options) }
        }
        return ctx.mutated(["width": .int(size.width), "height": .int(size.height), "resolution": .double(resolution)])
    }

    static func setResolution(_ ctx: MCPCallContext) throws -> CallTool.Result {
        _ = try ctx.document()
        let resolution = try ctx.args.double("resolution")
        guard (1...9600).contains(resolution) else { throw MCPToolError.invalidArgument("resolution must be 1–9600 pixels per inch.") }
        try requireSettledDocument(ctx.session)
        setDocumentResolution(resolution, ctx.session)
        return ctx.mutated(["resolution": .double(resolution)])
    }

    // MARK: Crop and trim

    static func crop(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let document = try ctx.document()
        guard let value = ctx.args["rect"] else { throw MCPToolError.invalidArgument("Missing 'rect' ({x, y, width, height}).") }
        guard let given = MCPValues.rect(from: value), given.width > 0, given.height > 0 else {
            throw MCPToolError.invalidArgument("rect must be {x, y, width, height} with a positive width and height.")
        }
        let rect = CropGeometry.snapped(given)
        guard CropGeometry.valid(rect) else {
            throw MCPToolError.invalidArgument("The crop must be 1–\(DocumentLimits.maxSide) pixels on each side and within ±1,000,000 pixels of the canvas.")
        }
        try requireSettledDocument(ctx.session)
        if rect != CGRect(origin: .zero, size: document.size) {
            let options = cropOptions(rect)
            try await resizeDocument(ctx, name: "Crop") { try await CanvasResizer.shared.resize($0, to: options) }
        }
        return ctx.mutated(["width": .int(Int(rect.width)), "height": .int(Int(rect.height)), "rect": MCPValues.rect(rect)])
    }

    static func trimCanvas(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let document = try ctx.document()
        let padding = try ctx.args.int("padding", default: 0)
        guard (0...DocumentLimits.maxSide).contains(padding) else { throw MCPToolError.invalidArgument("padding must be 0–\(DocumentLimits.maxSide) pixels.") }
        let jobs = try trimmedLayers(ctx, in: document).compactMap { layer in
            layer.asset.map { (asset: $0, transform: layer.transform) }
        }
        let session = ctx.session
        try requireSettledDocument(session)
        let snapshot = try projectSnapshot(ctx)
        let canvas = CGRect(origin: .zero, size: document.size)
        // Measuring and resizing both run while the document is marked busy, so what is cropped is what was measured.
        let (rect, resized) = try await MCPGuards.withProjectBusy(session) { () async throws -> (CGRect, ProjectSnapshot?) in
            let boxes = try await Task.detached(priority: .userInitiated) {
                try jobs.compactMap { job -> CGRect? in
                    let image = job.asset.image
                    return try ContentBounds.pixelBounds(of: image).map {
                        MCPRender.documentBox(ofPixels: $0, transform: job.transform, width: image.width, height: image.height)
                    }
                }
            }.value
            // Each layer's box is clipped to the canvas before the union, so a layer lying wholly off the canvas adds
            // nothing (null and empty pieces drop out; the union of none is null).
            let drawn = boxes.map { $0.intersection(canvas) }.filter { !$0.isNull && !$0.isEmpty }
                .reduce(CGRect.null) { $0.union($1) }
            guard !drawn.isNull, !drawn.isEmpty else {
                throw MCPToolError(.preconditionFailed, "Nothing is drawn on the canvas there, so there is nothing to trim to.",
                                   hint: "Trim measures the pixels of the layers shown (or of 'layers') that aren't fully transparent.",
                                   guard: "has_pixels")
            }
            // Whole pixels around the content; a millionth of a pixel either way is rounding from measuring turned layers.
            let pad = CGFloat(padding)
            let left = floor(drawn.minX + 1e-6) - pad, top = floor(drawn.minY + 1e-6) - pad
            let rect = CGRect(x: left, y: top, width: ceil(drawn.maxX - 1e-6) + pad - left, height: ceil(drawn.maxY - 1e-6) + pad - top)
            guard CropGeometry.valid(rect) else {
                throw MCPToolError.invalidArgument("With that padding the canvas would be over \(DocumentLimits.maxSide) pixels on a side.")
            }
            guard rect != canvas else { return (rect, nil) }
            return (rect, try await CanvasResizer.shared.resize(snapshot, to: cropOptions(rect)))
        }
        if let resized { try install(resized, name: "Trim", ctx) }
        return ctx.mutated(["width": .int(Int(rect.width)), "height": .int(Int(rect.height)), "rect": MCPValues.rect(rect)])
    }

    // MARK: Flipping

    static func flipCanvas(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let horizontally: Bool
        switch normalized(try ctx.args.string("axis")) {
        case "horizontal": horizontally = true
        case "vertical": horizontally = false
        default: throw MCPToolError.invalidArgument("axis must be horizontal or vertical.")
        }
        _ = try ctx.editableDocument()
        ctx.session.flipCanvas(horizontally: horizontally)
        return ctx.mutated(["axis": .string(horizontally ? "horizontal" : "vertical")])
    }

    // MARK: Guides

    static func addGuide(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let document = try ctx.document()
        let axis: CanvasGuide.Axis
        switch normalized(try ctx.args.string("axis")) {
        case "horizontal": axis = .horizontal
        case "vertical": axis = .vertical
        default: throw MCPToolError.invalidArgument("axis must be horizontal or vertical.")
        }
        let position = try ctx.args.double("position")
        guard abs(position) <= 1_000_000 else { throw MCPToolError.invalidArgument("position must be within ±1,000,000 pixels.") }
        try requireGuideEdits(ctx.session)
        guard document.guides.count < maxGuides else {
            throw MCPToolError(.preconditionFailed,
                               "The document already has \(document.guides.count) guides, the most a Compositor project can save.",
                               hint: "Remove some with remove_guide or clear_guides first.", guard: "max_guides")
        }
        let guide = CanvasGuide(id: UUID(), axis: axis, position: position)
        ctx.session.addGuide(guide)
        return ctx.mutated(["guide_id": .string(guide.id.uuidString), "guide": MCPValues.guide(guide)])
    }

    static func removeGuide(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let document = try ctx.document()
        let text = try ctx.args.string("guide_id")
        guard let id = UUID(uuidString: text) else {
            throw MCPToolError.invalidArgument("guide_id must be a guide's id.", hint: "list_guides shows the document's guides.")
        }
        guard let guide = document.guides.first(where: { $0.id == id }) else {
            throw MCPToolError.notFound("No guide with id \(text).", hint: "list_guides shows the document's guides.")
        }
        try requireGuideEdits(ctx.session)
        ctx.session.removeGuide(id)
        return ctx.mutated(["guide": MCPValues.guide(guide)])
    }

    static func clearGuides(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let document = try ctx.document()
        let session = ctx.session
        // As in the app, locked guides can still be cleared; only a running operation (whose result would bring
        // back the guides it started with) holds it up.
        if session.isProjectBusy || session.isImporting {
            throw MCPToolError(.busy, MCPGuards.blockingReason(session) ?? "Another operation is still running.",
                               hint: "Wait for it to finish, then retry.", guard: "can_clear_guides")
        }
        session.clearGuides()
        return ctx.mutated(["removed_count": .int(document.guides.count)])
    }

    static func listGuides(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let document = try ctx.document()
        return ok([
            "guides": .array(document.guides.map(MCPValues.guide)),
            "count": .int(document.guides.count),
            "visible": .bool(ctx.session.showsGuides),
            "locked": .bool(ctx.session.locksGuides),
        ])
    }

    // MARK: Helpers

    /// A snapshot of the tab's document for an off-main project operation.
    static func projectSnapshot(_ ctx: MCPCallContext) throws -> ProjectSnapshot {
        _ = try ctx.document()
        try MCPGuards.requireProjectOperation(ctx.session)
        guard let snapshot = ctx.session.projectSnapshot() else {
            throw MCPToolError(.internalError, "The document could not be prepared.")
        }
        return snapshot
    }

    /// Resizes a snapshot of the tab's document off the main actor while the document is marked busy, then installs
    /// the result as one undo step named `name`.
    private static func resizeDocument(_ ctx: MCPCallContext, name: String,
                                       _ resize: (ProjectSnapshot) async throws -> ProjectSnapshot) async throws {
        let snapshot = try projectSnapshot(ctx)
        let resized = try await MCPGuards.withProjectBusy(ctx.session) { try await resize(snapshot) }
        try install(resized, name: name, ctx)
    }

    /// Installs a resized document as one undo step named `name`, as the app's Canvas Size, Image Size and Crop do.
    private static func install(_ resized: ProjectSnapshot, name: String, _ ctx: MCPCallContext) throws {
        guard ctx.session.document?.id == resized.manifest.documentID else {
            throw MCPToolError(.preconditionFailed, "The document changed while resizing.",
                               hint: "Nothing was resized; call get_document to see it as it is now, then retry.", guard: "document_changed")
        }
        ctx.session.applyDocumentSize(resized, actionName: name)
    }

    /// What the Crop tool resizes by for `rect`: the rectangle becomes the canvas and its corner the origin.
    private static func cropOptions(_ rect: CGRect) -> CanvasSizeOptions {
        CanvasSizeOptions(width: Int(rect.width), height: Int(rect.height), contentOffset: CGPoint(x: -rect.minX, y: -rect.minY))
    }

    /// Stores `resolution` with the tab's document as one "Image Size" step (Image Size with resampling off). The
    /// same value records nothing.
    private static func setDocumentResolution(_ resolution: Double, _ session: EditorSession) {
        guard let current = session.document?.resolution, current != resolution else { return }
        session.beginEdit("Image Size")
        session.document?.resolution = resolution
        session.endEdit()
    }

    /// The `anchor` argument as a 3 × 3 grid index (0 top-left … 8 bottom-right): an integer, or an anchor name.
    private static func canvasAnchor(_ ctx: MCPCallContext) throws -> Int {
        let invalid = MCPToolError.invalidArgument("anchor must be 0–8 or one of \(anchorNames.joined(separator: ", ")).")
        if let name = ctx.args["anchor"]?.stringValue {
            guard let unit = anchorUnit(name) else { throw invalid }
            return Int(unit.x * 2) + Int(unit.y * 2) * 3
        }
        let index = try ctx.args.int("anchor", default: 4)
        guard (0...8).contains(index) else { throw invalid }
        return index
    }

    /// The `sampling` argument (high quality when omitted).
    private static func samplingArgument(_ ctx: MCPCallContext) throws -> LayerSampling {
        guard let name = try ctx.args.optionalString("sampling") else { return .high }
        switch normalized(name) {
        case "nearest", "nearestneighbor": return .nearest
        case "smooth", "bilinear": return .smooth
        case "high", "highquality", "bicubic": return .high
        default: throw MCPToolError.invalidArgument("sampling must be nearest, smooth or high.")
        }
    }

    /// The pixel layers trim_canvas measures: every shown layer, or those `layers` names (a folder standing for the
    /// layers shown in it).
    private static func trimmedLayers(_ ctx: MCPCallContext, in document: CanvasDocument) throws -> [ImageLayer] {
        guard ctx.args.has("layers") else { return document.renderLayers.filter { $0.asset != nil && $0.adjustment == nil } }
        var measured: [ImageLayer] = [], seen = Set<UUID>()
        for layer in try ctx.layers(in: document) {
            let members = layer.isGroup ? ctx.session.shownPixelLayers(in: layer.id, of: document) : [layer]
            for member in members where member.asset != nil && member.adjustment == nil && seen.insert(member.id).inserted {
                measured.append(member)
            }
        }
        return measured
    }

    /// The most guides a project may hold and still save (`ProjectStore.validateGuides`).
    private static let maxGuides = 1_000

    /// The whole document may be replaced or given an undo step of its own: a project operation may start
    /// (`canStartProjectOperation`), and nothing is in progress in the app that holds state in the old geometry or an
    /// open undo step (`canEditLayers`): a free transform (an Option-drag duplicate too), a crop frame, a gradient,
    /// moved pixels, the Hue/Saturation or a filter dialog. The app's own Canvas Size and Image Size cancel a crop
    /// frame and commit a transform first; an agent's call doesn't settle the user's edits behind their back, so it
    /// is refused instead. Fails with `guard: "can_edit_layers"`, pointing at settle_pending_edits.
    private static func requireSettledDocument(_ session: EditorSession) throws {
        try MCPGuards.requireProjectOperation(session)
        guard !session.canEditLayers else { return }
        throw MCPToolError(.preconditionFailed, MCPGuards.blockingReason(session) ?? "The document can't be edited right now.",
                           hint: "Commit or cancel it with settle_pending_edits (or finish it in Compositor), then retry.",
                           guard: "can_edit_layers")
    }

    /// Guides may be added or removed (`EditorSession.canEditGuides`); fails with `guard: "can_edit_guides"`, naming
    /// Lock Guides when that is why.
    private static func requireGuideEdits(_ session: EditorSession) throws {
        guard !session.canEditGuides else { return }
        if session.locksGuides {
            throw MCPToolError(.preconditionFailed, "Guides are locked in Compositor (View > Lock Guides).",
                               hint: "Unlock them in the View menu, then retry.", guard: "can_edit_guides")
        }
        let transient = session.isProjectBusy || session.isImporting
        throw MCPToolError(transient ? .busy : .preconditionFailed,
                           MCPGuards.blockingReason(session) ?? "Guides can't be changed right now.",
                           hint: transient ? "Wait for it to finish, then retry." : "Finish or cancel it in Compositor, then retry.",
                           guard: "can_edit_guides")
    }
}
