import Foundation
import MCP

// MARK: - History

extension MCPToolRegistry {
    static let historyTools: [MCPToolEntry] = [
        tool("undo", title: "Undo",
             description: "Undoes the last 'steps' edits (default 1) as ⌘Z does, stopping when nothing is left, and returns undone and the undo state. Refused while the app holds the history (guard can_use_history) or an edit open (history_busy).",
             properties: ["steps": MCPSchema.int("Entries to undo.", min: 1, default: 1)],
             effect: .destructive(idempotent: false), handler: undo),
        tool("redo", title: "Redo",
             description: "Redoes the last 'steps' undone edits (default 1) as ⇧⌘Z does, and returns redone and the undo state; refused when undo is.",
             properties: ["steps": MCPSchema.int("Entries to redo.", min: 1, default: 1)],
             effect: .destructive(idempotent: false), handler: redo),
        tool("get_history", title: "Get history",
             description: "Lists undo_names (what undo steps back through, next first) and redo_names, their counts, whether undo and redo can run now, and whether there are unsaved changes.",
             effect: .readOnly, handler: getHistory),
        tool("run_batch", title: "Run batch",
             description: "Runs up to \(maxBatchSteps) tool calls in order as one undo step named 'name' (default \"Batch (n)\"), each {tool, arguments} on this batch's document. It stops at the first failure (details.step, details.tool, completed, results); earlier steps stay unless rollback_on_error. Steps can't be \(disallowedToolList). Refused (guard can_use_history) while the app holds the history or an edit open: settle_pending_edits first.",
             properties: [
                 "steps": MCPSchema.arr("The calls, in order.", items: MCPSchema.object([
                     "tool": MCPSchema.str("The tool's name, e.g. add_blank_layer."),
                     "arguments": .object(["type": .string("object"), "description": .string("The tool's arguments, without 'document'.")]),
                 ], required: ["tool"]), minItems: 1, maxItems: maxBatchSteps),
                 "name": MCPSchema.str("The undo entry's name."),
                 "rollback_on_error": MCPSchema.bool("On failure, undo the earlier steps too.", default: false),
             ],
             required: ["steps"], effect: .destructive(idempotent: false), handler: runBatch),
    ]

    // MARK: Undo and redo

    static func undo(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let session = ctx.session
        let steps = try historySteps(ctx)
        let undone = moveThroughHistory(steps, session, available: { session.canUndo }) { session.undo() }
        return historyResult(ctx, ["undone": .int(undone)])
    }

    static func redo(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let session = ctx.session
        let steps = try historySteps(ctx)
        let redone = moveThroughHistory(steps, session, available: { session.canRedo }) { session.redo() }
        return historyResult(ctx, ["redone": .int(redone)])
    }

    static func getHistory(_ ctx: MCPCallContext) -> CallTool.Result {
        let history = ctx.session.history
        var fields = MCPValues.history(ctx.session)
        fields["undo_names"] = .array(history.undoNames.map { .string($0) })
        fields["redo_names"] = .array(history.redoNames.map { .string($0) })
        fields["undo_count"] = .int(history.undoCount)
        fields["redo_count"] = .int(history.redoNames.count)
        return ok(fields)
    }

    /// The `steps` argument (default 1), once the history can move: nothing in progress in the app holds it
    /// (`EditorSession.canUseHistory`), else `guard: "can_use_history"`, and no edit is open or pending (an adjustment
    /// layer's settings panel, an opacity drag, a gradient waiting to be committed, a crop frame, moved pixels, a
    /// filter or Hue/Saturation dialog), else `guard: "history_busy"`: undo would step past the open edit's start,
    /// throw a pending gradient away, or change the layer under a dialog so its OK is dropped.
    private static func historySteps(_ ctx: MCPCallContext) throws -> Int {
        let steps = try ctx.args.int("steps", default: 1)
        guard steps >= 1 else { throw MCPToolError.invalidArgument("steps must be at least 1.") }
        let session = ctx.session
        guard session.canUseHistory else {
            throw historyHeld(session, hint: "Finish or cancel it in Compositor (or call settle_pending_edits), then retry.")
        }
        guard !hasEditInProgress(session) else { throw historyBusy(session) }
        return steps
    }

    /// An edit is open in the history, or pending in the app without one (`MCPGuards.blockingReason` names each).
    private static func hasEditInProgress(_ session: EditorSession) -> Bool {
        session.history.isEditing || MCPGuards.blockingReason(session) != nil
    }

    /// `guard: "history_busy"`: the app holds an edit open, which undo, redo and batches must not reach into.
    private static func historyBusy(_ session: EditorSession) -> MCPToolError {
        let reason = MCPGuards.blockingReason(session)
            ?? (session.opacityEditLayerID != nil ? "A layer's opacity is being changed in the app." : "An edit is still open in the app.")
        return MCPToolError(.preconditionFailed, reason + " The undo history waits until it ends.",
                            hint: "Commit or cancel it with settle_pending_edits (or finish it in Compositor), then retry.",
                            guard: "history_busy")
    }

    /// `guard: "can_use_history"`: something in progress in the app holds the history. `busy` while that is an import
    /// or a long operation, which only finishing ends.
    private static func historyHeld(_ session: EditorSession, hint: String) -> MCPToolError {
        let reason = MCPGuards.blockingReason(session) ?? "Something in progress in the app holds the undo history."
        let transient = session.isProjectBusy || session.isImporting
        return MCPToolError(transient ? .busy : .preconditionFailed, reason,
                            hint: transient ? "Wait for it to finish, then retry." : hint, guard: "can_use_history")
    }

    /// Repeats `move` up to `steps` times while `available`, returning how many times it reached another history point.
    private static func moveThroughHistory(_ steps: Int, _ session: EditorSession, available: () -> Bool, _ move: () -> Void) -> Int {
        var moved = 0
        for _ in 0..<steps {
            guard available() else { break }
            let revision = session.history.revisionID
            move()
            if session.history.revisionID != revision { moved += 1 }
        }
        return moved
    }

    private static func historyResult(_ ctx: MCPCallContext, _ fields: [String: Value]) -> CallTool.Result {
        // Undo and redo move through existing entries; they never record a new one.
        ctx.mutated(MCPValues.history(ctx.session).merging(fields) { _, new in new }, recorded: false)
    }

    // MARK: Batches

    static let maxBatchSteps = 200

    /// Tools a batch can't run: they move through or reset the history the batch records into, open, close or
    /// switch documents, or (settle_pending_edits) finish the app's own edits, each meant as an undo step of its own
    /// that a batch would fold into its entry and a rollback would wipe out.
    static let batchDisallowedTools: Set<String> = [
        "undo", "redo", "run_batch", "new_document", "open_document", "close_document",
        "select_document", "duplicate_document", "revert_document", "settle_pending_edits",
    ]

    /// `batchDisallowedTools` in name order, as run_batch's description lists them: "a, b or c".
    static var disallowedToolList: String {
        let names = batchDisallowedTools.sorted()
        return names.dropLast().joined(separator: ", ") + " or " + (names.last ?? "")
    }

    private struct BatchStep {
        let index: Int
        let entry: MCPToolEntry
        let arguments: [String: Value]
        var tool: String { entry.tool.name }
    }

    static func runBatch(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let steps = try batchSteps(ctx.args)
        let name = try ctx.args.optionalString("name") ?? "Batch (\(steps.count))"
        let rollback = try ctx.args.bool("rollback_on_error", default: false)
        let session = ctx.session
        try requireBatchOwnsHistory(session)
        let original = session.document
        let originalSelection = (active: session.activeLayerID, selected: session.selectedLayerIDs, mask: session.isMaskSelected)
        var results: [Value] = []
        var failure: MCPToolError?
        // The document as the batch's last save wrote it to its file.
        var saved: CanvasDocument?

        session.beginEdit(name)
        // The app's own edits wait until the batch ends; its steps run as `runsAgentBatchStep`, which passes.
        session.beginAgentBatch()
        /// Only the batch's edit is open and nothing but its steps began one inside it.
        func batchOwnsHistory() -> Bool { session.history.editDepth == 1 && session.appEditsDuringAgentBatch == 0 }
        for step in steps {
            // As the registry dispatches: document tools act on the batch's tab, the rest on the current one.
            let tab = step.entry.takesDocument ? ctx.tab : ctx.workspace.current
            var stepFailure: MCPToolError?
            let stepStarted = ContinuousClock.now
            defer { MCPCallLog.batchStep(step.index, tool: step.tool, arguments: step.arguments, startedAt: stepStarted, failure: stepFailure) }
            do {
                let result = try await EditorSession.$runsAgentBatchStep.withValue(true) {
                    try await step.entry.handler(MCPCallContext(workspace: ctx.workspace, tab: tab, args: Args(step.arguments)))
                }
                var fields = result.structuredContent?.objectValue ?? [:]
                if result.isError == true { throw stepError(fields["error"]) }
                if savesDocument(step, fields) { saved = session.document }
                // Steps nest inside the batch's edit and record nothing of their own; the batch reports the entry.
                fields["ok"] = nil
                fields["undo"] = nil
                results.append(.object(fields))
            } catch {
                stepFailure = batchFailure(MCPToolError.from(error), at: step)
            }
            // A step that waited (a save, an export, reading a file) let the app run. Its edits wait while the batch
            // holds the history, but one whose command doesn't ask (or an edit left open, or a revert) would nest into
            // the batch's edit and record as part of it, so the batch stops there.
            guard batchOwnsHistory() else {
                failure = batchFailure(appEditedDuringBatch(session), at: step)
                break
            }
            if let stepFailure {
                failure = stepFailure
                break
            }
        }
        // Never rolled back over the app's work: the document may hold its edit, or be another document altogether.
        let ownsHistory = batchOwnsHistory()
        session.endAgentBatch()
        let rolledBack = failure != nil && rollback && ownsHistory
        if rolledBack {
            session.document = original
            session.activeLayerID = originalSelection.active
            session.selectedLayerIDs = originalSelection.selected
            session.isMaskSelected = originalSelection.mask && session.activeLayer?.mask != nil
        }
        // Closes the batch's level only. An app edit still open inside it ends when the app ends it (recording the
        // two together); after a history reset nothing of the batch's is left open.
        if session.history.isEditing { session.endEdit() }
        if let saved, ownsHistory { keepSavedStateHonest(session, saved: saved, original: original) }

        var fields: [String: Value] = ["completed": .int(results.count), "results": .array(results)]
        guard let failure else { return ctx.mutated(fields) }
        fields["rolled_back"] = .bool(rolledBack)
        fields["undo"] = MCPValues.undo(session, recorded: session.history.revisionID != ctx.startRevision)
        fields["ok"] = .bool(false)
        fields["error"] = failure.value
        return result(.object(fields), isError: true)
    }

    /// A batch records its own undo entry and owns its rollback, so it starts only when the app holds none of the
    /// history: nothing in progress blocks undo (`canUseHistory`) and no edit is open or pending. An adjustment layer's
    /// settings panel or an opacity drag keeps one open until it ends; the batch's edit would nest inside it, so the
    /// app's work and the batch's would record as one entry under the app's name. A pending gradient, crop or dialog
    /// would be settled or dropped by the batch's steps.
    private static func requireBatchOwnsHistory(_ session: EditorSession) throws {
        guard session.canUseHistory, !hasEditInProgress(session) else {
            throw historyHeld(session, hint: "Commit or cancel it with settle_pending_edits (or finish it in Compositor), then run the batch.")
        }
    }

    /// Why a batch stopped when the app edited the document (or reset its history) while a step waited.
    private static func appEditedDuringBatch(_ session: EditorSession) -> MCPToolError {
        let what = MCPGuards.blockingReason(session).map { " (\($0))" } ?? ""
        return MCPToolError(.preconditionFailed,
                            "Compositor edited the document itself\(what) while this step waited, so the batch stopped there, and nothing was rolled back: that would undo the app's edit too.",
                            hint: "Check the document with get_document and get_history; settle_pending_edits commits or cancels an edit still open in the app. Then run the remaining steps.",
                            guard: "history_busy")
    }

    /// The `steps` argument, each checked before any runs: a known tool that may run in a batch, and arguments
    /// (an object, `{}` when absent) without a `document` selector.
    private static func batchSteps(_ args: Args) throws -> [BatchStep] {
        guard let value = args["steps"] else {
            throw MCPToolError.invalidArgument("Missing 'steps': a list of {tool, arguments} calls.")
        }
        guard let list = value.arrayValue else {
            throw MCPToolError.invalidArgument("'steps' must be a list of {tool, arguments} objects.")
        }
        guard (1...maxBatchSteps).contains(list.count) else {
            throw MCPToolError.invalidArgument("'steps' must hold 1 to \(maxBatchSteps) calls; it has \(list.count).",
                                               hint: list.isEmpty ? nil : "Split the work into several batches.")
        }
        return try list.enumerated().map { index, value in
            func refuse(_ code: MCPErrorCode, _ message: String, hint: String? = nil, tool: String? = nil,
                        details extra: [String: Value] = [:]) -> MCPToolError {
                var details: [String: Value] = extra.merging(["step": .int(index)]) { _, new in new }
                if let tool { details["tool"] = .string(tool) }
                return MCPToolError(code, "steps[\(index)]: \(message)", hint: hint, details: details)
            }
            guard let step = value.objectValue, let tool = step["tool"]?.stringValue, !tool.isEmpty else {
                throw refuse(.invalidArgument, "Each step must be an object with a 'tool' name and optional 'arguments'.")
            }
            guard let entry = entriesByName[tool] else {
                throw refuse(.notFound, "Unknown tool '\(tool)'.", hint: "tools/list shows every tool Compositor offers.", tool: tool)
            }
            guard !batchDisallowedTools.contains(tool) else {
                throw refuse(.invalidArgument, "\(tool) can't run inside a batch.", hint: "Call it on its own, before or after run_batch.", tool: tool)
            }
            let arguments: [String: Value]
            switch step["arguments"] {
            case nil, .null?: arguments = [:]
            case .object(let object)?: arguments = object
            default: throw refuse(.invalidArgument, "'arguments' must be an object.", tool: tool)
            }
            guard Args(arguments)["document"] == nil else {
                throw refuse(.invalidArgument, "A step can't choose its own document; every step acts on the batch's document.",
                             hint: "Pass 'document' to run_batch itself.", tool: tool)
            }
            if let unknown = unknownArgument(arguments, of: entry) {
                throw refuse(unknown.code, unknown.message, hint: unknown.hint, tool: tool, details: unknown.details)
            }
            return BatchStep(index: index, entry: entry, arguments: arguments)
        }
    }

    /// The error a step returned as a failure result rather than threw.
    private static func stepError(_ value: Value?) -> MCPToolError {
        let error = value?.objectValue ?? [:]
        return MCPToolError(error["code"]?.stringValue.flatMap(MCPErrorCode.init(rawValue:)) ?? .internalError,
                            error["message"]?.stringValue ?? "The step failed.",
                            hint: error["hint"]?.stringValue, guard: error["guard"]?.stringValue,
                            details: error["details"]?.objectValue ?? [:])
    }

    /// `error` from the step at `step`, its message and details naming the step.
    private static func batchFailure(_ error: MCPToolError, at step: BatchStep) -> MCPToolError {
        var details = error.details
        details["step"] = .int(step.index)
        details["tool"] = .string(step.tool)
        return MCPToolError(error.code, "steps[\(step.index)] (\(step.tool)) failed: \(error.message)",
                            hint: error.hint, guard: error.guardName, details: details)
    }

    /// The step saved the document to its own file (and marked it saved), not a copy.
    private static func savesDocument(_ step: BatchStep, _ result: [String: Value]) -> Bool {
        switch step.tool {
        case "save_document": true
        case "save_document_as": result["set_as_current"] != .bool(false)
        default: false
        }
    }

    /// Inside the batch's open edit the history stays at its starting point, so a save step marked that point saved
    /// whatever it wrote. Once the batch closes: the document as it now is was saved when it matches the last save; the
    /// starting point was when the save wrote it unchanged (the save's own mark stands); otherwise no point in the
    /// history matches the file and the document reads as modified until it is saved again.
    private static func keepSavedStateHonest(_ session: EditorSession, saved: CanvasDocument, original: CanvasDocument?) {
        if session.document == saved {
            session.history.markSaved()
        } else if saved != original {
            session.history.markUnsaved()
        }
    }
}
