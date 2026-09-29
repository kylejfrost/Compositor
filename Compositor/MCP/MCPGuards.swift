import Foundation
import MCP

/// Preconditions tools check before touching a document, each failing with a
/// structured `MCPToolError` whose `guard` names the check.
@MainActor
enum MCPGuards {
    static func requireDocument(_ session: EditorSession) throws -> CanvasDocument {
        guard let document = session.document else {
            throw MCPToolError(.preconditionFailed, "This tab has no document open.",
                               hint: "Create one with new_document, or open one with open_document.", guard: "document")
        }
        return document
    }

    /// Layer edits are allowed (`EditorSession.canEditLayers`): a document is open and no
    /// modal edit, import or long operation holds it.
    static func requireEditable(_ session: EditorSession) throws {
        _ = try requireDocument(session)
        guard !session.canEditLayers else { return }
        throw blocked(session, guard: "can_edit_layers")
    }

    /// Project-level operations (save, export, resize) are allowed
    /// (`EditorSession.canStartProjectOperation`).
    static func requireProjectOperation(_ session: EditorSession) throws {
        guard !session.canStartProjectOperation else { return }
        throw blocked(session, guard: "can_start_project_operation")
    }

    /// The layer has pixels of its own: not a folder and not an adjustment layer.
    static func requirePixels(_ layer: ImageLayer) throws {
        if layer.isGroup {
            throw MCPToolError(.preconditionFailed, "'\(layer.name)' is a folder; it has no pixels of its own.",
                               hint: "Pick a layer inside it (get_layer lists its children) or another layer with pixels.", guard: "has_pixels")
        }
        if layer.adjustment != nil {
            throw MCPToolError(.preconditionFailed, "'\(layer.name)' is an adjustment layer; it has no pixels of its own.",
                               hint: "Pick a layer with pixels; an adjustment layer's settings change with set_adjustment.", guard: "has_pixels")
        }
    }

    /// Adding `count` layers keeps the document within `LayerLimitError.maximum` layers, folders included.
    static func requireLayerCapacity(_ document: CanvasDocument, adding count: Int = 1) throws {
        guard document.layers.count + count > LayerLimitError.maximum else { return }
        let more = count == 1 ? "another" : "\(count) more"
        throw MCPToolError(.preconditionFailed,
                           "The document has \(document.layers.count) layers; \(more) would pass 10,000, the most Compositor allows (folders count too).",
                           hint: "Delete, merge or flatten layers first.", guard: "max_layers")
    }

    /// Opening another tab stays within `MCPSettings.maxTabs`.
    static func requireTabCapacity(_ workspace: ProjectWorkspace) throws {
        guard workspace.tabs.count >= MCPSettings.maxTabs else { return }
        throw MCPToolError(.preconditionFailed, "\(MCPSettings.maxTabs) documents are already open, the most Compositor allows.",
                           hint: "Save and close a document with close_document first.", guard: "max_tabs")
    }

    /// Why the session refuses edits right now, as a sentence, or nil when nothing blocks it.
    static func blockingReason(_ session: EditorSession) -> String? {
        let reasons: [(Bool, String)] = [
            (session.isProjectBusy, "Another operation (an import, save, resize or render) is still running."),
            (session.isImporting, "Images are being imported."),
            (session.textDraft != nil, "A text layer is being edited in the app."),
            (session.transformEdit != nil, "A free transform is in progress in the app."),
            (session.cropRect != nil, "A crop is in progress in the app."),
            (session.gradientEdit != nil, "A gradient is being edited in the app."),
            (session.pixelMove != nil, "Selected pixels are being moved in the app."),
            (session.hueSaturation != nil, "The Hue/Saturation dialog is open."),
            (session.levels != nil, "The Levels dialog is open."),
            (session.filterEdit != nil, "A filter dialog is open."),
            (session.adjustmentEditingID != nil, "An adjustment layer's settings panel is open."),
            (session.showsNewDocument, "The New Document dialog is open."),
            (session.showsImporter, "The Open dialog is open."),
            (session.renamingLayerID != nil, "A layer is being renamed in the app."),
            (session.brushStroke != nil, "A brush stroke is in progress."),
            (session.warpStroke != nil, "A liquify stroke is in progress."),
            (session.selectionAmountOperation != nil, "A selection Expand/Contract/Feather dialog is open."),
            (session.importError != nil, "An error alert is showing in the app."),
            (session.showsConversionSheet, "The PSD conversion sheet is open."),
            (session.guideDrag != nil, "A guide is being dragged in the app."),
        ]
        return reasons.first { $0.0 }?.1
    }

    /// Marks the session busy for the duration of `body`, as the app does for long
    /// operations, so no other edit starts meanwhile.
    static func withProjectBusy<T>(_ session: EditorSession, _ body: () async throws -> T) async throws -> T {
        guard !session.isProjectBusy else { throw blocked(session, guard: "can_start_project_operation") }
        session.isProjectBusy = true
        defer { session.isProjectBusy = false }
        return try await body()
    }

    /// Runs a session command that reports failure through `session.brushError` (the
    /// app's "Couldn't paint" alert) and turns that report into a thrown error, so the
    /// alert never appears for an agent's call.
    static func captureBrushError<T>(_ session: EditorSession, _ body: () throws -> T) throws -> T {
        session.brushError = nil
        let value = try body()
        if let message = session.brushError {
            session.brushError = nil
            throw brushError(message)
        }
        return value
    }

    /// The app's own reason an edit failed, as it would show in its alert.
    fileprivate static func brushError(_ message: String) -> MCPToolError {
        MCPToolError(.preconditionFailed, message,
                     hint: "Fix what the message names (get_layer shows the layer's locks, visibility and pixels), then retry.",
                     guard: "brush_error")
    }

    private static func blocked(_ session: EditorSession, guard name: String) -> MCPToolError {
        let reason = blockingReason(session) ?? "The document can't be edited right now."
        let transient = session.isProjectBusy || session.isImporting
        return MCPToolError(transient ? .busy : .preconditionFailed, reason,
                            hint: transient ? "Wait for it to finish, then retry."
                                : "Commit or cancel it with settle_pending_edits (or finish it in Compositor), then retry.",
                            guard: name)
    }
}

// MARK: - Layer locks and Photoshop placeholders

extension MCPGuards {
    /// The locks in force on `layer` allow an edit `lock` stands for: `.position` moving or transforming it, `.pixels`
    /// changing its pixels, `.transparency` changing its transparent pixels, `.all` any other change (everything but
    /// showing, hiding and selecting it). Photoshop's Lock All blocks every one of them.
    ///
    /// A folder's locks apply to everything inside it, as in Photoshop (the contents show an inherited lock), so the
    /// layer's own locks and those of every folder it is in are checked — by `LayerLockIndex`, as the app's own edits
    /// are. Fails with `guard: "layer_locked"`; `details.locked_by_id` names the layer or folder whose lock blocks the
    /// edit.
    static func requireUnlocked(_ layer: ImageLayer, in document: CanvasDocument, _ lock: LayerLocks) throws {
        try requireUnlocked([layer], in: document, lock)
    }

    /// `requireUnlocked(_:in:_:)` for each of `layers`, in order.
    static func requireUnlocked(_ layers: [ImageLayer], in document: CanvasDocument, _ lock: LayerLocks) throws {
        guard !layers.isEmpty else { return }
        let index = document.lockIndex
        for layer in layers {
            if let blocker = index.blocker(of: lock, on: layer.id) { throw lockedError(layer, by: blocker) }
        }
    }

    private static func lockedError(_ layer: ImageLayer, by holder: LayerLockIndex.Blocker) -> MCPToolError {
        let names = MCPValues.layerLocks(holder.locks)
        let list = (names.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", ")
        let details: [String: Value] = ["layer_id": .string(layer.id.uuidString), "locked_by_id": .string(holder.id.uuidString),
                                        "locks": names]
        guard holder.id != layer.id else {
            return MCPToolError(.preconditionFailed, "'\(layer.name)' is locked (\(list)).",
                                hint: "Unlock it with set_layer_locks, then retry.", guard: "layer_locked", details: details)
        }
        return MCPToolError(.preconditionFailed,
                            "'\(layer.name)' is inside the folder '\(holder.name)', which is locked (\(list)); a folder's locks apply to everything in it.",
                            hint: "Unlock the folder '\(holder.name)' with set_layer_locks, then retry.", guard: "layer_locked",
                            details: details)
    }

    /// The layer is not a Photoshop placeholder: a layer Compositor can't show (an unsupported adjustment, say), kept
    /// hidden and without pixels only so it can be written back. Fails with `guard: "placeholder"`.
    static func requireNotPlaceholder(_ layer: ImageLayer) throws {
        guard let kind = layer.psdExtras?.placeholder else { return }
        throw MCPToolError(.preconditionFailed,
                           "'\(layer.name)' is a Photoshop layer (\(kind)) Compositor keeps only to write back; it has no pixels to edit.",
                           hint: "Leave it as it is to keep it in the Photoshop file; to get its effect, add a layer of your own (add_adjustment_layer, say).",
                           guard: "placeholder")
    }
}

extension MCPGuards {
    /// `captureBrushError` for an async session command (the Magic Wand, committing moved pixels). Named apart from
    /// it so a synchronous call in an async handler never resolves to this one.
    static func captureAsyncBrushError<T>(_ session: EditorSession, _ body: () async throws -> T) async throws -> T {
        session.brushError = nil
        let value: T
        do { value = try await body() } catch { session.brushError = nil; throw error }
        if let message = session.brushError {
            session.brushError = nil
            throw brushError(message)
        }
        return value
    }
}
