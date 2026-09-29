import CoreGraphics
import Foundation
import Testing
import MCP
@testable import Compositor

/// Follow-ups to the one lock model (Task 2.12's review): mask edits are held only by Lock All, as the app's and
/// Photoshop's are; mask switches respect Lock All; placeholders are named before a missing raster; a baked clip
/// leaves text and shape layers as pixels; the app's effect and adjustment edits refuse Lock All as the tools do; and
/// a refused nudge reports itself so the app, not the session, decides to beep.
@MainActor struct LockFollowUpTests {
    // MARK: Helpers

    private func solid(width: Int, height: Int, gray: CGFloat = 1) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: gray, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    @discardableResult
    private func addLayer(_ session: EditorSession, _ name: String, size: CGSize = CGSize(width: 64, height: 32)) throws -> UUID {
        let image = try solid(width: Int(size.width), height: Int(size.height))
        session.insert(ImportedImage(image: image, thumbnail: image, name: name))
        let id = try #require(session.activeLayerID)
        session.renameLayer(id, to: name)
        return id
    }

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

    private func layer(_ id: UUID, in session: EditorSession) throws -> ImageLayer {
        try #require(session.document?.layers.first { $0.id == id })
    }

    private func error(_ result: [String: Value]) -> [String: Value] { result["error"]?.objectValue ?? [:] }

    private func point(_ x: Double, _ y: Double) -> Value { ["x": .double(x), "y": .double(y)] }

    /// A placeholder as import builds one: hidden, with no pixels, covering the canvas.
    private func placeholder(_ session: EditorSession) -> ImageLayer {
        let layer = ImageLayer(id: UUID(), asset: nil, name: "Kept", isVisible: false,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 64, height: 32)),
                               psdExtras: PSDLayerExtras(importedVisible: true, placeholder: "adjustment:brit"))
        session.document?.layers.append(layer)
        return layer
    }

    // MARK: Masks under Lock Pixels

    /// Photoshop's Lock Pixels leaves a layer's mask editable, and so does the app (`checkUnlocked(_:mask:)`): the mask
    /// tools refuse only Lock All, the layer's own or a folder's. Applying a mask isn't one of them: it rewrites the
    /// layer's own pixels, which the pixel lock holds, as it holds painting them.
    @Test func maskEditsAreHeldOnlyByLockAll() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        let photo = try addLayer(session, "Photo")
        let other = try addLayer(session, "Other")
        session.selectLayer(other)
        session.addLayerMask(revealing: false)
        let folder = try folder(session, holding: [photo])
        try setLocks(session, folder, [.pixels])
        try await MCPTestSupport.call("select_rect", ["rect": ["x": 4, "y": 4, "width": 8, "height": 8]], in: workspace)

        let maskEdits: [(String, [String: Value])] = [
            ("add_layer_mask", ["layer": "Folder/Photo"]),
            ("stroke_path", ["layer": "Folder/Photo", "target": "mask", "points": [point(4, 16), point(60, 16)]]),
            ("fill_selection", ["layer": "Folder/Photo", "target": "mask", "color": "#000000"]),
            ("clear_selection", ["layer": "Folder/Photo", "target": "mask"]),
            ("invert_pixels", ["layer": "Folder/Photo", "target": "mask"]),
            ("draw_gradient", ["layer": "Folder/Photo", "target": "mask", "start": point(0, 0), "end": point(60, 0),
                               "colors": ["from": "#000000", "to": "#ffffff"]]),
            ("set_mask_enabled", ["layer": "Folder/Photo", "enabled": false]),
            ("set_mask_enabled", ["layer": "Folder/Photo", "enabled": true]),
            ("set_mask_linked", ["layer": "Folder/Photo", "linked": false]),
            ("copy_layer_mask", ["from": "Other", "to": "Folder/Photo"]),
            ("delete_layer_mask", ["layer": "Folder/Photo"]),
        ]
        for (tool, args) in maskEdits {
            let result = try await MCPTestSupport.call(tool, args, in: workspace)
            #expect(result["undo"]?.objectValue?["recorded"] == .bool(true), "\(tool): \(result)")
        }
        // Remove Background masks the layer too: whatever else stops it, the pixel lock doesn't.
        let background = await MCPToolRegistry.call("remove_background", ["layer": "Folder/Photo"], workspace: workspace)
        #expect(background.structuredContent?.objectValue?["error"]?.objectValue?["guard"]?.stringValue != "layer_locked")

        // Applying the mask rewrites the layer's pixels, so the folder's pixel lock holds it.
        if try layer(photo, in: session).mask == nil {
            try await MCPTestSupport.call("add_layer_mask", ["layer": "Folder/Photo"], in: workspace)
        }
        let applied = try await MCPTestSupport.call("apply_layer_mask", ["layer": "Folder/Photo"], in: workspace,
                                                    expectError: "precondition_failed")
        #expect(error(applied)["guard"]?.stringValue == "layer_locked", "apply_layer_mask: \(applied)")
        #expect(try layer(photo, in: session).mask != nil)
        try await MCPTestSupport.call("delete_layer_mask", ["layer": "Folder/Photo"], in: workspace)

        // The layer's own pixels stay locked.
        let refused = try await MCPTestSupport.call("stroke_path", ["layer": "Folder/Photo", "points": [point(4, 16), point(60, 16)]],
                                                    in: workspace, expectError: "precondition_failed")
        #expect(error(refused)["guard"]?.stringValue == "layer_locked", "stroke_path: \(refused)")
        try await MCPTestSupport.call("add_layer_mask", ["layer": "Folder/Photo", "kind": "hide_all"], in: workspace)

        // Lock All holds the mask as well.
        try setLocks(session, folder, [.all])
        let document = try #require(session.document)
        let undoCount = session.history.undoCount
        let lockAllRefusals: [(String, [String: Value])] = [
            ("add_layer_mask", ["layer": "Folder/Photo"]),
            ("stroke_path", ["layer": "Folder/Photo", "target": "mask", "points": [point(4, 16), point(60, 16)]]),
            ("fill_selection", ["layer": "Folder/Photo", "target": "mask", "color": "#000000"]),
            ("clear_selection", ["layer": "Folder/Photo", "target": "mask"]),
            ("invert_pixels", ["layer": "Folder/Photo", "target": "mask"]),
            ("draw_gradient", ["layer": "Folder/Photo", "target": "mask", "start": point(0, 0), "end": point(60, 0),
                               "colors": ["from": "#000000", "to": "#ffffff"]]),
            ("set_mask_enabled", ["layer": "Folder/Photo", "enabled": false]),
            ("set_mask_linked", ["layer": "Folder/Photo", "linked": false]),
            ("copy_layer_mask", ["from": "Other", "to": "Folder/Photo"]),
            ("delete_layer_mask", ["layer": "Folder/Photo"]),
            ("apply_layer_mask", ["layer": "Folder/Photo"]),
            ("remove_background", ["layer": "Folder/Photo"]),
        ]
        for (tool, args) in lockAllRefusals {
            let refused = try await MCPTestSupport.call(tool, args, in: workspace, expectError: "precondition_failed")
            #expect(error(refused)["guard"]?.stringValue == "layer_locked", "\(tool): \(refused)")
            #expect(error(refused)["details"]?.objectValue?["locked_by_id"]?.stringValue == folder.uuidString, "\(tool): \(refused)")
        }
        #expect(session.document == document && session.history.undoCount == undoCount)
    }

    @Test func maskSwitchesAreHeldByTheLayersOwnLockAll() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        let photo = try addLayer(session, "Photo")
        session.addLayerMask(revealing: true)
        try setLocks(session, photo, [.all])
        for (tool, args): (String, [String: Value]) in [("set_mask_enabled", ["layer": "Photo", "enabled": false]),
                                                         ("set_mask_linked", ["layer": "Photo", "linked": false])] {
            let refused = try await MCPTestSupport.call(tool, args, in: workspace, expectError: "precondition_failed")
            #expect(error(refused)["guard"]?.stringValue == "layer_locked", "\(tool): \(refused)")
        }
        let mask = try #require(try layer(photo, in: session).mask)
        #expect(mask.isEnabled && mask.isLinked)
    }

    // MARK: Transforms check each layer's contents once

    /// flip_layer, align_layers and distribute_layers check every listed layer and everything inside a listed folder,
    /// with one look at the document's locks per call.
    @Test func transformToolsCheckTheContentsOfEveryListedFolder() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 64)
        let session = workspace.current.session
        let a = try addLayer(session, "A", size: CGSize(width: 8, height: 8))
        let b = try addLayer(session, "B", size: CGSize(width: 8, height: 8))
        try addLayer(session, "C", size: CGSize(width: 8, height: 8))
        try addLayer(session, "D", size: CGSize(width: 8, height: 8))
        _ = try folder(session, holding: [a, b])
        try setLocks(session, b, [.position])
        let document = try #require(session.document)
        let refusals: [(String, [String: Value])] = [
            ("flip_layer", ["layers": ["C", "Folder"], "axis": "horizontal"]),
            ("align_layers", ["layers": ["C", "Folder"], "edge": "left", "to": "canvas"]),
            ("distribute_layers", ["layers": ["C", "Folder", "D"], "axis": "horizontal", "spacing": 2]),
        ]
        for (tool, args) in refusals {
            let refused = try await MCPTestSupport.call(tool, args, in: workspace, expectError: "precondition_failed")
            #expect(error(refused)["guard"]?.stringValue == "layer_locked", "\(tool): \(refused)")
            #expect(error(refused)["details"]?.objectValue?["layer_id"]?.stringValue == b.uuidString, "\(tool): \(refused)")
        }
        #expect(session.document == document)
        try setLocks(session, b, [])
        try await MCPTestSupport.call("align_layers", ["layers": ["C", "Folder"], "edge": "left", "to": "canvas"], in: workspace)
    }

    // MARK: Placeholders before a missing raster

    @Test func readingAPlaceholdersPixelsNamesThePlaceholder() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        let kept = placeholder(session)
        let id = Value.string(kept.id.uuidString)
        for (tool, args): (String, [String: Value]) in [("get_layer_pixels", ["layer": id]), ("copy_pixels", ["layer": id]),
                                                         ("load_layer_selection", ["layer": id])] {
            let refused = try await MCPTestSupport.call(tool, args, in: workspace, expectError: "precondition_failed")
            #expect(error(refused)["guard"]?.stringValue == "placeholder", "\(tool): \(refused)")
        }
    }

    /// A placeholder keeps its Photoshop mask (every adjustment layer has one), and reading or loading that mask
    /// still works: only the pixels it doesn't have are refused.
    @Test func aPlaceholdersMaskCanStillBeReadAndLoaded() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        let kept = placeholder(session)
        let index = try #require(session.document?.layers.firstIndex { $0.id == kept.id })
        // Black on its left half, white (revealed) on its right.
        let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 64,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 32, y: 0, width: 32, height: 32))
        session.document?.layers[index].mask = LayerMask(asset: try LayerMask.asset(from: try #require(context.makeImage())))
        let id = Value.string(kept.id.uuidString)

        let read = try await MCPTestSupport.call("get_layer_pixels", ["layer": id, "target": "mask"], in: workspace)
        #expect(read["target"] == "mask" && read["pixel_width"] == .int(64) && read["pixel_height"] == .int(32), "\(read)")
        let loaded = try await MCPTestSupport.call("load_layer_selection", ["layer": id, "source": "mask"], in: workspace)
        let bounds = try #require(loaded["selection"]?.objectValue?["bounds"].flatMap(MCPValues.rect(from:)))
        #expect(bounds == CGRect(x: 32, y: 0, width: 32, height: 32))

        for (tool, args): (String, [String: Value]) in [("get_layer_pixels", ["layer": id]), ("load_layer_selection", ["layer": id])] {
            let refused = try await MCPTestSupport.call(tool, args, in: workspace, expectError: "precondition_failed")
            #expect(error(refused)["guard"]?.stringValue == "placeholder", "\(tool): \(refused)")
        }
    }

    // MARK: Baking a clip

    /// Deleting a clip base bakes what was clipped to it into plain pixels, and copying a clipped layer to another
    /// document does too: a text or shape layer can't redraw itself from pixels it no longer matches.
    @Test func bakingAClipTurnsTextAndShapeLayersIntoPixels() async throws {
        let workspace = MCPTestSupport.workspace(width: 200, height: 100)
        let session = workspace.current.session
        try addLayer(session, "Base", size: CGSize(width: 200, height: 100))
        session.beginText(at: CGPoint(x: 10, y: 10), newLayer: true)
        var draft = try #require(session.textDraft)
        draft.style.content = "Hi"
        draft.style.fontSize = 40
        #expect(session.applyText(draft))
        let text = try #require(session.activeLayerID)
        session.toggleClippingMask(text)
        session.selectTool(.shape)
        session.beginShape(at: CGPoint(x: 100, y: 10))
        session.dragShape(to: CGPoint(x: 150, y: 60), square: false, fromCenter: false)
        session.finishShape()
        session.selectTool(.move)
        let shape = try #require(session.activeLayerID)
        session.toggleClippingMask(shape)
        #expect(try layer(text, in: session).liveText != nil && layer(shape, in: session).liveShape != nil)
        #expect(try layer(shape, in: session).maskSourceID != nil && layer(text, in: session).maskSourceID != nil)

        // Copied to another document, the text layer arrives as its clipped pixels.
        let target = workspace.addTab()
        target.session.createDocument(width: 64, height: 64)
        await workspace.copyLayer(text, into: target.id)
        let copied = try #require(target.session.document?.layers.last)
        #expect(copied.maskSourceID == nil && copied.text == nil && copied.liveText == nil)
        #expect(try layer(text, in: session).liveText != nil)

        workspace.select(workspace.tabs[0].id)
        let deleted = try await MCPTestSupport.call("delete_layers", ["layers": ["Base"]], in: workspace)
        #expect(deleted["baked_layer_ids"]?.arrayValue?.count == 2)
        for id in [text, shape] {
            let baked = try layer(id, in: session)
            #expect(baked.maskSourceID == nil && baked.text == nil && baked.shape == nil && baked.asset != nil)
        }
    }

    // MARK: The app

    @Test func theAppsEffectAndAdjustmentEditsRefuseLockAll() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        let photo = try addLayer(session, "Photo")
        session.addAdjustment(.levels)
        session.adjustmentEditingID = nil
        let levels = try #require(session.activeLayerID)
        let folder = try folder(session, holding: [photo, levels])
        try setLocks(session, folder, [.all])
        let undoCount = session.history.undoCount

        var effects = LayerEffects()
        effects.stroke = StrokeEffect(size: 3)
        session.setEffects(effects, on: photo)
        #expect(try layer(photo, in: session).effects == nil)
        session.selectLayer(photo)
        #expect(!session.canEditEffects)
        session.addEffect(.shadow)
        #expect(try layer(photo, in: session).effects == nil)

        var adjusted = try #require(try layer(levels, in: session).adjustment)
        adjusted.levels.current.black = 40
        session.setAdjustment(levels, value: adjusted)
        #expect(try layer(levels, in: session).adjustment?.levels.current.black != 40)
        // Its settings panel doesn't open, and says why.
        session.brushError = nil
        session.adjustmentEditingID = levels
        await session.beginAdjustmentEditing(levels)
        #expect(session.adjustmentEditingID == nil && session.adjustmentOriginal == nil && session.levels == nil)
        #expect(session.brushError?.contains("Folder") == true)
        #expect(!session.history.isEditing && session.history.undoCount == undoCount)

        // A pixel lock holds neither, as in Photoshop.
        try setLocks(session, folder, [.pixels])
        session.setEffects(effects, on: photo)
        session.setAdjustment(levels, value: adjusted)
        #expect(try layer(photo, in: session).effects == effects)
        #expect(try layer(levels, in: session).adjustment == adjusted)
    }

    @Test func aRefusedNudgeSaysSoWithoutBeepingItself() throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        let photo = try addLayer(session, "Photo", size: CGSize(width: 8, height: 8))
        try setLocks(session, photo, [.position])
        #expect(session.nudgeLayer(dx: 2, dy: 0) == false)
        #expect(session.isTransformPositionLocked)
        try setLocks(session, photo, [])
        #expect(session.nudgeLayer(dx: 2, dy: 0))
        #expect(try layer(photo, in: session).transform.origin.x == 30)
    }
}
