import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import MCP
@testable import Compositor

/// Undo, redo and run_batch while the app holds an edit open, and batches of the paint, mask, effect and adjustment
/// tools: one undo step, and a rollback that puts back the document, the layer selection and the mask target.
@MainActor struct MCPHistoryConsistencyTests {
    private func step(_ tool: String, _ arguments: [String: Value] = [:]) -> Value {
        .object(["tool": .string(tool), "arguments": .object(arguments)])
    }

    private func error(_ result: [String: Value]) -> [String: Value] { result["error"]?.objectValue ?? [:] }

    private func point(_ x: Double, _ y: Double) -> Value { ["x": .double(x), "y": .double(y)] }

    private func solid(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    @discardableResult
    private func addLayer(_ session: EditorSession, _ name: String) throws -> UUID {
        let image = try solid(width: 32, height: 32)
        session.insert(ImportedImage(image: image, thumbnail: image, name: name))
        let id = try #require(session.activeLayerID)
        session.renameLayer(id, to: name)
        return id
    }

    // MARK: Undo and redo

    @Test func undoAndRedoRefuseWhileTheAppHoldsAnEditOpen() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        try await MCPTestSupport.call("add_blank_layer", ["name": "A"], in: workspace)
        try await MCPTestSupport.call("undo", in: workspace)
        // An opacity drag in the app keeps an edit open until the mouse goes up.
        session.beginOpacityEdit()
        session.setLayerOpacity(0.5)
        for tool in ["undo", "redo"] {
            let refused = try await MCPTestSupport.call(tool, in: workspace, expectError: "precondition_failed")
            #expect(error(refused)["guard"]?.stringValue == "history_busy", "\(tool): \(refused)")
            #expect(error(refused)["hint"]?.stringValue?.contains("settle_pending_edits") == true, "\(tool): \(refused)")
        }
        session.finishOpacityEdit()
        let undone = try await MCPTestSupport.call("undo", in: workspace)
        #expect(undone["undone"]?.intValue == 1 && session.history.undoName != "Layer Opacity")
    }

    /// A gradient waiting to be committed, a crop frame or a dialog is the owner's edit in progress: undo would throw
    /// the pending gradient away (as the app's first ⌘Z does) and report nothing undone, leaving the agent's own step,
    /// or change the layer under a dialog so its OK is dropped. Undo, redo and run_batch refuse (history_busy) instead.
    @Test func undoRedoAndBatchesRefuseWhileAnEditIsPendingInTheApp() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 64)
        let session = workspace.current.session
        try await MCPTestSupport.call("add_blank_layer", ["name": "Agent"], in: workspace)
        try await MCPTestSupport.call("undo", in: workspace)
        try await MCPTestSupport.call("redo", in: workspace)
        let entries = session.history.undoCount
        session.tool = .gradient
        session.beginGradient(at: CGPoint(x: 1, y: 1))
        session.moveGradient(end: CGPoint(x: 60, y: 60))
        session.endGradientDrag()
        #expect(session.gradientEdit != nil)
        for (name, pending) in [("gradient", { session.gradientEdit != nil }), ("crop", { session.cropRect != nil })] {
            for tool in ["undo", "redo"] {
                let refused = try await MCPTestSupport.call(tool, in: workspace, expectError: "precondition_failed")
                #expect(error(refused)["guard"]?.stringValue == "history_busy", "\(name) \(tool): \(refused)")
                #expect(error(refused)["hint"]?.stringValue?.contains("settle_pending_edits") == true, "\(name) \(tool): \(refused)")
            }
            let batch = try await MCPTestSupport.call("run_batch", ["steps": [step("add_blank_layer")]], in: workspace,
                                                      expectError: "precondition_failed")
            #expect(error(batch)["guard"]?.stringValue == "can_use_history", "\(name): \(batch)")
            #expect(pending() && session.history.undoCount == entries, "\(name)")
            if name == "gradient" {
                session.cancelGradient()
                session.cropRect = CGRect(x: 4, y: 4, width: 20, height: 20)
            }
        }
        session.cancelCrop()
        let undone = try await MCPTestSupport.call("undo", in: workspace)
        #expect(undone["undone"]?.intValue == 1 && session.history.undoCount == entries - 1)
    }

    // MARK: Batches of paint, mask, effect and adjustment tools

    /// Two layers with pixels, A with a mask; A and B selected, A active with its mask targeted, and a selection.
    private func paintedDocument() async throws -> (ProjectWorkspace, EditorSession, a: UUID, b: UUID) {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        let a = try addLayer(session, "A")
        session.addLayerMask(revealing: true)
        let b = try addLayer(session, "B")
        try await MCPTestSupport.call("select_rect", ["rect": ["x": 4, "y": 4, "width": 12, "height": 12]], in: workspace)
        try await MCPTestSupport.call("select_layers", ["layers": ["A", "B"], "active": "A", "target": "mask"], in: workspace)
        #expect(session.selectedLayerIDs == [a, b] && session.activeLayerID == a && session.isMaskSelected)
        return (workspace, session, a, b)
    }

    private var paintSteps: [Value] {
        [
            step("stroke_path", ["layer": "B", "points": [point(2, 2), point(28, 28)], "brush": ["diameter": 4, "color": "#ff0000"]]),
            step("fill_selection", ["layer": "B", "color": "#0000ff"]),
            step("set_layer_effects", ["layer": "B", "effects": ["stroke": ["size": 2, "color": "#000000"]]]),
            step("add_adjustment_layer", ["kind": "invert"]),
            step("add_layer_mask", ["layer": "B", "kind": "hide_selection"]),
        ]
    }

    @Test func aBatchOfPaintMaskEffectAndAdjustmentToolsIsOneUndoStep() async throws {
        let (workspace, session, _, _) = try await paintedDocument()
        let document = try #require(session.document)
        let undoCount = session.history.undoCount
        let result = try await MCPTestSupport.call("run_batch", ["steps": .array(paintSteps), "name": "Paint Batch"], in: workspace)
        #expect(result["completed"]?.intValue == 5)
        #expect(session.history.undoCount == undoCount + 1 && session.history.undoName == "Paint Batch")
        #expect(result["undo"]?.objectValue?["recorded"] == .bool(true))
        #expect(session.document != document)
        session.undo()
        #expect(session.document == document)
    }

    @Test func rollingBackAFailedBatchRestoresTheDocumentLayerSelectionAndMaskTarget() async throws {
        let (workspace, session, a, b) = try await paintedDocument()
        let locked = try addLayer(session, "Locked")
        let index = try #require(session.document?.layers.firstIndex { $0.id == locked })
        session.document?.layers[index].locks = [.pixels]
        try await MCPTestSupport.call("select_layers", ["layers": ["A", "B"], "active": "A", "target": "mask"], in: workspace)
        let document = try #require(session.document)
        let undoCount = session.history.undoCount

        let failing = paintSteps + [step("fill_selection", ["layer": "Locked", "color": "#ff00ff"])]
        let result = await MCPToolRegistry.call("run_batch", ["steps": .array(failing), "rollback_on_error": true], workspace: workspace)
        let object = try #require(result.structuredContent?.objectValue)
        #expect(result.isError == true)
        #expect(object["rolled_back"] == .bool(true) && object["completed"]?.intValue == 5)
        #expect(error(object)["guard"]?.stringValue == "layer_locked")
        #expect(session.document == document)
        #expect(session.document?.selection == document.selection && session.document?.selection != nil)
        #expect(session.selectedLayerIDs == [a, b] && session.activeLayerID == a && session.isMaskSelected)
        #expect(session.history.undoCount == undoCount && !session.history.isEditing)
    }

    // MARK: The app editing during a batch

    /// Runs `run_batch` with `steps` (rolling back on error, plus `extra` arguments) in a task of its own, with a
    /// checker whose Documents listing hangs, so the step that reads `home`'s Documents waits there; once it does,
    /// `meanwhile` runs as the app would, outside the batch, and the listing is let through. Returns the batch's
    /// result, retrying (after `beforeRetry`) when a loaded machine made the step report the prompt as still waiting.
    private func batchInterrupted(_ steps: (URL) -> [Value], in workspace: ProjectWorkspace, arguments extra: [String: Value] = [:],
                                  beforeRetry: () async throws -> Void = {},
                                  meanwhile: () async throws -> Void) async throws -> [String: Value] {
        let home = FakeHome(roots: [.documents])
        let image = home[.documents].appendingPathComponent("photo.png")
        try writePNG(image)
        for attempt in 1...3 {
            let lister = FakeLister(["Documents": .hang])
            let checker = FolderAccess.Checker(locations: home.locations, lister: { try lister.list($0) })
            let arguments = extra.merging(["steps": .array(steps(image)), "rollback_on_error": true]) { _, new in new }
            let call = Task {
                await FolderAccess.$taskChecker.withValue(checker) {
                    await MCPToolRegistry.call("run_batch", arguments, workspace: workspace)
                }
            }
            let start = ContinuousClock.now
            while lister.listed.isEmpty, start.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(5)) }
            try #require(!lister.listed.isEmpty, "The batch never reached the folder check")
            try await meanwhile()
            lister.release()
            let result = try #require(await call.value.structuredContent?.objectValue)
            if error(result)["details"]?.objectValue?["code"]?.stringValue == "folder_access_pending", attempt < 3 {
                try await beforeRetry()
                continue
            }
            return result
        }
        return [:]
    }

    /// A step, one that waits on the folder check for `image` (where `meanwhile` runs), and one that fails, so the
    /// batch rolls back: with nothing of the app's inside it, it ends `not_found` and `rolled_back`.
    private func stepsThatWaitThenFail(_ image: URL) -> [Value] {
        [step("add_blank_layer", ["name": "First"]), step("add_image_layer", ["path": .string(image.path)]),
         step("set_layer_opacity", ["layer": "Nope", "opacity": 0.5])]
    }

    private func writePNG(_ url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try solid(width: 8, height: 8), nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// While a batch holds the history, the app's edits, undo and project operations wait (their menu items and
    /// gates read false), so none of them lands inside the batch's undo step or is thrown away by its rollback.
    @Test func theAppCantEditWhileABatchHoldsTheHistory() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        let before = try addLayer(session, "Before")
        let document = try #require(session.document)
        let undoCount = session.history.undoCount
        var seen: (canEdit: Bool, canUndo: Bool, canSave: Bool, names: [String])?
        let result = try await batchInterrupted({ image in
            [step("add_blank_layer", ["name": "First"]), step("add_image_layer", ["path": .string(image.path)]),
             step("set_layer_opacity", ["layer": "Nope", "opacity": 0.5])]
        }, in: workspace) {
            // The owner clicks New Layer, deletes another layer and presses Undo while the step waits.
            let canEdit = session.canEditLayers, canUndo = session.canUndo, canSave = session.canStartProjectOperation
            session.addBlankLayer()
            session.selectLayer(before)
            session.deleteSelectedLayers()
            session.undo()
            seen = (canEdit, canUndo, canSave, session.document?.layers.map(\.name) ?? [])
        }
        let seenNow = try #require(seen)
        #expect(!seenNow.canEdit && !seenNow.canUndo && !seenNow.canSave, "\(seenNow)")
        #expect(seenNow.names == document.layers.map(\.name) + ["First"], "The app edited inside the batch: \(seenNow.names)")
        #expect(error(result)["code"]?.stringValue == "not_found" && result["rolled_back"] == .bool(true), "\(result)")
        #expect(session.document == document && session.history.undoCount == undoCount)
        #expect(session.canEditLayers && session.canUseHistory && !session.history.isEditing)
    }

    /// An app edit that gets in anyway (one whose command doesn't consult the gates) stops the batch after the step
    /// that waited, and the batch never rolls back over it: the rollback would throw the owner's work away with no
    /// undo entry. A history reset under the batch (the document replaced) stops it the same way.
    @Test func aBatchNeverRollsBackOverAnEditTheAppMadeMeanwhile() async throws {
        for resets in [false, true] {
            let workspace = MCPTestSupport.workspace(width: 32, height: 32)
            let session = workspace.current.session
            let before = try addLayer(session, "Before")
            let result = try await batchInterrupted({ image in
                [step("add_blank_layer", ["name": "First"]), step("add_image_layer", ["path": .string(image.path)]),
                 step("set_layer_opacity", ["layer": "Nope", "opacity": 0.5])]
            }, in: workspace) {
                if resets {
                    session.history.reset()
                } else {
                    session.beginEdit("Owner's edit")
                    let index = try #require(session.document?.layers.firstIndex { $0.id == before })
                    session.document?.layers[index].name = "Renamed by the owner"
                    session.endEdit()
                }
            }
            #expect(result["ok"] == .bool(false) && error(result)["guard"]?.stringValue == "history_busy", "\(result)")
            #expect(error(result)["details"]?.objectValue?["step"]?.intValue == 1, "\(result)")
            #expect(result["rolled_back"] == .bool(false), "\(result)")
            let names = session.document?.layers.map(\.name) ?? []
            #expect(names.contains("First") && !names.contains("Nope"), "\(names)")
            if !resets { #expect(names.contains("Renamed by the owner"), "The rollback undid the owner's edit: \(names)") }
            #expect(!session.history.isEditing, "resets \(resets)")
        }
    }

    /// A step that waits (a save or export) lets the app run; an edit the app opens then and leaves open would nest
    /// into the batch's. The batch stops after that step without rolling back (which would undo whatever the open
    /// edit has changed) and closes only its own level, leaving the app's edit open for the app to finish.
    @Test func aBatchStopsWhenTheAppOpensAnEditWhileAStepWaits() async throws {
        for rollback in [true, false] {
            let workspace = MCPTestSupport.workspace(width: 32, height: 32)
            let session = workspace.current.session
            let undoCount = session.history.undoCount
            let url = MCPTestSupport.tempFile("batch.png")
            let intruder = Task { @MainActor in
                let deadline = Date().addingTimeInterval(20)
                while !session.isProjectBusy, Date() < deadline { await Task.yield() }
                session.beginEdit("Layer Opacity")
            }
            let steps: [Value] = [step("add_blank_layer", ["name": "First"]), step("export_image", ["path": .string(url.path)]),
                                  step("add_blank_layer", ["name": "Never"])]
            let result = await MCPToolRegistry.call("run_batch", ["steps": .array(steps), "rollback_on_error": .bool(rollback)],
                                                    workspace: workspace)
            await intruder.value
            let object = try #require(result.structuredContent?.objectValue)
            #expect(result.isError == true, "\(object)")
            #expect(error(object)["guard"]?.stringValue == "history_busy", "\(object)")
            #expect(error(object)["details"]?.objectValue?["step"]?.intValue == 1)
            #expect(object["completed"]?.intValue == 2 && object["rolled_back"] == .bool(false))
            #expect(session.document?.layers.contains { $0.name == "Never" } == false)
            #expect(session.document?.layers.contains { $0.name == "First" } == true)
            // The app's edit is still open; the batch closed only its own level.
            #expect(session.history.isEditing)
            session.endEdit()
            #expect(!session.history.isEditing)
            #expect(session.history.undoCount == undoCount + 1)
        }
    }

    // MARK: App edits that went round the batch's gates

    /// View > Clear Guides works on locked guides, so it has a gate of its own (`canClearGuides`), which waits for a
    /// batch like the rest: cleared while a step waits, the guides went into the batch's undo step and stopped it.
    @Test func clearGuidesWaitsWhileABatchHoldsTheHistory() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        let guide = CanvasGuide(id: UUID(), axis: .vertical, position: 8)
        session.addGuide(guide)
        let document = try #require(session.document)
        let undoCount = session.history.undoCount
        var couldClear: Bool?
        let result = try await batchInterrupted(stepsThatWaitThenFail, in: workspace) {
            // The owner picks View > Clear Guides while the step waits.
            couldClear = session.canClearGuides
            session.clearGuides()
        }
        #expect(couldClear == false)
        #expect(error(result)["code"]?.stringValue == "not_found" && result["rolled_back"] == .bool(true), "\(result)")
        #expect(session.document == document && session.history.undoCount == undoCount)
        #expect(session.document?.guides == [guide] && session.canClearGuides)
    }

    /// An image dropped on the batch's tab in the tab bar while another tab shows: the drop checks only the tab it
    /// switches away from, so the import itself (`waitForProjectAccess`) waits for the batch, then records its own step.
    @Test func anImageDroppedOnTheBatchsTabWaitsForTheBatch() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let batchTab = workspace.current
        let session = batchTab.session
        let showing = workspace.addTab(reuseEmpty: false)
        var document = try #require(session.document)
        var undoCount = session.history.undoCount
        let dropped = MCPTestSupport.tempFile("dropped.png")
        try writePNG(dropped)
        var drop: Task<Void, Never>?
        var importedMeanwhile = false
        let result = try await batchInterrupted(stepsThatWaitThenFail, in: workspace, arguments: ["document": 0], beforeRetry: {
            // That attempt's drop went in once its batch ended: let it finish, count from there, and show the other
            // tab again (the drop switched to the batch's).
            await drop?.value
            workspace.select(showing.id)
            try #require(workspace.current === showing)
            document = try #require(session.document)
            undoCount = session.history.undoCount
        }) {
            drop = Task { await workspace.receive([dropped], into: batchTab.id) }
            // The drop runs until it first waits, by then managing the workspace: in the import's wait for the batch,
            // or (without it) in the import it has already started.
            let deadline = ContinuousClock.now + .seconds(10)
            while !workspace.isManaging, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
            try #require(workspace.isManaging, "The drop never reached the import")
            importedMeanwhile = session.isImporting
        }
        await drop?.value
        #expect(!importedMeanwhile)
        #expect(error(result)["code"]?.stringValue == "not_found" && result["rolled_back"] == .bool(true), "\(result)")
        #expect(session.history.undoCount == undoCount + 1 && session.history.undoName == "Import Images")
        #expect(session.document?.layers.map(\.name) == document.layers.map(\.name) + ["dropped"])
    }

    /// A guide dragged out of a ruler is recorded when the mouse goes up. Begun before a batch, it recorded inside the
    /// batch's step when it ended, so, like a brush stroke, it holds the history: undo and run_batch refuse until then.
    @Test func aGuideDragInTheAppHoldsTheHistory() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        try await MCPTestSupport.call("add_blank_layer", ["name": "A"], in: workspace)
        let undoCount = session.history.undoCount
        session.beginGuideCreation(axis: .vertical, at: 10)
        #expect(session.guideDrag != nil && !session.canUseHistory && !session.canUndo)
        let batch = try await MCPTestSupport.call("run_batch", ["steps": [step("add_blank_layer", ["name": "B"])]],
                                                  in: workspace, expectError: "precondition_failed")
        #expect(error(batch)["guard"]?.stringValue == "can_use_history", "\(batch)")
        #expect(error(batch)["message"]?.stringValue?.contains("guide") == true, "\(batch)")
        let undo = try await MCPTestSupport.call("undo", in: workspace, expectError: "precondition_failed")
        #expect(error(undo)["guard"]?.stringValue == "can_use_history", "\(undo)")
        #expect(session.history.undoCount == undoCount && session.document?.layers.contains { $0.name == "A" } == true)
        session.moveGuideDrag(to: 12)
        session.finishGuideDrag(delete: false)
        #expect(session.history.undoName == "New Guide" && session.history.undoCount == undoCount + 1)
        try await MCPTestSupport.call("run_batch", ["steps": [step("add_blank_layer", ["name": "B"])]], in: workspace)
        #expect(session.history.undoName == "Batch (1)" && session.history.undoCount == undoCount + 2)
    }

    /// A layer dropped in the Layers list lands through the list's `place`, which opened its edit before asking
    /// whether layers could move: while a batch held the history, even a refused drop counted as the app editing
    /// inside the batch's step and stopped it.
    @Test func aLayerListDropWaitsWhileABatchHoldsTheHistory() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        let bottom = try addLayer(session, "Bottom")
        try addLayer(session, "Top")
        let document = try #require(session.document)
        let undoCount = session.history.undoCount
        let coordinator = NativeLayerList.Coordinator(session: session)
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layer")))
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.update(table)
        var moved: Bool?
        let result = try await batchInterrupted(stepsThatWaitThenFail, in: workspace) {
            // The owner drags Bottom to the top of the list while the step waits.
            moved = coordinator.moveLayer(bottom, to: 0)
        }
        #expect(moved == false)
        #expect(error(result)["code"]?.stringValue == "not_found" && result["rolled_back"] == .bool(true), "\(result)")
        #expect(session.document == document && session.history.undoCount == undoCount)
        #expect(coordinator.moveLayer(bottom, to: 0) && session.history.undoCount == undoCount + 1)
    }
}
