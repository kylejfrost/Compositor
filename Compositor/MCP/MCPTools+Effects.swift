import Foundation
import MCP

// MARK: - Layer effects

extension MCPToolRegistry {
    static let effectTools: [MCPToolEntry] = [
        tool("set_layer_effects", title: "Set layer effects",
             description: "Sets a layer's effects: stroke, shadow, color_overlay, inner_shadow, outer_glow and inner_glow. With merge (the default) only given fields change, a new effect starts from add_layer_effect's defaults and null removes one; merge false replaces the set. Unknown or out-of-range fields fail naming the field (color components clamp). Folders, adjustments and empty layers take no effects.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "effects": MCPSchema.object(
                     Dictionary(uniqueKeysWithValues: LayerEffectKind.allCases.map { (effectKey($0), MCPSchema.nullable(effectSchema($0))) }),
                     description: "Effects to set, each its fields or null to remove it."),
                 "merge": MCPSchema.bool("Patch the current effects; false replaces them.", default: true),
             ],
             required: ["layer", "effects"], effect: .destructive(idempotent: true), handler: setLayerEffects),
        tool("add_layer_effect", title: "Add layer effect",
             description: "Adds one effect at the app's defaults (a new stroke or color overlay takes the background color), then applies 'settings'; on an effect the layer has, only the settings change. No panel opens.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "kind": effectKindSchema,
                 "settings": MCPSchema.object([:], description: "Its fields, as set_layer_effects takes them."),
             ],
             required: ["layer", "kind"], effect: .additive(idempotent: false), handler: addLayerEffect),
        tool("remove_layer_effect", title: "Remove layer effect",
             description: "Removes one effect from a layer; not_found when it has none of that kind.",
             properties: ["layer": MCPSchema.layerSelector(), "kind": effectKindSchema],
             required: ["layer", "kind"], effect: .destructive(idempotent: false), handler: removeLayerEffect),
        tool("set_layer_effect_enabled", title: "Show or hide layer effect",
             description: "Shows or hides one of a layer's effects, keeping its settings.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "kind": effectKindSchema,
                 "enabled": MCPSchema.bool("Show it."),
             ],
             required: ["layer", "kind", "enabled"], effect: .additive(idempotent: true), handler: setLayerEffectEnabled),
    ]

    // MARK: Handlers

    static func setLayerEffects(_ ctx: MCPCallContext) throws -> CallTool.Result {
        guard let patch = try ctx.args.object("effects") else {
            throw MCPToolError.invalidArgument("Missing 'effects' object.",
                                               hint: "Pass e.g. {\"stroke\": {\"size\": 4, \"color\": \"#000000\"}, \"shadow\": null}.")
        }
        let merge = try ctx.args.bool("merge", default: true)
        let layer = try effectsLayer(ctx)
        let base = merge ? (layer.effects ?? LayerEffects()) : LayerEffects()
        let effects = try MCPCodable.decodeMerged(base, .object(try effectKeys(patch)), template: newEffects(ctx.session))
        return try commitEffects(effects, on: layer, ctx: ctx) { $0.setEffects($1, on: layer.id, name: "Layer Effects") }
    }

    static func addLayerEffect(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let kind = try effectKind(ctx)
        let settings = try ctx.args.object("settings") ?? [:]
        let layer = try effectsLayer(ctx)
        let current = layer.effects ?? LayerEffects()
        let added = !current.contains(kind)
        let effects = try MCPCodable.decodeMerged(current, .object([effectKey(kind): .object(settings)]),
                                                  template: newEffects(ctx.session))
        return try commitEffects(effects, on: layer, ctx: ctx, fields: ["kind": .string(effectName(kind)), "added": .bool(added)]) {
            $0.setEffects($1, on: layer.id, name: (added ? "Add " : "Edit ") + kind.rawValue)
        }
    }

    static func removeLayerEffect(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let kind = try effectKind(ctx)
        let layer = try effectsLayer(ctx)
        var effects = try requireEffect(kind, on: layer)
        effects.remove(kind)
        return try commitEffects(effects, on: layer, ctx: ctx, fields: ["kind": .string(effectName(kind))]) {
            $0.setEffects($1, on: layer.id, name: "Remove " + kind.rawValue)
        }
    }

    static func setLayerEffectEnabled(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let kind = try effectKind(ctx)
        let enabled = try ctx.args.bool("enabled")
        let layer = try effectsLayer(ctx)
        var effects = try requireEffect(kind, on: layer)
        effects.setEnabled(enabled, for: kind)
        return try commitEffects(effects, on: layer, ctx: ctx, fields: ["kind": .string(effectName(kind)), "enabled": .bool(enabled)]) { session, _ in
            session.toggleEffect(kind, on: layer.id)
        }
    }

    // MARK: Helpers

    /// The layer the call names, once it can carry effects: a layer with pixels of its own (not a Photoshop
    /// placeholder, a folder, an adjustment layer or an empty layer) in a document that allows layer edits, not held by
    /// Lock All (its own or a folder's). Photoshop's pixel lock leaves layer styles editable. A placeholder is named
    /// first: import keeps one without pixels, and the empty-layer hint would send the agent to paint it.
    static func effectsLayer(_ ctx: MCPCallContext) throws -> ImageLayer {
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        try MCPGuards.requireNotPlaceholder(layer)
        try MCPGuards.requirePixels(layer)
        guard layer.asset != nil else {
            throw MCPToolError(.preconditionFailed, "'\(layer.name)' has no pixels yet; effects draw around a layer's pixels.",
                               hint: "Paint or place something on it first.", guard: "has_pixels")
        }
        try MCPGuards.requireUnlocked(layer, in: document, .all)
        return layer
    }

    /// The layer's effects, which must include `kind`.
    static func requireEffect(_ kind: LayerEffectKind, on layer: ImageLayer) throws -> LayerEffects {
        let effects = layer.effects ?? LayerEffects()
        guard effects.contains(kind) else {
            let present = effects.kinds.map(effectName)
            throw MCPToolError.notFound("'\(layer.name)' has no \(effectName(kind)) effect.",
                                        hint: present.isEmpty ? "It has no effects." : "It has: \(present.joined(separator: ", ")).")
        }
        return effects
    }

    /// Writes `effects` to the layer through `write` (given the session and the effects to write) as one undo
    /// step, unless they are what the layer already has, and reports the layer's effects.
    static func commitEffects(_ effects: LayerEffects, on layer: ImageLayer, ctx: MCPCallContext, fields: [String: Value] = [:],
                              write: (EditorSession, LayerEffects) -> Void) throws -> CallTool.Result {
        let session = ctx.session
        let current = layer.effects ?? LayerEffects()
        let effects = keepingImplicitEnabled(effects, from: current)
        if effects != current {
            // The app's effects panel puts its effect back as it was on Cancel, so one open on an effect this call
            // changes is closed first, keeping its edits, as copying an effect does.
            if let editing = session.effectsEditing, editing.layerID == layer.id,
               only(editing.kind, of: effects) != only(editing.kind, of: current) {
                session.finishEffectsEditing(commit: true)
            }
            write(session, effects)
        }
        let applied = session.document?.layers.first { $0.id == layer.id }?.effects ?? LayerEffects()
        guard applied == effects else { throw MCPToolError(.internalError, "The effects could not be applied to '\(layer.name)'.") }
        var out = fields
        out["layer_id"] = .string(layer.id.uuidString)
        out["effects"] = try effectsValue(applied)
        return ctx.mutated(out)
    }

    /// Each effect the app would add, at the settings `addEffect` gives a new one.
    static func newEffects(_ session: EditorSession) -> LayerEffects {
        LayerEffectKind.allCases.reduce(LayerEffects()) { session.addingNewEffect($1, to: $0) }
    }

    /// `effects` with `enabled: true` put back to the unset value it replaced: both mean shown, so saying so
    /// again changes nothing.
    static func keepingImplicitEnabled(_ effects: LayerEffects, from current: LayerEffects) -> LayerEffects {
        var out = effects
        if current.stroke?.enabled == nil, out.stroke?.enabled == true { out.stroke?.enabled = nil }
        if current.shadow?.enabled == nil, out.shadow?.enabled == true { out.shadow?.enabled = nil }
        if current.colorOverlay?.enabled == nil, out.colorOverlay?.enabled == true { out.colorOverlay?.enabled = nil }
        if current.innerShadow?.enabled == nil, out.innerShadow?.enabled == true { out.innerShadow?.enabled = nil }
        if current.outerGlow?.enabled == nil, out.outerGlow?.enabled == true { out.outerGlow?.enabled = nil }
        if current.innerGlow?.enabled == nil, out.innerGlow?.enabled == true { out.innerGlow?.enabled = nil }
        return out
    }

    /// Just the `kind` effect of `effects`.
    static func only(_ kind: LayerEffectKind, of effects: LayerEffects) -> LayerEffects {
        var out = effects
        for other in LayerEffectKind.allCases where other != kind { out.remove(other) }
        return out
    }

    /// A layer's effects as tools report them: snake_case fields, with `enabled` spelled out.
    static func effectsValue(_ effects: LayerEffects) throws -> Value {
        var shown = effects
        for kind in effects.kinds { shown.setEnabled(effects.isEnabled(kind), for: kind) }
        return try MCPCodable.encode(shown)
    }

    // MARK: Kinds

    /// How tools name an effect kind (`drop_shadow`).
    static func effectName(_ kind: LayerEffectKind) -> String {
        switch kind {
        case .stroke: "stroke"
        case .shadow: "drop_shadow"
        case .colorOverlay: "color_overlay"
        case .innerShadow: "inner_shadow"
        case .outerGlow: "outer_glow"
        case .innerGlow: "inner_glow"
        }
    }

    /// The effect's key in a layer's `effects` object (`shadow` for the drop shadow).
    static func effectKey(_ kind: LayerEffectKind) -> String {
        kind == .shadow ? "shadow" : effectName(kind)
    }

    /// The kind `name` means, ignoring case, spaces and punctuation: a tool name, an effects key or the app's label.
    static func effectKind(_ name: String) -> LayerEffectKind? {
        let target = normalized(name)
        return LayerEffectKind.allCases.first { kind in
            [effectName(kind), effectKey(kind), kind.rawValue].contains { normalized($0) == target }
        }
    }

    static func effectKind(_ ctx: MCPCallContext) throws -> LayerEffectKind {
        let name = try ctx.args.string("kind")
        guard let kind = effectKind(name) else {
            throw MCPToolError.invalidArgument("Unknown effect kind '\(name)'.",
                                               hint: "Kinds: \(LayerEffectKind.allCases.map(effectName).joined(separator: ", ")).")
        }
        return kind
    }

    /// `patch` with each effect under the key `LayerEffects` stores it by (`drop_shadow` → `shadow`). Names that
    /// aren't effects pass through, for `decodeMerged` to report.
    static func effectKeys(_ patch: [String: Value]) throws -> [String: Value] {
        var out: [String: Value] = [:]
        for (name, value) in patch {
            let key = effectKind(name).map(effectKey) ?? name
            guard out[key] == nil else { throw MCPToolError.invalidArgument("'effects' gives the \(key) effect twice.") }
            out[key] = value
        }
        return out
    }

    // MARK: Schemas

    static var effectKindSchema: Value {
        MCPSchema.enumString("Effect kind.", LayerEffectKind.allCases.map(effectName))
    }

    static func effectSchema(_ kind: LayerEffectKind) -> Value {
        var fields: [String: Value] = [
            "color": MCPSchema.color(nil),
            "opacity": MCPSchema.num("Opacity.", min: 0, max: 1),
            "enabled": MCPSchema.bool("false hides it."),
        ]
        switch kind {
        case .stroke:
            fields["size"] = MCPSchema.num("Width in pixels.", min: 0, max: Double(StrokeEffect.maxSize))
            fields["inside"] = MCPSchema.bool("Inside the layer's edge.")
        case .shadow, .innerShadow:
            let maxDistance = kind == .shadow ? ShadowEffect.maxDistance : InnerShadowEffect.maxDistance
            let maxBlur = kind == .shadow ? ShadowEffect.maxBlur : InnerShadowEffect.maxBlur
            fields["angle"] = MCPSchema.num("Light angle, degrees counterclockwise from the right; 90 is from above.",
                                            min: -360, max: 360)
            fields["distance"] = MCPSchema.num("Offset in pixels.", min: 0, max: Double(maxDistance))
            fields["blur"] = MCPSchema.num("Softness in pixels.", min: 0, max: Double(maxBlur))
        case .colorOverlay:
            break
        case .outerGlow, .innerGlow:
            fields["size"] = MCPSchema.num("Spread in pixels.", min: 0,
                                           max: Double(kind == .outerGlow ? OuterGlowEffect.maxSize : InnerGlowEffect.maxSize))
        }
        return MCPSchema.object(fields, description: kind.rawValue + ".")
    }
}

// MARK: - Patching

nonisolated extension LayerEffects: MCPPatchable {
    static let mcpFieldRanges: [String: ClosedRange<Double>] = {
        var ranges: [String: ClosedRange<Double>] = [
            "stroke.size": 0...Double(StrokeEffect.maxSize),
            "shadow.angle": -360...360,
            "shadow.distance": 0...Double(ShadowEffect.maxDistance),
            "shadow.blur": 0...Double(ShadowEffect.maxBlur),
            "inner_shadow.angle": -360...360,
            "inner_shadow.distance": 0...Double(InnerShadowEffect.maxDistance),
            "inner_shadow.blur": 0...Double(InnerShadowEffect.maxBlur),
            "outer_glow.size": 0...Double(OuterGlowEffect.maxSize),
            "inner_glow.size": 0...Double(InnerGlowEffect.maxSize),
        ]
        for effect in ["stroke", "shadow", "color_overlay", "inner_shadow", "outer_glow", "inner_glow"] {
            for field in ["red", "green", "blue", "opacity"] { ranges[effect + "." + field] = 0...1 }
        }
        return ranges
    }()
}
