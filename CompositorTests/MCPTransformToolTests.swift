import CoreGraphics
import Foundation
import Testing
import MCP
@testable import Compositor

/// The Transforms domain: moving and placing layers, scaling and fitting them, rotating, flipping and distorting
/// them, and aligning and distributing several at once.
@MainActor struct MCPTransformToolTests {
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

    /// A `width` × `height` gray mask, white on its left half and black on its right.
    private func maskImage(width: Int, height: Int) throws -> CGImage {
        let bytes = (0..<height).flatMap { _ in (0..<width).map { $0 < width / 2 ? UInt8(255) : UInt8(0) } }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
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

    private func index(of name: String, in session: EditorSession) throws -> Int {
        try #require(session.document?.layers.firstIndex { $0.name == name })
    }

    /// The upright box around a layer on the document.
    private func box(_ name: String, in session: EditorSession) throws -> CGRect {
        MCPRender.box(of: try #require(layer(name, in: session)).transform)
    }

    private func errorObject(_ result: [String: Value]) -> [String: Value] {
        result["error"]?.objectValue ?? [:]
    }

    private func near(_ a: CGFloat, _ b: CGFloat, within tolerance: CGFloat = 1e-6) -> Bool { abs(a - b) <= tolerance }

    private func near(_ a: CGPoint, _ b: CGPoint) -> Bool { near(a.x, b.x) && near(a.y, b.y) }

    private func recorded(_ result: [String: Value]) -> Bool? { result["undo"]?.objectValue?["recorded"]?.boolValue }

    // MARK: Moving and placing

    @Test func moveLayerTakesAFoldersContentsAndTheirMasksAsOneStep() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 64)
        let session = workspace.current.session
        try insert(try solid(width: 8, height: 8), name: "A", in: session)
        try insert(try solid(width: 8, height: 8), name: "B", at: CGPoint(x: 10, y: 10), in: session)
        let mask = try LayerMask.asset(from: try maskImage(width: 4, height: 4))
        let linked = LayerTransform(origin: CGPoint(x: 3, y: 3), size: CGSize(width: 4, height: 4))
        let unlinked = LayerTransform(origin: CGPoint(x: 20, y: 20), size: CGSize(width: 4, height: 4))
        let a = try index(of: "A", in: session), b = try index(of: "B", in: session)
        session.document?.layers[a].mask = LayerMask(asset: mask, placement: linked, isLinked: true)
        session.document?.layers[b].mask = LayerMask(asset: mask, placement: unlinked, isLinked: false)
        try await MCPTestSupport.call("group_layers", ["layers": ["A", "B"], "name": "Folder"], in: workspace)

        let before = session.history.undoCount
        let moved = try await MCPTestSupport.call("move_layer", ["layer": "Folder", "dx": 5, "dy": -2], in: workspace)
        #expect(layer("A", in: session)?.transform.origin == CGPoint(x: 5, y: -2))
        #expect(layer("B", in: session)?.transform.origin == CGPoint(x: 15, y: 8))
        // A linked mask placed apart moves with its layer; an unlinked one stays where it is on the document.
        #expect(layer("A", in: session)?.mask?.placement?.origin == CGPoint(x: 8, y: 1))
        #expect(layer("B", in: session)?.mask?.placement == unlinked)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Move Layer")
        #expect(moved["layer_id"]?.stringValue == layer("Folder", in: session)?.id.uuidString)

        let still = try await MCPTestSupport.call("move_layer", ["layer": "A", "dx": 0, "dy": 0], in: workspace)
        #expect(recorded(still) == false)
        try await MCPTestSupport.call("move_layer", ["layer": "A", "dx": 2_000_000, "dy": 0], in: workspace, expectError: "invalid_argument")
        #expect(layer("A", in: session)?.transform.origin == CGPoint(x: 5, y: -2))
    }

    @Test func setLayerTransformPlacesAndResizesAboutAnAnchor() async throws {
        let workspace = MCPTestSupport.workspace(width: 100, height: 100)
        let session = workspace.current.session
        try insert(try solid(width: 20, height: 10), name: "Box", at: CGPoint(x: 10, y: 10), in: session)

        // With an anchor, x and y place that point of the layer: here, its middle on the canvas's.
        try await MCPTestSupport.call("set_layer_transform", ["layer": "Box", "anchor": "center", "x": 50, "y": 50], in: workspace)
        #expect(layer("Box", in: session)?.transform.origin == CGPoint(x: 40, y: 45))
        // Resizing keeps the anchor where it was.
        let resized = try await MCPTestSupport.call("set_layer_transform", ["layer": "Box", "anchor": "bottom_right", "width": 40, "height": 20],
                                                    in: workspace)
        #expect(layer("Box", in: session)?.transform.origin == CGPoint(x: 20, y: 35))
        #expect(layer("Box", in: session)?.transform.size == CGSize(width: 40, height: 20))
        #expect(resized["transform"]?.objectValue?["width"]?.doubleValue == 40)
        // So does turning it: a quarter turn about the top-left corner.
        try await MCPTestSupport.call("set_layer_transform", ["layer": "Box", "anchor": "top_left", "rotation": 90], in: workspace)
        let turned = try #require(layer("Box", in: session)?.transform)
        #expect(near(turned.point(CGPoint(x: 0, y: 0)), CGPoint(x: 20, y: 35)) && turned.rotation == 90)
        // Without an anchor, x and y are the top-left of the unturned box, as before.
        try await MCPTestSupport.call("set_layer_transform", ["layer": "Box", "x": 0, "y": 0, "rotation": 0], in: workspace)
        #expect(layer("Box", in: session)?.transform.origin == .zero)
        let same = try await MCPTestSupport.call("set_layer_transform", ["layer": "Box", "x": 0, "y": 0], in: workspace)
        #expect(recorded(same) == false)

        try await MCPTestSupport.call("set_layer_transform", ["layer": "Box", "anchor": "somewhere", "x": 1], in: workspace,
                                      expectError: "invalid_argument")
        // A folder can be moved, not resized, turned or flipped.
        try await MCPTestSupport.call("group_layers", ["layers": ["Box"], "name": "Folder"], in: workspace)
        try await MCPTestSupport.call("set_layer_transform", ["layer": "Folder", "width": 10], in: workspace, expectError: "invalid_argument")
        #expect(layer("Box", in: session)?.transform.size == CGSize(width: 40, height: 20))
    }

    @Test func setLayerTransformPlacesAFolderByTheBoxAroundItsContents() async throws {
        let workspace = MCPTestSupport.workspace(width: 200, height: 200)
        let session = workspace.current.session
        // Contents well away from the canvas's top-left: their box is (120, 130)–(160, 160), 40 × 30.
        try insert(try solid(width: 20, height: 10), name: "A", at: CGPoint(x: 120, y: 130), in: session)
        try insert(try solid(width: 10, height: 10), name: "B", at: CGPoint(x: 150, y: 150), in: session)
        try await MCPTestSupport.call("group_layers", ["layers": ["A", "B"], "name": "Folder"], in: workspace)

        // The anchor is a point of the box around what the folder shows, not of the folder's own (canvas-sized) box.
        let before = session.history.undoCount
        let centered = try await MCPTestSupport.call("set_layer_transform", ["layer": "Folder", "anchor": "center", "x": 100, "y": 100],
                                                     in: workspace)
        #expect(layer("A", in: session)?.transform.origin == CGPoint(x: 80, y: 85))
        #expect(layer("B", in: session)?.transform.origin == CGPoint(x: 110, y: 105))
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Move Layer")
        #expect(recorded(centered) == true)
        #expect(centered["bounds"] == MCPValues.rect(CGRect(x: 80, y: 85, width: 40, height: 30)))
        let again = try await MCPTestSupport.call("set_layer_transform", ["layer": "Folder", "anchor": "center", "x": 100, "y": 100],
                                                  in: workspace)
        #expect(recorded(again) == false && session.history.undoCount == before + 1)

        // Another anchor, and a coordinate left out keeps that one where it is.
        try await MCPTestSupport.call("set_layer_transform", ["layer": "Folder", "anchor": "bottom_right", "x": 200, "y": 200], in: workspace)
        #expect(layer("A", in: session)?.transform.origin == CGPoint(x: 160, y: 170))
        #expect(layer("B", in: session)?.transform.origin == CGPoint(x: 190, y: 190))
        try await MCPTestSupport.call("set_layer_transform", ["layer": "Folder", "anchor": "left", "x": 150], in: workspace)
        #expect(layer("A", in: session)?.transform.origin == CGPoint(x: 150, y: 170))
        // Without an anchor, x and y are the top-left of that box.
        try await MCPTestSupport.call("set_layer_transform", ["layer": "Folder", "x": 0, "y": 0], in: workspace)
        #expect(layer("A", in: session)?.transform.origin == CGPoint(x: 0, y: 0))
        #expect(layer("B", in: session)?.transform.origin == CGPoint(x: 30, y: 20))

        // Hidden layers don't count toward the box, but they move along.
        try await MCPTestSupport.call("set_layer_visibility", ["layer": "B", "visible": false], in: workspace)
        try await MCPTestSupport.call("set_layer_transform", ["layer": "Folder", "anchor": "center", "x": 100, "y": 100], in: workspace)
        #expect(layer("A", in: session)?.transform.origin == CGPoint(x: 90, y: 95))
        #expect(layer("B", in: session)?.transform.origin == CGPoint(x: 120, y: 115))

        // A folder showing nothing has no box to place, and a place beyond ±1,000,000 pixels is refused.
        try await MCPTestSupport.call("add_group", ["name": "Empty"], in: workspace)
        let empty = try await MCPTestSupport.call("set_layer_transform", ["layer": "Empty", "x": 5], in: workspace,
                                                  expectError: "precondition_failed")
        #expect(errorObject(empty)["guard"]?.stringValue == "has_pixels")
        let document = try #require(session.document)
        try await MCPTestSupport.call("set_layer_transform", ["layer": "Folder", "x": 999_990], in: workspace, expectError: "invalid_argument")
        #expect(session.document?.layers == document.layers)
    }

    // MARK: Scaling

    @Test func setLayerScaleSizesFromThePixelsAndRedrawsLiveShapes() async throws {
        let workspace = MCPTestSupport.workspace(width: 200, height: 200)
        let session = workspace.current.session
        try insert(try solid(width: 64, height: 32), name: "Photo", at: CGPoint(x: 10, y: 10), in: session)

        let before = session.history.undoCount
        try await MCPTestSupport.call("set_layer_scale", ["layer": "Photo", "percent": 50], in: workspace)
        var transform = try #require(layer("Photo", in: session)?.transform)
        #expect(transform.size == CGSize(width: 32, height: 16) && transform.center == CGPoint(x: 42, y: 26))
        #expect(session.history.undoCount == before + 1)
        // The percentage is of the layer's pixels, so asking again changes nothing.
        let again = try await MCPTestSupport.call("set_layer_scale", ["layer": "Photo", "percent": 50], in: workspace)
        #expect(recorded(again) == false)
        // Not keeping the center keeps the top-left corner.
        try await MCPTestSupport.call("set_layer_scale", ["layer": "Photo", "percent": 200, "keep_center": false], in: workspace)
        transform = try #require(layer("Photo", in: session)?.transform)
        #expect(transform.size == CGSize(width: 128, height: 64) && transform.origin == CGPoint(x: 26, y: 18))
        try await MCPTestSupport.call("set_layer_scale", ["layer": "Photo", "percent": 0], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("set_layer_scale", ["layer": "Photo", "percent": 20_000], in: workspace, expectError: "invalid_argument")

        // A live shape draws itself again at its new size, and stays a shape.
        session.selectTool(.shape)
        session.beginShape(at: CGPoint(x: 10, y: 10))
        session.dragShape(to: CGPoint(x: 30, y: 20), square: false, fromCenter: false)
        session.finishShape()
        let shape = try #require(session.activeLayer)
        #expect(shape.liveShape != nil && shape.asset?.image.width == 20)
        try await MCPTestSupport.call("set_layer_scale", ["layer": .string(shape.id.uuidString), "percent": 200], in: workspace)
        let scaled = try #require(session.document?.layers.first { $0.id == shape.id })
        #expect(scaled.transform.size == CGSize(width: 40, height: 20))
        #expect(scaled.asset?.image.width == 40 && scaled.asset?.image.height == 20)
        #expect(scaled.liveShape != nil)
    }

    @Test func scaleLayerToFitContainKeepsAspectAndCenters() async throws {
        let workspace = MCPTestSupport.workspace(width: 200, height: 200)
        let session = workspace.current.session
        try insert(try solid(width: 40, height: 20), name: "Wide", at: CGPoint(x: 5, y: 7), in: session)
        let rect: Value = ["x": 50, "y": 50, "width": 100, "height": 100]

        let before = session.history.undoCount
        let fitted = try await MCPTestSupport.call("scale_layer_to_fit", ["layer": "Wide", "rect": rect, "mode": "contain"], in: workspace)
        var transform = try #require(layer("Wide", in: session)?.transform)
        #expect(transform.size == CGSize(width: 100, height: 50))
        #expect(transform.center == CGPoint(x: 100, y: 100))
        #expect(session.history.undoCount == before + 1)
        #expect(fitted["transform"]?.objectValue?["width"]?.doubleValue == 100)
        let again = try await MCPTestSupport.call("scale_layer_to_fit", ["layer": "Wide", "rect": rect, "mode": "contain"], in: workspace)
        #expect(recorded(again) == false)

        // Cover fills the rectangle, spilling over on the long side; the anchor pins it to a corner.
        try await MCPTestSupport.call("scale_layer_to_fit", ["layer": "Wide", "rect": rect, "mode": "cover", "anchor": "top_left"],
                                      in: workspace)
        transform = try #require(layer("Wide", in: session)?.transform)
        #expect(transform.size == CGSize(width: 200, height: 100) && transform.origin == CGPoint(x: 50, y: 50))
        // Stretch fills it exactly.
        try await MCPTestSupport.call("scale_layer_to_fit", ["layer": "Wide", "rect": rect, "mode": "stretch"], in: workspace)
        transform = try #require(layer("Wide", in: session)?.transform)
        #expect(transform.size == CGSize(width: 100, height: 100) && transform.origin == CGPoint(x: 50, y: 50))

        // A turned layer fits by the upright box around it.
        try await MCPTestSupport.call("set_layer_transform", ["layer": "Wide", "width": 40, "height": 20, "rotation": 90], in: workspace)
        try await MCPTestSupport.call("scale_layer_to_fit", ["layer": "Wide", "rect": rect, "mode": "contain"], in: workspace)
        transform = try #require(layer("Wide", in: session)?.transform)
        #expect(near(transform.size.width, 100) && near(transform.size.height, 50) && transform.rotation == 90)
        let upright = try box("Wide", in: session)
        #expect(near(upright.minX, 75) && near(upright.minY, 50) && near(upright.width, 50) && near(upright.height, 100))

        try await MCPTestSupport.call("scale_layer_to_fit", ["layer": "Wide", "rect": rect, "mode": "squash"], in: workspace,
                                      expectError: "invalid_argument")
        try await MCPTestSupport.call("scale_layer_to_fit", ["layer": "Wide", "rect": ["x": 0, "y": 0, "width": 0, "height": 10],
                                                             "mode": "contain"], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("add_group", ["name": "Folder"], in: workspace)
        let folder = try await MCPTestSupport.call("scale_layer_to_fit", ["layer": "Folder", "rect": rect, "mode": "contain"], in: workspace,
                                                   expectError: "precondition_failed")
        #expect(errorObject(folder)["guard"]?.stringValue == "has_pixels")
    }

    @Test func scaleLayerToFitStretchKeepsAnAngleThatIsNotAQuarterTurn() async throws {
        let workspace = MCPTestSupport.workspace(width: 200, height: 200)
        let session = workspace.current.session
        try insert(try solid(width: 40, height: 20), name: "Tilted", at: CGPoint(x: 5, y: 7), in: session)
        try await MCPTestSupport.call("set_layer_transform", ["layer": "Tilted", "rotation": 30, "flip_x": true], in: workspace)
        func fillsExactly(_ rect: CGRect) throws -> Bool {
            let upright = try box("Tilted", in: session)
            return near(upright.minX, rect.minX) && near(upright.minY, rect.minY)
                && near(upright.width, rect.width) && near(upright.height, rect.height)
        }
        @discardableResult func stretch(_ rect: CGRect, expectError: String? = nil) async throws -> [String: Value] {
            let value: Value = ["x": .double(rect.minX), "y": .double(rect.minY), "width": .double(rect.width), "height": .double(rect.height)]
            return try await MCPTestSupport.call("scale_layer_to_fit", ["layer": "Tilted", "rect": value, "mode": "stretch"], in: workspace,
                                                 expectError: expectError)
        }

        // Turned 30°, the layer keeps its angle and flip and takes the sides whose upright box is the rectangle.
        let square = CGRect(x: 50, y: 50, width: 100, height: 100)
        let before = session.history.undoCount
        try await stretch(square)
        let transform = try #require(layer("Tilted", in: session)?.transform)
        let filled = try fillsExactly(square)
        #expect(transform.rotation == 30 && transform.flipX && !transform.flipY)
        #expect(filled)
        #expect(session.history.undoCount == before + 1)
        // So stretching again changes nothing and records nothing.
        let again = try await stretch(square)
        #expect(recorded(again) == false && session.history.undoCount == before + 1)
        #expect(layer("Tilted", in: session)?.transform == transform)

        // A longer rectangle works while a box turned that far can be that long (up to √3 : 1 at 30°).
        let wide = CGRect(x: 10, y: 20, width: 120, height: 80)
        try await stretch(wide)
        let filledWide = try fillsExactly(wide)
        #expect(layer("Tilted", in: session)?.transform.rotation == 30 && filledWide)
        // Beyond that no turned box fills it: refused, and nothing changes.
        let placed = try #require(layer("Tilted", in: session)?.transform)
        let tooWide = try await stretch(CGRect(x: 0, y: 0, width: 200, height: 100), expectError: "invalid_argument")
        #expect(errorObject(tooWide)["message"]?.stringValue?.contains("30") == true)
        #expect(layer("Tilted", in: session)?.transform == placed)

        // At 45° only a square rectangle can be filled; it then gets equal sides.
        try await MCPTestSupport.call("set_layer_transform", ["layer": "Tilted", "rotation": 45], in: workspace)
        try await stretch(CGRect(x: 0, y: 0, width: 100, height: 60), expectError: "invalid_argument")
        try await stretch(square)
        let diagonal = try #require(layer("Tilted", in: session)?.transform)
        let filledSquare = try fillsExactly(square)
        #expect(diagonal.rotation == 45 && near(diagonal.size.width, diagonal.size.height) && filledSquare)
        #expect(near(diagonal.size.width, 100 / 2.squareRoot()))
    }

    // MARK: Rotating, flipping, distorting

    @Test func rotateLayerRelativeTwiceDoublesTheAngle() async throws {
        let workspace = MCPTestSupport.workspace(width: 100, height: 100)
        let session = workspace.current.session
        try insert(try solid(width: 10, height: 10), name: "Tile", at: CGPoint(x: 40, y: 0), in: session)

        let before = session.history.undoCount
        try await MCPTestSupport.call("rotate_layer", ["layer": "Tile", "degrees": 30], in: workspace)
        let turned = try await MCPTestSupport.call("rotate_layer", ["layer": "Tile", "degrees": 30], in: workspace)
        #expect(layer("Tile", in: session)?.transform.rotation == 60)
        #expect(layer("Tile", in: session)?.transform.center == CGPoint(x: 45, y: 5))
        #expect(session.history.undoCount == before + 2)
        #expect(turned["transform"]?.objectValue?["rotation"]?.doubleValue == 60)

        // An absolute angle replaces it; asking for the angle it already has records nothing.
        try await MCPTestSupport.call("rotate_layer", ["layer": "Tile", "degrees": 90, "relative": false], in: workspace)
        #expect(layer("Tile", in: session)?.transform.rotation == 90)
        let same = try await MCPTestSupport.call("rotate_layer", ["layer": "Tile", "degrees": 90, "relative": false], in: workspace)
        #expect(recorded(same) == false)

        // About a point, the layer swings around it: a quarter turn about the canvas middle takes the top to the right.
        try await MCPTestSupport.call("rotate_layer", ["layer": "Tile", "degrees": 90, "around": ["x": 50, "y": 50]], in: workspace)
        let swung = try #require(layer("Tile", in: session)?.transform)
        #expect(swung.rotation == 180 && near(swung.center, CGPoint(x: 95, y: 45)))
        try await MCPTestSupport.call("rotate_layer", ["layer": "Tile"], in: workspace, expectError: "invalid_argument")
    }

    @Test func flipLayerMirrorsLayersAboutTheirMiddleAndKeepsTheSelection() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 64)
        let session = workspace.current.session
        try insert(try solid(width: 10, height: 10), name: "A", in: session)
        let b = try insert(try solid(width: 10, height: 10), name: "B", at: CGPoint(x: 30, y: 0), in: session)

        let before = session.history.undoCount
        try await MCPTestSupport.call("flip_layer", ["layers": ["A"], "axis": "horizontal"], in: workspace)
        #expect(layer("A", in: session)?.transform.flipX == true && layer("A", in: session)?.transform.origin == .zero)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Flip Horizontal")
        // Several layers flip together, about the middle of the box around them.
        let flipped = try await MCPTestSupport.call("flip_layer", ["layers": ["A", "B"], "axis": "horizontal"], in: workspace)
        #expect(layer("A", in: session)?.transform.origin == CGPoint(x: 30, y: 0) && layer("A", in: session)?.transform.flipX == false)
        #expect(layer("B", in: session)?.transform.origin == .zero && layer("B", in: session)?.transform.flipX == true)
        #expect(flipped["layer_ids"]?.arrayValue?.count == 2)
        // The layers selected before are selected again.
        #expect(session.selectedLayerIDs == [b] && session.activeLayerID == b)

        try await MCPTestSupport.call("set_layer_visibility", ["layer": "A", "visible": false], in: workspace)
        let hidden = try await MCPTestSupport.call("flip_layer", ["layers": ["A"], "axis": "vertical"], in: workspace,
                                                   expectError: "precondition_failed")
        #expect(errorObject(hidden)["guard"]?.stringValue == "can_transform")
        try await MCPTestSupport.call("flip_layer", ["layers": ["B"], "axis": "diagonal"], in: workspace, expectError: "invalid_argument")
    }

    @Test func distortLayerWarpsItIntoTheCornersAsOneStep() async throws {
        let workspace = MCPTestSupport.workspace(width: 100, height: 60)
        let session = workspace.current.session
        try insert(try solid(width: 20, height: 20), name: "Red", at: CGPoint(x: 10, y: 10), in: session)
        let corners: Value = [["x": 10, "y": 10], ["x": 60, "y": 10], ["x": 30, "y": 30], ["x": 10, "y": 30]]

        let before = session.history.undoCount
        let distorted = try await MCPTestSupport.call("distort_layer", ["layer": "Red", "corners": corners], in: workspace)
        let transform = try #require(layer("Red", in: session)?.transform)
        #expect(transform.origin == CGPoint(x: 10, y: 10) && transform.size == CGSize(width: 50, height: 20) && transform.rotation == 0)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Distort")
        #expect(distorted["transform"]?.objectValue?["width"]?.doubleValue == 50)

        // A shape with nothing to draw, or not four corners, is refused.
        let collapsed: Value = [["x": 10, "y": 10], ["x": 10, "y": 10], ["x": 30, "y": 30], ["x": 10, "y": 30]]
        try await MCPTestSupport.call("distort_layer", ["layer": "Red", "corners": collapsed], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("distort_layer", ["layer": "Red", "corners": [["x": 0, "y": 0], ["x": 5, "y": 0], ["x": 5, "y": 5]]],
                                      in: workspace, expectError: "invalid_argument")
        // Distorting resamples the pixels, so locked pixels refuse it as well as a locked position.
        try await MCPTestSupport.call("set_layer_locks", ["layer": "Red", "pixels": true], in: workspace)
        let locked = try await MCPTestSupport.call("distort_layer", ["layer": "Red", "corners": corners], in: workspace,
                                                   expectError: "precondition_failed")
        #expect(errorObject(locked)["guard"]?.stringValue == "layer_locked")
        #expect(layer("Red", in: session)?.transform == transform)
    }

    // MARK: Aligning and distributing

    @Test func alignLayersLeftToCanvasPutsEveryLeftEdgeAtZero() async throws {
        let workspace = MCPTestSupport.workspace(width: 200, height: 100)
        let session = workspace.current.session
        try insert(try solid(width: 10, height: 10), name: "A", at: CGPoint(x: 30, y: 5), in: session)
        try insert(try solid(width: 20, height: 10), name: "B", at: CGPoint(x: 70, y: 40), in: session)
        try insert(try solid(width: 40, height: 10), name: "C", at: CGPoint(x: 120, y: 60), in: session)
        let c = try index(of: "C", in: session)
        session.document?.layers[c].transform.rotation = 90

        let before = session.history.undoCount
        try await MCPTestSupport.call("align_layers", ["layers": ["A", "B", "C"], "edge": "left", "to": "canvas"], in: workspace)
        for name in ["A", "B", "C"] {
            let aligned = try box(name, in: session)
            #expect(near(aligned.minX, 0), "\(name): \(aligned)")
        }
        #expect(layer("B", in: session)?.transform.origin.y == 40)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Align Layers")
        let again = try await MCPTestSupport.call("align_layers", ["layers": ["A", "B", "C"], "edge": "left", "to": "canvas"], in: workspace)
        #expect(recorded(again) == false)

        // To the layers: their right edges meet the rightmost one's.
        try await MCPTestSupport.call("align_layers", ["layers": ["A", "B"], "edge": "right", "to": "layers"], in: workspace)
        #expect(try box("A", in: session).maxX == 20 && box("B", in: session).maxX == 20)
        try await MCPTestSupport.call("align_layers", ["layers": ["A"], "edge": "center_y", "to": "canvas"], in: workspace)
        #expect(layer("A", in: session)?.transform.center.y == 50)

        // To the selection's bounds, once there is a selection.
        let none = try await MCPTestSupport.call("align_layers", ["layers": ["A"], "edge": "bottom", "to": "selection"], in: workspace,
                                                 expectError: "precondition_failed")
        #expect(errorObject(none)["guard"]?.stringValue == "selection")
        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 100, y: 20, width: 50, height: 30), transform: nil))
        try await MCPTestSupport.call("align_layers", ["layers": ["A", "B"], "edge": "bottom", "to": "selection"], in: workspace)
        #expect(try box("A", in: session).maxY == 50 && box("B", in: session).maxY == 50)

        // By content, a layer's transparent margin is left out.
        let sparse = try image(width: 4, height: 4) { x, y in x == 1 && y == 2 ? (255, 0, 0, 255) : (0, 0, 0, 0) }
        try insert(sparse, name: "Sparse", at: CGPoint(x: 10, y: 10), in: session)
        try await MCPTestSupport.call("align_layers", ["layers": ["Sparse"], "edge": "left", "to": "canvas", "use_content_bounds": true],
                                      in: workspace)
        #expect(layer("Sparse", in: session)?.transform.origin.x == -1)

        // A folder aligns by the box around what is in it, and its contents keep their places within it.
        try await MCPTestSupport.call("move_layer", ["layer": "A", "dx": 0, "dy": -7], in: workspace)
        try await MCPTestSupport.call("group_layers", ["layers": ["A", "B"], "name": "Folder"], in: workspace)
        try await MCPTestSupport.call("align_layers", ["layers": ["Folder"], "edge": "top", "to": "canvas"], in: workspace)
        #expect(try box("A", in: session).minY == 0 && box("B", in: session).minY == 7)

        let alone = try await MCPTestSupport.call("align_layers", ["layers": ["C"], "edge": "left", "to": "layers"], in: workspace,
                                                  expectError: "invalid_argument")
        #expect(errorObject(alone)["message"]?.stringValue?.contains("2") == true)
        try await MCPTestSupport.call("align_layers", ["layers": ["C"], "edge": "sideways", "to": "canvas"], in: workspace,
                                      expectError: "invalid_argument")
    }

    @Test func distributeLayersYieldsEqualGaps() async throws {
        let workspace = MCPTestSupport.workspace(width: 300, height: 100)
        let session = workspace.current.session
        try insert(try solid(width: 10, height: 10), name: "A", at: CGPoint(x: 0, y: 0), in: session)
        try insert(try solid(width: 20, height: 10), name: "B", at: CGPoint(x: 15, y: 30), in: session)
        try insert(try solid(width: 30, height: 10), name: "C", at: CGPoint(x: 100, y: 60), in: session)

        let before = session.history.undoCount
        try await MCPTestSupport.call("distribute_layers", ["layers": ["C", "A", "B"], "axis": "horizontal"], in: workspace)
        let a = try box("A", in: session), b = try box("B", in: session), c = try box("C", in: session)
        #expect(a.minX == 0 && c.minX == 100)
        #expect(b.minX - a.maxX == 35 && c.minX - b.maxX == 35)
        #expect(b.minY == 30)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Distribute Layers")
        let again = try await MCPTestSupport.call("distribute_layers", ["layers": ["A", "B", "C"], "axis": "horizontal"], in: workspace)
        #expect(recorded(again) == false)
        // Vertically they are already evenly spaced.
        let vertical = try await MCPTestSupport.call("distribute_layers", ["layers": ["A", "B", "C"], "axis": "vertical"], in: workspace)
        #expect(recorded(vertical) == false)

        // A spacing lays them out from the first, that far apart.
        try await MCPTestSupport.call("distribute_layers", ["layers": ["A", "B", "C"], "axis": "horizontal", "spacing": 5], in: workspace)
        #expect(try box("A", in: session).minX == 0 && box("B", in: session).minX == 15 && box("C", in: session).minX == 40)

        try await MCPTestSupport.call("distribute_layers", ["layers": ["A", "B"], "axis": "horizontal"], in: workspace,
                                      expectError: "invalid_argument")
        try await MCPTestSupport.call("distribute_layers", ["layers": ["A", "B", "C"], "axis": "diagonal"], in: workspace,
                                      expectError: "invalid_argument")
    }

    // MARK: Locks

    @Test func positionLockedLayerFailsEveryTransformTool() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 64)
        let session = workspace.current.session
        try insert(try solid(width: 8, height: 8), name: "A", at: CGPoint(x: 4, y: 4), in: session)
        try insert(try solid(width: 8, height: 8), name: "B", at: CGPoint(x: 20, y: 4), in: session)
        try insert(try solid(width: 8, height: 8), name: "C", at: CGPoint(x: 40, y: 4), in: session)
        try await MCPTestSupport.call("set_layer_locks", ["layer": "A", "position": true], in: workspace)
        let document = try #require(session.document)
        let count = session.history.undoCount

        let corners: Value = [["x": 0, "y": 0], ["x": 10, "y": 0], ["x": 10, "y": 10], ["x": 0, "y": 10]]
        let refusals: [(String, [String: Value])] = [
            ("move_layer", ["layer": "A", "dx": 1, "dy": 1]),
            ("set_layer_transform", ["layer": "A", "x": 3]),
            ("set_layer_scale", ["layer": "A", "percent": 50]),
            ("scale_layer_to_fit", ["layer": "A", "rect": ["x": 0, "y": 0, "width": 32, "height": 32], "mode": "contain"]),
            ("rotate_layer", ["layer": "A", "degrees": 45]),
            ("flip_layer", ["layers": ["B", "A"], "axis": "horizontal"]),
            ("distort_layer", ["layer": "A", "corners": corners]),
            ("align_layers", ["layers": ["B", "A"], "edge": "left", "to": "canvas"]),
            ("distribute_layers", ["layers": ["A", "B", "C"], "axis": "vertical", "spacing": 2]),
        ]
        for (tool, args) in refusals {
            let refused = try await MCPTestSupport.call(tool, args, in: workspace, expectError: "precondition_failed")
            #expect(errorObject(refused)["guard"]?.stringValue == "layer_locked", "\(tool): \(refused)")
        }
        #expect(session.document?.layers == document.layers)
        #expect(session.history.undoCount == count)
        try await MCPTestSupport.call("move_layer", ["layer": "B", "dx": 1, "dy": 0], in: workspace)
    }
}
