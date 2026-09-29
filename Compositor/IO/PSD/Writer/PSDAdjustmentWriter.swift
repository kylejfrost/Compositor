import CoreGraphics
import Foundation

/// Writes adjustment layers' settings as Photoshop's adjustment blocks (Adobe's *Photoshop File Formats
/// Specification*, "Adjustment Layers", in the layouts psd-tools 1.19 reads and writes): the inverse of
/// `PSDAdjustments`. Original implementation.
///
/// The record is the layer record writer's: no pixels (a zero rectangle and empty channels), flags 0x18, and the
/// layer's mask when it has one. Its settings block is, for a layer Photoshop never saw, a fresh one, first among its
/// blocks as Photoshop orders them. A layer the document was opened with keeps the file's block byte for byte while its
/// settings are what import made of that block; once edited, the block is rewritten where it was, keeping what
/// Compositor doesn't show: the Hue/Saturation half (Master or the colorization) that isn't Compositor's Master, the
/// Levels records past the four channels, a gradient's version, method, name and middle stops, Black & White's other
/// keys and, until the tint's hue or saturation changes, its tint color. Every block written is padded to 4 bytes, as
/// Photoshop and psd-tools write them (Photoshop refuses a 19-byte `blnc`).
///
/// Kinds Photoshop has no adjustment layer for (`AdjustmentKind.psdKey` nil) refuse the document unless the save
/// allows lossy output, which writes each as a pixel layer of its result instead (`rasterizingUnwritable`).
nonisolated enum PSDAdjustmentWriter {
    /// Brings an adjustment layer record's `blocks` in line with the layer's settings; warnings for what the file holds
    /// differently.
    static func update(_ blocks: inout [PSDTaggedBlock], for layer: ProjectLayerRecord) -> [PSDWriteWarning] {
        guard let adjustment = layer.adjustment, let key = adjustment.kind.psdKey else { return [] }
        // Photoshop 4's `hue ` has the `hue2` layout; import reads `hue2` first.
        let existing = blocks.firstIndex { $0.key == key } ?? (key == "hue2" ? blocks.firstIndex { $0.key == "hue " } : nil)
        let original = existing.map { Data(blocks[$0].data) }
        if let existing, let original, PSDAdjustments.parse([blocks[existing].key: original])?.adjustment == adjustment {
            return []
        }
        let (data, notes) = block(for: adjustment, original: original)
        if let existing {
            blocks[existing] = PSDTaggedBlock(signature: blocks[existing].signature, key: key, data: data)
        } else {
            blocks.insert(PSDTaggedBlock(key: key, data: data), at: 0)
        }
        // A Curves note is a resampled curve: Photoshop draws a different curve from the document's.
        return notes.map { PSDWriteWarning(layerName: layer.name, message: $0, lossy: adjustment.kind == .curves) }
    }

    /// The block `adjustment` is written as, and notes on what it holds differently: fresh, or edited into `original`,
    /// the file's own block, where that can be read.
    private static func block(for adjustment: LayerAdjustment, original: Data?) -> (data: Data, notes: [String]) {
        switch adjustment.kind {
        case .levels: (levels(adjustment.levels, original: original), [])
        case .curves: curves(adjustment.curves)
        case .hsv: hueSaturation(adjustment.resolvedHSV, original: original)
        case .exposure: (exposure(adjustment.exposure), [])
        case .colorBalance: (colorBalance(adjustment.colorBalance), [])
        case .blackWhite: (blackWhite(adjustment.blackWhite, original: original), [])
        case .gradientMap: (gradientMap(adjustment.gradientMap, original: original), [])
        // Invert has no settings; the kinds Photoshop lacks never get here.
        default: (Data(), [])
        }
    }

    // MARK: Levels and Curves

    /// `levl`: version 2 and 29 records of `u16` input black, input white, output black, output white and gamma × 100
    /// (10…999): the composite, red, green and blue, then records RGB doesn't use, kept from the file (with anything
    /// after them) or written at their defaults.
    private static func levels(_ settings: LevelsSettings, original: Data?) -> Data {
        var data: Data
        if let original, original.count >= 292, u16(original, 0) == 2 {
            data = original
        } else {
            var writer = PSDByteWriter()
            writer.u16(2)
            for _ in 0..<29 { for value: UInt16 in [0, 255, 0, 255, 100] { writer.u16(value) } }
            data = writer.data
        }
        for (channel, range) in settings.ranges.prefix(4).enumerated() {
            let range = range.normalized
            let black = u16(range.black, in: 0...254)
            var record = PSDByteWriter()
            for value in [black, max(black + 1, u16(range.white, in: 0...255)), u16(range.outputBlack, in: 0...255),
                          u16(range.outputWhite, in: 0...255), u16(range.gamma * 100, in: 10...999)] {
                record.u16(value)
            }
            data.replaceSubrange(2 + channel * 10 ..< 12 + channel * 10, with: record.data)
        }
        return padded(data)
    }

    /// `curv`: `u8 0 · u16 1 · u32 0x0F` (all four curves: composite, red, green, blue), each curve's `u16` point count
    /// and `(output, input)` `u16` points, then `Crv ` · `u16 4` · `u32 4` and each curve again after its channel index.
    /// A longer curve than Photoshop holds (`maximumCurvePoints`) is resampled at even steps along Compositor's curve.
    private static func curves(_ settings: CurvesSettings) -> (data: Data, notes: [String]) {
        var notes: [String] = []
        let limit = maximumCurvePoints
        let curves = LevelsChannel.allCases.enumerated().map { channel, name in
            let points = settings.channels.indices.contains(channel) ? settings.channels[channel] : []
            guard points.count > limit else { return photoshopPoints(points) }
            notes.append("Its \(name.rawValue) curve has \(points.count) points, more than the \(limit) Photoshop holds, so it was resampled to \(limit).")
            return photoshopPoints((0..<limit).map { step in
                let x = Double(step) * 255 / Double(limit - 1)
                return CurvePoint(x: x, y: settings.value(x, channel: channel))
            })
        }
        var writer = PSDByteWriter()
        func write(_ points: [(input: UInt16, output: UInt16)]) {
            writer.u16(UInt16(points.count))
            for point in points {
                writer.u16(point.output)
                writer.u16(point.input)
            }
        }
        writer.u8(0)
        writer.u16(1)
        writer.u32(0x0F)
        curves.forEach(write)
        writer.code("Crv ")
        writer.u16(4)
        writer.u32(UInt32(curves.count))
        for (channel, points) in curves.enumerated() {
            writer.u16(UInt16(channel))
            write(points)
        }
        return (padded(writer.data), notes)
    }

    /// The most points a curve Photoshop 2026 opens has. The file format allows 19 (psd-tools reads that many), but
    /// Photoshop drops a Curves layer whose curve has 17 or more: it opens as an empty pixel layer.
    static let maximumCurvePoints = 16

    /// A curve's points on Photoshop's whole-number grid, inputs increasing: two that round to the same input keep the
    /// first, except that the end at 255 stays. A missing curve is the straight line.
    private static func photoshopPoints(_ points: [CurvePoint]) -> [(input: UInt16, output: UInt16)] {
        var result: [(input: UInt16, output: UInt16)] = []
        for point in points {
            let input = u16(point.x, in: 0...255), output = u16(point.y, in: 0...255)
            if let last = result.last, last.input >= input {
                if input == 255 { result[result.count - 1] = (input, output) }
                continue
            }
            result.append((input, output))
        }
        return result.count >= 2 ? result : [(0, 0), (255, 255)]
    }

    // MARK: Hue/Saturation

    /// `hue2`: `u16 version (2) · u8 colorize · u8 pad`, the colorization (hue, saturation, lightness) and Master as
    /// `i16`, then for reds, yellows, greens, cyans, blues and magentas the band (falloff start, range start, range end,
    /// falloff end, in degrees) and hue, saturation and lightness as `i16`. Colorizing, Compositor shows the
    /// colorization as Master; the half it doesn't show is the file's, or Photoshop's own: the colorization it starts
    /// from (0, 25, 0), Master at 0. Hues are turns, written in Photoshop's range: −180…180, the colorization 0…359;
    /// the colorization's saturation is 0…100.
    private static func hueSaturation(_ settings: HueSaturationSettings, original: Data?) -> (data: Data, notes: [String]) {
        let file = original.flatMap { $0.count >= 100 && u16($0, 0) == 2 ? $0 : nil }
        func values(_ adjustment: RangeAdjustment?, colorization: Bool = false) -> [Int16] {
            let adjustment = adjustment ?? RangeAdjustment()
            let hue = adjustment.hue.isFinite ? adjustment.hue.rounded().remainder(dividingBy: 360) : 0
            return [i16(colorization && hue < 0 ? hue + 360 : hue, in: -180...359),
                    i16(adjustment.saturation, in: colorization ? 0...100 : -100...100), i16(adjustment.lightness, in: -100...100)]
        }
        func stored(at offset: Int) -> [Int16]? {
            file.map { data in (0..<3).map { Int16(bitPattern: u16(data, offset + $0 * 2)) } }
        }
        let master = values(settings.adjustments[.master], colorization: settings.colorize)
        let colorization = settings.colorize ? master : stored(at: 4) ?? [0, 25, 0]
        let photoshopMaster = settings.colorize ? stored(at: 10) ?? [0, 0, 0] : master
        var writer = PSDByteWriter()
        writer.u16(2)
        writer.u8(settings.colorize ? 1 : 0)
        writer.u8(0)
        (colorization + photoshopMaster).forEach { writer.i16($0) }
        for range in ColorRange.colorRanges {
            for degrees in (settings.bands[range] ?? range.defaultBand).handles {
                let whole = Int(degrees.isFinite ? degrees.rounded() : 0) % 360
                writer.i16(Int16(whole < 0 ? whole + 360 : whole))
            }
            values(settings.adjustments[range]).forEach { writer.i16($0) }
        }
        var notes: [String] = []
        if settings.invertRange, settings.range != .master,
           (settings.adjustments[settings.range] ?? RangeAdjustment()) != RangeAdjustment() {
            notes.append("Photoshop can’t apply a color range outside its band, so the file applies the \(settings.range.rawValue) settings inside it.")
        }
        return (padded(writer.data), notes)
    }

    // MARK: Exposure, Color Balance, Black & White

    /// `expA`: `u16 version (1)`, then exposure, offset and gamma as `f32`.
    private static func exposure(_ settings: ExposureSettings) -> Data {
        let settings = settings.normalized
        var writer = PSDByteWriter()
        writer.u16(1)
        for value in [settings.exposure, settings.offset, settings.gamma] { writer.u32(Float(value).bitPattern) }
        return padded(writer.data)
    }

    /// `blnc`: shadows, midtones and highlights, each cyan–red, magenta–green and yellow–blue as `i16` (−100…100), then
    /// `u8` Preserve Luminosity.
    private static func colorBalance(_ settings: ColorBalanceSettings) -> Data {
        var writer = PSDByteWriter()
        for value in [settings.shadowCyanRed, settings.shadowMagentaGreen, settings.shadowYellowBlue,
                      settings.midCyanRed, settings.midMagentaGreen, settings.midYellowBlue,
                      settings.highlightCyanRed, settings.highlightMagentaGreen, settings.highlightYellowBlue] {
            writer.i16(i16(value, in: ColorBalanceSettings.range))
        }
        writer.u8(settings.preserveLuminosity ? 1 : 0)
        return padded(writer.data)
    }

    /// `blwh`: `u32 16` and a descriptor of each color's percentage as a `long`, `useTint`, the tint as an `RGBC` color
    /// (the tint's hue and saturation at full brightness), then Photoshop's preset fields: `bwPresetKind` 1 (Default)
    /// at Photoshop's default values, untinted, else 2 (Custom), as Photoshop 2026 reads them, and no
    /// `blackAndWhitePresetFileName`: the values are no preset file's. Edited, the file's descriptor keeps its other
    /// keys, and its tint color while the tint's hue and saturation are what import read from it.
    private static func blackWhite(_ settings: BlackWhiteSettings, original: Data?) -> Data {
        var descriptor = PSDDescriptor(classID: "null")
        var imported: BlackWhiteSettings?
        var offset = 0
        if let original, let read = try? PSDDescriptorReader.readBlock(original, at: &offset) {
            descriptor = read
            imported = PSDAdjustments.parse(["blwh": original])?.adjustment.blackWhite
        }
        func set(_ key: String, _ value: PSDDescriptorValue) {
            if let index = descriptor.items.firstIndex(where: { $0.key.id == key }) {
                descriptor.items[index].value = value
            } else {
                descriptor.items.append((key: PSDKey(key), value: value))
            }
        }
        let percents = [settings.reds, settings.yellows, settings.greens, settings.cyans, settings.blues, settings.magentas]
        for (key, percent) in zip(["Rd  ", "Yllw", "Grn ", "Cyn ", "Bl  ", "Mgnt"], percents) {
            set(key, .integer(Int32(i16(percent, in: BlackWhiteSettings.range))))
        }
        set("useTint", .bool(settings.tint))
        if imported?.tintHue != settings.tintHue || imported?.tintSaturation != settings.tintSaturation
            || descriptor["tintColor"] == nil {
            set("tintColor", tintColor(hue: settings.tintHue, saturation: settings.tintSaturation))
        }
        let defaults = BlackWhiteSettings()
        let isDefault = !settings.tint && [settings.reds, settings.yellows, settings.greens, settings.cyans, settings.blues,
                                            settings.magentas] == [defaults.reds, defaults.yellows, defaults.greens,
                                                                   defaults.cyans, defaults.blues, defaults.magentas]
        set("bwPresetKind", .integer(isDefault ? 1 : 2))
        set("blackAndWhitePresetFileName", .string(""))
        return padded(PSDDescriptorWriter.block(descriptor))
    }

    /// The `RGBC` color (0–255 components) of hue `hue`° and saturation `saturation`% at full brightness in HSB: the
    /// inverse of how import reads the tint.
    private static func tintColor(hue: Double, saturation: Double) -> PSDDescriptorValue {
        let wrapped = hue.isFinite ? (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) : 0
        let sector = wrapped / 60
        let chroma = 255 * (saturation.isFinite ? min(1, max(0, saturation / 100)) : 0)
        let middle = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (red, green, blue): (Double, Double, Double) = switch Int(sector) {
        case 0: (chroma, middle, 0)
        case 1: (middle, chroma, 0)
        case 2: (0, chroma, middle)
        case 3: (0, middle, chroma)
        case 4: (middle, 0, chroma)
        default: (chroma, 0, middle)
        }
        let lightest = 255 - chroma
        return .object(PSDDescriptor(classID: "RGBC", items: [
            (key: "Rd  ", value: .double(red + lightest)), (key: "Grn ", value: .double(green + lightest)),
            (key: "Bl  ", value: .double(blue + lightest)),
        ]))
    }

    // MARK: Gradient Map

    /// `grdm`, version 1 (Classic): `u8` reversed and dithered, the gradient's name, two color stops (`u32 location`
    /// 0…4096 · `u32 midpoint` % · `u16` color space 0, RGB · 4×`u16` components · 2 pad bytes) from the shadows color to
    /// the highlights color, two opaque transparency stops, then the fields Photoshop writes after them (expansion 2,
    /// smoothness, length 32, mode, seed, transparency and vector-color flags, roughness 2048, color model 3, and the
    /// minimum and maximum colors). Smoothness is 0, a straight ramp between the stops as Compositor draws it (Photoshop
    /// 2026 shows it identically on a gray ramp; its default, 4096, eases the ramp by up to 11 levels). Edited, the
    /// file's own gradient changes only its reversed flag and the colors of its first and last stops.
    private static func gradientMap(_ settings: GradientMapSettings, original: Data?) -> Data {
        let ends = [settings.shadows, settings.highlights].map { color in
            [color.red, color.green, color.blue].map { u16($0 * 65535, in: 0...65535) }
        }
        if let original, let stops = colorStops(original) {
            var data = original
            data[2] = settings.reversed ? 1 : 0
            for (stop, color) in zip([stops.first, stops.last], ends) {
                var components = PSDByteWriter()
                color.forEach { components.u16($0) }
                data.replaceSubrange(stop + 10 ..< stop + 16, with: components.data)
            }
            return padded(data)
        }
        var writer = PSDByteWriter()
        writer.u16(1)
        writer.u8(settings.reversed ? 1 : 0)
        writer.u8(0)
        writer.unicode("Custom", nulTerminated: false)
        writer.u16(2)
        for (location, color) in zip([UInt32(0), 4096], ends) {
            writer.u32(location)
            writer.u32(50)
            writer.u16(0)
            (color + [0]).forEach { writer.u16($0) }
            writer.u16(0)
        }
        writer.u16(2)
        for location: UInt32 in [0, 4096] {
            writer.u32(location)
            writer.u32(50)
            writer.u16(255)
        }
        for value: UInt16 in [2, 0, 32, 0] { writer.u16(value) }
        writer.u32(0)
        writer.u16(0)
        writer.u16(0)
        writer.u32(2048)
        writer.u16(3)
        for value: UInt16 in [0, 0, 0, 0, 100, 100, 100, 100, 0] { writer.u16(value) }
        return padded(writer.data)
    }

    /// Where a `grdm` block's first and last color stops start, when both are RGB, as import reads them.
    private static func colorStops(_ data: Data) -> (first: Int, last: Int)? {
        guard data.count >= 4, u16(data, 0) == 1 || u16(data, 0) == 3 else { return nil }
        let nameOffset = u16(data, 0) == 3 ? 8 : 4
        guard data.count >= nameOffset + 4 else { return nil }
        let countOffset = nameOffset + 4 + Int(u32(data, nameOffset)) * 2
        guard countOffset + 2 <= data.count else { return nil }
        let count = Int(u16(data, countOffset))
        let first = countOffset + 2, last = first + (count - 1) * 20
        guard count >= 2, last + 20 <= data.count, u16(data, first + 8) == 0, u16(data, last + 8) == 0 else { return nil }
        return (first, last)
    }

    // MARK: Kinds Photoshop lacks

    /// `snapshot` with each adjustment layer Photoshop has no adjustment for written as a pixel layer of its result,
    /// "<name> (rasterized)", over the canvas: what Compositor draws for it. The layer keeps its place, visibility,
    /// opacity, blend, Fill, mask and clipping. Without `allowLossy` the first such layer from the bottom refuses the
    /// document.
    ///
    /// Clipped in a clipping stack, the adjustment applies to the stack alone (`stacked(_:base:between:in:)`);
    /// otherwise to everything Compositor draws before it (folders pass through, so that includes what's under its
    /// folder).
    static func rasterizingUnwritable(_ snapshot: ProjectSnapshot, allowLossy: Bool) throws
        -> (snapshot: ProjectSnapshot, warnings: [PSDWriteWarning]) {
        let order = LayerHierarchy.entries(snapshot.manifest.layers).map(\.layer)
        let unwritable = order.filter { $0.isGroup != true && $0.adjustment != nil && $0.adjustment?.kind.psdKey == nil }
        guard let first = unwritable.first, let kind = first.adjustment?.kind else { return (snapshot, []) }
        guard allowLossy else { throw PSDWriteError.unsupportedAdjustment(layerName: first.name, kind: kind) }
        let canvas = CGSize(width: snapshot.manifest.width, height: snapshot.manifest.height)
        var manifest = snapshot.manifest, images = snapshot.images, warnings: [PSDWriteWarning] = []
        for layer in unwritable {
            guard let adjustment = layer.adjustment, let position = order.firstIndex(where: { $0.id == layer.id }),
                  let index = manifest.layers.firstIndex(where: { $0.id == layer.id }) else { continue }
            let result: CGImage
            if let stack = clippingStack(of: layer, in: snapshot.manifest.layers) {
                result = try stacked(adjustment, base: stack.base, between: stack.between, in: snapshot)
            } else {
                let below = try backdrop(hiding: Set(order[position...].map(\.id)), in: snapshot)
                do { result = try adjustment.apply(below, region: CGRect(origin: .zero, size: canvas)) } catch { throw PSDWriteError.render }
            }
            let name = "\(layer.name) (rasterized)"
            manifest.layers[index] = layer.rasterized(named: name, canvas: canvas)
            images[layer.id] = ImportedImage(image: result, thumbnail: result, name: name)
            warnings.append(PSDWriteWarning(layerName: layer.name,
                message: "Photoshop has no \(adjustment.kind.rawValue) adjustment, so it was saved as “\(name)”, a pixel layer of its result on the layers below.",
                lossy: true))
        }
        return (ProjectSnapshot(manifest: manifest, images: images, masks: snapshot.masks), warnings)
    }

    /// What Compositor draws before the layers in `hidden` (a layer and every one drawn after it): the document with
    /// them hidden.
    private static func backdrop(hiding hidden: Set<UUID>, in snapshot: ProjectSnapshot) throws -> CGImage {
        var manifest = snapshot.manifest
        for index in manifest.layers.indices where manifest.layers[index].isGroup != true && hidden.contains(manifest.layers[index].id) {
            manifest.layers[index].isVisible = false
        }
        return try composite(manifest.layers, in: snapshot)
    }

    /// The clipping stack `layer` is drawn in, as `LiveMaskRenderer.prepareStacks` forms it among the layers drawn:
    /// its base (`maskSourceID`, a pixel layer that isn't clipped itself) and the layers between them, each clipped to
    /// that base in the same folder; nil when `layer` isn't in one. Compositor skips hidden layers, so they neither
    /// join nor break a stack, but `layer` and its base count as drawn: hidden, the pixel layer holds what showing
    /// them would draw.
    private static func clippingStack(of layer: ProjectLayerRecord, in layers: [ProjectLayerRecord])
        -> (base: ProjectLayerRecord, between: [ProjectLayerRecord])? {
        guard let baseID = layer.maskSourceID else { return nil }
        let drawn = LayerHierarchy.entries(layers).filter {
            $0.layer.isGroup != true && ($0.visible || $0.layer.id == layer.id || $0.layer.id == baseID)
        }.map(\.layer)
        guard let baseIndex = drawn.firstIndex(where: { $0.id == baseID }),
              let index = drawn.firstIndex(where: { $0.id == layer.id }), baseIndex < index else { return nil }
        let base = drawn[baseIndex], run = drawn[(baseIndex + 1)...index]
        guard base.maskSourceID == nil, base.adjustment == nil,
              run.allSatisfy({ $0.maskSourceID == baseID && $0.parentID == base.parentID }) else { return nil }
        return (base, Array(run.dropLast()))
    }

    /// What `adjustment`, clipped to `base` above the stacked layers `between`, draws in Compositor, as a pixel layer
    /// clipped to the same base holds it. Compositor draws a clipping stack by itself
    /// (`LiveMaskRenderer.drawComposite`): the base, its color divided by its alpha to opaque (black where it has
    /// none), the stacked layers over it, the adjustment on that; then the base's alpha is restored and the stack drawn
    /// at the base's blend and opacity. Here the base is drawn at normal blend and full opacity (and outside its
    /// folders, whose opacity and mask apply to the whole stack), which changes only its alpha; the stacked layers
    /// keep the opacity their folders give them. The layers below the base never enter.
    ///
    /// Photoshop restores the base's alpha itself: it clips the pixel layer to the base and draws the group at the
    /// base's blend and opacity. So the pixel layer is opaque wherever the base has any alpha, its colors the
    /// adjustment's result there as Compositor holds it (premultiplied bytes, as `layer_restore_alpha` reads them), and
    /// empty elsewhere. The base's own alpha in it would apply twice, mixing the base's unadjusted colors into its
    /// soft edges.
    private static func stacked(_ adjustment: LayerAdjustment, base: ProjectLayerRecord, between: [ProjectLayerRecord],
                                in snapshot: ProjectSnapshot) throws -> CGImage {
        let width = snapshot.manifest.width, height = snapshot.manifest.height
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        var alone = base
        alone.parentID = nil
        alone.isVisible = true
        alone.opacity = 1
        alone.blendMode = .normal
        let drawn = try composite([alone], in: snapshot)
        guard let group = try? BrushRaster.context(width: width, height: height, mask: false),
              let coverage = try? BrushRaster.context(width: width, height: height, mask: true),
              let pixels = group.data?.assumingMemoryBound(to: UInt8.self),
              let alpha = coverage.data?.assumingMemoryBound(to: UInt8.self) else { throw PSDWriteError.render }
        BrushRaster.draw(drawn, in: rect, mask: false, context: group)
        layer_extract_alpha(pixels, group.bytesPerRow, alpha, coverage.bytesPerRow, width, height)
        layer_unpremultiply_opaque(pixels, group.bytesPerRow, width, height)
        guard var stack = group.makeImage() else { throw PSDWriteError.render }
        if !between.isEmpty {
            // The opaque base as a pixel layer the stacked layers clip to: a stack that restores full alpha, so its
            // composite is the stack's colors. Out of their folders, they keep the opacity the folders gave them.
            let records = Dictionary(snapshot.manifest.layers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let opaqueID = UUID()
            let opaque = ProjectLayerRecord(id: opaqueID, name: base.name, isVisible: true,
                                            transform: LayerTransform(origin: .zero, size: rect.size),
                                            imageFile: "\(opaqueID.uuidString).png")
            let clipped = between.map { layer in
                var layer = layer
                layer.opacity = layer.effectiveOpacity(in: records)
                layer.parentID = nil
                layer.maskSourceID = opaqueID
                return layer
            }
            var images = snapshot.images
            images[opaqueID] = ImportedImage(image: stack, thumbnail: stack, name: base.name)
            stack = try composite([opaque] + clipped, in: ProjectSnapshot(manifest: snapshot.manifest, images: images,
                                                                          masks: snapshot.masks))
        }
        let result: CGImage
        do { result = try adjustment.apply(stack, region: rect) } catch { throw PSDWriteError.render }
        BrushRaster.draw(result, in: rect, mask: false, context: group)
        for row in 0..<height {
            for column in 0..<width where alpha[row * coverage.bytesPerRow + column] != 0 {
                alpha[row * coverage.bytesPerRow + column] = 255
            }
        }
        layer_restore_alpha(pixels, group.bytesPerRow, alpha, coverage.bytesPerRow, width, height)
        guard let image = group.makeImage() else { throw PSDWriteError.render }
        return image
    }

    /// Compositor's rendering of `layers`, the images and masks `snapshot` holds for them, over its canvas.
    private static func composite(_ layers: [ProjectLayerRecord], in snapshot: ProjectSnapshot) throws -> CGImage {
        var manifest = snapshot.manifest
        manifest.layers = layers
        do {
            return try ImageExporter.composite(ProjectSnapshot(manifest: manifest, images: snapshot.images, masks: snapshot.masks)).image
        } catch ExportError.tooLarge {
            throw PSDWriteError.tooLarge
        } catch {
            throw PSDWriteError.render
        }
    }

    // MARK: Bytes

    /// Zeros to a multiple of 4 bytes.
    private static func padded(_ data: Data) -> Data {
        data + Data(count: (4 - data.count % 4) % 4)
    }

    /// `value` rounded into `range`, 0 (or the nearest end of `range`) when it isn't finite.
    private static func u16(_ value: Double, in range: ClosedRange<Double>) -> UInt16 {
        UInt16(min(range.upperBound, max(range.lowerBound, value.isFinite ? value.rounded() : 0)))
    }

    private static func i16(_ value: Double, in range: ClosedRange<Double>) -> Int16 {
        Int16(min(range.upperBound, max(range.lowerBound, value.isFinite ? value.rounded() : 0)))
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) << 8 | UInt16(data[data.startIndex + offset + 1])
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(u16(data, offset)) << 16 | UInt32(u16(data, offset + 2))
    }
}

nonisolated extension AdjustmentKind {
    /// The Photoshop adjustment block this kind is written as; nil for a kind Photoshop has no adjustment layer for,
    /// which a PSD holds only as pixels (`PSDAdjustmentWriter.rasterizingUnwritable`).
    var psdKey: String? {
        switch self {
        case .levels: "levl"
        case .curves: "curv"
        case .hsv: "hue2"
        case .exposure: "expA"
        case .colorBalance: "blnc"
        case .invert: "nvrt"
        case .blackWhite: "blwh"
        case .gradientMap: "grdm"
        default: nil
        }
    }
}

nonisolated extension ProjectLayerRecord {
    /// This adjustment layer as a pixel layer called `name` over the canvas, keeping its place, visibility, opacity,
    /// blend, Fill, locks, Photoshop data, clipping and mask, which stays where it was over the layer.
    fileprivate func rasterized(named name: String, canvas: CGSize) -> ProjectLayerRecord {
        ProjectLayerRecord(id: id, name: name, isVisible: isVisible, transform: LayerTransform(origin: .zero, size: canvas),
                           imageFile: "\(id.uuidString).png", parentID: parentID, opacity: opacity, blendMode: blendMode,
                           maskFile: maskFile, maskEnabled: maskEnabled, maskSourceID: maskSourceID,
                           maskPlacement: maskFile == nil ? maskPlacement : maskPlacement ?? transform,
                           maskLinked: maskLinked, locks: locks, fillOpacity: fillOpacity, psd: psd)
    }
}
