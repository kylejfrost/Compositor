import Foundation
import Testing
import MCP
@testable import Compositor

/// The History domain: undo and redo by steps, reading the history, and run_batch.
@MainActor struct MCPHistoryToolTests {
    private func names(_ session: EditorSession) -> [String] { session.document?.layers.map(\.name) ?? [] }

    private func strings(_ value: Value?) -> [String]? { value?.arrayValue?.compactMap(\.stringValue) }

    private func step(_ tool: String, _ arguments: [String: Value] = [:]) -> Value {
        .object(["tool": .string(tool), "arguments": .object(arguments)])
    }

    private func errorDetails(_ result: [String: Value]) -> [String: Value]? {
        result["error"]?.objectValue?["details"]?.objectValue
    }

    // MARK: Undo and redo

    @Test func undoAndRedoStepThroughSeveralEntries() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        let start = session.history.undoCount
        for name in ["A", "B", "C"] {
            try await MCPTestSupport.call("add_blank_layer", ["name": .string(name)], in: workspace)
        }

        let undone = try await MCPTestSupport.call("undo", ["steps": 2], in: workspace)
        #expect(undone["undone"]?.intValue == 2)
        #expect(names(session).contains("A") && !names(session).contains("B") && !names(session).contains("C"))
        #expect(session.history.undoCount == start + 1)
        #expect(undone["can_redo"] == .bool(true))
        #expect(undone["undo"]?.objectValue?["recorded"] == .bool(false))

        // More steps than there are entries goes as far as it can.
        let redone = try await MCPTestSupport.call("redo", ["steps": 5], in: workspace)
        #expect(redone["redone"]?.intValue == 2)
        #expect(names(session).contains("C") && session.history.undoCount == start + 3)
        #expect(redone["can_redo"] == .bool(false))
        let nothing = try await MCPTestSupport.call("redo", in: workspace)
        #expect(nothing["redone"]?.intValue == 0)

        // One step by default.
        let one = try await MCPTestSupport.call("undo", in: workspace)
        #expect(one["undone"]?.intValue == 1)
        #expect(names(session).contains("B") && !names(session).contains("C"))
    }

    @Test func undoRejectsBadStepsAndRefusesWhileTheAppHoldsTheHistory() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        try await MCPTestSupport.call("add_blank_layer", ["name": "A"], in: workspace)
        try await MCPTestSupport.call("undo", ["steps": 0], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("redo", ["steps": -1], in: workspace, expectError: "invalid_argument")
        #expect(names(session).contains("A"))

        // A layer being renamed in the app holds the history, as it blocks ⌘Z.
        session.renamingLayerID = session.activeLayerID
        let blocked = try await MCPTestSupport.call("undo", in: workspace, expectError: "precondition_failed")
        #expect(blocked["error"]?.objectValue?["guard"]?.stringValue == "can_use_history")
        try await MCPTestSupport.call("redo", in: workspace, expectError: "precondition_failed")
        #expect(names(session).contains("A"))
        session.renamingLayerID = nil
        try await MCPTestSupport.call("undo", in: workspace)
        #expect(!names(session).contains("A"))
    }

    // MARK: get_history

    @Test func getHistoryListsEntriesNextFirstWithoutChangingAnything() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        // Entry names oldest first, extended with the name each call reports.
        var recorded = Array(session.history.undoNames.reversed())
        for (tool, arguments) in [("add_blank_layer", ["name": Value.string("A")]),
                                  ("rename_layer", ["layer": "A", "name": "Alpha"]),
                                  ("set_layer_opacity", ["layer": "Alpha", "opacity": 0.5])] {
            let result = try await MCPTestSupport.call(tool, arguments, in: workspace)
            recorded.append(try #require(result["undo"]?.objectValue?["name"]?.stringValue))
        }
        try await MCPTestSupport.call("undo", in: workspace)
        session.history.markSaved()
        let revision = session.history.revisionID

        let history = try await MCPTestSupport.call("get_history", in: workspace)
        #expect(strings(history["undo_names"]) == Array(recorded.dropLast().reversed()))
        #expect(strings(history["redo_names"]) == [recorded.last!])
        #expect(history["undo_count"]?.intValue == recorded.count - 1)
        #expect(history["redo_count"]?.intValue == 1)
        #expect(history["undo_name"]?.stringValue == recorded[recorded.count - 2])
        #expect(history["can_undo"] == .bool(true) && history["can_redo"] == .bool(true))
        #expect(history["is_modified"] == .bool(false))
        #expect(history["undo"] == nil)
        #expect(session.history.revisionID == revision && session.canRedo)
    }

    // MARK: run_batch

    @Test func batchIsOneUndoStepAndStopsAtFirstError() async throws {
        let workspace = MCPTestSupport.workspace(); let session = workspace.current.session
        let before = session.history.undoCount
        let result = try await MCPTestSupport.call("run_batch", ["steps": .array([
            .object(["tool": "add_blank_layer", "arguments": .object(["name": "A"])]),
            .object(["tool": "add_blank_layer", "arguments": .object(["name": "B"])]),
            .object(["tool": "rename_layer", "arguments": .object(["layer": "Nope", "name": "X"])]),
            .object(["tool": "add_blank_layer", "arguments": .object(["name": "C"])]),
        ])], in: workspace, expectError: "not_found")
        #expect(result["completed"]?.intValue == 2)
        #expect(session.document?.layers.map(\.name).contains("C") == false)
        #expect(session.history.undoCount == before + 1)
    }

    @Test func failedBatchKeepsItsFinishedStepsAsOneEntryAndNamesTheFailingStep() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        let result = try await MCPTestSupport.call("run_batch", ["steps": [
            step("add_blank_layer", ["name": "A"]),
            step("move_layer", ["layer": "Nope", "dx": 1, "dy": 1]),
        ]], in: workspace, expectError: "not_found")
        #expect(errorDetails(result)?["step"]?.intValue == 1)
        #expect(errorDetails(result)?["tool"]?.stringValue == "move_layer")
        #expect(result["rolled_back"] == .bool(false))
        #expect(result["results"]?.arrayValue?.count == 1)
        #expect(result["undo"]?.objectValue?["recorded"] == .bool(true))
        #expect(session.history.undoName == "Batch (2)" && names(session).contains("A"))
        try await MCPTestSupport.call("undo", in: workspace)
        #expect(!names(session).contains("A"))
    }

    @Test func batchSucceedsAsOneNamedUndoStepAndReturnsEachResult() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        let before = session.history.undoCount
        let result = try await MCPTestSupport.call("run_batch", ["steps": [
            step("add_blank_layer", ["name": "A"]),
            step("rename_layer", ["layer": "A", "name": "Alpha"]),
            step("set_layer_opacity", ["layer": "Alpha", "opacity": 0.25]),
            step("get_layer", ["layer": "Alpha"]),
        ]], in: workspace)
        #expect(result["completed"]?.intValue == 4)
        let results = try #require(result["results"]?.arrayValue)
        #expect(results.count == 4)
        let alpha = try #require(session.document?.layers.first { $0.name == "Alpha" })
        #expect(results[0].objectValue?["layer_id"]?.stringValue == alpha.id.uuidString)
        #expect(results.allSatisfy { $0.objectValue?["undo"] == nil })
        #expect(alpha.opacity == 0.25)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Batch (4)")
        #expect(result["undo"]?.objectValue?["name"]?.stringValue == "Batch (4)")
        #expect(result["undo"]?.objectValue?["recorded"] == .bool(true))

        // One undo takes the whole batch back, one redo brings it back.
        try await MCPTestSupport.call("undo", in: workspace)
        #expect(!names(session).contains("Alpha") && !names(session).contains("A"))
        try await MCPTestSupport.call("redo", in: workspace)
        #expect(names(session).contains("Alpha"))

        let named = try await MCPTestSupport.call("run_batch", ["name": "Add B", "steps": [step("add_blank_layer", ["name": "B"])]],
                                                  in: workspace)
        #expect(named["undo"]?.objectValue?["name"]?.stringValue == "Add B" && session.history.undoName == "Add B")

        // A batch that changes nothing records nothing.
        let count = session.history.undoCount
        let unchanged = try await MCPTestSupport.call("run_batch", ["steps": [
            step("set_layer_opacity", ["layer": "Alpha", "opacity": 0.25]),
            step("get_document"),
        ]], in: workspace)
        #expect(unchanged["undo"]?.objectValue?["recorded"] == .bool(false) && session.history.undoCount == count)
    }

    @Test func batchRollbackRestoresTheDocumentAndActiveLayer() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        try await MCPTestSupport.call("add_blank_layer", ["name": "Base"], in: workspace)
        let original = session.document
        let active = session.activeLayerID
        let revision = session.history.revisionID
        let count = session.history.undoCount

        let result = try await MCPTestSupport.call("run_batch", ["rollback_on_error": true, "steps": [
            step("add_blank_layer", ["name": "A"]),
            step("set_layer_opacity", ["layer": "Base", "opacity": 0.3]),
            step("rename_layer", ["layer": "Nope", "name": "X"]),
        ]], in: workspace, expectError: "not_found")
        #expect(result["completed"]?.intValue == 2)
        #expect(result["rolled_back"] == .bool(true))
        #expect(errorDetails(result)?["step"]?.intValue == 2)
        #expect(session.document == original && session.activeLayerID == active)
        #expect(session.history.revisionID == revision && session.history.undoCount == count)
        #expect(result["undo"]?.objectValue?["recorded"] == .bool(false))
    }

    @Test func batchRefusesDisallowedAndMalformedStepsBeforeRunningAny() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        let original = session.document
        let revision = session.history.revisionID
        let disallowed = ["undo", "redo", "run_batch", "new_document", "open_document", "close_document",
                          "select_document", "duplicate_document", "revert_document", "settle_pending_edits"]
        for tool in disallowed {
            let result = try await MCPTestSupport.call("run_batch", ["steps": [step("add_blank_layer", ["name": "A"]), step(tool)]],
                                                       in: workspace, expectError: "invalid_argument")
            #expect(errorDetails(result)?["step"]?.intValue == 1, "\(tool)")
            #expect(errorDetails(result)?["tool"]?.stringValue == tool)
        }
        // A step can't pick its own document, not even one that ignores it.
        for tool in ["add_blank_layer", "list_files"] {
            let own = try await MCPTestSupport.call("run_batch", ["steps": [step(tool, ["document": 0])]],
                                                    in: workspace, expectError: "invalid_argument")
            #expect(errorDetails(own)?["step"]?.intValue == 0)
        }
        try await MCPTestSupport.call("run_batch", ["steps": [step("add_blank_layer"), step("no_such_tool")]],
                                      in: workspace, expectError: "not_found")
        try await MCPTestSupport.call("run_batch", in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("run_batch", ["steps": []], in: workspace, expectError: "invalid_argument")
        let tooMany = Value.array(Array(repeating: step("get_document"), count: 201))
        try await MCPTestSupport.call("run_batch", ["steps": tooMany], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("run_batch", ["steps": ["add_blank_layer"]], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("run_batch", ["steps": [.object(["tool": "add_blank_layer", "arguments": "A"])]],
                                      in: workspace, expectError: "invalid_argument")
        #expect(session.document == original && session.history.revisionID == revision)
    }

    @Test func batchRefusesToStartWhileTheAppHoldsTheHistory() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        try await MCPTestSupport.call("add_blank_layer", ["name": "Base"], in: workspace)
        let original = session.document
        let revision = session.history.revisionID

        // Text being typed in the app. Settled inside a batch, it would be committed into the batch's entry and a
        // rollback would then wipe it with no undo entry left to bring it back: the batch can't settle it.
        session.beginText(at: CGPoint(x: 4, y: 4), newLayer: true)
        session.textDraft?.style.content = "Typed in the app"
        let settle = try await MCPTestSupport.call("run_batch", ["rollback_on_error": true, "steps": [
            step("settle_pending_edits", ["mode": "commit"]),
            step("rename_layer", ["layer": "Nope", "name": "X"]),
        ]], in: workspace, expectError: "invalid_argument")
        #expect(errorDetails(settle)?["step"]?.intValue == 0)
        #expect(errorDetails(settle)?["tool"]?.stringValue == "settle_pending_edits")

        // Nor does it start while the draft holds the history.
        let held = try await MCPTestSupport.call("run_batch", ["steps": [step("get_document")]],
                                                 in: workspace, expectError: "precondition_failed")
        let error = held["error"]?.objectValue
        #expect(error?["guard"]?.stringValue == "can_use_history")
        #expect(error?["hint"]?.stringValue?.contains("settle_pending_edits") == true)
        #expect(error?["details"] == nil && held["completed"] == nil)
        #expect(session.textDraft?.style.content == "Typed in the app")
        #expect(session.document == original && session.history.revisionID == revision)

        // Settled on its own, the text is an undo entry of its own and the batch then runs as another.
        try await MCPTestSupport.call("settle_pending_edits", ["mode": "commit"], in: workspace)
        #expect(session.textDraft == nil && session.history.undoName == "New Text Layer")
        let batch = try await MCPTestSupport.call("run_batch", ["steps": [step("add_blank_layer", ["name": "A"])]], in: workspace)
        #expect(batch["undo"]?.objectValue?["name"]?.stringValue == "Batch (1)")
        #expect(Array(session.history.undoNames.prefix(2)) == ["Batch (1)", "New Text Layer"])

        // An import or long operation still running: busy.
        session.isProjectBusy = true
        let busy = try await MCPTestSupport.call("run_batch", ["steps": [step("add_blank_layer", ["name": "B"])]],
                                                 in: workspace, expectError: "busy")
        session.isProjectBusy = false
        #expect(busy["error"]?.objectValue?["guard"]?.stringValue == "can_use_history")
        #expect(!names(session).contains("B"))
    }

    @Test func batchRefusesToStartInsideAnEditTheAppHoldsOpen() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        try await MCPTestSupport.call("add_blank_layer", ["name": "Base"], in: workspace)

        // An adjustment layer's settings panel keeps its edit open without blocking undo. A batch started inside it
        // would record into the panel's "Edit … Adjustment" entry instead of one of its own.
        session.addAdjustment(.exposure)
        let id = try #require(session.adjustmentEditingID)
        await session.beginAdjustmentEditing(id)
        #expect(session.filterEdit != nil && session.canUseHistory && session.history.isEditing)
        let original = session.document
        let count = session.history.undoCount
        let held = try await MCPTestSupport.call("run_batch", ["steps": [step("get_document")]],
                                                 in: workspace, expectError: "precondition_failed")
        let error = held["error"]?.objectValue
        #expect(error?["guard"]?.stringValue == "can_use_history")
        #expect(error?["hint"]?.stringValue?.contains("settle_pending_edits") == true)
        #expect(error?["details"] == nil)
        #expect(session.document == original && session.adjustmentEditingID == id && session.history.isEditing)

        // Cancelled on its own first, the panel records nothing and the batch is an entry of its own.
        try await MCPTestSupport.call("settle_pending_edits", ["mode": "cancel"], in: workspace)
        #expect(session.adjustmentEditingID == nil && !session.history.isEditing && session.history.undoCount == count)
        let batch = try await MCPTestSupport.call("run_batch", ["steps": [step("add_blank_layer", ["name": "A"])]], in: workspace)
        #expect(batch["undo"]?.objectValue?["name"]?.stringValue == "Batch (1)")
        #expect(session.history.undoName == "Batch (1)" && session.history.undoCount == count + 1)

        // An opacity drag holds its edit open the same way; the batch's layer would have joined the "Layer Opacity" entry.
        session.beginOpacityEdit()
        #expect(session.history.isEditing)
        let dragging = try await MCPTestSupport.call("run_batch", ["steps": [step("add_blank_layer", ["name": "B"])]],
                                                     in: workspace, expectError: "precondition_failed")
        #expect(dragging["error"]?.objectValue?["guard"]?.stringValue == "can_use_history")
        #expect(!names(session).contains("B"))
        session.finishOpacityEdit()
        try await MCPTestSupport.call("run_batch", ["steps": [step("add_blank_layer", ["name": "B"])]], in: workspace)
        #expect(names(session).contains("B") && session.history.undoName == "Batch (1)")
        #expect(session.history.undoCount == count + 2)
    }

    @Test func batchRunsEveryStepAgainstItsOwnDocument() async throws {
        let workspace = MCPTestSupport.workspace()
        let first = workspace.current
        try await MCPTestSupport.call("new_document", ["width": 8, "height": 8], in: workspace)
        let second = workspace.current
        #expect(second !== first)

        let result = try await MCPTestSupport.call("run_batch", ["document": 0, "steps": [
            step("add_blank_layer", ["name": "Only In First"]),
            step("get_document"),
        ]], in: workspace)
        let read = result["results"]?.arrayValue?.last?.objectValue?["document"]?.objectValue
        #expect(read?["id"]?.stringValue == first.session.document?.id.uuidString)
        #expect(names(first.session).contains("Only In First") && !names(second.session).contains("Only In First"))
        #expect(first.session.history.undoName == "Batch (2)")
        #expect(workspace.current === second)
    }

    @Test func batchThatSavesLeavesTheSavedStateMatchingTheFile() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        let path = MCPTestSupport.tempFile("batch.comp")

        // Saving as the batch's last step: the document is saved as it now is.
        try await MCPTestSupport.call("run_batch", ["steps": [
            step("add_blank_layer", ["name": "A"]),
            step("save_document_as", ["path": .string(path.path)]),
        ]], in: workspace)
        #expect(session.projectURL?.lastPathComponent == "batch.comp" && !session.isModified)
        // Undoing the batch leaves a document the file no longer matches; redoing it matches again.
        session.undo()
        #expect(session.isModified)
        session.redo()
        #expect(!session.isModified)

        // Steps after the save leave the document modified.
        try await MCPTestSupport.call("run_batch", ["steps": [step("save_document"), step("add_blank_layer", ["name": "B"])]],
                                      in: workspace)
        #expect(session.isModified)
        session.undo()
        #expect(!session.isModified)

        // A rolled-back batch whose save wrote its changes reads as modified: the file holds what was rolled back.
        try await MCPTestSupport.call("run_batch", ["rollback_on_error": true, "steps": [
            step("add_blank_layer", ["name": "C"]),
            step("save_document"),
            step("rename_layer", ["layer": "Nope", "name": "X"]),
        ]], in: workspace, expectError: "not_found")
        #expect(!names(session).contains("C") && session.isModified)
    }
}
