import CoreGraphics
import Foundation
import Testing
import MCP
@testable import Compositor

/// The selection tools: shapes combine with the selection by mode, Expand/Contract/Feather and Transform Selection
/// change the outline, the Magic Wand and layer loads read pixels with the call's own settings (never the user's
/// tool settings), `move_selected_pixels` moves pixels as one undo step, and `get_selection` reports the outline.
@MainActor struct MCPSelectionToolTests {
    // MARK: Helpers

    /// A workspace whose active layer "Colors" fills the canvas: red left of `split`, blue from it on.
    private func twoColorWorkspace(width: Int = 64, height: Int = 32, split: Int = 32) throws -> (ProjectWorkspace, EditorSession) {
        let workspace = MCPTestSupport.workspace(width: width, height: height)
        let session = workspace.current.session
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: split, height: height))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Colors"))
        return (workspace, session)
    }

    private func bounds(_ session: EditorSession) -> CGRect? { session.selection?.path.boundingBoxOfPath }

    private func close(_ a: CGRect?, _ b: CGRect, within tolerance: CGFloat = 0.5) -> Bool {
        guard let a else { return false }
        return abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    private func recorded(_ result: [String: Value]) -> Bool? { result["undo"]?.objectValue?["recorded"]?.boolValue }

    private func guardName(_ result: [String: Value]) -> String? { result["error"]?.objectValue?["guard"]?.stringValue }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let index = (y * image.width + x) * 4
        return (0..<4).map { Int(bytes[index + $0]) }
    }

    private func render(_ session: EditorSession) async throws -> CGImage {
        try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
    }

    // MARK: Shapes

    @Test func rectEllipseAndPolygonSetTheirBounds() async throws {
        let workspace = MCPTestSupport.workspace(width: 100, height: 80)
        let session = workspace.current.session
        let before = session.history.undoCount
        let rect = try await MCPTestSupport.call("select_rect", ["rect": ["x": 10, "y": 20, "width": 30, "height": 40]], in: workspace)
        #expect(bounds(session) == CGRect(x: 10, y: 20, width: 30, height: 40))
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Rectangular Marquee")
        #expect(recorded(rect) == true)
        let reported = rect["selection"]?.objectValue
        #expect(reported?["exists"] == .bool(true))
        #expect(reported?["bounds"].flatMap(MCPValues.rect(from:)) == CGRect(x: 10, y: 20, width: 30, height: 40))

        try await MCPTestSupport.call("select_ellipse", ["rect": ["x": 50, "y": 10, "width": 40, "height": 20]], in: workspace)
        #expect(close(bounds(session), CGRect(x: 50, y: 10, width: 40, height: 20)), "\(String(describing: bounds(session)))")
        #expect(session.history.undoName == "Elliptical Marquee")

        let triangle: Value = [["x": 10, "y": 10], ["x": 60, "y": 10], ["x": 30, "y": 50]]
        try await MCPTestSupport.call("select_polygon", ["points": triangle, "mode": "add"], in: workspace)
        #expect(close(bounds(session), CGRect(x: 10, y: 10, width: 80, height: 40)), "\(String(describing: bounds(session)))")
        #expect(session.history.undoName == "Polygonal Lasso")

        // Subtracting the top band leaves the triangle's tip: x 20–45 at y 30, down to (30, 50).
        try await MCPTestSupport.call("select_rect", ["rect": ["x": 0, "y": 0, "width": 100, "height": 30], "mode": "subtract"],
                                      in: workspace)
        #expect(close(bounds(session), CGRect(x: 20, y: 30, width: 25, height: 20)), "\(String(describing: bounds(session)))")
        #expect(session.history.undoCount == before + 4)
    }

    @Test func antialiasingComesFromTheCallNotTheToolSettings() async throws {
        let workspace = MCPTestSupport.workspace(width: 100, height: 80)
        let session = workspace.current.session
        session.selectionAntialiased = true
        try await MCPTestSupport.call("select_rect", ["rect": ["x": 10, "y": 10, "width": 20, "height": 20], "antialiased": false],
                                      in: workspace)
        #expect(session.selection?.antialiased == false)
        session.selectionAntialiased = false
        try await MCPTestSupport.call("select_ellipse", ["rect": ["x": 10, "y": 10, "width": 20, "height": 20]], in: workspace)
        #expect(session.selection?.antialiased == true)
        #expect(session.selectionAntialiased == false)
    }

    @Test func invalidShapesAndModesFailWithoutAnEdit() async throws {
        let workspace = MCPTestSupport.workspace(width: 100, height: 80)
        let session = workspace.current.session
        let before = session.history.undoCount
        try await MCPTestSupport.call("select_rect", ["rect": ["x": 10, "y": 10, "width": 0, "height": 20]],
                                      in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("select_rect", ["rect": ["x": 200, "y": 10, "width": 10, "height": 10]],
                                      in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("select_polygon", ["points": [["x": 0, "y": 0], ["x": 10, "y": 10]]],
                                      in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("select_ellipse", ["rect": ["x": 0, "y": 0, "width": 10, "height": 10], "mode": "intersect"],
                                      in: workspace, expectError: "invalid_argument")
        #expect(session.selection == nil && session.history.undoCount == before)
    }

    @Test func selectionToolsWaitWhileAnOutlineIsDrawnInTheApp() async throws {
        let workspace = MCPTestSupport.workspace(width: 100, height: 80)
        let session = workspace.current.session
        session.lassoDraft = LassoDraft(points: [CGPoint(x: 5, y: 5)], cursor: nil, mode: .replace, kind: .freehand)
        let drawing = try await MCPTestSupport.call("select_all", in: workspace, expectError: "precondition_failed")
        #expect(guardName(drawing) == "can_edit_selection")
        #expect(session.selection == nil)
    }

    // MARK: Select all, none, inverse

    @Test func selectAllNoneAndInvert() async throws {
        let workspace = MCPTestSupport.workspace(width: 100, height: 80)
        let session = workspace.current.session
        let inverted = try await MCPTestSupport.call("invert_selection", in: workspace, expectError: "precondition_failed")
        #expect(guardName(inverted) == "selection")

        try await MCPTestSupport.call("select_all", in: workspace)
        #expect(bounds(session) == CGRect(x: 0, y: 0, width: 100, height: 80) && session.history.undoName == "Select All")

        try await MCPTestSupport.call("select_rect", ["rect": ["x": 10, "y": 10, "width": 20, "height": 20]], in: workspace)
        try await MCPTestSupport.call("invert_selection", in: workspace)
        let path = try #require(session.selection?.path)
        #expect(path.contains(CGPoint(x: 5, y: 5), using: .winding) && !path.contains(CGPoint(x: 15, y: 15), using: .winding))
        #expect(session.history.undoName == "Inverse")

        try await MCPTestSupport.call("select_none", in: workspace)
        #expect(session.selection == nil && session.history.undoName == "Deselect")
        let count = session.history.undoCount
        let again = try await MCPTestSupport.call("select_none", in: workspace)
        #expect(recorded(again) == false && session.history.undoCount == count)
    }

    // MARK: Modify

    @Test func expandGrowsContractShrinksAndFeatherSoftens() async throws {
        let workspace = MCPTestSupport.workspace(width: 100, height: 80)
        let session = workspace.current.session
        try await MCPTestSupport.call("select_rect", ["rect": ["x": 20, "y": 20, "width": 20, "height": 20]], in: workspace)
        try await MCPTestSupport.call("modify_selection", ["operation": "expand", "amount": 5], in: workspace)
        #expect(close(bounds(session), CGRect(x: 15, y: 15, width: 30, height: 30)), "\(String(describing: bounds(session)))")
        #expect(session.history.undoName == "Expand Selection")
        try await MCPTestSupport.call("modify_selection", ["operation": "contract", "amount": 10], in: workspace)
        #expect(close(bounds(session), CGRect(x: 25, y: 25, width: 10, height: 10)), "\(String(describing: bounds(session)))")
        #expect(session.history.undoName == "Contract Selection")
        try await MCPTestSupport.call("modify_selection", ["operation": "feather", "amount": 4], in: workspace)
        #expect(session.selection?.feather == 4 && session.history.undoName == "Feather Selection")

        let before = session.history.undoCount
        try await MCPTestSupport.call("modify_selection", ["operation": "expand", "amount": 0], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("modify_selection", ["operation": "expand", "amount": 501], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("modify_selection", ["operation": "feather", "amount": 251], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("modify_selection", ["operation": "grow", "amount": 5], in: workspace, expectError: "invalid_argument")
        #expect(session.history.undoCount == before)

        try await MCPTestSupport.call("select_none", in: workspace)
        let none = try await MCPTestSupport.call("modify_selection", ["operation": "expand", "amount": 5],
                                                 in: workspace, expectError: "precondition_failed")
        #expect(guardName(none) == "selection")
    }

    // MARK: Transform

    @Test func transformSelectionMovesAndScalesTheOutline() async throws {
        let workspace = MCPTestSupport.workspace(width: 100, height: 80)
        let session = workspace.current.session
        try await MCPTestSupport.call("select_rect", ["rect": ["x": 10, "y": 10, "width": 20, "height": 20]], in: workspace)
        try await MCPTestSupport.call("modify_selection", ["operation": "feather", "amount": 3], in: workspace)

        try await MCPTestSupport.call("transform_selection", ["dx": 5, "dy": -5], in: workspace)
        #expect(close(bounds(session), CGRect(x: 15, y: 5, width: 20, height: 20), within: 0.001))
        #expect(session.history.undoName == "Move Selection")

        // Scales about the outline's center by default.
        try await MCPTestSupport.call("transform_selection", ["scale_x": 2], in: workspace)
        #expect(close(bounds(session), CGRect(x: 5, y: 5, width: 40, height: 20), within: 0.001))
        #expect(session.history.undoName == "Transform Selection")

        try await MCPTestSupport.call("transform_selection", ["scale_y": 0.5, "around": ["x": 0, "y": 0]], in: workspace)
        #expect(close(bounds(session), CGRect(x: 5, y: 2.5, width: 40, height: 10), within: 0.001))
        #expect(session.selection?.feather == 3)

        let count = session.history.undoCount
        let unchanged = try await MCPTestSupport.call("transform_selection", in: workspace)
        #expect(recorded(unchanged) == false && session.history.undoCount == count)
        try await MCPTestSupport.call("transform_selection", ["scale_x": 0], in: workspace, expectError: "invalid_argument")
        // 'around' is bounded like dx and dy: scaling about a point near the largest double moved the outline so far
        // that its bounds overflowed to infinity, and the result couldn't be encoded though the edit was made.
        let before = bounds(session)
        for around: Value in [["x": 1e308, "y": 1e308], ["x": -2_000_000, "y": 0]] {
            let far = try await MCPTestSupport.call("transform_selection", ["scale_x": 0.01, "around": around], in: workspace,
                                                    expectError: "invalid_argument")
            #expect(far["error"]?.objectValue?["message"]?.stringValue?.contains("around") == true, "\(far)")
        }
        #expect(bounds(session) == before && session.history.undoCount == count)

        try await MCPTestSupport.call("select_none", in: workspace)
        let none = try await MCPTestSupport.call("transform_selection", ["dx": 1], in: workspace, expectError: "precondition_failed")
        #expect(guardName(none) == "selection")
    }

    // MARK: Magic Wand, Object Selection, Subject

    @Test func selectByColorOnATwoColorFixtureSelectsHalf() async throws {
        let (workspace, session) = try twoColorWorkspace()
        session.wandSettings.tolerance = 3
        session.wandSettings.contiguous = false
        let result = try await MCPTestSupport.call("select_by_color", ["x": 10, "y": 10], in: workspace)
        #expect(bounds(session) == CGRect(x: 0, y: 0, width: 32, height: 32))
        #expect(session.history.undoName == "Magic Wand" && recorded(result) == true)
        #expect(result["selection"]?.objectValue?["bounds"].flatMap(MCPValues.rect(from:)) == CGRect(x: 0, y: 0, width: 32, height: 32))
        // The call's settings never become the user's.
        #expect(session.wandSettings.tolerance == 3 && session.wandSettings.contiguous == false)

        try await MCPTestSupport.call("select_by_color", ["x": 50, "y": 10, "mode": "add", "sample_size": "3x3",
                                                          "sample_all_layers": true, "tolerance": 0], in: workspace)
        #expect(close(bounds(session), CGRect(x: 0, y: 0, width: 64, height: 32), within: 0.001))

        let before = session.history.undoCount
        try await MCPTestSupport.call("select_by_color", ["x": 10, "y": 10, "tolerance": 256], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("select_by_color", ["x": 64, "y": 10], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("select_by_color", ["x": 10, "y": 10, "sample_size": "7x7"], in: workspace, expectError: "invalid_argument")
        #expect(session.history.undoCount == before)
    }

    @Test func objectAndSubjectSelectionCheckArgumentsAndGuardsFirst() async throws {
        let (workspace, session) = try twoColorWorkspace()
        try await MCPTestSupport.call("select_object", ["x": 10, "y": 10, "edge_offset": 11], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("select_object", ["x": -1, "y": 10], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("select_object", ["y": 10], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("select_subject", ["mode": "sideways"], in: workspace, expectError: "invalid_argument")
        session.isProjectBusy = true
        try await MCPTestSupport.call("select_subject", in: workspace, expectError: "busy")
        session.isProjectBusy = false
        #expect(session.selection == nil)
    }

    // MARK: Layer and mask loads

    @Test func loadLayerSelectionReadsOpaquePixelsOrMaskWhiteAreas() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 48)
        let session = workspace.current.session
        let square = try #require(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        square.setFillColor(red: 0.2, green: 0.6, blue: 0.2, alpha: 1)
        square.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let image = try #require(square.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Square"))
        let id = try #require(session.activeLayerID)
        let origin = try #require(session.activeLayer?.transform.origin)

        try await MCPTestSupport.call("load_layer_selection", ["layer": "Square"], in: workspace)
        #expect(bounds(session) == CGRect(origin: origin, size: CGSize(width: 20, height: 20)))
        #expect(session.history.undoName == "Load Layer Selection")

        let noMask = try await MCPTestSupport.call("load_layer_selection", ["layer": "Square", "source": "mask"],
                                                   in: workspace, expectError: "precondition_failed")
        #expect(guardName(noMask) == "has_mask")

        // A mask black on its left half: the right half is what it reveals, which Photoshop's Cmd-click selects.
        let gray = try BrushRaster.context(width: 20, height: 20, mask: true)
        gray.setFillColor(gray: 1, alpha: 1)
        gray.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        gray.setFillColor(gray: 0, alpha: 1)
        gray.fill(CGRect(x: 0, y: 0, width: 10, height: 20))
        let maskAsset = try LayerMask.asset(from: try #require(gray.makeImage()))
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].mask = LayerMask(asset: maskAsset)
        try await MCPTestSupport.call("load_layer_selection", ["layer": "Square", "source": "mask"], in: workspace)
        #expect(bounds(session) == CGRect(origin: CGPoint(x: origin.x + 10, y: origin.y), size: CGSize(width: 10, height: 20)))
        #expect(session.history.undoName == "Load Mask Selection")

        // "Layer 1" is the new document's empty layer: nothing to select.
        let before = session.history.undoCount
        let empty = try await MCPTestSupport.call("load_layer_selection", ["layer": "Layer 1"], in: workspace, expectError: "precondition_failed")
        #expect(guardName(empty) == "has_pixels")
        #expect(session.history.undoCount == before)
    }

    // MARK: Moving pixels

    @Test func moveSelectedPixelsMovesPixelsAndOutlineAsOneUndo() async throws {
        let (workspace, session) = try twoColorWorkspace(width: 100, height: 40, split: 50)
        let colors = try #require(session.activeLayerID)
        try await MCPTestSupport.call("select_rect", ["rect": ["x": 10, "y": 10, "width": 10, "height": 10]], in: workspace)
        session.selectLayer(session.document?.layers.first { $0.name == "Layer 1" }?.id)
        let before = session.history.undoCount
        let result = try await MCPTestSupport.call("move_selected_pixels", ["layer": "Colors", "dx": 60, "dy": 5], in: workspace)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Move Pixels" && recorded(result) == true)
        #expect(session.activeLayerID == colors)
        #expect(bounds(session) == CGRect(x: 70, y: 15, width: 10, height: 10))
        let moved = try await render(session)
        #expect(try pixel(moved, x: 15, y: 15)[3] == 0)                 // Hole where the pixels were.
        #expect(try pixel(moved, x: 75, y: 20) == [255, 0, 0, 255])     // Red pixels now on blue.
        #expect(try pixel(moved, x: 85, y: 20) == [0, 0, 255, 255])     // Untouched blue.

        try await MCPTestSupport.call("select_rect", ["rect": ["x": 30, "y": 10, "width": 10, "height": 10]], in: workspace)
        try await MCPTestSupport.call("move_selected_pixels", ["layer": "Colors", "dx": 60, "dy": 0, "duplicate": true], in: workspace)
        #expect(session.history.undoName == "Duplicate Pixels")
        let duplicated = try await render(session)
        #expect(try pixel(duplicated, x: 35, y: 15) == [255, 0, 0, 255])
        #expect(try pixel(duplicated, x: 95, y: 15) == [255, 0, 0, 255])
    }

    @Test func moveSelectedPixelsNeedsASelectionPixelsAndNoPixelLock() async throws {
        let (workspace, session) = try twoColorWorkspace(width: 100, height: 40, split: 50)
        let colors = try #require(session.activeLayerID)
        let noSelection = try await MCPTestSupport.call("move_selected_pixels", ["layer": "Colors", "dx": 5, "dy": 0],
                                                        in: workspace, expectError: "precondition_failed")
        #expect(guardName(noSelection) == "selection")

        try await MCPTestSupport.call("select_rect", ["rect": ["x": 10, "y": 10, "width": 10, "height": 10]], in: workspace)
        let before = session.history.undoCount
        let index = try #require(session.document?.layers.firstIndex { $0.id == colors })
        session.document?.layers[index].locks = [.pixels]
        let locked = try await MCPTestSupport.call("move_selected_pixels", ["layer": "Colors", "dx": 5, "dy": 0],
                                                   in: workspace, expectError: "precondition_failed")
        #expect(guardName(locked) == "layer_locked")
        session.document?.layers[index].locks = []

        let empty = try await MCPTestSupport.call("move_selected_pixels", ["layer": "Layer 1", "dx": 5, "dy": 0],
                                                  in: workspace, expectError: "precondition_failed")
        #expect(guardName(empty) == "has_pixels")
        #expect(session.history.undoCount == before && session.pixelMove == nil)
    }

    @Test func aFailedMoveLeavesTheUsersLayerSelectionAlone() async throws {
        let (workspace, session) = try twoColorWorkspace(width: 100, height: 40, split: 50)
        let colors = try #require(session.activeLayerID)
        let blank = try #require(session.document?.layers.first { $0.name == "Layer 1" }?.id)
        // "Right" covers only x 80–100, so the selection at x 10–20 holds none of its pixels.
        let context = try #require(CGContext(data: nil, width: 20, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 40))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Right"), centeredAt: CGPoint(x: 90, y: 20))
        let right = try #require(session.activeLayerID)
        let rightIndex = try #require(session.document?.layers.firstIndex { $0.id == right })
        try #require(session.document?.layers[rightIndex].transform.origin == CGPoint(x: 80, y: 0))
        try await MCPTestSupport.call("select_rect", ["rect": ["x": 10, "y": 10, "width": 10, "height": 10]], in: workspace)

        // The user works on the mask of "Colors", with "Layer 1" selected too and an effect row picked.
        let white = try BrushRaster.context(width: 100, height: 40, mask: true)
        white.setFillColor(gray: 1, alpha: 1)
        white.fill(CGRect(x: 0, y: 0, width: 100, height: 40))
        let colorsIndex = try #require(session.document?.layers.firstIndex { $0.id == colors })
        session.document?.layers[colorsIndex].mask = LayerMask(asset: try LayerMask.asset(from: try #require(white.makeImage())))
        let effect = LayerEffectSelection(layerID: colors, kind: .shadow)

        func expectFailure(_ expected: String, _ situation: Comment) async throws {
            session.selectLayers([colors, blank], primary: colors)
            session.isMaskSelected = true
            session.effectSelection = effect
            let before = session.history.undoCount
            let result = try await MCPTestSupport.call("move_selected_pixels", ["layer": "Right", "dx": 5, "dy": 0],
                                                       in: workspace, expectError: "precondition_failed")
            #expect(guardName(result) == expected, situation)
            #expect(session.activeLayerID == colors, situation)
            #expect(session.selectedLayerIDs == [colors, blank], situation)
            #expect(session.isMaskSelected, situation)
            #expect(session.effectSelection == effect, situation)
            #expect(session.history.undoCount == before && session.pixelMove == nil, situation)
        }

        // Found only once "Right" is the active layer, so the switch has to be undone.
        try await expectFailure("has_pixels", "no pixels inside the selection")

        try await MCPTestSupport.call("select_rect", ["rect": ["x": 85, "y": 10, "width": 10, "height": 10]], in: workspace)
        session.document?.layers[rightIndex].isVisible = false
        try await expectFailure("can_paint", "a hidden layer")
        session.document?.layers[rightIndex].isVisible = true

        // A placeholder as import keeps one, hidden and without pixels, is named before either.
        let rightLayer = try #require(session.document?.layers[rightIndex])
        session.document?.layers[rightIndex].psdExtras = PSDLayerExtras(importedVisible: true, placeholder: "adjustment:brit")
        session.document?.layers[rightIndex].isVisible = false
        session.document?.layers[rightIndex].asset = nil
        try await expectFailure("placeholder", "a Photoshop placeholder")
        session.document?.layers[rightIndex] = rightLayer

        session.selectLayer(right)
        session.groupSelectedLayers()
        let folder = try #require(session.activeLayerID)
        #expect(folder != right && session.document?.layers.first { $0.id == right }?.parentID == folder)
        let folderIndex = try #require(session.document?.layers.firstIndex { $0.id == folder })
        session.document?.layers[folderIndex].isVisible = false
        try await expectFailure("can_paint", "a layer inside a hidden folder")
    }

    // MARK: get_selection

    @Test func getSelectionReportsTheOutlineAndAnSVGPath() async throws {
        let workspace = MCPTestSupport.workspace(width: 100, height: 80)
        let session = workspace.current.session
        let none = try await MCPTestSupport.call("get_selection", in: workspace)
        #expect(none["exists"] == .bool(false) && none["bounds"] == nil && none["path"] == nil)

        try await MCPTestSupport.call("select_rect", ["rect": ["x": 10, "y": 20, "width": 30, "height": 40], "antialiased": false],
                                      in: workspace)
        try await MCPTestSupport.call("modify_selection", ["operation": "feather", "amount": 2], in: workspace)
        let count = session.history.undoCount
        let plain = try await MCPTestSupport.call("get_selection", in: workspace)
        #expect(plain["exists"] == .bool(true) && plain["empty"] == .bool(false))
        #expect(plain["bounds"].flatMap(MCPValues.rect(from:)) == CGRect(x: 10, y: 20, width: 30, height: 40))
        #expect(MCPValues.number(plain["feather"]) == 2 && plain["antialiased"] == .bool(false))
        #expect(plain["path"] == nil)

        let withPath = try await MCPTestSupport.call("get_selection", ["include_path": true], in: workspace)
        let svg = try #require(withPath["path"]?.stringValue)
        #expect(svg.hasPrefix("M") && svg.hasSuffix("Z"), "\(svg)")
        let numbers = Set(svg.split { !($0.isNumber || $0 == "." || $0 == "-") }.compactMap { Double($0) })
        #expect(numbers == [10, 20, 40, 60], "\(svg)")
        #expect(session.history.undoCount == count)

        // Subtracting everything leaves an explicit empty selection, which is not the same as none.
        try await MCPTestSupport.call("select_rect", ["rect": ["x": 0, "y": 0, "width": 100, "height": 80], "mode": "subtract"], in: workspace)
        let empty = try await MCPTestSupport.call("get_selection", in: workspace)
        #expect(empty["exists"] == .bool(true) && empty["empty"] == .bool(true) && empty["bounds"] == .null, "\(empty)")
    }
}
