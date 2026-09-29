import CoreGraphics
import Foundation
import Testing
import MCP
@testable import Compositor

/// The Canvas and guides domain: canvas and image size, resolution, crop and trim, flipping the canvas, and guides.
@MainActor struct MCPCanvasToolTests {
    // MARK: Fixtures

    /// A `width` × `height` image painted by `pixel(x, y)` (top-left origin, unpremultiplied RGBA).
    private func image(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                let i = (y * width + x) * 4
                bytes[i] = UInt8(Int(r) * Int(a) / 255)
                bytes[i + 1] = UInt8(Int(g) * Int(a) / 255)
                bytes[i + 2] = UInt8(Int(b) * Int(a) / 255)
                bytes[i + 3] = a
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func solid(width: Int, height: Int) throws -> CGImage {
        try image(width: width, height: height) { _, _ in (255, 0, 0, 255) }
    }

    /// Red on the left half, transparent on the right.
    private func halfRed(width: Int, height: Int) throws -> CGImage {
        try image(width: width, height: height) { x, _ in x < width / 2 ? (255, 0, 0, 255) : (0, 0, 0, 0) }
    }

    /// Adds `image` as a new layer at `origin` (its own pixel size) and returns its id.
    @discardableResult
    private func insert(_ image: CGImage, name: String, at origin: CGPoint = .zero, in session: EditorSession) throws -> UUID {
        session.insert(ImportedImage(image: image, thumbnail: image, name: name))
        let id = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].transform.origin = origin
        return id
    }

    private func layer(_ name: String, in session: EditorSession) -> ImageLayer? {
        session.document?.layers.first { $0.name == name }
    }

    private func undoName(_ result: [String: Value]) -> String? { result["undo"]?.objectValue?["name"]?.stringValue }

    private func recorded(_ result: [String: Value]) -> Bool? { result["undo"]?.objectValue?["recorded"]?.boolValue }

    // MARK: Canvas and image size

    /// Mirrors `CanvasSizeTests.everyAnchorPreservesSourceAndTransformForExpansionAndShrink` through the tool.
    @Test func resizeCanvasAnchorsMirrorCanvasSizeTests() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        let id = try insert(try solid(width: 20, height: 10), name: "Box", at: CGPoint(x: 7, y: 5), in: session)
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].transform.rotation = 37
        session.document?.layers[index].transform.flipX = true
        let original = try #require(layer("Box", in: session)).transform
        let before = session.history.undoCount
        for delta in [5, -5] {
            for anchor in 0...8 {
                let result = try await MCPTestSupport.call("resize_canvas", ["width": .int(64 + delta), "height": .int(32 + delta),
                                                                             "anchor": .int(anchor)], in: workspace)
                let expected: [CGFloat] = [0, delta == 5 ? 2 : -3, CGFloat(delta)]
                let offset = CGPoint(x: expected[anchor % 3], y: expected[anchor / 3])
                let moved = try #require(layer("Box", in: session)).transform
                #expect(moved.origin == CGPoint(x: original.origin.x + offset.x, y: original.origin.y + offset.y),
                        "anchor \(anchor), delta \(delta)")
                #expect(moved.size == original.size && moved.rotation == 37 && moved.flipX)
                #expect(session.document?.width == 64 + delta && session.document?.height == 32 + delta)
                #expect(result["offset"] == MCPValues.point(offset))
                #expect(undoName(result) == "Canvas Size" && recorded(result) == true)
                #expect(session.history.undoCount == before + 1)
                session.undo()
                #expect(session.document?.width == 64 && layer("Box", in: session)?.transform == original)
            }
        }

        // Named anchors and relative sizes: bottom-right keeps that corner, so everything moves by the growth.
        let grown = try await MCPTestSupport.call("resize_canvas", ["width": 10, "height": -2, "relative": true,
                                                                    "anchor": "bottom_right"], in: workspace)
        #expect(session.document?.width == 74 && session.document?.height == 30)
        #expect(grown["width"]?.intValue == 74 && grown["height"]?.intValue == 30)
        #expect(layer("Box", in: session)?.transform.origin == CGPoint(x: original.origin.x + 10, y: original.origin.y - 2))

        // The same size again changes nothing and records nothing.
        let count = session.history.undoCount
        let same = try await MCPTestSupport.call("resize_canvas", ["width": 74, "height": 30], in: workspace)
        #expect(recorded(same) == false && session.history.undoCount == count)

        // A fill paints the added border into a new bottom layer.
        try await MCPTestSupport.call("resize_canvas", ["width": 80, "height": 30, "fill": "#00ff00"], in: workspace)
        #expect(session.document?.layers.first?.name == "Canvas Extension")

        try await MCPTestSupport.call("resize_canvas", ["width": -80, "height": 0, "relative": true], in: workspace,
                                      expectError: "invalid_argument")
        try await MCPTestSupport.call("resize_canvas", ["width": 10, "height": 10, "anchor": 9], in: workspace,
                                      expectError: "invalid_argument")
        try await MCPTestSupport.call("resize_canvas", ["width": 10, "height": 10, "anchor": "middle_top"], in: workspace,
                                      expectError: "invalid_argument")
    }

    /// Integers at the edge of `Int` (which the MCP SDK decodes a large JSON integer to) are refused before any
    /// arithmetic, instead of overflowing and crashing the app.
    @Test func resizeCanvasRefusesHugeSizesWithoutOverflowing() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        let before = session.history.undoCount
        let huge: [[String: Value]] = [
            ["width": .int(Int.max), "height": 1, "relative": true],
            ["width": 1, "height": .int(Int.max), "relative": true],
            ["width": .int(Int.min), "height": 1, "relative": true],
            ["width": 0, "height": .int(Int.min), "relative": true],
            ["width": .int(Int.max), "height": .int(Int.max)],
            ["width": 30_001, "height": 10, "relative": true],
        ]
        for args in huge {
            try await MCPTestSupport.call("resize_canvas", args, in: workspace, expectError: "invalid_argument")
        }
        #expect(session.document?.width == 64 && session.document?.height == 32)
        #expect(session.history.undoCount == before)

        // Changes within range still work, down to a single pixel.
        try await MCPTestSupport.call("resize_canvas", ["width": -63, "height": 0, "relative": true], in: workspace)
        #expect(session.document?.width == 1 && session.document?.height == 32)
    }

    @Test func resizeImageKeepsTheRatioFromOneSideOrAPercentage() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        session.document?.resolution = 300
        try insert(try solid(width: 64, height: 32), name: "Red", in: session)

        let wide = try await MCPTestSupport.call("resize_image", ["width": 32], in: workspace)
        #expect(session.document?.width == 32 && session.document?.height == 16)
        #expect(session.document?.resolution == 300, "An omitted resolution keeps the document's")
        #expect(wide["width"]?.intValue == 32 && wide["height"]?.intValue == 16)
        #expect(undoName(wide) == "Image Size" && recorded(wide) == true)
        #expect(layer("Red", in: session)?.transform.sampling == .high)

        try await MCPTestSupport.call("resize_image", ["height": 32], in: workspace)
        #expect(session.document?.width == 64 && session.document?.height == 32)

        try await MCPTestSupport.call("resize_image", ["percent": 50, "sampling": "Nearest"], in: workspace)
        #expect(session.document?.width == 32 && session.document?.height == 16)
        #expect(layer("Red", in: session)?.transform.sampling == .nearest)

        try await MCPTestSupport.call("resize_image", ["width": 10, "height": 40], in: workspace)
        #expect(session.document?.width == 10 && session.document?.height == 40)
        let count = session.history.undoCount
        let same = try await MCPTestSupport.call("resize_image", ["width": 10, "height": 40], in: workspace)
        #expect(recorded(same) == false && session.history.undoCount == count)

        // Resolution alone changes only the stored pixels per inch.
        let dpi = try await MCPTestSupport.call("resize_image", ["resolution": 144], in: workspace)
        #expect(session.document?.resolution == 144 && session.document?.width == 10 && session.document?.height == 40)
        #expect(undoName(dpi) == "Image Size" && session.history.undoCount == count + 1)

        try await MCPTestSupport.call("resize_image", in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("resize_image", ["width": 10, "percent": 50], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("resize_image", ["width": 40_000], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("resize_image", ["width": 20, "sampling": "cubic"], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("resize_image", ["width": 20, "resolution": 0], in: workspace, expectError: "invalid_argument")
    }

    @Test func setResolutionIsOneUndoStepAndIdempotent() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        let before = session.history.undoCount
        let set = try await MCPTestSupport.call("set_resolution", ["resolution": 300], in: workspace)
        #expect(session.document?.resolution == 300 && session.document?.width == 64)
        #expect(set["resolution"]?.doubleValue == 300)
        #expect(undoName(set) == "Image Size" && recorded(set) == true && session.history.undoCount == before + 1)

        let again = try await MCPTestSupport.call("set_resolution", ["resolution": 300], in: workspace)
        #expect(recorded(again) == false && session.history.undoCount == before + 1)

        try await MCPTestSupport.call("set_resolution", ["resolution": 0], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("set_resolution", ["resolution": 9601], in: workspace, expectError: "invalid_argument")
        session.undo()
        #expect(session.document?.resolution == 72)
    }

    // MARK: Crop and trim

    @Test func cropMatchesTheCropTool() async throws {
        func fixture() throws -> ProjectWorkspace {
            let workspace = MCPTestSupport.workspace(width: 64, height: 32)
            try insert(try halfRed(width: 64, height: 32), name: "Art", at: CGPoint(x: 3, y: 2), in: workspace.current.session)
            return workspace
        }
        let tool = try fixture(), app = try fixture()
        let session = tool.current.session, appSession = app.current.session
        let rect = CGRect(x: 8, y: 4, width: 32, height: 16)
        let before = session.history.undoCount

        let result = try await MCPTestSupport.call("crop", ["rect": MCPValues.rect(rect)], in: tool)
        appSession.selectTool(.crop)
        appSession.cropRect = rect
        await appSession.commitCrop()

        let cropped = try #require(session.document), expected = try #require(appSession.document)
        #expect(cropped.width == 32 && cropped.height == 16)
        #expect(cropped.width == expected.width && cropped.height == expected.height)
        #expect(cropped.layers.map(\.transform) == expected.layers.map(\.transform))
        #expect(cropped.layers.map { $0.asset?.image.width } == expected.layers.map { $0.asset?.image.width })
        #expect(undoName(result) == appSession.history.undoName && undoName(result) == "Crop")
        #expect(session.history.undoCount == before + 1)
        #expect(result["rect"] == MCPValues.rect(rect))
        let croppedPNG = try await ImageExporter.shared.pngData(try #require(session.projectSnapshot()))
        let expectedPNG = try await ImageExporter.shared.pngData(try #require(appSession.projectSnapshot()))
        #expect(croppedPNG == expectedPNG)

        // Edges snap to whole pixels as the crop frame does, and a rectangle past the canvas extends it.
        let outside = try await MCPTestSupport.call("crop", ["rect": ["x": -4.4, "y": -2.2, "width": 40.6, "height": 20.4]], in: tool)
        #expect(outside["rect"] == MCPValues.rect(CGRect(x: -4, y: -2, width: 40, height: 20)))
        #expect(session.document?.width == 40 && session.document?.height == 20)

        // The whole canvas changes nothing.
        let count = session.history.undoCount
        let whole = try await MCPTestSupport.call("crop", ["rect": MCPValues.rect(CGRect(x: 0, y: 0, width: 40, height: 20))], in: tool)
        #expect(recorded(whole) == false && session.history.undoCount == count)

        try await MCPTestSupport.call("crop", in: tool, expectError: "invalid_argument")
        try await MCPTestSupport.call("crop", ["rect": MCPValues.rect(CGRect(x: 0, y: 0, width: 0, height: 10))], in: tool,
                                      expectError: "invalid_argument")
        try await MCPTestSupport.call("crop", ["rect": MCPValues.rect(CGRect(x: 0, y: 0, width: 40_000, height: 10))], in: tool,
                                      expectError: "invalid_argument")
    }

    @Test func trimCanvasOnAHalfRedFixtureGivesHalfTheWidth() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        try insert(try halfRed(width: 64, height: 32), name: "Half", in: session)
        let before = session.history.undoCount

        let trimmed = try await MCPTestSupport.call("trim_canvas", in: workspace)
        #expect(session.document?.width == 32 && session.document?.height == 32)
        #expect(trimmed["rect"] == MCPValues.rect(CGRect(x: 0, y: 0, width: 32, height: 32)))
        #expect(undoName(trimmed) == "Trim" && recorded(trimmed) == true && session.history.undoCount == before + 1)
        let again = try await MCPTestSupport.call("trim_canvas", in: workspace)
        #expect(recorded(again) == false && session.history.undoCount == before + 1)
        session.undo()

        // Padding keeps a margin on every side, even past the old canvas.
        try await MCPTestSupport.call("trim_canvas", ["padding": 4], in: workspace)
        #expect(session.document?.width == 40 && session.document?.height == 40)
        #expect(layer("Half", in: session)?.transform.origin == CGPoint(x: 4, y: 4))
        session.undo()

        // Every shown layer counts by default; hidden ones don't, and `layers` narrows it.
        try insert(try solid(width: 8, height: 8), name: "Dot", at: CGPoint(x: 40, y: 8), in: session)
        try insert(try solid(width: 8, height: 8), name: "Ghost", at: CGPoint(x: 52, y: 20), in: session)
        try await MCPTestSupport.call("set_layer_visibility", ["layer": "Ghost", "visible": false], in: workspace)
        try await MCPTestSupport.call("trim_canvas", in: workspace)
        #expect(session.document?.width == 48 && session.document?.height == 32)
        session.undo()
        try await MCPTestSupport.call("trim_canvas", ["layers": ["Half"]], in: workspace)
        #expect(session.document?.width == 32)
        session.undo()
        // A named layer counts even when hidden.
        try await MCPTestSupport.call("trim_canvas", ["layers": ["Ghost"]], in: workspace)
        #expect(session.document?.width == 8 && layer("Ghost", in: session)?.transform.origin == .zero)
        session.undo()
        // A folder counts only the layers shown inside it.
        try await MCPTestSupport.call("group_layers", ["layers": ["Dot", "Ghost"], "name": "Folder"], in: workspace)
        try await MCPTestSupport.call("trim_canvas", ["layers": ["Folder"]], in: workspace)
        #expect(session.document?.width == 8 && session.document?.height == 8)
        #expect(layer("Dot", in: session)?.transform.origin == .zero)
        session.undo()
        try await MCPTestSupport.call("set_layer_visibility", ["layer": "Folder", "visible": false], in: workspace)
        try await MCPTestSupport.call("trim_canvas", in: workspace)
        #expect(session.document?.width == 32)

        let empty = MCPTestSupport.workspace(width: 64, height: 32)
        try await MCPTestSupport.call("trim_canvas", in: empty, expectError: "precondition_failed")
        try await MCPTestSupport.call("trim_canvas", ["padding": -1], in: workspace, expectError: "invalid_argument")
    }

    /// Each layer's box is clipped to the canvas before the union, so a layer parked off the canvas (beside it, past a
    /// corner, or just touching an edge from outside) doesn't stretch the trim.
    @Test func trimCanvasIgnoresLayersParkedOffTheCanvas() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        try insert(try solid(width: 32, height: 16), name: "Art", at: CGPoint(x: 20, y: 8), in: session)
        try insert(try solid(width: 8, height: 8), name: "Beside", at: CGPoint(x: -20, y: 12), in: session)
        try insert(try solid(width: 8, height: 8), name: "Corner", at: CGPoint(x: -20, y: -20), in: session)
        try insert(try solid(width: 8, height: 8), name: "Edge", at: CGPoint(x: 64, y: 0), in: session)

        let trimmed = try await MCPTestSupport.call("trim_canvas", in: workspace)
        #expect(trimmed["rect"] == MCPValues.rect(CGRect(x: 20, y: 8, width: 32, height: 16)))
        #expect(session.document?.width == 32 && session.document?.height == 16)
        #expect(layer("Art", in: session)?.transform.origin == .zero)
        session.undo()

        // A layer partly on the canvas counts with the part that is on it.
        try insert(try solid(width: 8, height: 8), name: "Overhang", at: CGPoint(x: 60, y: 28), in: session)
        let overhang = try await MCPTestSupport.call("trim_canvas", in: workspace)
        #expect(overhang["rect"] == MCPValues.rect(CGRect(x: 20, y: 8, width: 44, height: 24)))
        session.undo()

        // Only layers off the canvas: nothing to trim to.
        let off = try await MCPTestSupport.call("trim_canvas", ["layers": ["Beside", "Corner", "Edge"]], in: workspace,
                                                expectError: "precondition_failed")
        #expect(off["error"]?.objectValue?["guard"]?.stringValue == "has_pixels")
        #expect(session.document?.width == 64 && session.document?.height == 32)
    }

    /// The whole-document tools don't run under an edit in progress in the app, which would otherwise keep state in
    /// the old geometry (a transform's frame, a crop frame) or an open undo step (an Option-drag duplicate).
    @Test func wholeDocumentToolsWaitForEditsInProgress() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        try insert(try halfRed(width: 64, height: 32), name: "Art", in: session)
        let calls: [(String, [String: Value])] = [
            ("crop", ["rect": MCPValues.rect(CGRect(x: 8, y: 0, width: 32, height: 32))]),
            ("trim_canvas", [:]),
            ("resize_canvas", ["width": 80, "height": 40]),
            ("resize_image", ["width": 32]),
            ("set_resolution", ["resolution": 300]),
        ]
        func expectRefused(during state: String) async throws {
            let count = session.history.undoCount
            for (name, args) in calls {
                let refused = try await MCPTestSupport.call(name, args, in: workspace, expectError: "precondition_failed")
                let error = refused["error"]?.objectValue
                #expect(error?["guard"]?.stringValue == "can_edit_layers", "\(name) during \(state)")
                #expect(error?["hint"]?.stringValue?.contains("settle_pending_edits") == true, "\(name) during \(state)")
            }
            #expect(session.document?.width == 64 && session.document?.height == 32 && session.document?.resolution == 72,
                    "during \(state)")
            #expect(session.history.undoCount == count, "during \(state)")
        }

        // A free transform: committing it after a crop would write its frame in the old canvas's coordinates.
        session.beginTransform()
        #expect(session.transformEdit != nil)
        try await expectRefused(during: "a free transform")
        session.cancelTransform()

        // A crop frame: Return would crop to the stale rectangle.
        session.selectTool(.crop)
        session.cropRect = CGRect(x: 0, y: 0, width: 16, height: 16)
        try await expectRefused(during: "a crop frame")

        // Settling the edit clears the way.
        try await MCPTestSupport.call("settle_pending_edits", ["mode": "cancel"], in: workspace)
        #expect(session.cropRect == nil)
        let trimmed = try await MCPTestSupport.call("trim_canvas", in: workspace)
        #expect(session.document?.width == 32 && undoName(trimmed) == "Trim" && recorded(trimmed) == true)
        session.undo()

        // An Option-drag duplicate holds an outer undo step open, which a crop would nest inside.
        session.selectTool(.move)
        session.beginDuplicateTransform()
        #expect(session.transformEdit != nil)
        try await expectRefused(during: "an Option-drag duplicate")
        session.cancelTransform()
    }

    @Test func flipCanvasMirrorsLayersAndGuides() async throws {
        let workspace = MCPTestSupport.workspace(width: 100, height: 40)
        let session = workspace.current.session
        try insert(try solid(width: 10, height: 10), name: "Box", at: CGPoint(x: 5, y: 0), in: session)
        try await MCPTestSupport.call("add_guide", ["axis": "vertical", "position": 20], in: workspace)
        let flipped = try await MCPTestSupport.call("flip_canvas", ["axis": "Horizontal"], in: workspace)
        #expect(flipped["axis"]?.stringValue == "horizontal")
        #expect(undoName(flipped) == "Flip Canvas Horizontal" && recorded(flipped) == true)
        #expect(layer("Box", in: session)?.transform.origin.x == 85 && layer("Box", in: session)?.transform.flipX == true)
        #expect(session.document?.guides.first?.position == 80)
        try await MCPTestSupport.call("flip_canvas", ["axis": "diagonal"], in: workspace, expectError: "invalid_argument")
    }

    // MARK: Guides

    @Test func guidesAddListRemoveAndClearAsOneStepEach() async throws {
        let workspace = MCPTestSupport.workspace(width: 200, height: 100)
        let session = workspace.current.session
        let before = session.history.undoCount

        let vertical = try await MCPTestSupport.call("add_guide", ["axis": "vertical", "position": 40], in: workspace)
        let verticalID = try #require(vertical["guide_id"]?.stringValue)
        #expect(undoName(vertical) == "New Guide" && recorded(vertical) == true && session.history.undoCount == before + 1)
        let horizontal = try await MCPTestSupport.call("add_guide", ["axis": "Horizontal", "position": 25.5], in: workspace)
        let horizontalID = try #require(horizontal["guide_id"]?.stringValue)
        #expect(session.document?.guides.map(\.position) == [40, 25.5])
        #expect(session.document?.guides.map(\.axis) == [.vertical, .horizontal])

        let listed = try await MCPTestSupport.call("list_guides", in: workspace)
        let guides = try #require(session.document).guides
        #expect(listed["count"]?.intValue == 2)
        #expect(listed["guides"] == .array(guides.map(MCPValues.guide)))
        #expect(listed["locked"] == .bool(false))

        let removed = try await MCPTestSupport.call("remove_guide", ["guide_id": .string(verticalID)], in: workspace)
        #expect(session.document?.guides.map(\.id.uuidString) == [horizontalID])
        #expect(undoName(removed) == "Delete Guide" && session.history.undoCount == before + 3)
        try await MCPTestSupport.call("remove_guide", ["guide_id": .string(verticalID)], in: workspace, expectError: "not_found")
        try await MCPTestSupport.call("remove_guide", ["guide_id": "first"], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("add_guide", ["axis": "diagonal", "position": 10], in: workspace, expectError: "invalid_argument")

        // Locked guides can't be added or removed, but Clear Guides still works, as in the app.
        session.locksGuides = true
        defer { session.locksGuides = false }
        let locked = try await MCPTestSupport.call("add_guide", ["axis": "vertical", "position": 10], in: workspace,
                                                   expectError: "precondition_failed")
        #expect(locked["error"]?.objectValue?["guard"]?.stringValue == "can_edit_guides")
        try await MCPTestSupport.call("remove_guide", ["guide_id": .string(horizontalID)], in: workspace,
                                      expectError: "precondition_failed")
        let cleared = try await MCPTestSupport.call("clear_guides", in: workspace)
        #expect(session.document?.guides.isEmpty == true)
        #expect(cleared["removed_count"]?.intValue == 1)
        #expect(undoName(cleared) == "Clear Guides" && session.history.undoCount == before + 4)
        let none = try await MCPTestSupport.call("clear_guides", in: workspace)
        #expect(recorded(none) == false && session.history.undoCount == before + 4)
        session.undo()
        #expect(session.document?.guides.map(\.id.uuidString) == [horizontalID])
    }

    /// A project saves at most 1000 guides (`ProjectStore.validateGuides`), so add_guide stops there instead of
    /// leaving a document that can't be saved.
    @Test func addGuideStopsAtTheGuidesAProjectCanSave() async throws {
        let workspace = MCPTestSupport.workspace(width: 200, height: 100)
        let session = workspace.current.session
        session.document?.guides = (0..<999).map { CanvasGuide(id: UUID(), axis: .vertical, position: Double($0 % 200)) }

        try await MCPTestSupport.call("add_guide", ["axis": "horizontal", "position": 50], in: workspace)
        #expect(session.document?.guides.count == 1_000)
        let count = session.history.undoCount
        let full = try await MCPTestSupport.call("add_guide", ["axis": "horizontal", "position": 60], in: workspace,
                                                 expectError: "precondition_failed")
        let error = full["error"]?.objectValue
        #expect(error?["guard"]?.stringValue == "max_guides")
        #expect(error?["hint"]?.stringValue?.contains("clear_guides") == true)
        #expect(session.document?.guides.count == 1_000 && session.history.undoCount == count)

        // The limit is the store's: 1000 guides save, one more doesn't.
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: MCPTestSupport.tempFile("Guides.comp"))
        session.document?.guides.append(CanvasGuide(id: UUID(), axis: .horizontal, position: 70))
        let over = try #require(session.projectSnapshot())
        await #expect(throws: ProjectError.self) {
            try await ProjectStore.shared.save(over, to: MCPTestSupport.tempFile("TooMany.comp"))
        }

        // Removing one makes room again.
        session.document?.guides.removeLast()
        let first = try #require(session.document?.guides.first).id
        try await MCPTestSupport.call("remove_guide", ["guide_id": .string(first.uuidString)], in: workspace)
        try await MCPTestSupport.call("add_guide", ["axis": "horizontal", "position": 60], in: workspace)
        #expect(session.document?.guides.count == 1_000)
    }
}
