import Foundation
import MCP

// MARK: - Adjustment layers

extension MCPToolRegistry {
    static let adjustmentTools: [MCPToolEntry] = [
        tool("add_adjustment_layer", title: "Add adjustment layer",
             description: "Adds an adjustment layer of 'kind' above the active layer, optionally named, clipped to the layer below (clip_to_below) and configured with 'settings' as set_adjustment takes them, as one step. A Profile layer is named after its profile; no settings panel opens.",
             properties: [
                 "kind": adjustmentKindSchema,
                 "settings": MCPSchema.object([:], description: "Settings, as set_adjustment takes them."),
                 "name": MCPSchema.str("Layer name (default the kind, or the profile)."),
                 "clip_to_below": MCPSchema.bool("Clip to the layer below, adjusting only it.",
                                                 default: false),
             ],
             required: ["kind"], effect: .additive(idempotent: false), handler: addAdjustmentLayer),
        tool("set_adjustment", title: "Set adjustment",
             description: "Changes an adjustment layer's settings; only what is given changes. Shorthand keys — hue_saturation: hue, saturation, lightness, colorize; levels: channel, black, gamma, white, output_black, output_white; curves: channel, points [[x, y], …]; exposure: exposure, offset, gamma; gradient_map: shadows, highlights, reversed; grain: amount, size, roughness; gaussian_blur: radius; motion_blur: angle, distance; add_noise: amount, gaussian, monochromatic; black_white: reds…magentas, tint, tint_hue, tint_saturation; color_balance: shadow_, mid_ or highlight_ cyan_red, magenta_green, yellow_blue, preserve_luminosity; profile: profile (a list_profiles id or name; null for none), amount (0–200). The full settings it returns patch too: objects merge, arrays replace, null removes. An unknown or out-of-range key fails naming the field.",
             properties: [
                 "layer": MCPSchema.layerSelector("The adjustment layer"),
                 "settings": MCPSchema.object([:], description: "Shorthand keys, or the full form this tool returns."),
             ],
             required: ["layer", "settings"], effect: .additive(idempotent: true), handler: setAdjustment),
    ]

    // MARK: Handlers

    static func addAdjustmentLayer(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let kind = try adjustmentKind(ctx)
        let name = try ctx.args.optionalString("name")
        if let name, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MCPToolError(.invalidArgument, "'name' can't be blank.", hint: "Leave it out to name the layer after its kind.",
                               details: ["field": .string("name")])
        }
        let clip = try ctx.args.bool("clip_to_below", default: false)
        _ = try ctx.editableDocument()
        // A profile named by `profile` is loaded before the edit begins; the document is read again after the wait.
        let settings = try await resolvingProfileShorthand(try ctx.args.object("settings"), kind: kind)
        let document = try ctx.editableDocument()
        // The app's own limit, which `addAdjustment` enforces by adding nothing.
        try MCPGuards.requireLayerCapacity(document)
        let session = ctx.session
        let before = (document: session.document, active: session.activeLayerID, selected: session.selectedLayerIDs,
                      collapsed: session.collapsedGroupIDs, mask: session.isMaskSelected)
        session.beginEdit("New \(kind.rawValue) Adjustment")
        let id: UUID
        do {
            id = try addConfiguredAdjustment(kind, settings: settings, name: name, clip: clip, session: session)
        } catch {
            // Leave nothing behind: the layer and its settings are one step, so the edit closes unchanged and
            // records no history entry.
            session.document = before.document
            session.activeLayerID = before.active
            session.selectedLayerIDs = before.selected
            session.collapsedGroupIDs = before.collapsed
            // After the active layer, whose change clears it.
            session.isMaskSelected = before.mask
            session.endEdit()
            throw error
        }
        session.endEdit()
        guard let layer = session.document?.layers.first(where: { $0.id == id }), let adjustment = layer.adjustment else {
            throw MCPToolError(.internalError, "Could not add the adjustment layer.")
        }
        return ctx.mutated([
            "layer_id": .string(id.uuidString),
            "name": .string(layer.name),
            "kind": .string(adjustmentKindName(kind)),
            "clipping": .bool(layer.maskSourceID != nil),
            "settings": try adjustmentSettingsValue(adjustment),
        ])
    }

    static func setAdjustment(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        guard var settings = try ctx.args.object("settings") else {
            throw MCPToolError.invalidArgument("Missing 'settings' object.",
                                               hint: "Pass e.g. {\"saturation\": -30} for Hue/Saturation or {\"black\": 20} for Levels.")
        }
        // A profile named by `profile` is loaded first; the layer is read again after the wait.
        let kind = try requireAdjustment(try ctx.layer(in: try ctx.editableDocument())).kind
        settings = try await resolvingProfileShorthand(settings, kind: kind) ?? settings
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        let current = try requireAdjustment(layer)
        // Only Lock All holds an adjustment's settings: Photoshop's pixel lock doesn't apply to them.
        try MCPGuards.requireUnlocked(layer, in: document, .all)
        let value = try patchedAdjustment(current, with: settings)
        ctx.session.setAdjustment(layer.id, value: value)
        guard ctx.session.document?.layers.first(where: { $0.id == layer.id })?.adjustment == value else {
            throw MCPToolError(.internalError, "The settings could not be applied to '\(layer.name)'.")
        }
        return ctx.mutated([
            "layer_id": .string(layer.id.uuidString),
            "kind": .string(adjustmentKindName(current.kind)),
            "settings": try adjustmentSettingsValue(value),
        ])
    }

    /// Adds an adjustment layer inside the caller's edit, then names, clips and configures it, returning its id.
    /// Throws as soon as a part fails, leaving the caller to put the document back.
    static func addConfiguredAdjustment(_ kind: AdjustmentKind, settings: [String: Value]?, name: String?, clip: Bool,
                                        session: EditorSession) throws -> UUID {
        let previous = session.activeLayerID
        session.addAdjustment(kind)
        // The app opens a settings panel for a new adjustable layer; an agent's call must not.
        session.adjustmentEditingID = nil
        session.adjustmentOriginal = nil
        guard let id = session.activeLayerID, id != previous,
              let added = session.document?.layers.first(where: { $0.id == id })?.adjustment else {
            throw MCPToolError(.internalError, "Could not add the adjustment layer.")
        }
        placeOutsideLockAllFolders(id, session: session)
        if let name { session.renameLayer(id, to: name) }
        if clip {
            guard session.canToggleClippingMask(id) else {
                throw MCPToolError(.preconditionFailed,
                                   "The new layer has nothing to clip to: clipping needs a layer that isn't a folder directly below it, in the same folder.",
                                   hint: "Make that layer active first, or leave out clip_to_below.", guard: "can_clip")
            }
            session.toggleClippingMask(id)
        }
        if let settings { session.setAdjustment(id, value: try patchedAdjustment(added, with: settings)) }
        // Named after its profile, as the app names the Profile layers it adds, unless the call names it.
        if name == nil, kind == .profile,
           let profile = session.document?.layers.first(where: { $0.id == id })?.adjustment?.profile.reference?.name {
            session.renameLayer(id, to: profile)
        }
        return id
    }

    /// The layer's adjustment settings. A Photoshop adjustment or fill layer Compositor can't apply is kept only to
    /// be written back, so it has none to change.
    static func requireAdjustment(_ layer: ImageLayer) throws -> LayerAdjustment {
        if let placeholder = layer.psdExtras?.placeholder {
            let what = placeholder.hasPrefix("fill:") ? "fill layer" : "adjustment layer"
            throw MCPToolError(.unsupported,
                               "'\(layer.name)' is a Photoshop \(what) Compositor can't apply; it is kept hidden and unchanged only so it can be written back to Photoshop.",
                               hint: "Add a Compositor adjustment layer with add_adjustment_layer instead.",
                               guard: "placeholder", details: ["placeholder": .string(placeholder)])
        }
        guard let adjustment = layer.adjustment else {
            throw MCPToolError(.preconditionFailed, "'\(layer.name)' is not an adjustment layer.",
                               hint: "add_adjustment_layer adds one.", guard: "is_adjustment")
        }
        return adjustment
    }

    // MARK: Kinds

    /// How tools name an adjustment kind (`hue_saturation`, `black_white`).
    static func adjustmentKindName(_ kind: AdjustmentKind) -> String {
        MCPCodable.enumName(kind.rawValue)
    }

    static var adjustmentKindSchema: Value {
        MCPSchema.enumString("Adjustment kind.",
                             AdjustmentKind.allCases.map(adjustmentKindName))
    }

    static func adjustmentKind(_ ctx: MCPCallContext) throws -> AdjustmentKind {
        let name = try ctx.args.string("kind")
        guard let kind = adjustmentKind(name) else {
            throw MCPToolError.invalidArgument("Unknown adjustment kind '\(name)'.",
                                               hint: "Kinds: \(AdjustmentKind.allCases.map(adjustmentKindName).joined(separator: ", ")).")
        }
        return kind
    }

    static func adjustmentKind(_ name: String) -> AdjustmentKind? {
        let target = normalized(name)
        let aliases: [String: AdjustmentKind] = [
            "hsv": .hsv, "huesat": .hsv, "huesaturation": .hsv,
            "blackandwhite": .blackWhite, "blackwhite": .blackWhite, "bandw": .blackWhite,
            "colors": .hsv, "invert": .invert,
        ]
        if let alias = aliases[target] { return alias }
        return AdjustmentKind.allCases.first { normalized($0.rawValue) == target }
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Settings

    /// `current` with `settings` applied: the kind's shorthand keys, then everything merged through
    /// `MCPCodable.decodeMerged`. Fails naming the field for a setting the kind doesn't have, a mistyped value or one
    /// out of range, and for a `kind` other than the layer's.
    static func patchedAdjustment(_ current: LayerAdjustment, with settings: [String: Value]) throws -> LayerAdjustment {
        var settings = settings
        if let kind = settings.removeValue(forKey: "kind"), kind != .null {
            guard let name = kind.stringValue, adjustmentKind(name) == current.kind else {
                throw MCPToolError(.invalidArgument, "An adjustment layer's kind can't change; this one is \(adjustmentKindName(current.kind)).",
                                   hint: "Add a layer of the other kind with add_adjustment_layer.", details: ["field": .string("kind")])
            }
        }
        let patch = try expandingShorthand(settings, for: current)
        let fields = adjustmentSettingFields(current.kind)
        if let key = patch.keys.sorted().first(where: { !fields.contains($0) }) {
            let names = adjustmentSettingNames(current.kind)
            throw MCPToolError(.invalidArgument, "'\(key)' isn't a setting of this \(current.kind.rawValue) layer.",
                               hint: names.isEmpty ? "\(current.kind.rawValue) has no settings." : "Its settings: \(names.joined(separator: ", ")).",
                               details: ["field": .string(key)])
        }
        let patched = try MCPCodable.decodeMerged(current, .object(patch), template: adjustmentWithDefaults(current))
        let result = keepingImplicitDefaults(patched, from: current)
        if result.kind == .hsv {
            // Flat fields until the layer has range settings, which replace them (see `adjustmentSettingsValue`).
            try requireDialogHues(result.resolvedHSV) { range in
                result.hsvSettings == nil ? "hue" : "hsv_settings.adjustments.\(MCPCodable.enumName(range.rawValue)).hue"
            }
        }
        try requireApplicableProfile(result)
        return result
    }

    /// A Profile layer's reference must name a loaded profile, and a profile without Amount stays at 100.
    static func requireApplicableProfile(_ adjustment: LayerAdjustment) throws {
        guard adjustment.kind == .profile, let reference = adjustment.profile.reference else { return }
        guard let loaded = ProfileRegistry.shared.profile(reference.digest) else {
            throw MCPToolError(.notFound, "No loaded profile has digest \(reference.digest.hex).",
                               hint: "Choose a profile with list_profiles and set_adjustment's profile key.",
                               details: ["field": .string("profile_settings.reference")])
        }
        if !loaded.profile.support.contains(.amount), adjustment.profile.amount != 100 {
            throw MCPToolError(.invalidArgument, "“\(loaded.profile.name)” has no Amount; its amount stays 100.",
                               details: ["field": .string("amount")])
        }
    }

    /// `patched` with each optional member `current` leaves unset put back to unset where the patch gave it the
    /// value it takes while unset (as reported settings do): saying so again changes nothing.
    static func keepingImplicitDefaults(_ patched: LayerAdjustment, from current: LayerAdjustment) -> LayerAdjustment {
        var out = patched
        func keep<T: Equatable>(_ member: WritableKeyPath<LayerAdjustment, T?>, _ implicit: T?) {
            if current[keyPath: member] == nil, out[keyPath: member] == implicit { out[keyPath: member] = nil }
        }
        keep(\.hsvSettings, adjustmentWithDefaults(current).hsvSettings)
        keep(\.exposureSettings, current.exposure)
        keep(\.gradientMapSettings, current.gradientMap)
        keep(\.grainSettings, current.grain)
        keep(\.blackWhiteSettings, current.blackWhite)
        keep(\.colorBalanceSettings, current.colorBalance)
        keep(\.profileSettings, current.profile)
        keep(\.blurRadius, current.gaussianRadius)
        keep(\.motionAngle, current.resolvedMotionAngle)
        keep(\.motionDistance, current.resolvedMotionDistance)
        keep(\.noiseAmount, current.resolvedNoiseAmount)
        keep(\.noiseGaussian, current.resolvedNoiseGaussian)
        keep(\.noiseMonochromatic, current.resolvedNoiseMonochromatic)
        keep(\.noiseSeed, current.resolvedNoiseSeed)
        return out
    }

    /// An adjustment's settings as tools report them: the members its kind uses, in `MCPCodable.agentForm`, with
    /// optional ones at the values they take while unset. A Hue/Saturation layer shows its flat fields until it has
    /// range settings, which replace them.
    static func adjustmentSettingsValue(_ adjustment: LayerAdjustment) throws -> Value {
        var shown = adjustmentWithDefaults(adjustment)
        shown.hsvSettings = adjustment.hsvSettings
        let fields = adjustment.kind == .hsv
            ? (adjustment.hsvSettings == nil ? ["hue", "saturation", "lightness", "colorize"] : ["hsv_settings"])
            : adjustmentSettingFields(adjustment.kind)
        return .object((try MCPCodable.agentForm(shown).objectValue ?? [:]).filter { fields.contains($0.key) })
    }

    /// The members of `LayerAdjustment` (snake_case) that hold a kind's settings.
    static func adjustmentSettingFields(_ kind: AdjustmentKind) -> [String] {
        switch kind {
        case .hsv: ["hue", "saturation", "lightness", "colorize", "hsv_settings"]
        case .levels: ["levels"]
        case .curves: ["curves"]
        case .exposure: ["exposure_settings"]
        case .gradientMap: ["gradient_map_settings"]
        case .grain: ["grain_settings"]
        case .gaussianBlur: ["blur_radius"]
        case .motionBlur: ["motion_angle", "motion_distance"]
        case .addNoise: ["noise_amount", "noise_gaussian", "noise_monochromatic", "noise_seed"]
        case .invert: []
        case .blackWhite: ["black_white_settings"]
        case .colorBalance: ["color_balance_settings"]
        case .profile: ["profile_settings"]
        }
    }

    /// Every key `set_adjustment` takes for a kind: its shorthand keys, then its members.
    static func adjustmentSettingNames(_ kind: AdjustmentKind) -> [String] {
        let shorthand: [String] = switch kind {
        case .hsv: ["hue", "saturation", "lightness", "colorize"]
        case .levels: ["channel", "black", "gamma", "white", "output_black", "output_white"]
        case .curves: ["channel", "points"]
        case .profile: ["profile"] + adjustmentShorthand(kind).map(\.key)
        default: adjustmentShorthand(kind).map(\.key)
        }
        return shorthand + adjustmentSettingFields(kind).filter { !shorthand.contains($0) }
    }

    /// `adjustment` with every optional member at the value it takes while unset, and a Hue/Saturation entry and
    /// band for every color range: what a patch that adds one of them starts from.
    static func adjustmentWithDefaults(_ adjustment: LayerAdjustment) -> LayerAdjustment {
        var out = adjustment
        var hsv = adjustment.resolvedHSV
        for range in ColorRange.allCases {
            if hsv.adjustments[range] == nil { hsv.adjustments[range] = RangeAdjustment() }
            if hsv.bands[range] == nil { hsv.bands[range] = range.defaultBand }
        }
        out.hsvSettings = hsv
        out.exposure = adjustment.exposure
        out.gradientMap = adjustment.gradientMap
        out.grain = adjustment.grain
        out.blackWhite = adjustment.blackWhite
        out.colorBalance = adjustment.colorBalance
        out.profile = adjustment.profile
        out.gaussianRadius = adjustment.gaussianRadius
        out.resolvedMotionAngle = adjustment.resolvedMotionAngle
        out.resolvedMotionDistance = adjustment.resolvedMotionDistance
        out.resolvedNoiseAmount = adjustment.resolvedNoiseAmount
        out.resolvedNoiseGaussian = adjustment.resolvedNoiseGaussian
        out.resolvedNoiseMonochromatic = adjustment.resolvedNoiseMonochromatic
        out.resolvedNoiseSeed = adjustment.resolvedNoiseSeed
        return out
    }

    // MARK: Shorthand

    /// What a shorthand key takes.
    enum AdjustmentShorthandType {
        case number, bool, color
    }

    /// The shorthand keys of the kinds whose keys each stand for one field: the key, where its value goes, and what
    /// it takes. Hue/Saturation, Levels and Curves have shorthand of their own (see `expandingShorthand`).
    static func adjustmentShorthand(_ kind: AdjustmentKind) -> [(key: String, path: [String], type: AdjustmentShorthandType)] {
        func fields(_ member: String, _ keys: [String], _ type: AdjustmentShorthandType = .number)
            -> [(key: String, path: [String], type: AdjustmentShorthandType)] {
            keys.map { ($0, [member, $0], type) }
        }
        switch kind {
        case .exposure:
            return fields("exposure_settings", ["exposure", "offset", "gamma"])
        case .gradientMap:
            return fields("gradient_map_settings", ["shadows", "highlights"], .color) + fields("gradient_map_settings", ["reversed"], .bool)
        case .grain:
            return fields("grain_settings", ["amount", "size", "roughness"])
        case .gaussianBlur:
            return [("radius", ["blur_radius"], .number)]
        case .motionBlur:
            return [("angle", ["motion_angle"], .number), ("distance", ["motion_distance"], .number)]
        case .addNoise:
            return [("amount", ["noise_amount"], .number), ("gaussian", ["noise_gaussian"], .bool),
                    ("monochromatic", ["noise_monochromatic"], .bool)]
        case .blackWhite:
            return fields("black_white_settings", ["reds", "yellows", "greens", "cyans", "blues", "magentas", "tint_hue", "tint_saturation"])
                + fields("black_white_settings", ["tint"], .bool)
        case .colorBalance:
            let tones = ["shadow", "mid", "highlight"].flatMap { tone in ["cyan_red", "magenta_green", "yellow_blue"].map { tone + "_" + $0 } }
            return fields("color_balance_settings", tones) + fields("color_balance_settings", ["preserve_luminosity"], .bool)
        case .profile:
            return fields("profile_settings", ["amount"])
        case .hsv, .levels, .curves, .invert:
            return []
        }
    }

    /// `settings` with the kind's shorthand keys moved to the members that keep their values. Fails naming the key
    /// when one has the wrong type, or when the patch also sets its field in full.
    static func expandingShorthand(_ settings: [String: Value], for current: LayerAdjustment) throws -> [String: Value] {
        var patch = settings
        func take(_ key: String, _ type: AdjustmentShorthandType) throws -> Value? {
            guard let value = patch.removeValue(forKey: key) else { return nil }
            try requireShorthand(value, type, key: key)
            return value
        }
        func move(_ key: String, to path: [String], _ type: AdjustmentShorthandType) throws {
            guard let value = try take(key, type) else { return }
            try insertShorthand(value, at: path[...], into: &patch, key: key)
        }
        func takeChannel() throws -> LevelsChannel? {
            guard let value = patch.removeValue(forKey: "channel") else { return nil }
            guard let name = value.stringValue, let channel = LevelsChannel.allCases.first(where: { normalized($0.rawValue) == normalized(name) }) else {
                let names = LevelsChannel.allCases.map { MCPCodable.enumName($0.rawValue) }
                throw MCPToolError(.invalidArgument, "'channel' must be one of: \(names.joined(separator: ", ")).",
                                   details: ["field": .string("channel")])
            }
            return channel
        }
        /// The current channel list of `member` (`levels.ranges`, `curves.channels`) with `channel`'s entry replaced.
        func channels(_ member: String, _ list: String, replacing channel: LevelsChannel, with change: (Value) -> Value) throws -> Value {
            guard var items = try MCPCodable.agentForm(current).objectValue?[member]?.objectValue?[list]?.arrayValue,
                  items.indices.contains(channel.index) else {
                throw MCPToolError(.internalError, "The layer's \(member).\(list) can't be read.")
            }
            items[channel.index] = change(items[channel.index])
            return .array(items)
        }

        switch current.kind {
        case .hsv:
            // Once a layer has range settings they replace the flat fields, so the shorthand edits their Master range.
            let ranged = current.hsvSettings != nil || patch["hsv_settings"]?.objectValue != nil
            for key in ["hue", "saturation", "lightness"] {
                try move(key, to: ranged ? ["hsv_settings", "adjustments", "master", key] : [key], .number)
            }
            try move("colorize", to: ranged ? ["hsv_settings", "colorize"] : ["colorize"], .bool)
        case .levels:
            let channel = try takeChannel()
            var range: [String: Value] = [:]
            for key in ["black", "gamma", "white", "output_black", "output_white"] {
                if let value = try take(key, .number) { range[key] = value }
            }
            if let key = range.keys.sorted().first {
                let ranges = try channels("levels", "ranges", replacing: channel ?? .rgb) {
                    .object(($0.objectValue ?? [:]).merging(range) { $1 })
                }
                try insertShorthand(ranges, at: ["levels", "ranges"], into: &patch, key: key)
            }
            if let channel { try insertShorthand(.string(MCPCodable.enumName(channel.rawValue)), at: ["levels", "channel"], into: &patch, key: "channel") }
        case .curves:
            let channel = try takeChannel()
            if let given = patch.removeValue(forKey: "points") {
                let points = Value.array(try curvePoints(given))
                let curves = try channels("curves", "channels", replacing: channel ?? .rgb) { _ in points }
                try insertShorthand(curves, at: ["curves", "channels"], into: &patch, key: "points")
            }
            if let channel { try insertShorthand(.string(MCPCodable.enumName(channel.rawValue)), at: ["curves", "channel"], into: &patch, key: "channel") }
        default:
            for (key, path, type) in adjustmentShorthand(current.kind) { try move(key, to: path, type) }
        }
        return patch
    }

    static func requireShorthand(_ value: Value, _ type: AdjustmentShorthandType, key: String) throws {
        let expected: String? = switch type {
        case .number: MCPValues.number(value) == nil ? "a finite number" : nil
        case .bool: value.boolValue == nil ? "true or false" : nil
        // `decodeMerged` reads the color itself.
        case .color: value.stringValue == nil && value.objectValue == nil ? "a color: {\"r\", \"g\", \"b\"} in 0–1, or \"#rrggbb\"" : nil
        }
        if let expected {
            throw MCPToolError(.invalidArgument, "'\(key)' must be \(expected).", details: ["field": .string(key)])
        }
    }

    /// Puts shorthand `key`'s value at `path` in `patch`, failing when the patch also sets that field in full.
    static func insertShorthand(_ value: Value, at path: ArraySlice<String>, into patch: inout [String: Value], key: String,
                                field: String? = nil) throws {
        let field = field ?? path.joined(separator: ".")
        guard let first = path.first else { return }
        let conflict = MCPToolError(.invalidArgument, "'\(key)' and '\(field)' both set the same setting; give one of them.",
                                    details: ["field": .string(key)])
        guard path.count > 1 else {
            guard patch[first] == nil else { throw conflict }
            patch[first] = value
            return
        }
        var inner: [String: Value] = [:]
        if let existing = patch[first] {
            guard let object = existing.objectValue else { throw conflict }
            inner = object
        }
        try insertShorthand(value, at: path.dropFirst(), into: &inner, key: key, field: field)
        patch[first] = .object(inner)
    }

    /// Curve points given as `[x, y]` pairs or `{x, y}` objects in 0–255, as the settings store them.
    static func curvePoints(_ value: Value) throws -> [Value] {
        guard let items = value.arrayValue else {
            throw MCPToolError(.invalidArgument, "'points' must be an array of [x, y] points in 0–255.", details: ["field": .string("points")])
        }
        return try items.enumerated().map { index, item in
            let field = "points[\(index)]"
            let pair: (Value?, Value?)? = if let array = item.arrayValue, array.count == 2 {
                (array[0], array[1])
            } else if let object = item.objectValue, Set(object.keys) == ["x", "y"] {
                (object["x"], object["y"])
            } else {
                nil
            }
            guard let pair, let x = MCPValues.number(pair.0), let y = MCPValues.number(pair.1) else {
                throw MCPToolError(.invalidArgument, "'\(field)' must be a point: [x, y] or {\"x\", \"y\"}, numbers in 0–255.",
                                   details: ["field": .string(field)])
            }
            guard (0...255).contains(x), (0...255).contains(y) else {
                throw MCPToolError(.invalidArgument, "'\(field)' is outside 0–255.", details: ["field": .string(field)])
            }
            return .object(["x": .double(x), "y": .double(y)])
        }
    }
}

// MARK: - Patching

nonisolated extension LayerAdjustment: MCPPatchable {
    static let mcpFieldRanges: [String: ClosedRange<Double>] = {
        var ranges: [String: ClosedRange<Double>] = [
            "hue": -360...360, "saturation": -100...100, "lightness": -100...100,
            "levels.ranges[].black": 0...254, "levels.ranges[].white": 1...255, "levels.ranges[].gamma": 0.1...9.99,
            "levels.ranges[].output_black": 0...255, "levels.ranges[].output_white": 0...255,
            "curves.channels[][].x": 0...255, "curves.channels[][].y": 0...255,
            "exposure_settings.exposure": ExposureSettings.exposureRange,
            "exposure_settings.offset": ExposureSettings.offsetRange,
            "exposure_settings.gamma": ExposureSettings.gammaRange,
            "grain_settings.amount": GrainSettings.amountRange,
            "grain_settings.size": GrainSettings.sizeRange,
            "grain_settings.roughness": GrainSettings.roughnessRange,
            "black_white_settings.tint_hue": 0...360, "black_white_settings.tint_saturation": 0...100,
            "blur_radius": 0.1...250, "motion_angle": -90...90, "motion_distance": 1...2000, "noise_amount": 0.1...400,
            "profile_settings.amount": 0...200,
        ]
        for range in ColorRange.allCases {
            let entry = "hsv_settings.adjustments." + MCPCodable.enumName(range.rawValue)
            ranges[entry + ".hue"] = -360...360
            ranges[entry + ".saturation"] = -100...100
            ranges[entry + ".lightness"] = -100...100
        }
        for end in ["shadows", "highlights"] {
            for channel in ["red", "green", "blue"] { ranges["gradient_map_settings.\(end).\(channel)"] = 0...1 }
        }
        for color in ["reds", "yellows", "greens", "cyans", "blues", "magentas"] {
            ranges["black_white_settings." + color] = BlackWhiteSettings.range
        }
        for tone in ["shadow", "mid", "highlight"] {
            for pair in ["cyan_red", "magenta_green", "yellow_blue"] { ranges["color_balance_settings.\(tone)_\(pair)"] = ColorBalanceSettings.range }
        }
        return ranges
    }()

    static let mcpEnumMembers: [String: [String]] = [
        "kind": AdjustmentKind.allCases.map(\.rawValue),
        "levels.channel": LevelsChannel.allCases.map(\.rawValue),
        "curves.channel": LevelsChannel.allCases.map(\.rawValue),
        "hsv_settings.range": ColorRange.allCases.map(\.rawValue),
        "hsv_settings.adjustments.*": ColorRange.allCases.map(\.rawValue),
        "hsv_settings.bands.*": ColorRange.allCases.map(\.rawValue),
    ]

    /// What the ranges can't say: a white point at or below its black point, or a curve without its ends.
    var mcpInvalidReason: String? {
        let channels = LevelsChannel.allCases.map { MCPCodable.enumName($0.rawValue) }
        guard levels.ranges.count == channels.count else {
            return "'levels.ranges' must have \(channels.count) entries: \(channels.joined(separator: ", "))."
        }
        for (index, range) in levels.ranges.enumerated() where range.white < range.black + 1 {
            return "In the \(channels[index]) levels (levels.ranges[\(index)]), white (\(Self.text(range.white))) must be at least 1 above black (\(Self.text(range.black)))."
        }
        guard curves.channels.count == channels.count else {
            return "'curves.channels' must have \(channels.count) entries: \(channels.joined(separator: ", "))."
        }
        for (index, points) in curves.channels.enumerated() {
            let curve = "The \(channels[index]) curve (curves.channels[\(index)])"
            if !(2...32).contains(points.count) { return "\(curve) needs 2–32 points; it has \(points.count)." }
            if points.first?.x != 0 || points.last?.x != 255 { return "\(curve) must start at x 0 and end at x 255." }
            if !zip(points, points.dropFirst()).allSatisfy({ $0.x < $1.x }) { return "\(curve) must have x increasing from point to point." }
        }
        return nil
    }

    private static func text(_ number: Double) -> String {
        number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
    }
}
