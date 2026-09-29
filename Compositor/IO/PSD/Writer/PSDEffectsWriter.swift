import CoreGraphics
import Foundation

/// Writes a layer's live effects as Photoshop's object-based effects, `lfx2` (`u32 0 · u32 16 · descriptor`, from
/// Adobe's *Photoshop File Formats Specification*, "Object Based Effects Layer Info"): the inverse of
/// `PSDEffectsReader`. Original implementation.
///
/// Compositor draws effects in the layer's own pixels and the writer bakes the layer's transform into the record, so
/// sizes (distance, blur, glow size, stroke size) are multiplied by the layer's scale, `transform.size.width /
/// image.width`, to become the document pixels Photoshop draws them in. Blur is written as Compositor holds it, and
/// angles are wrapped to Photoshop's ±180°.
///
/// A layer the document was opened with keeps its effect blocks (`lfx2`, the legacy `lrFX`, and `lmfx`) byte for
/// byte while its effects are what import made of them and it hasn't been scaled. Once they differ, Compositor's
/// values are written into the file's own `lfx2` descriptor, each only where it differs from what import read, so
/// what Compositor doesn't model stays: blend modes, choke, noise, contours, glow technique, the kinds Compositor lacks,
/// extra entries of a kind, and what import approximated (a centered stroke, the global light, a size beyond
/// Compositor's range) until that value is edited. An effect added in Compositor is new, so it gets a fresh entry
/// (normal blend, Photoshop's defaults), also where the file had an entry import made nothing of: one Photoshop keeps
/// hidden at its own defaults (a Multiply shadow), or a stroke painted with a gradient. `lrFX` and `lmfx` would still
/// describe the old effects, and Photoshop could read them instead, so an edited layer drops both. A layer Photoshop
/// never saw gets a fresh `lfx2` before its name. Folders, adjustment layers and placeholders keep the effect blocks
/// they were stored with.
nonisolated enum PSDEffectsWriter {
    /// Brings a pixel layer's record `blocks` in line with its effects. `extras` is the layer's Photoshop data, nil
    /// when none is written back; `image` its pixels, before the transform.
    static func update(_ blocks: inout [PSDTaggedBlock], for layer: ProjectLayerRecord, image: CGImage?,
                       extras: PSDLayerExtras?) {
        let scale = scale(of: layer.transform, image: image)
        let effects = layer.effects.flatMap { $0.isEmpty ? nil : $0 }
        let imported = extras?.importedEffects.flatMap { $0.isEmpty ? nil : $0 }
        if effects == imported, effects == nil || scale == 1 { return }
        blocks.removeAll { $0.key == "lrFX" || $0.key == "lmfx" }
        let existing = blocks.firstIndex { $0.key == "lfx2" }
        if let existing, let rewritten = rewrite(blocks[existing].data, effects: effects, imported: imported, scale: scale) {
            blocks[existing].data = rewritten
        } else if let effects {
            let fresh = lfx2(effects, scale: scale)
            if let existing {
                blocks[existing].data = fresh
            } else {
                blocks.insert(PSDTaggedBlock(key: "lfx2", data: fresh), at: blocks.firstIndex { $0.key == "luni" } ?? 0)
            }
        }
    }

    /// How much larger than its pixels the layer is drawn: 1 without pixels, or when it's within rounding of 1.
    private static func scale(of transform: LayerTransform, image: CGImage?) -> CGFloat {
        guard let width = image?.width, width > 0 else { return 1 }
        let scale = transform.size.width / CGFloat(width)
        return scale.isFinite && scale > 0 && abs(scale - 1) > 1e-6 ? scale : 1
    }

    /// A fresh `lfx2` payload: `null {Scl , masterFXSwitch, DrSh?, IrSh?, OrGl?, IrGl?, SoFi?, FrFX?, numModifyingFX}`, each
    /// effect with Photoshop's defaults for what Compositor doesn't model.
    static func lfx2(_ effects: LayerEffects, scale: CGFloat) -> Data {
        var items: [(key: PSDKey, value: PSDDescriptorValue)] = [
            (key: "Scl ", value: .unitFloat(unit: "#Prc", value: 100)),
            (key: "masterFXSwitch", value: .bool(true)),
        ]
        for kind in Kind.allCases {
            if let values = kind.values(in: effects, scale: scale) {
                items.append((key: PSDKey(kind.key), value: .object(kind.entry(values))))
            }
        }
        items.append((key: "numModifyingFX", value: .integer(0)))
        return PSDDescriptorWriter.block2(PSDDescriptor(classID: "null", items: items), version: 0)
    }

    // MARK: Rewriting

    /// The file's `lfx2` with Compositor's effects written into it, in its own version; nil when it can't be read.
    private static func rewrite(_ lfx2: Data, effects: LayerEffects?, imported: LayerEffects?, scale: CGFloat) -> Data? {
        let data = lfx2.startIndex == 0 ? lfx2 : Data(lfx2)
        guard data.count >= 4 else { return nil }
        var offset = 4
        guard var root = try? PSDDescriptorReader.readBlock(data, at: &offset) else { return nil }
        // Photoshop's switch for all of a layer's effects was off, and Compositor now shows one: the switch goes on,
        // and every entry Compositor doesn't show is turned off so it stays hidden.
        let showing = root.bool("masterFXSwitch") == false
            && Kind.allCases.contains { $0.values(in: effects, scale: scale)?.enabled == true }
        var shown: Set<Location> = []
        var added: [(kind: Kind, entry: PSDDescriptor)] = []
        for kind in Kind.allCases {
            let new = kind.values(in: effects, scale: scale), old = kind.values(in: imported, scale: 1)
            guard let location = kind.location(in: root), var current = entry(at: location, in: root) else {
                if let new { added.append((kind, kind.entry(new))) }
                continue
            }
            if let new {
                if let old {
                    kind.write(new, over: old, into: &current)
                } else {
                    // Import made nothing of this entry (Photoshop's hidden defaults, or a stroke Compositor couldn't
                    // show), so Compositor's effect is new: a fresh entry takes its place, drawn as Compositor draws it.
                    current = kind.entry(new)
                }
                if showing { set("enab", .bool(new.enabled), in: &current) }
                shown.insert(location)
            } else if old != nil {
                // Removed in Compositor.
                set("present", .bool(false), in: &current)
            } else {
                continue
            }
            replace(at: location, with: current, in: &root)
        }
        if showing {
            set("masterFXSwitch", .bool(true), in: &root)
            for location in allEntries(in: root) where !shown.contains(location) {
                guard var other = entry(at: location, in: root), other.bool("enab") != false else { continue }
                set("enab", .bool(false), in: &other)
                replace(at: location, with: other, in: &root)
            }
        }
        // Added last, so the locations above still hold.
        for (kind, entry) in added { kind.insert(entry, into: &root) }
        return PSDDescriptorWriter.block2(root, version: data.prefix(4).reduce(0) { $0 << 8 | UInt32($1) })
    }

    /// Where an effect entry sits in the `lfx2` descriptor: an item of its own, or an element of an item's list.
    private nonisolated struct Location: Hashable {
        var item: Int
        var element: Int?
    }

    private static func object(_ value: PSDDescriptorValue) -> PSDDescriptor? {
        switch value {
        case .object(let descriptor), .globalObject(let descriptor): descriptor
        default: nil
        }
    }

    private static func entry(at location: Location, in root: PSDDescriptor) -> PSDDescriptor? {
        let value = root.items[location.item].value
        guard let element = location.element else { return object(value) }
        guard case .list(let values) = value, values.indices.contains(element) else { return nil }
        return object(values[element])
    }

    /// Puts `entry` back at `location`, as the same kind of object.
    private static func replace(at location: Location, with entry: PSDDescriptor, in root: inout PSDDescriptor) {
        func wrapped(_ old: PSDDescriptorValue) -> PSDDescriptorValue {
            if case .globalObject = old { return .globalObject(entry) }
            return .object(entry)
        }
        guard let element = location.element else {
            root.items[location.item].value = wrapped(root.items[location.item].value)
            return
        }
        guard case .list(var values) = root.items[location.item].value, values.indices.contains(element) else { return }
        values[element] = wrapped(values[element])
        root.items[location.item].value = .list(values)
    }

    /// Every entry: the descriptor's objects and the objects in its lists.
    private static func allEntries(in root: PSDDescriptor) -> [Location] {
        root.items.indices.flatMap { item -> [Location] in
            switch root.items[item].value {
            case .object, .globalObject: [Location(item: item)]
            case .list(let values): values.indices.filter { object(values[$0]) != nil }.map { Location(item: item, element: $0) }
            default: []
            }
        }
    }

    /// Replaces the value of the first item with `key`, or adds the item at the end.
    private static func set(_ key: String, _ value: PSDDescriptorValue, in descriptor: inout PSDDescriptor) {
        if let index = descriptor.items.firstIndex(where: { $0.key.id == key }) {
            descriptor.items[index].value = value
        } else {
            descriptor.items.append((key: PSDKey(key), value: value))
        }
    }

    // MARK: Kinds

    /// What Compositor models of one effect, sizes in document pixels.
    private nonisolated struct Values: Equatable {
        var enabled: Bool
        var color: [CGFloat]
        var opacity: Double
        var angle: CGFloat? = nil
        var distance: CGFloat? = nil
        /// A shadow's blur, or a glow's size.
        var blur: CGFloat? = nil
        var size: CGFloat? = nil
        var inside: Bool? = nil
    }

    /// The kinds Compositor models, in the order a fresh `lfx2` lists them.
    private nonisolated enum Kind: CaseIterable {
        case dropShadow, innerShadow, outerGlow, innerGlow, colorOverlay, stroke

        /// The key of a single entry, which is also the entry's class.
        var key: String {
            switch self {
            case .dropShadow: "DrSh"
            case .innerShadow: "IrSh"
            case .outerGlow: "OrGl"
            case .innerGlow: "IrGl"
            case .colorOverlay: "SoFi"
            case .stroke: "FrFX"
            }
        }

        /// The list Photoshop keeps several entries of the kind in, read before `key` (as `PSDEffectsReader` reads it).
        var multi: String? {
            switch self {
            case .dropShadow: "dropShadowMulti"
            case .innerShadow: "innerShadowMulti"
            case .outerGlow, .innerGlow: nil
            case .colorOverlay: "solidFillMulti"
            case .stroke: "frameFXMulti"
            }
        }

        func values(in effects: LayerEffects?, scale: CGFloat) -> Values? {
            switch self {
            case .dropShadow:
                effects?.shadow.map { Values(enabled: $0.isEnabled, color: [$0.red, $0.green, $0.blue], opacity: $0.opacity,
                                             angle: $0.angle, distance: $0.distance * scale, blur: $0.blur * scale) }
            case .innerShadow:
                effects?.innerShadow.map { Values(enabled: $0.isEnabled, color: [$0.red, $0.green, $0.blue], opacity: $0.opacity,
                                                  angle: $0.angle, distance: $0.distance * scale, blur: $0.blur * scale) }
            case .outerGlow:
                effects?.outerGlow.map { Values(enabled: $0.isEnabled, color: [$0.red, $0.green, $0.blue], opacity: $0.opacity,
                                                blur: $0.size * scale) }
            case .innerGlow:
                effects?.innerGlow.map { Values(enabled: $0.isEnabled, color: [$0.red, $0.green, $0.blue], opacity: $0.opacity,
                                                blur: $0.size * scale) }
            case .colorOverlay:
                effects?.colorOverlay.map { Values(enabled: $0.isEnabled, color: [$0.red, $0.green, $0.blue], opacity: $0.opacity) }
            case .stroke:
                effects?.stroke.map { Values(enabled: $0.isEnabled, color: [$0.red, $0.green, $0.blue], opacity: $0.opacity,
                                             size: $0.size * scale, inside: $0.inside) }
            }
        }

        /// The entry `PSDEffectsReader` imports (the first enabled `present` one, else the first `present` one), else
        /// the first entry, which isn't present and is the slot an added effect takes; nil when there are none.
        func location(in root: PSDDescriptor) -> Location? {
            var candidates: [Location] = []
            if let multi, let item = root.items.firstIndex(where: { $0.key.id == multi }),
               case .list(let values) = root.items[item].value {
                candidates = values.indices.map { Location(item: item, element: $0) }
            }
            if candidates.allSatisfy({ PSDEffectsWriter.entry(at: $0, in: root) == nil }),
               let item = root.items.firstIndex(where: { $0.key.id == key }) {
                candidates = [Location(item: item)]
            }
            let entries = candidates.compactMap { location in PSDEffectsWriter.entry(at: location, in: root).map { (location, $0) } }
            let present = entries.filter { $0.1.bool("present") ?? true }
            return (present.first { $0.1.bool("enab") ?? true } ?? present.first ?? entries.first)?.0
        }

        /// A new entry: the keys Photoshop writes, at its defaults for what Compositor doesn't model, holding `values`.
        func entry(_ values: Values) -> PSDDescriptor {
            var entry = PSDDescriptor(classID: PSDKey(key), items: template)
            write(values, over: nil, into: &entry)
            return entry
        }

        /// Writes into `entry` each of `values` that differs from `old`, what import made of the entry (every value,
        /// without it, as into a new entry); the rest of the entry stays as it is.
        func write(_ values: Values, over old: Values?, into entry: inout PSDDescriptor) {
            func changed<T: Equatable>(_ value: KeyPath<Values, T>) -> Bool {
                guard let old else { return true }
                return old[keyPath: value] != values[keyPath: value]
            }
            func set(_ key: String, _ value: PSDDescriptorValue) { PSDEffectsWriter.set(key, value, in: &entry) }
            func pixels(_ value: CGFloat) -> PSDDescriptorValue { .unitFloat(unit: "#Pxl", value: Double(value)) }
            if changed(\.enabled) { set("enab", .bool(values.enabled)) }
            if changed(\.color) {
                set("Clr ", .object(PSDDescriptor(classID: "RGBC", items: zip(["Rd  ", "Grn ", "Bl  "], values.color).map {
                    (key: PSDKey($0), value: .double(Double($1 * 255)))
                })))
            }
            if changed(\.opacity) { set("Opct", .unitFloat(unit: "#Prc", value: values.opacity * 100)) }
            if let angle = values.angle, changed(\.angle) {
                // The layer's own angle from now on, not the document's global light.
                set("uglg", .bool(false))
                set("lagl", .unitFloat(unit: "#Ang", value: remainder(Double(angle), 360)))
            }
            if let distance = values.distance, changed(\.distance) { set("Dstn", pixels(distance)) }
            if let blur = values.blur, changed(\.blur) { set("blur", pixels(blur)) }
            if let size = values.size, changed(\.size) { set("Sz  ", pixels(size)) }
            if let inside = values.inside, changed(\.inside) { set("Styl", .enumerated(type: "FStl", value: inside ? "InsF" : "OutF")) }
        }

        /// Adds a new entry: to the kind's list when the descriptor has one, else as a single entry before
        /// `numModifyingFX`.
        func insert(_ entry: PSDDescriptor, into root: inout PSDDescriptor) {
            if let multi, let item = root.items.firstIndex(where: { $0.key.id == multi }),
               case .list(let values) = root.items[item].value {
                root.items[item].value = .list(values + [.object(entry)])
            } else {
                let end = root.items.firstIndex { $0.key.id == "numModifyingFX" } ?? root.items.count
                root.items.insert((key: PSDKey(key), value: .object(entry)), at: end)
            }
        }

        /// Photoshop's keys for the kind, in its order, at its defaults.
        private var template: [(key: PSDKey, value: PSDDescriptorValue)] {
            let black = PSDDescriptorValue.object(PSDDescriptor(classID: "RGBC", items: [
                (key: "Rd  ", value: .double(0)), (key: "Grn ", value: .double(0)), (key: "Bl  ", value: .double(0)),
            ]))
            // A linear contour, (0, 0) to (255, 255).
            let linear = PSDDescriptorValue.object(PSDDescriptor(classID: "ShpC", items: [
                (key: "Nm  ", value: .string("Linear")),
                (key: "Crv ", value: .list([0.0, 255.0].map { point -> PSDDescriptorValue in
                    .object(PSDDescriptor(classID: "CrPt", items: [(key: "Hrzn", value: .double(point)),
                                                                     (key: "Vrtc", value: .double(point))]))
                })),
            ]))
            func pixels(_ value: Double) -> PSDDescriptorValue { .unitFloat(unit: "#Pxl", value: value) }
            func percent(_ value: Double) -> PSDDescriptorValue { .unitFloat(unit: "#Prc", value: value) }
            var items: [(key: PSDKey, value: PSDDescriptorValue)] = [
                (key: "enab", value: .bool(true)),
                (key: "present", value: .bool(true)),
                (key: "showInDialog", value: .bool(true)),
                (key: "Md  ", value: .enumerated(type: "BlnM", value: "Nrml")),
                (key: "Clr ", value: black),
                (key: "Opct", value: percent(100)),
            ]
            switch self {
            case .dropShadow, .innerShadow:
                items += [
                    (key: "uglg", value: .bool(false)),
                    (key: "lagl", value: .unitFloat(unit: "#Ang", value: 90)),
                    (key: "Dstn", value: pixels(0)),
                    (key: "Ckmt", value: pixels(0)),
                    (key: "blur", value: pixels(0)),
                    (key: "Nose", value: percent(0)),
                    (key: "AntA", value: .bool(false)),
                    (key: "TrnS", value: linear),
                ]
                if self == .dropShadow { items.append((key: "layerConceals", value: .bool(true))) }
            case .outerGlow, .innerGlow:
                items += [
                    (key: "GlwT", value: .enumerated(type: "BETE", value: "SfBL")),
                    (key: "Ckmt", value: pixels(0)),
                    (key: "blur", value: pixels(0)),
                    (key: "Nose", value: percent(0)),
                    (key: "ShdN", value: percent(0)),
                    (key: "AntA", value: .bool(false)),
                    (key: "TrnS", value: linear),
                    (key: "Inpr", value: percent(50)),
                ]
                // An inner glow glows in from the layer's edges, as Compositor draws it.
                if self == .innerGlow { items.append((key: "glwS", value: .enumerated(type: "IGSr", value: "SrcE"))) }
            case .colorOverlay:
                break
            case .stroke:
                items += [
                    (key: "Styl", value: .enumerated(type: "FStl", value: "OutF")),
                    (key: "PntT", value: .enumerated(type: "FrFl", value: "SClr")),
                    (key: "Sz  ", value: pixels(0)),
                    (key: "overprint", value: .bool(false)),
                ]
            }
            return items
        }
    }
}
