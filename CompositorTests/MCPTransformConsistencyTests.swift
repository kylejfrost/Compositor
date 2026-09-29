import CoreGraphics
import Foundation
import Testing
import MCP
@testable import Compositor

/// Moves that would take a layer past ±1,000,000 pixels are refused as invalid arguments rather than silently
/// skipped, and align_layers and distribute_layers move every layer or none.
@MainActor struct MCPTransformConsistencyTests {
    private func solid() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return try #require(context.makeImage())
    }

    /// An 8 × 8 layer named `name` with its top-left corner at (`x`, 0).
    @discardableResult
    private func addLayer(_ session: EditorSession, _ name: String, x: CGFloat) throws -> UUID {
        let image = try solid()
        session.insert(ImportedImage(image: image, thumbnail: image, name: name))
        let id = try #require(session.activeLayerID)
        session.renameLayer(id, to: name)
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].transform.origin = CGPoint(x: x, y: 0)
        return id
    }

    private func folder(_ session: EditorSession, _ ids: Set<UUID>, name: String) throws -> UUID {
        session.selectLayers(ids, primary: ids.first)
        session.groupSelectedLayers()
        let folder = try #require(session.activeLayerID)
        session.renameLayer(folder, to: name)
        return folder
    }

    @Test func movesPastTheLimitAreInvalidArguments() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 64)
        let session = workspace.current.session
        try addLayer(session, "A", x: 0)
        let far = try addLayer(session, "Far", x: 999_990)
        let near = try addLayer(session, "Near", x: 0)
        _ = try folder(session, [far, near], name: "Folder")
        let document = try #require(session.document)
        let undoCount = session.history.undoCount
        let calls: [(String, [String: Value])] = [
            ("move_layer", ["layer": "A", "dx": 2_000_000, "dy": 0]),
            // The folder's own box is the canvas, but what is inside it would go too far.
            ("move_layer", ["layer": "Folder", "dx": 20, "dy": 0]),
            ("set_layer_transform", ["layer": "Folder", "x": 20]),
        ]
        for (tool, args) in calls {
            let refused = try await MCPTestSupport.call(tool, args, in: workspace, expectError: "invalid_argument")
            #expect(refused["error"]?.objectValue?["message"]?.stringValue?.contains("1,000,000") == true, "\(tool): \(refused)")
        }
        #expect(session.document == document && session.history.undoCount == undoCount)
    }

    @Test func alignAndDistributeMoveEveryLayerOrNone() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 64)
        let session = workspace.current.session
        try addLayer(session, "A", x: 100)
        let left = try addLayer(session, "Left", x: -999_990)
        let right = try addLayer(session, "Right", x: 999_990)
        _ = try folder(session, [left, right], name: "Wide")
        try addLayer(session, "B", x: 10)
        try addLayer(session, "C", x: 20)
        let document = try #require(session.document)
        let undoCount = session.history.undoCount

        // Centering the wide folder moves Right past the limit; A alone could move, but nothing does.
        let aligned = try await MCPTestSupport.call("align_layers", ["layers": ["A", "Wide"], "edge": "center_x", "to": "canvas"],
                                                    in: workspace, expectError: "invalid_argument")
        #expect(aligned["error"]?.objectValue?["message"]?.stringValue?.contains("Wide") == true, "\(aligned)")
        // At 900,000 pixels apart, B still fits and C doesn't.
        try await MCPTestSupport.call("distribute_layers", ["layers": ["A", "B", "C"], "axis": "horizontal", "spacing": 900_000],
                                      in: workspace, expectError: "invalid_argument")
        #expect(session.document == document && session.history.undoCount == undoCount)

        // Within the limit both still work.
        try await MCPTestSupport.call("align_layers", ["layers": ["A", "B"], "edge": "left", "to": "canvas"], in: workspace)
        try await MCPTestSupport.call("distribute_layers", ["layers": ["A", "B", "C"], "axis": "horizontal", "spacing": 4], in: workspace)
        #expect(session.history.undoCount == undoCount + 2)
    }
}
