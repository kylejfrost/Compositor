import CoreGraphics
import Foundation
import ImageIO
import Testing
import MCP
@testable import Compositor

/// The Layers domain: reading a layer, creating and placing layers, their appearance and locks, deleting (baking
/// what was clipped to them), duplicating, grouping and ungrouping, merging, flattening and rasterizing.
@MainActor struct MCPLayerToolTests {
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

    private func solid(width: Int, height: Int, _ rgba: (UInt8, UInt8, UInt8, UInt8)) throws -> CGImage {
        try image(width: width, height: height) { _, _ in rgba }
    }

    /// Adds `image` as a new layer at `origin` (its own pixel size, nearest sampling) and returns its id.
    @discardableResult
    private func insert(_ image: CGImage, name: String, at origin: CGPoint = .zero, in session: EditorSession) throws -> UUID {
        session.insert(ImportedImage(image: image, thumbnail: image, name: name))
        let id = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].transform.origin = origin
        session.document?.layers[index].transform.sampling = .nearest
        return id
    }

    /// `image`'s premultiplied RGBA bytes, drawn 1:1 into a fresh context.
    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: image.width * image.height * 4))
    }

    private func alpha(_ image: CGImage) throws -> [UInt8] {
        try rgba(image).enumerated().filter { $0.offset % 4 == 3 }.map(\.element)
    }

    private func pngFile(_ image: CGImage, named name: String) throws -> URL {
        let url = MCPTestSupport.tempFile(name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func errorObject(_ result: [String: Value]) -> [String: Value] {
        result["error"]?.objectValue ?? [:]
    }

    private func layer(_ name: String, in session: EditorSession) -> ImageLayer? {
        session.document?.layers.first { $0.name == name }
    }

    /// The names of `parent`'s contents (nil: the top level), bottom to top.
    private func names(in parent: UUID?, of session: EditorSession) -> [String] {
        session.document?.layers.filter { $0.parentID == parent }.map(\.name) ?? []
    }

    // MARK: Reading

    @Test func getLayerDescribesOneLayerWithContentBoundsWhenFull() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 48)
        let session = workspace.current.session
        let sparse = try image(width: 4, height: 4) { x, y in x == 1 && y == 2 ? (255, 0, 0, 255) : (0, 0, 0, 0) }
        let id = try insert(sparse, name: "Sparse", at: CGPoint(x: 10, y: 20), in: session)
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].fillOpacity = 0.4
        session.document?.layers[index].locks = [.position]

        let full = try await MCPTestSupport.call("get_layer", ["layer": "Sparse"], in: workspace)
        let described = try #require(full["layer"]?.objectValue)
        #expect(described["id"]?.stringValue == id.uuidString)
        #expect(described["kind"]?.stringValue == "raster")
        #expect(described["fill_opacity"]?.doubleValue == 0.4)
        #expect(described["locks"] == .array([.string("position")]))
        let bounds = try #require(described["content_bounds"]?.objectValue)
        #expect(bounds["x"]?.doubleValue == 11 && bounds["y"]?.doubleValue == 22)
        #expect(bounds["width"]?.doubleValue == 1 && bounds["height"]?.doubleValue == 1)

        let summary = try await MCPTestSupport.call("get_layer", ["layer": "Sparse", "detail": "summary"], in: workspace)
        #expect(summary["layer"]?.objectValue?["content_bounds"] == nil)

        let folder = try await MCPTestSupport.call("add_group", ["name": "Folder"], in: workspace)
        let folderID = try #require(folder["group_id"]?.stringValue)
        try await MCPTestSupport.call("place_layer", ["layer": "Sparse", "parent": .string(folderID)], in: workspace)
        let group = try await MCPTestSupport.call("get_layer", ["layer": "Folder"], in: workspace)
        let children = group["layer"]?.objectValue?["children"]?.arrayValue
        #expect(children?.compactMap { $0.objectValue?["name"]?.stringValue } == ["Sparse"])
        #expect(group["layer"]?.objectValue?["content_bounds"]?.objectValue?["x"]?.doubleValue == 11)
        try await MCPTestSupport.call("get_layer", ["layer": "Nope"], in: workspace, expectError: "not_found")
    }

    // MARK: Creation

    @Test func addBlankLayerGoesIntoAFolderOrAboveALayerAsOneStep() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        let session = workspace.current.session
        let folder = try await MCPTestSupport.call("add_group", ["name": "F"], in: workspace)
        let folderID = try #require(folder["group_id"]?.stringValue.flatMap(UUID.init))

        let before = session.history.undoCount
        let inside = try await MCPTestSupport.call("add_blank_layer", ["name": "In", "parent": "F"], in: workspace)
        #expect(layer("In", in: session)?.parentID == folderID)
        #expect(inside["layer_id"]?.stringValue == layer("In", in: session)?.id.uuidString)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "New Blank Layer")

        try await MCPTestSupport.call("add_blank_layer", ["name": "Low", "above": "Layer 1"], in: workspace)
        #expect(names(in: nil, of: session) == ["Layer 1", "Low", "F"])
        try await MCPTestSupport.call("add_blank_layer", ["name": "Top", "parent": .null], in: workspace)
        #expect(names(in: nil, of: session) == ["Layer 1", "Low", "F", "Top"])

        let refused = try await MCPTestSupport.call("add_blank_layer", ["parent": "Layer 1"], in: workspace, expectError: "invalid_argument")
        #expect(errorObject(refused)["message"]?.stringValue?.contains("not a folder") == true)
        try await MCPTestSupport.call("add_blank_layer", ["parent": "F", "above": "Low"], in: workspace, expectError: "invalid_argument")
        #expect(session.document?.layers.count == 5)
    }

    @Test func addImageLayerCentersAndFitsInOneStep() async throws {
        let workspace = MCPTestSupport.workspace(width: 100, height: 50)
        let session = workspace.current.session
        let url = try pngFile(try solid(width: 20, height: 20, (0, 128, 255, 255)), named: "square.png")

        let before = session.history.undoCount
        let placed = try await MCPTestSupport.call("add_image_layer", [
            "path": .string(url.path), "name": "Photo", "center": ["x": 10, "y": 10],
        ], in: workspace)
        let photo = try #require(layer("Photo", in: session))
        #expect(placed["layer_id"]?.stringValue == photo.id.uuidString)
        #expect(photo.transform.origin == .zero && photo.transform.size == CGSize(width: 20, height: 20))
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Import Image")

        try await MCPTestSupport.call("add_image_layer", ["path": .string(url.path), "name": "Contained", "fit": "contain"], in: workspace)
        let contained = try #require(layer("Contained", in: session))
        #expect(contained.transform.size == CGSize(width: 50, height: 50))
        #expect(contained.transform.origin == CGPoint(x: 25, y: 0))

        try await MCPTestSupport.call("add_image_layer", [
            "path": .string(url.path), "name": "Covered", "fit": "cover", "center": ["x": 10, "y": 10],
        ], in: workspace)
        let covered = try #require(layer("Covered", in: session))
        #expect(covered.transform.size == CGSize(width: 100, height: 100))
        #expect(covered.transform.center == CGPoint(x: 10, y: 10))
        #expect(session.history.undoCount == before + 3)

        try await MCPTestSupport.call("add_image_layer", ["path": .string(url.path), "fit": "stretchy"], in: workspace, expectError: "invalid_argument")
        let legacy = try await MCPTestSupport.call("add_image_layer", ["path": .string(url.path), "center_x": 5, "center_y": 5],
                                                   in: workspace, expectError: "invalid_argument")
        #expect(errorObject(legacy)["hint"]?.stringValue?.contains("center") == true)
        #expect(session.history.undoCount == before + 3)
    }

    /// An SVG comes in as pixels, as the app imports one (upstream): drawn at its own size, or at the size a fit gives
    /// it, so a fitted drawing stays sharp. place_smart_object is the way to keep it vector.
    @Test func addImageLayerDrawsAnSVGIntoPixels() async throws {
        let workspace = MCPTestSupport.workspace(width: 200, height: 100)
        let session = workspace.current.session
        let url = MCPTestSupport.tempFile("badge.svg")
        try Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><rect width="40" height="20" fill="#ff0000"/></svg>"##.utf8)
            .write(to: url)
        try await MCPTestSupport.call("add_image_layer", ["path": .string(url.path), "name": "Badge"], in: workspace)
        let badge = try #require(layer("Badge", in: session))
        #expect(badge.asset?.image.width == 40 && badge.asset?.image.height == 20)
        #expect(badge.smartObject == nil && badge.transform.size == CGSize(width: 40, height: 20))
        try await MCPTestSupport.call("add_image_layer", ["path": .string(url.path), "name": "Fitted", "fit": "contain"], in: workspace)
        let fitted = try #require(layer("Fitted", in: session))
        #expect(fitted.asset?.image.width == 200 && fitted.asset?.image.height == 100)
        #expect(fitted.transform.size == CGSize(width: 200, height: 100))
        let image = try #require(fitted.asset?.image)
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -100, y: -50, width: 200, height: 100))
        let pixel = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
        #expect(pixel[0] > 240 && pixel[1] < 10 && pixel[3] == 255)
    }

    /// Fitted to cover a canvas of another shape, an SVG is drawn at the covering size, not at the size that fits
    /// inside and then scaled up to cover (which left it soft). One too long for a layer at that size is drawn as large
    /// as a layer may be, and its transform scales up the rest.
    @Test func addImageLayerDrawsAnSVGAtTheSizeCoverGivesIt() async throws {
        let workspace = MCPTestSupport.workspace(width: 200, height: 100)
        let session = workspace.current.session
        // Square on a 2:1 canvas: contain would draw it 100×100; cover fills 200×200. Red left half, blue right half.
        let url = MCPTestSupport.tempFile("square.svg")
        try Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><rect width="10" height="20" fill="#ff0000"/><rect x="10" width="10" height="20" fill="#0000ff"/></svg>"##.utf8)
            .write(to: url)
        try await MCPTestSupport.call("add_image_layer", ["path": .string(url.path), "name": "Cover", "fit": "cover"], in: workspace)
        let cover = try #require(layer("Cover", in: session))
        let image = try #require(cover.asset?.image)
        #expect(image.width == 200 && image.height == 200, "\(image.width)×\(image.height)")
        #expect(cover.transform.size == CGSize(width: 200, height: 200))
        #expect(cover.transform.origin == CGPoint(x: 0, y: -50))
        // Drawn at this size, the halves meet on a pixel boundary: no column is a blend of the two.
        let context = try #require(CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 800,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 200, height: 200))
        let pixels = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
        let row = 100 * 800
        #expect(pixels[row + 99 * 4] > 240 && pixels[row + 99 * 4 + 2] < 10, "column 99 is red")
        #expect(pixels[row + 100 * 4] < 10 && pixels[row + 100 * 4 + 2] > 240, "column 100 is blue")
        try await MCPTestSupport.call("add_image_layer", ["path": .string(url.path), "name": "Contain", "fit": "contain"], in: workspace)
        #expect(try #require(layer("Contain", in: session)).asset?.image.width == 100)

        // 1×1000 covering 200×100 would be 200×200,000: drawn 30×30,000 (the longest side a layer may have), shown at 200×200,000.
        let tall = MCPTestSupport.tempFile("tall.svg")
        try Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1000"><rect width="1" height="1000" fill="#00ff00"/></svg>"##.utf8)
            .write(to: tall)
        try await MCPTestSupport.call("add_image_layer", ["path": .string(tall.path), "name": "Tall", "fit": "cover"], in: workspace)
        let long = try #require(layer("Tall", in: session))
        #expect(long.asset?.image.width == 30 && long.asset?.image.height == 30_000,
                "\(long.asset?.image.width ?? 0)×\(long.asset?.image.height ?? 0)")
        #expect(abs(long.transform.size.width - 200) < 0.001 && abs(long.transform.size.height - 200_000) < 0.01,
                "\(long.transform.size)")
    }

    /// Like every other tool that adds a layer: directly above the active layer, or at the top of the active folder.
    @Test func addImageLayerGoesDirectlyAboveTheActiveLayer() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        let session = workspace.current.session
        let url = try pngFile(try solid(width: 4, height: 4, (255, 0, 0, 255)), named: "texture.png")
        try await MCPTestSupport.call("add_blank_layer", ["name": "Photo"], in: workspace)
        try await MCPTestSupport.call("add_blank_layer", ["name": "Title"], in: workspace)
        try await MCPTestSupport.call("select_layers", ["layers": ["Layer 1"]], in: workspace)
        let added = try await MCPTestSupport.call("add_image_layer", ["path": .string(url.path), "name": "Texture"], in: workspace)
        #expect(names(in: nil, of: session) == ["Layer 1", "Texture", "Photo", "Title"])
        #expect(added["layer_id"]?.stringValue == session.activeLayerID?.uuidString)

        let folder = try await MCPTestSupport.call("add_group", ["name": "F"], in: workspace)
        let folderID = try #require(folder["group_id"]?.stringValue.flatMap(UUID.init))
        try await MCPTestSupport.call("add_blank_layer", ["name": "In", "parent": "F"], in: workspace)
        try await MCPTestSupport.call("add_blank_layer", ["name": "Top", "parent": .null], in: workspace)
        try await MCPTestSupport.call("select_layers", ["layers": ["F"]], in: workspace)
        let topLevel = names(in: nil, of: session)
        try await MCPTestSupport.call("add_image_layer", ["path": .string(url.path), "name": "In F"], in: workspace)
        #expect(names(in: folderID, of: session) == ["In", "In F"])
        #expect(names(in: nil, of: session) == topLevel)
        let order = session.document?.layers.map(\.name) ?? []
        #expect(order.firstIndex(of: "In F") == order.firstIndex(of: "In").map { $0 + 1 }, "\(order)")
    }

    /// New Blank Layer, Place Smart Object and add_image_layer place their layer by one rule
    /// (`EditorSession.insertionIndex(above:in:)`): with the same layer or folder active, each lands at the same index,
    /// in the same folder, including above a nested folder's contents when the outer folder is active.
    @Test func everyLayerCreatorPlacesItsLayerByTheSameRule() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        let session = workspace.current.session
        let url = try pngFile(try solid(width: 4, height: 4, (255, 0, 0, 255)), named: "texture.png")
        try await MCPTestSupport.call("add_blank_layer", ["name": "Photo"], in: workspace)
        try await MCPTestSupport.call("add_group", ["name": "Outer"], in: workspace)
        try await MCPTestSupport.call("add_group", ["name": "Inner"], in: workspace)
        try await MCPTestSupport.call("add_blank_layer", ["name": "Deep"], in: workspace)
        try await MCPTestSupport.call("add_blank_layer", ["name": "Top", "parent": .null], in: workspace)
        let outer = try #require(layer("Outer", in: session)), inner = try #require(layer("Inner", in: session))
        #expect(inner.parentID == outer.id && layer("Deep", in: session)?.parentID == inner.id)
        let before = try #require(session.document)
        for active in ["Layer 1", "Photo", "Outer", "Inner", "Deep", "Top"] {
            var placed: [String] = []
            for tool in ["add_blank_layer", "place_smart_object", "add_image_layer"] {
                try await MCPTestSupport.call("select_layers", ["layers": .array([.string(active)])], in: workspace)
                let arguments: [String: Value] = tool == "add_blank_layer" ? ["name": "New"] : ["path": .string(url.path), "name": "New"]
                try await MCPTestSupport.call(tool, arguments, in: workspace)
                let layers = try #require(session.document?.layers)
                let index = try #require(layers.firstIndex { $0.name == "New" }, "\(tool) with \(active) active")
                let parent = layers[index].parentID.flatMap { id in layers.first { $0.id == id }?.name } ?? "top level"
                placed.append("\(index) in \(parent)")
                try await MCPTestSupport.call("undo", in: workspace)
                #expect(session.document == before, "\(tool) with \(active) active")
            }
            #expect(Set(placed).count == 1, "\(active) active: \(placed)")
        }
        // With the outer folder active, the new layer goes above the inner folder's contents, not just above Outer.
        try await MCPTestSupport.call("select_layers", ["layers": ["Outer"]], in: workspace)
        try await MCPTestSupport.call("add_image_layer", ["path": .string(url.path), "name": "New"], in: workspace)
        let order = session.document?.layers.map(\.name) ?? []
        let topmost = before.layers.lastIndex { $0.parentID == outer.id || $0.parentID == inner.id }
        #expect(order.firstIndex(of: "New") == topmost.map { $0 + 1 }, "\(order)")
        #expect(layer("New", in: session)?.parentID == outer.id)
    }

    /// Reading the image lets the app run. An edit the owner starts meanwhile (typing text, here) stops the call
    /// before the layer goes in: inserted inside that open edit, it would be recorded with it, or thrown away when
    /// the owner cancels, though the call reported success.
    @Test func addImageLayerStopsWhenTheAppBeginsAnEditWhileTheImageIsRead() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 64)
        let session = workspace.current.session
        let url = try pngFile(try solid(width: 1000, height: 1000, (0, 128, 255, 255)), named: "big.png")
        let layers = session.document?.layers.count
        // Runs at the call's first wait, which is the decode: a path outside the protected folders isn't waited on.
        let intruder = Task { @MainActor in session.beginText(at: CGPoint(x: 2, y: 2)) }
        let result = await MCPToolRegistry.call("add_image_layer", ["path": .string(url.path), "name": "Agent"], workspace: workspace)
        await intruder.value
        #expect(session.textDraft != nil)
        let object = result.structuredContent?.objectValue ?? [:]
        #expect(result.isError == true, "The image went in while text was being typed: \(object)")
        #expect(errorObject(object)["guard"]?.stringValue == "can_start_project_operation", "\(object)")
        #expect(layer("Agent", in: session) == nil && session.document?.layers.count == layers)
        session.cancelText()
    }

    // MARK: Appearance

    @Test func setLayerBlendModeRefusesFoldersAndMatchesLooseNames() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let session = workspace.current.session
        try await MCPTestSupport.call("set_layer_blend_mode", ["layer": "Layer 1", "mode": "color_burn"], in: workspace)
        #expect(layer("Layer 1", in: session)?.blendMode == .colorBurn)
        try await MCPTestSupport.call("set_layer_blend_mode", ["layer": "Layer 1", "mode": "linear_dodge"], in: workspace)
        #expect(layer("Layer 1", in: session)?.blendMode == .linearDodge)
        try await MCPTestSupport.call("set_layer_blend_mode", ["layer": "Layer 1", "mode": "Soft Light"], in: workspace)
        #expect(layer("Layer 1", in: session)?.blendMode == .softLight)
        try await MCPTestSupport.call("set_layer_blend_mode", ["layer": "Layer 1", "mode": "sparkle"], in: workspace, expectError: "invalid_argument")

        try await MCPTestSupport.call("add_group", ["name": "F"], in: workspace)
        let before = session.history.undoCount
        let refused = try await MCPTestSupport.call("set_layer_blend_mode", ["layer": "F", "mode": "multiply"],
                                                    in: workspace, expectError: "precondition_failed")
        #expect(errorObject(refused)["guard"]?.stringValue == "not_folder")
        #expect(layer("F", in: session)?.blendMode == .normal && session.history.undoCount == before)
    }

    @Test func setLayerFillOpacityIsOneStepAndValidated() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let session = workspace.current.session
        let before = session.history.undoCount
        let changed = try await MCPTestSupport.call("set_layer_fill_opacity", ["layer": "Layer 1", "fill_opacity": 0.4], in: workspace)
        #expect(layer("Layer 1", in: session)?.fillOpacity == 0.4)
        #expect(layer("Layer 1", in: session)?.opacity == 1)
        #expect(changed["fill_opacity"]?.doubleValue == 0.4)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Layer Fill")
        let same = try await MCPTestSupport.call("set_layer_fill_opacity", ["layer": "Layer 1", "fill_opacity": 0.4], in: workspace)
        #expect(same["undo"]?.objectValue?["recorded"] == .bool(false))
        session.undo()
        #expect(layer("Layer 1", in: session)?.fillOpacity == 1)
        session.redo()

        try await MCPTestSupport.call("set_layer_fill_opacity", ["layer": "Layer 1", "fill_opacity": 1.5], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("set_layer_opacity", ["layer": "Layer 1", "opacity": -0.1], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("add_group", ["name": "F"], in: workspace)
        let folder = try await MCPTestSupport.call("set_layer_fill_opacity", ["layer": "F", "fill_opacity": 0.5],
                                                   in: workspace, expectError: "precondition_failed")
        #expect(errorObject(folder)["guard"]?.stringValue == "not_folder")
        #expect(layer("Layer 1", in: session)?.fillOpacity == 0.4)
    }

    // MARK: Locks

    @Test func positionLockBlocksMovingButNotStackingOrder() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        let session = workspace.current.session
        try await MCPTestSupport.call("add_blank_layer", ["name": "A"], in: workspace)
        try await MCPTestSupport.call("add_blank_layer", ["name": "B"], in: workspace)
        let aIndex = try #require(session.document?.layers.firstIndex { $0.name == "A" })
        session.document?.layers[aIndex].locks = [.artboardNesting]

        let before = session.history.undoCount
        let locked = try await MCPTestSupport.call("set_layer_locks", ["layer": "A", "position": true], in: workspace)
        #expect(locked["locks"] == .array([.string("position"), .string("artboard_nesting")]))
        #expect(layer("A", in: session)?.locks == [.position, .artboardNesting])
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Lock Layer")
        let again = try await MCPTestSupport.call("set_layer_locks", ["layer": "A", "position": true], in: workspace)
        #expect(again["undo"]?.objectValue?["recorded"] == .bool(false))
        try await MCPTestSupport.call("set_layer_locks", ["layer": "A"], in: workspace, expectError: "invalid_argument")

        let moved = try await MCPTestSupport.call("move_layer", ["layer": "A", "dx": 3, "dy": 0], in: workspace, expectError: "precondition_failed")
        #expect(errorObject(moved)["guard"]?.stringValue == "layer_locked")
        #expect(errorObject(moved)["hint"]?.stringValue?.contains("set_layer_locks") == true)
        try await MCPTestSupport.call("set_layer_transform", ["layer": "A", "x": 3], in: workspace, expectError: "precondition_failed")
        #expect(layer("A", in: session)?.transform.origin == .zero)

        // Stacking order and appearance are not position: Photoshop lets a position-locked layer move in the stack.
        try await MCPTestSupport.call("reorder_layer", ["layer": "A", "index": 0], in: workspace)
        #expect(names(in: nil, of: session).first == "A")
        try await MCPTestSupport.call("set_layer_opacity", ["layer": "A", "opacity": 0.5], in: workspace)
        try await MCPTestSupport.call("rename_layer", ["layer": "A", "name": "Anchor"], in: workspace)
        #expect(layer("Anchor", in: session)?.opacity == 0.5)
    }

    @Test func lockAllBlocksEverythingButVisibilityAndSelection() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        let session = workspace.current.session
        try insert(try solid(width: 4, height: 4, (255, 0, 0, 255)), name: "A", in: session)
        try insert(try solid(width: 4, height: 4, (0, 0, 255, 255)), name: "B", in: session)
        let lockedAll = try await MCPTestSupport.call("set_layer_locks", ["layer": "A", "all": true], in: workspace)
        #expect(lockedAll["locks"] == .array([.string("all")]))
        let document = try #require(session.document)

        let refusals: [(String, [String: Value])] = [
            ("rename_layer", ["layer": "A", "name": "X"]),
            ("set_layer_opacity", ["layer": "A", "opacity": 0.5]),
            ("set_layer_fill_opacity", ["layer": "A", "fill_opacity": 0.5]),
            ("set_layer_blend_mode", ["layer": "A", "mode": "multiply"]),
            ("delete_layers", ["layers": ["A"]]),
            ("reorder_layer", ["layer": "A", "index": 0]),
            ("place_layer", ["layer": "A", "bottom": true]),
            ("group_layers", ["layers": ["A", "B"]]),
            ("set_clipping_mask", ["layer": "A", "enabled": true]),
            ("rasterize_layer", ["layer": "A"]),
            // Merging B down would change A's pixels.
            ("merge_layers", ["layers": ["B"]]),
            ("move_layer", ["layer": "A", "dx": 1, "dy": 1]),
        ]
        for (tool, args) in refusals {
            let refused = try await MCPTestSupport.call(tool, args, in: workspace, expectError: "precondition_failed")
            #expect(errorObject(refused)["guard"]?.stringValue == "layer_locked", "\(tool): \(refused)")
        }
        #expect(session.document?.layers.map(\.id) == document.layers.map(\.id))
        #expect(layer("A", in: session) == document.layers.first { $0.name == "A" })

        try await MCPTestSupport.call("set_layer_visibility", ["layer": "A", "visible": false], in: workspace)
        try await MCPTestSupport.call("select_layers", ["layers": ["A"]], in: workspace)
        try await MCPTestSupport.call("duplicate_layer", ["layer": "A", "name": "A copy"], in: workspace)
        #expect(layer("A copy", in: session)?.locks == .all)

        try await MCPTestSupport.call("set_layer_locks", ["layer": "A", "all": false], in: workspace)
        try await MCPTestSupport.call("rename_layer", ["layer": "A", "name": "Free"], in: workspace)
        #expect(layer("Free", in: session)?.locks == [])
    }

    @Test func pixelLockBlocksRasterizingAndMerging() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        let session = workspace.current.session
        try insert(try solid(width: 4, height: 4, (255, 0, 0, 255)), name: "Low", in: session)
        try insert(try solid(width: 4, height: 4, (0, 0, 255, 255)), name: "High", in: session)
        try await MCPTestSupport.call("set_layer_locks", ["layer": "Low", "pixels": true], in: workspace)
        let merge = try await MCPTestSupport.call("merge_layers", ["layers": ["High"]], in: workspace, expectError: "precondition_failed")
        #expect(errorObject(merge)["guard"]?.stringValue == "layer_locked")
        try await MCPTestSupport.call("rasterize_layer", ["layer": "Low"], in: workspace, expectError: "precondition_failed")
        // Pixel locks leave the rest of the layer editable.
        try await MCPTestSupport.call("set_layer_opacity", ["layer": "Low", "opacity": 0.5], in: workspace)
        try await MCPTestSupport.call("move_layer", ["layer": "Low", "dx": 1, "dy": 0], in: workspace)
        #expect(session.document?.layers.count == 3)
    }

    @Test func folderLocksApplyToEverythingInside() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        let session = workspace.current.session
        let folder = try #require(try await MCPTestSupport.call("add_group", ["name": "Folder"], in: workspace)["group_id"]?.stringValue)
        let inner = try #require(try await MCPTestSupport.call("add_group", ["name": "Inner"], in: workspace)["group_id"]?.stringValue)
        try insert(try solid(width: 4, height: 4, (255, 0, 0, 255)), name: "Sibling", in: session)
        try await MCPTestSupport.call("place_layer", ["layer": "Sibling", "parent": "Folder/Inner"], in: workspace)
        try insert(try solid(width: 4, height: 4, (0, 0, 255, 255)), name: "Child", in: session)
        try await MCPTestSupport.call("place_layer", ["layer": "Child", "parent": "Folder/Inner"], in: workspace)
        try await MCPTestSupport.call("add_blank_layer", ["name": "Free", "parent": .null], in: workspace)
        #expect(names(in: UUID(uuidString: inner), of: session) == ["Sibling", "Child"])
        #expect(layer("Inner", in: session)?.parentID?.uuidString == folder)
        let child = try #require(layer("Child", in: session))

        // Lock All on the outer folder reaches a layer two folders down, which has no locks of its own.
        try await MCPTestSupport.call("set_layer_locks", ["layer": "Folder", "all": true], in: workspace)
        #expect(child.locks.isEmpty)
        let document = try #require(session.document)
        let undoCount = session.history.undoCount
        let refusals: [(String, [String: Value])] = [
            ("rename_layer", ["layer": "Child", "name": "X"]),
            ("set_layer_opacity", ["layer": "Child", "opacity": 0.5]),
            ("set_layer_fill_opacity", ["layer": "Child", "fill_opacity": 0.5]),
            ("set_layer_blend_mode", ["layer": "Child", "mode": "multiply"]),
            ("delete_layers", ["layers": ["Child"]]),
            ("move_layer", ["layer": "Child", "dx": 1, "dy": 1]),
            ("set_layer_transform", ["layer": "Child", "x": 3]),
            ("reorder_layer", ["layer": "Child", "index": 0]),
            ("place_layer", ["layer": "Child", "parent": .null]),
            ("group_layers", ["layers": ["Child", "Sibling"]]),
            ("set_clipping_mask", ["layer": "Child", "enabled": true]),
            ("rasterize_layer", ["layer": "Child"]),
            ("merge_layers", ["layers": ["Child"]]),
            ("ungroup_layer", ["layer": "Inner"]),
            ("delete_layers", ["layers": ["Inner"]]),
            // Nothing moves into a folder under Lock All either.
            ("place_layer", ["layer": "Free", "parent": "Folder/Inner"]),
        ]
        for (tool, args) in refusals {
            let refused = try await MCPTestSupport.call(tool, args, in: workspace, expectError: "precondition_failed")
            #expect(errorObject(refused)["guard"]?.stringValue == "layer_locked", "\(tool): \(refused)")
            #expect(errorObject(refused)["details"]?.objectValue?["locked_by_id"]?.stringValue == folder, "\(tool): \(refused)")
        }
        let renamed = try await MCPTestSupport.call("rename_layer", ["layer": "Child", "name": "X"], in: workspace, expectError: "precondition_failed")
        let details = errorObject(renamed)["details"]?.objectValue
        #expect(details?["layer_id"]?.stringValue == child.id.uuidString)
        #expect(details?["locks"] == .array([.string("all")]))
        #expect(errorObject(renamed)["hint"]?.stringValue?.contains("'Folder'") == true)
        #expect(session.document?.layers == document.layers)
        #expect(session.history.undoCount == undoCount)

        // Showing, hiding and selecting stay allowed, and layers outside the folder are unaffected.
        try await MCPTestSupport.call("set_layer_visibility", ["layer": "Child", "visible": false], in: workspace)
        try await MCPTestSupport.call("set_layer_visibility", ["layer": "Child", "visible": true], in: workspace)
        try await MCPTestSupport.call("select_layers", ["layers": ["Child"]], in: workspace)
        try await MCPTestSupport.call("move_layer", ["layer": "Free", "dx": 1, "dy": 0], in: workspace)

        // A folder's position lock keeps what is inside it in place, but not in the stack.
        try await MCPTestSupport.call("set_layer_locks", ["layer": "Folder", "all": false, "position": true], in: workspace)
        let positionRefusals: [(String, [String: Value])] = [
            ("move_layer", ["layer": "Child", "dx": 1, "dy": 1]),
            ("set_layer_transform", ["layer": "Child", "x": 3]),
            ("move_layer", ["layer": "Inner", "dx": 1, "dy": 1]),
        ]
        for (tool, args) in positionRefusals {
            let refused = try await MCPTestSupport.call(tool, args, in: workspace, expectError: "precondition_failed")
            #expect(errorObject(refused)["guard"]?.stringValue == "layer_locked", "\(tool): \(refused)")
            #expect(errorObject(refused)["details"]?.objectValue?["locks"] == .array([.string("position")]), "\(tool): \(refused)")
        }
        #expect(layer("Child", in: session)?.transform.origin == .zero)
        try await MCPTestSupport.call("reorder_layer", ["layer": "Child", "index": 0], in: workspace)
        #expect(names(in: UUID(uuidString: inner), of: session) == ["Child", "Sibling"])

        // A folder's pixel lock keeps the pixels inside it as they are, and leaves moving them alone.
        try await MCPTestSupport.call("set_layer_locks", ["layer": "Folder", "position": false, "pixels": true], in: workspace)
        let merge = try await MCPTestSupport.call("merge_layers", ["layers": ["Sibling"]], in: workspace, expectError: "precondition_failed")
        #expect(errorObject(merge)["guard"]?.stringValue == "layer_locked")
        #expect(errorObject(merge)["details"]?.objectValue?["locks"] == .array([.string("pixels")]))
        try await MCPTestSupport.call("rasterize_layer", ["layer": "Child"], in: workspace, expectError: "precondition_failed")
        try await MCPTestSupport.call("move_layer", ["layer": "Child", "dx": 2, "dy": 0], in: workspace)
        #expect(layer("Child", in: session)?.transform.origin == CGPoint(x: 2, y: 0))
    }

    // MARK: Structure

    @Test func deleteLayersBakesWhatWasClippedToThemInOneStep() async throws {
        let workspace = MCPTestSupport.workspace(width: 2, height: 2)
        let session = workspace.current.session
        let alphas: [UInt8] = [255, 0, 128, 255]
        let base = try insert(try image(width: 2, height: 2) { x, y in (0, 0, 0, alphas[y * 2 + x]) }, name: "Base", in: session)
        let top = try insert(try solid(width: 2, height: 2, (255, 0, 0, 255)), name: "Top", in: session)
        // A hidden base still clips what is above it.
        let baseIndex = try #require(session.document?.layers.firstIndex { $0.id == base })
        session.document?.layers[baseIndex].isVisible = false
        try await MCPTestSupport.call("set_clipping_mask", ["layer": "Top", "enabled": true], in: workspace)
        #expect(layer("Top", in: session)?.maskSourceID == base)
        let before = try await ImageExporter.shared.render(#require(session.projectSnapshot()))
        #expect(try alpha(before.image) == alphas)

        let first = try #require(layer("Layer 1", in: session)?.id)
        let undoCount = session.history.undoCount
        let result = try await MCPTestSupport.call("delete_layers", ["layers": ["Base", "Layer 1"]], in: workspace)
        #expect(result["deleted_layer_ids"] == .array([.string(first.uuidString), .string(base.uuidString)]))
        #expect(result["baked_layer_ids"] == .array([.string(top.uuidString)]))
        #expect(session.document?.layers.map(\.id) == [top])
        #expect(layer("Top", in: session)?.maskSourceID == nil)
        let after = try await ImageExporter.shared.render(#require(session.projectSnapshot()))
        #expect(try alpha(after.image) == alphas)
        #expect(session.history.undoCount == undoCount + 1 && session.history.undoName == "Delete Layers")
        #expect(!session.isProjectBusy)

        session.undo()
        #expect(session.document?.layers.count == 3 && layer("Top", in: session)?.maskSourceID == base)
    }

    @Test func duplicateAndLayerViaCopy() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let session = workspace.current.session
        try insert(try solid(width: 4, height: 4, (255, 0, 0, 255)), name: "Red", in: session)

        let before = session.history.undoCount
        let copy = try await MCPTestSupport.call("duplicate_layer", ["layer": "Red", "name": "Red 2"], in: workspace)
        #expect(copy["layer_id"]?.stringValue == layer("Red 2", in: session)?.id.uuidString)
        #expect(layer("Red 2", in: session)?.asset?.image === layer("Red", in: session)?.asset?.image)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Duplicate Layer")

        session.setSelection(DocumentSelection(path: CGPath(rect: CGRect(x: 1, y: 1, width: 2, height: 2), transform: nil)), name: "Select")
        let via = try await MCPTestSupport.call("layer_via_copy", ["layer": "Red"], in: workspace)
        let pieceID = try #require(via["layer_id"]?.stringValue)
        let piece = try #require(session.document?.layers.first { $0.id.uuidString == pieceID })
        #expect(piece.transform.origin == CGPoint(x: 1, y: 1) && piece.asset?.image.width == 2)
        #expect(session.history.undoName == "Layer via Copy")

        session.setSelection(DocumentSelection(path: CGPath(rect: CGRect(x: 1, y: 1, width: 2, height: 2), transform: nil)), name: "Select")
        let blank = try await MCPTestSupport.call("layer_via_copy", ["layer": "Layer 1"], in: workspace, expectError: "precondition_failed")
        #expect(errorObject(blank)["guard"]?.stringValue == "can_copy_pixels")
        try await MCPTestSupport.call("add_group", ["name": "F"], in: workspace)
        try await MCPTestSupport.call("layer_via_copy", ["layer": "F"], in: workspace, expectError: "precondition_failed")
    }

    /// The app's Cmd-J duplicates every selected layer (upstream); duplicate_layer and layer_via_copy still copy just
    /// the layer the call names, whatever the person has selected in the Layers panel.
    @Test func duplicatingOverMCPCopiesOnlyTheNamedLayerWhateverIsSelected() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let session = workspace.current.session
        try insert(try solid(width: 4, height: 4, (255, 0, 0, 255)), name: "Red", in: session)
        try insert(try solid(width: 4, height: 4, (0, 0, 255, 255)), name: "Blue", in: session)
        let red = try #require(layer("Red", in: session)?.id), blue = try #require(layer("Blue", in: session)?.id)
        func selectBoth() {
            session.activeLayerID = blue
            session.selectedLayerIDs = [red, blue, try! #require(layer("Layer 1", in: session)?.id)]
        }
        selectBoth()
        let count = session.document?.layers.count ?? 0
        let copy = try await MCPTestSupport.call("duplicate_layer", ["layer": "Red"], in: workspace)
        #expect(session.document?.layers.count == count + 1)
        #expect(copy["name"] == .string("Red copy"))
        #expect(session.document?.layers.map(\.name) == ["Layer 1", "Red", "Red copy", "Blue"])

        selectBoth()
        try await MCPTestSupport.call("layer_via_copy", ["layer": "Red"], in: workspace)
        #expect(session.document?.layers.count == count + 2)
        #expect(session.history.undoName == "Duplicate Layer")
    }

    @Test func placeLayerIntoAFolderThenUngroupRoundTrips() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let session = workspace.current.session
        for name in ["A", "B", "C"] { try await MCPTestSupport.call("add_blank_layer", ["name": .string(name)], in: workspace) }
        let original = names(in: nil, of: session)
        #expect(original == ["Layer 1", "A", "B", "C"])

        let folder = try await MCPTestSupport.call("add_group", ["name": "F"], in: workspace)
        let folderID = try #require(folder["group_id"]?.stringValue.flatMap(UUID.init))
        try await MCPTestSupport.call("place_layer", ["layer": "F", "above": "A"], in: workspace)
        #expect(names(in: nil, of: session) == ["Layer 1", "A", "F", "B", "C"])
        let placed = try await MCPTestSupport.call("place_layer", ["layer": "B", "parent": "F"], in: workspace)
        #expect(placed["parent_id"]?.stringValue == folderID.uuidString)
        #expect(names(in: folderID, of: session) == ["B"] && names(in: nil, of: session) == ["Layer 1", "A", "F", "C"])
        let same = try await MCPTestSupport.call("place_layer", ["layer": "B", "parent": "F"], in: workspace)
        #expect(same["undo"]?.objectValue?["recorded"] == .bool(false))

        let before = session.history.undoCount
        let ungrouped = try await MCPTestSupport.call("ungroup_layer", ["layer": "F"], in: workspace)
        #expect(ungrouped["layer_ids"] == .array([.string(try #require(layer("B", in: session)).id.uuidString)]))
        #expect(names(in: nil, of: session) == original)
        #expect(layer("F", in: session) == nil && layer("B", in: session)?.parentID == nil)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Ungroup")
        #expect(session.activeLayerID == layer("B", in: session)?.id)

        session.undo()
        #expect(names(in: folderID, of: session) == ["B"])
        try await MCPTestSupport.call("ungroup_layer", ["layer": "A"], in: workspace, expectError: "precondition_failed")
    }

    @Test func ungroupMovesContentsIntoTheParentFolderInOrder() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let session = workspace.current.session
        let outer = try #require(try await MCPTestSupport.call("add_group", ["name": "Outer"], in: workspace)["group_id"]?.stringValue.flatMap(UUID.init))
        try await MCPTestSupport.call("add_blank_layer", ["name": "X", "parent": "Outer"], in: workspace)
        try await MCPTestSupport.call("add_group", ["name": "Inner"], in: workspace)
        try await MCPTestSupport.call("add_blank_layer", ["name": "P", "parent": "Inner"], in: workspace)
        try await MCPTestSupport.call("add_blank_layer", ["name": "Q", "parent": "Inner"], in: workspace)
        try await MCPTestSupport.call("add_blank_layer", ["name": "Y", "parent": "Outer"], in: workspace)
        #expect(names(in: outer, of: session) == ["X", "Inner", "Y"])

        let result = try await MCPTestSupport.call("ungroup_layer", ["layer": "Outer/Inner"], in: workspace)
        #expect(result["layer_ids"]?.arrayValue?.count == 2)
        #expect(names(in: outer, of: session) == ["X", "P", "Q", "Y"])
        #expect(session.selectedLayerIDs == Set(["P", "Q"].compactMap { layer($0, in: session)?.id }))

        // Placement errors: a folder into itself, 'above' outside the named folder, both above and bottom.
        try await MCPTestSupport.call("place_layer", ["layer": "Outer", "parent": "Outer"], in: workspace, expectError: "precondition_failed")
        try await MCPTestSupport.call("place_layer", ["layer": "X", "parent": .null, "above": "P"], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("place_layer", ["layer": "X", "above": "P", "bottom": true], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("place_layer", ["layer": "X", "parent": .null, "bottom": true], in: workspace)
        #expect(names(in: nil, of: session) == ["X", "Layer 1", "Outer"])
    }

    @Test func groupLayersNamesTheFolderInOneStep() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let session = workspace.current.session
        try await MCPTestSupport.call("add_blank_layer", ["name": "A"], in: workspace)
        let before = session.history.undoCount
        let grouped = try await MCPTestSupport.call("group_layers", ["layers": ["Layer 1", "A"], "name": "Pair"], in: workspace)
        let folder = try #require(layer("Pair", in: session))
        #expect(grouped["group_id"]?.stringValue == folder.id.uuidString)
        #expect(names(in: folder.id, of: session) == ["Layer 1", "A"])
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Group Layers")
    }

    @Test func selectLayersTargetsTheMask() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let session = workspace.current.session
        try await MCPTestSupport.call("add_blank_layer", ["name": "A"], in: workspace)
        let refused = try await MCPTestSupport.call("select_layers", ["layers": ["A"], "target": "mask"], in: workspace, expectError: "precondition_failed")
        #expect(errorObject(refused)["guard"]?.stringValue == "has_mask")
        session.addLayerMask(revealing: true)
        try await MCPTestSupport.call("select_layers", ["layers": ["Layer 1"]], in: workspace)
        let masked = try await MCPTestSupport.call("select_layers", ["layers": ["A"], "target": "mask"], in: workspace)
        #expect(masked["target"]?.stringValue == "mask")
        #expect(session.activeLayer?.name == "A" && session.isMaskSelected)
        try await MCPTestSupport.call("select_layers", ["layers": ["A"], "target": "pixels"], in: workspace)
        #expect(!session.isMaskSelected)
    }

    @Test func mergeLayersReportsWhatItDid() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let session = workspace.current.session
        try insert(try solid(width: 4, height: 4, (255, 0, 0, 255)), name: "Low", in: session)
        try insert(try solid(width: 2, height: 2, (0, 0, 255, 255)), name: "High", in: session)
        let refused = try await MCPTestSupport.call("merge_layers", ["layers": ["Layer 1"]], in: workspace, expectError: "precondition_failed")
        #expect(errorObject(refused)["guard"]?.stringValue == "can_merge_layers")
        let legacy = try await MCPTestSupport.call("merge_layers", ["layer": "High"], in: workspace, expectError: "invalid_argument")
        #expect(errorObject(legacy)["hint"]?.stringValue?.contains("layers") == true)

        let merged = try await MCPTestSupport.call("merge_layers", ["layers": ["High"]], in: workspace)
        #expect(merged["action"]?.stringValue == "Merge Down")
        #expect(merged["merged_layer_id"]?.stringValue == layer("Low", in: session)?.id.uuidString)
        #expect(names(in: nil, of: session) == ["Layer 1", "Low"])

        try await MCPTestSupport.call("add_blank_layer", ["name": "C"], in: workspace)
        let many = try await MCPTestSupport.call("merge_layers", ["layers": ["Low", "C"]], in: workspace)
        #expect(many["action"]?.stringValue == "Merge Layers")
        #expect(session.history.undoName == "Merge Layers")
    }

    // MARK: Flatten and rasterize

    @Test func flattenImageLeavesOneLayerMatchingTheExport() async throws {
        let workspace = MCPTestSupport.workspace(width: 6, height: 4)
        let session = workspace.current.session
        try insert(try solid(width: 4, height: 4, (255, 0, 0, 255)), name: "Red", in: session)
        let blue = try insert(try solid(width: 4, height: 2, (0, 0, 255, 160)), name: "Blue", at: CGPoint(x: 2, y: 1), in: session)
        let hidden = try insert(try solid(width: 6, height: 4, (0, 255, 0, 255)), name: "Hidden", in: session)
        for (id, change) in [(blue, { (layer: inout ImageLayer) in layer.opacity = 0.5; layer.blendMode = .multiply }),
                             (hidden, { (layer: inout ImageLayer) in layer.isVisible = false })] {
            let index = try #require(session.document?.layers.firstIndex { $0.id == id })
            change(&session.document!.layers[index])
        }
        let snapshot = try #require(session.projectSnapshot())
        let rendered = try await ImageExporter.shared.render(snapshot).image
        let png = try await ImageExporter.shared.pngData(snapshot)
        let exported = try #require(CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })

        let layers = session.document?.layers
        let kept = try await MCPTestSupport.call("flatten_image", ["discard_hidden": false], in: workspace, expectError: "precondition_failed")
        #expect(errorObject(kept)["guard"]?.stringValue == "hidden_layers")
        #expect(session.document?.layers == layers)

        let before = session.history.undoCount
        let result = try await MCPTestSupport.call("flatten_image", in: workspace)
        let flat = try #require(session.document?.layers.first)
        #expect(session.document?.layers.count == 1)
        #expect(result["layer_id"]?.stringValue == flat.id.uuidString)
        #expect(result["discarded_hidden"]?.intValue == 1)
        #expect(flat.name == "Background" && flat.transform == LayerTransform(origin: .zero, size: CGSize(width: 6, height: 4)))
        let image = try #require(flat.asset?.image)
        #expect(try rgba(image) == rgba(rendered))
        let difference = zip(try rgba(image), try rgba(exported)).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(difference <= 1, "The flattened pixels differ from the exported PNG by \(difference)")
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Flatten Image")
        #expect(session.activeLayerID == flat.id && !session.isProjectBusy)

        session.undo()
        #expect(session.document?.layers == layers)
    }

    @Test func rasterizeLayerTurnsTextIntoPixelsKeepingEffects() async throws {
        let workspace = MCPTestSupport.workspace(width: 200, height: 100)
        let session = workspace.current.session
        session.selectTool(.type)
        session.beginText(at: CGPoint(x: 10, y: 10))
        var draft = try #require(session.textDraft)
        draft.style.content = "Hi"
        draft.style.fontSize = 40
        #expect(session.applyText(draft))
        let id = try #require(session.activeLayerID)
        var effects = LayerEffects()
        effects.stroke = StrokeEffect(size: 3)
        session.setEffects(effects, on: id, name: "Stroke")
        let text = try #require(session.document?.layers.first { $0.id == id })
        #expect(text.liveText != nil)
        let kind = try await MCPTestSupport.call("get_layer", ["layer": .string(id.uuidString), "detail": "summary"], in: workspace)
        #expect(kind["layer"]?.objectValue?["kind"]?.stringValue == "text")

        let before = session.history.undoCount
        let result = try await MCPTestSupport.call("rasterize_layer", ["layer": .string(id.uuidString)], in: workspace)
        let raster = try #require(session.document?.layers.first { $0.id == id })
        #expect(raster.text == nil && raster.liveText == nil)
        #expect(raster.effects == effects)
        #expect(raster.asset?.image === text.asset?.image && raster.transform == text.transform)
        #expect(result["kind"]?.stringValue == "raster")
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Rasterize Layer")

        let again = try await MCPTestSupport.call("rasterize_layer", ["layer": .string(id.uuidString)], in: workspace)
        #expect(again["undo"]?.objectValue?["recorded"] == .bool(false))
        try await MCPTestSupport.call("add_group", ["name": "F"], in: workspace)
        let folder = try await MCPTestSupport.call("rasterize_layer", ["layer": "F"], in: workspace, expectError: "precondition_failed")
        #expect(errorObject(folder)["guard"]?.stringValue == "has_pixels")

        session.undo()
        session.undo()
        #expect(session.document?.layers.first { $0.id == id }?.liveText != nil)
    }

    @Test func photoshopPlaceholdersRefusePixelOperations() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let session = workspace.current.session
        var placeholder = ImageLayer(name: "Brightness/Contrast 1", blankSize: CGSize(width: 8, height: 8))
        placeholder.isVisible = false
        placeholder.psdExtras = PSDLayerExtras(placeholder: "adjustment:brit")
        session.document?.layers.append(placeholder)

        let described = try await MCPTestSupport.call("get_layer", ["layer": .string(placeholder.id.uuidString)], in: workspace)
        #expect(described["layer"]?.objectValue?["kind"]?.stringValue == "placeholder")
        for tool in ["rasterize_layer", "layer_via_copy"] {
            let refused = try await MCPTestSupport.call(tool, ["layer": .string(placeholder.id.uuidString)], in: workspace, expectError: "precondition_failed")
            #expect(errorObject(refused)["guard"]?.stringValue == "placeholder", "\(tool): \(refused)")
        }
        #expect(session.document?.layers.count == 2)
    }
}
