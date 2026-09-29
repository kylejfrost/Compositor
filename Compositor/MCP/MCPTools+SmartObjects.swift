import CoreGraphics
import Foundation
import MCP

// MARK: - Smart objects

extension MCPToolRegistry {
    static let smartObjectTools: [MCPToolEntry] = [
        tool("place_smart_object", title: "Place smart object",
             description: "Places a file as a new smart object, which keeps the file whole so it can be replaced later: PNG, JPEG, TIFF, GIF, SVG, PDF or PSD (not PSB or EPS), up to 512 MiB. It takes its own size, shrunk to the canvas, centered on 'center', or goes in fit_rect as fit says.",
             properties: [
                 "path": MCPSchema.str("The file to place."),
                 "center": MCPSchema.point("Where its center goes (not with fit_rect)."),
                 "fit_rect": MCPSchema.rect("A box to fit the contents in."),
                 "fit": fitSchema("How the contents go in fit_rect (only with it; default fit)"),
                 "name": MCPSchema.str("Layer name (default the file name)."),
             ],
             required: ["path"], effect: .additive(idempotent: false), handler: placeSmartObject),
        tool("replace_smart_object_contents", title: "Replace smart object contents",
             description: "Replaces a smart object's contents with a file and draws them in the object's placement (its quad) as fit says. The name, effects, mask and Photoshop settings stay, and contents_revision goes up.",
             properties: [
                 "layer": MCPSchema.layerSelector("The smart object"),
                 "path": MCPSchema.str("The file with the new contents."),
                 "fit": fitSchema("How the new contents go in the object's quad", default: "fit"),
             ],
             required: ["layer", "path"], effect: .destructive(idempotent: false), handler: replaceSmartObjectContents),
        tool("get_smart_object_info", title: "Get smart object info",
             description: "Describes a smart object's contents: file_type, file_name, bytes (null when not held), natural_size, quad (where they are placed, in document pixels), embedded and contents_revision.",
             properties: ["layer": MCPSchema.layerSelector("The smart object")],
             required: ["layer"], effect: .readOnly, handler: getSmartObjectInfo),
        tool("export_smart_object_contents", title: "Export smart object contents",
             description: "Writes a smart object's contents to a file exactly as the document holds them (the placed PNG, PDF or PSD), to edit elsewhere and bring back with replace_smart_object_contents. A path without an extension takes theirs.",
             properties: [
                 "layer": MCPSchema.layerSelector("The smart object"),
                 "path": MCPSchema.str("Where to write the contents."),
                 "overwrite": MCPSchema.bool("Replace a file at path.", default: false),
             ],
             required: ["layer", "path"], effect: .destructive(idempotent: true), handler: exportSmartObjectContents),
    ]

    /// What the smart-object tools can take, for their descriptions.
    private static let contentsFormats = "PNG, JPEG, TIFF, GIF, SVG, PDF (its first page) and Photoshop .psd files can be drawn; PSB and EPS can't, and files over 512 MiB are refused."

    // MARK: Handlers

    static func placeSmartObject(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let raw = try ctx.args.string("path")
        let name = try ctx.args.optionalString("name")
        let center = try centerArgument(ctx.args)
        let rect = try fitRectArgument(ctx.args)
        let fit = try fitArgument(ctx.args)
        if center != nil, rect != nil {
            throw MCPToolError(.invalidArgument, "'center' and 'fit_rect' both place the layer; give one of them.",
                               hint: "The contents go in the middle of fit_rect.", details: ["field": .string("center")])
        }
        if fit != nil, rect == nil {
            throw MCPToolError(.invalidArgument, "'fit' says how the contents go in 'fit_rect'; pass fit_rect too, or leave fit out.",
                               hint: "Without fit_rect the contents keep their own size, shrunk to fit the canvas.",
                               details: ["field": .string("fit")])
        }
        try placeableDocument(ctx)
        let url = try await contentsFile(raw)
        // Checked again: the file check awaited, and the session commits a pending transform before its own checks.
        let document = try placeableDocument(ctx)
        let session = ctx.session
        let id: UUID
        do {
            // Placing, naming and moving the layer out of a locked folder are one step, as for other new layers.
            id = try await addLayerInOneStep(ctx, document: document, editName: "Place Smart Object", name: name) {
                try await session.placeSmartObject(from: url, at: center, fitting: fit ?? .fit, in: rect)
            }
        } catch {
            throw smartObjectFailure(error, url: url, fitting: rect == nil ? nil : fit ?? .fit)
        }
        return try smartObjectResult(id, ctx)
    }

    static func replaceSmartObjectContents(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let raw = try ctx.args.string("path")
        let fit = try fitArgument(ctx.args) ?? .fit
        let target = try replaceableSmartObject(ctx).id
        let url = try await contentsFile(raw)
        // Checked again: the file check awaited, and the session commits a pending transform before its own checks.
        let layer = try replaceableSmartObject(ctx, id: target)
        do {
            try await ctx.session.replaceSmartObjectContents(layer.id, with: url, fitting: fit)
        } catch is LayerLockedError {
            throw lockedFailure(layer, ctx)
        } catch {
            throw smartObjectFailure(error, url: url, fitting: fit)
        }
        return try smartObjectResult(layer.id, ctx)
    }

    static func getSmartObjectInfo(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let document = try ctx.document()
        let layer = try ctx.layer(in: document)
        let smartObject = try smartObject(of: layer)
        var out = MCPValues.smartObject(smartObject, transform: layer.transform).objectValue ?? [:]
        out["layer_id"] = .string(layer.id.uuidString)
        out["name"] = .string(layer.name)
        return ok(out)
    }

    static func exportSmartObjectContents(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let raw = try ctx.args.string("path")
        let overwrite = try ctx.args.bool("overwrite", default: false)
        let document = try ctx.document()
        let layer = try ctx.layer(in: document)
        let smartObject = try smartObject(of: layer)
        guard let payload = smartObject.payload else {
            throw MCPToolError(.preconditionFailed,
                               "The document doesn't hold the contents of '\(layer.name)' (\(smartObject.info.fileName)): Photoshop linked them to a file, or left them out.",
                               hint: "replace_smart_object_contents gives it contents the document keeps.", guard: "has_contents")
        }
        var url = try await MCPPaths.resolveReachable(raw)
        if url.pathExtension.isEmpty { url.appendPathExtension(smartObject.info.fileExtension) }
        // The file with its extension, and the folder it goes in, before anything there is looked at.
        try await MCPPaths.ensureReachable(url, forWriting: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw MCPToolError(.invalidArgument, "\(url.path) is a folder; give a file path to write the contents to.",
                               details: ["path": .string(url.path)])
        }
        try await MCPPaths.prepareForWriting(url, overwrite: overwrite)
        let data = payload.data
        try await ImageExporter.shared.write(data, to: url)
        return ok([
            "layer_id": .string(layer.id.uuidString),
            "path": .string(url.path),
            "bytes": .int(data.count),
            "file_type": .string(smartObject.info.fileType.trimmingCharacters(in: .whitespaces)),
            "file_name": .string(smartObject.info.fileName),
        ])
    }

    // MARK: Checks

    /// The tab's document, once a layer may be added to it: layer edits allowed and room for another layer
    /// (`MCPGuards.requireLayerCapacity`).
    @discardableResult
    private static func placeableDocument(_ ctx: MCPCallContext) throws -> CanvasDocument {
        let document = try ctx.editableDocument()
        try MCPGuards.requireLayerCapacity(document)
        return document
    }

    /// The smart object the call's `layer` names (the layer `id`, once found), once its contents may be replaced:
    /// layer edits allowed, not a Photoshop placeholder, a smart object, and its pixels not locked (by its own locks or
    /// a folder's). Whether a locked position lets the contents in depends on where they land, which the session
    /// checks once it has read them.
    private static func replaceableSmartObject(_ ctx: MCPCallContext, id: UUID? = nil) throws -> ImageLayer {
        let document = try ctx.editableDocument()
        let layer: ImageLayer
        if let id {
            guard let current = document.layers.first(where: { $0.id == id }) else {
                throw MCPToolError.notFound("The smart object was deleted while its new contents were being found.")
            }
            layer = current
        } else {
            layer = try ctx.layer(in: document)
        }
        _ = try smartObject(of: layer)
        try MCPGuards.requireUnlocked(layer, in: document, .pixels)
        return layer
    }

    /// `layer`'s smart object. A Photoshop placeholder is named as one first.
    private static func smartObject(of layer: ImageLayer) throws -> LayerSmartObject {
        try MCPGuards.requireNotPlaceholder(layer)
        guard let smartObject = layer.smartObject else {
            throw MCPToolError(.preconditionFailed, "'\(layer.name)' is not a smart object.",
                               hint: "place_smart_object places a file as a smart object.", guard: "is_smart_object")
        }
        return smartObject
    }

    /// The file at the call's `path`, as contents: resolved and reachable (`MCPPaths.resolveReachable`: macOS lets
    /// Compositor read it, and something is there, else `not_found`), a file rather than a folder, and no larger than
    /// a project keeps (512 MiB).
    private static func contentsFile(_ raw: String) async throws -> URL {
        let url = try await MCPPaths.resolveReachable(raw, mustExist: true)
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard !isDirectory.boolValue else {
            throw MCPToolError(.invalidArgument, "\(url.path) is a folder; smart-object contents are a file.",
                               details: ["path": .string(url.path)])
        }
        if let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes > SmartObjectFileRecord.maximumBytes {
            throw oversizedContents(url, bytes: bytes)
        }
        return url
    }

    // MARK: Arguments

    /// The call's `fit`, or nil when it isn't given.
    private static func fitArgument(_ args: Args) throws -> SmartObjectFit? {
        guard let name = try args.optionalString("fit") else { return nil }
        let fits: [SmartObjectFit] = [.fit, .fill, .stretch]
        guard let fit = fits.first(where: { normalized($0.rawValue) == normalized(name) }) else {
            throw MCPToolError(.invalidArgument, "fit must be fit, fill or stretch, not '\(name)'.", details: ["field": .string("fit")])
        }
        return fit
    }

    /// The call's `center`, within a million pixels of the canvas, or nil when it isn't given.
    private static func centerArgument(_ args: Args) throws -> CGPoint? {
        guard let value = args["center"] else { return nil }
        guard let point = MCPValues.point(from: value), abs(point.x) <= 1_000_000, abs(point.y) <= 1_000_000 else {
            throw MCPToolError(.invalidArgument, "'center' must be a point {x, y} within ±1,000,000 document pixels.",
                               details: ["field": .string("center")])
        }
        return point
    }

    /// The call's `fit_rect`, or nil when it isn't given: a box a layer can fill, within a million pixels of the canvas.
    private static func fitRectArgument(_ args: Args) throws -> CGRect? {
        guard let value = args["fit_rect"] else { return nil }
        func refuse(_ message: String) -> MCPToolError {
            MCPToolError(.invalidArgument, message, details: ["field": .string("fit_rect")])
        }
        guard let rect = MCPValues.rect(from: value) else {
            throw refuse("'fit_rect' must be {x, y, width, height} in document pixels.")
        }
        // `size`, not `width`/`height`, which make a negative size positive.
        guard (1...300_000).contains(rect.size.width), (1...300_000).contains(rect.size.height) else {
            throw refuse("'fit_rect' must be 1–300,000 pixels wide and tall, as a layer can be.")
        }
        guard [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy({ abs($0) <= 1_000_000 }) else {
            throw refuse("'fit_rect' must lie within ±1,000,000 document pixels.")
        }
        return rect
    }

    // MARK: Results and failures

    /// A place or replace result: the layer's id, name, transform and smart object.
    private static func smartObjectResult(_ id: UUID, _ ctx: MCPCallContext) throws -> CallTool.Result {
        guard let layer = ctx.session.document?.layers.first(where: { $0.id == id }), let smartObject = layer.smartObject else {
            throw MCPToolError(.internalError, "The smart object layer is gone.")
        }
        return ctx.mutated([
            "layer_id": .string(id.uuidString),
            "name": .string(layer.name),
            "transform": MCPValues.transform(layer.transform),
            "smart_object": MCPValues.smartObject(smartObject, transform: layer.transform),
        ])
    }

    /// Contents at `url` larger than a project keeps.
    private static func oversizedContents(_ url: URL, bytes: Int?) -> MCPToolError {
        let size = bytes.map { " is \(($0 + (1 << 20) - 1) >> 20) MiB;" } ?? " is too large:"
        return MCPToolError(.invalidArgument,
                            "\(url.lastPathComponent)\(size) smart-object contents can be at most 512 MiB, the most a project keeps.",
                            details: ["path": .string(url.path)])
    }

    /// Why placing or replacing contents from `url` failed, as a tool error; errors the session didn't raise (a
    /// folder macOS keeps Compositor out of, say) pass through. `fitting` is how the contents were placed in a box
    /// (a fit_rect or the smart object's quad), nil when they kept their own size.
    private static func smartObjectFailure(_ error: Error, url: URL, fitting: SmartObjectFit?) -> Error {
        let path: [String: Value] = ["path": .string(url.path)]
        let file = url.lastPathComponent
        switch error {
        case let error as SmartObjectError:
            switch error {
            case .largeDocument:
                return MCPToolError(.unsupported, "\(file) is a Large Document (PSB); Compositor can't draw PSB contents.",
                                    hint: "Save it from Photoshop as a .psd, or export a PNG or PDF, and use that.", details: path)
            case .unsupported:
                return MCPToolError(.unsupported,
                                    "Compositor can't draw \(file). Use a PNG, JPEG, TIFF, GIF, SVG, PDF or Photoshop (.psd) file; EPS can't be drawn, as macOS 14 and later have no PostScript interpreter.",
                                    details: path)
            case .unreadable:
                return MCPToolError(.ioError, "\(file) couldn't be read as smart-object contents; it may be damaged.", details: path)
            case .invalidPlacement:
                return MCPToolError(.invalidArgument, "That would place the layer beyond 1,000,000 pixels from the canvas.",
                                    hint: "Give a center nearer the canvas.", details: ["field": .string("center")])
            case .notSmartObject:
                return MCPToolError(.preconditionFailed, "That layer is not a smart object.",
                                    hint: "place_smart_object places a file as a smart object.", guard: "is_smart_object")
            case .noDocument:
                return MCPToolError(.preconditionFailed, "This tab has no document open.",
                                    hint: "Create one with new_document, or open one with open_document.", guard: "document")
            case .busy, .changed:
                return MCPToolError(.busy, "Another edit started while \(file) was being read, so nothing was changed.",
                                    hint: "Retry once it has finished.", guard: "can_edit_layers")
            }
        case ImageImportError.tooLarge:
            guard let fitting else { return oversizedContents(url, bytes: nil) }
            return MCPToolError(.invalidArgument,
                                "Placed as fit: \(fitting.rawValue) says, \(file) would make the layer larger than Compositor allows (300,000 pixels a side, within 1,000,000 pixels of the canvas).",
                                details: path)
        default:
            return error
        }
    }

    /// Replacing `layer`'s contents was refused by a lock: its pixels', or its position's once the contents would
    /// move it. Named as `MCPGuards.requireUnlocked` names locks, with the layer or folder that holds it.
    private static func lockedFailure(_ layer: ImageLayer, _ ctx: MCPCallContext) -> MCPToolError {
        if let document = ctx.session.document, let current = document.layers.first(where: { $0.id == layer.id }) {
            do {
                try MCPGuards.requireUnlocked(current, in: document, .pixels)
                try MCPGuards.requireUnlocked(current, in: document, .position)
            } catch let locked as MCPToolError {
                guard locked.details["locks"]?.arrayValue?.contains(.string("position")) == true else { return locked }
                return MCPToolError(locked.code, locked.message + " The new contents would move or resize it.",
                                    hint: "Unlock its position with set_layer_locks, or use fit: fill or stretch, which keep a placement covering the whole layer.",
                                    guard: locked.guardName, details: locked.details)
            } catch {}
        }
        return MCPToolError(.preconditionFailed, "'\(layer.name)' is locked.", hint: "Unlock it with set_layer_locks, then retry.",
                            guard: "layer_locked")
    }

    // MARK: Schemas

    /// How contents go in a box: `fit` inside or `fill` it keeping their proportions (centered), or `stretch` to it.
    /// Filling crops the contents to the box, and the crop becomes the contents.
    private static func fitSchema(_ description: String, default fallback: String? = nil) -> Value {
        MCPSchema.enumString(description + ": fit inside or fill keeping proportions, centered (fill crops them and keeps the crop as the contents), or stretch.",
                             ["fit", "fill", "stretch"], default: fallback)
    }
}
