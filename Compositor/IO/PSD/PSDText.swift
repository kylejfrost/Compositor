import AppKit
import Foundation

/// One character style run of a Photoshop type layer, its values already merged over the run defaults and the
/// normal style sheet. `length` counts UTF-16 units of `PSDTypeLayer.text`.
nonisolated struct PSDTextRun: Equatable, Sendable {
    var length: Int
    var fontName: String
    /// Pre-transform pixels.
    var fontSize: Double
    var autoLeading: Bool
    /// Pre-transform pixels, baseline to baseline.
    var leading: Double
    /// Thousandths of an em.
    var tracking: Double
    /// `FillColor.Type`: 1 is RGB, with `fillValues` = [a, r, g, b] in 0…1.
    var fillType: Int
    var fillValues: [Double]
    /// Photoshop's character scaling (1 is none) and faux styles, which Compositor's text doesn't have.
    var horizontalScale: Double = 1
    var verticalScale: Double = 1
    var fauxBold = false
    var fauxItalic = false
}

/// One paragraph run: `Justification` 0 left, 1 right, 2 center, 3–5 justified with the last line left, right or
/// centered, 6 justify all.
nonisolated struct PSDParagraphRun: Equatable, Sendable {
    var length: Int
    var justification: Int
}

/// What a `TySh` block holds, decoded. Sizes are Photoshop's pre-transform pixels; `transform` is
/// `[xx, xy, yx, yy, tx, ty]`, with `(tx, ty)` the first line's baseline at the alignment point (point text) or the
/// box's origin (paragraph text).
nonisolated struct PSDTypeLayer: Equatable, Sendable {
    var transform: [Double]
    /// `EngineDict.Editor.Text` as stored: paragraphs end in `\r`, forced line breaks are U+0003.
    var text: String
    var fontNames: [String]
    var styleRuns: [PSDTextRun]
    var paragraphRuns: [PSDParagraphRun]
    var isParagraphText: Bool
    /// `BoxBounds` [left top right bottom] of paragraph text, in text space.
    var boxBounds: CGRect?
    var bounds: CGRect?
    var boundingBox: CGRect?
    var antiAlias: String
    var orientation: String
    var warpStyle: String
    var textIndex: Int
}

nonisolated enum PSDTypeError: Error, Equatable {
    case malformed
}

/// Reads Photoshop type layers (`TySh`) and maps them onto Compositor's text. Original implementation from Adobe's
/// *Photoshop File Formats Specification* ("Type tool object setting") and the EngineData structure.
nonisolated enum PSDTypeReader {
    /// `u16 version (1) · 6×f64 transform · u16 text version (50) · text descriptor block · u16 warp version (1) ·
    /// warp descriptor block · 4×i32` (the last are not needed and may be missing).
    static func parse(_ tySh: Data) throws -> PSDTypeLayer {
        let data = tySh.startIndex == 0 ? tySh : Data(tySh)
        var offset = 0
        func u16() throws -> UInt16 {
            guard offset + 2 <= data.count else { throw PSDTypeError.malformed }
            defer { offset += 2 }
            return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
        }
        func f64() throws -> Double {
            guard offset + 8 <= data.count else { throw PSDTypeError.malformed }
            var bits: UInt64 = 0
            for index in 0..<8 { bits = bits << 8 | UInt64(data[offset + index]) }
            offset += 8
            return Double(bitPattern: bits)
        }
        guard try u16() == 1 else { throw PSDTypeError.malformed }
        var transform: [Double] = []
        for _ in 0..<6 { transform.append(try f64()) }
        guard transform.allSatisfy(\.isFinite), try u16() == 50 else { throw PSDTypeError.malformed }
        let descriptor = try PSDDescriptorReader.readBlock(data, at: &offset)
        guard try u16() == 1 else { throw PSDTypeError.malformed }
        let warp = try PSDDescriptorReader.readBlock(data, at: &offset)
        guard case .rawData(let engineBytes)? = descriptor["EngineData"] else { throw PSDTypeError.malformed }
        let engine = try EngineDataParser.parse(engineBytes)
        let resources = engine["ResourceDict"] ?? engine["DocumentResources"]
        guard let text = engine[path: "EngineDict.Editor.Text"]?.string ?? descriptor.string("Txt "),
              let resources else { throw PSDTypeError.malformed }
        let fontNames = (resources["FontSet"]?.array ?? []).map { $0["Name"]?.string ?? "" }
        // Run lengths count UTF-16 units of `text`: none may be negative or longer than the text, and their sum must
        // fit in an `Int`, so the coverage arithmetic below can't overflow.
        let textLength = text.utf16.count
        func runLengths(_ values: [EngineValue]) throws -> [Int] {
            var total = 0
            return try values.map { value in
                guard let length = value.int, (0...textLength).contains(length) else { throw PSDTypeError.malformed }
                let (sum, overflow) = total.addingReportingOverflow(length)
                guard !overflow else { throw PSDTypeError.malformed }
                total = sum
                return length
            }
        }

        // A run's values fall back on the run defaults, then on the normal style sheet.
        let normalStyle = resources[path: "StyleSheetSet.\(resources["TheNormalStyleSheet"]?.int ?? 0).StyleSheetData"]
        let defaultStyle = engine[path: "EngineDict.StyleRun.DefaultRunData.StyleSheet.StyleSheetData"]
        guard let styleArray = engine[path: "EngineDict.StyleRun.RunArray"]?.array,
              let styleLengthValues = engine[path: "EngineDict.StyleRun.RunLengthArray"]?.array,
              !styleArray.isEmpty, styleArray.count == styleLengthValues.count else { throw PSDTypeError.malformed }
        let styleLengths = try runLengths(styleLengthValues)
        var styleRuns: [PSDTextRun] = []
        for (run, length) in zip(styleArray, styleLengths) {
            let data = run[path: "StyleSheet.StyleSheetData"]
            func value(_ key: String) -> EngineValue? { data?[key] ?? defaultStyle?[key] ?? normalStyle?[key] }
            let fontIndex = value("Font")?.int ?? 0
            let fill = value("FillColor")
            let fontSize = value("FontSize")?.double ?? 12
            let leading = value("Leading")?.double ?? 0
            let tracking = value("Tracking")?.double ?? 0
            guard fontSize.isFinite, leading.isFinite, tracking.isFinite else { throw PSDTypeError.malformed }
            styleRuns.append(PSDTextRun(
                length: length, fontName: fontNames.indices.contains(fontIndex) ? fontNames[fontIndex] : "",
                fontSize: fontSize, autoLeading: value("AutoLeading")?.bool ?? true, leading: leading, tracking: tracking,
                fillType: fill?["Type"]?.int ?? 1,
                fillValues: fill?["Values"]?.array?.compactMap(\.double) ?? [1, 0, 0, 0],
                horizontalScale: value("HorizontalScale")?.double ?? 1, verticalScale: value("VerticalScale")?.double ?? 1,
                fauxBold: value("FauxBold")?.bool ?? false, fauxItalic: value("FauxItalic")?.bool ?? false))
        }

        let normalParagraph = resources[path: "ParagraphSheetSet.\(resources["TheNormalParagraphSheet"]?.int ?? 0).Properties"]
        let defaultParagraph = engine[path: "EngineDict.ParagraphRun.DefaultRunData.ParagraphSheet.Properties"]
        let paragraphArray = engine[path: "EngineDict.ParagraphRun.RunArray"]?.array ?? []
        let paragraphLengths = try runLengths(engine[path: "EngineDict.ParagraphRun.RunLengthArray"]?.array ?? [])
        guard paragraphArray.count == paragraphLengths.count else { throw PSDTypeError.malformed }
        var paragraphRuns: [PSDParagraphRun] = []
        for (run, length) in zip(paragraphArray, paragraphLengths) {
            let justification = run[path: "ParagraphSheet.Properties.Justification"]?.int
                ?? defaultParagraph?["Justification"]?.int ?? normalParagraph?["Justification"]?.int ?? 0
            paragraphRuns.append(PSDParagraphRun(length: length, justification: justification))
        }

        let shape = engine[path: "EngineDict.Rendered.Shapes.Children.0"]
        let cookie = shape?[path: "Cookie.Photoshop"]
        let isParagraphText = (cookie?["ShapeType"]?.int ?? shape?["ShapeType"]?.int ?? 0) == 1
        var boxBounds: CGRect?
        if let values = cookie?["BoxBounds"]?.array?.compactMap(\.double), values.count == 4, values.allSatisfy(\.isFinite) {
            boxBounds = CGRect(x: values[0], y: values[1], width: values[2] - values[0], height: values[3] - values[1])
        }
        return PSDTypeLayer(
            transform: transform, text: text, fontNames: fontNames, styleRuns: styleRuns, paragraphRuns: paragraphRuns,
            isParagraphText: isParagraphText, boxBounds: boxBounds,
            bounds: rect(descriptor.object("bounds")), boundingBox: rect(descriptor.object("boundingBox")),
            antiAlias: descriptor.enumValue("AntA") ?? "", orientation: descriptor.enumValue("Ornt") ?? "Hrzn",
            warpStyle: warp.enumValue("warpStyle") ?? "warpNone", textIndex: descriptor.int("TextIndex") ?? 0)
    }

    /// The text descriptor's `TextIndex` (which of the document's `Txt2` texts is the layer's), read without the
    /// EngineData, so it is known even when the rest of the type data can't be read. Nil when the header or the
    /// text descriptor can't be read, or the descriptor has none.
    static func textIndex(_ tySh: Data) -> Int32? {
        let data = tySh.startIndex == 0 ? tySh : Data(tySh)
        // `u16 1 · 6×f64 · u16 50` precede the text descriptor.
        var offset = 2 + 6 * 8 + 2
        guard data.count >= offset, data[0] == 0, data[1] == 1, data[offset - 2] == 0, data[offset - 1] == 50,
              let descriptor = try? PSDDescriptorReader.readBlock(data, at: &offset),
              let index = descriptor.int("TextIndex") else { return nil }
        return Int32(exactly: index)
    }

    private static func rect(_ descriptor: PSDDescriptor?) -> CGRect? {
        guard let descriptor, let left = descriptor.unit("Left")?.value, let top = descriptor.unit("Top ")?.value,
              let right = descriptor.unit("Rght")?.value, let bottom = descriptor.unit("Btom")?.value,
              [left, top, right, bottom].allSatisfy(\.isFinite) else { return nil }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    // MARK: Mapping

    /// Photoshop's faux bold and italic: Compositor draws the font as it is.
    static let fauxStyleNote = "This text uses Photoshop’s faux bold or italic, which Compositor’s text doesn’t have. The imported pixels are kept; editing the text draws it without them."

    /// Why `layer` can't be edited as Compositor text, as a conversion note; nil when it can. The layer then keeps
    /// Photoshop's pixels, and its type data stays in its blocks to be written back.
    static func unsupportedReason(_ layer: PSDTypeLayer) -> String? {
        let keep = "can’t be edited as text yet, so the layer keeps Photoshop’s pixels. Its type settings are kept."
        let t = layer.transform
        guard t.count == 6 else { return "This text’s placement \(keep)" }
        let (xx, xy, yx, yy) = (t[0], t[1], t[2], t[3])
        let sx = hypot(xx, xy), sy = hypot(yx, yy)
        if layer.orientation == "Vrtc" { return "Vertical text \(keep)" }
        if layer.warpStyle != "warpNone" { return "Warped text \(keep)" }
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0 else { return "This text’s placement \(keep)" }
        // The cosine of the angle between the text's x and y axes: 0 unless the text is skewed.
        if abs(xx * yx + xy * yy) / (sx * sy) >= 0.01 { return "Skewed text \(keep)" }
        if abs(atan2(xy, xx)) > 0.0001 { return "Rotated text \(keep)" }
        if xx * yy - xy * yx < 0 { return "Mirrored text \(keep)" }
        guard let run = dominantRun(layer) else { return "This text’s styles \(keep)" }
        if run.fillType != 1 || run.fillValues.count != 4 || !run.fillValues.allSatisfy(\.isFinite) {
            return "Text whose color isn’t RGB \(keep)"
        }
        if layer.isParagraphText {
            guard let box = layer.boxBounds, box.width > 0, box.height > 0 else { return "This text’s box \(keep)" }
        }
        return nil
    }

    /// Compositor text for `layer`: the dominant style run (most characters, runs of only line breaks aside) over the
    /// whole text, sizes scaled by the transform, and `origin`, the document point Photoshop's first baseline (point
    /// text) or box top-left (paragraph text) sits on. Nil for vertical, warped, skewed (≥ 1%), rotated or mirrored
    /// text, non-RGB fills, and text whose values Compositor's text can't hold.
    @MainActor
    static func style(_ layer: PSDTypeLayer, fontResolver: FontResolver.Type) -> (style: LayerTextStyle, origin: CGPoint, notes: [String])? {
        guard unsupportedReason(layer) == nil, let run = dominantRun(layer) else { return nil }
        let t = layer.transform
        let sx = hypot(t[0], t[1]), sy = hypot(t[2], t[3])
        var notes: [String] = []
        var style = LayerTextStyle()
        style.content = content(layer.text)
        style.fontName = run.fontName
        style.fontSize = CGFloat(min(2000, max(1, run.fontSize * sy)))
        style.leading = run.autoLeading ? 0 : CGFloat(min(5000, max(0, run.leading * sy)))
        style.tracking = CGFloat(min(1000, max(-100, run.tracking / 1000 * Double(style.fontSize))))
        let values = run.fillValues.map { CGFloat(min(1, max(0, $0))) }
        style.red = values[1]; style.green = values[2]; style.blue = values[3]
        let justification = dominantParagraph(layer)?.justification ?? 0
        switch justification {
        case 1, 4: style.alignment = .right
        case 2, 5: style.alignment = .center
        default: style.alignment = .left
        }
        if (3...5).contains(justification) {
            notes.append("Justified text isn’t supported; it’s editable as \(style.alignment.rawValue.lowercased())-aligned text.")
        } else if justification == 6 {
            notes.append("Justified text isn’t supported; it’s editable as left-aligned text.")
        }
        let ratio = sx / sy
        if abs(ratio - 1) >= 0.01 { style.horizontalScale = CGFloat(min(10, max(0.1, ratio))) }
        var origin = CGPoint(x: t[4], y: t[5])
        if layer.isParagraphText, let box = layer.boxBounds {
            let padding = Double(LayerTextStyle.padding)
            // Whole pixels, as Compositor's boxes are (see `LayerTextStyle.scaled`).
            style.boxSize = CGSize(width: (box.width * sx + 2 * padding).rounded(), height: (box.height * sy + 2 * padding).rounded())
            origin = CGPoint(x: t[4] + box.minX * t[0] + box.minY * t[2], y: t[5] + box.minX * t[1] + box.minY * t[3])
        }
        guard style.isValid, origin.x.isFinite, origin.y.isFinite else { return nil }
        if run.fauxBold || run.fauxItalic { notes.append(fauxStyleNote) }
        if let note = otherStylesNote(layer, dominant: run, scale: sy) { notes.append(note) }
        let resolved = fontResolver.resolve(style.fontName, size: style.fontSize)
        if resolved.isSubstitute {
            let name = resolved.font.displayName ?? resolved.font.fontName
            notes.append("Font “\(style.fontName)” isn't installed. The imported pixels are kept; editing this text will use \(name) until the font is installed.")
        }
        return (style, origin, notes)
    }

    /// The stored text as Compositor text: Photoshop's final `\r` dropped, and paragraph ends (`\r`) and forced line
    /// breaks (U+0003) as `\n`.
    static func content(_ text: String) -> String {
        var text = text
        if text.hasSuffix("\r") { text.removeLast() }
        return text.replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{3}", with: "\n")
    }

    /// How many of each run's UTF-16 units aren't line terminators, so a run holding only the final `\r`
    /// (usually in `AdobeInvisFont`) never counts. Each run is clamped to the text that remains, so no length, however
    /// large or negative, can overflow or step outside the text.
    private static func coverage<Run>(_ runs: [Run], length: (Run) -> Int, in text: String) -> [Int] {
        let units = Array(text.utf16)
        var start = 0
        return runs.map { run in
            let end = start + max(0, min(length(run), units.count - start))
            defer { start = end }
            guard start < end else { return 0 }
            return units[start..<end].filter { $0 != 0x0D && $0 != 0x0A && $0 != 0x03 }.count
        }
    }

    /// The style run covering the most characters; the first on a tie, and the first run when none covers any.
    static func dominantRun(_ layer: PSDTypeLayer) -> PSDTextRun? {
        let counts = coverage(layer.styleRuns, length: \.length, in: layer.text)
        guard let best = counts.indices.max(by: { counts[$0] < counts[$1] || (counts[$0] == counts[$1] && $0 > $1) }) else { return nil }
        return layer.styleRuns[best]
    }

    private static func dominantParagraph(_ layer: PSDTypeLayer) -> PSDParagraphRun? {
        let counts = coverage(layer.paragraphRuns, length: \.length, in: layer.text)
        guard let best = counts.indices.max(by: { counts[$0] < counts[$1] || (counts[$0] == counts[$1] && $0 > $1) }) else { return nil }
        return layer.paragraphRuns[best]
    }

    /// The most other styles the mixed-styles note names; the rest are counted.
    private static let namedStyles = 5

    /// A note naming the (font, size) of the other runs that show characters, when the text mixes styles: the first
    /// `namedStyles` of them in text order, then how many more. One pass over the runs, however many there are.
    private static func otherStylesNote(_ layer: PSDTypeLayer, dominant: PSDTextRun, scale: Double) -> String? {
        func size(_ run: PSDTextRun) -> String {
            let value = (min(2000, max(1, run.fontSize * scale)) * 10).rounded() / 10
            return value == value.rounded() ? String(Int(value)) : String(value)
        }
        func label(_ run: PSDTextRun) -> String { "\(run.fontName) \(size(run)) px" }
        let counts = coverage(layer.styleRuns, length: \.length, in: layer.text)
        let shown = zip(layer.styleRuns, counts).filter { $0.1 > 0 }.map(\.0)
        let main = label(dominant)
        var seen: Set<String> = [], named: [String] = []
        var differs = false
        for run in shown where run != dominant {
            let name = label(run)
            if name != main {
                if seen.insert(name).inserted, named.count < namedStyles { named.append(name) }
            } else if run.fillValues != dominant.fillValues || run.tracking != dominant.tracking
                        || run.leading != dominant.leading || run.autoLeading != dominant.autoLeading
                        || run.horizontalScale != dominant.horizontalScale || run.verticalScale != dominant.verticalScale
                        || run.fauxBold != dominant.fauxBold || run.fauxItalic != dominant.fauxItalic {
                differs = true
            }
        }
        if !named.isEmpty {
            let more = seen.count - named.count
            let list = named.joined(separator: ", ") + (more > 0 ? " and \(more) more" : "")
            return "This text mixes styles. It’s editable as \(main) throughout; editing it drops its other styles (\(list))."
        }
        return differs ? "This text mixes colors, spacing or character styles. It’s editable with its main style; editing it applies that style throughout." : nil
    }
}
