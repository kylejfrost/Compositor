import AppKit
import Foundation
import Testing
import MCP
@testable import Compositor

/// The text and font tools: `add_text_layer` places new type by an anchor (and can shrink it to a width),
/// `set_text`/`set_text_style` restyle a live text layer through `decodeMerged` as one "Edit Text" step,
/// `fit_text` shrinks point text to a width, `get_text_metrics` measures a layer or a style, and
/// `list_fonts`/`check_fonts` report what is installed.
@MainActor struct MCPTextToolTests {
    // MARK: Helpers

    private func layer(_ session: EditorSession, _ id: UUID) -> ImageLayer? {
        session.document?.layers.first { $0.id == id }
    }

    private func id(_ result: [String: Value]) throws -> UUID {
        try #require(result["layer_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
    }

    private func message(_ result: [String: Value]) -> String {
        result["error"]?.objectValue?["message"]?.stringValue ?? ""
    }

    private func error(_ result: [String: Value]) -> [String: Value] {
        result["error"]?.objectValue ?? [:]
    }

    private func recorded(_ result: [String: Value]) -> Bool? {
        result["undo"]?.objectValue?["recorded"]?.boolValue
    }

    /// A workspace holding one point-text layer named "Title" ("Hello" in 72-px Helvetica at 40, 50).
    private func titleWorkspace(_ text: String = "Hello") async throws -> (workspace: ProjectWorkspace, session: EditorSession, id: UUID) {
        let workspace = MCPTestSupport.workspace()
        let result = try await MCPTestSupport.call("add_text_layer", ["text": .string(text), "x": 40, "y": 50, "name": "Title"],
                                                   in: workspace)
        return (workspace, workspace.current.session, try id(result))
    }

    // MARK: add_text_layer

    @Test func addTextLayerCentersTheBoxOnTheAnchor() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        session.foregroundColor = PaletteColor(red: 0.2, green: 0.4, blue: 0.6)
        let before = session.history.undoCount
        let result = try await MCPTestSupport.call(
            "add_text_layer", ["text": "Hello", "x": 320, "y": 240, "anchor": "center", "style": ["font_size": 40]], in: workspace)
        let added = try #require(layer(session, try id(result)))
        #expect(abs(added.transform.center.x - 320) < 0.001 && abs(added.transform.center.y - 240) < 0.001)
        let style = try #require(added.liveText?.style)
        #expect(style.content == "Hello" && style.fontSize == 40 && style.fontName == "Helvetica" && style.boxSize == nil)
        #expect(style.red == 0.2 && style.green == 0.4 && style.blue == 0.6)
        #expect(added.name == "Hello")
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "New Text Layer")
        #expect(recorded(result) == true)
        let transform = try #require(result["transform"]?.objectValue)
        #expect(MCPValues.number(transform["center_x"]) == 320 && MCPValues.number(transform["center_y"]) == 240)
        let metrics = try #require(result["metrics"]?.objectValue)
        #expect(MCPValues.number(metrics["font_size"]) == 40)
        #expect(MCPValues.number(metrics["box"]?.objectValue?["width"]) == Double(added.transform.size.width))
        #expect(result["text"]?.objectValue?["alignment"]?.stringValue == "left")
    }

    @Test func addTextLayerTakesAnchorsStyleAndAName() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        let result = try await MCPTestSupport.call("add_text_layer", [
            "text": "Paragraph text", "x": 600, "y": 400, "anchor": "bottom_right", "name": "Body",
            "style": ["font_name": "Helvetica-Bold", "font_size": 24, "color": "#ff0000", "alignment": "Center",
                      "tracking": 2, "leading": 30, "box_size": ["width": 200, "height": 100]],
        ], in: workspace)
        let added = try #require(layer(session, try id(result)))
        #expect(added.name == "Body")
        #expect(abs(added.transform.origin.x - 400) < 0.001 && abs(added.transform.origin.y - 300) < 0.001)
        let style = try #require(added.liveText?.style)
        #expect(style.fontName == "Helvetica-Bold" && style.fontSize == 24 && style.alignment == .center)
        #expect(style.red == 1 && style.green == 0 && style.blue == 0 && style.tracking == 2 && style.leading == 30)
        #expect(style.boxSize == CGSize(width: 200, height: 100))
        let reported = try #require(result["text"]?.objectValue)
        #expect(reported["box_size"]?.objectValue?["width"].flatMap(MCPValues.number) == 200)
        #expect(reported["alignment"]?.stringValue == "center")
    }

    @Test func addTextLayerWithMaxWidthShrinksTheTypeInOneStep() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        let before = session.history.undoCount
        let result = try await MCPTestSupport.call("add_text_layer", [
            "text": "A headline far too wide", "x": 320, "y": 100, "anchor": "top", "max_width": 150,
            "style": ["leading": 90],
        ], in: workspace)
        let added = try #require(layer(session, try id(result)))
        let style = try #require(added.liveText?.style)
        #expect(style.fontSize < 72)
        #expect(abs(style.leading - 90 * style.fontSize / 72) < 0.001)
        #expect(EditorSession.textBoxSize(style).width - 2 * LayerTextStyle.padding <= 150)
        #expect(MCPValues.number(result["metrics"]?.objectValue?["width"]).map { $0 <= 150 } == true)
        #expect(abs(added.transform.center.x - 320) < 0.001 && abs(added.transform.origin.y - 100) < 0.001)
        #expect(session.history.undoCount == before + 1)
    }

    @Test func addTextLayerRefusesBadArguments() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        let before = session.history.undoCount
        let blank = try await MCPTestSupport.call("add_text_layer", ["text": "  \n", "x": 0, "y": 0], in: workspace,
                                                  expectError: "invalid_argument")
        #expect(message(blank).contains("text"))
        let anchor = try await MCPTestSupport.call("add_text_layer", ["text": "Hi", "x": 0, "y": 0, "anchor": "middle_top_left"],
                                                   in: workspace, expectError: "invalid_argument")
        #expect(message(anchor).contains("top_left"))
        let size = try await MCPTestSupport.call("add_text_layer", ["text": "Hi", "x": 0, "y": 0, "style": ["font_size": 5000]],
                                                 in: workspace, expectError: "invalid_argument")
        #expect(message(size).contains("font_size") && message(size).contains("1–2000"), "\(message(size))")
        #expect(error(size)["details"]?.objectValue?["field"]?.stringValue == "font_size")
        let color = try await MCPTestSupport.call("add_text_layer", ["text": "Hi", "x": 0, "y": 0, "style": ["color": ["r": 2, "g": 0, "b": 0]]],
                                                  in: workspace, expectError: "invalid_argument")
        #expect(message(color).contains("color.r") && message(color).contains("0–1"), "\(message(color))")
        let unknown = try await MCPTestSupport.call("add_text_layer", ["text": "Hi", "x": 0, "y": 0, "style": ["font_weight": 700]],
                                                    in: workspace, expectError: "invalid_argument")
        #expect(message(unknown).contains("font_weight"))
        let box = try await MCPTestSupport.call("add_text_layer", ["text": "Hi", "x": 0, "y": 0, "style": ["box_size": ["width": 4, "height": 50]]],
                                                in: workspace, expectError: "invalid_argument")
        #expect(message(box).contains("box_size.width"), "\(message(box))")
        let content = try await MCPTestSupport.call("add_text_layer", ["text": "Hi", "x": 0, "y": 0, "style": ["content": "Other"]],
                                                    in: workspace, expectError: "invalid_argument")
        #expect(message(content).contains("'text'"))
        try await MCPTestSupport.call("add_text_layer", ["text": "Hi", "x": 0, "y": 0, "max_width": 100,
                                                         "style": ["box_size": ["width": 200, "height": 50]]],
                                      in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("add_text_layer", ["text": "Hi", "x": 5_000_000, "y": 0], in: workspace, expectError: "invalid_argument")
        #expect(session.history.undoCount == before)
        #expect(session.document?.layers.count == 1)
    }

    @Test func addTextLayerGoesAboveTheOutermostLockAllFolder() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        let outer = try #require(try await MCPTestSupport.call("add_group", ["name": "Outer"], in: workspace)["group_id"]?.stringValue)
        try await MCPTestSupport.call("add_group", ["name": "Inner"], in: workspace)
        try await MCPTestSupport.call("add_blank_layer", ["name": "Deep"], in: workspace)
        try await MCPTestSupport.call("set_layer_locks", ["layer": .string(outer), "all": true], in: workspace)
        try await MCPTestSupport.call("select_layers", ["layers": ["Deep"]], in: workspace)
        let before = session.history.undoCount
        let result = try await MCPTestSupport.call("add_text_layer", ["text": "Free", "x": 10, "y": 10], in: workspace)
        let document = try #require(session.document)
        let added = try #require(layer(session, try id(result)))
        #expect(added.parentID == nil)
        // Directly above the locked folder, among the top-level layers.
        let topLevel = document.layers.filter { $0.parentID == nil }.map(\.id)
        #expect(topLevel.last == added.id && topLevel.dropLast().last?.uuidString == outer)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "New Text Layer")
    }

    @Test func addTextLayerStopsAtTheLayerCap() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        let size = try #require(session.document?.size)
        session.document?.layers = (0..<10_000).map { ImageLayer(name: "Layer \($0)", blankSize: size) }
        let result = try await MCPTestSupport.call("add_text_layer", ["text": "One too many", "x": 0, "y": 0], in: workspace,
                                                   expectError: "precondition_failed")
        #expect(error(result)["guard"]?.stringValue == "max_layers")
        #expect(session.document?.layers.count == 10_000)
    }

    // MARK: set_text and set_text_style

    @Test func setTextKeepsTheOriginAndIsOneStep() async throws {
        let (workspace, session, id) = try await titleWorkspace()
        let origin = try #require(layer(session, id)?.origin)
        let before = session.history.undoCount
        let result = try await MCPTestSupport.call("set_text", ["layer": "Title", "text": "Hello, longer world"], in: workspace)
        let changed = try #require(layer(session, id))
        #expect(changed.liveText?.style.content == "Hello, longer world")
        #expect(changed.origin == origin)
        #expect(changed.name == "Title")
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Edit Text")
        #expect(recorded(result) == true)
        #expect(result["text"]?.objectValue?["content"]?.stringValue == "Hello, longer world")
        let again = try await MCPTestSupport.call("set_text", ["layer": "Title", "text": "Hello, longer world"], in: workspace)
        #expect(recorded(again) == false && session.history.undoCount == before + 1)
        session.undo()
        #expect(layer(session, id)?.liveText?.style.content == "Hello")
    }

    @Test func setTextStylePatchesOnlyWhatIsGiven() async throws {
        let (workspace, session, id) = try await titleWorkspace()
        let before = session.history.undoCount
        try await MCPTestSupport.call("set_text_style", ["layer": "Title", "style": ["font_size": 30, "color": ["r": 0, "g": 0, "b": 1]]],
                                      in: workspace)
        var style = try #require(layer(session, id)?.liveText?.style)
        #expect(style.fontSize == 30 && style.red == 0 && style.green == 0 && style.blue == 1)
        #expect(style.content == "Hello" && style.fontName == "Helvetica" && style.alignment == .left)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Edit Text")

        let boxed = try await MCPTestSupport.call("set_text_style", ["layer": "Title", "style": ["box_size": ["width": 300, "height": 80]]],
                                                  in: workspace)
        style = try #require(layer(session, id)?.liveText?.style)
        #expect(style.boxSize == CGSize(width: 300, height: 80))
        #expect(layer(session, id)?.transform.size == CGSize(width: 300, height: 80))
        #expect(boxed["text"]?.objectValue?["box_size"]?.objectValue?["height"].flatMap(MCPValues.number) == 80)
        try await MCPTestSupport.call("set_text_style", ["layer": "Title", "style": ["box_size": nil]], in: workspace)
        style = try #require(layer(session, id)?.liveText?.style)
        #expect(style.boxSize == nil)
        #expect(layer(session, id)?.transform.size == EditorSession.textBoxSize(style))

        let same = try await MCPTestSupport.call("set_text_style", ["layer": "Title", "style": ["font_size": 30]], in: workspace)
        #expect(recorded(same) == false)
        let failed = try await MCPTestSupport.call("set_text_style", ["layer": "Title", "style": ["tracking": 5000]], in: workspace,
                                                   expectError: "invalid_argument")
        #expect(message(failed).contains("'tracking' is 5000") && message(failed).contains("-100–1000"), "\(message(failed))")
        try await MCPTestSupport.call("set_text_style", ["layer": "Title", "style": ["alignment": "justified"]], in: workspace,
                                      expectError: "invalid_argument")
        try await MCPTestSupport.call("set_text_style", ["layer": "Title", "style": ["content": " \n"]], in: workspace,
                                      expectError: "invalid_argument")
        try await MCPTestSupport.call("set_text_style", ["layer": "Title", "style": ["color": "#00ff00", "red": 1]], in: workspace,
                                      expectError: "invalid_argument")
        #expect(layer(session, id)?.liveText?.style.fontSize == 30)
    }

    @Test func getLayerReportsTheStyleSetTextStyleTakes() async throws {
        let (workspace, session, id) = try await titleWorkspace()
        try await MCPTestSupport.call("set_text_style", ["layer": "Title", "style": ["alignment": "right", "box_size": ["width": 320, "height": 90]]],
                                      in: workspace)
        let described = try await MCPTestSupport.call("get_layer", ["layer": "Title"], in: workspace)
        let text = try #require(described["layer"]?.objectValue?["text"]?.objectValue)
        #expect(text["font_name"]?.stringValue == "Helvetica" && text["alignment"]?.stringValue == "right")
        #expect(text["box_size"]?.objectValue?["width"].flatMap(MCPValues.number) == 320)
        #expect(text["fontName"] == nil)
        let before = session.history.undoCount
        let roundTrip = try await MCPTestSupport.call("set_text_style", ["layer": "Title", "style": .object(text)], in: workspace)
        #expect(recorded(roundTrip) == false && session.history.undoCount == before)
        #expect(layer(session, id)?.liveText?.style.boxSize == CGSize(width: 320, height: 90))
    }

    // MARK: Edits keep the text's anchor

    /// Where an upright, unscaled point-text layer's text hangs from on the document: its first baseline's y, and the
    /// x of its alignment point — the left end of its lines, their middle or their right end, inside the 12-pixel
    /// padding.
    private func pointTextAnchor(_ layer: ImageLayer) throws -> CGPoint {
        let style = try #require(layer.liveText?.style)
        let box = layer.transform
        let padding = LayerTextStyle.padding
        let x: CGFloat = switch style.alignment {
        case .left: box.origin.x + padding
        case .center: box.origin.x + box.size.width / 2
        case .right: box.origin.x + box.size.width - padding
        }
        return CGPoint(x: x, y: box.origin.y + EditorSession.textMetrics(style).firstBaseline)
    }

    /// Photoshop keeps a point-text layer's anchor through an edit: centered text that gets longer grows both ways
    /// instead of drifting right, and the first baseline stays where it was whatever the new size or font.
    @Test(arguments: ["left", "center", "right"])
    func textEditsKeepThePointTextsAlignmentAnchor(alignment: String) async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        let added = try await MCPTestSupport.call("add_text_layer", [
            "text": "Name", "x": 320, "y": 200, "anchor": "center", "style": ["alignment": .string(alignment), "font_size": 48],
        ], in: workspace)
        let id = try id(added)
        let selector = Value.string(id.uuidString)
        let start = try #require(layer(session, id))
        let anchor = try pointTextAnchor(start)
        func expectAnchorKept(after step: String) throws {
            let now = try pointTextAnchor(try #require(layer(session, id)))
            #expect(abs(now.x - anchor.x) < 0.001 && abs(now.y - anchor.y) < 0.001, "\(alignment) after \(step): \(now), was \(anchor)")
        }

        try await MCPTestSupport.call("set_text", ["layer": selector, "text": "A much longer name"], in: workspace)
        #expect(layer(session, id)?.transform.size.width != start.transform.size.width)
        try expectAnchorKept(after: "set_text")
        try await MCPTestSupport.call("set_text_style", ["layer": selector, "style": ["font_size": 64, "tracking": 20]], in: workspace)
        try expectAnchorKept(after: "set_text_style (size and tracking)")
        try await MCPTestSupport.call("set_text_style", ["layer": selector, "style": ["font_name": "Helvetica-Bold"]], in: workspace)
        try expectAnchorKept(after: "set_text_style (font)")
        try await MCPTestSupport.call("fit_text", ["layer": selector, "max_width": 150], in: workspace)
        #expect((layer(session, id)?.liveText?.style.fontSize ?? 64) < 64)
        try expectAnchorKept(after: "fit_text")
    }

    /// Paragraph text keeps its box's top-left corner, as in Photoshop: the box is what the text is laid out in.
    @Test func textEditsKeepAParagraphsBoxTopLeft() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        let added = try await MCPTestSupport.call("add_text_layer", [
            "text": "A paragraph", "x": 100, "y": 80,
            "style": ["alignment": "center", "font_size": 30, "box_size": ["width": 300, "height": 200]],
        ], in: workspace)
        let id = try id(added)
        let selector = Value.string(id.uuidString)
        let origin = try #require(layer(session, id)?.transform.origin)
        try await MCPTestSupport.call("set_text", ["layer": selector, "text": "A paragraph that is a good deal longer than it was"],
                                      in: workspace)
        #expect(layer(session, id)?.transform.origin == origin)
        try await MCPTestSupport.call("set_text_style", ["layer": selector, "style": ["font_size": 40, "alignment": "right"]],
                                      in: workspace)
        #expect(layer(session, id)?.transform.origin == origin)
        #expect(layer(session, id)?.transform.size == CGSize(width: 300, height: 200))
    }

    // MARK: Imported Photoshop text

    /// A workspace holding the text Photoshop's type block `block` imports as ("Title", over a stand-in raster at
    /// `bounds`, scaled by `scale`), still waiting for its first edit.
    private func importedWorkspace(_ block: Data, bounds: CGRect,
                                   scale: CGFloat = 1) async throws -> (workspace: ProjectWorkspace, session: EditorSession, id: UUID) {
        func raster(_ width: Int, _ height: Int) throws -> CGImage {
            let context = try BrushRaster.context(width: width, height: height, mask: false)
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 2, y: 2, width: width - 4, height: height - 4))
            return try #require(context.makeImage())
        }
        let workspace = MCPTestSupport.workspace()
        var record = PSDRecord(id: UUID(), name: "Title")
        record.bounds = bounds
        record.image = try raster(Int(bounds.width), Int(bounds.height))
        record.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "TySh", data: block)])
        let data = try PSDFixture.data(PSDDocument(width: 640, height: 480, resolution: 72, layers: [record]),
                                       composite: try raster(640, 480))
        let session = workspace.current.session
        try session.insertPhotoshop(try PSDDocumentBuilder.makeImport(try PSDReader.read(data)), named: "Fixture")
        let index = try #require(session.document?.layers.firstIndex { $0.name == "Title" })
        session.document?.layers[index].transform.size.width *= scale
        session.document?.layers[index].transform.size.height *= scale
        let layer = try #require(session.document?.layers[index])
        #expect(layer.liveText != nil && layer.psdExtras?.importedTextAnchor != nil)
        return (workspace, session, layer.id)
    }

    /// The ink (alpha > 0) of an unrotated, unflipped `layer`, in document pixels.
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

    /// Where the letters of the imported text land when it is first drawn again as it is (by Photoshop's anchor):
    /// measured on a recolored copy, then undone.
    private func inkAtTheImportedAnchor(_ workspace: ProjectWorkspace, _ session: EditorSession, _ id: UUID) async throws -> CGRect {
        try await MCPTestSupport.call("set_text_style", ["layer": "Title", "style": ["color": "#ff0000"]], in: workspace)
        let placed = try ink(try #require(layer(session, id)))
        session.undo()
        #expect(layer(session, id)?.psdExtras?.importedTextAnchor != nil)
        return placed
    }

    private func isNear(_ a: CGRect, _ b: CGRect, within tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
    }

    /// Photoshop anchors point text by its first baseline, at the alignment point. Making it a box before its first
    /// edit keeps the corner the text has there, as the editor's handles do, so the letters don't drop an ascent or
    /// slide sideways by the alignment; making it point text again keeps them there too.
    @Test(arguments: [(0, 1.0), (2, 1.0), (1, 1.0), (2, 2.0)])
    func setTextStyleMakesImportedPointTextABoxInPlace(justification: Int, scale: Double) async throws {
        let block = PSDFixture.typeToolBlock(text: "HH", font: "Helvetica", fontSize: 40, justification: justification,
                                             transform: [1, 0, 0, 1, 300, 150])
        let (workspace, session, id) = try await importedWorkspace(block, bounds: CGRect(x: 250, y: 118, width: 100, height: 40),
                                                                   scale: scale)
        let expected = try await inkAtTheImportedAnchor(workspace, session, id)
        // "HH" sits on Photoshop's baseline, 32 pixels down the layer.
        #expect(abs(expected.maxY - (118 + 32 * scale)) <= 1.5 * scale, "\(expected)")
        let style = try #require(layer(session, id)?.liveText?.style)
        #expect(style.boxSize == nil)
        let box = EditorSession.textBoxSize(style)
        let before = session.history.undoCount
        try await MCPTestSupport.call("set_text_style", ["layer": "Title",
                                                         "style": ["box_size": ["width": .double(box.width), "height": .double(box.height)]]],
                                      in: workspace)
        var changed = try #require(layer(session, id))
        #expect(changed.liveText?.style.boxSize == box)
        #expect(changed.psdExtras?.importedTextAnchor == nil)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Edit Text")
        let boxed = try ink(changed)
        #expect(isNear(boxed, expected, within: 1), "\(boxed) vs \(expected)")

        try await MCPTestSupport.call("set_text_style", ["layer": "Title", "style": ["box_size": nil]], in: workspace)
        changed = try #require(layer(session, id))
        #expect(changed.liveText?.style.boxSize == nil)
        let pointed = try ink(changed)
        #expect(isNear(pointed, expected, within: 1), "\(pointed) vs \(expected)")
        session.undo()
        session.undo()
        #expect(layer(session, id)?.psdExtras?.importedTextAnchor != nil)
    }

    /// Photoshop anchors paragraph text by its box's top-left corner. Making it point text before its first edit keeps
    /// the corner the box has there, so the first line doesn't jump up onto the corner by its baseline.
    @Test func setTextStyleMakesImportedParagraphTextPointTextInPlace() async throws {
        let block = PSDFixture.typeToolBlock(text: "HH", font: "Helvetica", fontSize: 40, transform: [1, 0, 0, 1, 200, 100],
                                             box: CGRect(x: 0, y: 0, width: 300, height: 120))
        let (workspace, session, id) = try await importedWorkspace(block, bounds: CGRect(x: 198, y: 104, width: 70, height: 36))
        #expect(layer(session, id)?.liveText?.style.boxSize != nil)
        let expected = try await inkAtTheImportedAnchor(workspace, session, id)
        // The box's corner is at (200, 100): the letters hang below it.
        #expect(expected.minY > 100 && expected.minY < 115 && expected.minX >= 200 && expected.minX < 206, "\(expected)")
        try await MCPTestSupport.call("set_text_style", ["layer": "Title", "style": ["box_size": nil]], in: workspace)
        let changed = try #require(layer(session, id))
        #expect(changed.liveText?.style.boxSize == nil)
        #expect(changed.psdExtras?.importedTextAnchor == nil)
        let placed = try ink(changed)
        #expect(isNear(placed, expected, within: 1), "\(placed) vs \(expected)")
    }

    @Test func textEditsRefuseLockAllAndNonTextLayers() async throws {
        let (workspace, session, id) = try await titleWorkspace()
        try await MCPTestSupport.call("set_layer_locks", ["layer": "Title", "all": true], in: workspace)
        for (tool, args) in [("set_text", ["text": "Locked"]), ("set_text_style", ["style": ["font_size": 20]]),
                             ("fit_text", ["max_width": 50])] as [(String, [String: Value])] {
            var arguments = args
            arguments["layer"] = "Title"
            let result = try await MCPTestSupport.call(tool, arguments, in: workspace, expectError: "precondition_failed")
            #expect(error(result)["guard"]?.stringValue == "layer_locked", "\(tool)")
        }
        try await MCPTestSupport.call("set_layer_locks", ["layer": "Title", "all": false], in: workspace)
        // Held by a folder's Lock All too.
        let folder = try await MCPTestSupport.call("group_layers", ["layers": ["Title"], "name": "Locked folder"], in: workspace)
        try await MCPTestSupport.call("set_layer_locks", ["layer": try #require(folder["group_id"]), "all": true], in: workspace)
        let inherited = try await MCPTestSupport.call("set_text", ["layer": "Title", "text": "Locked"], in: workspace,
                                                      expectError: "precondition_failed")
        #expect(error(inherited)["guard"]?.stringValue == "layer_locked")
        // Position and pixel locks leave type editable.
        try await MCPTestSupport.call("set_layer_locks", ["layer": try #require(folder["group_id"]), "all": false], in: workspace)
        try await MCPTestSupport.call("set_layer_locks", ["layer": "Title", "pixels": true, "position": true], in: workspace)
        try await MCPTestSupport.call("set_text", ["layer": "Title", "text": "Still editable"], in: workspace)
        #expect(layer(session, id)?.liveText?.style.content == "Still editable")

        try await MCPTestSupport.call("add_blank_layer", ["name": "Pixels"], in: workspace)
        let notText = try await MCPTestSupport.call("set_text", ["layer": "Pixels", "text": "No"], in: workspace, expectError: "precondition_failed")
        #expect(error(notText)["guard"]?.stringValue == "is_text")
        try await MCPTestSupport.call("get_text_metrics", ["layer": "Pixels"], in: workspace, expectError: "precondition_failed")
        // A Photoshop placeholder is named as one first.
        var placeholder = ImageLayer(name: "Brightness Contrast 1", blankSize: CGSize(width: 32, height: 32))
        placeholder.isVisible = false
        placeholder.psdExtras = PSDLayerExtras(importedVisible: true, placeholder: "adjustment:brit")
        session.document?.layers.append(placeholder)
        let held = try await MCPTestSupport.call("set_text_style", ["layer": "Brightness Contrast 1", "style": ["font_size": 20]],
                                                 in: workspace, expectError: "precondition_failed")
        #expect(error(held)["guard"]?.stringValue == "placeholder")
    }

    // MARK: fit_text

    @Test func fitTextKeepsTheMeasuredWidthWithinMaxWidth() async throws {
        let (workspace, session, id) = try await titleWorkspace("Wide headline")
        try await MCPTestSupport.call("set_text_style", ["layer": "Title", "style": ["leading": 100, "tracking": 10]], in: workspace)
        let before = session.history.undoCount
        let result = try await MCPTestSupport.call("fit_text", ["layer": "Title", "max_width": 100], in: workspace)
        let style = try #require(layer(session, id)?.liveText?.style)
        #expect(style.fontSize < 72 && style.fontSize >= 1)
        #expect(MCPValues.number(result["font_size"]) == Double(style.fontSize))
        #expect(MCPValues.number(result["previous_font_size"]) == 72)
        #expect(abs(style.leading - 100 * style.fontSize / 72) < 0.001)
        #expect(abs(style.tracking - 10 * style.fontSize / 72) < 0.001)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Fit Text")
        let metrics = try await MCPTestSupport.call("get_text_metrics", ["layer": "Title"], in: workspace)
        let width = try #require(MCPValues.number(metrics["width"]))
        #expect(width <= 100 && width > 80, "\(width)")
        // A size 0.1 larger would not fit.
        var larger = style
        larger.fontSize += 0.1
        larger.leading = 100 * larger.fontSize / 72
        larger.tracking = 10 * larger.fontSize / 72
        #expect(EditorSession.textBoxSize(larger).width - 2 * LayerTextStyle.padding > 100)

        let fits = try await MCPTestSupport.call("fit_text", ["layer": "Title", "max_width": 1000], in: workspace)
        #expect(recorded(fits) == false && MCPValues.number(fits["font_size"]) == Double(style.fontSize))
        try await MCPTestSupport.call("fit_text", ["layer": "Title", "max_width": 1], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("set_text_style", ["layer": "Title", "style": ["box_size": ["width": 300, "height": 200]]], in: workspace)
        let boxed = try await MCPTestSupport.call("fit_text", ["layer": "Title", "max_width": 100], in: workspace, expectError: "precondition_failed")
        #expect(error(boxed)["guard"]?.stringValue == "point_text")
    }

    @Test func fitTextMeasuresInDocumentPixelsOnAScaledLayer() async throws {
        let (workspace, session, id) = try await titleWorkspace("Scaled headline")
        try await MCPTestSupport.call("set_layer_scale", ["layer": "Title", "percent": 50], in: workspace)
        try await MCPTestSupport.call("fit_text", ["layer": "Title", "max_width": 100], in: workspace)
        let fitted = try #require(layer(session, id))
        let style = try #require(fitted.liveText?.style)
        let scale = fitted.transform.size.width / CGFloat(try #require(fitted.asset?.image.width))
        #expect(abs(scale - 0.5) < 0.01)
        #expect((EditorSession.textBoxSize(style).width - 2 * LayerTextStyle.padding) * scale <= 100)
        #expect((EditorSession.textBoxSize(style).width - 2 * LayerTextStyle.padding) * scale > 80)
    }

    // MARK: get_text_metrics

    @Test func getTextMetricsMeasuresALayerOrAStyle() async throws {
        let (workspace, _, id) = try await titleWorkspace("Two\nlines")
        let metrics = try await MCPTestSupport.call("get_text_metrics", ["layer": "Title"], in: workspace)
        #expect(metrics["layer_id"]?.stringValue == id.uuidString)
        let lines = try #require(metrics["lines"]?.arrayValue)
        #expect(lines.map { $0.objectValue?["text"]?.stringValue } == ["Two", "lines"])
        let baselines = lines.compactMap { MCPValues.number($0.objectValue?["baseline"]) }
        #expect(baselines.count == 2 && abs(baselines[1] - baselines[0] - 72 * 1.2) < 0.5)
        #expect(MCPValues.number(metrics["line_height"]) == 72 * 1.2)
        let font = try #require(NSFont(name: "Helvetica", size: 72))
        #expect(abs((MCPValues.number(metrics["ascent"]) ?? 0) - Double(font.ascender)) < 0.001)
        #expect(abs((MCPValues.number(metrics["descent"]) ?? 0) + Double(font.descender)) < 0.001)
        #expect(metrics["font_available"] == .bool(true) && metrics["font_used"]?.stringValue == "Helvetica")
        #expect(metrics["overflows"] == .bool(false))
        #expect(metrics["bounds"]?.objectValue != nil && MCPValues.number(metrics["scale"]?.objectValue?["x"]) == 1)

        let styled = try await MCPTestSupport.call("get_text_metrics", [
            "text": "Wide", "style": ["font_size": 20, "horizontal_scale": 2, "font_name": "NoSuchSlab-Medium"],
        ], in: workspace)
        #expect(styled["layer_id"] == nil)
        #expect(styled["font_available"] == .bool(false))
        #expect(styled["font_used"]?.stringValue != "NoSuchSlab-Medium" && styled["font_used"]?.stringValue?.isEmpty == false)
        var plain = LayerTextStyle()
        plain.content = "Wide"; plain.fontName = "NoSuchSlab-Medium"; plain.fontSize = 20
        let plainWidth = EditorSession.textLayoutMetrics(plain).size.width
        #expect(abs((MCPValues.number(styled["width"]) ?? 0) - 2 * Double(plainWidth)) < 1)
        try await MCPTestSupport.call("get_text_metrics", ["style": ["font_size": 20]], in: workspace, expectError: "invalid_argument")

        let overflow = try await MCPTestSupport.call("get_text_metrics", [
            "text": "Far too much text for a small box to hold", "style": ["box_size": ["width": 60, "height": 40]],
        ], in: workspace)
        #expect(overflow["overflows"] == .bool(true))
    }

    // MARK: Fonts

    @Test func checkFontsReportsAvailableAndSubstitutedFonts() async throws {
        let workspace = MCPTestSupport.workspace()
        try await MCPTestSupport.call("add_text_layer", ["text": "Missing", "x": 0, "y": 0, "name": "Missing",
                                                         "style": ["font_name": "NoSuchGrotesk-Black"]], in: workspace)
        let result = try await MCPTestSupport.call("check_fonts", ["names": ["Helvetica-Bold", "NoSuchGrotesk-Black", "HelveticaNeue-NoSuchCut"]],
                                                   in: workspace)
        let fonts = (result["fonts"]?.arrayValue ?? []).compactMap { $0.objectValue }
        #expect(fonts.count == 3)
        #expect(fonts[0]["name"]?.stringValue == "Helvetica-Bold" && fonts[0]["available"] == .bool(true))
        #expect(fonts[0]["substitute"] == .null && fonts[0]["family_match"] == .bool(true))
        #expect(fonts[1]["available"] == .bool(false) && fonts[1]["family_match"] == .bool(false))
        let substitute = try #require(fonts[1]["substitute"]?.stringValue)
        #expect(substitute != "NoSuchGrotesk-Black" && NSFont(name: substitute, size: 12) != nil)
        #expect(fonts[2]["available"] == .bool(false) && fonts[2]["family_match"] == .bool(true))
        #expect(fonts[2]["substitute"]?.stringValue?.hasPrefix("HelveticaNeue") == true)
        let missing = (result["document_missing"]?.arrayValue ?? []).compactMap { $0.objectValue }
        #expect(missing.count == 1)
        #expect(missing.first?["layer_name"]?.stringValue == "Missing" && missing.first?["requested"]?.stringValue == "NoSuchGrotesk-Black")
        try await MCPTestSupport.call("check_fonts", ["names": []], in: workspace, expectError: "invalid_argument")
    }

    @Test func listFontsFiltersByQueryAndLimit() async throws {
        let workspace = MCPTestSupport.workspace()
        let result = try await MCPTestSupport.call("list_fonts", ["query": "helvetica bold", "limit": 3], in: workspace)
        let fonts = (result["fonts"]?.arrayValue ?? []).compactMap { $0.objectValue }
        #expect(!fonts.isEmpty && fonts.count <= 3)
        for font in fonts {
            let family = font["family"]?.stringValue ?? "", style = font["style"]?.stringValue ?? ""
            let name = font["postscript_name"]?.stringValue ?? ""
            #expect((family + style + name).lowercased().contains("helvetica"), "\(font)")
            #expect(NSFont(name: name, size: 12) != nil)
        }
        #expect(fonts.contains { $0["postscript_name"]?.stringValue == "Helvetica-Bold" })
        let total = try #require(result["total"]?.intValue)
        #expect(total >= fonts.count && result["truncated"] == .bool(total > fonts.count))
        let all = try await MCPTestSupport.call("list_fonts", [:], in: workspace)
        #expect((all["fonts"]?.arrayValue?.count ?? 0) <= 200)
        try await MCPTestSupport.call("list_fonts", ["limit": 0], in: workspace, expectError: "invalid_argument")
    }
}
