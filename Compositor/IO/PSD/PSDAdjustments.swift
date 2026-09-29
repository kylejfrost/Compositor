import CoreGraphics
import Foundation

/// Reads the settings blocks of Photoshop adjustment layers (Adobe's *Photoshop File Formats Specification*,
/// "Adjustment Layers") into Compositor's adjustments. Original implementation.
///
/// Settings Compositor can't read (a version it doesn't know, too few bytes, colors it can't convert) give nil: the
/// layer then stays a hidden placeholder that keeps its block. The block is kept either way and written back as it was.
nonisolated enum PSDAdjustments {
    struct Parsed: Equatable, Sendable {
        var adjustment: LayerAdjustment
        /// What the settings lose in Compositor, for the conversion report.
        var notes: [String] = []
    }

    /// The adjustment keys whose settings Compositor reads; the others (`PSDReader.adjustmentKeys`) are kinds it lacks.
    static let readableKeys: Set<String> = ["levl", "curv", "hue2", "hue ", "expA", "blnc", "nvrt", "blwh", "grdm"]

    static func parse(_ extra: [String: Data]) -> Parsed? {
        func block(_ key: String) -> Data? { extra[key].map { $0.startIndex == 0 ? $0 : Data($0) } }
        if let data = block("levl") { return levels(data).map { Parsed(adjustment: $0) } }
        if let data = block("curv") { return curves(data).map { Parsed(adjustment: $0) } }
        if let data = block("hue2") ?? block("hue ") { return hue(data) }
        if let data = block("expA") { return exposure(data).map { Parsed(adjustment: $0) } }
        if let data = block("blnc") { return colorBalance(data).map { Parsed(adjustment: $0) } }
        if block("nvrt") != nil { return Parsed(adjustment: LayerAdjustment(kind: .invert)) }
        if let data = block("blwh") { return blackWhite(data).map { Parsed(adjustment: $0) } }
        if let data = block("grdm") { return gradientMap(data) }
        return nil
    }

    /// `levl`: `u16 version (2)`, then 29 records of five `u16` (input black, input white, output black, output white,
    /// gamma × 100 in 10…999), composite RGB first, then red, green and blue.
    private static func levels(_ data: Data) -> LayerAdjustment? {
        guard data.count >= 292, u16(data, 0) == 2 else { return nil }
        var settings = LevelsSettings()
        for channel in 0..<4 {
            let base = 2 + channel * 10
            let inputBlack = Double(u16(data, base))
            let inputWhite = Double(u16(data, base + 2))
            let outputBlack = Double(u16(data, base + 4))
            let outputWhite = Double(u16(data, base + 6))
            let gamma = Double(u16(data, base + 8)) / 100
            settings.ranges[channel] = LevelRange(black: inputBlack, gamma: gamma, white: inputWhite,
                                                  outputBlack: outputBlack, outputWhite: outputWhite).normalized
        }
        return LayerAdjustment(kind: .levels, levels: settings)
    }

    /// `curv`: `u8` (nonzero: the curves are 256-entry lookup tables, which Compositor doesn't read) · `u16 version (1 or
    /// 4)` · `u32` which curves follow (version 1: a bit per channel, composite, red, green, blue; version 4: how many,
    /// in channel order), then each curve as a `u16` point count and `(output, input)` `u16` points. Photoshop follows
    /// them with `Crv ` · `u16 version` · `u32 count` and each curve again after its `u16` channel index, which is read
    /// instead when it's all there. A curve not listed stays a straight line.
    private static func curves(_ data: Data) -> LayerAdjustment? {
        guard data.count >= 7, data[0] == 0 else { return nil }
        let version = u16(data, 1)
        guard version == 1 || version == 4 else { return nil }
        let listed = u32(data, 3)
        let channels = version == 1 ? (0..<32).filter { listed & (1 << $0) != 0 } : Array(0..<Int(min(listed, 32)))
        var offset = 7
        /// A curve's points in 0…255 by input, running from input 0 to 255; nil past the data, empty for fewer than 2.
        func curve() -> [CurvePoint]? {
            guard offset + 2 <= data.count else { return nil }
            let count = Int(u16(data, offset))
            offset += 2
            guard offset + count * 4 <= data.count else { return nil }
            var points = (0..<count).map { index in
                let point = offset + index * 4
                return CurvePoint(x: min(255, Double(u16(data, point + 2))), y: min(255, Double(u16(data, point))))
            }
            offset += count * 4
            guard points.count >= 2 else { return [] }
            points.sort { $0.x < $1.x }
            if points[0].x != 0 { points.insert(CurvePoint(x: 0, y: points[0].y), at: 0) }
            if points[points.count - 1].x != 255 { points.append(CurvePoint(x: 255, y: points[points.count - 1].y)) }
            return points
        }
        var settings = CurvesSettings()
        for channel in channels {
            guard let points = curve() else { return nil }
            if channel < 4, !points.isEmpty { settings.channels[channel] = points }
        }
        if offset + 10 <= data.count, data[offset ..< offset + 4].elementsEqual("Crv ".utf8) {
            let count = Int(u32(data, offset + 6))
            offset += 10
            var extra = CurvesSettings(), complete = true
            for _ in 0..<count {
                guard offset + 2 <= data.count else { complete = false; break }
                let channel = Int(u16(data, offset))
                offset += 2
                guard let points = curve() else { complete = false; break }
                if channel < 4, !points.isEmpty { extra.channels[channel] = points }
            }
            if complete { settings = extra }
        }
        guard settings.isValid else { return nil }
        return LayerAdjustment(kind: .curves, curves: settings)
    }

    /// `hue2` (and Photoshop 4's `hue `): `u16 version (2) · u8 colorize · u8 pad · 3×i16 colorization (hue, saturation,
    /// lightness) · 3×i16 Master`, then for reds, yellows, greens, cyans, blues and magentas `4×i16 band (falloff
    /// start, range start, range end, falloff end) · 3×i16 hue, saturation, lightness`. Colorizing shows the
    /// colorization values as Master's. A band that isn't in order around the hue circle keeps the default; one wider
    /// than the 350° Compositor's bands span (`HueBand.setHandle`) is narrowed to that from its falloff start, noted.
    private static func hue(_ data: Data) -> Parsed? {
        guard data.count >= 16 + 6 * 14, u16(data, 0) == 2 else { return nil }
        func values(at offset: Int) -> RangeAdjustment {
            RangeAdjustment(hue: Double(i16(data, offset)), saturation: Double(i16(data, offset + 2)),
                            lightness: Double(i16(data, offset + 4)))
        }
        func wrapped(_ degrees: Double) -> Double { (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) }
        let colorize = data[2] != 0
        var settings = HueSaturationSettings(colorize: colorize)
        var notes: [String] = []
        settings.adjustments[.master] = values(at: colorize ? 4 : 10)
        for (index, range) in ColorRange.colorRanges.enumerated() {
            let offset = 16 + index * 14
            let degrees = (0..<4).map { wrapped(Double(i16(data, offset + $0 * 2))) }
            var band = HueBand(falloffStart: degrees[0], rangeStart: degrees[1], rangeEnd: degrees[2], falloffEnd: degrees[3])
            let span = HueBand.forward(band.falloffStart, band.falloffEnd)
            let start = HueBand.forward(band.falloffStart, band.rangeStart)
            let end = HueBand.forward(band.falloffStart, band.rangeEnd)
            if span > 0, start <= end, end <= span {
                if span > 350 {
                    band.falloffEnd = wrapped(band.falloffStart + 350)
                    band.rangeEnd = wrapped(band.falloffStart + min(end, 350))
                    band.rangeStart = wrapped(band.falloffStart + min(start, 350))
                    notes.append("The \(range.rawValue) hue range is wider than the 350° Compositor supports, so it was narrowed to 350°.")
                }
                settings.bands[range] = band
            }
            settings.adjustments[range] = values(at: offset + 8)
        }
        return Parsed(adjustment: LayerAdjustment(kind: .hsv, hsvSettings: settings), notes: notes)
    }

    /// `expA`: `u16 version (1)`, then exposure (stops), offset and gamma as big-endian `f32`.
    private static func exposure(_ data: Data) -> LayerAdjustment? {
        guard data.count >= 14, u16(data, 0) == 1 else { return nil }
        func float(_ offset: Int) -> Double { Double(Float(bitPattern: u32(data, offset))) }
        var adjustment = LayerAdjustment(kind: .exposure)
        adjustment.exposure = ExposureSettings(exposure: float(2), offset: float(6), gamma: float(10)).normalized
        return adjustment
    }

    /// `blnc`: shadows, midtones and highlights, each as cyan–red, magenta–green and yellow–blue `i16` (−100…100), then
    /// `u8` Preserve Luminosity.
    private static func colorBalance(_ data: Data) -> LayerAdjustment? {
        guard data.count >= 19 else { return nil }
        let range = ColorBalanceSettings.range
        let values = (0..<9).map { min(range.upperBound, max(range.lowerBound, Double(i16(data, $0 * 2)))) }
        var adjustment = LayerAdjustment(kind: .colorBalance)
        adjustment.colorBalance = ColorBalanceSettings(
            shadowCyanRed: values[0], shadowMagentaGreen: values[1], shadowYellowBlue: values[2],
            midCyanRed: values[3], midMagentaGreen: values[4], midYellowBlue: values[5],
            highlightCyanRed: values[6], highlightMagentaGreen: values[7], highlightYellowBlue: values[8],
            preserveLuminosity: data[18] != 0)
        return adjustment
    }

    /// `blwh`: `u32 16` and a descriptor of each color's percentage (`Rd  `, `Yllw`, `Grn `, `Cyn `, `Bl  `, `Mgnt`;
    /// −200…300), `useTint` and the tint as an `RGBC` color (`tintColor`), whose HSB hue and saturation become
    /// Compositor's tint. A value that's missing keeps Photoshop's default.
    private static func blackWhite(_ data: Data) -> LayerAdjustment? {
        var offset = 0
        guard let descriptor = try? PSDDescriptorReader.readBlock(data, at: &offset) else { return nil }
        var settings = BlackWhiteSettings()
        func percent(_ key: String, _ value: inout Double) {
            guard let number = descriptor.int(key).map(Double.init) ?? descriptor.double(key), number.isFinite else { return }
            value = min(BlackWhiteSettings.range.upperBound, max(BlackWhiteSettings.range.lowerBound, number))
        }
        percent("Rd  ", &settings.reds)
        percent("Yllw", &settings.yellows)
        percent("Grn ", &settings.greens)
        percent("Cyn ", &settings.cyans)
        percent("Bl  ", &settings.blues)
        percent("Mgnt", &settings.magentas)
        settings.tint = descriptor.bool("useTint") ?? false
        if let color = descriptor.rgb("tintColor") {
            (settings.tintHue, settings.tintSaturation) = hueAndSaturation(red: Double(color.r), green: Double(color.g),
                                                                           blue: Double(color.b))
        }
        var adjustment = LayerAdjustment(kind: .blackWhite)
        adjustment.blackWhite = settings
        return adjustment
    }

    /// An RGB color's hue (0…360°) and saturation (0…100%) in HSB; a gray has neither.
    private static func hueAndSaturation(red: Double, green: Double, blue: Double) -> (hue: Double, saturation: Double) {
        let brightest = max(red, green, blue), delta = brightest - min(red, green, blue)
        guard brightest > 0, delta > 0 else { return (0, 0) }
        let sector: Double = if brightest == red {
            (green - blue) / delta
        } else if brightest == green {
            2 + (blue - red) / delta
        } else {
            4 + (red - green) / delta
        }
        let hue = sector * 60
        return (hue < 0 ? hue + 360 : hue, delta / brightest * 100)
    }

    /// `grdm`: `u16 version · u8 reversed · u8 dithered`; in version 3 (Photoshop's gradient interpolation methods) a
    /// 4-byte method follows: `Gcls` (Classic), `Perc` (Perceptual), `Lnr ` (Linear) or `Smoo` (Smooth). Then the
    /// gradient's name (`u32` count, UTF-16), `u16` count and the color stops, each `i32 location (0…4096) · i32
    /// midpoint (%) · u16 color space · 4×u16 components · 2 bytes`; then transparency stops and noise settings, which
    /// Compositor doesn't use. Compositor's Gradient Map runs from the first stop's color to the last's, so more stops
    /// are noted. Their colors must be RGB (color space 0). It ramps the Classic way in sRGB, so another method is noted.
    private static func gradientMap(_ data: Data) -> Parsed? {
        let stopSize = 20
        guard data.count >= 4 else { return nil }
        let version = u16(data, 0)
        guard version == 1 || version == 3 else { return nil }
        let nameOffset = version == 3 ? 8 : 4
        guard data.count >= nameOffset + 4 else { return nil }
        let method = version == 3 ? String(decoding: data[4..<8], as: UTF8.self) : "Gcls"
        let countOffset = nameOffset + 4 + Int(u32(data, nameOffset)) * 2
        guard countOffset + 2 <= data.count else { return nil }
        let count = Int(u16(data, countOffset))
        guard count >= 2, countOffset + 2 + count * stopSize <= data.count else { return nil }
        func color(ofStop index: Int) -> AdjustmentColor? {
            let offset = countOffset + 2 + index * stopSize
            guard u16(data, offset + 8) == 0 else { return nil }
            func component(_ index: Int) -> Double { Double(u16(data, offset + 10 + index * 2)) / 65535 }
            return AdjustmentColor(red: component(0), green: component(1), blue: component(2))
        }
        guard let first = color(ofStop: 0), let last = color(ofStop: count - 1) else { return nil }
        var adjustment = LayerAdjustment(kind: .gradientMap)
        adjustment.gradientMap = GradientMapSettings(shadows: first, highlights: last, reversed: data[2] != 0)
        var notes = [String]()
        if count > 2 {
            notes.append("This gradient has \(count) color stops; Compositor’s Gradient Map keeps only the first and last. Its Photoshop settings are kept.")
        }
        if method != "Gcls" {
            let name = ["Perc": "Perceptual ", "Lnr ": "Linear ", "Smoo": "Smooth "][method] ?? ""
            notes.append("This gradient’s \(name)interpolation isn’t supported; Compositor’s Gradient Map blends the Classic way, so it may look different than in Photoshop. Its Photoshop settings are kept.")
        }
        return Parsed(adjustment: adjustment, notes: notes)
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(u16(data, offset)) << 16 | UInt32(u16(data, offset + 2))
    }

    private static func i16(_ data: Data, _ offset: Int) -> Int16 {
        Int16(bitPattern: u16(data, offset))
    }
}
