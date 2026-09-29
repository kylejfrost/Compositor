import CoreGraphics
import Foundation
import Testing
import MCP
@testable import Compositor

/// One lock model across the tool families: a folder's locks hold what is inside it for paint, mask, filter, pixel
/// move and transform tools alike (`MCPGuards.requireUnlocked`, the same folder-aware check the app makes). Effects
/// and adjustment settings are refused only by Lock All, since Photoshop's pixel lock leaves layer styles editable.
/// Photoshop placeholders are refused with one guard name, `placeholder`.
@MainActor struct MCPLockToolTests {
    // MARK: Helpers

    /// An opaque `width` × `height` image of one color.
    private func solid(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// Adds an opaque `size` layer named `name`, centered at `center` (the canvas's center by default).
    @discardableResult
    private func addLayer(_ session: EditorSession, _ name: String, size: CGSize = CGSize(width: 64, height: 32),
                          at center: CGPoint? = nil) throws -> UUID {
        let image = try solid(width: Int(size.width), height: Int(size.height))
        session.insert(ImportedImage(image: image, thumbnail: image, name: name), centeredAt: center)
        return try #require(session.activeLayerID)
    }

    /// Puts `ids` into a new folder named "Folder" and returns the folder's id.
    private func folder(_ session: EditorSession, holding ids: Set<UUID>) throws -> UUID {
        session.selectLayers(ids, primary: ids.first)
        session.groupSelectedLayers()
        let folder = try #require(session.activeLayerID)
        session.renameLayer(folder, to: "Folder")
        return folder
    }

    private func setLocks(_ session: EditorSession, _ id: UUID, _ locks: LayerLocks) throws {
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].locks = locks
    }

    private func error(_ result: [String: Value]) -> [String: Value] { result["error"]?.objectValue ?? [:] }

    private func point(_ x: Double, _ y: Double) -> Value { ["x": .double(x), "y": .double(y)] }

    // MARK: Pixels

    @Test func aPixelLockedFolderBlocksPaintFiltersAndPixelMovesOnItsChild() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        let photo = try addLayer(session, "Photo")
        let folder = try folder(session, holding: [photo])
        try setLocks(session, folder, [.pixels])
        try await MCPTestSupport.call("select_rect", ["rect": ["x": 4, "y": 4, "width": 8, "height": 8]], in: workspace)
        let document = try #require(session.document)
        let before = session.history.undoCount

        let refusals: [(String, [String: Value])] = [
            ("stroke_path", ["layer": "Folder/Photo", "points": [point(4, 16), point(60, 16)]]),
            ("fill_selection", ["layer": "Folder/Photo", "color": "#00ff00"]),
            // Its mask stays editable, as in Photoshop: only Lock All holds a mask (LockFollowUpTests).
            ("invert_pixels", ["layer": "Folder/Photo"]),
            ("apply_filter", ["layer": "Folder/Photo", "kind": "gaussian_blur", "settings": ["radius": 2]]),
            ("move_selected_pixels", ["layer": "Folder/Photo", "dx": 5, "dy": 0]),
        ]
        for (tool, args) in refusals {
            let refused = try await MCPTestSupport.call(tool, args, in: workspace, expectError: "precondition_failed")
            #expect(error(refused)["guard"]?.stringValue == "layer_locked", "\(tool): \(refused)")
            #expect(error(refused)["details"]?.objectValue?["locked_by_id"]?.stringValue == folder.uuidString, "\(tool): \(refused)")
            #expect(error(refused)["message"]?.stringValue?.contains("'Folder'") == true, "\(tool): \(refused)")
        }
        #expect(session.document?.layers == document.layers)
        #expect(session.history.undoCount == before)

        // Unlocked, a stroke goes through.
        try setLocks(session, folder, [])
        try await MCPTestSupport.call("select_none", in: workspace)
        let painted = try await MCPTestSupport.call("stroke_path", ["layer": "Folder/Photo", "points": [point(4, 16), point(60, 16)]],
                                                    in: workspace)
        #expect(painted["undo"]?.objectValue?["recorded"] == .bool(true))
    }

    // MARK: Effects and adjustments

    @Test func onlyLockAllBlocksEffectsAndAdjustmentSettings() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        let photo = try addLayer(session, "Photo")
        try await MCPTestSupport.call("add_adjustment_layer", ["kind": "hue_saturation", "name": "Tint"], in: workspace)
        let tint = try #require(session.activeLayerID)
        let folder = try folder(session, holding: [photo, tint])
        let stroke: [String: Value] = ["layer": "Folder/Photo", "effects": ["stroke": ["size": 2, "color": "#000000"]]]

        // A pixel lock, the layer's own or its folder's, leaves layer styles and adjustment settings editable.
        try setLocks(session, photo, [.pixels])
        try await MCPTestSupport.call("set_layer_effects", stroke, in: workspace)
        try setLocks(session, photo, [])
        try setLocks(session, folder, [.pixels, .position])
        try await MCPTestSupport.call("set_layer_effect_enabled", ["layer": "Folder/Photo", "kind": "stroke", "enabled": false], in: workspace)
        try await MCPTestSupport.call("set_adjustment", ["layer": "Folder/Tint", "settings": ["hue": 10]], in: workspace)

        // Lock All on the folder holds both.
        try setLocks(session, folder, [.all])
        let document = try #require(session.document)
        let refusals: [(String, [String: Value])] = [
            ("set_layer_effects", stroke),
            ("add_layer_effect", ["layer": "Folder/Photo", "kind": "shadow"]),
            ("remove_layer_effect", ["layer": "Folder/Photo", "kind": "stroke"]),
            ("set_layer_effect_enabled", ["layer": "Folder/Photo", "kind": "stroke", "enabled": true]),
            ("set_adjustment", ["layer": "Folder/Tint", "settings": ["hue": 20]]),
        ]
        for (tool, args) in refusals {
            let refused = try await MCPTestSupport.call(tool, args, in: workspace, expectError: "precondition_failed")
            #expect(error(refused)["guard"]?.stringValue == "layer_locked", "\(tool): \(refused)")
            #expect(error(refused)["details"]?.objectValue?["locked_by_id"]?.stringValue == folder.uuidString, "\(tool): \(refused)")
        }
        #expect(session.document?.layers == document.layers)
        // The layer's own Lock All does too.
        try setLocks(session, folder, [])
        try setLocks(session, photo, [.all])
        try await MCPTestSupport.call("set_layer_effects", stroke, in: workspace, expectError: "precondition_failed")
    }

    // MARK: Transforms

    /// A folder's position lock holds everything in it against every tool that moves layers, the folder itself
    /// included, while layers outside it stay free.
    @Test func aPositionLockedFolderHoldsItsContentsAgainstEveryTransformTool() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 64)
        let session = workspace.current.session
        let a = try addLayer(session, "A", size: CGSize(width: 8, height: 8), at: CGPoint(x: 8, y: 8))
        let b = try addLayer(session, "B", size: CGSize(width: 8, height: 8), at: CGPoint(x: 24, y: 8))
        try addLayer(session, "C", size: CGSize(width: 8, height: 8), at: CGPoint(x: 44, y: 8))
        let folder = try folder(session, holding: [a, b])
        try setLocks(session, folder, [.position])
        let document = try #require(session.document)
        let before = session.history.undoCount

        let corners: Value = [point(0, 0), point(10, 0), point(10, 10), point(0, 10)]
        let refusals: [(String, [String: Value])] = [
            ("move_layer", ["layer": "Folder", "dx": 1, "dy": 1]),
            ("move_layer", ["layer": "Folder/A", "dx": 1, "dy": 1]),
            ("set_layer_transform", ["layer": "Folder/A", "x": 3]),
            ("set_layer_scale", ["layer": "Folder/A", "percent": 50]),
            ("rotate_layer", ["layer": "Folder/A", "degrees": 45]),
            ("scale_layer_to_fit", ["layer": "Folder/A", "rect": ["x": 0, "y": 0, "width": 32, "height": 32], "mode": "contain"]),
            ("flip_layer", ["layers": ["C", "Folder/A"], "axis": "horizontal"]),
            ("flip_layer", ["layers": ["Folder"], "axis": "vertical"]),
            ("distort_layer", ["layer": "Folder/B", "corners": corners]),
            ("align_layers", ["layers": ["C", "Folder/B"], "edge": "left", "to": "canvas"]),
            ("distribute_layers", ["layers": ["Folder/A", "Folder/B", "C"], "axis": "vertical", "spacing": 2]),
        ]
        for (tool, args) in refusals {
            let refused = try await MCPTestSupport.call(tool, args, in: workspace, expectError: "precondition_failed")
            #expect(error(refused)["guard"]?.stringValue == "layer_locked", "\(tool): \(refused)")
            #expect(error(refused)["details"]?.objectValue?["locked_by_id"]?.stringValue == folder.uuidString, "\(tool): \(refused)")
        }
        #expect(session.document?.layers == document.layers)
        #expect(session.history.undoCount == before)
        try await MCPTestSupport.call("move_layer", ["layer": "C", "dx": 1, "dy": 0], in: workspace)
    }

    // MARK: Reporting

    @Test func getLayerAndGetDocumentReportOwnAndEffectiveLocks() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        let photo = try addLayer(session, "Photo")
        let folder = try folder(session, holding: [photo])
        try setLocks(session, folder, [.position])
        try setLocks(session, photo, [.pixels])

        let described = try await MCPTestSupport.call("get_layer", ["layer": "Folder/Photo"], in: workspace)
        let layer = try #require(described["layer"]?.objectValue)
        #expect(layer["locks"] == .array([.string("pixels")]))
        #expect(layer["effective_locks"] == .array([.string("pixels"), .string("position")]))

        let summary = try await MCPTestSupport.call("get_document", in: workspace)
        let roots = try #require(summary["document"]?.objectValue?["layers"]?.arrayValue).compactMap(\.objectValue)
        let folderValue = try #require(roots.first { $0["id"]?.stringValue == folder.uuidString })
        #expect(folderValue["effective_locks"] == .array([.string("position")]))
        let child = try #require(folderValue["children"]?.arrayValue?.first?.objectValue)
        #expect(child["locks"] == .array([.string("pixels")]))
        #expect(child["effective_locks"] == .array([.string("pixels"), .string("position")]))
    }

    // MARK: Placeholders

    /// A placeholder built as import builds one (`PSDDocumentBuilder`): hidden, with no pixels, covering the canvas.
    /// Every tool names the placeholder as the reason, before it looks for pixels, visibility or a mask, so no hint
    /// sends the agent to paint a layer that can't be painted.
    @Test func photoshopPlaceholdersAreRefusedWithOneGuardName() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        let placeholder = ImageLayer(id: UUID(), asset: nil, name: "Photo", isVisible: false,
                                     transform: LayerTransform(origin: .zero, size: CGSize(width: 64, height: 32)),
                                     psdExtras: PSDLayerExtras(importedVisible: true, placeholder: "adjustment:brit"))
        session.document?.layers.append(placeholder)
        try await MCPTestSupport.call("select_rect", ["rect": ["x": 4, "y": 4, "width": 8, "height": 8]], in: workspace)
        let document = try #require(session.document)
        let undoCount = session.history.undoCount

        let refusals: [(String, [String: Value], String)] = [
            ("stroke_path", ["layer": "Photo", "points": [point(4, 16), point(60, 16)]], "precondition_failed"),
            ("fill_selection", ["layer": "Photo", "color": "#00ff00"], "precondition_failed"),
            ("fill_selection", ["layer": "Photo", "target": "mask", "color": "#000000"], "precondition_failed"),
            ("invert_pixels", ["layer": "Photo"], "precondition_failed"),
            ("apply_filter", ["layer": "Photo", "kind": "gaussian_blur", "settings": ["radius": 2]], "precondition_failed"),
            ("apply_levels", ["layer": "Photo", "settings": ["black": 20]], "precondition_failed"),
            ("apply_hue_saturation", ["layer": "Photo", "settings": ["hue": 20]], "precondition_failed"),
            ("content_aware_fill", ["layer": "Photo"], "precondition_failed"),
            ("remove_background", ["layer": "Photo"], "precondition_failed"),
            ("move_selected_pixels", ["layer": "Photo", "dx": 5, "dy": 0], "precondition_failed"),
            ("apply_layer_mask", ["layer": "Photo"], "precondition_failed"),
            ("rasterize_layer", ["layer": "Photo"], "precondition_failed"),
            ("set_layer_scale", ["layer": "Photo", "percent": 50], "precondition_failed"),
            ("set_layer_effects", ["layer": "Photo", "effects": ["stroke": ["size": 2, "color": "#000000"]]], "precondition_failed"),
            ("add_layer_effect", ["layer": "Photo", "kind": "shadow"], "precondition_failed"),
            ("set_adjustment", ["layer": "Photo", "settings": ["hue": 10]], "unsupported"),
        ]
        for (tool, args, code) in refusals {
            let refused = try await MCPTestSupport.call(tool, args, in: workspace, expectError: code)
            #expect(error(refused)["guard"]?.stringValue == "placeholder", "\(tool): \(refused)")
        }
        #expect(session.document?.layers == document.layers)
        #expect(session.history.undoCount == undoCount)
    }
}
