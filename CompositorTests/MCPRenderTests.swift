import CoreGraphics
import Foundation
import ImageIO
import Testing
import MCP
@testable import Compositor

/// Image previews over MCP: `render_document`, `render_region` and `render_layer` return a real
/// image content block (first) and a JSON text block; `get_layer_bounds`, `get_pixel_color` and
/// `sample_colors` report geometry and colors.
@MainActor struct MCPRenderTests {
    // MARK: Helpers

    /// A solid `width` × `height` RGBA image, or one painted by `pixel(x, y)` (top-left origin).
    private func image(width: Int, height: Int,
                       pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                let i = (y * width + x) * 4
                // Premultiplied, as the app's rasters are.
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

    /// Adds `image` as a new layer placed at `origin` (its own pixel size) and returns its id.
    @discardableResult
    private func insert(_ image: CGImage, name: String, at origin: CGPoint, in session: EditorSession) throws -> UUID {
        session.insert(ImportedImage(image: image, thumbnail: image, name: name))
        let id = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].transform.origin = origin
        return id
    }

    /// The raw result, for its content blocks.
    private func raw(_ name: String, _ args: [String: Value], in workspace: ProjectWorkspace) async -> CallTool.Result {
        await MCPToolRegistry.call(name, args, workspace: workspace)
    }

    /// The decoded image of the result's first content block, with its MIME type.
    private func decodedImage(_ result: CallTool.Result) throws -> (image: CGImage, mimeType: String) {
        guard case .image(let base64, let mimeType, _, _) = try #require(result.content.first) else {
            Issue.record("The first content block is not an image: \(result.content)")
            throw CancellationError()
        }
        let data = try #require(Data(base64Encoded: base64))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return (try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)), mimeType)
    }

    /// One pixel of `image` as unpremultiplied 0–255 RGBA.
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let a = Int(bytes[3])
        guard a > 0 else { return [0, 0, 0, 0] }
        return [0, 1, 2].map { min(255, (Int(bytes[$0]) * 255 + a / 2) / a) } + [a]
    }

    private func rect(_ value: Value?) -> CGRect? {
        guard let object = value?.objectValue else { return nil }
        func n(_ key: String) -> CGFloat? { (object[key]?.doubleValue ?? object[key]?.intValue.map(Double.init)).map { CGFloat($0) } }
        guard let x = n("x"), let y = n("y"), let w = n("width"), let h = n("height") else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: render_document

    @Test func renderDocumentReturnsADownscaledPNGImageBlockFirst() async throws {
        let workspace = MCPTestSupport.workspace(width: 2000, height: 1000)
        let result = await raw("render_document", ["max_size": 500], in: workspace)
        #expect(result.isError != true, "\(result)")
        let (image, mimeType) = try decodedImage(result)
        #expect(mimeType == "image/png")
        #expect(image.width == 500 && image.height == 250)
        #expect(result.content.count == 2)
        guard case .text(let text, _, _) = result.content.last else { Issue.record("No JSON text block"); return }
        let fields = try #require(result.structuredContent?.objectValue)
        #expect(text.contains("\"scale\""))
        #expect(fields["ok"] == .bool(true))
        #expect(fields["width"]?.intValue == 500 && fields["height"]?.intValue == 250)
        #expect(fields["scale"]?.doubleValue == 0.25)
        #expect(fields["scale_x"]?.doubleValue == 0.25 && fields["scale_y"]?.doubleValue == 0.25)
        #expect(fields["document_width"]?.intValue == 2000 && fields["document_height"]?.intValue == 1000)
        #expect(fields["format"]?.stringValue == "png")
        #expect((fields["bytes"]?.intValue ?? 0) > 0)
        // Previews never write files.
        #expect(fields["saved_path"] == nil)
        // The JSON never carries the image bytes.
        #expect(fields["data"] == nil)
    }

    @Test func renderDocumentNeverUpscalesAndShowsTheComposite() async throws {
        let workspace = MCPTestSupport.workspace(width: 40, height: 30)
        let session = workspace.current.session
        try insert(try solid(width: 10, height: 10, (255, 0, 0, 255)), name: "Red", at: CGPoint(x: 5, y: 5), in: session)
        let result = await raw("render_document", [:], in: workspace)
        let (image, _) = try decodedImage(result)
        #expect(image.width == 40 && image.height == 30)
        #expect(result.structuredContent?.objectValue?["scale"]?.doubleValue == 1)
        #expect(try pixel(image, x: 7, y: 7) == [255, 0, 0, 255])
        #expect(try pixel(image, x: 30, y: 20)[3] == 0)
    }

    @Test func renderDocumentJPEGAndBackgrounds() async throws {
        let workspace = MCPTestSupport.workspace(width: 20, height: 20)
        let jpeg = await raw("render_document", ["format": "jpeg", "quality": 0.9], in: workspace)
        let (image, mimeType) = try decodedImage(jpeg)
        #expect(mimeType == "image/jpeg")
        // JPEG has no alpha: the empty canvas comes out on white by default.
        let white = try pixel(image, x: 10, y: 10)
        #expect(white[0] > 245 && white[1] > 245 && white[2] > 245 && white[3] == 255)
        #expect(jpeg.structuredContent?.objectValue?["format"]?.stringValue == "jpeg")

        let black = await raw("render_document", ["background": "black"], in: workspace)
        #expect(try pixel(try decodedImage(black).image, x: 3, y: 3) == [0, 0, 0, 255])
        let checker = try decodedImage(await raw("render_document", ["background": "checkerboard"], in: workspace)).image
        #expect(try pixel(checker, x: 0, y: 0) != pixel(checker, x: 8, y: 0))
        #expect(try pixel(checker, x: 0, y: 0)[3] == 255)

        try await MCPTestSupport.call("render_document", ["format": "jpeg", "background": "transparent"], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("render_document", ["format": "gif"], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("render_document", ["max_size": 8], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("render_document", ["max_size": 5000], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("render_document", ["quality": 2], in: workspace, expectError: "invalid_argument")
    }

    @Test func renderScalesReportTheRoundedSizePerAxis() async throws {
        // 1000×333 at max_size 100 is 100×33: 0.1 asked, 33/333 on the short side.
        let workspace = MCPTestSupport.workspace(width: 1000, height: 333)
        let result = try await MCPTestSupport.call("render_document", ["max_size": 100], in: workspace)
        #expect(result["width"]?.intValue == 100 && result["height"]?.intValue == 33)
        #expect(result["scale"]?.doubleValue == 0.1 && result["scale_x"]?.doubleValue == 0.1)
        #expect(result["scale_y"]?.doubleValue == 33.0 / 333.0)
    }

    @Test func exportImageScalesFlattensAndRefusesToOverwrite() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        try insert(try solid(width: 32, height: 32, (255, 0, 0, 255)), name: "Red", at: .zero, in: session)
        func decoded(_ path: String) throws -> CGImage {
            let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
            return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }

        let target = MCPTestSupport.tempFile("small")
        let small = try await MCPTestSupport.call("export_image", ["path": .string(target.path), "max_size": 16, "background": "black"], in: workspace)
        let path = try #require(small["path"]?.stringValue)
        #expect(path == target.path + ".png")
        #expect(small["width"]?.intValue == 16 && small["height"]?.intValue == 8 && small["scale"]?.doubleValue == 0.25)
        let image = try decoded(path)
        #expect(image.width == 16 && image.height == 8)
        #expect(try pixel(image, x: 3, y: 3) == [255, 0, 0, 255])
        #expect(try pixel(image, x: 12, y: 3) == [0, 0, 0, 255])
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).count == small["bytes"]?.intValue)

        let refused = try await MCPTestSupport.call("export_image", ["path": .string(path)], in: workspace, expectError: "io_error")
        #expect(refused["error"]?.objectValue?["details"]?.objectValue?["code"]?.stringValue == "file_exists")
        try await MCPTestSupport.call("export_image", ["path": .string(path), "overwrite": true], in: workspace)
        #expect(try decoded(path).width == 64)

        // Without max_size the file is full size; PNG stays transparent and JPEG goes on white by default.
        let full = try await MCPTestSupport.call("export_image", ["path": .string(MCPTestSupport.tempFile("full.png").path)], in: workspace)
        let fullImage = try decoded(try #require(full["path"]?.stringValue))
        #expect(fullImage.width == 64 && fullImage.height == 32 && full["scale"]?.doubleValue == 1)
        #expect(try pixel(fullImage, x: 50, y: 10)[3] == 0)
        let jpeg = try await MCPTestSupport.call("export_image", ["path": .string(MCPTestSupport.tempFile("flat.jpg").path)], in: workspace)
        #expect(jpeg["format"]?.stringValue == "jpeg")
        let white = try pixel(try decoded(try #require(jpeg["path"]?.stringValue)), x: 50, y: 10)
        #expect(white[0] > 245 && white[1] > 245 && white[2] > 245)

        try await MCPTestSupport.call("export_image", ["path": .string(MCPTestSupport.tempFile("t.jpg").path), "background": "transparent"],
                                      in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("export_image", ["path": .string(MCPTestSupport.tempFile("tiny.png").path), "max_size": 4],
                                      in: workspace, expectError: "invalid_argument")
    }

    @Test func renderDocumentRefusesWhileTheProjectIsBusy() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        workspace.current.session.isProjectBusy = true
        defer { workspace.current.session.isProjectBusy = false }
        try await MCPTestSupport.call("render_document", [:], in: workspace, expectError: "busy")
    }

    // MARK: render_region

    @Test func renderRegionCropsPadsAndClampsToTheCanvas() async throws {
        let workspace = MCPTestSupport.workspace(width: 100, height: 80)
        let session = workspace.current.session
        try insert(try solid(width: 4, height: 4, (0, 0, 255, 255)), name: "Blue", at: CGPoint(x: 20, y: 20), in: session)

        let padded = await raw("render_region", ["region": ["x": 20, "y": 20, "width": 4, "height": 4], "padding": 3], in: workspace)
        let (image, _) = try decodedImage(padded)
        #expect(image.width == 10 && image.height == 10)
        #expect(rect(padded.structuredContent?.objectValue?["region"]) == CGRect(x: 17, y: 17, width: 10, height: 10))
        #expect(try pixel(image, x: 3, y: 3) == [0, 0, 255, 255])
        #expect(try pixel(image, x: 1, y: 1)[3] == 0)

        let edge = try await MCPTestSupport.call("render_region", ["region": ["x": 90, "y": 70, "width": 20, "height": 20]], in: workspace)
        #expect(edge["width"]?.intValue == 10 && edge["height"]?.intValue == 10)
        #expect(rect(edge["region"]) == CGRect(x: 90, y: 70, width: 10, height: 10))

        let scaled = try await MCPTestSupport.call("render_region", ["region": ["x": 0, "y": 0, "width": 100, "height": 50], "max_size": 20], in: workspace)
        #expect(scaled["width"]?.intValue == 20 && scaled["height"]?.intValue == 10 && scaled["scale"]?.doubleValue == 0.2)

        try await MCPTestSupport.call("render_region", ["region": ["x": 200, "y": 0, "width": 10, "height": 10]], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("render_region", ["region": ["x": 0, "y": 0, "width": 0, "height": 10]], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("render_region", ["region": "everything"], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("render_region", [:], in: workspace, expectError: "invalid_argument")
    }

    @Test func renderRegionCountsRowsFromTheTop() async throws {
        let workspace = MCPTestSupport.workspace(width: 100, height: 80)
        let session = workspace.current.session
        // Red at the region's top-left, blue at its bottom-right: a flipped crop would swap them.
        try insert(try solid(width: 2, height: 2, (255, 0, 0, 255)), name: "Top", at: CGPoint(x: 20, y: 10), in: session)
        try insert(try solid(width: 2, height: 2, (0, 0, 255, 255)), name: "Bottom", at: CGPoint(x: 28, y: 48), in: session)
        let result = await raw("render_region", ["region": ["x": 20, "y": 10, "width": 10, "height": 40]], in: workspace)
        let (image, _) = try decodedImage(result)
        #expect(image.width == 10 && image.height == 40)
        #expect(try pixel(image, x: 0, y: 0) == [255, 0, 0, 255])
        #expect(try pixel(image, x: 9, y: 39) == [0, 0, 255, 255])
        #expect(try pixel(image, x: 0, y: 39)[3] == 0 && pixel(image, x: 9, y: 0)[3] == 0)
    }

    @Test func renderRegionUsesTheSelectionBounds() async throws {
        let workspace = MCPTestSupport.workspace(width: 100, height: 80)
        let session = workspace.current.session
        try await MCPTestSupport.call("render_region", ["region": "selection"], in: workspace, expectError: "precondition_failed")
        session.setSelection(DocumentSelection(path: CGPath(ellipseIn: CGRect(x: 10, y: 20, width: 30, height: 16), transform: nil)), name: "Select")
        let result = try await MCPTestSupport.call("render_region", ["region": "selection", "padding": 2], in: workspace)
        #expect(rect(result["region"]) == CGRect(x: 8, y: 18, width: 34, height: 20))
        #expect(result["width"]?.intValue == 34 && result["height"]?.intValue == 20)
    }

    // MARK: render_layer

    @Test func renderLayerCropsToTheLayerWithOrWithoutEffects() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 64)
        let session = workspace.current.session
        let id = try insert(try solid(width: 8, height: 8, (255, 0, 0, 255)), name: "Red", at: CGPoint(x: 10, y: 12), in: session)
        var effects = LayerEffects()
        effects.stroke = StrokeEffect(size: 4, red: 0, green: 0, blue: 1)
        session.setEffects(effects, on: id, name: "Stroke")
        #expect(session.document?.layers.first { $0.id == id }?.effects != nil)
        // Hidden layers render too: render_layer shows the layer by itself.
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].isVisible = false

        let bare = await raw("render_layer", ["layer": "Red", "include_effects": false], in: workspace)
        let (plain, _) = try decodedImage(bare)
        #expect(plain.width == 8 && plain.height == 8)
        #expect(try pixel(plain, x: 0, y: 0) == [255, 0, 0, 255])
        #expect(rect(bare.structuredContent?.objectValue?["region"]) == CGRect(x: 10, y: 12, width: 8, height: 8))
        #expect(bare.structuredContent?.objectValue?["layer_id"]?.stringValue == id.uuidString)

        let styled = await raw("render_layer", ["layer": "Red"], in: workspace)
        let (withEffects, _) = try decodedImage(styled)
        // A 4 px outside stroke needs ceil(4) + 2 = 6 px of room on each side.
        let margin = Int(LayerEffectsRenderer.margin(for: effects))
        #expect(margin == 6)
        #expect(withEffects.width == 8 + 2 * margin && withEffects.height == 8 + 2 * margin)
        #expect(rect(styled.structuredContent?.objectValue?["region"]) == CGRect(x: 10 - margin, y: 12 - margin, width: 8 + 2 * margin, height: 8 + 2 * margin))
        // The stroke's blue shows outside the red square.
        let edge = try pixel(withEffects, x: withEffects.width / 2, y: 4)
        #expect(edge[2] > 200 && edge[0] < 50, "\(edge)")

        let canvas = try await MCPTestSupport.call("render_layer", ["layer": "Red", "crop": "canvas"], in: workspace)
        #expect(canvas["width"]?.intValue == 64 && canvas["height"]?.intValue == 64)
        try await MCPTestSupport.call("render_layer", ["layer": "Red", "crop": "page"], in: workspace, expectError: "invalid_argument")
    }

    @Test func renderLayerCropsATurnedLayerToItsUprightBox() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 64)
        let session = workspace.current.session
        // 8×4, left half red and right half blue, turned a quarter clockwise about its center (14, 12).
        let halves = try image(width: 8, height: 4) { x, _ in x < 4 ? (255, 0, 0, 255) : (0, 0, 255, 255) }
        let id = try insert(halves, name: "Turned", at: CGPoint(x: 10, y: 10), in: session)
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].transform.rotation = 90
        let result = await raw("render_layer", ["layer": "Turned"], in: workspace)
        let (turned, _) = try decodedImage(result)
        // Upright 4×8 box, with no extra row from rounding error; the left half now sits on top.
        #expect(rect(result.structuredContent?.objectValue?["region"]) == CGRect(x: 12, y: 8, width: 4, height: 8))
        #expect(turned.width == 4 && turned.height == 8)
        #expect(try pixel(turned, x: 2, y: 1) == [255, 0, 0, 255])
        #expect(try pixel(turned, x: 2, y: 6) == [0, 0, 255, 255])

        // Flipped horizontally instead, the blue half is on the left.
        session.document?.layers[index].transform.rotation = 0
        session.document?.layers[index].transform.flipX = true
        let (flipped, _) = try decodedImage(await raw("render_layer", ["layer": "Turned"], in: workspace))
        #expect(flipped.width == 8 && flipped.height == 4)
        #expect(try pixel(flipped, x: 1, y: 2) == [0, 0, 255, 255] && pixel(flipped, x: 6, y: 2) == [255, 0, 0, 255])
    }

    @Test func renderLayerLeavesOutOtherLayersAndItsClippingBase() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        try insert(try solid(width: 32, height: 32, (0, 255, 0, 255)), name: "Base", at: .zero, in: session)
        let top = try insert(try solid(width: 4, height: 4, (255, 0, 0, 255)), name: "Top", at: CGPoint(x: 8, y: 8), in: session)
        try await MCPTestSupport.call("set_clipping_mask", ["layer": .string(top.uuidString), "enabled": true], in: workspace)
        let (image, _) = try decodedImage(await raw("render_layer", ["layer": "Top", "crop": "canvas"], in: workspace))
        #expect(try pixel(image, x: 9, y: 9) == [255, 0, 0, 255])
        #expect(try pixel(image, x: 2, y: 2)[3] == 0)
    }

    @Test func renderLayerRendersAFolderAndRefusesAdjustmentLayers() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 64)
        let session = workspace.current.session
        try insert(try solid(width: 4, height: 4, (255, 0, 0, 255)), name: "A", at: CGPoint(x: 4, y: 4), in: session)
        try insert(try solid(width: 4, height: 4, (0, 0, 255, 255)), name: "B", at: CGPoint(x: 20, y: 10), in: session)
        try await MCPTestSupport.call("group_layers", ["layers": ["A", "B"]], in: workspace)
        let folder = try #require(session.document?.layers.first { $0.isGroup })
        let result = try await MCPTestSupport.call("render_layer", ["layer": .string(folder.id.uuidString)], in: workspace)
        #expect(rect(result["region"]) == CGRect(x: 4, y: 4, width: 20, height: 10))
        let bounds = try await MCPTestSupport.call("get_layer_bounds", ["layer": .string(folder.id.uuidString)], in: workspace)
        #expect(rect(bounds["bounds"]) == CGRect(x: 4, y: 4, width: 20, height: 10) && bounds["layer_count"]?.intValue == 2)
        // A hidden layer inside the folder is left out of both, alike; the folder itself may be hidden.
        try await MCPTestSupport.call("set_layer_visibility", ["layer": "B", "visible": false], in: workspace)
        try await MCPTestSupport.call("set_layer_visibility", ["layer": .string(folder.id.uuidString), "visible": false], in: workspace)
        let narrowed = try await MCPTestSupport.call("render_layer", ["layer": .string(folder.id.uuidString)], in: workspace)
        #expect(rect(narrowed["region"]) == CGRect(x: 4, y: 4, width: 4, height: 4))
        let visibleBounds = try await MCPTestSupport.call("get_layer_bounds", ["layer": .string(folder.id.uuidString)], in: workspace)
        #expect(rect(visibleBounds["bounds"]) == CGRect(x: 4, y: 4, width: 4, height: 4) && visibleBounds["layer_count"]?.intValue == 1)

        let adjustment = try await MCPTestSupport.call("add_adjustment_layer", ["kind": "exposure"], in: workspace)
        let adjustmentID = try #require(adjustment["layer_id"]?.stringValue)
        try await MCPTestSupport.call("render_layer", ["layer": .string(adjustmentID)], in: workspace, expectError: "unsupported")
        try await MCPTestSupport.call("render_layer", ["layer": "Nope"], in: workspace, expectError: "not_found")
    }

    // MARK: Content bounds

    @Test func contentBoundsFindTheOnlyOpaquePixel() throws {
        let sparse = try image(width: 10, height: 10) { x, y in x == 3 && y == 7 ? (255, 255, 255, 255) : (0, 0, 0, 0) }
        #expect(try ContentBounds.pixelBounds(of: sparse) == CGRect(x: 3, y: 7, width: 1, height: 1))
        let empty = try solid(width: 6, height: 6, (0, 0, 0, 0))
        #expect(try ContentBounds.pixelBounds(of: empty) == nil)
        let full = try solid(width: 6, height: 5, (10, 20, 30, 255))
        #expect(try ContentBounds.pixelBounds(of: full) == CGRect(x: 0, y: 0, width: 6, height: 5))
    }

    @Test func layerBoundsReportTransformCornersContentAndMask() async throws {
        let workspace = MCPTestSupport.workspace(width: 100, height: 100)
        let session = workspace.current.session
        // Opaque only in pixels x 2..<4, y 4..<6 of an 8×8 layer drawn at 2× from (10, 20).
        let sparse = try image(width: 8, height: 8) { x, y in (2..<4).contains(x) && (4..<6).contains(y) ? (0, 0, 0, 255) : (0, 0, 0, 0) }
        let id = try insert(sparse, name: "Sparse", at: CGPoint(x: 10, y: 20), in: session)
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].transform.size = CGSize(width: 16, height: 16)

        let bounds = try await MCPTestSupport.call("get_layer_bounds", ["layer": "Sparse"], in: workspace)
        #expect(rect(bounds["bounds"]) == CGRect(x: 10, y: 20, width: 16, height: 16))
        #expect(rect(bounds["content_bounds"]) == CGRect(x: 14, y: 28, width: 4, height: 4))
        #expect(rect(bounds["pixel_content_bounds"]) == CGRect(x: 2, y: 4, width: 2, height: 2))
        #expect(bounds["pixel_width"]?.intValue == 8 && bounds["pixel_height"]?.intValue == 8)
        let corners = try #require(bounds["corners"]?.arrayValue)
        #expect(corners.count == 4)
        #expect(corners[0].objectValue?["x"]?.doubleValue == 10 && corners[2].objectValue?["y"]?.doubleValue == 36)
        #expect(bounds["transform"]?.objectValue?["width"]?.doubleValue == 16)
        #expect(bounds["mask"] == nil || bounds["mask"] == .null)

        let skipped = try await MCPTestSupport.call("get_layer_bounds", ["layer": "Sparse", "content": false], in: workspace)
        #expect(skipped["content_bounds"] == nil)

        // Rotated a quarter turn, the upright box swaps its sides around the same center.
        session.document?.layers[index].transform.size = CGSize(width: 16, height: 8)
        session.document?.layers[index].transform.rotation = 90
        let turned = try await MCPTestSupport.call("get_layer_bounds", ["layer": "Sparse"], in: workspace)
        let box = try #require(rect(turned["bounds"]))
        #expect(abs(box.minX - 14) < 1e-6 && abs(box.minY - 16) < 1e-6 && abs(box.width - 8) < 1e-6 && abs(box.height - 16) < 1e-6)

        // A mask reports where it sits; effects grow the drawn box.
        session.selectLayer(id)
        session.addLayerMask()
        var effects = LayerEffects()
        effects.stroke = StrokeEffect(size: 3)
        session.setEffects(effects, on: id, name: "Stroke")
        let masked = try await MCPTestSupport.call("get_layer_bounds", ["layer": "Sparse"], in: workspace)
        #expect(masked["mask"]?.objectValue?["enabled"] == .bool(true))
        #expect(rect(masked["mask"]?.objectValue?["bounds"]) != nil)
        let grown = try #require(rect(masked["effects_bounds"]))
        #expect(grown.contains(box) && grown != box)

        try await MCPTestSupport.call("get_layer_bounds", [:], in: workspace, expectError: "invalid_argument")
    }

    @Test func layerBoundsOfTextIncludeMetrics() async throws {
        let workspace = MCPTestSupport.workspace(width: 400, height: 200)
        let session = workspace.current.session
        session.beginText(at: CGPoint(x: 20, y: 30), newLayer: true)
        var draft = try #require(session.textDraft)
        draft.style.content = "Hello\nWorld"
        draft.style.fontSize = 24
        try #require(session.applyText(draft))
        let id = try #require(session.activeLayerID)
        let bounds = try await MCPTestSupport.call("get_layer_bounds", ["layer": .string(id.uuidString)], in: workspace)
        let text = try #require(bounds["text"]?.objectValue)
        #expect(text["font_size"]?.doubleValue == 24)
        #expect(text["line_count"]?.intValue == 2)
        #expect(text["line_height"]?.doubleValue == 24 * 1.2)
        // The ink sits inside the layer's padded box.
        let box = try #require(rect(bounds["bounds"]))
        let ink = try #require(rect(bounds["content_bounds"]))
        #expect(box.contains(ink) && ink.width < box.width)
    }

    // MARK: Colors

    @Test func pixelColorFromTheCompositeAndFromALayer() async throws {
        let workspace = MCPTestSupport.workspace(width: 40, height: 40)
        let session = workspace.current.session
        try insert(try solid(width: 10, height: 10, (255, 0, 0, 255)), name: "Red", at: CGPoint(x: 0, y: 0), in: session)
        // Left pixel red, right pixel blue, stretched over 20×10 and flipped horizontally.
        let pair = try image(width: 2, height: 1) { x, _ in x == 0 ? (255, 0, 0, 255) : (0, 0, 255, 128) }
        let id = try insert(pair, name: "Pair", at: CGPoint(x: 20, y: 20), in: session)
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].transform.size = CGSize(width: 20, height: 10)
        session.document?.layers[index].transform.flipX = true
        session.document?.layers[index].opacity = 0.5

        let red = try await MCPTestSupport.call("get_pixel_color", ["x": 5, "y": 5], in: workspace)
        #expect(red["hex"]?.stringValue == "#ff0000" && red["a"]?.doubleValue == 1)
        #expect(red["r"]?.doubleValue == 1 && red["g"]?.doubleValue == 0)
        let clear = try await MCPTestSupport.call("get_pixel_color", ["x": 30, "y": 5], in: workspace)
        #expect(clear["a"]?.doubleValue == 0)

        // Layer source: the layer's own pixel under the point, before opacity; flipped, the left half is blue.
        let left = try await MCPTestSupport.call("get_pixel_color", ["x": 21, "y": 25, "source": "layer", "layer": "Pair"], in: workspace)
        #expect(left["hex"]?.stringValue == "#0000ff")
        #expect(abs((left["a"]?.doubleValue ?? 0) - 128.0 / 255) < 0.01)
        #expect(left["inside"] == .bool(true))
        #expect(left["layer_x"]?.intValue == 1 && left["layer_y"]?.intValue == 0)
        let right = try await MCPTestSupport.call("get_pixel_color", ["x": 38, "y": 29, "source": "layer", "layer": "Pair"], in: workspace)
        #expect(right["hex"]?.stringValue == "#ff0000" && right["layer_x"]?.intValue == 0)
        let outside = try await MCPTestSupport.call("get_pixel_color", ["x": 5, "y": 5, "source": "layer", "layer": "Pair"], in: workspace)
        #expect(outside["inside"] == .bool(false) && outside["a"]?.doubleValue == 0)
        // Layer sampling defaults to the active layer ("Pair", inserted last).
        let active = try await MCPTestSupport.call("get_pixel_color", ["x": 21, "y": 25, "source": "layer"], in: workspace)
        #expect(active["layer_id"]?.stringValue == id.uuidString)

        try await MCPTestSupport.call("get_pixel_color", ["x": 40, "y": 0], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("get_pixel_color", ["x": 1], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("get_pixel_color", ["x": 1, "y": 1, "source": "mask"], in: workspace, expectError: "invalid_argument")
        let folder = try await MCPTestSupport.call("add_group", [:], in: workspace)
        let folderID = try #require(folder["group_id"]?.stringValue)
        try await MCPTestSupport.call("get_pixel_color", ["x": 1, "y": 1, "source": "layer", "layer": .string(folderID)],
                                      in: workspace, expectError: "precondition_failed")
    }

    @Test func sampleColorsReadsManyPointsAtOnce() async throws {
        let workspace = MCPTestSupport.workspace(width: 20, height: 20)
        let session = workspace.current.session
        try insert(try solid(width: 10, height: 20, (0, 255, 0, 255)), name: "Green", at: .zero, in: session)
        let result = try await MCPTestSupport.call("sample_colors", ["points": [["x": 1, "y": 1], ["x": 15, "y": 3], ["x": 9.7, "y": 19.2]]], in: workspace)
        let colors = try #require(result["colors"]?.arrayValue)
        #expect(colors.count == 3)
        #expect(colors[0].objectValue?["hex"]?.stringValue == "#00ff00")
        #expect(colors[1].objectValue?["a"]?.doubleValue == 0)
        #expect(colors[2].objectValue?["x"]?.intValue == 9 && colors[2].objectValue?["hex"]?.stringValue == "#00ff00")

        let layer = try await MCPTestSupport.call("sample_colors", ["points": [["x": 1, "y": 1]], "source": "layer", "layer": "Green"], in: workspace)
        #expect(layer["colors"]?.arrayValue?.first?.objectValue?["hex"]?.stringValue == "#00ff00")

        let tooMany: [Value] = (0..<257).map { _ in ["x": 1, "y": 1] }
        try await MCPTestSupport.call("sample_colors", ["points": .array(tooMany)], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("sample_colors", ["points": []], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("sample_colors", ["points": [["x": 1]]], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("sample_colors", ["points": [["x": 1, "y": 50]]], in: workspace, expectError: "invalid_argument")
    }

    // MARK: Registry

    @Test func renderPreviewIsReplacedAndPreviewToolsAreAnnotated() {
        let names = Set(MCPToolRegistry.tools.map(\.name))
        #expect(!names.contains("render_preview"))
        for name in ["render_document", "render_region", "render_layer", "get_layer_bounds", "get_pixel_color", "sample_colors"] {
            #expect(names.contains(name), "Missing \(name)")
        }
        // Previews are the most frequent call in an edit/look loop: read-only, so clients never prompt for them.
        for name in ["render_document", "render_region", "render_layer", "get_layer_bounds", "get_pixel_color", "sample_colors"] {
            let annotations = MCPToolRegistry.entriesByName[name]?.tool.annotations
            #expect(annotations?.readOnlyHint == true && annotations?.destructiveHint == false && annotations?.idempotentHint == true, "\(name)")
            let properties = MCPToolRegistry.entriesByName[name]?.tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
            #expect(properties["save_to"] == nil && properties["overwrite"] == nil, "\(name) must not write files")
        }
        #expect(MCPToolRegistry.instructions.contains("render_document"))
        #expect(!MCPToolRegistry.instructions.contains("render_preview"))
    }
}
