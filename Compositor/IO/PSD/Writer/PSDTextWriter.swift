import CoreGraphics
import Foundation

/// Writes live text as an editable Photoshop type layer: a `TySh` block (Adobe's *Photoshop File Formats
/// Specification*, "Type tool object setting") beside the rendered pixels, which stay in the channels so the file shows
/// the text even where Photoshop can't lay it out again. Original implementation; the EngineData follows what Photoshop
/// 2026 writes for type layers.
///
/// Text space is Photoshop's: its origin is the first baseline at the alignment point (point text) or the box's
/// top-left (paragraph text), one unit is a pixel of the text tool's raster vertically and `horizontalScale` of them
/// across, and `FontSize` is the style's size in those units. The `TySh` transform maps it into the document through
/// the layer's placement (`BrushRaster.pixelToDocument`).
///
/// Type data the layer was imported with is written back while the text is what import made of it and its pixels are
/// still Photoshop's (`importedTextAnchor`, which the first redraw removes): byte for byte while the layer stays where
/// it was, with only its transform moved when the layer was moved, scaled or turned, or its pixels resampled by Image
/// Size (keeping every style run Photoshop had). Edited text is written from its style, even once edited back to the imported one, since its pixels are the
/// text tool's render; text rasterized since, or all text when `PSDWriteOptions.textAsPixels` asks for
/// it, is written as pixels only.
nonisolated enum PSDTextWriter {
    // MARK: Layers

    /// Adds, rewrites or removes `record`'s `TySh` block for `layer`, whose pixels are `raster`. `baked` says the
    /// record's pixels aren't the layer's own (the writer applied a clip to them), so the layer is written as those
    /// pixels. Returns whether the block written is the one the file had (or neither has one), so the document's
    /// `Txt2` still describes it.
    static func apply(to record: inout PSDLayerRecord, layer: ProjectLayerRecord, raster: CGImage?,
                      sidecar: PSDLayerSidecar, extras: PSDLayerExtras?, options: PSDWriteOptions, baked: Bool = false,
                      indices: inout PSDTextIndices) throws -> Bool {
        let stored = extras?.block("TySh")
        func write(_ block: Data?) -> Bool {
            if let block {
                if let index = record.blocks.firstIndex(where: { $0.key == "TySh" }) {
                    record.blocks[index].data = block
                } else {
                    // First, where Photoshop puts it on a type layer.
                    record.blocks.insert(PSDTaggedBlock(key: "TySh", data: block), at: 0)
                }
            } else {
                record.blocks.removeAll { $0.key == "TySh" }
            }
            return block == stored
        }
        // Text that import made editable and that is plain pixels now (Rasterize Layer, a paint stroke), or whose clip
        // was applied to its pixels, is written as a pixel layer.
        if options.textAsPixels || baked || (layer.text == nil && extras?.importedText != nil) { return write(nil) }
        guard let style = layer.text else {
            // Type Compositor can't edit is written as it was read.
            return write(stored.map { numbered($0, indices: &indices) })
        }
        guard let metrics = sidecar.textMetrics else { throw PSDWriteError.invalidText(layerName: layer.name) }

        // Where the origin is in the layer's pixels: where Photoshop put it while its pixels are still Photoshop's,
        // else where the text tool draws it.
        var anchor = metrics.anchor
        var toDocument = BrushRaster.pixelToDocument(layer.transform, width: Int(metrics.size.width),
                                                     height: Int(metrics.size.height))
        if let unit = extras?.importedTextAnchor, let raster, raster.width > 0, raster.height > 0 {
            // Photoshop's text space is in the pixels import read, which Image Size may have resampled since.
            let size = extras?.importedTextPixelSize ?? CGSize(width: raster.width, height: raster.height)
            let width = max(1, Int(size.width)), height = max(1, Int(size.height))
            anchor = CGPoint(x: unit.x * CGFloat(width), y: unit.y * CGFloat(height))
            toDocument = BrushRaster.pixelToDocument(layer.transform, width: width, height: height)
        }
        // Photoshop's own type data describes these pixels only until the text is drawn again: after an edit, even one
        // undone by another (a recolor and back), they are the text tool's render, so the type data is
        // written from the style and Photoshop's other runs go, as they did in Compositor.
        if let stored, extras?.importedTextAnchor != nil, style == extras?.importedText,
           let placed = placing(stored, anchor: anchor, toDocument: toDocument) {
            return write(numbered(placed, indices: &indices))
        }
        let textToDocument = CGAffineTransform(scaleX: style.widthScale, y: 1)
            .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y))
            .concatenating(toDocument)
        let block = typeToolBlock(style, metrics: metrics, transform: textToDocument,
                                  textIndex: indices.claim(extras?.textIndex),
                                  fontName: sidecar.fontPostScriptName ?? style.fontName)
        return write(block)
    }

    /// `tySh`, Photoshop's own type data, with its transform moved so that the text origin, which import anchored at
    /// `anchor` in the layer's pixels, follows them through `toDocument`: the bytes as they are while it stays put.
    /// Nil when `tySh` can't be read.
    static func placing(_ tySh: Data, anchor: CGPoint, toDocument: CGAffineTransform) -> Data? {
        guard let type = try? PSDTypeReader.parse(tySh), type.transform.count == 6 else { return nil }
        let t = type.transform
        let stored = CGAffineTransform(a: t[0], b: t[1], c: t[2], d: t[3], tx: t[4], ty: t[5])
        // The point import anchored: Photoshop's origin, or the top-left of a paragraph's box.
        var origin = CGPoint(x: t[4], y: t[5])
        if type.isParagraphText, let box = type.boxBounds { origin = box.origin.applying(stored) }
        let moved = stored.concatenating(CGAffineTransform(translationX: anchor.x - origin.x, y: anchor.y - origin.y))
            .concatenating(toDocument)
        let values = [moved.a, moved.b, moved.c, moved.d, moved.tx, moved.ty].map(Double.init)
        guard values.allSatisfy(\.isFinite) else { return nil }
        if zip(values, t).allSatisfy({ abs($0 - $1) <= 1e-9 * max(1, abs($1)) }) { return tySh }
        var data = Data(tySh)
        for (index, value) in values.enumerated() {
            withUnsafeBytes(of: value.bitPattern.bigEndian) { data.replaceSubrange(2 + index * 8 ..< 10 + index * 8, with: $0) }
        }
        return data
    }

    /// `tySh` with the `TextIndex` `indices` gives it: its own unless another type layer has it already (a duplicate).
    /// Unchanged when its index can't be read.
    static func numbered(_ tySh: Data, indices: inout PSDTextIndices) -> Data {
        guard let index = PSDTypeReader.textIndex(tySh) else { return tySh }
        let claimed = indices.claim(index)
        guard claimed != index else { return tySh }
        let data = Data(tySh)
        // `u16 1 · 6×f64 · u16 50` precede the text descriptor.
        var offset = 2 + 6 * 8 + 2
        guard var descriptor = try? PSDDescriptorReader.readBlock(data, at: &offset),
              let item = descriptor.items.firstIndex(where: { $0.key.id == "TextIndex" }) else { return tySh }
        descriptor.items[item].value = .integer(claimed)
        return data.prefix(2 + 6 * 8 + 2) + PSDDescriptorWriter.block(descriptor) + data.suffix(from: offset)
    }

    // MARK: Type data

    /// A `TySh` payload for `style`: `u16 1 · 6×f64 transform (xx, xy, yx, yy, tx, ty) · u16 50 · TxLr descriptor ·
    /// u16 1 · warp descriptor · 4×i32 0`, padded to 4 bytes. `transform` maps text space to the document.
    static func typeToolBlock(_ style: LayerTextStyle, metrics: PSDTextMetrics, transform: CGAffineTransform,
                              textIndex: Int32, fontName: String) -> Data {
        let bounds: CGRect
        if let box = boxBounds(style) {
            bounds = box
        } else {
            let lineWidth = Double(metrics.lineWidth)
            let left = style.alignment == .left ? 0 : -lineWidth * (style.alignment == .center ? 0.5 : 1)
            let bottom = Double(metrics.descent) + Double(max(0, metrics.lineCount - 1)) * Double(style.lineHeight)
            bounds = CGRect(x: left, y: -Double(metrics.ascent), width: lineWidth, height: bottom + Double(metrics.ascent))
        }
        func rect(_ classID: String) -> PSDDescriptorValue {
            .object(PSDDescriptor(classID: PSDKey(classID), items: [
                (key: "Left", value: .unitFloat(unit: "#Pnt", value: Double(bounds.minX))),
                (key: "Top ", value: .unitFloat(unit: "#Pnt", value: Double(bounds.minY))),
                (key: "Rght", value: .unitFloat(unit: "#Pnt", value: Double(bounds.maxX))),
                (key: "Btom", value: .unitFloat(unit: "#Pnt", value: Double(bounds.maxY))),
            ]))
        }
        let engine = PSDEngineDataWriter.data(engineData(style, fontName: fontName, fontType: metrics.fontType))
        let text = PSDDescriptor(classID: "TxLr", items: [
            (key: "Txt ", value: .string(paragraphs(style.content).joined(separator: "\r"))),
            (key: "textGridding", value: .enumerated(type: "textGridding", value: "None")),
            (key: "Ornt", value: .enumerated(type: "Ornt", value: "Hrzn")),
            (key: "AntA", value: .enumerated(type: "Annt", value: "AnSm")),
            (key: "bounds", value: rect("bounds")),
            (key: "boundingBox", value: rect("boundingBox")),
            (key: "TextIndex", value: .integer(textIndex)),
            (key: "EngineData", value: .rawData(engine)),
        ])
        // Photoshop writes `warp` as a four-character stringID, with its length.
        let warp = PSDDescriptor(classID: PSDKey("warp", explicitLength: true), items: [
            (key: "warpStyle", value: .enumerated(type: "warpStyle", value: "warpNone")),
            (key: "warpValue", value: .double(0)),
            (key: "warpPerspective", value: .double(0)),
            (key: "warpPerspectiveOther", value: .double(0)),
            (key: "warpRotate", value: .enumerated(type: "Ornt", value: "Hrzn")),
        ])
        var writer = PSDByteWriter()
        writer.u16(1)
        for value in [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty] {
            writer.f64(Double(value))
        }
        writer.u16(50)
        writer.bytes(PSDDescriptorWriter.block(text))
        writer.u16(1)
        writer.bytes(PSDDescriptorWriter.block(warp))
        writer.bytes(Data(count: 16))
        writer.pad(to: 4)
        return writer.data
    }

    /// Paragraph text's box in text space (`BoxBounds`): the box less its padding, narrowed by the horizontal scale
    /// the transform carries. Nil for point text.
    private static func boxBounds(_ style: LayerTextStyle) -> CGRect? {
        guard let box = style.boxSize else { return nil }
        let padding = LayerTextStyle.padding
        return CGRect(x: 0, y: 0, width: max(0, box.width - 2 * padding) / style.widthScale, height: max(0, box.height - 2 * padding))
    }

    /// The text's paragraphs: Compositor's line breaks (`\n`, `\r\n` or `\r`) end them, as Photoshop's `\r` does.
    private static func paragraphs(_ content: String) -> [String] {
        let unified = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return unified.components(separatedBy: "\n")
    }

    // MARK: EngineData

    private typealias Items = [(key: String, value: EngineValue)]

    /// The EngineData of a type layer: `Editor.Text` ends every paragraph in `\r` (the last one too), one paragraph
    /// run per paragraph and one style run per stretch of one color, face and size, so every run
    /// length fits the text and they add up to it exactly. The layer's face is `FontSet` entry 0.
    static func engineData(_ style: LayerTextStyle, fontName: String, fontType: Int) -> EngineValue {
        let paragraphs = Self.paragraphs(style.content)
        let text = paragraphs.map { $0 + "\r" }.joined()
        let justification = switch style.alignment {
        case .left: 0
        case .right: 1
        case .center: 2
        }
        let (styleRuns, fonts) = Self.styleRuns(style, baseFontName: fontName)
        let fontSize = Double(style.fontSize)
        let isAutoLeading = style.leading <= 0
        let run: Items = [
            (key: "Font", value: .integer(0)), (key: "FontSize", value: .number(fontSize)),
            (key: "FauxBold", value: .bool(false)), (key: "FauxItalic", value: .bool(false)),
            (key: "AutoLeading", value: .bool(isAutoLeading)), (key: "Leading", value: .number(Double(style.lineHeight))),
            (key: "HorizontalScale", value: .number(1)), (key: "VerticalScale", value: .number(1)),
            // Thousandths of an em.
            (key: "Tracking", value: .integer(Int((Double(style.tracking) / fontSize * 1000).rounded()))),
            (key: "AutoKerning", value: .bool(true)), (key: "Kerning", value: .integer(0)),
            (key: "BaselineShift", value: .number(0)), (key: "FontCaps", value: .integer(0)),
            (key: "FontBaseline", value: .integer(0)), (key: "Underline", value: .bool(false)),
            (key: "Strikethrough", value: .bool(false)), (key: "Ligatures", value: .bool(true)),
            (key: "DLigatures", value: .bool(false)), (key: "BaselineDirection", value: .integer(1)),
            (key: "Tsume", value: .number(0)), (key: "StyleRunAlignment", value: .integer(2)),
            (key: "Language", value: .integer(0)), (key: "NoBreak", value: .bool(false)),
            (key: "FillColor", value: fillColor(PaletteColor(red: style.red, green: style.green, blue: style.blue))),
            (key: "StrokeColor", value: color([1, 0, 0, 0])), (key: "YUnderline", value: .integer(1)),
            (key: "HindiNumbers", value: .bool(false)), (key: "Kashida", value: .integer(1)),
        ]
        let adjustments: EngineValue = .dictionary([(key: "Axis", value: numbers([1, 0, 1])), (key: "XY", value: numbers([0, 0]))])
        let paragraphRun: Items = [
            (key: "DefaultRunData", value: .dictionary([
                (key: "ParagraphSheet", value: .dictionary([(key: "DefaultStyleSheet", value: .integer(0)),
                                                            (key: "Properties", value: .dictionary([]))])),
                (key: "Adjustments", value: adjustments),
            ])),
            (key: "RunArray", value: .array(paragraphs.map { _ in
                .dictionary([
                    (key: "ParagraphSheet", value: .dictionary([
                        (key: "DefaultStyleSheet", value: .integer(0)),
                        (key: "Properties", value: paragraphProperties(justification: justification, hyphenates: false)),
                    ])),
                    (key: "Adjustments", value: adjustments),
                ])
            })),
            (key: "RunLengthArray", value: .array(paragraphs.map { .integer($0.utf16.count + 1) })),
            (key: "IsJoinable", value: .integer(1)),
        ]
        let styleRun: Items = [
            (key: "DefaultRunData", value: .dictionary([(key: "StyleSheet", value: .dictionary([
                (key: "StyleSheetData", value: .dictionary([])),
            ]))])),
            (key: "RunArray", value: .array(styleRuns.map { styled in
                let data = run.map { item in
                    if item.key == "FillColor" { return (key: item.key, value: fillColor(styled.color)) }
                    if item.key == "Font" { return (key: item.key, value: EngineValue.integer(styled.fontIndex)) }
                    if item.key == "FontSize" { return (key: item.key, value: EngineValue.number(Double(styled.fontSize))) }
                    return item
                }
                return .dictionary([(key: "StyleSheet", value: .dictionary([(key: "StyleSheetData", value: .dictionary(data))]))])
            })),
            (key: "RunLengthArray", value: .array(styleRuns.map { .integer($0.length) })),
            (key: "IsJoinable", value: .integer(2)),
        ]
        let shapeType = style.boxSize == nil ? 0 : 1
        var cookie: Items = [(key: "ShapeType", value: .integer(shapeType))]
        if let box = boxBounds(style) {
            cookie.append((key: "BoxBounds", value: numbers([0, 0, Double(box.width), Double(box.height)])))
        } else {
            cookie.append((key: "PointBase", value: numbers([0, 0])))
        }
        cookie.append((key: "Base", value: .dictionary([
            (key: "ShapeType", value: .integer(shapeType)),
            (key: "TransformPoint0", value: numbers([1, 0])), (key: "TransformPoint1", value: numbers([0, 1])),
            (key: "TransformPoint2", value: numbers([0, 0])),
        ])))
        let rendered: Items = [
            (key: "Version", value: .integer(1)),
            (key: "Shapes", value: .dictionary([
                (key: "WritingDirection", value: .integer(0)),
                (key: "Children", value: .array([.dictionary([
                    (key: "ShapeType", value: .integer(shapeType)), (key: "Procession", value: .integer(0)),
                    (key: "Lines", value: .dictionary([(key: "WritingDirection", value: .integer(0)),
                                                       (key: "Children", value: .array([]))])),
                    (key: "Cookie", value: .dictionary([(key: "Photoshop", value: .dictionary(cookie))])),
                ])])),
            ])),
        ]
        let gridColor = color([0, 0, 0, 1])
        let engine: Items = [
            (key: "Editor", value: .dictionary([(key: "Text", value: .string(text))])),
            (key: "ParagraphRun", value: .dictionary(paragraphRun)),
            (key: "StyleRun", value: .dictionary(styleRun)),
            (key: "GridInfo", value: .dictionary([
                (key: "GridIsOn", value: .bool(false)), (key: "ShowGrid", value: .bool(false)),
                (key: "GridSize", value: .number(18)), (key: "GridLeading", value: .number(22)),
                (key: "GridColor", value: gridColor), (key: "GridLeadingFillColor", value: gridColor),
                (key: "AlignLineHeightToGridFlags", value: .bool(false)),
            ])),
            // Smooth, as the text descriptor's `AntA` says.
            (key: "AntiAlias", value: .integer(3)),
            (key: "UseFractionalGlyphWidths", value: .bool(true)),
            (key: "Rendered", value: .dictionary(rendered)),
        ]
        let resources = documentResources(fontNames: fonts, fontType: fontType)
        return .dictionary([(key: "EngineDict", value: .dictionary(engine)), (key: "ResourceDict", value: resources),
                            (key: "DocumentResources", value: resources)])
    }

    private static func numbers(_ values: [Double]) -> EngineValue { .array(values.map(EngineValue.number)) }

    /// The style runs over `Editor.Text`. A CRLF is one paragraph break, and the closing CR inherits the last
    /// letter's color and face. The returned font names index `FontSet` in the same order the runs use.
    private static func styleRuns(_ style: LayerTextStyle, baseFontName: String)
        -> (runs: [(length: Int, color: PaletteColor, fontIndex: Int, fontSize: CGFloat)], fonts: [String]) {
        let base = PaletteColor(red: style.red, green: style.green, blue: style.blue)
        let units = Array(style.content.utf16)
        var colors = Array(repeating: base, count: units.count)
        var faces = Array(repeating: baseFontName, count: units.count)
        var sizes = Array(repeating: style.fontSize, count: units.count)
        for run in style.colorRuns ?? [] where run.length > 0 {
            let color = PaletteColor(red: run.red, green: run.green, blue: run.blue)
            for index in max(0, run.location)..<max(max(0, run.location), min(units.count, run.location + run.length)) {
                colors[index] = color
            }
        }
        for run in style.fontRuns ?? [] where run.length > 0 {
            let name = run.fontName == style.fontName ? baseFontName : run.fontName
            for index in max(0, run.location)..<max(max(0, run.location), min(units.count, run.location + run.length)) {
                faces[index] = name
            }
        }
        for run in style.sizeRuns ?? [] where run.length > 0 {
            for index in max(0, run.location)..<max(max(0, run.location), min(units.count, run.location + run.length)) {
                sizes[index] = run.fontSize
            }
        }
        var fonts = [baseFontName]
        var engine: [(color: PaletteColor, fontIndex: Int, fontSize: CGFloat)] = []
        var index = 0
        while index < units.count {
            let name = faces[index]
            if !fonts.contains(name) { fonts.append(name) }
            engine.append((colors[index], fonts.firstIndex(of: name)!, sizes[index]))
            // "\r\n" is one paragraph break, as `paragraphs` reads it.
            index += units[index] == 13 && index + 1 < units.count && units[index + 1] == 10 ? 2 : 1
        }
        engine.append(engine.last ?? (base, 0, style.fontSize))
        var runs: [(length: Int, color: PaletteColor, fontIndex: Int, fontSize: CGFloat)] = []
        for styled in engine {
            if let last = runs.last, last.color == styled.color, last.fontIndex == styled.fontIndex,
               last.fontSize == styled.fontSize {
                runs[runs.count - 1].length += 1
            } else { runs.append((1, styled.color, styled.fontIndex, styled.fontSize)) }
        }
        return (runs, fonts)
    }

    private static func fillColor(_ color: PaletteColor) -> EngineValue {
        Self.color([1, Double(color.red), Double(color.green), Double(color.blue)])
    }

    /// An RGB color: `Values` [alpha, red, green, blue], each 0…1.
    private static func color(_ values: [Double]) -> EngineValue {
        .dictionary([(key: "Type", value: .integer(1)), (key: "Values", value: numbers(values))])
    }

    private static func paragraphProperties(justification: Int, hyphenates: Bool) -> EngineValue {
        .dictionary([
            (key: "Justification", value: .integer(justification)), (key: "FirstLineIndent", value: .number(0)),
            (key: "StartIndent", value: .number(0)), (key: "EndIndent", value: .number(0)),
            (key: "SpaceBefore", value: .number(0)), (key: "SpaceAfter", value: .number(0)),
            (key: "AutoHyphenate", value: .bool(hyphenates)), (key: "HyphenatedWordSize", value: .integer(6)),
            (key: "PreHyphen", value: .integer(2)), (key: "PostHyphen", value: .integer(2)),
            (key: "ConsecutiveHyphens", value: .integer(8)), (key: "Zone", value: .number(36)),
            (key: "WordSpacing", value: numbers([0.8, 1, 1.33])), (key: "LetterSpacing", value: numbers([0, 0, 0])),
            (key: "GlyphSpacing", value: numbers([1, 1, 1])), (key: "AutoLeading", value: .number(1.2)),
            (key: "LeadingType", value: .integer(0)), (key: "Hanging", value: .bool(false)),
            (key: "Burasagari", value: .bool(false)), (key: "KinsokuOrder", value: .integer(0)),
            // The single-line composer breaks lines the way the text tool does.
            (key: "EveryLineComposer", value: .bool(false)),
        ])
    }

    /// `ResourceDict` (and `DocumentResources`, the same): Photoshop's kinsoku and mojikumi sets, the Normal RGB
    /// paragraph and style sheets, the fonts, and its superscript, subscript and small-caps proportions.
    private static func documentResources(fontNames: [String], fontType: Int) -> EngineValue {
        func font(_ name: String, type: Int) -> EngineValue {
            .dictionary([(key: "Name", value: .string(name)), (key: "Script", value: .integer(0)),
                         (key: "FontType", value: .integer(type)), (key: "Synthetic", value: .integer(0))])
        }
        let kinsoku = kinsokuSets.map { set in
            EngineValue.dictionary([(key: "Name", value: .string(set.name)), (key: "NoStart", value: .string(set.noStart)),
                                    (key: "NoEnd", value: .string(set.noEnd)), (key: "Keep", value: .string("\u{2015}\u{2025}")),
                                    (key: "Hanging", value: .string("\u{3001}\u{3002}.,"))])
        }
        let normalStyle: Items = [
            (key: "Font", value: .integer(0)), (key: "FontSize", value: .number(12)),
            (key: "FauxBold", value: .bool(false)), (key: "FauxItalic", value: .bool(false)),
            (key: "AutoLeading", value: .bool(true)), (key: "Leading", value: .number(0)),
            (key: "HorizontalScale", value: .number(1)), (key: "VerticalScale", value: .number(1)),
            (key: "Tracking", value: .integer(0)), (key: "AutoKerning", value: .bool(true)),
            (key: "Kerning", value: .integer(0)), (key: "BaselineShift", value: .number(0)),
            (key: "FontCaps", value: .integer(0)), (key: "FontBaseline", value: .integer(0)),
            (key: "Underline", value: .bool(false)), (key: "Strikethrough", value: .bool(false)),
            (key: "Ligatures", value: .bool(true)), (key: "DLigatures", value: .bool(false)),
            (key: "BaselineDirection", value: .integer(2)), (key: "Tsume", value: .number(0)),
            (key: "StyleRunAlignment", value: .integer(2)), (key: "Language", value: .integer(0)),
            (key: "NoBreak", value: .bool(false)), (key: "FillColor", value: color([1, 0, 0, 0])),
            (key: "StrokeColor", value: color([1, 0, 0, 0])), (key: "FillFlag", value: .bool(true)),
            (key: "StrokeFlag", value: .bool(false)), (key: "FillFirst", value: .bool(true)),
            (key: "YUnderline", value: .integer(1)), (key: "OutlineWidth", value: .number(1)),
            (key: "CharacterDirection", value: .integer(0)), (key: "HindiNumbers", value: .bool(false)),
            (key: "Kashida", value: .integer(1)), (key: "DiacriticPos", value: .integer(2)),
        ]
        return .dictionary([
            (key: "KinsokuSet", value: .array(kinsoku)),
            (key: "MojiKumiSet", value: .array((1...4).map { .dictionary([(key: "InternalName", value: .string("Photoshop6MojiKumiSet\($0)"))]) })),
            (key: "TheNormalStyleSheet", value: .integer(0)),
            (key: "TheNormalParagraphSheet", value: .integer(0)),
            (key: "ParagraphSheetSet", value: .array([.dictionary([
                (key: "Name", value: .string("Normal RGB")), (key: "DefaultStyleSheet", value: .integer(0)),
                (key: "Properties", value: paragraphProperties(justification: 0, hyphenates: true)),
            ])])),
            (key: "StyleSheetSet", value: .array([.dictionary([
                (key: "Name", value: .string("Normal RGB")), (key: "StyleSheetData", value: .dictionary(normalStyle)),
            ])])),
            (key: "FontSet", value: .array(fontNames.map { font($0, type: fontType) } + [font("AdobeInvisFont", type: 0)])),
            (key: "SuperscriptSize", value: .number(0.583)), (key: "SuperscriptPosition", value: .number(0.333)),
            (key: "SubscriptSize", value: .number(0.583)), (key: "SubscriptPosition", value: .number(0.333)),
            (key: "SmallCapSize", value: .number(0.7)),
        ])
    }

    /// Photoshop's Japanese line-breaking rules, the same in every file it writes: characters a line may not start
    /// with, and characters it may not end with.
    private static let kinsokuSets: [(name: String, noStart: String, noEnd: String)] = [
        (name: "PhotoshopKinsokuHard",
         noStart: "\u{3001}\u{3002}\u{FF0C}\u{FF0E}\u{30FB}\u{FF1A}\u{FF1B}\u{FF1F}\u{FF01}\u{30FC}\u{2015}\u{2019}\u{201D}\u{FF09}\u{3015}\u{FF3D}\u{FF5D}\u{3009}\u{300B}\u{300D}\u{300F}\u{3011}\u{30FD}\u{30FE}\u{309D}\u{309E}\u{3005}\u{3041}\u{3043}\u{3045}\u{3047}\u{3049}\u{3063}\u{3083}\u{3085}\u{3087}\u{308E}\u{30A1}\u{30A3}\u{30A5}\u{30A7}\u{30A9}\u{30C3}\u{30E3}\u{30E5}\u{30E7}\u{30EE}\u{30F5}\u{30F6}\u{309B}\u{309C}?!)]},.:;\u{2103}\u{2109}\u{A2}\u{FF05}\u{2030}",
         noEnd: "\u{2018}\u{201C}\u{FF08}\u{3014}\u{FF3B}\u{FF5B}\u{3008}\u{300A}\u{300C}\u{300E}\u{3010}([{\u{FFE5}\u{FF04}\u{A3}\u{FF20}\u{A7}\u{3012}\u{FF03}"),
        (name: "PhotoshopKinsokuSoft",
         noStart: "\u{3001}\u{3002}\u{FF0C}\u{FF0E}\u{30FB}\u{FF1A}\u{FF1B}\u{FF1F}\u{FF01}\u{2019}\u{201D}\u{FF09}\u{3015}\u{FF3D}\u{FF5D}\u{3009}\u{300B}\u{300D}\u{300F}\u{3011}\u{30FD}\u{30FE}\u{309D}\u{309E}\u{3005}",
         noEnd: "\u{2018}\u{201C}\u{FF08}\u{3014}\u{FF3B}\u{FF5B}\u{3008}\u{300A}\u{300C}\u{300E}\u{3010}"),
    ]
}

/// Photoshop `TextIndex` values (which of the document's `Txt2` texts is a type layer's): each layer keeps its own
/// unless another layer already has it, as a duplicate does; the rest count up from the largest one kept.
nonisolated struct PSDTextIndices {
    private var used: Set<Int32> = []
    private var next: Int32

    init(preserved: [Int32]) {
        let largest = preserved.filter { $0 >= 0 }.max() ?? -1
        next = largest < Int32.max ? largest + 1 : 0
    }

    mutating func claim(_ preferred: Int32?) -> Int32 {
        if let preferred, preferred >= 0, used.insert(preferred).inserted { return preferred }
        while used.contains(next) { next = next == Int32.max ? 0 : next + 1 }
        used.insert(next)
        return next
    }
}
