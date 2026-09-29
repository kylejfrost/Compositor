import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import MCP
@testable import Compositor

/// The lock rulings the layer tools share: a folder under Lock All takes no new layers (tools that make one put it
/// above the outermost such folder, as Photoshop does) and keeps the locks of what is inside it; deleting a clip base
/// checks the layers it would bake; refused merges and copies leave the layer selection alone; and structural edits
/// close an opacity edit the app left open, so each is its own undo step.
@MainActor struct MCPLockPolicyTests {
    // MARK: Helpers

    private func solid(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    @discardableResult
    private func addLayer(_ session: EditorSession, _ name: String, size: CGSize = CGSize(width: 16, height: 16)) throws -> UUID {
        let image = try solid(width: Int(size.width), height: Int(size.height))
        session.insert(ImportedImage(image: image, thumbnail: image, name: name))
        let id = try #require(session.activeLayerID)
        session.renameLayer(id, to: name)
        return id
    }

    @discardableResult
    private func group(_ session: EditorSession, _ ids: Set<UUID>, name: String) throws -> UUID {
        session.selectLayers(ids, primary: ids.first)
        session.groupSelectedLayers()
        let folder = try #require(session.activeLayerID)
        session.renameLayer(folder, to: name)
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

    /// Base at the top level, then Outer (Lock All) holding Inner holding Child.
    private func lockedTree() throws -> (workspace: ProjectWorkspace, session: EditorSession, outer: UUID, inner: UUID, child: UUID) {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        try addLayer(session, "Base")
        let child = try addLayer(session, "Child")
        let inner = try group(session, [child], name: "Inner")
        let outer = try group(session, [inner], name: "Outer")
        try setLocks(session, outer, [.all])
        return (workspace, session, outer, inner, child)
    }

    private func pngFile() throws -> URL {
        let url = MCPTestSupport.tempFile("layer.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try solid(width: 4, height: 4), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// The ids of the top-level layers, bottom to top.
    private func roots(_ session: EditorSession) -> [UUID] {
        (session.document?.layers ?? []).filter { $0.parentID == nil }.map(\.id)
    }

    // MARK: Lock-All folders take no new layers

    @Test func layerCreatorsPutNewLayersAboveTheOutermostLockAllFolder() async throws {
        let (workspace, session, outer, inner, child) = try lockedTree()
        let png = try pngFile()
        let pasted = try solid(width: 4, height: 4)
        let childID = Value.string(child.uuidString)
        let creators: [(String, [String: Value])] = [
            ("add_blank_layer", [:]),
            ("add_group", [:]),
            ("add_image_layer", ["path": .string(png.path)]),
            ("duplicate_layer", ["layer": childID]),
            ("layer_via_copy", ["layer": childID]),
            ("add_adjustment_layer", ["kind": "invert"]),
            ("paste_pixels", [:]),
            ("add_text_layer", ["text": "Title", "x": 2, "y": 2]),
            ("add_shape", ["kind": "rectangle", "rect": ["x": 2, "y": 2, "width": 8, "height": 8]]),
            ("place_smart_object", ["path": .string(png.path)]),
        ]
        for (tool, args) in creators {
            session.selectLayer(child)
            if tool == "paste_pixels" {
                session.pasteboard = TestPasteboards.unique()
                session.pixelClipboard = PixelClipboard(image: pasted, origin: .zero, changeCount: session.pasteboard.changeCount)
            }
            let undoCount = session.history.undoCount
            let result = try await MCPTestSupport.call(tool, args, in: workspace)
            let added = try #require(session.activeLayerID)
            #expect(added != child, "\(tool)")
            #expect(try layer(added, in: session).parentID == nil, "\(tool): \(result)")
            let top = roots(session)
            #expect(top.firstIndex(of: added) == top.firstIndex(of: outer).map { $0 + 1 }, "\(tool)")
            #expect(session.history.undoCount == undoCount + 1, "\(tool) made \(session.history.undoCount - undoCount) steps")
        }
        #expect(session.descendantIDs(of: outer) == [inner, child])

        // With the folder itself active, a new layer would go to the top of it: it goes above it instead.
        session.selectLayer(outer)
        try await MCPTestSupport.call("add_blank_layer", ["name": "Above"], in: workspace)
        let above = try #require(session.activeLayerID)
        #expect(try layer(above, in: session).parentID == nil)
        #expect(roots(session).firstIndex(of: above) == roots(session).firstIndex(of: outer).map { $0 + 1 })

        // Asked for a place inside it, as place_layer is, the call is refused.
        let before = try #require(session.document)
        for args: [String: Value] in [["parent": "Outer"], ["above": "Outer/Inner/Child"], ["parent": "Outer/Inner"]] {
            let refused = try await MCPTestSupport.call("add_blank_layer", args, in: workspace, expectError: "precondition_failed")
            #expect(error(refused)["guard"]?.stringValue == "layer_locked", "\(args): \(refused)")
            #expect(error(refused)["details"]?.objectValue?["locked_by_id"]?.stringValue == outer.uuidString, "\(args): \(refused)")
        }
        #expect(session.document == before)

        // A folder locked short of Lock All takes new layers as before.
        try setLocks(session, outer, [.pixels, .position])
        session.selectLayer(child)
        try await MCPTestSupport.call("add_blank_layer", ["name": "Inside"], in: workspace)
        #expect(try layer(#require(session.activeLayerID), in: session).parentID == inner)
    }

    @Test func aLayerInsideALockAllFolderKeepsItsLocks() async throws {
        let (workspace, session, outer, inner, child) = try lockedTree()
        let undoCount = session.history.undoCount
        for target in [child, inner] {
            let refused = try await MCPTestSupport.call("set_layer_locks", ["layer": .string(target.uuidString), "pixels": true],
                                                        in: workspace, expectError: "precondition_failed")
            #expect(error(refused)["guard"]?.stringValue == "locked_by_folder", "\(refused)")
            let details = error(refused)["details"]?.objectValue
            #expect(details?["locked_by_id"]?.stringValue == outer.uuidString)
            #expect(details?["layer_id"]?.stringValue == target.uuidString)
            #expect(error(refused)["hint"]?.stringValue?.contains("'Outer'") == true, "\(refused)")
            #expect(try layer(target, in: session).locks.isEmpty)
        }
        #expect(session.history.undoCount == undoCount)

        // The folder's own locks can change, and once it is unlocked so can those of what is inside it.
        try await MCPTestSupport.call("set_layer_locks", ["layer": "Outer", "all": false], in: workspace)
        try await MCPTestSupport.call("set_layer_locks", ["layer": .string(child.uuidString), "pixels": true], in: workspace)
        #expect(try layer(child, in: session).locks == [.pixels])
    }

    // MARK: Guards before changes

    @Test func deletingAClipBaseChecksTheLocksOfTheLayersItBakes() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        let session = workspace.current.session
        try addLayer(session, "Base")
        let top = try addLayer(session, "Top")
        session.toggleClippingMask(top)
        #expect(try layer(top, in: session).maskSourceID != nil)
        try setLocks(session, top, [.pixels])
        let document = try #require(session.document)
        let undoCount = session.history.undoCount

        let refused = try await MCPTestSupport.call("delete_layers", ["layers": ["Base"]], in: workspace, expectError: "precondition_failed")
        #expect(error(refused)["guard"]?.stringValue == "layer_locked")
        #expect(error(refused)["details"]?.objectValue?["layer_id"]?.stringValue == top.uuidString)
        #expect(session.document == document && session.history.undoCount == undoCount)

        // A position lock doesn't keep the clip from being baked in.
        try setLocks(session, top, [.position])
        let deleted = try await MCPTestSupport.call("delete_layers", ["layers": ["Base"]], in: workspace)
        #expect(deleted["baked_layer_ids"] == .array([.string(top.uuidString)]))
    }

    @Test func refusedMergesAndCopiesLeaveTheLayerSelectionAsItWas() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        let session = workspace.current.session
        try addLayer(session, "A")
        let b = try addLayer(session, "B")
        try setLocks(session, b, [.pixels])
        try await MCPTestSupport.call("add_blank_layer", ["name": "Empty"], in: workspace)
        let c = try addLayer(session, "C")
        try await MCPTestSupport.call("select_layers", ["layers": ["C"]], in: workspace)

        let locked = try await MCPTestSupport.call("merge_layers", ["layers": ["B"]], in: workspace, expectError: "precondition_failed")
        #expect(error(locked)["guard"]?.stringValue == "layer_locked")
        #expect(session.activeLayerID == c && session.selectedLayerIDs == [c])
        // "Layer 1", the document's first layer, is at the bottom: nothing is below it to merge onto.
        let nothing = try await MCPTestSupport.call("merge_layers", ["layers": ["Layer 1"]], in: workspace, expectError: "precondition_failed")
        #expect(error(nothing)["guard"]?.stringValue == "can_merge_layers")
        #expect(session.activeLayerID == c && session.selectedLayerIDs == [c])

        try await MCPTestSupport.call("select_rect", ["rect": ["x": 0, "y": 0, "width": 4, "height": 4]], in: workspace)
        let empty = try await MCPTestSupport.call("layer_via_copy", ["layer": "Empty"], in: workspace, expectError: "precondition_failed")
        #expect(error(empty)["guard"]?.stringValue == "can_copy_pixels")
        #expect(session.activeLayerID == c && session.selectedLayerIDs == [c])
    }

    @Test func structuralEditsAndCreatorsCloseAnOpenOpacityEditFirst() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        let plain = try addLayer(session, "Plain")
        let inside = try addLayer(session, "Inside")
        try group(session, [inside], name: "Folder")
        session.selectLayer(plain)
        session.selectTool(.shape)
        session.beginShape(at: CGPoint(x: 2, y: 2))
        session.dragShape(to: CGPoint(x: 20, y: 20), square: false, fromCenter: false)
        session.finishShape()
        let shape = try #require(session.activeLayerID)
        #expect(try layer(shape, in: session).liveShape != nil)
        session.selectTool(.move)

        // The creators too: each settles the drag before its own step, rather than folding into "Layer Opacity".
        let plainID = Value.string(plain.uuidString)
        let png = try pngFile()
        let calls: [(String, [String: Value], String)] = [
            ("rasterize_layer", ["layer": .string(shape.uuidString)], "Rasterize Layer"),
            ("ungroup_layer", ["layer": "Folder"], "Ungroup"),
            ("paste_pixels", [:], "Paste"),
            ("layer_via_copy", ["layer": plainID], "Layer via Copy"),
            ("add_blank_layer", [:], "New Blank Layer"),
            ("add_image_layer", ["path": .string(png.path)], "Import Image"),
            ("duplicate_layer", ["layer": plainID], "Duplicate Layer"),
            ("set_layer_locks", ["layer": plainID, "pixels": true], "Lock Layer"),
            ("group_layers", ["layers": [plainID]], "Group Layers"),
            ("add_text_layer", ["text": "Title", "x": 2, "y": 2], "New Text Layer"),
            ("add_shape", ["kind": "rectangle", "rect": ["x": 2, "y": 2, "width": 8, "height": 8]], "Rectangle"),
            ("place_smart_object", ["path": .string(png.path)], "Place Smart Object"),
        ]
        for (index, (tool, args, step)) in calls.enumerated() {
            session.selectLayer(plain)
            // Layer via Copy copies what is selected of the layer; the others run without a selection.
            session.document?.selection = tool == "layer_via_copy"
                ? DocumentSelection(path: CGPath(rect: CGRect(x: 10, y: 10, width: 4, height: 4), transform: nil)) : nil
            if tool == "paste_pixels" {
                session.pasteboard = TestPasteboards.unique()
                session.pixelClipboard = PixelClipboard(image: try solid(width: 4, height: 4), origin: .zero,
                                                        changeCount: session.pasteboard.changeCount)
            }
            session.beginOpacityEdit()
            // A different opacity each time (below 1, where it would stop changing), so each drag records a step.
            session.setLayerOpacity(0.05 * Double(index + 1))
            #expect(session.history.isEditing)
            try await MCPTestSupport.call(tool, args, in: workspace)
            #expect(session.opacityEditLayerID == nil, "\(tool)")
            #expect(!session.history.isEditing, "\(tool)")
            #expect(Array(session.history.undoNames.prefix(2)) == [step, "Layer Opacity"], "\(tool): \(session.history.undoNames)")
        }
    }
}
