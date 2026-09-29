import AppKit
import Foundation
import Testing
@testable import Compositor

/// Live text written as editable Photoshop type layers (Task 4.7): EngineData formatted as Photoshop and psd-tools
/// write it, `TySh` placed where the text tool drew the text, and type data the file already had written back.
@MainActor
@Suite(.serialized)
struct PSDTextWriterTests {
    private let canvas = CGSize(width: 600, height: 400)

    // MARK: Fixtures

    private func style(_ content: String, font: String = "Helvetica", size: CGFloat = 40, alignment: TextAlignment = .left,
                       leading: CGFloat = 0, tracking: CGFloat = 0, box: CGSize? = nil,
                       horizontalScale: CGFloat? = nil) -> LayerTextStyle {
        var style = LayerTextStyle()
        style.content = content
        style.fontName = font
        style.fontSize = size
        style.red = 0.2; style.green = 0.4; style.blue = 0.6
        style.alignment = alignment
        style.leading = leading
        style.tracking = tracking
        style.boxSize = box
        style.horizontalScale = horizontalScale
        return style
    }

    /// A live text layer drawn by the text tool, its raster placed at `origin` and scaled by `scale`.
    private func textLayer(_ style: LayerTextStyle, at origin: CGPoint, scale: CGFloat = 1, name: String = "Text") throws -> ImageLayer {
        let image = try EditorSession.textImage(style)
        return ImageLayer(id: UUID(), asset: ImportedImage(image: image, thumbnail: image, name: name), name: name,
                          isVisible: true,
                          transform: LayerTransform(origin: origin, size: CGSize(width: CGFloat(image.width) * scale,
                                                                                 height: CGFloat(image.height) * scale)),
                          text: LayerText(style: style, image: image))
    }

    private func session(_ layers: [ImageLayer]) -> EditorSession {
        let session = EditorSession()
        session.document = CanvasDocument(width: Int(canvas.width), height: Int(canvas.height), layers: layers)
        session.activeLayerID = layers.last?.id
        return session
    }

    private func written(_ session: EditorSession, _ options: PSDWriteOptions = .init()) throws -> (document: PSDDocument, data: Data) {
        let data = try PSDWriter.data(for: try #require(session.psdWriteRequest()), options: options).data
        return (try PSDReader.read(data), data)
    }

    private func record(_ document: PSDDocument, _ name: String) throws -> PSDRecord {
        try #require(document.layers.first { $0.name == name })
    }

    private func raster(width: Int, height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 2, y: 2, width: width - 4, height: height - 4))
        return try #require(context.makeImage())
    }

    /// A Photoshop file of type layers (name, `TySh`, raster bounds), opened as the app opens one, with a `Txt2`
    /// document block beside them.
    private func opened(_ layers: [(name: String, tySh: Data, bounds: CGRect)]) throws -> EditorSession {
        let records = try layers.map { layer in
            var record = PSDRecord(id: UUID(), name: layer.name)
            record.bounds = layer.bounds
            record.image = try raster(width: Int(layer.bounds.width), height: Int(layer.bounds.height))
            record.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "TySh", data: layer.tySh)])
            return record
        }
        let document = PSDDocument(width: Int(canvas.width), height: Int(canvas.height), resolution: 72, layers: records,
                                   extras: PSDDocumentExtras(globalBlocks: [txt2]))
        let data = try PSDFixture.data(document, composite: try raster(width: Int(canvas.width), height: Int(canvas.height)))
        let session = EditorSession()
        try session.insertPhotoshop(try PSDDocumentBuilder.makeImport(try PSDReader.read(data)), named: "Fixture")
        #expect(session.document?.layers.allSatisfy { $0.liveText != nil } == true)
        return session
    }

    private let txt2 = PSDTaggedBlock(key: "Txt2", data: Data("\n\n/DocumentResources << >>".utf8))

    private func storedTextIndex(_ tySh: Data) throws -> Int32 { try #require(PSDTypeReader.textIndex(tySh)) }

    /// The EngineData inside a `TySh` payload, parsed.
    private func engine(_ tySh: Data) throws -> EngineValue {
        var offset = 2 + 6 * 8 + 2
        let descriptor = try PSDDescriptorReader.readBlock(tySh, at: &offset)
        guard case .rawData(let bytes)? = descriptor["EngineData"] else { throw PSDTypeError.malformed }
        return try EngineDataParser.parse(bytes)
    }

    private func expectTransform(_ actual: [Double], _ expected: [Double], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.count == 6, sourceLocation: sourceLocation)
        for (a, e) in zip(actual, expected) {
            #expect(abs(a - e) < 1e-6, "\(actual) ≠ \(expected)", sourceLocation: sourceLocation)
        }
    }

    // MARK: EngineData formatting

    @Test func numbersAreWrittenAsPhotoshopAndPsdToolsWriteThem() {
        let cases: [(Double, String)] = [(0, "0.0"), (-0.0, "0.0"), (1, "1.0"), (72, "72.0"), (0.5, ".5"), (-0.25, "-.25"),
                                         (1.2, "1.2"), (0.1098, ".1098"), (12.123456789, "12.12345679"), (-3, "-3.0"),
                                         (43.2, "43.2"), (0.583, ".583"), (100_000, "100000.0"), (1e-9, ".0")]
        for (value, text) in cases {
            #expect(PSDEngineDataWriter.number(value) == text, "\(value)")
        }
    }

    /// Bytes psd-tools 1.19 writes for the same value (`EngineData.write`), which is how Photoshop lays it out.
    @Test func engineDataIsLaidOutAsPhotoshopAndPsdToolsWriteIt() throws {
        let value: EngineValue = .dictionary([
            (key: "Editor", value: .dictionary([(key: "Text", value: .string("A(b)\\c"))])),
            (key: "Runs", value: .array([.dictionary([(key: "Length", value: .integer(3))]),
                                         .dictionary([(key: "Length", value: .integer(1))])])),
            (key: "Values", value: .array([.number(1), .number(0.5), .integer(2)])),
            (key: "Empty", value: .array([])),
            (key: "Nested", value: .array([.array([.number(0), .number(1)])])),
            (key: "Flag", value: .bool(true)),
            (key: "Neg", value: .number(-0.25)),
        ])
        var expected = Data("\n\n<<\n\t/Editor\n\t<<\n\t\t/Text (".utf8)
        expected.append(contentsOf: [0xFE, 0xFF, 0x00, 0x41, 0x00, 0x5C, 0x28, 0x00, 0x62, 0x00, 0x5C, 0x29, 0x00, 0x5C, 0x5C, 0x00, 0x63])
        expected.append(contentsOf: Array((")\n\t>>\n\t/Runs [\n\t<<\n\t\t/Length 3\n\t>>\n\t<<\n\t\t/Length 1\n\t>>\n\t]\n"
            + "\t/Values [ 1.0 .5 2 ]\n\t/Empty [ ]\n\t/Nested [ [ 0.0 1.0 ] ]\n\t/Flag true\n\t/Neg -.25\n>>").utf8))
        let data = PSDEngineDataWriter.data(value)
        #expect(data == expected)
        #expect(try EngineDataParser.parse(data) == value)
    }

    /// Letters colored on their own are written as style runs in their colors; a "\r\n" is one "\r" to Photoshop, so
    /// the runs still add up to the text.
    @Test func lettersColoredOnTheirOwnWriteAStyleRunPerColor() throws {
        var colored = style("Hi\r\nyo")
        colored.colorRuns = [LayerTextColorRun(location: 1, length: 1, red: 1, green: 0, blue: 0)]
        #expect(colored.isValid)
        let data = PSDEngineDataWriter.data(PSDTextWriter.engineData(colored, fontName: "Helvetica", fontType: 1))
        let engine = try EngineDataParser.parse(data)
        #expect(engine[path: "EngineDict.Editor.Text"]?.string == "Hi\ryo\r")
        #expect(engine[path: "EngineDict.StyleRun.RunLengthArray"] == .array([.integer(1), .integer(1), .integer(4)]))
        func fill(_ index: Int) -> EngineValue? {
            engine[path: "EngineDict.StyleRun.RunArray.\(index).StyleSheet.StyleSheetData.FillColor.Values"]
        }
        #expect(fill(1) == .array([.number(1), .number(1), .number(0), .number(0)]))
        #expect(fill(0) == fill(2) && fill(0) != fill(1))
        let own = try #require(engine[path: "EngineDict.StyleRun.RunArray.0.StyleSheet.StyleSheetData"])
        #expect(own["FontSize"] == .number(40))
    }

    @Test func lettersWithDifferentFacesKeepTheirFacesAndColorsInPhotoshop() throws {
        var mixed = style("Hi\r\nyo")
        mixed.fontRuns = [LayerTextFontRun(location: 1, length: 1, fontName: "Courier")]
        mixed.colorRuns = [LayerTextColorRun(location: 1, length: 1, red: 1, green: 0, blue: 0)]
        let data = PSDEngineDataWriter.data(PSDTextWriter.engineData(mixed, fontName: "Helvetica", fontType: 1))
        let engine = try EngineDataParser.parse(data)
        #expect(engine[path: "EngineDict.Editor.Text"]?.string == "Hi\ryo\r")
        #expect(engine[path: "EngineDict.StyleRun.RunLengthArray"] == .array([.integer(1), .integer(1), .integer(4)]))
        #expect(engine[path: "EngineDict.StyleRun.RunArray.0.StyleSheet.StyleSheetData.Font"] == .integer(0))
        #expect(engine[path: "EngineDict.StyleRun.RunArray.1.StyleSheet.StyleSheetData.Font"] == .integer(1))
        #expect(engine[path: "EngineDict.StyleRun.RunArray.2.StyleSheet.StyleSheetData.Font"] == .integer(0))
        #expect(engine[path: "ResourceDict.FontSet.0.Name"]?.string == "Helvetica")
        #expect(engine[path: "ResourceDict.FontSet.1.Name"]?.string == "Courier")
        #expect(engine[path: "ResourceDict.FontSet.2.Name"]?.string == "AdobeInvisFont")
    }

    @Test func aTwoParagraphCenteredStyleWritesPhotoshopsEngineData() throws {
        var centered = style("Hello\nWorld", size: 36, alignment: .center)
        centered.red = 1; centered.green = 0.5; centered.blue = 0
        let data = PSDEngineDataWriter.data(PSDTextWriter.engineData(centered, fontName: "Helvetica", fontType: 1))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("\n\n<<\n\t/EngineDict\n\t<<\n\t\t/Editor\n\t\t<<\n\t\t\t/Text ("))
        #expect(text.contains("\n\t\t/ParagraphRun\n\t\t<<\n\t\t\t/DefaultRunData\n\t\t\t<<\n\t\t\t\t/ParagraphSheet\n\t\t\t\t<<\n\t\t\t\t\t/DefaultStyleSheet 0\n"))
        #expect(text.contains("\n\t\t\t/RunLengthArray [ 6 6 ]\n\t\t\t/IsJoinable 1\n"))
        #expect(text.contains("\n\t\t\t\t\t\t\t/Values [ 1.0 1.0 .5 0.0 ]\n"))
        #expect(text.hasSuffix("\n\t\t/SmallCapSize .7\n\t>>\n>>"))
        let engine = try EngineDataParser.parse(data)
        // The same bytes again from what they parse to: the layout is the serializer's own.
        #expect(PSDEngineDataWriter.data(engine) == data)

        #expect(engine[path: "EngineDict.Editor.Text"]?.string == "Hello\rWorld\r")
        #expect(engine[path: "EngineDict.ParagraphRun.RunLengthArray"] == .array([.integer(6), .integer(6)]))
        for index in 0..<2 {
            let properties = engine[path: "EngineDict.ParagraphRun.RunArray.\(index).ParagraphSheet.Properties"]
            #expect(properties?["Justification"] == .integer(2))
            #expect(properties?["AutoLeading"] == .number(1.2))
        }
        #expect(engine[path: "EngineDict.StyleRun.RunLengthArray"] == .array([.integer(12)]))
        let run = try #require(engine[path: "EngineDict.StyleRun.RunArray.0.StyleSheet.StyleSheetData"])
        #expect(run["Font"] == .integer(0) && run["FontSize"] == .number(36))
        #expect(run["AutoLeading"] == .bool(true) && run["Leading"]?.double.map { abs($0 - 43.2) < 1e-9 } == true)
        #expect(run["Tracking"] == .integer(0) && run["Ligatures"] == .bool(true))
        #expect(run[path: "FillColor.Type"] == .integer(1))
        #expect(run[path: "FillColor.Values"] == .array([.number(1), .number(1), .number(0.5), .number(0)]))
        #expect(engine[path: "EngineDict.AntiAlias"] == .integer(3))
        #expect(engine[path: "EngineDict.UseFractionalGlyphWidths"] == .bool(true))
        #expect(engine[path: "EngineDict.GridInfo.GridIsOn"] == .bool(false))
        let shape = try #require(engine[path: "EngineDict.Rendered.Shapes.Children.0"])
        #expect(shape["ShapeType"] == .integer(0) && shape[path: "Cookie.Photoshop.ShapeType"] == .integer(0))
        #expect(shape[path: "Cookie.Photoshop.PointBase"] == .array([.number(0), .number(0)]))
        #expect(shape[path: "Cookie.Photoshop.Base.TransformPoint0"] == .array([.number(1), .number(0)]))
        #expect(shape[path: "Cookie.Photoshop.Base.TransformPoint1"] == .array([.number(0), .number(1)]))
        #expect(shape[path: "Cookie.Photoshop.Base.TransformPoint2"] == .array([.number(0), .number(0)]))

        let resources = try #require(engine["ResourceDict"])
        #expect(engine["DocumentResources"] == resources)
        #expect(resources[path: "FontSet"]?.array?.map { $0["Name"]?.string } == ["Helvetica", "AdobeInvisFont"])
        #expect(resources[path: "FontSet"]?.array?.map { $0["FontType"] } == [.integer(1), .integer(0)])
        #expect(resources[path: "KinsokuSet"]?.array?.map { $0["Name"]?.string } == ["PhotoshopKinsokuHard", "PhotoshopKinsokuSoft"])
        #expect(resources[path: "KinsokuSet.0.NoStart"]?.string?.utf16.count == 65)
        #expect(resources[path: "KinsokuSet.1.NoEnd"]?.string?.utf16.count == 11)
        #expect(resources[path: "MojiKumiSet"]?.array?.map { $0["InternalName"]?.string }
                    == (1...4).map { "Photoshop6MojiKumiSet\($0)" })
        #expect(resources[path: "ParagraphSheetSet.0.Name"]?.string == "Normal RGB")
        #expect(resources[path: "StyleSheetSet.0.Name"]?.string == "Normal RGB")
        #expect(resources[path: "StyleSheetSet.0.StyleSheetData.Font"] == .integer(0))
        #expect(resources["SuperscriptSize"] == .number(0.583) && resources["SmallCapSize"] == .number(0.7))

        // Photoshop's own reading of it.
        let block = PSDTextWriter.typeToolBlock(centered, metrics: PSDTextMetrics.measure(centered),
                                                transform: .identity, textIndex: 0, fontName: "Helvetica")
        let type = try PSDTypeReader.parse(block)
        #expect(type.paragraphRuns.map(\.justification) == [2, 2])
        #expect(PSDTypeReader.content(type.text) == "Hello\nWorld")
    }

    @Test func paragraphTextNamesItsBoxInTheEngineData() throws {
        let boxed = style("Wrapped", box: CGSize(width: 300, height: 120), horizontalScale: 2)
        let engine = try EngineDataParser.parse(PSDEngineDataWriter.data(
            PSDTextWriter.engineData(boxed, fontName: "Helvetica", fontType: 1)))
        let shape = try #require(engine[path: "EngineDict.Rendered.Shapes.Children.0"])
        #expect(shape["ShapeType"] == .integer(1) && shape[path: "Cookie.Photoshop.ShapeType"] == .integer(1))
        // Text space is the box less its padding, narrowed by the horizontal scale the transform carries.
        #expect(shape[path: "Cookie.Photoshop.BoxBounds"] == .array([.number(0), .number(0), .number(138), .number(96)]))
        #expect(shape[path: "Cookie.Photoshop.PointBase"] == nil)
    }

    // MARK: Placement

    @Test func newPointTextIsPlacedByItsFirstBaselineForIdentityAndScale() throws {
        let plain = style("Hi there", tracking: 2)
        let metrics = PSDTextMetrics.measure(plain)
        let identity = try textLayer(plain, at: CGPoint(x: 100, y: 50), name: "Identity")
        let doubled = try textLayer(plain, at: CGPoint(x: 20, y: 200), scale: 2, name: "Doubled")
        let wide = try textLayer(style("Wide", horizontalScale: 1.5), at: CGPoint(x: 300, y: 40), name: "Wide")
        let wideMetrics = PSDTextMetrics.measure(style("Wide", horizontalScale: 1.5))
        let (document, _) = try written(session([identity, doubled, wide]))

        let first = try record(document, "Identity")
        #expect(first.kind == .text)
        #expect(first.extras?.blocks.map(\.key) == ["TySh", "luni", "lyid", "clbl", "infx", "knko", "lspf", "lclr", "fxrp"])
        let type = try #require(first.typeLayer)
        expectTransform(type.transform, [1, 0, 0, 1, 100 + metrics.anchor.x, 50 + metrics.anchor.y])
        #expect(!type.isParagraphText && type.antiAlias == "AnSm" && type.orientation == "Hrzn" && type.warpStyle == "warpNone")
        #expect(type.styleRuns.map(\.fontName) == ["Helvetica"] && type.styleRuns.map(\.fontSize) == [40])
        #expect(type.styleRuns.map(\.tracking) == [50])
        let bounds = try #require(type.bounds)
        #expect(bounds.minX == 0 && abs(bounds.width - metrics.lineWidth) < 1e-6)
        #expect(abs(bounds.minY + metrics.ascent) < 1e-6 && abs(bounds.maxY - metrics.descent) < 1e-6)

        let scaled = try #require(try record(document, "Doubled").typeLayer)
        expectTransform(scaled.transform, [2, 0, 0, 2, 20 + 2 * metrics.anchor.x, 200 + 2 * metrics.anchor.y])
        #expect(scaled.styleRuns.map(\.fontSize) == [40])

        let stretched = try #require(try record(document, "Wide").typeLayer)
        expectTransform(stretched.transform, [1.5, 0, 0, 1, 300 + wideMetrics.anchor.x, 40 + wideMetrics.anchor.y])
    }

    @Test func centeredPointTextSpansItsWidestLineAroundTheAnchor() throws {
        let centered = style("A\nmuch longer line", alignment: .center, leading: 60)
        let metrics = PSDTextMetrics.measure(centered)
        let (document, _) = try written(session([try textLayer(centered, at: CGPoint(x: 10, y: 10))]))
        let bounds = try #require(try record(document, "Text").typeLayer?.bounds)
        #expect(metrics.lineCount == 2)
        #expect(abs(bounds.minX + metrics.lineWidth / 2) < 1e-6 && abs(bounds.maxX - metrics.lineWidth / 2) < 1e-6)
        #expect(abs(bounds.maxY - (metrics.descent + 60)) < 1e-6)
    }

    @Test func paragraphTextIsPlacedByItsBoxTopLeftWithBoxBounds() throws {
        let boxed = style("A paragraph of text that wraps inside its box", alignment: .right,
                          box: CGSize(width: 300, height: 150))
        let (document, _) = try written(session([try textLayer(boxed, at: CGPoint(x: 40, y: 30))]))
        let type = try #require(try record(document, "Text").typeLayer)
        #expect(type.isParagraphText)
        #expect(type.boxBounds == CGRect(x: 0, y: 0, width: 276, height: 126))
        #expect(type.bounds == CGRect(x: 0, y: 0, width: 276, height: 126))
        expectTransform(type.transform, [1, 0, 0, 1, 52, 42])
        #expect(type.paragraphRuns.map(\.justification) == [1])
    }

    // MARK: Round trips

    @Test func newTextReimportsAsTheSameEditableTextAtTheSamePlace() throws {
        let point = style("Hello\nWorld", alignment: .center, tracking: 5)
        let paragraph = style("Text that wraps in a box", alignment: .right, leading: 50, box: CGSize(width: 260, height: 140))
        let layers = [try textLayer(point, at: CGPoint(x: 80, y: 60), name: "Point"),
                      try textLayer(paragraph, at: CGPoint(x: 300, y: 200), name: "Paragraph")]
        let (_, data) = try written(session(layers))
        let reopened = EditorSession()
        try reopened.insertPhotoshop(try PSDDocumentBuilder.makeImport(try PSDReader.read(data)), named: "Written")
        for (original, style) in zip(layers, [point, paragraph]) {
            let layer = try #require(reopened.document?.layers.first { $0.name == original.name })
            #expect(layer.liveText?.style == style)
            // Where Photoshop's origin was is where the text tool anchors the text.
            let metrics = PSDTextMetrics.measure(style)
            let expected = CGPoint(x: original.transform.origin.x + metrics.anchor.x, y: original.transform.origin.y + metrics.anchor.y)
            let anchor = layer.transform.documentPoint(ofUnit: try #require(layer.psdExtras?.importedTextAnchor))
            #expect(abs(anchor.x - expected.x) < 1e-6 && abs(anchor.y - expected.y) < 1e-6)
        }
    }

    @Test func untouchedImportedTextKeepsItsTypeDataByteForByte() throws {
        let tySh = try PSDFixture.typeToolBlock(PSDFixture.typeToolBlock(
            text: "Hello", font: "Helvetica", fontSize: 24, color: (1, 0.5, 0.25), justification: 2,
            transform: [1, 0, 0, 1, 160, 90]), textIndex: 4)
        let session = try opened([("Title", tySh, CGRect(x: 100, y: 60, width: 120, height: 40))])
        let (document, _) = try written(session)
        #expect(try record(document, "Title").extras?.block("TySh") == tySh)
        #expect(document.extras?.globalBlocks.contains(txt2) == true)
    }

    @Test func movedImportedTextKeepsItsTypeDataAtItsNewPlace() throws {
        let tySh = PSDFixture.typeToolBlock(text: "Hello", font: "Helvetica", fontSize: 24, justification: 2,
                                            transform: [1, 0, 0, 1, 160, 90],
                                            runs: [PSDFixture.TextRun(length: 3, font: "Helvetica", fontSize: 24),
                                                   PSDFixture.TextRun(length: 3, font: "Helvetica-Bold", fontSize: 30)])
        let session = try opened([("Title", tySh, CGRect(x: 100, y: 60, width: 120, height: 40))])
        let id = try #require(session.document?.layers.first?.id)
        session.translateLayers([id], by: CGPoint(x: 30, y: -10))
        let (document, _) = try written(session)
        let moved = try #require(try record(document, "Title").extras?.block("TySh"))
        expectTransform(try PSDTypeReader.parse(moved).transform, [1, 0, 0, 1, 190, 80])
        // Everything but the transform is Photoshop's, both style runs included.
        #expect(moved.prefix(2) == tySh.prefix(2) && moved.dropFirst(50) == tySh.dropFirst(50))
        #expect(document.extras?.globalBlocks.contains { $0.key == "Txt2" } == false)
    }

    /// Image Size resamples Photoshop's pixels and scales the text with them; the text is still what import made of
    /// it, so Photoshop's type data is written back, every style run kept, with only its transform scaled.
    @Test func imageSizeKeepsPhotoshopsTypeDataAndScalesItsTransform() async throws {
        let tySh = try PSDFixture.typeToolBlock(PSDFixture.typeToolBlock(
            text: "Hello", font: "Helvetica", fontSize: 24, justification: 2, transform: [1, 0, 0, 1, 160, 90],
            runs: [PSDFixture.TextRun(length: 3, font: "Helvetica", fontSize: 24),
                   PSDFixture.TextRun(length: 3, font: "Helvetica-Bold", fontSize: 30)]), textIndex: 4)
        let session = try opened([("Title", tySh, CGRect(x: 100, y: 60, width: 120, height: 40))])
        let resized = try await ImageResizer.shared.resize(try #require(session.projectSnapshot()),
                                                           to: ImageSizeOptions(width: 300, height: 200, resolution: 72))
        session.applyImageSize(resized)
        let layer = try #require(session.document?.layers.first)
        #expect(layer.psdExtras?.importedTextAnchor != nil && layer.liveText?.style.fontSize == 12)

        let (document, _) = try written(session)
        let scaled = try #require(try record(document, "Title").extras?.block("TySh"))
        expectTransform(try PSDTypeReader.parse(scaled).transform, [0.5, 0, 0, 0.5, 80, 45])
        #expect(try PSDTypeReader.parse(scaled).styleRuns.map(\.fontSize) == [24, 30])
        #expect(scaled.prefix(2) == tySh.prefix(2) && scaled.dropFirst(50) == tySh.dropFirst(50))
    }

    @Test func editedImportedTextIsWrittenFromItsStyleAtPhotoshopsAnchor() throws {
        let tySh = try PSDFixture.typeToolBlock(PSDFixture.typeToolBlock(
            text: "Hello", font: "Helvetica", fontSize: 24, justification: 2, transform: [1, 0, 0, 1, 160, 90]), textIndex: 4)
        let session = try opened([("Title", tySh, CGRect(x: 100, y: 60, width: 120, height: 40))])
        let id = try #require(session.document?.layers.first?.id)
        session.selectLayer(id)
        session.editActiveText()
        var draft = try #require(session.textDraft)
        draft.style.content = "Changed"
        #expect(session.applyText(draft))
        let (document, _) = try written(session)
        let block = try #require(try record(document, "Title").extras?.block("TySh"))
        #expect(try engine(block)[path: "EngineDict.Editor.Text"]?.string == "Changed\r")
        #expect(try storedTextIndex(block) == 4)
        let type = try PSDTypeReader.parse(block)
        expectTransform(type.transform, [1, 0, 0, 1, 160, 90])
        #expect(type.styleRuns.map(\.fontSize) == [24] && type.paragraphRuns.map(\.justification) == [2])
        #expect(document.extras?.globalBlocks.contains { $0.key == "Txt2" } == false)
    }

    /// Recoloring mixed-run Photoshop text and back gives its imported style again, but the pixels are the text tool's
    /// single-style render now, so the type data is written from that style: Photoshop's other runs are gone, as they
    /// are in Compositor.
    @Test func importedTextEditedAndRevertedIsWrittenFromItsStyle() throws {
        let tySh = try PSDFixture.typeToolBlock(PSDFixture.typeToolBlock(
            text: "Hello", font: "Helvetica", fontSize: 24, color: (1, 0.5, 0.25), justification: 2,
            transform: [1, 0, 0, 1, 160, 90],
            runs: [PSDFixture.TextRun(length: 3, font: "Helvetica", fontSize: 24),
                   PSDFixture.TextRun(length: 3, font: "Helvetica-Bold", fontSize: 30)]), textIndex: 4)
        let session = try opened([("Title", tySh, CGRect(x: 100, y: 60, width: 120, height: 40))])
        let id = try #require(session.document?.layers.first?.id)
        let imported = try #require(session.document?.layers.first?.liveText?.style)
        #expect(session.recolorText(id, to: PaletteColor(red: 1, green: 0, blue: 0)))
        #expect(session.recolorText(id, to: PaletteColor(red: imported.red, green: imported.green, blue: imported.blue)))
        let layer = try #require(session.document?.layers.first)
        #expect(layer.liveText?.style == layer.psdExtras?.importedText && layer.psdExtras?.importedTextAnchor == nil)

        let (document, _) = try written(session)
        let block = try #require(try record(document, "Title").extras?.block("TySh"))
        #expect(block != tySh)
        let type = try PSDTypeReader.parse(block)
        #expect(type.styleRuns.map(\.fontName) == [imported.fontName] && type.styleRuns.map(\.fontSize) == [24])
        #expect(try engine(block)[path: "EngineDict.Editor.Text"]?.string == "Hello\r")
        #expect(try storedTextIndex(block) == 4)
        expectTransform(type.transform, [1, 0, 0, 1, 160, 90])
        #expect(document.extras?.globalBlocks.contains { $0.key == "Txt2" } == false)
    }

    @Test func rasterizedTextIsWrittenAsPlainPixels() throws {
        let tySh = PSDFixture.typeToolBlock(text: "Hello", font: "Helvetica", transform: [1, 0, 0, 1, 160, 90])
        let session = try opened([("Title", tySh, CGRect(x: 100, y: 60, width: 120, height: 40))])
        try session.rasterizeLayer(try #require(session.document?.layers.first?.id))
        let (document, _) = try written(session)
        let layer = try record(document, "Title")
        #expect(layer.kind == .raster && layer.extras?.block("TySh") == nil)
        #expect(document.extras?.globalBlocks.contains { $0.key == "Txt2" } == false)
    }

    /// Type whose clip the writer applies to its pixels (its base isn't directly below it) is written as those pixels,
    /// without `TySh`: Photoshop would lay the text out again, unclipped, on its first edit.
    @Test func textWithABakedClipIsWrittenAsPixels() throws {
        let tySh = try PSDFixture.typeToolBlock(PSDFixture.typeToolBlock(text: "Hello", font: "Helvetica",
                                                                         transform: [1, 0, 0, 1, 160, 90]), textIndex: 0)
        let session = try opened([("Title", tySh, CGRect(x: 100, y: 60, width: 120, height: 40))])
        let base = ImageLayer(id: UUID(), asset: ImportedImage(image: try raster(width: 600, height: 400),
                                                               thumbnail: try raster(width: 4, height: 4), name: "Base"),
                              name: "Base", isVisible: true, transform: LayerTransform(origin: .zero, size: canvas))
        let spacer = ImageLayer(id: UUID(), asset: ImportedImage(image: try raster(width: 4, height: 4),
                                                                 thumbnail: try raster(width: 4, height: 4), name: "Spacer"),
                                name: "Spacer", isVisible: true,
                                transform: LayerTransform(origin: .zero, size: CGSize(width: 4, height: 4)))
        session.document?.layers.insert(contentsOf: [base, spacer], at: 0)
        let index = try #require(session.document?.layers.firstIndex { $0.name == "Title" })
        session.document?.layers[index].maskSourceID = base.id
        let (document, _) = try written(session)
        #expect(try record(document, "Title").extras?.block("TySh") == nil)
        #expect(try record(document, "Title").kind == .raster)
        #expect(document.extras?.globalBlocks.contains { $0.key == "Txt2" } == false)
    }

    // MARK: Text the file holds elsewhere

    private let secret = "Draft: Acme pricing $48k"

    /// Two type layers ("Secret", "Public") in a file whose other copies of their text are Photoshop's: `Txt2`, the XMP
    /// packet's `photoshop:TextLayers` and the old-style thumbnail (1033, here holding the text as bytes).
    private func openedWithTextElsewhere() throws -> EditorSession {
        let secretTySh = try PSDFixture.typeToolBlock(PSDFixture.typeToolBlock(text: secret, font: "Helvetica",
                                                                               transform: [1, 0, 0, 1, 40, 60]), textIndex: 0)
        let publicTySh = try PSDFixture.typeToolBlock(PSDFixture.typeToolBlock(text: "Hello", font: "Helvetica",
                                                                               transform: [1, 0, 0, 1, 40, 160]), textIndex: 1)
        let records = try [("Secret", secretTySh, CGRect(x: 30, y: 30, width: 200, height: 40)),
                           ("Public", publicTySh, CGRect(x: 30, y: 130, width: 80, height: 40))].map { layer in
            var record = PSDRecord(id: UUID(), name: layer.0)
            record.bounds = layer.2
            record.image = try raster(width: Int(layer.2.width), height: Int(layer.2.height))
            record.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "TySh", data: layer.1)])
            return record
        }
        let utf16 = Data([0xFE, 0xFF]) + Data(secret.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
        var engine = Data("\n\n/DocumentObjects << /TextObjects [ << /Text (".utf8)
        engine.append(utf16)
        engine.append(Data(") >> << /Text (Hello) >> ] >>".utf8))
        let packet: [String] = [
            "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\">",
            "<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\" ",
            "xmlns:photoshop=\"http://ns.adobe.com/photoshop/1.0/\" photoshop:ColorMode=\"3\">\n",
            "<photoshop:TextLayers>\n<rdf:Bag>\n",
            "<rdf:li photoshop:LayerName=\"Secret\" photoshop:LayerText=\"" + secret + "\"/>\n",
            "<rdf:li photoshop:LayerName=\"Public\" photoshop:LayerText=\"Hello\"/>\n</rdf:Bag>\n</photoshop:TextLayers>\n",
            "</rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>",
        ]
        let xmp = Data(packet.joined().utf8)
        let extras = PSDDocumentExtras(resources: [PSDImageResource(id: 1060, name: "", data: xmp),
                                                   PSDImageResource(id: 1033, name: "", data: Data(secret.utf8))],
                                       globalBlocks: [PSDTaggedBlock(key: "Txt2", data: engine)])
        let document = PSDDocument(width: Int(canvas.width), height: Int(canvas.height), resolution: 72, layers: records,
                                   extras: extras)
        let data = try PSDFixture.data(document, composite: try raster(width: Int(canvas.width), height: Int(canvas.height)))
        let session = EditorSession()
        try session.insertPhotoshop(try PSDDocumentBuilder.makeImport(try PSDReader.read(data)), named: "Fixture")
        return session
    }

    /// Whether `data` holds `text` in any encoding the file's text is stored in.
    private func holds(_ data: Data, _ text: String) -> Bool {
        let utf16BE = Data(text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
        let utf16LE = Data(text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        return [Data(text.utf8), utf16BE, utf16LE].contains { data.range(of: $0) != nil }
    }

    /// Deleting a type layer takes its text out of the whole file: its `TySh` goes with the layer, and the copies
    /// Photoshop keeps elsewhere (`Txt2`, XMP `photoshop:TextLayers`, the old thumbnail) are left out.
    @Test func aDeletedTypeLayersTextIsNowhereInTheFile() throws {
        let untouched = try openedWithTextElsewhere()
        let (kept, keptData) = try written(untouched)
        #expect(kept.extras?.globalBlocks.contains { $0.key == "Txt2" } == true)
        #expect(String(decoding: try #require(kept.extras?.resources.first { $0.id == 1060 }?.data), as: UTF8.self)
            .contains("<photoshop:TextLayers>"))
        #expect(holds(keptData, secret))

        let session = try openedWithTextElsewhere()
        session.document?.layers.removeAll { $0.name == "Secret" }
        let (document, data) = try written(session)
        #expect(document.layers.map(\.name) == ["Public"])
        #expect(!holds(data, secret))
        #expect(document.extras?.globalBlocks.contains { $0.key == "Txt2" } == false)
        #expect(document.extras?.resources.contains { $0.id == 1033 } == false)
        let xmp = String(decoding: try #require(document.extras?.resources.first { $0.id == 1060 }?.data), as: UTF8.self)
        #expect(!xmp.contains("TextLayers") && xmp.contains("photoshop:ColorMode=\"3\"") && xmp.hasSuffix("<?xpacket end=\"w\"?>"))
    }

    /// Edited or renamed type leaves Photoshop's own copies of the old text and name out too.
    @Test func editedOrRenamedTypeLeavesTheOldTextOut() throws {
        let edited = try openedWithTextElsewhere()
        let id = try #require(edited.document?.layers.first { $0.name == "Secret" }?.id)
        edited.selectLayer(id)
        edited.editActiveText()
        var draft = try #require(edited.textDraft)
        draft.style.content = "Public price"
        #expect(edited.applyText(draft))
        #expect(!holds(try written(edited).data, secret))

        let renamed = try openedWithTextElsewhere()
        let index = try #require(renamed.document?.layers.firstIndex { $0.name == "Secret" })
        renamed.document?.layers[index].name = "Headline"
        let xmp = try #require(try written(renamed).document.extras?.resources.first { $0.id == 1060 }?.data)
        #expect(!String(decoding: xmp, as: UTF8.self).contains("TextLayers"))
    }

    @Test func duplicatedAndNewTextTakeTheNextTextIndices() throws {
        let first = try PSDFixture.typeToolBlock(PSDFixture.typeToolBlock(text: "One", font: "Helvetica",
                                                                          transform: [1, 0, 0, 1, 40, 60]), textIndex: 0)
        let second = try PSDFixture.typeToolBlock(PSDFixture.typeToolBlock(text: "Two", font: "Helvetica",
                                                                           transform: [1, 0, 0, 1, 40, 160]), textIndex: 1)
        let session = try opened([("First", first, CGRect(x: 30, y: 30, width: 80, height: 40)),
                                  ("Second", second, CGRect(x: 30, y: 130, width: 80, height: 40))])
        session.selectLayer(try #require(session.document?.layers.first { $0.name == "Second" }?.id))
        session.duplicateActiveLayer()
        session.document?.layers.append(try textLayer(style("New"), at: CGPoint(x: 300, y: 300), name: "New"))
        let (document, _) = try written(session)
        let copy = try #require(try record(document, "Second copy").extras?.block("TySh"))
        #expect(try storedTextIndex(try #require(try record(document, "First").extras?.block("TySh"))) == 0)
        #expect(try record(document, "Second").extras?.block("TySh") == second)
        #expect(try storedTextIndex(copy) == 2)
        #expect(try PSDFixture.typeToolBlock(copy, textIndex: 1) == second)
        #expect(try storedTextIndex(try #require(try record(document, "New").extras?.block("TySh"))) == 3)
        #expect(document.extras?.globalBlocks.contains { $0.key == "Txt2" } == false)
    }

    @Test func textAsPixelsLeavesOutEveryTypeLayer() throws {
        let tySh = PSDFixture.typeToolBlock(text: "Hello", font: "Helvetica", transform: [1, 0, 0, 1, 160, 90])
        let session = try opened([("Title", tySh, CGRect(x: 100, y: 60, width: 120, height: 40))])
        session.document?.layers.append(try textLayer(style("New"), at: CGPoint(x: 300, y: 300), name: "New"))
        var options = PSDWriteOptions()
        options.textAsPixels = true
        let (document, _) = try written(session, options)
        #expect(document.layers.map(\.kind) == [.raster, .raster])
        #expect(document.layers.allSatisfy { $0.extras?.block("TySh") == nil })
        #expect(document.extras?.globalBlocks.contains { $0.key == "Txt2" } == false)
    }

    // MARK: Metrics

    @Test func metricsMeasureTheLayoutTheTextToolDraws() throws {
        let point = style("One\nTwo\nThree", alignment: .center)
        let metrics = PSDTextMetrics.measure(point)
        let drawn = EditorSession.textMetrics(point)
        let image = try EditorSession.textImage(point)
        #expect(metrics.size == CGSize(width: image.width, height: image.height) && metrics.size == drawn.size)
        #expect(metrics.anchor == CGPoint(x: drawn.alignmentX, y: drawn.firstBaseline))
        #expect(metrics.lineCount == 3 && metrics.lineWidth > 0 && metrics.ascent > 0 && metrics.descent > 0)
        #expect(metrics.fontType == 1)
        let boxed = PSDTextMetrics.measure(style("Box", box: CGSize(width: 200, height: 100)))
        #expect(boxed.anchor == CGPoint(x: LayerTextStyle.padding, y: LayerTextStyle.padding))
        #expect(PSDTextMetrics.measure(style("CFF", font: "HiraginoSans-W3")).fontType == 0)
    }

    @Test func theWriteRequestMeasuresLiveTextOnly() throws {
        let text = try textLayer(style("Measured"), at: .zero)
        var pixels = try textLayer(style("Pixels"), at: CGPoint(x: 0, y: 100), name: "Pixels")
        pixels.text = nil
        let request = try #require(session([text, pixels]).psdWriteRequest())
        #expect(request.sidecars[text.id]?.textMetrics == PSDTextMetrics.measure(style("Measured")))
        #expect(request.sidecars[pixels.id]?.textMetrics == nil)
    }
}
