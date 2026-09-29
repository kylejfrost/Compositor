import CoreGraphics
import Foundation
import MCP

// MARK: - Filters

extension MCPToolRegistry {
    static let filterTools: [MCPToolEntry] = [
        tool("apply_filter", title: "Apply filter",
             description: "Runs a filter on a layer's pixels, inside the selection when there is one, without a panel. 'settings' takes set_adjustment's keys for the same kind, or the full form it reports; a filter without an adjustment layer takes its panel's sliders (an unknown key's error lists them), and Vignette also paints an empty layer. Unset settings are the filter's defaults, not the app's last-used ones; a filter that changes nothing records nothing.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "kind": MCPSchema.enumString("The filter.", filterKinds.map { MCPCodable.enumName($0.rawValue) }),
                 "settings": MCPSchema.object([:], description: "Settings to change from the defaults."),
             ],
             required: ["layer", "kind"], effect: .destructive(idempotent: false), handler: applyFilter),
        tool("apply_levels", title: "Apply levels",
             description: "Applies Levels to a layer's pixels, inside the selection when there is one: one channel's black, gamma, white, output_black and output_white, or 'ranges' for all four (rgb, red, green, blue). 'auto' (contrast, color or neutral) sets them from the histogram first.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "settings": MCPSchema.object([:], description: "One channel's range, or ranges for all four."),
                 "auto": MCPSchema.enumString("Start from automatic levels.",
                                              ["contrast", "color", "neutral"]),
             ],
             required: ["layer"], effect: .destructive(idempotent: false), handler: applyLevels),
        tool("apply_hue_saturation", title: "Apply hue/saturation",
             description: "Applies Hue/Saturation to a layer's pixels, inside the selection when there is one. hue (−180…180, or 0–360 with colorize), saturation and lightness (−100…100) change 'range' (default master); 'adjustments' sets several ranges; bands and invert_range tune which hues a range covers.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "settings": MCPSchema.object([:], description: "hue, saturation, lightness, range, colorize, adjustments, bands, invert_range."),
             ],
             required: ["layer", "settings"], effect: .destructive(idempotent: false), handler: applyHueSaturation),
        tool("content_aware_fill", title: "Content-aware fill",
             description: "Fills the selection on a layer's pixels with texture from the pixels around it (Content-Aware Fill); needs a selection that leaves enough of the layer to copy from.",
             properties: ["layer": MCPSchema.layerSelector()],
             required: ["layer"], effect: .destructive(idempotent: false), handler: contentAwareFill),
        tool("remove_background", title: "Remove background",
             description: "Masks out a layer's background, keeping the subject Vision finds, with a layer mask that is black over the background; nothing is erased, and a mask already there is combined. quality advanced refines the edge (refine_edges, matte_contrast, shift_edge). Fails when no subject is found.",
             properties: [
                 "layer": MCPSchema.layerSelector(),
                 "quality": MCPSchema.enumString("advanced refines the edge.", ["basic", "advanced"],
                                                 default: "basic"),
                 "refine_edges": MCPSchema.num("Advanced: edge pull onto detail (0 off).", min: 0, max: 40,
                                               default: 12),
                 "matte_contrast": MCPSchema.num("Advanced: matte contrast.", min: 0, max: 100, default: 25),
                 "shift_edge": MCPSchema.num("Advanced: contract (negative) or expand.", min: -10, max: 10,
                                             default: 0),
             ],
             required: ["layer"], effect: .additive(idempotent: false), handler: removeBackground),
    ]

    /// The filters `apply_filter` runs: all but the automatic ones, which have tools of their own.
    static let filterKinds = FilterKind.allCases.filter { !$0.isAutomatic }

    // MARK: apply_filter

    static func applyFilter(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let kind = try filterKind(ctx.args)
        let patch = try ctx.args.object("settings") ?? [:]
        let session = ctx.session
        var defaults = FilterSettings()
        // As in the app, a Gradient Map starts from the foreground and background colors.
        defaults.gradientMap = GradientMapSettings(shadows: AdjustmentColor(session.foregroundColor),
                                                   highlights: AdjustmentColor(session.backgroundColor))
        let (settings, reported) = try filterSettings(kind, patch: patch, defaults: defaults)
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        // Vignette, as in the app, also starts an empty layer (not a folder or adjustment) from clear pixels.
        try requireEditablePixels(layer, mask: false, in: document, session: session, guard: "can_adjust_colors",
                                  needsRaster: !(kind == .vignette && layer.asset == nil))
        try await withPixelTarget(ctx, layer, mask: false) {
            try await runFilter(kind, settings: settings, layer: layer, session: session)
        }
        return ctx.mutated(["layer_id": .string(layer.id.uuidString), "kind": .string(MCPCodable.enumName(kind.rawValue)),
                            "settings": reported])
    }

    static func filterKind(_ args: Args) throws -> FilterKind {
        let name = try args.string("kind")
        let target = normalized(name)
        if let kind = filterKinds.first(where: { normalized($0.rawValue) == target }) { return kind }
        if let automatic = FilterKind.allCases.first(where: { $0.isAutomatic && normalized($0.rawValue) == target }) {
            throw MCPToolError.invalidArgument("\(automatic.rawValue) has a tool of its own.",
                                               hint: "Call \(automatic == .removeBackground ? "remove_background" : "content_aware_fill").")
        }
        throw MCPToolError.invalidArgument("Unknown filter '\(name)'.",
                                           hint: "Filters: \(filterKinds.map { MCPCodable.enumName($0.rawValue) }.joined(separator: ", ")).")
    }

    /// A panel slider of a filter that has no adjustment layer: its `settings` key, where it lives in `FilterSettings`,
    /// and its range.
    struct FilterSlider {
        let key: String
        let path: WritableKeyPath<FilterSettings, Double>
        let range: ClosedRange<Double>
    }

    /// The sliders apply_filter takes for the filters without an adjustment layer, as their panels show them. Camera Raw
    /// takes its Basic and Presence sliders; its curves, mixer, grading, detail, optics and geometry are the panel's.
    static let filterSliders: [FilterKind: [FilterSlider]] = [
        .lensCorrection: [FilterSlider(key: "distortion", path: \.distortion, range: -100...100)],
        .vignette: [FilterSlider(key: "amount", path: \.vignetteAmount, range: 0...100),
                    FilterSlider(key: "midpoint", path: \.vignetteMidpoint, range: 0...100),
                    FilterSlider(key: "roundness", path: \.vignetteRoundness, range: -100...100),
                    FilterSlider(key: "feather", path: \.vignetteFeather, range: 0...100),
                    FilterSlider(key: "highlights", path: \.vignetteHighlights, range: 0...100)],
        .bloomGlow: [FilterSlider(key: "amount", path: \.bloomAmount, range: 0...100),
                     FilterSlider(key: "radius", path: \.bloomRadius, range: 1...150)],
        .tonalContrast: [FilterSlider(key: "amount", path: \.tonalAmount, range: 0...100),
                         FilterSlider(key: "radius", path: \.tonalRadius, range: 1...100),
                         FilterSlider(key: "shadows", path: \.tonalShadows, range: -100...100),
                         FilterSlider(key: "midtones", path: \.tonalMidtones, range: -100...100),
                         FilterSlider(key: "highlights", path: \.tonalHighlights, range: -100...100)],
        .cameraRaw: [FilterSlider(key: "temperature", path: \.cameraRaw.temperature, range: CameraRawSettings.toneRange),
                     FilterSlider(key: "tint", path: \.cameraRaw.tint, range: CameraRawSettings.toneRange),
                     FilterSlider(key: "exposure", path: \.cameraRaw.exposure, range: CameraRawSettings.exposureRange),
                     FilterSlider(key: "contrast", path: \.cameraRaw.contrast, range: CameraRawSettings.toneRange),
                     FilterSlider(key: "highlights", path: \.cameraRaw.highlights, range: CameraRawSettings.toneRange),
                     FilterSlider(key: "shadows", path: \.cameraRaw.shadows, range: CameraRawSettings.toneRange),
                     FilterSlider(key: "whites", path: \.cameraRaw.whites, range: CameraRawSettings.toneRange),
                     FilterSlider(key: "blacks", path: \.cameraRaw.blacks, range: CameraRawSettings.toneRange),
                     FilterSlider(key: "texture", path: \.cameraRaw.texture, range: CameraRawSettings.toneRange),
                     FilterSlider(key: "clarity", path: \.cameraRaw.clarity, range: CameraRawSettings.toneRange),
                     FilterSlider(key: "dehaze", path: \.cameraRaw.dehaze, range: CameraRawSettings.toneRange),
                     FilterSlider(key: "vibrance", path: \.cameraRaw.vibrance, range: CameraRawSettings.toneRange),
                     FilterSlider(key: "saturation", path: \.cameraRaw.saturation, range: CameraRawSettings.toneRange)],
    ]

    /// `defaults` with `patch` setting `kind`'s sliders (`filterSliders`), and Vignette's `color`; and those settings as
    /// tools report them.
    static func sliderSettings(_ kind: FilterKind, sliders: [FilterSlider], patch: [String: Value],
                               defaults: FilterSettings) throws -> (FilterSettings, Value) {
        var settings = defaults
        let keys = sliders.map(\.key) + (kind == .vignette ? ["color"] : [])
        if let key = patch.keys.sorted().first(where: { !keys.contains($0) }) {
            throw MCPToolError(.invalidArgument, "'\(key)' isn't a setting of \(kind.rawValue).",
                               hint: "It takes \(keys.joined(separator: ", ")).", details: ["field": .string(key)])
        }
        for slider in sliders {
            guard let value = patch[slider.key], value != .null else { continue }
            guard let number = MCPValues.number(value), slider.range.contains(number) else {
                throw MCPToolError(.invalidArgument, "'\(slider.key)' must be a number from \(slider.range.lowerBound.formatted()) to \(slider.range.upperBound.formatted()).",
                                   details: ["field": .string(slider.key)])
            }
            settings[keyPath: slider.path] = number
        }
        if kind == .vignette, let value = patch["color"], value != .null {
            guard let color = MCPValues.color(from: value) else {
                throw MCPToolError(.invalidArgument, "'color' must be {r, g, b} in 0–1 or \"#rrggbb\".", details: ["field": .string("color")])
            }
            settings.vignetteColor = AdjustmentColor(red: color.red, green: color.green, blue: color.blue)
        }
        var reported = Dictionary(uniqueKeysWithValues: sliders.map { ($0.key, Value.double(settings[keyPath: $0.path])) })
        if kind == .vignette {
            let color = settings.vignetteColor
            reported["color"] = .object(["r": .double(color.red), "g": .double(color.green), "b": .double(color.blue)])
        }
        return (settings, .object(reported))
    }

    /// The settings `kind` runs with: `defaults` with `patch` applied as set_adjustment patches an adjustment layer of the
    /// same kind, or, for a filter without one, as its panel's sliders (`filterSliders`); and those settings as tools
    /// report them.
    static func filterSettings(_ kind: FilterKind, patch: [String: Value], defaults: FilterSettings) throws -> (FilterSettings, Value) {
        var settings = defaults
        guard let adjustmentKind = AdjustmentKind.allCases.first(where: { $0.filterKind == kind }) else {
            return try sliderSettings(kind, sliders: filterSliders[kind] ?? [], patch: patch, defaults: defaults)
        }
        // Each application gets a pattern of its own, as in the app.
        let seed = kind == .addNoise && patch["noise_seed"] != nil ? "noise_seed"
            : kind == .grain && patch["grain_settings"]?.objectValue?["seed"] != nil ? "grain_settings.seed" : nil
        if let seed {
            throw MCPToolError(.invalidArgument, "'\(seed)' can't be set: each application of \(kind.rawValue) makes a pattern of its own.",
                               details: ["field": .string(seed)])
        }
        var adjustment = LayerAdjustment(kind: adjustmentKind)
        adjustment.gaussianRadius = defaults.radius
        adjustment.resolvedMotionAngle = defaults.angle
        adjustment.resolvedMotionDistance = defaults.distance
        adjustment.resolvedNoiseAmount = defaults.amount
        adjustment.resolvedNoiseGaussian = defaults.gaussian
        adjustment.resolvedNoiseMonochromatic = defaults.monochromatic
        adjustment.curves = defaults.curves
        adjustment.exposure = defaults.exposure
        adjustment.gradientMap = defaults.gradientMap
        adjustment.grain = defaults.grain
        adjustment.blackWhite = defaults.blackWhite
        adjustment.colorBalance = defaults.colorBalance
        let patched = try patchedAdjustment(adjustment, with: patch)
        settings.radius = patched.gaussianRadius
        settings.angle = patched.resolvedMotionAngle
        settings.distance = patched.resolvedMotionDistance
        settings.amount = patched.resolvedNoiseAmount
        settings.gaussian = patched.resolvedNoiseGaussian
        settings.monochromatic = patched.resolvedNoiseMonochromatic
        settings.curves = patched.curves
        settings.exposure = patched.exposure
        settings.gradientMap = patched.gradientMap
        settings.grain = patched.grain
        settings.blackWhite = patched.blackWhite
        settings.colorBalance = patched.colorBalance
        var reported = try adjustmentSettingsValue(patched).objectValue ?? [:]
        reported["noise_seed"] = nil
        if var grain = reported["grain_settings"]?.objectValue {
            grain["seed"] = nil
            reported["grain_settings"] = .object(grain)
        }
        return (settings, .object(reported))
    }

    /// Runs `kind` on the active layer as its panel's OK button does, with `settings` and no panel. The user's filter
    /// settings, which the app's panels start from and OK overwrites, are left as they were. An automatic filter that
    /// can't make its result fails with `filter_failed`, giving the reason its panel would show.
    static func runFilter(_ kind: FilterKind, settings: FilterSettings, layer: ImageLayer, session: EditorSession) async throws {
        let ready = kind == .contentAwareFill ? session.canContentAwareFill : kind == .vignette ? session.canVignette : session.canAdjustColors
        guard ready else {
            throw cannotEditPixels(layer, session, guard: kind == .contentAwareFill ? "can_content_aware_fill" : "can_adjust_colors")
        }
        let userSettings = session.filterSettings
        session.filterSettings = settings
        defer { session.filterSettings = userSettings }
        try await MCPGuards.captureAsyncBrushError(session) {
            session.beginFilter(kind)
            // Without an edit, `brushError` says why.
            guard let edit = session.filterEdit else { return }
            if !kind.isAutomatic {
                session.updateFilter(settings, preview: false)
            } else if edit.settings != settings.normalized {
                session.updateFilter(settings, preview: true)
            }
            await session.commitFilter()
            // An automatic filter whose result couldn't be made keeps its panel open, showing why.
            if let open = session.filterEdit {
                let reason = open.previewError
                session.cancelFilter()
                throw MCPToolError(.preconditionFailed, reason ?? "\(kind.rawValue) couldn't be applied to '\(layer.name)'.",
                                   hint: "Nothing changed. Try other settings, a different selection, or another layer.", guard: "filter_failed")
            }
        }
    }

    /// The checks `canAdjustColors` makes that don't need the layer to be active: pixels of its own, visible, not
    /// locked or a Photoshop placeholder, and a selection, if there is one, that selects something.
    static func requireColorAdjustable(_ layer: ImageLayer, in document: CanvasDocument, session: EditorSession) throws {
        try requireEditablePixels(layer, mask: false, in: document, session: session, guard: "can_adjust_colors", needsRaster: true)
    }

    // MARK: apply_levels

    static func applyLevels(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let patch = try ctx.args.object("settings")
        let auto = try levelsAuto(ctx.args)
        guard patch != nil || auto != nil else {
            throw MCPToolError.invalidArgument("Give 'settings', 'auto', or both.", hint: "For example {\"settings\": {\"black\": 20}} or {\"auto\": \"contrast\"}.")
        }
        let changes = patch ?? [:]
        // Checked before anything opens; automatic levels are checked again once known.
        _ = try patchedLevels(LevelsSettings(), with: changes)
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        let session = ctx.session
        try requireColorAdjustable(layer, in: document, session: session)
        let applied = try await withPixelTarget(ctx, layer, mask: false) { () async throws -> LevelsSettings in
            guard session.canAdjustColors else { throw cannotEditPixels(layer, session, guard: "can_adjust_colors") }
            return try await MCPGuards.captureAsyncBrushError(session) { () async throws -> LevelsSettings in
                session.beginLevels()
                guard let edit = session.levels else { return LevelsSettings() }
                do {
                    var base = LevelsSettings()
                    if let auto {
                        await edit.histogramTask?.value
                        session.autoLevels(auto)
                        base = edit.settings
                    }
                    let settings = try patchedLevels(base, with: changes)
                    session.updateLevels(settings, preview: false)
                    await session.commitLevels()
                    return settings
                } catch {
                    session.cancelLevels()
                    throw error
                }
            }
        }
        return ctx.mutated(["layer_id": .string(layer.id.uuidString), "settings": try MCPCodable.agentForm(applied)])
    }

    private static func levelsAuto(_ args: Args) throws -> LevelsAuto? {
        guard let name = try args.optionalString("auto") else { return nil }
        switch normalized(name) {
        case "contrast": return .contrast
        case "color": return .color
        case "neutral", "colorneutralmidtones": return .neutral
        default: throw MCPToolError.invalidArgument("'auto' must be contrast, color or neutral.")
        }
    }

    /// `base` with `given` applied: shorthand for one channel's range (`channel`, `black`, `gamma`, `white`,
    /// `output_black`, `output_white`), then everything merged through `MCPCodable.decodeMerged`.
    static func patchedLevels(_ base: LevelsSettings, with given: [String: Value]) throws -> LevelsSettings {
        var patch = given
        var channel = LevelsChannel.rgb
        if let value = patch["channel"], value != .null {
            guard let name = value.stringValue,
                  let named = LevelsChannel.allCases.first(where: { normalized($0.rawValue) == normalized(name) }) else {
                throw MCPToolError(.invalidArgument, "'channel' must be one of: rgb, red, green, blue.", details: ["field": .string("channel")])
            }
            channel = named
        }
        var range: [String: Value] = [:]
        for key in ["black", "gamma", "white", "output_black", "output_white"] {
            guard let value = patch.removeValue(forKey: key) else { continue }
            try requireShorthand(value, .number, key: key)
            range[key] = value
        }
        if let key = range.keys.sorted().first {
            guard var ranges = try MCPCodable.agentForm(base).objectValue?["ranges"]?.arrayValue, ranges.indices.contains(channel.index) else {
                throw MCPToolError(.internalError, "The levels' ranges can't be read.")
            }
            ranges[channel.index] = .object((ranges[channel.index].objectValue ?? [:]).merging(range) { $1 })
            try insertShorthand(.array(ranges), at: ["ranges"], into: &patch, key: key)
        }
        return try MCPCodable.decodeMerged(base, .object(patch))
    }

    // MARK: apply_hue_saturation

    static func applyHueSaturation(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        guard let given = try ctx.args.object("settings") else {
            throw MCPToolError.invalidArgument("Missing 'settings' object.", hint: "For example {\"saturation\": -30} or {\"range\": \"reds\", \"hue\": 20}.")
        }
        let settings = try patchedHueSaturation(given)
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        let session = ctx.session
        try requireColorAdjustable(layer, in: document, session: session)
        try await withPixelTarget(ctx, layer, mask: false) {
            guard session.canAdjustColors else { throw cannotEditPixels(layer, session, guard: "can_adjust_colors") }
            try await MCPGuards.captureAsyncBrushError(session) {
                session.beginHueSaturation()
                guard session.hueSaturation != nil else { return }
                session.updateHueSaturation(settings, preview: false)
                await session.commitHueSaturation()
            }
        }
        return ctx.mutated(["layer_id": .string(layer.id.uuidString), "settings": try MCPCodable.agentForm(settings)])
    }

    /// Identity settings with `given` applied: `hue`, `saturation` and `lightness` change `range` (default master), then
    /// everything is merged through `MCPCodable.decodeMerged`.
    static func patchedHueSaturation(_ given: [String: Value]) throws -> HueSaturationSettings {
        var patch = given
        var range = ColorRange.master
        if let value = patch["range"], value != .null {
            guard let name = value.stringValue,
                  let named = ColorRange.allCases.first(where: { normalized($0.rawValue) == normalized(name) }) else {
                let names = ColorRange.allCases.map { MCPCodable.enumName($0.rawValue) }.joined(separator: ", ")
                throw MCPToolError(.invalidArgument, "'range' must be one of: \(names).", details: ["field": .string("range")])
            }
            range = named
        }
        for key in ["hue", "saturation", "lightness"] {
            guard let value = patch.removeValue(forKey: key) else { continue }
            try requireShorthand(value, .number, key: key)
            try insertShorthand(value, at: ["adjustments", MCPCodable.enumName(range.rawValue), key], into: &patch, key: key)
        }
        var template = HueSaturationSettings()
        for range in ColorRange.allCases { template.adjustments[range] = RangeAdjustment() }
        let settings = try MCPCodable.decodeMerged(HueSaturationSettings(), .object(patch), template: template)
        try requireDialogHues(settings, field: { "adjustments.\(MCPCodable.enumName($0.rawValue)).hue" })
        return settings
    }

    /// Hue/Saturation's hues as the app's dialog sets them: a shift from −180 to 180, and with colorize the hue it
    /// tints with (the selected range's) from 0 to 360. The settings can hold ±360, which is the same shift, but a
    /// colorize hue below 0 draws the wrong colors, so tools take only what the dialog does. Fails naming the field
    /// `field` gives the range's hue.
    static func requireDialogHues(_ settings: HueSaturationSettings, field: (ColorRange) -> String) throws {
        for range in ColorRange.allCases {
            guard let hue = settings.adjustments[range]?.hue else { continue }
            let colorizing = settings.colorize && range == settings.range
            let allowed: ClosedRange<Double> = colorizing ? 0...360 : -180...180
            guard !allowed.contains(hue) else { continue }
            let name = field(range)
            let shown = hue.rounded() == hue && abs(hue) < 1e15 ? String(Int(hue)) : String(hue)
            throw MCPToolError(.invalidArgument,
                               "'\(name)' is \(shown), outside its range \(Int(allowed.lowerBound))–\(Int(allowed.upperBound))\(colorizing ? " while colorizing" : "").",
                               hint: "A hue shift runs from -180 to 180; with colorize, the hue to tint with runs from 0 to 360.",
                               details: ["field": .string(name), "value": .double(hue), "min": .double(allowed.lowerBound),
                                         "max": .double(allowed.upperBound)])
        }
    }

    // MARK: Automatic filters

    static func contentAwareFill(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        let session = ctx.session
        try requireColorAdjustable(layer, in: document, session: session)
        guard session.selection != nil else {
            throw MCPToolError(.preconditionFailed, "Content-Aware Fill fills the selection, and there is none.",
                               hint: "Select the area to fill first, e.g. with select_rect.", guard: "can_content_aware_fill")
        }
        try await withPixelTarget(ctx, layer, mask: false) {
            try await runFilter(.contentAwareFill, settings: FilterSettings(), layer: layer, session: session)
        }
        return ctx.mutated(["layer_id": .string(layer.id.uuidString)])
    }

    static func removeBackground(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        var settings = FilterSettings()
        switch normalized(try ctx.args.string("quality", default: "basic")) {
        case "basic": settings.backgroundQuality = .basic
        case "advanced": settings.backgroundQuality = .advanced
        default: throw MCPToolError.invalidArgument("'quality' must be basic or advanced.")
        }
        func number(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) throws -> Double {
            let value = try ctx.args.double(key, default: fallback)
            guard range.contains(value) else {
                throw MCPToolError(.invalidArgument, "'\(key)' is \(value); it must be from \(Int(range.lowerBound)) to \(Int(range.upperBound)).",
                                   details: ["field": .string(key)])
            }
            return value
        }
        settings.refineEdges = try number("refine_edges", 12, 0...40)
        settings.matteContrast = try number("matte_contrast", 25, 0...100)
        settings.shiftEdge = try number("shift_edge", 0, -10...10)
        let document = try ctx.editableDocument()
        let layer = try ctx.layer(in: document)
        let session = ctx.session
        // It masks the layer rather than changing its pixels, so only Lock All holds it, as in the app.
        try requireEditablePixels(layer, mask: false, in: document, session: session, guard: "can_adjust_colors", needsRaster: true,
                                  lock: .all)
        try await withPixelTarget(ctx, layer, mask: false) {
            try await runFilter(.removeBackground, settings: settings, layer: layer, session: session)
        }
        let mask = session.document?.layers.first { $0.id == layer.id }?.mask
        return ctx.mutated([
            "layer_id": .string(layer.id.uuidString),
            "mask": mask.map { .object(["enabled": .bool($0.isEnabled), "linked": .bool($0.isLinked)]) } ?? .null,
            "settings": .object([
                "quality": .string(settings.backgroundQuality == .advanced ? "advanced" : "basic"),
                "refine_edges": .double(settings.refineEdges),
                "matte_contrast": .double(settings.matteContrast),
                "shift_edge": .double(settings.shiftEdge),
            ]),
        ])
    }
}

// MARK: - Patching

nonisolated extension LevelsSettings: MCPPatchable {
    var isValid: Bool { ranges.count == LevelsChannel.allCases.count && ranges.allSatisfy { $0 == $0.normalized } }

    static let mcpFieldRanges: [String: ClosedRange<Double>] = [
        "ranges[].black": 0...254, "ranges[].white": 1...255, "ranges[].gamma": 0.1...9.99,
        "ranges[].output_black": 0...255, "ranges[].output_white": 0...255,
    ]

    static let mcpEnumMembers: [String: [String]] = ["channel": LevelsChannel.allCases.map(\.rawValue)]

    /// What the ranges can't say: four channels, each with its white point above its black point.
    var mcpInvalidReason: String? {
        let channels = LevelsChannel.allCases.map { MCPCodable.enumName($0.rawValue) }
        guard ranges.count == channels.count else { return "'ranges' must have \(channels.count) entries: \(channels.joined(separator: ", "))." }
        for (index, range) in ranges.enumerated() where range.white < range.black + 1 {
            return "In the \(channels[index]) levels (ranges[\(index)]), white must be at least 1 above black."
        }
        return nil
    }
}

nonisolated extension HueSaturationSettings: MCPPatchable {
    var isValid: Bool {
        adjustments.values.allSatisfy {
            $0.hue.isFinite && abs($0.hue) <= 360 && $0.saturation.isFinite && abs($0.saturation) <= 100
                && $0.lightness.isFinite && abs($0.lightness) <= 100
        }
        && bands.values.allSatisfy { $0.handles.allSatisfy(\.isFinite) }
    }

    static let mcpFieldRanges: [String: ClosedRange<Double>] = {
        var ranges: [String: ClosedRange<Double>] = [:]
        for range in ColorRange.allCases {
            let entry = "adjustments." + MCPCodable.enumName(range.rawValue)
            ranges[entry + ".hue"] = -360...360
            ranges[entry + ".saturation"] = -100...100
            ranges[entry + ".lightness"] = -100...100
        }
        return ranges
    }()

    static let mcpEnumMembers: [String: [String]] = [
        "range": ColorRange.allCases.map(\.rawValue),
        "adjustments.*": ColorRange.allCases.map(\.rawValue),
        "bands.*": ColorRange.allCases.map(\.rawValue),
    ]
}
