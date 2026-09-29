import Foundation
import MCP

// MARK: - Layer masks

extension MCPToolRegistry {
    static let maskTools: [MCPToolEntry] = [
        tool("add_layer_mask", title: "Add layer mask",
             description: "Adds a mask to a layer or folder: reveal_all (white), hide_all (black), from_selection or hide_selection. Paint it with stroke_path, fill_selection, draw_gradient or invert_pixels (target: mask); black hides, white reveals.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "kind": MCPSchema.enumString("What the mask shows.", MaskKind.allCases.map(\.rawValue), default: MaskKind.revealAll.rawValue),
             ],
             required: ["layer"], effect: .additive(idempotent: false), handler: addLayerMask),
        tool("set_mask_enabled", title: "Enable or disable layer mask",
             description: "Turns a layer's mask on or off, keeping its pixels.",
             properties: ["layer": MCPSchema.layerSelector(), "enabled": MCPSchema.bool("Apply the mask.")],
             required: ["layer", "enabled"], effect: .additive(idempotent: true), handler: setMaskEnabled),
        tool("set_mask_linked", title: "Link or unlink layer mask",
             description: "Links a layer's mask to it, so they move and transform together, or unlinks it, so the mask stays put on the document.",
             properties: ["layer": MCPSchema.layerSelector(), "linked": MCPSchema.bool("Link it.")],
             required: ["layer", "linked"], effect: .additive(idempotent: true), handler: setMaskLinked),
        tool("delete_layer_mask", title: "Delete layer mask",
             description: "Deletes a layer's mask, showing the whole layer again.",
             properties: ["layer": MCPSchema.layerSelector()],
             required: ["layer"], effect: .destructive(idempotent: false), handler: deleteLayerMask),
        tool("apply_layer_mask", title: "Apply layer mask",
             description: "Applies a layer's mask to its pixels, making what it hides transparent, and removes it. Text and shape layers become pixels; folders, adjustment layers, a disabled mask and Lock Pixels are refused.",
             properties: ["layer": MCPSchema.layerSelector()],
             required: ["layer"], effect: .destructive(idempotent: false), handler: applyLayerMask),
        tool("copy_layer_mask", title: "Copy layer mask",
             description: "Copies one layer's mask to another, replacing any mask it has, where the mask sits on the document. Folders can't take one.",
             properties: [
                 "from": MCPSchema.layerSelector("The layer whose mask is copied"),
                 "to": MCPSchema.layerSelector("The layer that takes the copy"),
             ],
             required: ["from", "to"], effect: .additive(idempotent: false), handler: copyLayerMask),
    ]

    /// What `add_layer_mask` makes.
    enum MaskKind: String, CaseIterable {
        case revealAll = "reveal_all", hideAll = "hide_all", fromSelection = "from_selection", hideSelection = "hide_selection"

        var usesSelection: Bool { self == .fromSelection || self == .hideSelection }
    }

    // MARK: Handlers

    static func addLayerMask(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let kind = try maskKind(ctx.args)
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        let session = ctx.session
        // Photoshop's Lock Pixels leaves the mask editable, as the app does: only Lock All holds it.
        try MCPGuards.requireUnlocked(layer, in: document, .all)
        guard layer.mask == nil else {
            throw MCPToolError(.preconditionFailed, "'\(layer.name)' already has a layer mask.",
                               hint: "Paint it with target: mask, or delete it with delete_layer_mask first.", guard: "no_mask")
        }
        if kind.usesSelection {
            guard let selection = session.selection else {
                throw MCPToolError(.preconditionFailed, "\(kind.rawValue) needs a selection.",
                                   hint: "Select the area first, e.g. with select_rect; reveal_all and hide_all need none.", guard: "selection")
            }
            if selection.isEmpty { throw emptySelectionError() }
        }
        try await withPixelTarget(ctx, layer, mask: false) {
            try MCPGuards.captureBrushError(session) {
                switch kind {
                case .revealAll: session.addLayerMask(revealing: true)
                case .hideAll: session.addLayerMask(revealing: false)
                // The app's selection masks are named by their color outside the selection: black shows only it.
                case .fromSelection: session.addMask(revealing: false)
                case .hideSelection: session.addMask(revealing: true)
                }
            }
            guard currentMask(of: layer, in: session) != nil else { throw cannotEditPixels(layer, session, guard: "can_edit_layers") }
        }
        return ctx.mutated(["layer_id": .string(layer.id.uuidString), "kind": .string(kind.rawValue),
                            "mask": maskValue(currentMask(of: layer, in: session))])
    }

    static func setMaskEnabled(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let enabled = try ctx.args.bool("enabled")
        let (layer, mask, document) = try maskedLayer(ctx)
        let session = ctx.session
        if mask.isEnabled != enabled {
            try MCPGuards.requireUnlocked(layer, in: document, .all)
            try await withPixelTarget(ctx, layer, mask: false) {
                session.toggleLayerMask()
                guard currentMask(of: layer, in: session)?.isEnabled == enabled else {
                    throw cannotEditPixels(layer, session, guard: "can_edit_layers")
                }
            }
        }
        return ctx.mutated(["layer_id": .string(layer.id.uuidString), "enabled": .bool(enabled)])
    }

    static func setMaskLinked(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let linked = try ctx.args.bool("linked")
        let (layer, mask, document) = try maskedLayer(ctx)
        let session = ctx.session
        if mask.isLinked != linked {
            try MCPGuards.requireUnlocked(layer, in: document, .all)
            session.toggleMaskLink(layer.id)
            guard currentMask(of: layer, in: session)?.isLinked == linked else {
                throw cannotEditPixels(layer, session, guard: "can_edit_layers")
            }
        }
        return ctx.mutated(["layer_id": .string(layer.id.uuidString), "linked": .bool(linked)])
    }

    static func deleteLayerMask(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let (layer, _, document) = try maskedLayer(ctx)
        let session = ctx.session
        try MCPGuards.requireUnlocked(layer, in: document, .all)
        try await withPixelTarget(ctx, layer, mask: false) {
            session.deleteLayerMask()
            guard currentMask(of: layer, in: session) == nil else { throw cannotEditPixels(layer, session, guard: "can_edit_layers") }
        }
        return ctx.mutated(["layer_id": .string(layer.id.uuidString)])
    }

    static func applyLayerMask(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        try MCPGuards.requireNotPlaceholder(layer)
        try MCPGuards.requirePixels(layer)
        guard let mask = layer.mask else { throw missingMask(layer) }
        guard mask.isEnabled else {
            throw MCPToolError(.preconditionFailed, "The mask of '\(layer.name)' is disabled, so it hides nothing to apply.",
                               hint: "Enable it with set_mask_enabled first, or remove it with delete_layer_mask.", guard: "mask_enabled")
        }
        // Unlike the other mask tools, this rewrites the layer's pixels (turning text, a shape or a smart object into
        // pixels), so Lock Pixels holds it as well as Lock All, the layer's own or a folder's, as it holds rasterize_layer.
        try MCPGuards.requireUnlocked(layer, in: document, .pixels)
        try await runHeadlessEdit { try ctx.session.applyLayerMask(layer.id) }
        return ctx.mutated(["layer_id": .string(layer.id.uuidString)])
    }

    static func copyLayerMask(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let document = try ctx.editableDocument()
        let source = try ctx.layer("from", in: document)
        let target = try ctx.layer("to", in: document)
        let session = ctx.session
        guard source.id != target.id else {
            throw MCPToolError.invalidArgument("'from' and 'to' are the same layer.", hint: "Copy the mask to another layer.")
        }
        guard let mask = source.mask else { throw missingMask(source) }
        guard !target.isGroup else {
            throw MCPToolError(.preconditionFailed, "'\(target.name)' is a folder; a copied mask goes on a layer.",
                               hint: "Give a folder a mask of its own with add_layer_mask.", guard: "not_folder")
        }
        try MCPGuards.requireUnlocked(target, in: document, .all)
        let replaced = target.mask != nil
        session.copyMask(from: source.id, to: target.id)
        let copied = currentMask(of: target, in: session)
        guard copied?.asset.image === mask.asset.image else { throw cannotEditPixels(target, session, guard: "can_edit_layers") }
        return ctx.mutated(["layer_id": .string(target.id.uuidString), "source_id": .string(source.id.uuidString),
                            "replaced": .bool(replaced), "mask": maskValue(copied)])
    }

    // MARK: Helpers

    static func maskKind(_ args: Args) throws -> MaskKind {
        guard let name = try args.optionalString("kind") else { return .revealAll }
        let target = normalized(name)
        guard let kind = MaskKind.allCases.first(where: { normalized($0.rawValue) == target }) else {
            throw MCPToolError.invalidArgument("Unknown mask kind '\(name)'.",
                                               hint: "Kinds: \(MaskKind.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return kind
    }

    /// The layer the call names, in a document that allows layer edits, and its mask, which it must have.
    static func maskedLayer(_ ctx: MCPCallContext) throws -> (ImageLayer, LayerMask, CanvasDocument) {
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        guard let mask = layer.mask else { throw missingMask(layer) }
        return (layer, mask, document)
    }

    static func missingMask(_ layer: ImageLayer) -> MCPToolError {
        MCPToolError(.preconditionFailed, "'\(layer.name)' has no layer mask.", hint: "Add one with add_layer_mask.", guard: "has_mask")
    }

    /// `layer`'s mask as the document holds it now.
    static func currentMask(of layer: ImageLayer, in session: EditorSession) -> LayerMask? {
        session.document?.layers.first { $0.id == layer.id }?.mask
    }

    static func maskValue(_ mask: LayerMask?) -> Value {
        mask.map { .object(["enabled": .bool($0.isEnabled), "linked": .bool($0.isLinked)]) } ?? .null
    }
}
