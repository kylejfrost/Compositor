import AppKit
import Foundation
import MCP
import Testing
@testable import Compositor

/// Photoshop type layers (`TySh`) import as editable text that keeps Photoshop's pixels until it is edited.
@MainActor
@Suite(.serialized)
struct PSDTextImportTests {
    private let canvas = CGSize(width: 600, height: 400)

    private func raster(width: Int, height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 2, y: 2, width: width - 4, height: height - 4))
        return try #require(context.makeImage())
    }

    /// A one-layer file whose layer has `block` as its `TySh` and a raster at `bounds`, read and converted.
    private func importing(_ block: Data, bounds: CGRect = CGRect(x: 100, y: 60, width: 120, height: 40),
                           name: String = "Title") throws -> PSDImport {
        var record = PSDRecord(id: UUID(), name: name)
        record.bounds = bounds
        record.image = try raster(width: Int(bounds.width), height: Int(bounds.height))
        record.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "TySh", data: block)])
        let composite = try raster(width: Int(canvas.width), height: Int(canvas.height))
        let data = try PSDFixture.data(PSDDocument(width: Int(canvas.width), height: Int(canvas.height), resolution: 72,
                                                   layers: [record]), composite: composite)
        return try PSDDocumentBuilder.makeImport(try PSDReader.read(data))
    }

    private func session(with imported: PSDImport) throws -> EditorSession {
        let session = EditorSession()
        try session.insertPhotoshop(imported, named: "Fixture")
        return session
    }

    /// The ink (alpha > 0) of `layer` in document pixels, for an unrotated, unflipped layer.
    private func ink(_ layer: ImageLayer) throws -> CGRect {
        let image = try #require(layer.asset?.image)
        let width = image.width, height = image.height
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[y * width * 4 + x * 4 + 3] > 0 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        #expect(maxX >= 0)
        let sx = layer.transform.size.width / CGFloat(width), sy = layer.transform.size.height / CGFloat(height)
        return CGRect(x: layer.transform.origin.x + CGFloat(minX) * sx, y: layer.transform.origin.y + CGFloat(minY) * sy,
                      width: CGFloat(maxX - minX + 1) * sx, height: CGFloat(maxY - minY + 1) * sy)
    }

    /// Edits the only layer's text to `content` through the text tool, as a person would.
    private func edit(_ session: EditorSession, to content: String) throws {
        let id = try #require(session.document?.layers.first?.id)
        session.selectLayer(id)
        session.editActiveText()
        var draft = try #require(session.textDraft)
        draft.style.content = content
        #expect(session.applyText(draft))
    }

    // MARK: Mapping

    @Test func pointTextMapsFontSizeColorAlignmentLeadingTrackingAndOrigin() throws {
        let block = PSDFixture.typeToolBlock(text: "Hello", font: "HelveticaNeue-Bold", fontSize: 24,
                                             color: (1, 0.5, 0.25), justification: 2, leading: 30, tracking: 50,
                                             transform: [2, 0, 0, 2, 160, 90])
        let type = try PSDTypeReader.parse(block)
        #expect(type.text == "Hello\r")
        #expect(type.transform == [2, 0, 0, 2, 160, 90])
        #expect(!type.isParagraphText && type.orientation == "Hrzn" && type.warpStyle == "warpNone")
        let mapped = try #require(PSDTypeReader.style(type, fontResolver: FontResolver.self))
        let style = mapped.style
        #expect(style.content == "Hello")
        #expect(style.fontName == "HelveticaNeue-Bold")
        #expect(style.fontSize == 48)
        #expect(style.red == 1 && style.green == 0.5 && style.blue == 0.25)
        #expect(style.alignment == .center)
        #expect(style.leading == 60)
        #expect(abs(style.tracking - 2.4) < 0.0001)
        #expect(style.boxSize == nil && style.horizontalScale == nil)
        #expect(mapped.origin == CGPoint(x: 160, y: 90))
        #expect(mapped.notes.isEmpty)

        let bounds = CGRect(x: 100, y: 60, width: 120, height: 40)
        let imported = try importing(block, bounds: bounds)
        #expect(imported.conversions.isEmpty)
        let layer = try #require(imported.layers.first)
        let text = try #require(layer.liveText)
        #expect(text.style == style)
        #expect(text.image === layer.asset?.image)
        #expect(layer.transform.origin == bounds.origin && layer.transform.size == bounds.size)
        #expect(layer.psdExtras?.importedText == style)
        #expect(layer.psdExtras?.importedTextIsBox == false)
        let anchor = try #require(layer.psdExtras?.importedTextAnchor)
        #expect(abs(anchor.x - 0.5) < 0.0001 && abs(anchor.y - 0.75) < 0.0001)
        #expect(layer.psdExtras?.block("TySh") == block)
    }

    @Test func autoLeadingLineBreaksAndJustifiedAlignment() throws {
        let block = PSDFixture.typeToolBlock(text: "One\rTwo\u{3}Three", justification: 3)
        let mapped = try #require(PSDTypeReader.style(try PSDTypeReader.parse(block), fontResolver: FontResolver.self))
        #expect(mapped.style.content == "One\nTwo\nThree")
        #expect(mapped.style.leading == 0)
        #expect(mapped.style.alignment == .left)
        #expect(mapped.notes.contains { $0.contains("Justified") })
        let right = try #require(PSDTypeReader.style(try PSDTypeReader.parse(PSDFixture.typeToolBlock(text: "A", justification: 1)),
                                                     fontResolver: FontResolver.self))
        #expect(right.style.alignment == .right && right.notes.isEmpty)
        let all = try #require(PSDTypeReader.style(try PSDTypeReader.parse(PSDFixture.typeToolBlock(text: "A", justification: 6)),
                                                   fontResolver: FontResolver.self))
        #expect(all.style.alignment == .left && !all.notes.isEmpty)
    }

    @Test func paragraphTextMapsItsBox() throws {
        let block = PSDFixture.typeToolBlock(text: "A paragraph of text", fontSize: 20,
                                             transform: [1.5, 0, 0, 1.5, 40, 30], box: CGRect(x: 0, y: 0, width: 200, height: 100))
        let type = try PSDTypeReader.parse(block)
        #expect(type.isParagraphText && type.boxBounds == CGRect(x: 0, y: 0, width: 200, height: 100))
        let mapped = try #require(PSDTypeReader.style(type, fontResolver: FontResolver.self))
        let padding = LayerTextStyle.padding
        #expect(mapped.style.boxSize == CGSize(width: 300 + 2 * padding, height: 150 + 2 * padding))
        #expect(mapped.style.fontSize == 30)
        #expect(mapped.origin == CGPoint(x: 40, y: 30))
        let imported = try importing(block, bounds: CGRect(x: 30, y: 20, width: 200, height: 80))
        let layer = try #require(imported.layers.first)
        #expect(layer.liveText?.style.boxSize == mapped.style.boxSize)
        #expect(layer.psdExtras?.importedTextIsBox == true)
        let anchor = try #require(layer.psdExtras?.importedTextAnchor)
        #expect(abs(anchor.x - 0.05) < 0.0001 && abs(anchor.y - 0.125) < 0.0001)
    }

    @Test func twoRunsImportTheDominantRunWithANote() throws {
        // "Headline" (8 units) in one font, " tiny" (5) in another, and the paragraph's `\r` in AdobeInvisFont.
        let runs = [PSDFixture.TextRun(length: 8, font: "HelveticaNeue-Bold", fontSize: 40),
                    PSDFixture.TextRun(length: 5, font: "Helvetica", fontSize: 12),
                    PSDFixture.TextRun(length: 1, font: "AdobeInvisFont", fontSize: 40)]
        let block = PSDFixture.typeToolBlock(text: "Headline tiny", transform: [1, 0, 0, 1, 10, 50], runs: runs)
        let type = try PSDTypeReader.parse(block)
        #expect(type.styleRuns.count == 3)
        let mapped = try #require(PSDTypeReader.style(type, fontResolver: FontResolver.self))
        #expect(mapped.style.fontName == "HelveticaNeue-Bold" && mapped.style.fontSize == 40)
        let note = try #require(mapped.notes.first)
        #expect(mapped.notes.count == 1)
        #expect(note.contains("Helvetica 12"))
        #expect(!note.contains("AdobeInvisFont"))
        let imported = try importing(block)
        #expect(imported.conversions.map(\.message) == [note])
        #expect(imported.layers.first?.liveText != nil)
    }

    /// However many other styles the text has, the note names the first five, then how many more: a file of
    /// thousands of one-letter runs makes a short note, found in one pass over the runs.
    @Test func theMixedStylesNoteNamesAtMostFiveOtherStyles() throws {
        let text = String(repeating: "a", count: 40) + String(repeating: "b", count: 12)
        let runs = [PSDFixture.TextRun(length: 40, font: "Helvetica", fontSize: 40)]
            + (1 ... 12).map { PSDFixture.TextRun(length: 1, font: "Helvetica", fontSize: Double($0)) }
            + [PSDFixture.TextRun(length: 1, font: "AdobeInvisFont", fontSize: 40)]
        let type = try PSDTypeReader.parse(PSDFixture.typeToolBlock(text: text, transform: [1, 0, 0, 1, 10, 50], runs: runs))
        let mapped = try #require(PSDTypeReader.style(type, fontResolver: FontResolver.self))
        let note = try #require(mapped.notes.first)
        #expect(note.contains("(Helvetica 1 px, Helvetica 2 px, Helvetica 3 px, Helvetica 4 px, Helvetica 5 px and 7 more)"))
        #expect(!note.contains("Helvetica 6 px"))
    }

    @Test func aMissingFontKeepsTheRasterAndSaysWhatEditingWillUse() throws {
        let block = PSDFixture.typeToolBlock(text: "Sale", font: "NoSuchFoundry-Heavy", fontSize: 36)
        let imported = try importing(block)
        let layer = try #require(imported.layers.first)
        let text = try #require(layer.liveText)
        #expect(text.image === layer.asset?.image)
        #expect(text.style.fontName == "NoSuchFoundry-Heavy")
        let resolved = FontResolver.resolve("NoSuchFoundry-Heavy", size: 36)
        #expect(resolved.isSubstitute)
        let name = resolved.font.displayName ?? resolved.font.fontName
        #expect(imported.conversions.map(\.message) == [
            "Font “NoSuchFoundry-Heavy” isn't installed. The imported pixels are kept; editing this text will use \(name) until the font is installed."
        ])
        let session = try session(with: imported)
        #expect(session.missingFonts().map(\.requested) == ["NoSuchFoundry-Heavy"])
    }

    @Test func importedTextIsLiveAndKeepsPhotoshopsExactRaster() throws {
        var record = PSDRecord(id: UUID(), name: "Title")
        record.bounds = CGRect(x: 100, y: 60, width: 120, height: 40)
        record.image = try raster(width: 120, height: 40)
        let block = PSDFixture.typeToolBlock(text: "Hi")
        record.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "TySh", data: block)])
        // As `PSDReader` leaves a type layer: its kind and decoded `TySh`.
        record.kind = .text
        record.typeLayer = try PSDTypeReader.parse(block)
        let document = PSDDocument(width: 600, height: 400, resolution: 72, layers: [record])
        let assets = try PSDDocumentBuilder.assets(from: document)
        let imported = try PSDDocumentBuilder.makeImport(document, assets: assets)
        let layer = try #require(imported.layers.first)
        #expect(layer.liveText != nil)
        #expect(layer.asset?.image === assets[record.id]?.image)
        #expect(layer.liveText?.image === record.image)
        let session = try session(with: imported)
        // Opening the editor and closing it without a change keeps Photoshop's pixels.
        session.selectLayer(layer.id)
        session.editActiveText()
        #expect(session.applyText(try #require(session.textDraft)))
        #expect(session.document?.layers.first?.asset?.image === record.image)
        #expect(session.document?.layers.first?.psdExtras?.importedTextAnchor != nil)
    }

    // MARK: The first edit

    @Test(arguments: [0, 2, 1])
    func theFirstEditLandsTheFirstBaselineOnTheAnchor(justification: Int) throws {
        let block = PSDFixture.typeToolBlock(text: "HH", font: "Helvetica", fontSize: 40, justification: justification,
                                             transform: [1, 0, 0, 1, 300, 150])
        let session = try session(with: try importing(block, bounds: CGRect(x: 250, y: 118, width: 100, height: 40)))
        try edit(session, to: "HHHH")
        let layer = try #require(session.document?.layers.first)
        #expect(layer.psdExtras?.importedTextAnchor == nil)
        let style = try #require(layer.liveText?.style)
        #expect(style.content == "HHHH")
        let metrics = EditorSession.textMetrics(style)
        #expect(CGFloat(try #require(layer.asset?.image.width)) == metrics.size.width)
        let baseline = layer.transform.point(CGPoint(x: metrics.alignmentX / metrics.size.width,
                                                     y: metrics.firstBaseline / metrics.size.height))
        #expect(abs(baseline.x - 300) < 0.01 && abs(baseline.y - 150) < 0.01)
        // The letters themselves: H sits on the baseline and starts, centers or ends at the alignment point.
        let box = try ink(layer)
        #expect(abs(box.maxY - 150) <= 1)
        switch justification {
        case 0: #expect(box.minX >= 299 && box.minX - 300 < 8)
        case 1: #expect(box.maxX <= 301 && 300 - box.maxX < 8)
        default: #expect(abs(box.midX - 300) <= 1)
        }
    }

    @Test func theFirstEditOfParagraphTextPutsTheBoxOnItsTopLeft() throws {
        let block = PSDFixture.typeToolBlock(text: "Boxed", font: "Helvetica", fontSize: 30,
                                             transform: [1, 0, 0, 1, 40, 30], box: CGRect(x: 0, y: 0, width: 240, height: 90))
        let session = try session(with: try importing(block, bounds: CGRect(x: 42, y: 36, width: 80, height: 30)))
        try edit(session, to: "Boxed text")
        let layer = try #require(session.document?.layers.first)
        let style = try #require(layer.liveText?.style)
        let padding = LayerTextStyle.padding
        #expect(layer.transform.size == CGSize(width: 240 + 2 * padding, height: 90 + 2 * padding))
        let topLeft = layer.transform.point(CGPoint(x: padding / layer.transform.size.width, y: padding / layer.transform.size.height))
        #expect(abs(topLeft.x - 40) < 0.01 && abs(topLeft.y - 30) < 0.01)
        #expect(style.boxSize == layer.transform.size)
        #expect(layer.psdExtras?.importedTextAnchor == nil)
    }

    @Test func movingTheLayerBeforeTheFirstEditMovesTheAnchor() throws {
        let block = PSDFixture.typeToolBlock(text: "HH", font: "Helvetica", fontSize: 40, transform: [1, 0, 0, 1, 300, 150])
        let session = try session(with: try importing(block, bounds: CGRect(x: 298, y: 118, width: 60, height: 40)))
        session.document?.layers[0].transform.origin.x += 30
        session.document?.layers[0].transform.origin.y -= 20
        try edit(session, to: "HHH")
        let layer = try #require(session.document?.layers.first)
        let metrics = EditorSession.textMetrics(try #require(layer.liveText?.style))
        let baseline = layer.transform.point(CGPoint(x: metrics.alignmentX / metrics.size.width,
                                                     y: metrics.firstBaseline / metrics.size.height))
        #expect(abs(baseline.x - 330) < 0.01 && abs(baseline.y - 130) < 0.01)
        #expect(abs(try ink(layer).maxY - 130) <= 1)
    }

    @Test func aScaledLayerKeepsItsScaleOnTheFirstEdit() throws {
        let block = PSDFixture.typeToolBlock(text: "HH", font: "Helvetica", fontSize: 40, transform: [1, 0, 0, 1, 300, 150])
        let session = try session(with: try importing(block, bounds: CGRect(x: 298, y: 118, width: 60, height: 40)))
        let old = session.document!.layers[0].transform
        session.document?.layers[0].transform.size = CGSize(width: old.size.width * 2, height: old.size.height * 2)
        session.document?.layers[0].transform.origin = CGPoint(x: old.origin.x - old.size.width / 2, y: old.origin.y - old.size.height / 2)
        // The anchor follows the scale: unit (2/60, 32/40) of the new 120×80 box at (268, 98) is (272, 162).
        try edit(session, to: "HHH")
        let layer = try #require(session.document?.layers.first)
        let image = try #require(layer.asset?.image)
        #expect(abs(layer.transform.size.width / CGFloat(image.width) - 2) < 0.0001)
        let metrics = EditorSession.textMetrics(try #require(layer.liveText?.style))
        let baseline = layer.transform.point(CGPoint(x: metrics.alignmentX / metrics.size.width,
                                                     y: metrics.firstBaseline / metrics.size.height))
        #expect(abs(baseline.x - 272) < 0.01 && abs(baseline.y - 162) < 0.01)
    }

    /// The editor shows imported centered or right-aligned text where committing it will put it: growing around the
    /// alignment point Photoshop anchored it by, not from its top-left corner, so nothing jumps on commit. Also for a
    /// layer that was scaled, which opens the editor on the layer's own transform.
    @Test(arguments: [(2, 1.0), (1, 1.0), (2, 2.0)])
    func theEditorGrowsImportedTextWhereTheCommitWillPutIt(justification: Int, scale: Double) throws {
        let block = PSDFixture.typeToolBlock(text: "HH", font: "Helvetica", fontSize: 40, justification: justification,
                                             transform: [1, 0, 0, 1, 300, 150])
        let session = try session(with: try importing(block, bounds: CGRect(x: 250, y: 118, width: 100, height: 40)))
        let id = try #require(session.document?.layers.first?.id)
        session.document?.layers[0].transform.size.width *= scale
        session.document?.layers[0].transform.size.height *= scale
        session.selectLayer(id)
        session.editActiveText()
        let canvas = CanvasView(session: session)
        session.textDraft?.style.content = "HHHHHH"
        canvas.synchronizeInlineText()
        let shown = try #require(canvas.inlineTextEditor).frame
        #expect(session.applyText(try #require(session.textDraft)))
        let layer = try #require(session.document?.layers.first)
        let document = try #require(session.document)
        let origin = session.viewport.viewPoint(from: layer.transform.point(.zero), documentSize: document.size)
        let pointsPerPixel = session.viewport.pointsPerPixel
        #expect(abs(shown.minX - origin.x) < 0.01 && abs(shown.minY - origin.y) < 0.01, "\(shown) vs \(origin)")
        #expect(abs(shown.width - layer.transform.size.width * pointsPerPixel) < 0.01)
        #expect(abs(shown.height - layer.transform.size.height * pointsPerPixel) < 0.01)
    }

    /// Photoshop's paragraph boxes can be fractional; Compositor's are whole pixels, as Image Size leaves them.
    @Test func paragraphBoxesImportAsWholePixels() throws {
        let block = PSDFixture.typeToolBlock(text: "A paragraph", fontSize: 20, transform: [1.5, 0, 0, 1.5, 40, 30],
                                             box: CGRect(x: 0, y: 0, width: 200.3, height: 100.5))
        let mapped = try #require(PSDTypeReader.style(try PSDTypeReader.parse(block), fontResolver: FontResolver.self))
        // 300.45 + 24 and 150.75 + 24, rounded.
        #expect(mapped.style.boxSize == CGSize(width: 324, height: 175))
    }

    @Test func recoloringBeforeTheFirstEditAlsoUsesTheAnchor() throws {
        let block = PSDFixture.typeToolBlock(text: "HH", font: "Helvetica", fontSize: 40, transform: [1, 0, 0, 1, 300, 150])
        let session = try session(with: try importing(block, bounds: CGRect(x: 298, y: 118, width: 60, height: 40)))
        let id = try #require(session.document?.layers.first?.id)
        #expect(session.recolorText(id, to: PaletteColor(red: 1, green: 0, blue: 0)))
        let layer = try #require(session.document?.layers.first)
        #expect(layer.psdExtras?.importedTextAnchor == nil)
        #expect(abs(try ink(layer).maxY - 150) <= 1)
    }

    // MARK: Upstream's text import cases

    /// The type's matrix alone maps Photoshop's sizes to pixels: a 300 ppi file is no bigger than a 72 ppi one
    /// (from upstream's photoshopTextSizeUsesMatrixScaleNotDocumentResolution).
    @Test func fontSizeFollowsTheTransformNotTheDocumentResolution() throws {
        func size(_ block: Data, resolution: Double) throws -> CGFloat? {
            var record = PSDRecord(id: UUID(), name: "Title")
            record.bounds = CGRect(x: 10, y: 10, width: 60, height: 30)
            record.image = try raster(width: 60, height: 30)
            record.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "TySh", data: block)])
            let data = try PSDFixture.data(PSDDocument(width: 100, height: 60, resolution: resolution, layers: [record]),
                                           composite: try raster(width: 100, height: 60))
            return try PSDDocumentBuilder.makeImport(try PSDReader.read(data)).layers.first?.liveText?.style.fontSize
        }
        let plain = PSDFixture.typeToolBlock(text: "Hello", fontSize: 24)
        #expect(try size(plain, resolution: 72) == 24)
        #expect(try size(plain, resolution: 300) == 24)
        #expect(try size(PSDFixture.typeToolBlock(text: "Hello", fontSize: 24, transform: [2, 0, 0, 2, 0, 0]), resolution: 300) == 48)
        #expect(try size(PSDFixture.typeToolBlock(text: "Hello", fontSize: 25, transform: [2, 0, 0, 2, 0, 0]), resolution: 72) == 50)
    }

    /// Runs of one font and size that differ only in leading, character scale or faux styles still mix styles, which
    /// editing drops: the note says so (from upstream's photoshopTextReportsLeadingOnlyStyleDifferences).
    @Test func runsThatDifferOnlyInLeadingOrScaleAreNoted() throws {
        let runs = [PSDFixture.TextRun(length: 3, font: "Helvetica", fontSize: 24),
                    PSDFixture.TextRun(length: 3, font: "Helvetica", fontSize: 24)]
        let base = PSDFixture.typeToolBlock(text: "Hello", leading: 30, runs: runs)
        let plain = try #require(PSDTypeReader.style(try PSDTypeReader.parse(base), fontResolver: FontResolver.self))
        #expect(plain.notes.isEmpty)
        for (key, value) in [("Leading", EngineValue.number(48)), ("HorizontalScale", .number(1.2)),
                             ("VerticalScale", .number(0.8)), ("FauxItalic", .bool(true))] {
            let block = try PSDFixture.typeToolBlock(base, settingEngineData: "EngineDict.StyleRun.RunArray.1.StyleSheet.StyleSheetData.\(key)",
                                                     to: value)
            let mapped = try #require(PSDTypeReader.style(try PSDTypeReader.parse(block), fontResolver: FontResolver.self))
            #expect(mapped.notes.contains { $0.contains("mixes") }, "\(key)")
        }
    }

    /// Faux bold and faux italic are Photoshop's; the text shows Photoshop's pixels, and a note says editing drops them
    /// (from upstream's warpedPhotoshopTextStaysEditableAndSaysSo, whose warp half Compositor keeps as pixels instead).
    @Test func fauxBoldOrItalicIsNoted() throws {
        for key in ["FauxBold", "FauxItalic"] {
            let block = try PSDFixture.typeToolBlock(PSDFixture.typeToolBlock(text: "Bold"),
                                                     settingEngineData: "EngineDict.StyleRun.RunArray.0.StyleSheet.StyleSheetData.\(key)",
                                                     to: .bool(true))
            let imported = try importing(block)
            #expect(imported.layers.first?.liveText != nil)
            #expect(imported.conversions.map(\.message) == [PSDTypeReader.fauxStyleNote], "\(key)")
        }
    }

    /// A paragraph box larger than a text box can be keeps Photoshop's pixels and its type data, and says so (from
    /// upstream's oversizedPhotoshopParagraphFrameStaysPixels).
    @Test func anOversizedParagraphBoxKeepsPhotoshopsPixels() throws {
        let block = PSDFixture.typeToolBlock(text: "Billboard", box: CGRect(x: 0, y: 0, width: 40_000, height: 100))
        let imported = try importing(block)
        let layer = try #require(imported.layers.first)
        #expect(layer.liveText == nil && layer.asset != nil)
        #expect(layer.psdExtras?.block("TySh") == block)
        #expect(imported.conversions.map(\.message) == [
            "This text’s settings are beyond what Compositor’s text supports, so the layer keeps Photoshop’s pixels. Its type settings are kept."
        ])
    }

    // MARK: Kept as pixels

    @Test(arguments: [
        ("sheared", [1.0, 0, 0.2, 1, 50, 50], "Hrzn", "warpNone", 1),
        ("rotated", [0.9659258, 0.2588190, -0.2588190, 0.9659258, 50, 50], "Hrzn", "warpNone", 1),
        ("vertical", [1.0, 0, 0, 1, 50, 50], "Vrtc", "warpNone", 1),
        ("warped", [1.0, 0, 0, 1, 50, 50], "Hrzn", "warpArc", 1),
        ("non-RGB", [1.0, 0, 0, 1, 50, 50], "Hrzn", "warpNone", 2),
    ])
    func unsupportedTypeKeepsItsPixelsAndSaysWhy(_ kind: String, _ transform: [Double], _ orientation: String,
                                                 _ warp: String, _ fillType: Int) throws {
        let block = PSDFixture.typeToolBlock(text: "Tilted", transform: transform, orientation: orientation,
                                             warpStyle: warp, fillType: fillType)
        let type = try PSDTypeReader.parse(block)
        #expect(PSDTypeReader.style(type, fontResolver: FontResolver.self) == nil)
        let imported = try importing(block)
        let layer = try #require(imported.layers.first)
        #expect(layer.liveText == nil && layer.text == nil)
        #expect(layer.asset != nil)
        #expect(layer.psdExtras?.block("TySh") == block)
        #expect(layer.psdExtras?.importedText == nil && layer.psdExtras?.importedTextAnchor == nil)
        let note = try #require(imported.conversions.first?.message)
        #expect(imported.conversions.count == 1)
        let words = ["sheared": "Skewed", "rotated": "Rotated", "vertical": "Vertical", "warped": "Warped", "non-RGB": "RGB"]
        #expect(note.contains(words[kind]!))
    }

    @Test func unreadableTypeDataKeepsTheLayerItsPixelsAndItsBytes() throws {
        let garbage = Data([0, 1, 0x3F, 0xF0, 0, 0, 0, 0, 0, 0, 1, 2, 3])
        let imported = try importing(garbage)
        let layer = try #require(imported.layers.first)
        #expect(layer.asset != nil && layer.text == nil)
        #expect(layer.psdExtras?.block("TySh") == garbage)
        #expect(imported.conversions.count == 1)
        #expect(throws: (any Error).self) { try PSDTypeReader.parse(garbage) }
    }

    /// Run lengths count UTF-16 units of the text. One longer than the text, or lengths whose sum overflows `Int`, make
    /// the type data unreadable: the import keeps the layer, its pixels and its bytes instead of trapping.
    @Test(arguments: [
        ("StyleRun", [1000]),
        ("StyleRun", [1, Int.max]),
        ("ParagraphRun", [Int.max]),
        ("ParagraphRun", [1, Int.max]),
        ("ParagraphRun", [Int.max, Int.max]),
    ])
    func anImpossibleRunLengthKeepsTheLayerItsPixelsAndItsBytes(_ runs: String, _ lengths: [Int]) throws {
        let base = PSDFixture.typeToolBlock(text: "Huge")
        // The editing helper alone changes nothing: "Huge\r" is 5 units in one run.
        let same = try PSDFixture.typeToolBlock(base, settingEngineData: "EngineDict.\(runs).RunLengthArray", to: .array([.integer(5)]))
        #expect(try PSDTypeReader.parse(same) == PSDTypeReader.parse(base))

        var block = try PSDFixture.typeToolBlock(base, settingEngineData: "EngineDict.\(runs).RunArray",
                                                 to: .array(lengths.map { _ in .dictionary([]) }))
        block = try PSDFixture.typeToolBlock(block, settingEngineData: "EngineDict.\(runs).RunLengthArray",
                                             to: .array(lengths.map(EngineValue.integer)))
        #expect(throws: PSDTypeError.malformed) { try PSDTypeReader.parse(block) }
        let imported = try importing(block)
        let layer = try #require(imported.layers.first)
        #expect(layer.asset != nil && layer.text == nil && layer.liveText == nil)
        #expect(layer.psdExtras?.block("TySh") == block)
        #expect(layer.psdExtras?.importedText == nil && layer.psdExtras?.importedTextAnchor == nil)
        #expect(imported.conversions.count == 1)
        #expect(imported.conversions.first?.message.contains("type data couldn’t be read") == true)
    }

    /// The mapping clamps every run to the text that remains, so lengths no reader would accept (negative, `Int.max`,
    /// or summing past `Int.max`) in a hand-built layer can't trap or reach outside the text.
    @Test func runLengthsBeyondTheTextNeverTrapTheMapping() throws {
        var type = try PSDTypeReader.parse(PSDFixture.typeToolBlock(text: "Safe", font: "HelveticaNeue-Bold", fontSize: 30))
        let run = try #require(type.styleRuns.first)
        var negative = run
        negative.length = -3
        negative.fontName = "Helvetica"
        var huge = run
        huge.length = Int.max
        huge.fontName = "Helvetica"
        type.styleRuns = [negative, run, huge, huge]
        // "Saf" is centered; "e\r" and nothing are right-aligned.
        type.paragraphRuns = [PSDParagraphRun(length: 3, justification: 2), PSDParagraphRun(length: Int.max, justification: 1),
                              PSDParagraphRun(length: Int.max, justification: 1)]
        #expect(PSDTypeReader.unsupportedReason(type) == nil)
        #expect(PSDTypeReader.dominantRun(type) == run)
        let mapped = try #require(PSDTypeReader.style(type, fontResolver: FontResolver.self))
        #expect(mapped.style.fontName == "HelveticaNeue-Bold" && mapped.style.fontSize == 30)
        #expect(mapped.style.alignment == .center)
        #expect(mapped.notes.isEmpty)
    }

    // MARK: Persistence, scale and MCP

    @Test func aProjectRoundTripKeepsTheTextAndItsAnchor() async throws {
        let block = PSDFixture.typeToolBlock(text: "Saved", font: "HelveticaNeue", fontSize: 30, transform: [1, 0, 0, 1, 120, 90])
        let session = try session(with: try importing(block))
        let original = try #require(session.document?.layers.first)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PSDTextImportTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Text.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let reopened = EditorSession()
        reopened.installProject(try await ProjectStore.shared.load(from: url), from: url)
        let restored = try #require(reopened.document?.layers.first)
        #expect(restored.liveText?.style == original.liveText?.style)
        #expect(restored.psdExtras?.importedTextAnchor == original.psdExtras?.importedTextAnchor)
        #expect(restored.psdExtras?.importedText == original.psdExtras?.importedText)
        #expect(restored.psdExtras?.importedTextIsBox == false)
        try edit(reopened, to: "Saved!")
        let edited = try #require(reopened.document?.layers.first)
        let metrics = EditorSession.textMetrics(try #require(edited.liveText?.style))
        let baseline = edited.transform.point(CGPoint(x: metrics.alignmentX / metrics.size.width,
                                                      y: metrics.firstBaseline / metrics.size.height))
        #expect(abs(baseline.x - 120) < 0.01 && abs(baseline.y - 90) < 0.01)

        // A horizontal scale saves and loads; one outside 0.1…10 is rejected.
        var manifest = try #require(session.projectSnapshot()).manifest
        let index = try #require(manifest.layers.firstIndex { $0.text != nil })
        manifest.layers[index].text?.horizontalScale = 1.5
        try JSONEncoder().encode(manifest).write(to: url.appendingPathComponent("manifest.json"))
        #expect(try await ProjectStore.shared.load(from: url).manifest.layers[index].text?.horizontalScale == 1.5)
        manifest.layers[index].text?.horizontalScale = 20
        try JSONEncoder().encode(manifest).write(to: url.appendingPathComponent("manifest.json"))
        do {
            _ = try await ProjectStore.shared.load(from: url)
            Issue.record("A horizontal scale of 20 should be rejected")
        } catch ProjectError.invalid {}
    }

    @Test func horizontalScaleComesFromUnevenScalingAndRendersWider() throws {
        let block = PSDFixture.typeToolBlock(text: "Wide", font: "Helvetica", fontSize: 30, transform: [2, 0, 0, 1, 10, 50])
        let mapped = try #require(PSDTypeReader.style(try PSDTypeReader.parse(block), fontResolver: FontResolver.self))
        #expect(mapped.style.horizontalScale == 2)
        #expect(mapped.style.fontSize == 30)
        let even = try #require(PSDTypeReader.style(try PSDTypeReader.parse(
            PSDFixture.typeToolBlock(text: "Even", transform: [1.005, 0, 0, 1, 0, 0])), fontResolver: FontResolver.self))
        #expect(even.style.horizontalScale == nil)

        var style = LayerTextStyle()
        style.content = "HHHH"
        style.fontName = "Helvetica"
        style.fontSize = 40
        let plain = try EditorSession.textImage(style)
        style.horizontalScale = 2
        let wide = try EditorSession.textImage(style)
        #expect(wide.height == plain.height)
        let padding = 2 * LayerTextStyle.padding
        let ratio = (CGFloat(wide.width) - padding) / (CGFloat(plain.width) - padding)
        #expect(abs(ratio - 2) < 0.05)
        let plainInk = try ink(ImageLayer(asset: ImportedImage(image: plain, thumbnail: plain, name: "p"), origin: .zero))
        let wideInk = try ink(ImageLayer(asset: ImportedImage(image: wide, thumbnail: wide, name: "w"), origin: .zero))
        #expect(abs(wideInk.width / plainInk.width - 2) < 0.05)
        style.horizontalScale = 20
        #expect(!style.isValid)
        style.horizontalScale = 0.05
        #expect(!style.isValid)
    }

    @Test func mcpReportsImportedTypeAsText() throws {
        let block = PSDFixture.typeToolBlock(text: "Agent", font: "HelveticaNeue", fontSize: 30)
        let session = try session(with: try importing(block))
        let document = try #require(session.document)
        let layer = try #require(document.layers.first)
        let value = MCPValues.layerDetail(layer, in: document, full: true).objectValue
        #expect(value?["kind"]?.stringValue == "text")
        #expect(value?["text"]?.objectValue?["content"]?.stringValue == "Agent")
        #expect(value?["text"]?.objectValue?["font_name"]?.stringValue == "HelveticaNeue")
    }
}
