import CoreGraphics
import Foundation
import ImageIO
import Testing
import MCP
@testable import Compositor

/// Document tools: open_document re-checks its guards once the file is read, names can't be blank, revert says how to
/// clear a pending edit, and opening in the background into the lone empty tab reports where the document went.
@MainActor struct MCPDocumentConsistencyTests {
    private func error(_ result: [String: Value]) -> [String: Value] { result["error"]?.objectValue ?? [:] }

    private func pngFile(_ name: String = "open.png") throws -> URL {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let url = MCPTestSupport.tempFile(name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// Runs `change` on the main actor once the call that is running next first waits (for its file read), and
    /// returns the task so the test can wait for it.
    private func whileTheNextCallWaits(_ change: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in change() }
    }

    // MARK: open_document

    @Test func openDocumentChecksTheTabCapAgainOnceTheFileIsRead() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        while workspace.tabs.count < MCPSettings.maxTabs - 1 { workspace.addTab(reuseEmpty: false) }
        let url = try pngFile()
        // The app opens a tab while the file is being read, filling the last place.
        let app = whileTheNextCallWaits { workspace.addTab(reuseEmpty: false) }
        let refused = try await MCPTestSupport.call("open_document", ["path": .string(url.path), "select": false], in: workspace,
                                                    expectError: "precondition_failed")
        await app.value
        #expect(error(refused)["guard"]?.stringValue == "max_tabs", "\(refused)")
        #expect(workspace.tabs.count == MCPSettings.maxTabs)
        #expect(workspace.tab(showing: url) == nil)
    }

    @Test func openDocumentChecksItCanSwitchAgainOnceTheFileIsRead() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        let session = workspace.current.session
        let current = workspace.current
        let url = try pngFile()
        // A layer rename starts in the app while the file is being read: the tab can't be left now.
        let app = whileTheNextCallWaits { session.renamingLayerID = session.activeLayerID }
        let refused = try await MCPTestSupport.call("open_document", ["path": .string(url.path)], in: workspace, expectError: "busy")
        await app.value
        #expect(error(refused)["guard"]?.stringValue == "can_switch", "\(refused)")
        #expect(workspace.tabs.count == 1 && workspace.current === current)
        #expect(session.renamingLayerID != nil)
    }

    @Test func openingInTheBackgroundIntoTheLoneEmptyTabReportsItCurrent() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        try await MCPTestSupport.call("close_document", ["discard_changes": true], in: workspace)
        #expect(workspace.tabs.count == 1 && workspace.current.session.document == nil)
        let url = try pngFile()
        // The lone empty tab takes the document, so it is the current one, whatever select asked.
        let opened = try await MCPTestSupport.call("open_document", ["path": .string(url.path), "select": false], in: workspace)
        #expect(opened["current"] == .bool(true) && opened["tab_index"]?.intValue == 0)
        #expect(workspace.tabs.count == 1 && workspace.current.session.document != nil)
        #expect(opened["tab_id"]?.stringValue == workspace.current.id.uuidString)

        // With a document there, it opens behind it.
        let other = try pngFile("other.png")
        let behind = try await MCPTestSupport.call("open_document", ["path": .string(other.path), "select": false], in: workspace)
        #expect(behind["current"] == .bool(false) && behind["tab_index"]?.intValue == 1)
        #expect(workspace.tabs.count == 2 && workspace.current.id.uuidString == opened["tab_id"]?.stringValue)
    }

    // MARK: Names

    @Test func blankDocumentNamesAreRefused() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        for name in ["", "   ", " \t\n"] {
            try await MCPTestSupport.call("new_document", ["width": 8, "height": 8, "name": .string(name)], in: workspace,
                                          expectError: "invalid_argument")
            try await MCPTestSupport.call("duplicate_document", ["name": .string(name)], in: workspace, expectError: "invalid_argument")
        }
        #expect(workspace.tabs.count == 1)
        let named = try await MCPTestSupport.call("new_document", ["width": 8, "height": 8, "name": " Poster "], in: workspace)
        #expect(named["title"]?.stringValue == " Poster ")
    }

    // MARK: Switching tabs

    /// Switching tabs commits a free transform in progress (`ProjectWorkspace.select`, `newCanvas`), so an agent's
    /// select_document, new_document, duplicate_document or open_document would commit the owner's half-finished
    /// transform behind their back. They're refused instead (guard can_switch), pointing at settle_pending_edits, as
    /// the canvas tools refuse; a crop frame the same way.
    @Test func tabSwitchingToolsLeaveTheOwnersTransformAlone() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        try await MCPTestSupport.call("new_document", ["width": 16, "height": 16], in: workspace)
        try await MCPTestSupport.call("fill_selection", ["layer": "Layer 1", "color": "#ff0000"], in: workspace)
        let session = workspace.current.session
        let png = try pngFile()
        let tabs = workspace.tabs.count
        let calls: [(String, [String: Value])] = [
            ("select_document", ["document": 0]), ("new_document", ["width": 8, "height": 8]),
            ("duplicate_document", ["document": 0]), ("open_document", ["path": .string(png.path)]),
        ]
        for pending in ["transform", "crop"] {
            if pending == "transform" { session.beginTransform() } else { session.cropRect = CGRect(x: 2, y: 2, width: 8, height: 8) }
            try #require(session.transformEdit != nil || session.cropRect != nil)
            let undoCount = session.history.undoCount
            for (tool, args) in calls {
                let refused = try await MCPTestSupport.call(tool, args, in: workspace, expectError: "precondition_failed")
                #expect(error(refused)["guard"]?.stringValue == "can_switch", "\(pending) \(tool): \(refused)")
                #expect(error(refused)["hint"]?.stringValue?.contains("settle_pending_edits") == true, "\(pending) \(tool): \(refused)")
                #expect(workspace.tabs.count == tabs && workspace.current.session === session, "\(pending) \(tool)")
                #expect((pending == "transform" ? session.transformEdit != nil : session.cropRect != nil), "\(pending) \(tool) settled it")
            }
            #expect(session.history.undoCount == undoCount)
            session.cancelTransform()
            session.cancelCrop()
        }
        try await MCPTestSupport.call("select_document", ["document": 0], in: workspace)
        #expect(workspace.current.session !== session)
    }

    // MARK: Saving

    /// An edit the owner has open in the app is half-done in the document: a floating selection transform has cut the
    /// pixels out onto a layer of its own, an opacity drag holds an in-between value. Saving then would write that
    /// and mark the document saved, so Escape would leave a file that differs from a document that reads as saved.
    /// Saves are refused instead, pointing at settle_pending_edits; a batch's own open edit doesn't count.
    @Test func savingIsRefusedWhileTheAppHoldsAnEditHalfDone() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        let session = workspace.current.session
        let url = MCPTestSupport.tempFile("Half.comp")
        let copy = MCPTestSupport.tempFile("Copy.comp")
        try await MCPTestSupport.call("fill_selection", ["layer": "Layer 1", "color": "#ff0000"], in: workspace)
        try await MCPTestSupport.call("select_rect", ["rect": ["x": 2, "y": 2, "width": 4, "height": 4]], in: workspace)
        try await MCPTestSupport.call("save_document_as", ["path": .string(url.path)], in: workspace)
        let manifest = url.appendingPathComponent("manifest.json")
        let saved = try Data(contentsOf: manifest)

        await session.beginSelectionTransform()
        #expect(session.transformEdit?.floating != nil)
        for (tool, args) in [("save_document", [String: Value]()),
                             ("save_document_as", ["path": .string(copy.path), "set_as_current": false])] {
            let refused = try await MCPTestSupport.call(tool, args, in: workspace, expectError: "precondition_failed")
            #expect(error(refused)["guard"]?.stringValue == "can_edit_layers", "\(tool): \(refused)")
            #expect(error(refused)["hint"]?.stringValue?.contains("settle_pending_edits") == true, "\(tool): \(refused)")
        }
        session.cancelTransform()
        #expect(try Data(contentsOf: manifest) == saved && !session.isModified)
        #expect(!FileManager.default.fileExists(atPath: copy.path))

        session.beginOpacityEdit()
        session.setLayerOpacity(0.5)
        let dragging = try await MCPTestSupport.call("save_document", in: workspace, expectError: "precondition_failed")
        #expect(error(dragging)["guard"]?.stringValue == "can_edit_layers", "\(dragging)")
        session.finishOpacityEdit()
        #expect(try Data(contentsOf: manifest) == saved)

        // A batch's steps run inside its own open edit, which isn't the app's.
        try await MCPTestSupport.call("run_batch", ["steps": [["tool": "add_blank_layer"], ["tool": "save_document"]]], in: workspace)
        #expect(try Data(contentsOf: manifest) != saved && !session.isModified)
    }

    // MARK: revert_document

    @Test func revertingDuringAPendingEditPointsAtSettlePendingEdits() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        let session = workspace.current.session
        let url = MCPTestSupport.tempFile("Revert.comp")
        try await MCPTestSupport.call("save_document_as", ["path": .string(url.path)], in: workspace)
        session.renamingLayerID = session.activeLayerID
        let refused = try await MCPTestSupport.call("revert_document", ["discard_changes": true], in: workspace,
                                                    expectError: "precondition_failed")
        #expect(error(refused)["guard"]?.stringValue == "can_edit_layers")
        #expect(error(refused)["hint"]?.stringValue?.contains("settle_pending_edits") == true, "\(refused)")
    }
}
