import AppKit
import Foundation
import Testing
import MCP
@testable import Compositor

/// The shape tools: `add_shape` draws a live rectangle, ellipse or line (with an optional stroke) as one undo step, and
/// `set_shape_style` restyles a live shape through `decodeMerged` as one "Edit Shape" step, keeping it live.
@MainActor struct MCPShapesToolTests {
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

    /// The flattened document, and a reader for one pixel's RGBA.
    private func pixels(_ session: EditorSession) async throws -> (Int, Int) -> [Int] {
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                              count: image.width * image.height * 4))
        let width = image.width
        return { x, y in (0..<4).map { Int(bytes[(y * width + x) * 4 + $0]) } }
    }

    /// A workspace whose document holds only a transparent layer, so a shape's pixels are all that is drawn.
    private func clearWorkspace() -> ProjectWorkspace {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        if let size = session.document?.size { session.document?.layers = [ImageLayer(name: "Layer 1", blankSize: size)] }
        session.activeLayerID = session.document?.layers.first?.id
        return workspace
    }

    /// A workspace holding one live red 200 × 100 rectangle named "Box" at (100, 100).
    private func boxWorkspace() async throws -> (workspace: ProjectWorkspace, session: EditorSession, id: UUID) {
        let workspace = clearWorkspace()
        let result = try await MCPTestSupport.call("add_shape", [
            "kind": "rectangle", "rect": ["x": 100, "y": 100, "width": 200, "height": 100], "color": "#ff0000", "name": "Box",
        ], in: workspace)
        return (workspace, workspace.current.session, try id(result))
    }

    // MARK: add_shape

    @Test func addSolidFillCoversTheCanvasAndCanBeRestyled() async throws {
        let workspace = MCPTestSupport.workspace(width: 24, height: 16)
        let session = workspace.current.session
        let before = session.history.undoCount
        let result = try await MCPTestSupport.call("add_solid_fill", ["color": "#336699"], in: workspace)
        let id = try self.id(result)
        let added = try #require(layer(session, id))
        #expect(added.name == "Solid Color Fill 1")
        #expect(added.liveShape?.style.color == PaletteColor(red: 0x33 / 255, green: 0x66 / 255, blue: 0x99 / 255))
        #expect(added.transform == LayerTransform(origin: .zero, size: CGSize(width: 24, height: 16)))
        #expect(session.history.undoCount == before + 1 && recorded(result) == true)
        let pixel = try await pixels(session)
        #expect(pixel(0, 0) == [51, 102, 153, 255] && pixel(23, 15) == [51, 102, 153, 255])
        try await MCPTestSupport.call("set_shape_style", ["layer": .string(id.uuidString), "color": .string("#ff0000")], in: workspace)
        let restyled = try await pixels(session)
        #expect(restyled(12, 8) == [255, 0, 0, 255])
    }

    @Test func addShapeRoundsARectanglesCornersAsOneStep() async throws {
        let workspace = clearWorkspace()
        let session = workspace.current.session
        session.foregroundColor = PaletteColor(red: 0, green: 0, blue: 1)
        let before = session.history.undoCount
        let result = try await MCPTestSupport.call("add_shape", [
            "kind": "Rectangle", "rect": ["x": 100, "y": 100, "width": 200, "height": 100], "corner_radius": 30,
        ], in: workspace)
        let added = try #require(layer(session, try id(result)))
        #expect(added.name == "Rectangle 1" && result["name"]?.stringValue == "Rectangle 1")
        #expect(added.transform.origin == CGPoint(x: 100, y: 100) && added.transform.size == CGSize(width: 200, height: 100))
        let style = try #require(added.liveShape?.style)
        #expect(style.kind == .rectangle && style.cornerRadius == 30 && style.blue == 1 && style.red == 0, "the foreground color by default")
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Rectangle" && recorded(result) == true)
        let pixel = try await pixels(session)
        #expect(pixel(100, 100)[3] == 0, "the rounded corner is transparent")
        #expect(pixel(103, 103)[3] == 0)
        #expect(pixel(200, 150) == [0, 0, 255, 255] && pixel(200, 100) == [0, 0, 255, 255] && pixel(100, 150) == [0, 0, 255, 255])
        let shape = try #require(result["shape"]?.objectValue)
        #expect(shape["kind"]?.stringValue == "rectangle" && MCPValues.number(shape["corner_radius"]) == 30)
        #expect(MCPValues.number(result["transform"]?.objectValue?["width"]) == 200)
    }

    @Test func addShapeDrawsEllipsesAndLines() async throws {
        let workspace = clearWorkspace()
        let session = workspace.current.session
        let ellipse = try await MCPTestSupport.call("add_shape", [
            "kind": "ellipse", "rect": ["x": 10, "y": 20, "width": 100, "height": 60], "color": ["r": 0, "g": 1, "b": 0], "name": "Dot",
        ], in: workspace)
        let oval = try #require(layer(session, try id(ellipse)))
        #expect(oval.name == "Dot" && oval.liveShape?.style.kind == .ellipse && oval.liveShape?.style.green == 1)
        #expect(oval.transform.origin == CGPoint(x: 10, y: 20) && oval.transform.size == CGSize(width: 100, height: 60))

        let line = try await MCPTestSupport.call("add_shape", [
            "kind": "line", "start": ["x": 300, "y": 200], "end": ["x": 400, "y": 250], "line_width": 6, "color": "background",
        ], in: workspace)
        let drawn = try #require(layer(session, try id(line)))
        #expect(drawn.name == "Line 1")
        #expect(drawn.transform.origin == CGPoint(x: 297, y: 197) && drawn.transform.size == CGSize(width: 106, height: 56))
        let style = try #require(drawn.liveShape?.style)
        #expect(style.kind == .line && style.lineWidth == 6)
        #expect(style.red == session.backgroundColor.red && style.green == session.backgroundColor.green)
        let reported = try #require(line["shape"]?.objectValue)
        #expect(reported["kind"]?.stringValue == "line" && MCPValues.number(reported["line_width"]) == 6)
        #expect(MCPValues.number(reported["start"]?.objectValue?["x"]).map { abs($0 - 3.0 / 106) < 1e-9 } == true)

        // The default weight is 4.
        let thin = try await MCPTestSupport.call("add_shape", ["kind": "line", "start": ["x": 0, "y": 10], "end": ["x": 50, "y": 10]],
                                                 in: workspace)
        #expect(layer(session, try id(thin))?.liveShape?.style.lineWidth == 4)
        #expect(layer(session, try id(thin))?.transform.size == CGSize(width: 54, height: 4))
    }

    /// A stroke is drawn around the shape, so the layer's box grows to hold it while the shape itself fills the rect
    /// given; still one undo step.
    @Test func addShapeWithAStrokeKeepsTheShapeOnTheRect() async throws {
        let workspace = clearWorkspace()
        let session = workspace.current.session
        let before = session.history.undoCount
        let result = try await MCPTestSupport.call("add_shape", [
            "kind": "rectangle", "rect": ["x": 100, "y": 100, "width": 200, "height": 100], "color": "#ff0000",
            "stroke": ["width": 10, "color": "#0000ff", "alignment": "Outside"],
        ], in: workspace)
        let added = try #require(layer(session, try id(result)))
        #expect(added.transform.origin == CGPoint(x: 90, y: 90) && added.transform.size == CGSize(width: 220, height: 120))
        let stroke = try #require(added.liveShape?.style.stroke)
        #expect(stroke == ShapeStroke(enabled: true, width: 10, red: 0, green: 0, blue: 1, alignment: .outside))
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Rectangle")
        let pixel = try await pixels(session)
        #expect(pixel(95, 150) == [0, 0, 255, 255] && pixel(100, 150) == [255, 0, 0, 255] && pixel(89, 150)[3] == 0)
        let reported = try #require(result["shape"]?.objectValue?["stroke"]?.objectValue)
        #expect(reported["alignment"]?.stringValue == "outside" && MCPValues.number(reported["width"]) == 10)
        session.undo()
        #expect(session.document?.layers.count == 1)
    }

    @Test func addShapeRefusesBadArguments() async throws {
        let workspace = clearWorkspace()
        let session = workspace.current.session
        let before = session.history.undoCount
        let rect: Value = ["x": 10, "y": 10, "width": 50, "height": 40]
        let cases: [(args: [String: Value], mentions: String)] = [
            (["rect": rect], "kind"),
            (["kind": "triangle", "rect": rect], "rectangle"),
            (["kind": "rectangle"], "rect"),
            (["kind": "rectangle", "rect": ["x": 10, "y": 10, "width": 0.2, "height": 40]], "rect"),
            (["kind": "line", "start": ["x": 0, "y": 0]], "end"),
            (["kind": "line", "rect": rect], "start"),
            (["kind": "ellipse", "rect": rect, "start": ["x": 0, "y": 0], "end": ["x": 5, "y": 5]], "start"),
            (["kind": "ellipse", "rect": rect, "corner_radius": 8], "corner_radius"),
            (["kind": "rectangle", "rect": rect, "line_width": 8], "line_width"),
            (["kind": "rectangle", "rect": rect, "corner_radius": 6000], "0–5000"),
            (["kind": "line", "start": ["x": 0, "y": 0], "end": ["x": 5, "y": 5], "line_width": 0], "1–5000"),
            (["kind": "line", "start": ["x": 0, "y": 0], "end": ["x": 5, "y": 5], "stroke": ["width": 2]], "line_width"),
            (["kind": "rectangle", "rect": rect, "color": ["r": 2, "g": 0, "b": 0]], "color.r"),
            (["kind": "rectangle", "rect": rect, "stroke": ["width": 900]], "stroke.width"),
            (["kind": "rectangle", "rect": rect, "stroke": ["alignment": "middle"]], "stroke.alignment"),
            (["kind": "rectangle", "rect": rect, "stroke": ["dash": 2]], "stroke.dash"),
            (["kind": "rectangle", "rect": ["x": 0, "y": 0, "width": 20_000, "height": 20_000]], "\(DocumentLimits.maxSurfaceMegapixels) megapixels"),
            (["kind": "rectangle", "rect": ["x": 5_000_000, "y": 0, "width": 20, "height": 20]], "1,000,000"),
        ]
        for (args, mentions) in cases {
            let result = try await MCPTestSupport.call("add_shape", args, in: workspace, expectError: "invalid_argument")
            #expect(message(result).contains(mentions), "\(args): \(message(result))")
        }
        let range = try await MCPTestSupport.call("add_shape", ["kind": "rectangle", "rect": rect, "stroke": ["width": 900]], in: workspace,
                                                  expectError: "invalid_argument")
        #expect(message(range).contains("0–500"), "\(message(range))")
        #expect(error(range)["details"]?.objectValue?["field"]?.stringValue == "stroke.width")
        #expect(session.history.undoCount == before && session.document?.layers.count == 1)
    }

    @Test func addShapeGoesAboveTheOutermostLockAllFolderAndStopsAtTheLayerCap() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        let outer = try #require(try await MCPTestSupport.call("add_group", ["name": "Outer"], in: workspace)["group_id"]?.stringValue)
        try await MCPTestSupport.call("add_group", ["name": "Inner"], in: workspace)
        try await MCPTestSupport.call("add_blank_layer", ["name": "Deep"], in: workspace)
        try await MCPTestSupport.call("set_layer_locks", ["layer": .string(outer), "all": true], in: workspace)
        try await MCPTestSupport.call("select_layers", ["layers": ["Deep"]], in: workspace)
        let before = session.history.undoCount
        let result = try await MCPTestSupport.call("add_shape", ["kind": "ellipse", "rect": ["x": 10, "y": 10, "width": 30, "height": 30]],
                                                   in: workspace)
        let document = try #require(session.document)
        let added = try #require(layer(session, try id(result)))
        #expect(added.parentID == nil)
        let topLevel = document.layers.filter { $0.parentID == nil }.map(\.id)
        #expect(topLevel.last == added.id && topLevel.dropLast().last?.uuidString == outer)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Ellipse")

        let full = MCPTestSupport.workspace(width: 32, height: 32)
        let size = try #require(full.current.session.document?.size)
        full.current.session.document?.layers = (0..<10_000).map { ImageLayer(name: "Layer \($0)", blankSize: size) }
        let capped = try await MCPTestSupport.call("add_shape", ["kind": "rectangle", "rect": ["x": 0, "y": 0, "width": 8, "height": 8]],
                                                   in: full, expectError: "precondition_failed")
        #expect(error(capped)["guard"]?.stringValue == "max_layers")
        #expect(full.current.session.document?.layers.count == 10_000)
    }

    /// A part of add_shape that fails after the layer is added (here its stroke pushing the box past the ±1,000,000-pixel
    /// limit) leaves the layers, the active and selected layers and history as they were.
    @Test func addShapeThatFailsAfterAddingItPutsTheSelectionBack() async throws {
        let workspace = clearWorkspace()
        let session = workspace.current.session
        try await MCPTestSupport.call("add_blank_layer", ["name": "Top"], in: workspace)
        try await MCPTestSupport.call("select_layers", ["layers": ["Layer 1", "Top"]], in: workspace)
        let selected = session.selectedLayerIDs, active = session.activeLayerID
        let layers = session.document?.layers.map(\.id)
        #expect(selected.count == 2)
        let before = session.history.undoCount
        let result = try await MCPTestSupport.call("add_shape", [
            "kind": "rectangle", "rect": ["x": -999_998, "y": 0, "width": 4, "height": 4], "stroke": ["width": 10, "alignment": "outside"],
        ], in: workspace, expectError: "invalid_argument")
        #expect(message(result).contains("1,000,000"), "\(message(result))")
        #expect(session.document?.layers.map(\.id) == layers)
        #expect(session.activeLayerID == active && session.selectedLayerIDs == selected)
        #expect(session.history.undoCount == before)
    }

    /// The add-layer step add_text_layer and add_shape share also puts the folders' collapsed state back when a part fails.
    @Test func addLayerInOneStepPutsCollapsedFoldersBackWhenAPartFails() async throws {
        let workspace = clearWorkspace()
        let session = workspace.current.session
        let group = try await MCPTestSupport.call("add_group", ["name": "Folder"], in: workspace)
        let folder = try #require(group["group_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        session.activeLayerID = folder
        session.collapsedGroupIDs = [folder]
        let document = try #require(session.document)
        let before = session.history.undoCount
        let ctx = MCPCallContext(workspace: workspace, tab: workspace.current, args: MCPToolRegistry.Args([:]))
        #expect(throws: MCPToolError.self) {
            try MCPToolRegistry.addLayerInOneStep(ctx, document: document, editName: "Test", name: "Added") {
                // Adding into a collapsed folder opens it.
                session.addBlankLayer()
                throw MCPToolError.invalidArgument("A part failed.")
            }
        }
        #expect(session.document?.layers.map(\.id) == document.layers.map(\.id))
        #expect(session.activeLayerID == folder && session.collapsedGroupIDs == [folder])
        #expect(session.history.undoCount == before)
    }

    /// The same step for an add that awaits (place_smart_object's): put back the same way when a part fails, and one
    /// step, named and moved out of a folder under Lock All, when it succeeds.
    @Test func addLayerInOneStepAwaitsItsAddInTheSameStep() async throws {
        let workspace = clearWorkspace()
        let session = workspace.current.session
        let group = try await MCPTestSupport.call("add_group", ["name": "Folder"], in: workspace)
        let folder = try #require(group["group_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        session.activeLayerID = folder
        session.collapsedGroupIDs = [folder]
        let document = try #require(session.document)
        let before = session.history.undoCount
        let ctx = MCPCallContext(workspace: workspace, tab: workspace.current, args: MCPToolRegistry.Args([:]))
        await #expect(throws: MCPToolError.self) {
            try await MCPToolRegistry.addLayerInOneStep(ctx, document: document, editName: "Test", name: "Added") {
                session.addBlankLayer()
                await Task.yield()
                throw MCPToolError.invalidArgument("A part failed.")
            }
        }
        #expect(session.document?.layers.map(\.id) == document.layers.map(\.id))
        #expect(session.activeLayerID == folder && session.collapsedGroupIDs == [folder])
        #expect(session.history.undoCount == before)

        try await MCPTestSupport.call("set_layer_locks", ["layer": .string(folder.uuidString), "all": true], in: workspace)
        let locked = session.history.undoCount
        let existing = Set(document.layers.map(\.id))
        let id = try await MCPToolRegistry.addLayerInOneStep(ctx, document: try #require(session.document), editName: "Test",
                                                             name: "Added") {
            await Task.yield()
            // Into the locked folder, which is active.
            session.addBlankLayer()
            return try #require(session.document?.layers.first { !existing.contains($0.id) }?.id)
        }
        let added = try #require(session.document?.layers.first { $0.id == id })
        #expect(added.name == "Added" && added.parentID == nil && session.document?.layers.last?.id == id)
        #expect(session.history.undoCount == locked + 1 && session.history.undoName == "Test")
    }

    // MARK: set_shape_style

    @Test func setShapeStyleRecolorsAndKeepsTheShapeLive() async throws {
        let (workspace, session, id) = try await boxWorkspace()
        let before = session.history.undoCount
        let result = try await MCPTestSupport.call("set_shape_style", ["layer": "Box", "color": ["r": 0, "g": 1, "b": 0]], in: workspace)
        let changed = try #require(layer(session, id))
        let live = try #require(changed.liveShape, "the layer is still a live shape")
        #expect(live.style.red == 0 && live.style.green == 1 && live.style.blue == 0 && live.style.kind == .rectangle)
        #expect(changed.transform.origin == CGPoint(x: 100, y: 100) && changed.transform.size == CGSize(width: 200, height: 100))
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Edit Shape" && recorded(result) == true)
        #expect(result["shape"]?.objectValue?["green"].flatMap(MCPValues.number) == 1)
        let pixel = try await pixels(session)
        #expect(pixel(200, 150) == [0, 255, 0, 255])

        let again = try await MCPTestSupport.call("set_shape_style", ["layer": "Box", "color": "#00ff00"], in: workspace)
        #expect(recorded(again) == false && session.history.undoCount == before + 1)
        session.undo()
        #expect(layer(session, id)?.liveShape?.style.red == 1)
    }

    /// A stroke patch changes only the fields given; the box grows by what the stroke reaches past the shape, not again
    /// when the same stroke is set twice, and `null` removes the stroke.
    @Test func setShapeStylePatchesTheStrokeAndResizesTheBoxAroundTheShape() async throws {
        let (workspace, session, id) = try await boxWorkspace()
        try await MCPTestSupport.call("set_shape_style", ["layer": "Box", "stroke": ["width": 8, "color": "#0000ff", "alignment": "center"],
                                                          "corner_radius": 12], in: workspace)
        var shape = try #require(layer(session, id))
        #expect(shape.liveShape?.style.stroke == ShapeStroke(enabled: true, width: 8, red: 0, green: 0, blue: 1, alignment: .center))
        #expect(shape.liveShape?.style.cornerRadius == 12)
        #expect(shape.transform.origin == CGPoint(x: 96, y: 96) && shape.transform.size == CGSize(width: 208, height: 108))
        let before = session.history.undoCount
        let same = try await MCPTestSupport.call("set_shape_style", ["layer": "Box", "stroke": ["width": 8]], in: workspace)
        #expect(recorded(same) == false && session.history.undoCount == before)
        #expect(layer(session, id)?.transform.size == CGSize(width: 208, height: 108))

        try await MCPTestSupport.call("set_shape_style", ["layer": "Box", "stroke": ["alignment": "inside"]], in: workspace)
        shape = try #require(layer(session, id))
        #expect(shape.liveShape?.style.stroke?.width == 8 && shape.liveShape?.style.stroke?.blue == 1)
        #expect(shape.transform.origin == CGPoint(x: 100, y: 100) && shape.transform.size == CGSize(width: 200, height: 100))

        try await MCPTestSupport.call("set_shape_style", ["layer": "Box", "stroke": ["alignment": "outside", "enabled": false]], in: workspace)
        #expect(layer(session, id)?.liveShape?.style.stroke?.enabled == false)
        #expect(layer(session, id)?.transform.size == CGSize(width: 200, height: 100), "a stroke that is off reaches nowhere")
        try await MCPTestSupport.call("set_shape_style", ["layer": "Box", "stroke": ["enabled": true]], in: workspace)
        #expect(layer(session, id)?.transform.size == CGSize(width: 216, height: 116))
        let removed = try await MCPTestSupport.call("set_shape_style", ["layer": "Box", "stroke": nil], in: workspace)
        #expect(layer(session, id)?.liveShape?.style.stroke == nil)
        #expect(layer(session, id)?.transform.origin == CGPoint(x: 100, y: 100))
        #expect(removed["shape"]?.objectValue?["stroke"] == nil)
    }

    @Test func setShapeStyleThickensALineInPlace() async throws {
        let workspace = clearWorkspace()
        let session = workspace.current.session
        let line = try await MCPTestSupport.call("add_shape", ["kind": "line", "start": ["x": 100, "y": 100], "end": ["x": 200, "y": 100],
                                                               "name": "Rule"], in: workspace)
        let id = try id(line)
        try await MCPTestSupport.call("set_shape_style", ["layer": "Rule", "line_width": 20], in: workspace)
        let thick = try #require(layer(session, id))
        #expect(thick.liveShape?.style.lineWidth == 20)
        #expect(thick.transform.origin == CGPoint(x: 90, y: 90) && thick.transform.size == CGSize(width: 120, height: 20))
        let pixel = try await pixels(session)
        #expect(pixel(150, 92)[3] == 255 && pixel(150, 108)[3] == 255 && pixel(150, 111)[3] == 0)
        let refused = try await MCPTestSupport.call("set_shape_style", ["layer": "Rule", "stroke": ["width": 4]], in: workspace,
                                                    expectError: "invalid_argument")
        #expect(message(refused).contains("line_width"))
        try await MCPTestSupport.call("set_shape_style", ["layer": "Rule", "corner_radius": 4], in: workspace, expectError: "invalid_argument")
    }

    /// A Photoshop line imports with any stroke in its own color, which widens it: recoloring the line recolors that
    /// stroke too, and `stroke: null` removes it, thinning the line where it is.
    @Test func setShapeStyleKeepsAnImportedLinesStrokeInItsColor() async throws {
        let workspace = clearWorkspace()
        let session = workspace.current.session
        let line = try await MCPTestSupport.call("add_shape", ["kind": "line", "start": ["x": 100, "y": 100], "end": ["x": 200, "y": 100],
                                                               "color": "#ff0000", "name": "Rule"], in: workspace)
        let id = try id(line)
        try session.updateShapeStyle(id) { $0.stroke = ShapeStroke(enabled: true, width: 2, red: 1, green: 0, blue: 0, alignment: .center) }
        #expect(layer(session, id)?.transform.size == CGSize(width: 106, height: 6))
        try await MCPTestSupport.call("set_shape_style", ["layer": "Rule", "color": "#0000ff"], in: workspace)
        #expect(layer(session, id)?.liveShape?.style.stroke == ShapeStroke(enabled: true, width: 2, red: 0, green: 0, blue: 1, alignment: .center))
        try await MCPTestSupport.call("set_shape_style", ["layer": "Rule", "stroke": nil], in: workspace)
        #expect(layer(session, id)?.liveShape?.style.stroke == nil)
        #expect(layer(session, id)?.transform.origin == CGPoint(x: 98, y: 98) && layer(session, id)?.transform.size == CGSize(width: 104, height: 4))
    }

    /// Import keeps a line's stroke that is off in any color (Photoshop's stored black, say). It keeps that color: the
    /// line's own color again changes nothing, and neither a new line_width nor a new color touches it. A drawn stroke
    /// a shade off the line's color (as close as import takes it) stays too while the line's color does.
    @Test func setShapeStyleLeavesALinesStrokeThatIsOffInItsOwnColor() async throws {
        let workspace = clearWorkspace()
        let session = workspace.current.session
        let line = try await MCPTestSupport.call("add_shape", ["kind": "line", "start": ["x": 100, "y": 100], "end": ["x": 200, "y": 100],
                                                               "color": "#ff0000", "name": "Rule"], in: workspace)
        let id = try id(line)
        let off = ShapeStroke(enabled: false, width: 3, red: 0, green: 0, blue: 0, alignment: .center)
        try session.updateShapeStyle(id) { $0.stroke = off }
        let before = session.history.undoCount
        let same = try await MCPTestSupport.call("set_shape_style", ["layer": "Rule", "color": "#ff0000"], in: workspace)
        #expect(recorded(same) == false && session.history.undoCount == before)
        #expect(layer(session, id)?.liveShape?.style.stroke == off)

        try await MCPTestSupport.call("set_shape_style", ["layer": "Rule", "line_width": 8], in: workspace)
        #expect(layer(session, id)?.liveShape?.style.lineWidth == 8 && layer(session, id)?.liveShape?.style.stroke == off)
        try await MCPTestSupport.call("set_shape_style", ["layer": "Rule", "color": "#0000ff"], in: workspace)
        #expect(layer(session, id)?.liveShape?.style.blue == 1 && layer(session, id)?.liveShape?.style.stroke == off)

        let shade = ShapeStroke(enabled: true, width: 2, red: 0, green: 0, blue: 1 - 0.4 / 255, alignment: .center)
        try session.updateShapeStyle(id) { $0.stroke = shade }
        let drawn = session.history.undoCount
        let unchanged = try await MCPTestSupport.call("set_shape_style", ["layer": "Rule", "color": "#0000ff"], in: workspace)
        #expect(recorded(unchanged) == false && session.history.undoCount == drawn)
        #expect(layer(session, id)?.liveShape?.style.stroke == shade)
    }

    @Test func getLayerReportsTheShapeAsTheShapeToolsDescribeIt() async throws {
        let (workspace, _, _) = try await boxWorkspace()
        try await MCPTestSupport.call("set_shape_style", ["layer": "Box", "stroke": ["width": 3, "alignment": "outside"]], in: workspace)
        let described = try await MCPTestSupport.call("get_layer", ["layer": "Box"], in: workspace)
        let shape = try #require(described["layer"]?.objectValue?["shape"]?.objectValue)
        #expect(shape["kind"]?.stringValue == "rectangle" && MCPValues.number(shape["red"]) == 1)
        #expect(shape["stroke"]?.objectValue?["alignment"]?.stringValue == "outside")
        #expect(shape["cornerRadius"] == nil && shape["corner_radius"] != nil)
    }

    @Test func setShapeStyleRefusesLockAllNonShapesAndPlaceholders() async throws {
        let (workspace, session, id) = try await boxWorkspace()
        let none = try await MCPTestSupport.call("set_shape_style", ["layer": "Box"], in: workspace, expectError: "invalid_argument")
        #expect(message(none).contains("color"))
        try await MCPTestSupport.call("set_layer_locks", ["layer": "Box", "all": true], in: workspace)
        let locked = try await MCPTestSupport.call("set_shape_style", ["layer": "Box", "color": "#00ff00"], in: workspace,
                                                   expectError: "precondition_failed")
        #expect(error(locked)["guard"]?.stringValue == "layer_locked")
        try await MCPTestSupport.call("set_layer_locks", ["layer": "Box", "all": false], in: workspace)
        // Held by a folder's Lock All too.
        let folder = try await MCPTestSupport.call("group_layers", ["layers": ["Box"], "name": "Locked folder"], in: workspace)
        try await MCPTestSupport.call("set_layer_locks", ["layer": try #require(folder["group_id"]), "all": true], in: workspace)
        let inherited = try await MCPTestSupport.call("set_shape_style", ["layer": "Box", "color": "#00ff00"], in: workspace,
                                                      expectError: "precondition_failed")
        #expect(error(inherited)["guard"]?.stringValue == "layer_locked")
        // Position and pixel locks leave the style editable.
        try await MCPTestSupport.call("set_layer_locks", ["layer": try #require(folder["group_id"]), "all": false], in: workspace)
        try await MCPTestSupport.call("set_layer_locks", ["layer": "Box", "pixels": true, "position": true], in: workspace)
        try await MCPTestSupport.call("set_shape_style", ["layer": "Box", "color": "#00ff00"], in: workspace)
        #expect(layer(session, id)?.liveShape?.style.green == 1)

        try await MCPTestSupport.call("add_blank_layer", ["name": "Pixels"], in: workspace)
        let notShape = try await MCPTestSupport.call("set_shape_style", ["layer": "Pixels", "color": "#00ff00"], in: workspace,
                                                     expectError: "precondition_failed")
        #expect(error(notShape)["guard"]?.stringValue == "is_shape")
        var placeholder = ImageLayer(name: "Brightness Contrast 1", blankSize: CGSize(width: 32, height: 32))
        placeholder.isVisible = false
        placeholder.psdExtras = PSDLayerExtras(importedVisible: true, placeholder: "adjustment:brit")
        session.document?.layers.append(placeholder)
        let held = try await MCPTestSupport.call("set_shape_style", ["layer": "Brightness Contrast 1", "color": "#00ff00"],
                                                 in: workspace, expectError: "precondition_failed")
        #expect(error(held)["guard"]?.stringValue == "placeholder")
    }
}
