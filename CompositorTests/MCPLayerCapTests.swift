import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import MCP
@testable import Compositor

/// The 10,000-layer cap: every tool that adds layers checks it before changing anything, with guard `max_layers`, and
/// opening a file with too many layers says so the same way rather than as a pixel budget.
@MainActor struct MCPLayerCapTests {
    private func solid(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func error(_ result: [String: Value]) -> [String: Value] { result["error"]?.objectValue ?? [:] }

    /// A document of exactly `count` layers: blank ones, then a folder "Folder" holding "Inside", then "Photo" with
    /// pixels, which is active.
    private func crowded(_ count: Int) throws -> (ProjectWorkspace, EditorSession) {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        let session = workspace.current.session
        let size = CGSize(width: 16, height: 16)
        var layers = (0..<(count - 3)).map { ImageLayer(name: "Blank \($0)", blankSize: size) }
        var folder = ImageLayer(name: "Folder", blankSize: size)
        folder.isGroup = true
        var inside = ImageLayer(name: "Inside", blankSize: size)
        inside.parentID = folder.id
        let image = try solid(width: 16, height: 16)
        let photo = ImageLayer(id: UUID(), asset: ImportedImage(image: image, thumbnail: image, name: "Photo"), name: "Photo",
                               isVisible: true, transform: LayerTransform(origin: .zero, size: size))
        layers += [inside, folder, photo]
        session.document?.layers = layers
        session.selectLayer(photo.id)
        return (workspace, session)
    }

    private func pngFile() throws -> URL {
        let url = MCPTestSupport.tempFile("cap.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try solid(width: 4, height: 4), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func everyToolThatAddsLayersChecksTheCapFirst() async throws {
        let (workspace, session) = try crowded(10_000)
        let png = try pngFile()
        session.pasteboard = TestPasteboards.unique()
        session.pixelClipboard = PixelClipboard(image: try solid(width: 4, height: 4), origin: .zero,
                                                changeCount: session.pasteboard.changeCount)
        let document = try #require(session.document)
        let undoCount = session.history.undoCount
        let calls: [(String, [String: Value])] = [
            ("add_blank_layer", [:]),
            ("add_image_layer", ["path": .string(png.path)]),
            ("add_group", [:]),
            ("duplicate_layer", ["layer": "Photo"]),
            ("layer_via_copy", ["layer": "Photo"]),
            ("group_layers", ["layers": ["Photo"]]),
            ("paste_pixels", [:]),
            ("add_adjustment_layer", ["kind": "invert"]),
            ("add_text_layer", ["text": "Title", "x": 0, "y": 0]),
            ("add_shape", ["kind": "rectangle", "rect": ["x": 0, "y": 0, "width": 4, "height": 4]]),
            ("place_smart_object", ["path": .string(png.path)]),
            // A colored border is a layer of its own.
            ("resize_canvas", ["width": 20, "height": 20, "fill": "#ff0000"]),
        ]
        for (tool, args) in calls {
            let refused = try await MCPTestSupport.call(tool, args, in: workspace, expectError: "precondition_failed")
            #expect(error(refused)["guard"]?.stringValue == "max_layers", "\(tool): \(refused)")
            // One check, one message: every tool refuses through MCPGuards.requireLayerCapacity.
            #expect(error(refused)["hint"]?.stringValue == "Delete, merge or flatten layers first.", "\(tool): \(refused)")
            #expect(error(refused)["message"]?.stringValue?.contains("folders count too") == true, "\(tool): \(refused)")
        }
        #expect(session.document == document && session.history.undoCount == undoCount)
        // Without a fill nothing is added.
        try await MCPTestSupport.call("resize_canvas", ["width": 20, "height": 20], in: workspace)
        #expect(session.document?.width == 20 && session.document?.layers.count == 10_000)
    }

    /// The resizer itself stops at the cap with `LayerLimitError`, so the app's Canvas Size says the document has too
    /// many layers, not that it's too large.
    @Test func aColoredCanvasExtensionStopsAtTheLayerCap() async throws {
        let (_, session) = try crowded(10_000)
        let snapshot = try #require(session.projectSnapshot())
        let options = CanvasSizeOptions(width: 20, height: 20, anchor: 4, fill: CanvasExtensionColor(red: 1, green: 0, blue: 0))
        await #expect(throws: LayerLimitError.self) { try await CanvasResizer.shared.resize(snapshot, to: options) }
    }

    /// The session's own commands stop at the same cap, `LayerLimitError.maximum`, and say so with `LayerLimitError`,
    /// which tools report as guard max_layers rather than as a file too large to import.
    @Test func sessionCommandsStopAtTheSharedCap() async throws {
        let (_, session) = try crowded(LayerLimitError.maximum)
        let document = try #require(session.document)
        let png = try pngFile()
        await #expect(throws: LayerLimitError.self) { _ = try await session.placeSmartObject(from: png) }
        #expect(session.insertAdjustmentLayer(LayerAdjustment(kind: .invert), name: "Invert") == nil)
        #expect(session.document == document)
        #expect(MCPToolError.from(LayerLimitError()).guardName == "max_layers")
    }

    /// A folder's copy counts its contents too.
    @Test func duplicatingAFolderCountsWhatIsInsideIt() async throws {
        let (workspace, session) = try crowded(9_999)
        let refused = try await MCPTestSupport.call("duplicate_layer", ["layer": "Folder"], in: workspace, expectError: "precondition_failed")
        #expect(error(refused)["guard"]?.stringValue == "max_layers")
        try await MCPTestSupport.call("duplicate_layer", ["layer": "Photo"], in: workspace)
        #expect(session.document?.layers.count == 10_000)
    }

    // MARK: Opening

    @Test func aPhotoshopFileWithTooManyLayersIsRefusedByTheLayerCap() async throws {
        let image = try solid(width: 2, height: 2)
        var record = PSDRecord(id: UUID(), name: "Only")
        record.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        record.image = image
        var data = Data(try PSDFixture.data(PSDDocument(width: 2, height: 2, resolution: 72, layers: [record]), composite: image))
        // The layer count, after the header, color mode data, image resources and the two section lengths.
        func u32(_ at: Int) -> Int { data[at..<(at + 4)].reduce(0) { $0 << 8 | Int($1) } }
        var offset = 26
        offset += 4 + u32(offset)
        offset += 4 + u32(offset)
        offset += 8
        let count = UInt16(10_001)
        data[offset] = UInt8(count >> 8)
        data[offset + 1] = UInt8(count & 0xFF)
        let url = MCPTestSupport.tempFile("Crowded.psd")
        try data.write(to: url)

        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        let refused = try await MCPTestSupport.call("open_document", ["path": .string(url.path)], in: workspace, expectError: "precondition_failed")
        #expect(error(refused)["guard"]?.stringValue == "max_layers", "\(refused)")
        #expect(error(refused)["details"]?.objectValue?["path"]?.stringValue == url.path)
        #expect(workspace.tabs.count == 1)
    }

    @Test func aProjectWithTooManyLayersIsRefusedByTheLayerCap() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        let url = MCPTestSupport.tempFile("Crowded.comp")
        try await MCPTestSupport.call("save_document_as", ["path": .string(url.path)], in: workspace)
        let manifestURL = url.appendingPathComponent("manifest.json")
        var manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let layer = try #require((manifest["layers"] as? [Any])?.first)
        manifest["layers"] = Array(repeating: layer, count: 10_001)
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        try await MCPTestSupport.call("close_document", ["discard_changes": true], in: workspace)

        let refused = try await MCPTestSupport.call("open_document", ["path": .string(url.path)], in: workspace, expectError: "precondition_failed")
        #expect(error(refused)["guard"]?.stringValue == "max_layers", "\(refused)")
    }
}
