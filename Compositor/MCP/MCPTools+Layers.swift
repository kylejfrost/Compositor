import CoreGraphics
import Foundation
import MCP

// MARK: - Layers

extension MCPToolRegistry {
    static let layerTools: [MCPToolEntry] = [
        tool("get_layer", title: "Get layer",
             description: "Describes one layer as get_document does: id, name, path, kind, visibility, opacity, blending, clipping, transform, locks and effective_locks, and a folder's children. Kinds: raster, text, shape, smart_object, adjustment, folder, placeholder. detail full (the default) adds its box, content bounds, effects, text, shape, adjustment, smart-object and mask details.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "detail": MCPSchema.enumString("Detail.", ["summary", "full"], default: "full"),
             ],
             required: ["layer"], effect: .readOnly, handler: getLayer),
        tool("add_blank_layer", title: "Add blank layer",
             description: "Adds an empty transparent layer above the active layer (at the top of it when it is a folder), at the top of 'parent' (null: the top level), or directly above 'above'.",
             properties: [
                 "name": MCPSchema.str("Layer name."),
                 "parent": MCPSchema.nullable(MCPSchema.layerSelector("The folder to add it to (null: the top level)")),
                 "above": MCPSchema.layerSelector("The layer to put it directly above"),
             ],
             effect: .additive(idempotent: false), handler: addBlankLayer),
        tool("add_image_layer", title: "Add image layer",
             description: "Imports an image file (PNG, JPEG, HEIC, TIFF, camera raw, or SVG drawn into pixels) as a new layer above the active layer, centered on 'center' (default the canvas center). fit contain or cover sizes the layer to fit inside or cover the canvas, keeping its pixels. A tab with no document gets one sized to the image.",
             properties: [
                 "path": MCPSchema.str("Image file."),
                 "name": MCPSchema.str("Layer name (default the file name)."),
                 "center": MCPSchema.point("Where its center goes (default the canvas center)."),
                 "fit": MCPSchema.enumString("Size against the canvas.", ["none", "contain", "cover"], default: "none"),
             ],
             required: ["path"], effect: .additive(idempotent: false), handler: addImageLayer),
        tool("add_group", title: "Add folder",
             description: "Adds an empty folder above the active layer (inside it when it is a folder).",
             properties: ["name": MCPSchema.str("Folder name.")],
             effect: .additive(idempotent: false), handler: addGroup),
        tool("rename_layer", title: "Rename layer",
             description: "Renames a layer or folder.",
             properties: ["layer": MCPSchema.layerSelector(), "name": MCPSchema.str("New name.")],
             required: ["layer", "name"], effect: .additive(idempotent: true), handler: renameLayer),
        tool("set_layer_visibility", title: "Set layer visibility",
             description: "Shows or hides a layer or folder, even a locked one.",
             properties: ["layer": MCPSchema.layerSelector(), "visible": MCPSchema.bool("Show it.")],
             required: ["layer", "visible"], effect: .additive(idempotent: true), handler: setLayerVisibility),
        tool("set_layer_opacity", title: "Set layer opacity",
             description: "Sets a layer's or folder's opacity from 0 to 1, its effects included.",
             properties: ["layer": MCPSchema.layerSelector(), "opacity": MCPSchema.num("Opacity.", min: 0, max: 1)],
             required: ["layer", "opacity"], effect: .additive(idempotent: true), handler: setLayerOpacity),
        tool("set_layer_fill_opacity", title: "Set layer fill opacity",
             description: "Sets a layer's fill opacity (Photoshop's Fill) from 0 to 1: its own pixels' opacity, apart from its effects. It is saved and written to PSD, and drawn on layers without effects. Folders have none.",
             properties: ["layer": MCPSchema.layerSelector(), "fill_opacity": MCPSchema.num("Fill opacity.", min: 0, max: 1)],
             required: ["layer", "fill_opacity"], effect: .additive(idempotent: true), handler: setLayerFillOpacity),
        tool("set_layer_blend_mode", title: "Set layer blend mode",
             description: "Sets a layer's blend mode; names match loosely (color_burn, Color Burn). Folders pass their contents through and take none.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "mode": MCPSchema.enumString("Blend mode name.", LayerBlendMode.allCases.map(\.rawValue)),
             ],
             required: ["layer", "mode"], effect: .additive(idempotent: true), handler: setLayerBlendMode),
        tool("set_layer_locks", title: "Set layer locks",
             description: "Turns layer locks on or off: position (moving, transforming), pixels (painting, rasterizing, merging), all (every change but showing, hiding and selecting) and transparency (kept for PSD). Locks not given keep their state; a folder's locks hold everything in it.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "transparency": MCPSchema.bool("Lock transparent pixels."),
                 "pixels": MCPSchema.bool("Lock image pixels."),
                 "position": MCPSchema.bool("Lock position."),
                 "all": MCPSchema.bool("Lock all."),
             ],
             required: ["layer"], effect: .additive(idempotent: true), handler: setLayerLocks),
        tool("delete_layers", title: "Delete layers",
             description: "Deletes layers, a folder with its contents. Layers clipped to a deleted one are baked to their current look first, as the app's Delete does.",
             properties: ["layers": MCPSchema.layerSelectors("Layers to delete")],
             required: ["layers"], effect: .destructive(idempotent: false), handler: deleteLayers),
        tool("duplicate_layer", title: "Duplicate layer",
             description: "Duplicates a layer, a folder with its contents, directly above it and selects the copy.",
             properties: ["layer": MCPSchema.layerSelector(), "name": MCPSchema.str("The copy's name.")],
             required: ["layer"], effect: .additive(idempotent: false), handler: duplicateLayer),
        tool("layer_via_copy", title: "Layer via copy",
             description: "Copies a pixel layer's pixels inside the selection to a new layer, in place above it (Layer via Copy); without a selection the whole layer is duplicated.",
             properties: ["layer": MCPSchema.layerSelector()],
             required: ["layer"], effect: .additive(idempotent: false), handler: layerViaCopy),
        tool("reorder_layer", title: "Reorder layer",
             description: "Moves a layer to a sibling index inside its folder, 0 being the bottom. Clipping follows the stack: moved into a clipping group a layer joins it, moved out of one it stops clipping.",
             properties: ["layer": MCPSchema.layerSelector(), "index": MCPSchema.int("Sibling index, 0 the bottom (past the top: the top).", min: 0)],
             required: ["layer", "index"], effect: .additive(idempotent: true), handler: reorderLayer),
        tool("place_layer", title: "Place layer",
             description: "Moves a layer or folder into a folder or out of one. It goes into 'parent' (null: the top level; omitted, the folder 'above' is in, else its own), directly above 'above', at the bottom with bottom: true, or else at the top.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "parent": MCPSchema.nullable(MCPSchema.layerSelector("The folder to move it into (null: the top level)")),
                 "above": MCPSchema.layerSelector("The layer to put it directly above"),
                 "bottom": MCPSchema.bool("Put it at the bottom.", default: false),
             ],
             required: ["layer"], effect: .additive(idempotent: true), handler: placeLayer),
        tool("group_layers", title: "Group layers",
             description: "Collects layers into a new folder, placed where the topmost of them was.",
             properties: [
                 "layers": MCPSchema.layerSelectors("Layers to group"),
                 "name": MCPSchema.str("Folder name."),
             ],
             required: ["layers"], effect: .additive(idempotent: false), handler: groupLayers),
        tool("ungroup_layer", title: "Ungroup folder",
             description: "Removes a folder, moving its contents into its parent at its place in the stack, in order, and selects them. The folder's own opacity, mask and effects go with it, as in Photoshop.",
             properties: ["layer": MCPSchema.layerSelector("The folder")],
             required: ["layer"], effect: .destructive(idempotent: false), handler: ungroupLayer),
        tool("set_clipping_mask", title: "Set clipping mask",
             description: "Clips a layer to the layer below it, or unclips it (Photoshop's clipping mask).",
             properties: ["layer": MCPSchema.layerSelector(), "enabled": MCPSchema.bool("Clip to the layer below.")],
             required: ["layer", "enabled"], effect: .additive(idempotent: true), handler: setClippingMask),
        tool("select_layers", title: "Select layers",
             description: "Sets the active layer and multi-selection (what merge_layers and the app act on), and whether edits in the app target the active layer's pixels or its mask.",
             properties: [
                 "layers": MCPSchema.layerSelectors("Layers to select"),
                 "active": MCPSchema.layerSelector("The layer to make active (defaults to the first of 'layers')"),
                 "target": MCPSchema.enumString("pixels, or mask (it must have one).", ["pixels", "mask"], default: "pixels"),
             ],
             required: ["layers"], effect: .additive(idempotent: true), handler: selectLayers),
        tool("merge_layers", title: "Merge layers",
             description: "Merges layers into one pixel layer, baking blending, masks, clipping and adjustments: one layer merges down, several merge together, and a folder merges its contents. layers defaults to the selection; the result names the action.",
             properties: ["layers": MCPSchema.layerSelectors("Layers to merge (default: the current selection)")],
             effect: .destructive(idempotent: false), handler: mergeLayers),
        tool("flatten_image", title: "Flatten image",
             description: "Flattens the document into one full-canvas pixel layer, 'Background', as export_image renders it. Hidden layers are discarded, or with discard_hidden false the call is refused while there are any.",
             properties: ["discard_hidden": MCPSchema.bool("Discard hidden layers (false: refuse if any).", default: true)],
             effect: .destructive(idempotent: false), handler: flattenImage),
        tool("rasterize_layer", title: "Rasterize layer",
             description: "Turns a text or shape layer into the plain pixels it shows now, keeping its effects and mask. A pixel layer stays as it is; folders, adjustment layers and placeholders are refused.",
             properties: ["layer": MCPSchema.layerSelector()],
             required: ["layer"], effect: .destructive(idempotent: false), handler: rasterizeLayer),
    ]

    // MARK: Reading

    static func getLayer(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let full: Bool
        switch try ctx.args.optionalString("detail").map(normalized) ?? "full" {
        case "summary": full = false
        case "full": full = true
        default: throw MCPToolError.invalidArgument("detail must be summary or full.")
        }
        let document = try ctx.document()
        let layer = try ctx.layer(in: document)
        var bounds: [UUID: CGRect] = [:]
        if full {
            let subtree = ctx.session.descendantIDs(of: layer.id).union([layer.id])
            var scanned = document
            scanned.layers = document.layers.filter { subtree.contains($0.id) }
            bounds = try await contentBounds(of: scanned)
        }
        return ok(["layer": MCPValues.layerDetail(layer, in: document, full: full, contentBounds: bounds)])
    }

    // MARK: Creation

    static func addBlankLayer(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let name = try ctx.args.optionalString("name")
        let document = try ctx.editableDocument()
        try MCPGuards.requireLayerCapacity(document)
        let session = ctx.session
        let place = ctx.args.values["parent"] != nil || ctx.args.has("above") ? try placement(ctx, in: document, fallback: nil) : nil
        // As place_layer: a folder under Lock All takes no new layers.
        if let folder = place?.parent.flatMap({ parent in document.layers.first { $0.id == parent } }) {
            try MCPGuards.requireUnlocked(folder, in: document, .all)
        }
        let before = session.activeLayerID
        let placed = asOneStep(session, "New Blank Layer") { () -> UUID? in
            session.addBlankLayer()
            guard let id = session.activeLayerID, id != before else { return nil }
            if let name { session.renameLayer(id, to: name) }
            guard let place else {
                placeOutsideLockAllFolders(id, session: session)
                return id
            }
            if !session.placeLayer(id, in: place.parent, above: place.above?.id) {
                session.document = document
                session.activeLayerID = before
                return nil
            }
            return id
        }
        guard let id = placed else { throw MCPToolError(.internalError, "Could not add a layer there.") }
        return ctx.mutated(["layer_id": .string(id.uuidString), "name": .string(session.activeLayer?.name ?? "")])
    }

    static func addImageLayer(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        if ctx.args.has("center_x") || ctx.args.has("center_y") {
            throw MCPToolError.invalidArgument("center_x and center_y are no longer read.", hint: "Pass 'center': {\"x\": …, \"y\": …} instead.")
        }
        let url = try await MCPPaths.resolveReachable(try ctx.args.string("path"), mustExist: true)
        let name = try ctx.args.optionalString("name")
        let center = try ctx.args["center"].map { value -> CGPoint in
            guard let point = MCPValues.point(from: value) else { throw MCPToolError.invalidArgument("'center' must be {\"x\", \"y\"} in document pixels.") }
            return point
        }
        let fit = try ctx.args.optionalString("fit").map(normalized) ?? "none"
        guard ["none", "contain", "cover"].contains(fit) else { throw MCPToolError.invalidArgument("fit must be none, contain or cover.") }
        let session = ctx.session
        try MCPGuards.requireProjectOperation(session)
        if let document = session.document {
            try MCPGuards.requireEditable(session)
            try MCPGuards.requireLayerCapacity(document)
        }
        // An SVG is drawn at its own size, or at the size the fit gives it on the canvas (inside it for contain, filling
        // it for cover), so the fitted layer is sharp rather than scaled up.
        let asset = ImageImporter.isSVG(url)
            ? try await ImageImporter.shared.decodeSVG(url, fitting: fit == "none" ? nil : session.document?.size, cover: fit == "cover")
            : try await ImageImporter.shared.decode(url)
        // Reading the file let the app run: an edit it began meanwhile (a transform, typed text, a save or resize)
        // must not get the layer inside it, and the document may have filled up.
        try MCPGuards.requireProjectOperation(session)
        if let document = session.document {
            try MCPGuards.requireEditable(session)
            try MCPGuards.requireLayerCapacity(document)
        }
        let before = (document: session.document, active: session.activeLayerID)
        let added = try asOneStep(session, "Import Image") { () throws -> ImageLayer? in
            session.insert(asset, centeredAt: center)
            guard let id = session.activeLayerID, id != before.active else { return nil }
            moveAboveActiveLayer(id, active: before.active, session: session)
            guard let document = session.document, let index = document.layers.firstIndex(where: { $0.id == id }) else { return nil }
            if let name { session.renameLayer(id, to: name) }
            if fit != "none" {
                let width = CGFloat(asset.image.width), height = CGFloat(asset.image.height)
                let ratios = (CGFloat(document.width) / width, CGFloat(document.height) / height)
                let scale = fit == "contain" ? min(ratios.0, ratios.1) : max(ratios.0, ratios.1)
                let size = CGSize(width: width * scale, height: height * scale)
                let middle = center ?? CGPoint(x: CGFloat(document.width) / 2, y: CGFloat(document.height) / 2)
                var transform = document.layers[index].transform
                transform.size = size
                transform.origin = CGPoint(x: middle.x - size.width / 2, y: middle.y - size.height / 2)
                guard transform.isValid else {
                    // Nothing changed, so the step records nothing.
                    session.document = before.document
                    session.activeLayerID = before.active
                    throw MCPToolError.invalidArgument("Fitting makes the layer larger than Compositor allows (300,000 pixels a side).")
                }
                session.document?.layers[index].transform = transform
            }
            placeOutsideLockAllFolders(id, session: session)
            return session.document?.layers.first { $0.id == id }
        }
        guard let layer = added else { throw MCPToolError(.internalError, "The image could not be added.") }
        return ctx.mutated(["layer_id": .string(layer.id.uuidString), "name": .string(layer.name),
                            "transform": MCPValues.transform(layer.transform)])
    }

    static func addGroup(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let name = try ctx.args.optionalString("name")
        let document = try ctx.editableDocument()
        try MCPGuards.requireLayerCapacity(document)
        let session = ctx.session
        let before = session.activeLayerID
        session.beginEdit("New Folder")
        session.addGroup()
        if let id = session.activeLayerID, id != before {
            if let name { session.renameLayer(id, to: name) }
            placeOutsideLockAllFolders(id, session: session)
        }
        session.endEdit()
        guard let id = session.activeLayerID, id != before else { throw MCPToolError(.internalError, "Could not add a folder.") }
        return ctx.mutated(["group_id": .string(id.uuidString)])
    }

    // MARK: Properties

    static func renameLayer(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        let name = try ctx.args.string("name")
        try MCPGuards.requireUnlocked(layer, in: document, .all)
        ctx.session.renameLayer(layer.id, to: name)
        let renamed = ctx.session.document?.layers.first { $0.id == layer.id }?.name ?? name
        return ctx.mutated(["layer_id": .string(layer.id.uuidString), "name": .string(renamed)])
    }

    static func setLayerVisibility(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        let visible = try ctx.args.bool("visible")
        try edit(layer.id, ctx: ctx, name: visible ? "Show Layer" : "Hide Layer") { layer in
            guard layer.isVisible != visible else { return false }
            layer.isVisible = visible
            return true
        }
        return ctx.mutated(["visible": .bool(visible)])
    }

    static func setLayerOpacity(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        let opacity = try unitValue("opacity", ctx: ctx)
        try MCPGuards.requireUnlocked(layer, in: document, .all)
        try edit(layer.id, ctx: ctx, name: "Layer Opacity") { layer in
            guard layer.opacity != opacity else { return false }
            layer.opacity = opacity
            return true
        }
        return ctx.mutated(["opacity": .double(opacity)])
    }

    static func setLayerFillOpacity(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        let fill = try unitValue("fill_opacity", ctx: ctx)
        if layer.isGroup {
            throw MCPToolError(.preconditionFailed, "'\(layer.name)' is a folder; folders have no fill opacity.",
                               hint: "Use set_layer_opacity to dim a folder's contents.", guard: "not_folder")
        }
        try MCPGuards.requireUnlocked(layer, in: document, .all)
        try edit(layer.id, ctx: ctx, name: "Layer Fill") { layer in
            guard layer.fillOpacity != fill else { return false }
            layer.fillOpacity = fill
            return true
        }
        return ctx.mutated(["fill_opacity": .double(fill)])
    }

    /// A number in 0…1 read from `key`; anything outside is `invalid_argument`, never clamped.
    private static func unitValue(_ key: String, ctx: MCPCallContext) throws -> Double {
        let value = try ctx.args.double(key)
        guard (0...1).contains(value) else { throw MCPToolError.invalidArgument("'\(key)' must be from 0 to 1.") }
        return value
    }

    /// The blend mode `name` means: its display name or case name, ignoring case, spaces and punctuation.
    static func blendMode(_ name: String) -> LayerBlendMode? {
        let target = normalized(name)
        return LayerBlendMode.allCases.first { normalized($0.rawValue) == target || normalized("\($0)") == target }
    }

    static func setLayerBlendMode(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        let name = try ctx.args.string("mode")
        guard let mode = blendMode(name) else {
            throw MCPToolError.invalidArgument("Unknown blend mode '\(name)'.",
                                               hint: "Modes: \(LayerBlendMode.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        if layer.isGroup {
            throw MCPToolError(.preconditionFailed, "'\(layer.name)' is a folder; folders pass their contents through and take no blend mode.",
                               hint: "Set the blend mode on the layers inside it.", guard: "not_folder")
        }
        try MCPGuards.requireUnlocked(layer, in: document, .all)
        try edit(layer.id, ctx: ctx, name: "Layer Blend Mode") { layer in
            guard layer.blendMode != mode else { return false }
            layer.blendMode = mode
            return true
        }
        return ctx.mutated(["blend_mode": .string(mode.rawValue)])
    }

    static func setLayerLocks(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        var locks = layer.locks
        var given = false
        for (key, lock) in [("transparency", LayerLocks.transparency), ("pixels", .pixels), ("position", .position), ("all", .all)] {
            guard let on = try ctx.args.optionalBool(key) else { continue }
            given = true
            if on { locks.insert(lock) } else { locks.remove(lock) }
        }
        guard given else { throw MCPToolError.invalidArgument("Pass at least one of transparency, pixels, position or all.") }
        // What is inside a folder under Lock All keeps its locks, as in Photoshop, until the folder is unlocked.
        if let parent = layer.parentID, let folder = document.lockIndex.blocker(of: .all, on: parent) {
            throw MCPToolError(.preconditionFailed,
                               "'\(layer.name)' is inside the folder '\(folder.name)', which is under Lock All, so its locks can't change.",
                               hint: "Unlock the folder '\(folder.name)' with set_layer_locks (all: false) first.", guard: "locked_by_folder",
                               details: ["layer_id": .string(layer.id.uuidString), "locked_by_id": .string(folder.id.uuidString)])
        }
        ctx.session.setLocks(locks, on: layer.id)
        return ctx.mutated(["layer_id": .string(layer.id.uuidString), "locks": MCPValues.layerLocks(locks)])
    }

    /// Changes one layer in place as one undo step; `change` returns false for a no-op,
    /// which then records no history entry.
    static func edit(_ id: UUID, ctx: MCPCallContext, name: String, _ change: (inout ImageLayer) -> Bool) throws {
        let session = ctx.session
        guard let index = session.document?.layers.firstIndex(where: { $0.id == id }), var layer = session.document?.layers[index] else {
            throw MCPToolError(.notFound, "The layer no longer exists.")
        }
        guard change(&layer) else { return }
        session.beginEdit(name)
        session.document?.layers[index] = layer
        session.endEdit()
    }

    // MARK: Structure

    static func deleteLayers(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let session = ctx.session
        let document = try ctx.editableDocument()
        let chosen = Set(try ctx.layers(in: document).map(\.id))
        // In stacking order, as the app's multi-delete takes them.
        let ids = document.layers.map(\.id).filter(chosen.contains)
        let removed = ids.reduce(into: Set<UUID>()) { $0.formUnion(session.descendantIDs(of: $1).union([$1])) }
        try MCPGuards.requireUnlocked(document.layers.filter { removed.contains($0.id) }, in: document, .all)
        let clipped = document.layers.filter { !removed.contains($0.id) && $0.maskSourceID.map(removed.contains) == true }
        // Baking a clip in changes those layers' pixels.
        try MCPGuards.requireUnlocked(clipped, in: document, .pixels)
        let targets = clipped.map(\.id)
        var baked: [UUID: ImportedImage] = [:]
        if !targets.isEmpty {
            guard let snapshot = session.projectSnapshot() else { throw MCPToolError(.internalError, "Could not prepare the deletion.") }
            baked = try await MCPGuards.withProjectBusy(session) {
                try await Task.detached(priority: .userInitiated) {
                    var result: [UUID: ImportedImage] = [:]
                    for target in targets { result[target] = try LiveMaskBaker.bake(snapshot, target: target) }
                    return result
                }.value
            }
        }
        session.finishDeletingLayers(ids, baked: baked)
        return ctx.mutated([
            "deleted_layer_ids": .array(document.layers.filter { removed.contains($0.id) }.map { .string($0.id.uuidString) }),
            "baked_layer_ids": .array(targets.map { .string($0.uuidString) }),
        ])
    }

    static func duplicateLayer(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let session = ctx.session
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        let name = try ctx.args.optionalString("name")
        // A folder is copied with everything inside it.
        try MCPGuards.requireLayerCapacity(document, adding: 1 + session.descendantIDs(of: layer.id).count)
        let copy = asOneStep(session, "Duplicate Layer") { () -> UUID? in
            session.selectLayer(layer.id)
            session.duplicateActiveLayer()
            guard let copy = session.activeLayerID, copy != layer.id else { return nil }
            if let name { session.renameLayer(copy, to: name) }
            placeOutsideLockAllFolders(copy, session: session)
            return copy
        }
        guard let copy else { throw MCPToolError(.internalError, "Duplicate failed.") }
        return ctx.mutated(["layer_id": .string(copy.uuidString), "name": .string(session.activeLayer?.name ?? "")])
    }

    static func layerViaCopy(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let session = ctx.session
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        try MCPGuards.requireNotPlaceholder(layer)
        try MCPGuards.requirePixels(layer)
        try MCPGuards.requireLayerCapacity(document)
        // The app copies from the active layer; a refused call leaves the layer selection as it was.
        let copy = try keepingLayerSelectionOnFailure(session) { () throws -> ImageLayer in
            session.selectLayer(layer.id)
            session.isMaskSelected = false
            if session.selection != nil, !session.canCopyPixels {
                throw MCPToolError(.preconditionFailed, "'\(layer.name)' has no pixels under the selection to copy.",
                                   hint: "Select part of a layer that has pixels, or clear the selection to duplicate the whole layer.",
                                   guard: "can_copy_pixels")
            }
            return try asOneStep(session, session.selection == nil ? "Duplicate Layer" : "Layer via Copy") { () throws -> ImageLayer in
                try MCPGuards.captureBrushError(session) { session.layerViaCopy() }
                guard let copy = session.activeLayerID, copy != layer.id else {
                    throw MCPToolError(.preconditionFailed, "The selection holds no pixels of '\(layer.name)'.",
                                       hint: "Select part of the layer that has pixels, or clear the selection to duplicate the whole layer.",
                                       guard: "can_copy_pixels")
                }
                placeOutsideLockAllFolders(copy, session: session)
                guard let added = session.document?.layers.first(where: { $0.id == copy }) else {
                    throw MCPToolError(.internalError, "Layer via Copy made no layer.")
                }
                return added
            }
        }
        return ctx.mutated(["layer_id": .string(copy.id.uuidString), "name": .string(copy.name),
                            "transform": MCPValues.transform(copy.transform)])
    }

    static func reorderLayer(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let session = ctx.session
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        let index = try ctx.args.int("index")
        let siblings = document.layers.filter { $0.parentID == layer.parentID }
        guard let current = siblings.firstIndex(where: { $0.id == layer.id }) else {
            throw MCPToolError(.internalError, "Could not find the layer's stack position.")
        }
        let target = min(max(0, index), siblings.count - 1)
        guard target != current else { return ctx.mutated(["index": .int(target)]) }
        try MCPGuards.requireUnlocked(layer, in: document, .all)
        let others = siblings.filter { $0.id != layer.id }
        let moved = asOneStep(session, "Reorder Layers") {
            target == 0 ? session.placeLayer(layer.id, in: layer.parentID, atBottom: true)
                : session.placeLayer(layer.id, in: layer.parentID, above: others[target - 1].id)
        }
        guard moved else { throw MCPToolError(.internalError, "Could not move the layer.") }
        return ctx.mutated(["index": .int(target)])
    }

    static func placeLayer(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let session = ctx.session
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        let bottom = try ctx.args.bool("bottom", default: false)
        let place = try placement(ctx, in: document, fallback: layer.parentID)
        if bottom, place.above != nil { throw MCPToolError.invalidArgument("Pass 'above' or bottom: true, not both.") }
        if place.above?.id == layer.id { throw MCPToolError.invalidArgument("A layer can't be placed above itself.") }
        try MCPGuards.requireUnlocked(layer, in: document, .all)
        // A folder under Lock All keeps its contents as they are: nothing moves in, as nothing inside moves.
        if let folder = place.parent.flatMap({ parent in document.layers.first { $0.id == parent } }) {
            try MCPGuards.requireUnlocked(folder, in: document, .all)
        }
        guard session.canPlaceLayer(layer.id, in: place.parent) else {
            throw MCPToolError(.preconditionFailed, "'\(layer.name)' can't go into a folder inside itself.",
                               hint: "Pick a folder that isn't inside it, or null for the top level.", guard: "can_place_layer")
        }
        guard session.placeLayer(layer.id, in: place.parent, above: place.above?.id, atBottom: bottom) else {
            throw MCPToolError(.internalError, "Could not move the layer there.")
        }
        return ctx.mutated(["layer_id": .string(layer.id.uuidString), "parent_id": place.parent.map { .string($0.uuidString) } ?? .null])
    }

    /// Where the `parent` and `above` arguments put a layer: `parent`'s folder (a `null` parent is the top level),
    /// else the folder `above` is in, else `fallback`. `above` must be in that folder.
    private static func placement(_ ctx: MCPCallContext, in document: CanvasDocument,
                                  fallback: UUID?) throws -> (parent: UUID?, above: ImageLayer?) {
        let above = try ctx.optionalLayer("above", in: document)
        let parent: UUID?
        if ctx.args.values["parent"] == .null {
            parent = nil
        } else if let folder = try ctx.optionalLayer("parent", in: document) {
            guard folder.isGroup else { throw MCPToolError.invalidArgument("'\(folder.name)' is not a folder.") }
            parent = folder.id
        } else {
            parent = above.map(\.parentID) ?? fallback
        }
        if let above, above.parentID != parent {
            throw MCPToolError.invalidArgument("'\(above.name)' is not in the folder 'parent' names.",
                                               hint: "Omit 'parent' to use the folder 'above' is in.")
        }
        return (parent, above)
    }

    static func groupLayers(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let session = ctx.session
        let document = try ctx.editableDocument()
        let layers = try ctx.layers(in: document)
        let name = try ctx.args.optionalString("name")
        try MCPGuards.requireUnlocked(layers, in: document, .all)
        try MCPGuards.requireLayerCapacity(document)
        let ids = layers.map(\.id)
        let before = Set(document.layers.map(\.id))
        let group = asOneStep(session, "Group Layers") { () -> UUID? in
            session.selectLayers(Set(ids), primary: ids.first)
            session.groupSelectedLayers()
            guard let group = session.activeLayerID, !before.contains(group) else { return nil }
            if let name { session.renameLayer(group, to: name) }
            return group
        }
        guard let group else {
            throw MCPToolError(.preconditionFailed, "Those layers could not be grouped.",
                               hint: "Group layers from one folder, not a folder together with what is inside it.", guard: "can_group")
        }
        return ctx.mutated(["group_id": .string(group.uuidString)])
    }

    static func ungroupLayer(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let session = ctx.session
        let document = try ctx.editableDocument()
        let folder = try ctx.layer(in: document)
        guard folder.isGroup else {
            throw MCPToolError(.preconditionFailed, "'\(folder.name)' is not a folder.",
                               hint: "Pass a folder; get_document shows each layer's kind.", guard: "is_folder")
        }
        try MCPGuards.requireUnlocked(folder, in: document, .all)
        let moved = session.ungroup(folder.id)
        guard session.document?.layers.contains(where: { $0.id == folder.id }) == false else {
            throw MCPToolError(.internalError, "Could not ungroup '\(folder.name)'.")
        }
        return ctx.mutated(["layer_ids": .array(moved.map { .string($0.uuidString) })])
    }

    static func setClippingMask(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let session = ctx.session
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        let enabled = try ctx.args.bool("enabled")
        if (layer.maskSourceID != nil) == enabled { return ctx.mutated(["clipping": .bool(enabled)]) }
        try MCPGuards.requireUnlocked(layer, in: document, .all)
        if enabled {
            guard session.canToggleClippingMask(layer.id) else {
                throw MCPToolError(.preconditionFailed, "Cannot clip: the layer needs a non-folder layer directly below it.",
                                   hint: "Move it directly above the layer to clip to (reorder_layer or place_layer), in the same folder.", guard: "can_clip")
            }
        }
        session.toggleClippingMask(layer.id)
        return ctx.mutated(["clipping": .bool(enabled)])
    }

    static func selectLayers(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let session = ctx.session
        let document = try ctx.editableDocument()
        let layers = try ctx.layers(in: document)
        let requested = try ctx.optionalLayer("active", in: document)?.id
        let mask: Bool
        switch try ctx.args.optionalString("target").map(normalized) ?? "pixels" {
        case "pixels": mask = false
        case "mask": mask = true
        default: throw MCPToolError.invalidArgument("target must be pixels or mask.")
        }
        let primary = layers.first { $0.id == requested } ?? layers[0]
        if mask, primary.mask == nil {
            throw MCPToolError(.preconditionFailed, "'\(primary.name)' has no mask to target.",
                               hint: "Add one with add_layer_mask, or use target: pixels.", guard: "has_mask")
        }
        session.selectLayers(Set(layers.map(\.id)), primary: primary.id)
        session.isMaskSelected = mask && session.activeLayer?.mask != nil
        return ok([
            "active_layer_id": session.activeLayerID.map { .string($0.uuidString) } ?? .null,
            "selected_layer_ids": .array(layers.map { .string($0.id.uuidString) }),
            "target": .string(session.isMaskSelected ? "mask" : "pixels"),
        ])
    }

    static func mergeLayers(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let session = ctx.session
        let document = try ctx.editableDocument()
        if ctx.args.has("layer"), !ctx.args.has("layers") {
            throw MCPToolError.invalidArgument("merge_layers takes 'layers', not 'layer'.", hint: "Pass 'layers': [\"<the layer>\"] to merge it down.")
        }
        let ids = ctx.args.has("layers") ? try ctx.layers(in: document).map(\.id) : nil
        // What merges follows the selection, so the layers are selected to ask; a refused call puts it back.
        try keepingLayerSelectionOnFailure(session) {
            if let ids { session.selectLayers(Set(ids), primary: ids.last) }
            guard session.canMergeLayers else {
                throw MCPToolError(.preconditionFailed, "Nothing to merge: a single layer needs a pixel layer directly below it in its folder, a folder needs pixel layers inside it.",
                                   hint: "Pass several layers, a folder, or a layer with a pixel layer below it.", guard: "can_merge_layers")
            }
            let merging = session.mergingLayerIDs
            try MCPGuards.requireUnlocked(document.layers.filter { merging.contains($0.id) }, in: document, .pixels)
        }
        let action = session.mergeTitle
        let before = Set(document.layers.map(\.id))
        session.mergeLayers()
        guard let merged = session.activeLayerID, !before.contains(merged) else {
            throw MCPToolError(.internalError, "The layers could not be merged.")
        }
        return ctx.mutated(["merged_layer_id": .string(merged.uuidString), "action": .string(action)])
    }

    // MARK: Flatten and rasterize

    static func flattenImage(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let discardHidden = try ctx.args.bool("discard_hidden", default: true)
        let document = try ctx.editableDocument()
        let visible = document.effectiveVisibleIDs
        let hidden = document.layers.filter { !$0.isGroup && !visible.contains($0.id) }
        if !discardHidden, !hidden.isEmpty {
            throw MCPToolError(.preconditionFailed, "Flattening would discard \(hidden.count) hidden layer\(hidden.count == 1 ? "" : "s").",
                               hint: "Show or delete them first, or pass discard_hidden: true.", guard: "hidden_layers",
                               details: ["hidden_layer_ids": .array(hidden.map { .string($0.id.uuidString) })])
        }
        try await ctx.session.flattenImage(discardHidden: discardHidden)
        guard let flat = ctx.session.document?.layers.first, ctx.session.document?.layers.count == 1 else {
            throw MCPToolError(.internalError, "The document could not be flattened.")
        }
        return ctx.mutated(["layer_id": .string(flat.id.uuidString), "discarded_hidden": .int(hidden.count)])
    }

    static func rasterizeLayer(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        try MCPGuards.requireNotPlaceholder(layer)
        try MCPGuards.requirePixels(layer)
        try MCPGuards.requireUnlocked(layer, in: document, .pixels)
        try ctx.session.rasterizeLayer(layer.id)
        let kind = ctx.session.document?.layers.first { $0.id == layer.id }.map(MCPValues.kind(of:)) ?? "raster"
        return ctx.mutated(["layer_id": .string(layer.id.uuidString), "kind": .string(kind)])
    }

    /// `MCPGuards.requireUnlocked` for a layer (its own locks and its folders') and, when it is a folder, everything
    /// inside it.
    static func requireUnlocked(_ layer: ImageLayer, withContentsIn session: EditorSession, _ lock: LayerLocks) throws {
        try requireUnlocked([layer], withContentsIn: session, lock)
    }

    /// `requireUnlocked(_:withContentsIn:_:)` for each of `layers`, in order, each followed by what is inside it, with
    /// one look at the document's layers and locks for them all.
    static func requireUnlocked(_ layers: [ImageLayer], withContentsIn session: EditorSession, _ lock: LayerLocks) throws {
        let document = try MCPGuards.requireDocument(session)
        let children = Dictionary(grouping: document.layers, by: \.parentID)
        var checked: [ImageLayer] = [], seen = Set<UUID>()
        for layer in layers {
            var pending = [layer]
            while let next = pending.popLast() {
                guard seen.insert(next.id).inserted else { continue }
                checked.append(next)
                pending += (children[next.id] ?? []).reversed()
            }
        }
        try MCPGuards.requireUnlocked(checked, in: document, lock)
    }

    /// Runs `body` as one undo step named `name`: edits the session makes inside it nest into this one, and the step
    /// is closed even when `body` throws. An opacity drag the app has open is settled first, as the session's own
    /// commands settle it, so the step isn't folded into the drag's "Layer Opacity" entry.
    static func asOneStep<T>(_ session: EditorSession, _ name: String, _ body: () throws -> T) rethrows -> T {
        session.finishOpacityEdit()
        session.beginEdit(name)
        defer { session.endEdit() }
        return try body()
    }

    /// `asOneStep` for a `body` that awaits (placing a file as a smart object reads it first): the step stays open
    /// across the await, so what `body` does before and after it is still one undo step. Named apart from `asOneStep`
    /// so a synchronous body in an async handler never resolves to this one.
    static func asOneAwaitingStep<T>(_ session: EditorSession, _ name: String, _ body: () async throws -> T) async rethrows -> T {
        session.finishOpacityEdit()
        session.beginEdit(name)
        defer { session.endEdit() }
        return try await body()
    }

    /// Runs `body`, which may change the layer selection to ask the app about it; when `body` throws, the layer
    /// selection, mask target and selected effect are put back, so later '@active' calls act on the layer they did.
    static func keepingLayerSelectionOnFailure<T>(_ session: EditorSession, _ body: () throws -> T) rethrows -> T {
        let before = (selected: session.selectedLayerIDs, active: session.activeLayerID, mask: session.isMaskSelected,
                      effect: session.effectSelection)
        do {
            return try body()
        } catch {
            session.selectLayers(before.selected, primary: before.active)
            session.isMaskSelected = before.mask && session.activeLayer?.mask != nil
            session.effectSelection = before.effect
            throw error
        }
    }

    /// Moves the layer `insert` just added (at the end of the layers, in the active layer's folder) to where every
    /// other tool puts a new layer (`EditorSession.insertionIndex(above:in:)`): directly above `active`, or above the
    /// topmost contents of `active` when it's a folder. Part of the caller's undo step.
    private static func moveAboveActiveLayer(_ id: UUID, active: UUID?, session: EditorSession) {
        guard var layers = session.document?.layers, let from = layers.firstIndex(where: { $0.id == id }) else { return }
        let layer = layers.remove(at: from)
        layers.insert(layer, at: session.insertionIndex(above: active, in: layers))
        session.document?.layers = layers
    }

    /// A folder under Lock All takes no new layers, as in Photoshop: when the app put the new layer `id` inside one
    /// (inside it, or in a folder within it), it moves directly above the outermost such folder. Called inside the
    /// edit that made the layer, so the move is part of the same undo step.
    static func placeOutsideLockAllFolders(_ id: UUID, session: EditorSession) {
        guard let document = session.document, let layer = document.layers.first(where: { $0.id == id }) else { return }
        let byID = Dictionary(document.layers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var outermost: ImageLayer?
        var parent = layer.parentID, depth = 0
        while let folderID = parent, let folder = byID[folderID], depth <= 64 {
            if folder.locks.contains(.all) { outermost = folder }
            parent = folder.parentID
            depth += 1
        }
        guard let outermost else { return }
        session.placeLayer(id, in: outermost.parentID, above: outermost.id)
    }
}
