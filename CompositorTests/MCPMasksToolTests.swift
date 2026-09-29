import CoreGraphics
import Foundation
import Testing
import MCP
@testable import Compositor

/// The layer mask tools: adding a mask that reveals, hides or follows the selection, showing and linking it, deleting
/// it, applying it to the layer's pixels and copying it to another layer. Each edit is one undo step named as the app
/// names it; the toggles change nothing (and record nothing) when the mask is already as asked.
@MainActor struct MCPMasksToolTests {
    // MARK: Helpers

    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A 64×32 document whose "Layer 1" is filled opaque red.
    private func redWorkspace() async throws -> ProjectWorkspace {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        try await MCPTestSupport.call("fill_selection", ["layer": "Layer 1", "color": "#ff0000"], in: workspace)
        return workspace
    }

    private func layer(_ session: EditorSession, _ name: String) -> ImageLayer? { session.document?.layers.first { $0.name == name } }

    /// Sets a layer's Photoshop locks directly, as a file would bring them.
    private func lock(_ session: EditorSession, _ name: String, _ locks: LayerLocks) throws {
        let index = try #require(session.document?.layers.firstIndex { $0.name == name })
        session.document?.layers[index].locks = locks
    }

    /// One pixel as premultiplied 0–255 RGBA.
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let index = (y * image.width + x) * 4
        return (0..<4).map { Int(bytes[index + $0]) }
    }

    private func alpha(_ image: CGImage, x: Int, y: Int) throws -> Int { try pixel(image, x: x, y: y)[3] }

    /// A mask's stored gray value (0 hides, 255 reveals), read from its bytes without color conversion.
    private func maskValue(_ mask: CGImage, x: Int, y: Int) throws -> Int {
        let data = try #require(mask.dataProvider?.data) as Data
        return Int(data[y * mask.bytesPerRow + x])
    }

    private func render(_ session: EditorSession) async throws -> CGImage {
        try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
    }

    private func select(_ x: Double, _ y: Double, _ width: Double, _ height: Double, in workspace: ProjectWorkspace) async throws {
        try await MCPTestSupport.call("select_rect", ["rect": ["x": .double(x), "y": .double(y), "width": .double(width),
                                                               "height": .double(height)]], in: workspace)
    }

    private func recorded(_ result: [String: Value]) -> Bool? { result["undo"]?.objectValue?["recorded"]?.boolValue }

    private func guardName(_ result: [String: Value]) -> String? { result["error"]?.objectValue?["guard"]?.stringValue }

    // MARK: add_layer_mask

    @Test func addLayerMaskRevealsHidesOrFollowsTheSelection() async throws {
        let workspace = try await redWorkspace()
        let session = workspace.current.session
        let before = session.history.undoCount

        let hidden = try await MCPTestSupport.call("add_layer_mask", ["layer": "Layer 1", "kind": "hide_all"], in: workspace)
        #expect(hidden["kind"]?.stringValue == "hide_all")
        #expect(hidden["mask"]?.objectValue?["enabled"] == .bool(true) && hidden["mask"]?.objectValue?["linked"] == .bool(true))
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Add Hide-All Mask" && recorded(hidden) == true)
        #expect(try alpha(try await render(session), x: 10, y: 10) == 0)
        #expect(session.isMaskSelected)
        session.undo()

        // A reveal-all mask ignores the selection and leaves it in place.
        try await select(0, 0, 32, 32, in: workspace)
        try await MCPTestSupport.call("add_layer_mask", ["layer": "Layer 1", "kind": "reveal_all"], in: workspace)
        #expect(session.history.undoName == "Add Reveal-All Mask" && session.selection != nil)
        var rendered = try await render(session)
        #expect(try pixel(rendered, x: 10, y: 10) == [255, 0, 0, 255] && alpha(rendered, x: 50, y: 10) == 255)
        session.undo()

        // from_selection shows only the selection; the selection is used up in the same step.
        let count = session.history.undoCount
        try await MCPTestSupport.call("add_layer_mask", ["layer": "Layer 1", "kind": "from_selection"], in: workspace)
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Add Mask from Selection")
        #expect(session.selection == nil)
        rendered = try await render(session)
        #expect(try alpha(rendered, x: 10, y: 10) == 255 && alpha(rendered, x: 50, y: 10) == 0)
        session.undo()
        #expect(layer(session, "Layer 1")?.mask == nil && session.selection != nil)

        // hide_selection hides it.
        try await MCPTestSupport.call("add_layer_mask", ["layer": "Layer 1", "kind": "hide_selection"], in: workspace)
        rendered = try await render(session)
        #expect(try alpha(rendered, x: 10, y: 10) == 0 && alpha(rendered, x: 50, y: 10) == 255)
        #expect(session.history.undoName == "Add Mask from Selection" && session.selection == nil)
    }

    @Test func addLayerMaskRefusesWithoutAnEdit() async throws {
        let workspace = try await redWorkspace()
        let session = workspace.current.session
        let before = session.history.undoCount

        var result = try await MCPTestSupport.call("add_layer_mask", ["layer": "Layer 1", "kind": "from_selection"], in: workspace,
                                                   expectError: "precondition_failed")
        #expect(guardName(result) == "selection")
        try await MCPTestSupport.call("add_layer_mask", ["layer": "Layer 1", "kind": "sideways"], in: workspace,
                                      expectError: "invalid_argument")
        // Lock Pixels leaves the mask editable, as in Photoshop; Lock All holds it.
        try lock(session, "Layer 1", .all)
        result = try await MCPTestSupport.call("add_layer_mask", ["layer": "Layer 1", "kind": "reveal_all"], in: workspace,
                                               expectError: "precondition_failed")
        #expect(guardName(result) == "layer_locked")
        try lock(session, "Layer 1", [])
        #expect(session.history.undoCount == before && layer(session, "Layer 1")?.mask == nil)

        try await MCPTestSupport.call("add_layer_mask", ["layer": "Layer 1"], in: workspace)
        #expect(session.history.undoName == "Add Reveal-All Mask")
        result = try await MCPTestSupport.call("add_layer_mask", ["layer": "Layer 1", "kind": "hide_all"], in: workspace,
                                               expectError: "precondition_failed")
        #expect(guardName(result) == "no_mask")
        #expect(session.history.undoCount == before + 1)
    }

    // MARK: set_mask_enabled, set_mask_linked

    @Test func maskTogglesAreIdempotent() async throws {
        let workspace = try await redWorkspace()
        let session = workspace.current.session
        var result = try await MCPTestSupport.call("set_mask_enabled", ["layer": "Layer 1", "enabled": false], in: workspace,
                                                   expectError: "precondition_failed")
        #expect(guardName(result) == "has_mask")
        try await MCPTestSupport.call("add_layer_mask", ["layer": "Layer 1", "kind": "hide_all"], in: workspace)
        let before = session.history.undoCount

        result = try await MCPTestSupport.call("set_mask_enabled", ["layer": "Layer 1", "enabled": false], in: workspace)
        #expect(layer(session, "Layer 1")?.mask?.isEnabled == false && result["enabled"] == .bool(false))
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Disable Layer Mask" && recorded(result) == true)
        #expect(try alpha(try await render(session), x: 10, y: 10) == 255)
        result = try await MCPTestSupport.call("set_mask_enabled", ["layer": "Layer 1", "enabled": false], in: workspace)
        #expect(session.history.undoCount == before + 1 && recorded(result) == false)
        try await MCPTestSupport.call("set_mask_enabled", ["layer": "Layer 1", "enabled": true], in: workspace)
        #expect(layer(session, "Layer 1")?.mask?.isEnabled == true && session.history.undoName == "Enable Layer Mask")
        #expect(session.history.undoCount == before + 2)

        result = try await MCPTestSupport.call("set_mask_linked", ["layer": "Layer 1", "linked": false], in: workspace)
        #expect(layer(session, "Layer 1")?.mask?.isLinked == false && result["linked"] == .bool(false))
        #expect(session.history.undoCount == before + 3 && session.history.undoName == "Unlink Layer Mask")
        result = try await MCPTestSupport.call("set_mask_linked", ["layer": "Layer 1", "linked": false], in: workspace)
        #expect(session.history.undoCount == before + 3 && recorded(result) == false)
        try await MCPTestSupport.call("set_mask_linked", ["layer": "Layer 1", "linked": true], in: workspace)
        #expect(layer(session, "Layer 1")?.mask?.isLinked == true && session.history.undoName == "Link Layer Mask")
        result = try await MCPTestSupport.call("set_mask_linked", ["layer": "Layer 1", "linked": true], in: workspace)
        #expect(session.history.undoCount == before + 4 && recorded(result) == false)
    }

    // MARK: delete_layer_mask

    @Test func deleteLayerMaskRemovesItAsOneStep() async throws {
        let workspace = try await redWorkspace()
        let session = workspace.current.session
        try await MCPTestSupport.call("add_layer_mask", ["layer": "Layer 1", "kind": "hide_all"], in: workspace)
        let before = session.history.undoCount
        try await MCPTestSupport.call("delete_layer_mask", ["layer": "Layer 1"], in: workspace)
        #expect(layer(session, "Layer 1")?.mask == nil && !session.isMaskSelected)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Delete Layer Mask")
        #expect(try alpha(try await render(session), x: 10, y: 10) == 255)
        let result = try await MCPTestSupport.call("delete_layer_mask", ["layer": "Layer 1"], in: workspace,
                                                   expectError: "precondition_failed")
        #expect(guardName(result) == "has_mask" && session.history.undoCount == before + 1)
    }

    // MARK: apply_layer_mask

    @Test func applyLayerMaskMultipliesAlphaAndRemovesTheMask() async throws {
        let workspace = try await redWorkspace()
        let session = workspace.current.session
        // The mask shows the left half, hides the right, and partly shows a gray band on the left.
        try await select(0, 0, 32, 32, in: workspace)
        try await MCPTestSupport.call("add_layer_mask", ["layer": "Layer 1", "kind": "from_selection"], in: workspace)
        try await select(0, 16, 32, 16, in: workspace)
        try await MCPTestSupport.call("fill_selection", ["layer": "Layer 1", "target": "mask", "color": "#808080"], in: workspace)
        try await MCPTestSupport.call("select_none", in: workspace)
        let shown = try await render(session)
        let gray = try maskValue(try #require(layer(session, "Layer 1")?.mask?.asset.image), x: 10, y: 24)
        #expect(gray > 0 && gray < 255)
        let original = try #require(layer(session, "Layer 1")?.asset?.image)
        let before = session.history.undoCount

        let result = try await MCPTestSupport.call("apply_layer_mask", ["layer": "Layer 1"], in: workspace)
        let applied = try #require(layer(session, "Layer 1"))
        #expect(applied.mask == nil && !session.isMaskSelected && result["layer_id"]?.stringValue == applied.id.uuidString)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Apply Layer Mask" && recorded(result) == true)
        let pixels = try #require(applied.asset?.image)
        #expect(pixels.width == original.width && pixels.height == original.height)
        #expect(try pixel(pixels, x: 10, y: 8) == [255, 0, 0, 255])
        #expect(try alpha(pixels, x: 50, y: 8) == 0 && alpha(pixels, x: 50, y: 24) == 0)
        let band = try pixel(pixels, x: 10, y: 24)
        #expect(abs(band[3] - gray) <= 1 && band[0] == band[3] && band[1] == 0, "\(band) through mask value \(gray)")
        // The layer looks as it did through its mask.
        let after = try await render(session)
        for (x, y) in [(10, 8), (10, 24), (50, 8), (50, 24)] {
            let old = try pixel(shown, x: x, y: y), new = try pixel(after, x: x, y: y)
            #expect(zip(old, new).allSatisfy { abs($0 - $1) <= 1 }, "(\(x), \(y)): \(old) before, \(new) after")
        }

        session.undo()
        #expect(layer(session, "Layer 1")?.mask != nil && layer(session, "Layer 1")?.asset?.image === original)
        try await MCPTestSupport.call("delete_layer_mask", ["layer": "Layer 1"], in: workspace)
        let missing = try await MCPTestSupport.call("apply_layer_mask", ["layer": "Layer 1"], in: workspace,
                                                    expectError: "precondition_failed")
        #expect(guardName(missing) == "has_mask")
    }

    @Test func applyLayerMaskKeepsEffectsAndLeavesTextAsPixels() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        session.beginText(at: CGPoint(x: 4, y: 4), newLayer: true)
        var draft = try #require(session.textDraft)
        draft.style.content = "Hi"
        draft.style.fontSize = 12
        #expect(session.applyText(draft))
        let id = try #require(session.activeLayerID)
        try await MCPTestSupport.call("set_layer_effects", ["layer": .string(id.uuidString), "effects": ["stroke": ["size": 2]]],
                                      in: workspace)
        let effects = try #require(session.document?.layers.first { $0.id == id }?.effects)
        try await MCPTestSupport.call("add_layer_mask", ["layer": .string(id.uuidString)], in: workspace)
        try await MCPTestSupport.call("apply_layer_mask", ["layer": .string(id.uuidString)], in: workspace)
        let applied = try #require(session.document?.layers.first { $0.id == id })
        #expect(applied.mask == nil && applied.text == nil && applied.asset != nil && applied.effects == effects)
    }

    @Test func applyLayerMaskRefusesFoldersAdjustmentsDisabledMasksAndLockAll() async throws {
        let workspace = try await redWorkspace()
        let session = workspace.current.session
        try await MCPTestSupport.call("add_group", ["name": "Folder"], in: workspace)
        // Folders take masks, but have no pixels to apply one to.
        try await MCPTestSupport.call("add_layer_mask", ["layer": "Folder", "kind": "hide_all"], in: workspace)
        var result = try await MCPTestSupport.call("apply_layer_mask", ["layer": "Folder"], in: workspace,
                                                   expectError: "precondition_failed")
        #expect(guardName(result) == "has_pixels")

        let adjustment = try await MCPTestSupport.call("add_adjustment_layer", ["kind": "exposure"], in: workspace)
        let adjustmentID = try #require(adjustment["layer_id"]?.stringValue)
        try await MCPTestSupport.call("add_layer_mask", ["layer": .string(adjustmentID)], in: workspace)
        result = try await MCPTestSupport.call("apply_layer_mask", ["layer": .string(adjustmentID)], in: workspace,
                                               expectError: "precondition_failed")
        #expect(guardName(result) == "has_pixels")

        try await MCPTestSupport.call("add_layer_mask", ["layer": "Layer 1", "kind": "hide_all"], in: workspace)
        try await MCPTestSupport.call("set_mask_enabled", ["layer": "Layer 1", "enabled": false], in: workspace)
        let before = session.history.undoCount
        result = try await MCPTestSupport.call("apply_layer_mask", ["layer": "Layer 1"], in: workspace, expectError: "precondition_failed")
        #expect(guardName(result) == "mask_enabled")
        try await MCPTestSupport.call("set_mask_enabled", ["layer": "Layer 1", "enabled": true], in: workspace)
        // Unlike the other mask tools it rewrites the layer's pixels, so Lock Pixels holds it as well as Lock All.
        for locks in [LayerLocks.all, .pixels] {
            try lock(session, "Layer 1", locks)
            result = try await MCPTestSupport.call("apply_layer_mask", ["layer": "Layer 1"], in: workspace, expectError: "precondition_failed")
            #expect(guardName(result) == "layer_locked", "\(locks)")
            #expect(session.history.undoCount == before + 1 && layer(session, "Layer 1")?.mask != nil, "\(locks)")
        }
        try lock(session, "Layer 1", [])
        try await MCPTestSupport.call("apply_layer_mask", ["layer": "Layer 1"], in: workspace)
        #expect(session.history.undoCount == before + 2 && layer(session, "Layer 1")?.mask == nil)
    }

    /// Applying a mask to a text layer turns it into pixels, which Lock Pixels forbids (rasterize_layer refuses the
    /// same layer): the text must stay live, and a pixel lock on its folder holds it the same way.
    @Test func applyLayerMaskLeavesAPixelLockedTextLayerLive() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        session.beginText(at: CGPoint(x: 4, y: 4), newLayer: true)
        var draft = try #require(session.textDraft)
        draft.style.content = "Hi"
        #expect(session.applyText(draft))
        let id = try #require(session.activeLayerID)
        try await MCPTestSupport.call("add_layer_mask", ["layer": .string(id.uuidString)], in: workspace)
        try await MCPTestSupport.call("set_layer_locks", ["layer": .string(id.uuidString), "pixels": true], in: workspace)
        let refused = try await MCPTestSupport.call("apply_layer_mask", ["layer": .string(id.uuidString)], in: workspace,
                                                    expectError: "precondition_failed")
        #expect(guardName(refused) == "layer_locked")
        let kept = try #require(session.document?.layers.first { $0.id == id })
        #expect(kept.text != nil && kept.mask != nil)
    }

    // MARK: copy_layer_mask

    @Test func copyLayerMaskKeepsWhereTheMaskSitsAndAppliesThere() async throws {
        let workspace = try await redWorkspace()
        let session = workspace.current.session
        // The stencil covers the canvas, its mask showing the left half. The photo is 32×32 at x 16…48.
        try await select(0, 0, 32, 32, in: workspace)
        try await MCPTestSupport.call("add_layer_mask", ["layer": "Layer 1", "kind": "from_selection"], in: workspace)
        try await MCPTestSupport.call("rename_layer", ["layer": "Layer 1", "name": "Stencil"], in: workspace)
        let context = try #require(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let blue = try #require(context.makeImage())
        session.insert(ImportedImage(image: blue, thumbnail: blue, name: "Photo"), centeredAt: CGPoint(x: 32, y: 16))
        #expect(layer(session, "Photo")?.transform.origin == CGPoint(x: 16, y: 0))
        try await MCPTestSupport.call("set_layer_visibility", ["layer": "Stencil", "visible": false], in: workspace)

        let before = session.history.undoCount
        let copied = try await MCPTestSupport.call("copy_layer_mask", ["from": "Stencil", "to": "Photo"], in: workspace)
        let photo = try #require(layer(session, "Photo"))
        #expect(photo.mask != nil && layer(session, "Stencil")?.mask != nil && copied["layer_id"]?.stringValue == photo.id.uuidString)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Copy Layer Mask")
        #expect(session.activeLayerID == photo.id && session.isMaskSelected)
        let rendered = try await render(session)
        #expect(try pixel(rendered, x: 24, y: 16) == [0, 0, 255, 255] && alpha(rendered, x: 40, y: 16) == 0)

        // Applied, the mask cuts the photo's own pixels where it sat on the document.
        try await MCPTestSupport.call("apply_layer_mask", ["layer": "Photo"], in: workspace)
        let pixels = try #require(layer(session, "Photo")?.asset?.image)
        #expect(try pixel(pixels, x: 8, y: 16) == [0, 0, 255, 255] && alpha(pixels, x: 24, y: 16) == 0)
        session.undo()

        // A copy replaces a mask the layer has.
        try await MCPTestSupport.call("delete_layer_mask", ["layer": "Photo"], in: workspace)
        try await MCPTestSupport.call("add_layer_mask", ["layer": "Photo", "kind": "hide_all"], in: workspace)
        let replaced = try await MCPTestSupport.call("copy_layer_mask", ["from": "Stencil", "to": "Photo"], in: workspace)
        #expect(session.history.undoName == "Replace Layer Mask" && replaced["replaced"] == .bool(true))
        #expect(try alpha(try await render(session), x: 24, y: 16) == 255)

        let count = session.history.undoCount
        try await MCPTestSupport.call("copy_layer_mask", ["from": "Photo", "to": "Photo"], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("add_group", ["name": "Folder"], in: workspace)
        var result = try await MCPTestSupport.call("copy_layer_mask", ["from": "Stencil", "to": "Folder"], in: workspace,
                                                   expectError: "precondition_failed")
        #expect(guardName(result) == "not_folder")
        try await MCPTestSupport.call("delete_layer_mask", ["layer": "Photo"], in: workspace)
        result = try await MCPTestSupport.call("copy_layer_mask", ["from": "Photo", "to": "Stencil"], in: workspace,
                                               expectError: "precondition_failed")
        #expect(guardName(result) == "has_mask")
        try lock(session, "Photo", .all)
        result = try await MCPTestSupport.call("copy_layer_mask", ["from": "Stencil", "to": "Photo"], in: workspace,
                                               expectError: "precondition_failed")
        #expect(guardName(result) == "layer_locked")
        #expect(session.history.undoCount == count + 2) // The folder and the deleted mask.
    }
}
