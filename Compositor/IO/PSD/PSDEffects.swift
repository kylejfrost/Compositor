import CoreGraphics
import Foundation

/// Reads a layer's object-based effects (`lfx2`: `u32 version · u32 16 · descriptor`, from Adobe's *Photoshop File
/// Formats Specification*, "Object Based Effects Layer Info") into Compositor's live effects. Original
/// implementation.
///
/// Compositor has one effect of each kind; Photoshop keeps some kinds as lists (`dropShadowMulti`, `frameFXMulti`…)
/// beside the single keys (`DrSh`, `FrFX`…). Of a kind's `present` entries the first enabled one is imported, else
/// the first (hidden). `masterFXSwitch` off imports every effect hidden. Sizes are final document pixels: `Scl ` is
/// left in the block, never multiplied in. Notes name only what Photoshop shows and Compositor won't (extra enabled
/// entries, a centered stroke drawn outside, a gradient or pattern stroke, kinds Compositor lacks, a color that
/// can't be read, settings Compositor's effects don't model) and values limited to Compositor's ranges. The `lfx2`
/// bytes, and `lrFX` (never parsed), stay in the layer's Photoshop data unchanged.
nonisolated enum PSDEffectsReader {
    struct Result: Equatable, Sendable {
        var effects: LayerEffects
        var notes: [String]
    }

    /// Throws `PSDError.truncated` when `lfx2` holds no readable descriptor.
    static func parse(_ lfx2: Data, globalLightAngle: Double?) throws -> Result {
        let data = lfx2.startIndex == 0 ? lfx2 : Data(lfx2)
        // `u32` object effects version, then the descriptor block.
        var offset = 4
        let descriptor = try PSDDescriptorReader.readBlock(data, at: &offset)
        var reader = Reader(root: descriptor, globalLightAngle: globalLightAngle)
        var effects = LayerEffects()
        effects.stroke = reader.stroke()
        effects.shadow = reader.dropShadow()
        effects.colorOverlay = reader.colorOverlay()
        effects.innerShadow = reader.innerShadow()
        effects.outerGlow = reader.outerGlow()
        effects.innerGlow = reader.innerGlow()
        reader.noteUnsupported()
        return Result(effects: effects, notes: reader.notes)
    }

    /// The effects an effects block (`lfx2`, `lmfx`) shows in Photoshop that Compositor doesn't draw: kinds it lacks
    /// and, of the kinds it has, entries beyond the one it shows. Empty when the block can't be read or its effects are
    /// switched off.
    static func undrawn(_ block: Data) -> [String] {
        let data = block.startIndex == 0 ? block : Data(block)
        var offset = 4
        guard let root = try? PSDDescriptorReader.readBlock(data, at: &offset) else { return [] }
        let reader = Reader(root: root, globalLightAngle: nil)
        guard reader.master else { return [] }
        var names = unsupported.filter { kind in
            kind.keys.flatMap { reader.entries(single: $0, multi: $0) }.contains(where: Reader.isEnabled)
        }.map(\.name)
        for (single, multi, name) in [("FrFX", "frameFXMulti", "stroke"), ("DrSh", "dropShadowMulti", "drop shadow"),
                                      ("SoFi", "solidFillMulti", "color overlay"), ("IrSh", "innerShadowMulti", "inner shadow")] {
            let extra = reader.entries(single: single, multi: multi).filter(Reader.isEnabled).count - 1
            if extra > 0 { names.append(extra == 1 ? "a second \(name)" : "\(extra) more \(name)s") }
        }
        return names
    }

    /// Effect kinds Compositor doesn't have, by the keys Photoshop stores them under.
    private static let unsupported: [(keys: [String], name: String)] = [
        (["ebbl"], "Bevel & Emboss"),
        (["GrFl", "gradientFillMulti"], "Gradient Overlay"),
        (["patternFill"], "Pattern Overlay"),
        (["ChFX"], "Satin"),
    ]

    private struct Reader {
        let root: PSDDescriptor
        let globalLightAngle: Double?
        /// `masterFXSwitch`: off hides every effect.
        let master: Bool
        var notes: [String] = []

        init(root: PSDDescriptor, globalLightAngle: Double?) {
            self.root = root
            self.globalLightAngle = globalLightAngle
            master = root.bool("masterFXSwitch") ?? true
        }

        // MARK: Kinds

        mutating func stroke() -> StrokeEffect? {
            guard let (entry, shows) = chosenEntry(single: "FrFX", multi: "frameFXMulti", name: "stroke") else { return nil }
            let paint = entry.enumValue("PntT") ?? "SClr"
            guard paint == "SClr" else {
                let fill = ["GrFl": "a gradient", "Ptrn": "a pattern"][paint] ?? "a fill type"
                if shows { notes.append("The stroke is painted with \(fill), which Compositor doesn’t support, so it isn’t shown. Its Photoshop settings are kept.") }
                return nil
            }
            guard let color = color(entry, shows: shows, name: "stroke") else { return nil }
            let style = entry.enumValue("Styl") ?? "OutF"
            if style == "CtrF", shows {
                notes.append("The stroke is centered on the layer’s edge in Photoshop; Compositor draws it outside the edge.")
            }
            noteUnmodeled(entry, shows: shows, name: "stroke", color: color)
            var stroke = StrokeEffect(enabled: shows)
            stroke.size = limited(Self.number(entry, "Sz  "), fallback: stroke.size, to: 0...StrokeEffect.maxSize,
                                  "stroke’s size", unit: " px")
            (stroke.red, stroke.green, stroke.blue) = color
            stroke.opacity = opacity(entry, fallback: stroke.opacity, name: "stroke")
            stroke.inside = style == "InsF"
            return stroke
        }

        mutating func dropShadow() -> ShadowEffect? {
            guard let (entry, shows) = chosenEntry(single: "DrSh", multi: "dropShadowMulti", name: "drop shadow"),
                  let color = color(entry, shows: shows, name: "drop shadow") else { return nil }
            noteUnmodeled(entry, shows: shows, name: "drop shadow", color: color)
            var shadow = ShadowEffect(enabled: shows)
            shadow.angle = angle(entry, fallback: shadow.angle, name: "drop shadow")
            shadow.distance = limited(Self.number(entry, "Dstn"), fallback: shadow.distance,
                                      to: 0...ShadowEffect.maxDistance, "drop shadow’s distance", unit: " px")
            shadow.blur = limited(Self.number(entry, "blur"), fallback: shadow.blur, to: 0...ShadowEffect.maxBlur,
                                  "drop shadow’s size", unit: " px")
            (shadow.red, shadow.green, shadow.blue) = color
            shadow.opacity = opacity(entry, fallback: shadow.opacity, name: "drop shadow")
            // Layer Knocks Out Drop Shadow: on (Photoshop's default) unless the file turns it off.
            if entry.bool("layerConceals") == false { shadow.knocksOut = false }
            return shadow
        }

        mutating func colorOverlay() -> ColorOverlayEffect? {
            guard let (entry, shows) = chosenEntry(single: "SoFi", multi: "solidFillMulti", name: "color overlay"),
                  let color = color(entry, shows: shows, name: "color overlay") else { return nil }
            noteUnmodeled(entry, shows: shows, name: "color overlay", color: color)
            var overlay = ColorOverlayEffect(enabled: shows)
            (overlay.red, overlay.green, overlay.blue) = color
            overlay.opacity = opacity(entry, fallback: overlay.opacity, name: "color overlay")
            return overlay
        }

        mutating func innerShadow() -> InnerShadowEffect? {
            guard let (entry, shows) = chosenEntry(single: "IrSh", multi: "innerShadowMulti", name: "inner shadow"),
                  let color = color(entry, shows: shows, name: "inner shadow") else { return nil }
            noteUnmodeled(entry, shows: shows, name: "inner shadow", color: color, spread: "choke")
            var shadow = InnerShadowEffect(enabled: shows)
            shadow.angle = angle(entry, fallback: shadow.angle, name: "inner shadow")
            shadow.distance = limited(Self.number(entry, "Dstn"), fallback: shadow.distance,
                                      to: 0...InnerShadowEffect.maxDistance, "inner shadow’s distance", unit: " px")
            shadow.blur = limited(Self.number(entry, "blur"), fallback: shadow.blur, to: 0...InnerShadowEffect.maxBlur,
                                  "inner shadow’s size", unit: " px")
            (shadow.red, shadow.green, shadow.blue) = color
            shadow.opacity = opacity(entry, fallback: shadow.opacity, name: "inner shadow")
            return shadow
        }

        mutating func outerGlow() -> OuterGlowEffect? {
            guard let (entry, shows) = chosenEntry(single: "OrGl", multi: nil, name: "outer glow"),
                  let color = color(entry, shows: shows, name: "outer glow") else { return nil }
            noteUnmodeled(entry, shows: shows, name: "outer glow", color: color)
            var glow = OuterGlowEffect(enabled: shows)
            glow.size = limited(Self.number(entry, "blur"), fallback: glow.size, to: 0...OuterGlowEffect.maxSize,
                                "outer glow’s size", unit: " px")
            (glow.red, glow.green, glow.blue) = color
            glow.opacity = opacity(entry, fallback: glow.opacity, name: "outer glow")
            return glow
        }

        /// Photoshop's Inner Glow: Compositor's glows in from the layer's edges, so a glow from its center (`glwS`
        /// `SrcC`) is noted.
        mutating func innerGlow() -> InnerGlowEffect? {
            guard let (entry, shows) = chosenEntry(single: "IrGl", multi: nil, name: "inner glow"),
                  let color = color(entry, shows: shows, name: "inner glow") else { return nil }
            noteUnmodeled(entry, shows: shows, name: "inner glow", color: color, spread: "choke")
            if shows, entry.enumValue("glwS") == "SrcC" {
                notes.append("The inner glow’s center source isn’t supported, so it may look different than in Photoshop. Its Photoshop settings are kept.")
            }
            var glow = InnerGlowEffect(enabled: shows)
            glow.size = limited(Self.number(entry, "blur"), fallback: glow.size, to: 0...InnerGlowEffect.maxSize,
                                "inner glow’s size", unit: " px")
            (glow.red, glow.green, glow.blue) = color
            glow.opacity = opacity(entry, fallback: glow.opacity, name: "inner glow")
            return glow
        }

        /// A note for each kind Compositor lacks that Photoshop shows on this layer.
        mutating func noteUnsupported() {
            for kind in PSDEffectsReader.unsupported {
                let shown = kind.keys.flatMap { entries(single: $0, multi: $0) }.contains { master && Self.isEnabled($0) }
                if shown { notes.append("\(kind.name) isn’t supported, so it isn’t shown. Its Photoshop settings are kept.") }
            }
        }

        /// One note, when the effect shows, for what Photoshop draws that Compositor's effect doesn't model: a blend
        /// mode other than Normal (Multiply in black and Screen in white draw just as Normal does), spread or choke
        /// (`Ckmt`), noise (`Nose`), a contour (`TrnS`) that isn't linear and the Precise glow technique (`GlwT`).
        mutating func noteUnmodeled(_ entry: PSDDescriptor, shows: Bool, name: String, color: (CGFloat, CGFloat, CGFloat),
                                    spread: String = "spread") {
            guard shows else { return }
            var unmodeled: [String] = []
            let mode = entry.enumValue("Md  ") ?? "Nrml"
            if mode != "Nrml", !(mode == "Mltp" && color == (0, 0, 0)), !(mode == "Scrn" && color == (1, 1, 1)) {
                unmodeled.append("blend mode")
            }
            if let amount = Self.number(entry, "Ckmt"), amount != 0 { unmodeled.append(spread) }
            if let noise = Self.number(entry, "Nose"), noise != 0 { unmodeled.append("noise") }
            if let contour = entry.object("TrnS"), !Self.isLinear(contour) { unmodeled.append("contour") }
            if let technique = entry.enumValue("GlwT"), technique != "SfBL" { unmodeled.append("Precise technique") }
            guard let last = unmodeled.last else { return }
            let list = unmodeled.count == 1 ? last : unmodeled.dropLast().joined(separator: ", ") + " and " + last
            notes.append("The \(name)’s \(list) \(unmodeled.count == 1 ? "isn’t" : "aren’t") supported, so it may look different than in Photoshop. Its Photoshop settings are kept.")
        }

        /// A contour (`ShpC`) whose points all lie on the diagonal, output equal to input. One whose curve can't be
        /// read counts as linear.
        static func isLinear(_ contour: PSDDescriptor) -> Bool {
            (contour.list("Crv ") ?? []).compactMap(object).allSatisfy { point in
                guard let x = number(point, "Hrzn"), let y = number(point, "Vrtc") else { return true }
                return abs(x - y) < 0.5
            }
        }

        // MARK: Entries

        /// The kind's entry to import and whether it shows: the first enabled `present` entry, else the first. Extra
        /// entries Photoshop shows are noted.
        mutating func chosenEntry(single: String, multi: String?, name: String) -> (PSDDescriptor, shows: Bool)? {
            let present = entries(single: single, multi: multi)
            guard !present.isEmpty else { return nil }
            let index = present.firstIndex(where: Self.isEnabled) ?? 0
            let chosen = present[index]
            let extra = master ? present.indices.filter { $0 != index && Self.isEnabled(present[$0]) }.count : 0
            if extra > 0 {
                notes.append("Compositor shows one \(name) per layer; \(extra) more \(extra == 1 ? "isn’t" : "aren’t") shown. \(extra == 1 ? "Its" : "Their") Photoshop settings are kept.")
            }
            return (chosen, master && Self.isEnabled(chosen))
        }

        /// The `present` entries under `multi` (a list), or else under `single`. A missing `present` counts as present.
        func entries(single: String, multi: String?) -> [PSDDescriptor] {
            let listed = multi.flatMap { root.list($0) }?.compactMap(Self.object) ?? []
            let all = listed.isEmpty ? (root.object(single).map { [$0] } ?? []) : listed
            return all.filter { $0.bool("present") ?? true }
        }

        static func object(_ value: PSDDescriptorValue) -> PSDDescriptor? {
            switch value {
            case .object(let descriptor), .globalObject(let descriptor): descriptor
            default: nil
            }
        }

        static func isEnabled(_ entry: PSDDescriptor) -> Bool { entry.bool("enab") ?? true }

        // MARK: Values

        static func number(_ entry: PSDDescriptor, _ key: String) -> Double? {
            switch entry[key] {
            case .unitFloat(_, let value)?, .double(let value)?: value
            case .integer(let value)?: Double(value)
            case .largeInteger(let value)?: Double(value)
            default: nil
            }
        }

        /// `Clr ` in 0…1, or nil (noted when the effect shows) when it isn't an RGB color.
        mutating func color(_ entry: PSDDescriptor, shows: Bool, name: String) -> (CGFloat, CGFloat, CGFloat)? {
            guard let rgb = entry.rgb("Clr ") else {
                if shows { notes.append("The \(name)’s color couldn’t be read, so it isn’t shown. Its Photoshop settings are kept.") }
                return nil
            }
            return (rgb.r / 255, rgb.g / 255, rgb.b / 255)
        }

        /// `Opct` (percent) as 0…1.
        mutating func opacity(_ entry: PSDDescriptor, fallback: Double, name: String) -> Double {
            Double(limited(Self.number(entry, "Opct"), fallback: CGFloat(fallback * 100), to: 0...100,
                           "\(name)’s opacity", unit: "%")) / 100
        }

        /// `lagl`, or the document's global light (resource 1037) when `uglg` is on. Angles are periodic, so one past
        /// ±360° is brought into range rather than limited.
        mutating func angle(_ entry: PSDDescriptor, fallback: CGFloat, name: String) -> CGFloat {
            let local = Self.number(entry, "lagl")
            let angle = entry.bool("uglg") == true ? globalLightAngle ?? local : local
            // Missing: the fallback; not a number: noted.
            guard let angle, angle.isFinite else {
                return limited(angle, fallback: fallback, to: -360...360, "\(name)’s angle", unit: "°")
            }
            return CGFloat((-360...360).contains(angle) ? angle : remainder(angle, 360))
        }

        /// `value` within `range`, noted when it had to change; `fallback` when it's missing.
        mutating func limited(_ value: Double?, fallback: CGFloat, to range: ClosedRange<CGFloat>, _ what: String,
                              unit: String) -> CGFloat {
            guard let value else { return fallback }
            let number = CGFloat(value)
            if number.isFinite, range.contains(number) { return number }
            guard number.isFinite else {
                notes.append("The \(what) couldn’t be read and was set to \(Self.format(fallback))\(unit).")
                return fallback
            }
            let result = min(range.upperBound, max(range.lowerBound, number))
            notes.append("The \(what) of \(Self.format(number))\(unit) is beyond what Compositor supports and was set to \(Self.format(result))\(unit).")
            return result
        }

        static func format(_ value: CGFloat) -> String {
            value == value.rounded() && abs(value) < 1e9 ? String(Int(value)) : String(format: "%.1f", Double(value))
        }
    }
}
