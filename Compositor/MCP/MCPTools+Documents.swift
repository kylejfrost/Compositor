import CoreGraphics
import Foundation
import MCP

// MARK: - Documents & tabs

extension MCPToolRegistry {
    /// The longest canvas side, and the most pixels one canvas (or an export) may have (`DocumentLimits`).
    static let canvasSideLimit = DocumentLimits.maxSide
    static let canvasPixelBudget = DocumentLimits.maxSurfacePixels
    /// Output pixels per document pixel export_image accepts.
    static let exportScaleRange = 0.05...4.0

    static let documentTools: [MCPToolEntry] = [
        tool("list_documents", title: "List open documents",
             description: "Lists the open document tabs: index, tab and document ids, title, whether it is current, canvas size, and unsaved changes.",
             targetsDocument: false, effect: .readOnly, handler: listDocuments),
        tool("get_document", title: "Get document",
             description: "Describes a document: canvas, format and files, the layer tree, selection, guides, undo state, palette, and capabilities (which edits can run now, and what blocks them). Each layer reports its own locks and effective_locks (its folders' too). detail full adds each layer's box, content bounds, effects, text, shape, adjustment, smart-object and mask details.",
             properties: ["detail": MCPSchema.enumString("Detail per layer.", ["summary", "full"], default: "summary")],
             effect: .readOnly, handler: getDocument),
        tool("get_app_info", title: "Get app info",
             description: "Reports Compositor's version, MCP endpoint, limits, Agent folder, formats and features, and whether macOS lets it into each protected location (folder_access). Each is granted, denied, not_determined (a permission prompt is waiting) or absent; folder_access_detail names denied or waiting providers and volumes. Locations not checked yet are probed now, within about two seconds.",
             targetsDocument: false, effect: .readOnly, handler: getAppInfo),
        tool("select_document", title: "Select document",
             description: "Switches the visible document tab.",
             properties: ["document": MCPSchema.documentSelector("The document to show.")],
             required: ["document"], targetsDocument: false, effect: .additive(idempotent: true), handler: selectDocument),
        tool("new_document", title: "New document",
             description: "Creates a document in a new tab and makes it current, with one layer, 'Layer 1', transparent or filled with 'fill'. It counts as unsaved; 'name' titles it until it is saved.",
             properties: [
                 "width": MCPSchema.int("Canvas width.", min: 1, max: canvasSideLimit, default: 1920),
                 "height": MCPSchema.int("Canvas height.", min: 1, max: canvasSideLimit, default: 1080),
                 "resolution": MCPSchema.num("Pixels per inch.", min: 1, max: 9600, default: 72),
                 "name": MCPSchema.str("Title (default 'Untitled N')."),
                 "fill": MCPSchema.color("Fill for the first layer (default transparent)."),
             ],
             targetsDocument: false, effect: .additive(idempotent: false), handler: newDocument),
        tool("open_document", title: "Open document",
             description: "Opens a .comp project, a Photoshop .psd or .psb (8-bit RGB) or an image (PNG, JPEG, HEIC, TIFF, camera raw, SVG as pixels) in a new tab, without dialogs. What Compositor converted in a PSD is listed in conversions. A file already open returns its tab with already_open: true. The file itself is never changed: a PSD or image document has no project file until save_document_as.",
             properties: [
                 "path": MCPSchema.str("The file; a path with no extension is also tried with .comp."),
                 "select": MCPSchema.bool("Make it the current tab.", default: true),
             ],
             required: ["path"], targetsDocument: false, effect: .additive(idempotent: true), handler: openDocument),
        tool("save_document", title: "Save document",
             description: "Saves the document to its own file (the .comp it was opened from, or the .comp/.psd it was last saved as) in that file's format, and marks it saved. A document without one (new, duplicated, or opened from a Photoshop file or image) fails with a hint to use save_document_as, so an original is never replaced. A .psd follows save_document_as's allow_lossy rule and returns its warnings.",
             properties: ["allow_lossy": allowLossySchema],
             effect: .destructive(idempotent: true), handler: saveDocument),
        tool("save_document_as", title: "Save document as",
             description: "Saves the document to a file: a Compositor project (.comp), which keeps everything, or a layered Photoshop file (.psd). The format comes from 'format' or the path's extension (a path with neither gets '.comp'). Never replaces an existing file unless overwrite is true, the Photoshop file the document was opened from included. With set_as_current (the default) the document now lives at that path in that format (save_document writes it again) and is marked saved; false writes a copy and leaves the document as it was. A Photoshop save returns 'warnings', what the file holds differently from the document; lossy ones (an adjustment Photoshop lacks written as pixels, a clipping applied to pixels or left out, a curve resampled, a shape saved as pixels or a plain path, alpha channels or an adjustment's vector mask left out) refuse the save (guard lossy, listed in details.warnings, nothing written) unless allow_lossy is true.",
             properties: [
                 "path": MCPSchema.str("Where to save: absolute, ~/…, or relative to the Agent folder, e.g. 'work/hero.comp'."),
                 "format": MCPSchema.enumString("File format. Defaults from the path's extension, else comp.", ["comp", "psd"]),
                 "overwrite": MCPSchema.bool("Replace an existing file at 'path'.", default: false),
                 "set_as_current": MCPSchema.bool("Make 'path' the document's file (Save As). false saves a copy.", default: true),
                 "allow_lossy": allowLossySchema,
             ],
             required: ["path"], effect: .destructive(idempotent: false), handler: saveDocumentAs),
        tool("export_image", title: "Export image",
             description: "Renders the composite, or a region of it, to a PNG or JPEG file, resized by 'scale' and scaled down to fit 'max_size'.",
             properties: [
                 "path": MCPSchema.str("Output path; its extension sets the format unless 'format' does."),
                 "format": MCPSchema.enumString("Output format (default from the extension).", ["png", "jpeg"]),
                 "quality": MCPSchema.num("JPEG quality.", min: 0, max: 1, default: MCPRenderOptions.defaultQuality),
                 "region": MCPSchema.rect("Part of the canvas to export (default all)."),
                 "scale": MCPSchema.num("Output pixels per document pixel.",
                                        min: exportScaleRange.lowerBound, max: exportScaleRange.upperBound, default: 1),
                 "max_size": MCPSchema.int("Longest side of the file; larger results scale down.",
                                           min: MCPRenderOptions.maxSizeRange.lowerBound, max: canvasSideLimit),
                 "background": MCPSchema.enumString("Behind transparent pixels; default transparent (PNG) or white (JPEG).",
                                                    MCPRender.Background.allCases.map(\.rawValue)),
                 "overwrite": MCPSchema.bool("Replace an existing file at 'path'.", default: false),
             ],
             required: ["path"], effect: .destructive(idempotent: true), handler: exportImage),
        tool("close_document", title: "Close document",
             description: "Closes a document's tab; one with unsaved changes is refused (guard unsaved_changes) unless discard_changes is true. Closing the last tab leaves an empty one.",
             properties: ["discard_changes": MCPSchema.bool("Close despite unsaved changes, losing them.", default: false)],
             effect: .destructive(idempotent: false), handler: closeDocument),
        tool("duplicate_document", title: "Duplicate document",
             description: "Copies the document into a new tab and makes it current: the same canvas, layers, guides and selection under new ids, with no file and no undo history (it counts as unsaved).",
             properties: ["name": MCPSchema.str("The copy's title.")],
             effect: .additive(idempotent: false), handler: duplicateDocument),
        tool("revert_document", title: "Revert document",
             description: "Reloads the document from its file in the same tab, dropping every change and the undo history. Unsaved changes are refused (guard unsaved_changes) unless discard_changes is true; a PSD or image document gets a new document_id.",
             properties: ["discard_changes": MCPSchema.bool("Revert despite unsaved changes, losing them.", default: false)],
             effect: .destructive(idempotent: false), handler: revertDocument),
        tool("settle_pending_edits", title: "Settle pending edits",
             description: "Commits (mode commit) or cancels an edit in progress in the app that blocks tools: a transform, typed text, a crop, gradient, lasso or shape, a filter or adjustment dialog, moved pixels. It also dismisses renames, pickers and error alerts. Returns settled, failed [{edit, message}] and blocking_reason; each committed edit is its own undo step. Text or a crop that fails stays open; imports and long operations are left to finish.",
             properties: ["mode": MCPSchema.enumString("Keep or throw away the pending edits.", ["commit", "cancel"])],
             required: ["mode"], effect: .destructive(idempotent: false), handler: settlePendingEdits),
    ]

    // MARK: Reading

    static func listDocuments(_ ctx: MCPCallContext) -> CallTool.Result {
        ok(["tabs": .array(ctx.workspace.tabs.map { MCPValues.tab($0, in: ctx.workspace) })])
    }

    static func getDocument(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let full: Bool
        switch try ctx.args.optionalString("detail").map(normalized) ?? "summary" {
        case "summary": full = false
        case "full": full = true
        default: throw MCPToolError.invalidArgument("detail must be summary or full.")
        }
        var out: [String: Value] = ["tab": MCPValues.tab(ctx.tab, in: ctx.workspace)]
        guard let document = ctx.session.document else {
            out["document"] = .null
            out["note"] = .string("No document in this tab. Create one with new_document (or open_document).")
            return ok(out)
        }
        let bounds = full ? try await contentBounds(of: document) : [:]
        out["document"] = MCPValues.documentDetail(ctx.session, document, full: full, contentBounds: bounds)
        return ok(out)
    }

    /// Where each layer's non-transparent pixels lie, as document-space boxes scanned off the main actor: a layer by
    /// its own pixels, a folder as the union of what it shows (its visible contents, inside visible folders; a hidden
    /// folder still reports what it would show). Layers that draw nothing are left out.
    static func contentBounds(of document: CanvasDocument) async throws -> [UUID: CGRect] {
        let jobs = document.layers.compactMap { layer in layer.asset.map { (id: layer.id, asset: $0, transform: layer.transform) } }
        let found = try await Task.detached(priority: .userInitiated) {
            try jobs.map { job -> (id: UUID, box: CGRect?) in
                let image = job.asset.image
                let box = try ContentBounds.pixelBounds(of: image).map {
                    MCPRender.documentBox(ofPixels: $0, transform: job.transform, width: image.width, height: image.height)
                }
                return (job.id, box)
            }
        }.value
        let layers = Dictionary(document.layers.map { ($0.id, (parent: $0.parentID, visible: $0.isVisible)) },
                                uniquingKeysWith: { first, _ in first })
        var bounds: [UUID: CGRect] = [:]
        for (id, box) in found {
            guard let box else { continue }
            bounds[id] = bounds[id].map { $0.union(box) } ?? box
            // What a hidden layer or folder holds doesn't show in the folders around it.
            var shows = layers[id]?.visible ?? false
            var parent = layers[id]?.parent ?? nil
            var depth = 0
            while shows, let folder = parent, depth < 64 {
                bounds[folder] = bounds[folder].map { $0.union(box) } ?? box
                shows = layers[folder]?.visible ?? false
                parent = layers[folder]?.parent ?? nil
                depth += 1
            }
        }
        return bounds
    }

    static func getAppInfo(_ ctx: MCPCallContext) async -> CallTool.Result {
        let info = Bundle.main.infoDictionary ?? [:]
        let access = await FolderAccess.currentAccess()
        let endpoint = endpointInfo(MCPEndpointFile.read(at: MCPSettings.endpointFileURL), pid: getpid())
        return ok([
            "name": .string("Compositor"),
            "version": .object([
                "app": .string(info["CFBundleShortVersionString"] as? String ?? "1.0"),
                "build": .string(info["CFBundleVersion"] as? String ?? ""),
            ]),
            "endpoint": endpoint,
            "limits": .object([
                "max_documents": .int(MCPSettings.maxTabs),
                "max_queued_calls": .int(MCPSettings.maxQueuedCalls),
                "max_canvas_side": .int(canvasSideLimit),
                "max_pixels": .int(canvasPixelBudget),
                "document_pixel_budget": .int(DocumentLimits.documentPixelBudget),
                "max_layers": .int(LayerLimitError.maximum),
                "undo_steps": .int(ctx.session.history.entryLimit),
                "render_max_size": .int(MCPRenderOptions.maxSizeRange.upperBound),
                "export_scale": .object(["min": .double(exportScaleRange.lowerBound), "max": .double(exportScaleRange.upperBound)]),
                "sample_points": .int(MCPRenderOptions.maxSamplePoints),
            ]),
            "documents_open": .int(ctx.workspace.tabs.count),
            "agent_folder": .string(MCPSettings.agentRootURL.path),
            "logs": logsInfo(CompositorLog.active.status),
            "features": .object([
                "open": .array(["comp", "psd", "psb", "png", "jpeg", "heic", "tiff", "raw", "svg"].map { .string($0) }),
                "save": .array([.string("comp"), .string("psd")]),
                "export": .array([.string("png"), .string("jpeg")]),
                "photoshop_save": .bool(true),
                "tool_count": .int(tools.count),
            ]),
            "folder_access": .object(Dictionary(uniqueKeysWithValues: access.map { ($0.key.rawValue, .string($0.value.state.rawValue)) })),
            "folder_access_detail": .object(Dictionary(uniqueKeysWithValues: access.compactMap { root, found -> (String, Value)? in
                guard !found.deniedFolders.isEmpty || !found.pendingFolders.isEmpty else { return nil }
                return (root.rawValue, .object(["denied_folders": .array(found.deniedFolders.map { .string($0) }),
                                                "pending_folders": .array(found.pendingFolders.map { .string($0) })]))
            })),
        ])
    }

    /// get_app_info's `logs`: whether the diagnostic log is on, whether it's verbose, and its folder (docs/logging.md);
    /// never what it holds.
    static func logsInfo(_ status: CompositorLog.Status) -> Value {
        .object(["enabled": .bool(status.isEnabled), "verbose": .bool(status.isVerbose),
                 "directory": status.directory.map { .string($0.path) } ?? .null])
    }

    /// get_app_info's `endpoint`: what `record` publishes when `pid` (this process) wrote it, else null (the server
    /// isn't running, or another Compositor holds the file). `auth` says whether requests need the access token; the
    /// token itself, and where it is kept, are never reported.
    static func endpointInfo(_ record: MCPEndpointRecord?, pid: Int32) -> Value {
        guard let record, record.pid == pid else { return .null }
        return .object([
            "url": .string(record.url),
            "port": .int(Int(record.port)),
            "transport": .string(record.transport),
            "protocol": .string(record.protocol),
            "auth": .string(record.auth ?? MCPEndpointRecord.noAuth),
        ])
    }

    // MARK: Tabs

    static func selectDocument(_ ctx: MCPCallContext) throws -> CallTool.Result {
        guard ctx.args.has("document") else {
            throw MCPToolError.invalidArgument("Missing 'document': which document to show.", hint: "list_documents shows the open tabs.")
        }
        let workspace = ctx.workspace
        if workspace.current !== ctx.tab {
            try requireSwitch(workspace)
            workspace.select(ctx.tab.id)
        }
        return ok(["index": .int(ctx.tabIndex), "tab_id": .string(ctx.tab.id.uuidString), "title": .string(ctx.tab.title)])
    }

    static func newDocument(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let width = try ctx.args.int("width", default: 1920)
        let height = try ctx.args.int("height", default: 1080)
        guard (1...canvasSideLimit).contains(width), (1...canvasSideLimit).contains(height) else {
            throw MCPToolError.invalidArgument("width and height must be within 1–\(canvasSideLimit) pixels.")
        }
        let resolution = try ctx.args.double("resolution", default: 72)
        guard (1...9600).contains(resolution) else { throw MCPToolError.invalidArgument("resolution must be 1–9600 pixels per inch.") }
        let name = try documentName(ctx.args)
        let fill = try ctx.args.color("fill")
        if fill != nil, width * height > canvasPixelBudget {
            throw MCPToolError(.preconditionFailed, "A filled canvas is limited to \(DocumentLimits.maxSurfaceMegapixels) megapixels; \(width)×\(height) is larger.",
                               hint: "Leave out 'fill', or make the canvas smaller.", guard: "pixel_budget")
        }
        let workspace = ctx.workspace
        /// Whether the lone idle empty tab takes the document; otherwise a new tab must fit and the current one let go.
        func reusesEmptyTab() throws -> Bool {
            let empty = workspace.current.session
            if workspace.tabs.count == 1, empty.document == nil, empty.canStartProjectOperation, !workspace.isManaging { return true }
            try MCPGuards.requireTabCapacity(workspace)
            try requireSwitch(workspace)
            return false
        }
        _ = try reusesEmptyTab()
        var fillAsset: ImportedImage?
        if let fill {
            fillAsset = try await Task.detached(priority: .userInitiated) { try solidImage(width: width, height: height, color: fill) }.value
        }
        // Checked again: the app may have opened or switched tabs while the fill was drawn.
        let tab: ProjectTab
        if try reusesEmptyTab() {
            tab = workspace.current
        } else {
            workspace.current.session.commitTransform()
            tab = workspace.addTab(reuseEmpty: false)
        }
        let session = tab.session
        session.clearProject()
        // One step, as File > New makes: the canvas, its resolution and its fill.
        session.beginEdit("New Canvas")
        session.createDocument(width: width, height: height, emptyLayer: true)
        session.document?.resolution = resolution
        if let fillAsset, let index = session.document?.layers.firstIndex(where: { $0.id == session.activeLayerID }) {
            session.document?.layers[index].asset = fillAsset
        }
        session.endEdit()
        if let name { tab.defaultName = name }
        return ok([
            "document_id": session.document.map { .string($0.id.uuidString) } ?? .null,
            "tab_id": .string(tab.id.uuidString),
            "tab_index": .int(MCPValues.tabIndex(tab, in: workspace)),
            "title": .string(tab.title),
            "active_layer_id": session.activeLayerID.map { .string($0.uuidString) } ?? .null,
            "width": .int(width),
            "height": .int(height),
            "resolution": .double(resolution),
            "undo": MCPValues.undo(session, recorded: true),
        ])
    }

    static func openDocument(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        var url = try await MCPPaths.resolveReachable(try ctx.args.string("path"))
        var found = try await MCPPaths.exists(url)
        if !found, url.pathExtension.isEmpty, try await MCPPaths.exists(url.appendingPathExtension("comp")) {
            url.appendPathExtension("comp")
            found = true
        }
        guard found else {
            throw MCPToolError(.notFound, "No such file: \(url.path)",
                               hint: "Relative paths resolve inside the Agent folder; list_files shows what is there.",
                               details: ["path": .string(url.path)])
        }
        let select = try ctx.args.bool("select", default: true)
        let workspace = ctx.workspace
        let existing = workspace.tab(showing: url)
        if existing == nil {
            let empty = workspace.current.session
            let replacesEmpty = workspace.tabs.count == 1 && empty.document == nil && empty.canStartProjectOperation && !workspace.isManaging
            if !replacesEmpty { try MCPGuards.requireTabCapacity(workspace) }
        }
        if select, existing !== workspace.current { try requireSwitch(workspace) }
        // Checked again once the file is read: the app may have opened tabs or begun an edit meanwhile.
        let recheck = { (replacesEmpty: Bool) throws in
            if !replacesEmpty { try MCPGuards.requireTabCapacity(workspace) }
            if select { try requireSwitch(workspace) }
        }
        let opened: (tab: ProjectTab, conversions: [PSDConversion])
        do { opened = try await workspace.openDocument(at: url, select: select, validate: recheck) } catch { throw openFailure(error, url: url) }
        let tab = opened.tab
        return ok([
            "path": .string(url.path),
            "already_open": .bool(existing != nil),
            "document_id": tab.session.document.map { .string($0.id.uuidString) } ?? .null,
            "tab_id": .string(tab.id.uuidString),
            "tab_index": .int(MCPValues.tabIndex(tab, in: workspace)),
            "title": .string(tab.title),
            "format": .string(tab.session.documentFormat.rawValue),
            "current": .bool(workspace.current === tab),
            "conversions": conversions(opened.conversions),
        ])
    }

    static func closeDocument(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let tab = ctx.tab, session = tab.session, workspace = ctx.workspace
        let discard = try ctx.args.bool("discard_changes", default: false)
        let unsaved = session.document != nil && session.isModified
        guard !unsaved || discard else {
            throw MCPToolError(.preconditionFailed, "'\(tab.title)' has unsaved changes; refusing to lose work.",
                               hint: "Save it with save_document or save_document_as first, or pass discard_changes: true to close it without saving.",
                               guard: "unsaved_changes")
        }
        try requireIdleWorkspace(workspace)
        // An edit still in progress (a transform being dragged, say) is unsaved work too.
        if !discard, session.document != nil { try MCPGuards.requireEditable(session) }
        try MCPGuards.requireProjectOperation(session)
        let documentID = session.document?.id
        workspace.removeTab(tab.id)
        return ok([
            "closed": .bool(true),
            "tab_id": .string(tab.id.uuidString),
            "document_id": documentID.map { .string($0.uuidString) } ?? .null,
            "discarded_changes": .bool(unsaved),
            "remaining_tabs": .int(workspace.tabs.count),
            "current_tab_index": .int(MCPValues.tabIndex(workspace.current, in: workspace)),
        ])
    }

    static func duplicateDocument(_ ctx: MCPCallContext) throws -> CallTool.Result {
        let document = try ctx.editableDocument()
        let name = try documentName(ctx.args) ?? "\(ctx.tab.title) copy"
        let workspace = ctx.workspace
        try MCPGuards.requireTabCapacity(workspace)
        try requireSwitch(workspace)
        workspace.current.session.commitTransform()
        let tab = workspace.addTab(reuseEmpty: false)
        tab.session.installCopy(of: document, activeLayerID: ctx.session.activeLayerID)
        tab.defaultName = name
        return ok([
            "document_id": tab.session.document.map { .string($0.id.uuidString) } ?? .null,
            "source_document_id": .string(document.id.uuidString),
            "tab_id": .string(tab.id.uuidString),
            "tab_index": .int(MCPValues.tabIndex(tab, in: workspace)),
            "title": .string(tab.title),
            "layer_count": .int(document.layers.count),
            "undo": MCPValues.undo(tab.session, recorded: false),
        ])
    }

    static func revertDocument(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let tab = ctx.tab, session = tab.session
        _ = try ctx.document()
        let discard = try ctx.args.bool("discard_changes", default: false)
        guard let url = session.projectURL ?? session.sourceURL else {
            throw MCPToolError(.preconditionFailed, "'\(tab.title)' has never been saved, so there is no file to revert to.",
                               hint: "Use undo to step back, or close_document with discard_changes: true.", guard: "project_file")
        }
        guard !session.isModified || discard else { throw unsavedChanges(tab, reloading: url) }
        let revision = session.history.revisionID
        // The document's own file may be somewhere macOS guards: checked before it's looked at.
        guard try await MCPPaths.exists(url) else {
            throw MCPToolError(.notFound, "The file '\(tab.title)' came from is gone: \(url.path)", details: ["path": .string(url.path)])
        }
        try requireIdleWorkspace(ctx.workspace)
        try MCPGuards.requireEditable(session)
        // Checking the file let the app run: an edit made meanwhile is unsaved work too.
        let unsaved = session.isModified || session.history.revisionID != revision
        guard !unsaved || discard else { throw unsavedChanges(tab, reloading: url) }
        let conversions: [PSDConversion]
        do {
            conversions = try await MCPGuards.withProjectBusy(session) { try await ctx.workspace.revertDocument(tab) }
        } catch { throw openFailure(error, url: url) }
        return ok([
            "path": .string(url.path),
            "document_id": session.document.map { .string($0.id.uuidString) } ?? .null,
            "tab_id": .string(tab.id.uuidString),
            "tab_index": .int(ctx.tabIndex),
            "format": .string(session.documentFormat.rawValue),
            "discarded_changes": .bool(unsaved),
            "conversions": self.conversions(conversions),
            "undo": MCPValues.undo(session, recorded: false),
        ])
    }

    /// save_document's refusal for a document without a file of its own (guard `project_file`).
    private static func noFileOfItsOwn(_ ctx: MCPCallContext) -> MCPToolError {
        let origin = ctx.session.sourceURL.map { " It was opened from \($0.lastPathComponent), which is left untouched." } ?? ""
        return MCPToolError(.preconditionFailed, "'\(ctx.tab.title)' has no file of its own yet.\(origin)",
                            hint: "Call save_document_as with a .comp or .psd path; replacing the file it was opened from takes overwrite: true.",
                            guard: "project_file")
    }

    /// revert_document's refusal to throw away unsaved changes (guard `unsaved_changes`).
    private static func unsavedChanges(_ tab: ProjectTab, reloading url: URL) -> MCPToolError {
        MCPToolError(.preconditionFailed, "'\(tab.title)' has unsaved changes; refusing to lose work.",
                     hint: "Pass discard_changes: true to throw them away and reload \(url.lastPathComponent).", guard: "unsaved_changes")
    }

    static func settlePendingEdits(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let commit: Bool
        switch normalized(try ctx.args.string("mode")) {
        case "commit": commit = true
        case "cancel": commit = false
        default: throw MCPToolError.invalidArgument("mode must be commit or cancel.")
        }
        let session = ctx.session
        if session.isProjectBusy || session.isImporting {
            throw MCPToolError(.busy, MCPGuards.blockingReason(session) ?? "Another operation is still running.",
                               hint: "Imports and long operations finish on their own; wait, then retry.", guard: "can_start_project_operation")
        }
        let settlement = await session.settlePendingEdits(commit: commit)
        return ctx.mutated([
            "mode": .string(commit ? "commit" : "cancel"),
            "settled": .array(settlement.settled.map { .string($0) }),
            "failed": .array(settlement.failed.map { .object(["edit": .string($0.edit), "message": .string($0.message)]) }),
            "can_edit_layers": .bool(session.canEditLayers),
            "blocking_reason": MCPGuards.blockingReason(session).map { .string($0) } ?? .null,
        ])
    }

    // MARK: Saving

    static func saveDocument(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        if ctx.args.has("path") {
            throw MCPToolError.invalidArgument("save_document writes the document's own file and takes no path.",
                                               hint: "Use save_document_as to save to a path.")
        }
        let session = ctx.session
        _ = try ctx.document()
        let allowLossy = try ctx.args.bool("allow_lossy", default: false)
        guard var url = session.projectURL else { throw noFileOfItsOwn(ctx) }
        var format = session.documentFormat
        try requireSavable(session)
        for attempt in 1...3 {
            // The document's own file may be somewhere macOS guards: checked like any path.
            try await MCPPaths.checkForWriting(url, overwrite: true)
            // Checked again: the app may have started an edit while access was checked, which must not be saved half-done.
            try requireSavable(session)
            // A Save As that finished meanwhile moved the document to another file, maybe in another format: that is the
            // document's own file now, so it's the one checked and written, never the old one.
            guard let current = session.projectURL else { throw noFileOfItsOwn(ctx) }
            if current == url, session.documentFormat == format { break }
            guard attempt < 3 else {
                throw MCPToolError(.busy, "'\(ctx.tab.title)' kept moving to another file while it was being saved.",
                                   hint: "Retry save_document once the app's saves have finished.", guard: "can_start_project_operation")
            }
            url = current
            format = session.documentFormat
        }
        try MCPPaths.createParentFolder(of: url)
        let report = try await saveFile(ctx.tab, to: url, format: format, adopt: true, allowLossy: allowLossy, title: ctx.tab.title)
        var result: [String: Value] = ["path": .string(url.path), "format": .string(format.rawValue), "saved": .bool(true)]
        if let report { result["warnings"] = warnings(report.warnings) }
        return ok(result)
    }

    static func saveDocumentAs(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let session = ctx.session
        _ = try ctx.document()
        var url = try await MCPPaths.resolveReachable(try ctx.args.string("path"))
        let format = try saveFormat(ctx.args, url: &url)
        let overwrite = try ctx.args.bool("overwrite", default: false)
        let setAsCurrent = try ctx.args.bool("set_as_current", default: true)
        let allowLossy = try ctx.args.bool("allow_lossy", default: false)
        try requireSavable(session)
        // Saving over the document's own file is an ordinary save, not an overwrite. The Photoshop file or image it was
        // opened from (`sourceURL`) is not its own file: replacing that takes overwrite.
        let isOwnFile = await MCPPaths.isSameFile(url, as: session.projectURL)
        try await MCPPaths.checkForWriting(url, overwrite: overwrite || isOwnFile)
        // Checked again: the app may have started an edit while access was checked, which must not be saved half-done.
        try requireSavable(session)
        try MCPPaths.createParentFolder(of: url)
        let report = try await saveFile(ctx.tab, to: url, format: format, adopt: setAsCurrent, allowLossy: allowLossy, title: ctx.tab.title)
        var result: [String: Value] = [
            "path": .string(url.path),
            "format": .string(format.rawValue),
            "saved": .bool(true),
            "set_as_current": .bool(setAsCurrent),
            "title": .string(ctx.tab.title),
            "is_modified": .bool(session.isModified),
        ]
        if let report { result["warnings"] = warnings(report.warnings) }
        return ok(result)
    }

    /// A save may start (`requireProjectOperation`) and nothing the app has open is half-done in the document: a free
    /// transform (a floating selection cut out onto a layer of its own, an Option-drag duplicate), a crop frame, a
    /// gradient, moved pixels, or an open undo edit (an opacity drag). Saved then, the file would hold the half-done
    /// state while the document is marked saved at its start; the app's own Save commits a transform first, but an
    /// agent's call doesn't settle the owner's edits behind their back. A batch's own edit, which its steps run
    /// inside, isn't the app's. Fails with `guard: "can_edit_layers"`, pointing at settle_pending_edits.
    private static func requireSavable(_ session: EditorSession) throws {
        try MCPGuards.requireProjectOperation(session)
        let appEdits = session.history.editDepth - (EditorSession.runsAgentBatchStep ? 1 : 0)
        guard session.transformEdit != nil || session.cropRect != nil || session.gradientEdit != nil || session.pixelMove != nil
                || appEdits > 0 else { return }
        let reason = MCPGuards.blockingReason(session)
            ?? (session.opacityEditLayerID != nil ? "A layer's opacity is being changed in the app." : "An edit is still open in the app.")
        throw MCPToolError(.preconditionFailed, reason + " Saving now would write it half-done.",
                           hint: "Commit or cancel it with settle_pending_edits (or finish it in Compositor), then retry.",
                           guard: "can_edit_layers")
    }

    static let allowLossySchema = MCPSchema.bool(
        "For a .psd: write what Photoshop can't hold exactly as an approximation (listed in 'warnings' with lossy: true) instead of refusing the save.",
        default: false)

    /// The format save_document_as writes: `format`, else the path's extension, else comp. A path without a known
    /// extension gets the format's; an explicit format must agree with a known extension.
    private static func saveFormat(_ args: Args, url: inout URL) throws -> ProjectFileFormat {
        let ext = url.pathExtension.lowercased()
        // Compositor reads Large Documents but writes version-1 Photoshop files, which a .psb name would misdescribe.
        if ext == "psb" {
            throw MCPToolError.invalidArgument("Compositor writes Photoshop files as .psd (version 1), not .psb.",
                                               hint: "Give the path a .psd extension; the document is within a .psd's 30,000 pixels a side.")
        }
        let byExtension: ProjectFileFormat? = ext == "comp" ? .comp : ext == "psd" ? .psd : nil
        var format = byExtension ?? .comp
        if let name = try args.optionalString("format") {
            switch normalized(name) {
            case "comp": format = .comp
            case "psd", "photoshop": format = .psd
            default: throw MCPToolError.invalidArgument("format must be comp or psd.")
            }
            if let byExtension, byExtension != format {
                throw MCPToolError.invalidArgument("The path ends in .\(ext) but format is \(format.rawValue).",
                                                   hint: "Leave out 'format', or give the path a .\(format.rawValue) extension.")
            }
        }
        if byExtension == nil { url.appendPathExtension(format.rawValue) }
        return format
    }

    /// Saves `session`'s document at `url` as `format`, busy throughout so no edit lands between the snapshot and
    /// marking it saved. `adopt` makes `url` the document's file, in that format (Save As); otherwise a copy is written
    /// and the document is left as it was. A Photoshop file returns its report; one with lossy items is refused, with
    /// nothing written, unless `allowLossy`. A project returns nil.
    private static func saveFile(_ tab: ProjectTab, to url: URL, format: ProjectFileFormat, adopt: Bool,
                                 allowLossy: Bool, title: String) async throws -> PSDWriteReport? {
        let session = tab.session, controller = tab.controller
        // A Save from the menu still writing in the background finishes first, so the two never write at once.
        await controller.finishWriting()
        let started = ContinuousClock.now, kind = DocumentLog.saveKind(to: url, current: session.projectURL, adopts: adopt)
        let saved = try await MCPGuards.withProjectBusy(session) {
            var report: PSDWriteReport?
            switch format {
            case .comp:
                guard let snapshot = session.projectSnapshot() else {
                    throw MCPToolError(.internalError, "The document could not be prepared for saving.")
                }
                let quickLook = await ImageExporter.shared.quickLookImages(snapshot)
                // Written as the app's own save, so the project's watch doesn't take it for another app's change.
                try await controller.savingProject(to: url, adopt: adopt) {
                    try await ProjectStore.shared.save(snapshot, to: url, quickLook: quickLook)
                    if adopt { adoptFile(session, url: url, format: format) }
                }
            case .psd:
                report = try await writePhotoshop(session, to: url, allowLossy: allowLossy, title: title)
                if adopt {
                    adoptFile(session, url: url, format: format)
                    await controller.syncProjectWatch()
                }
            }
            return report
        }
        DocumentLog.saved(url, format: format, kind: kind, via: "mcp", report: saved, startedAt: started)
        return saved
    }

    /// Makes `url`, in `format`, the document's file, the document as it is marked saved.
    private static func adoptFile(_ session: EditorSession, url: URL, format: ProjectFileFormat) {
        session.projectURL = url
        session.documentFormat = format
        session.history.markSaved()
    }

    /// Writes `session`'s document as a Photoshop file at `url`. Unless `allowLossy`, the writer's plan is checked first
    /// and a document with lossy items refused (guard lossy) before anything is written.
    private static func writePhotoshop(_ session: EditorSession, to url: URL, allowLossy: Bool,
                                       title: String) async throws -> PSDWriteReport {
        guard let request = session.psdWriteRequest() else {
            throw MCPToolError(.internalError, "The document could not be prepared for saving.")
        }
        var options = PSDWriteOptions()
        options.allowLossy = true
        options.collapsedGroupIDs = session.collapsedGroupIDs
        do {
            // Planned once: checked for lossy items, then written as planned.
            let plan = try await PSDExporter.shared.plan(request, options: options)
            if !allowLossy {
                let lossy = plan.warnings.filter(\.lossy)
                if !lossy.isEmpty {
                    let layers = Set(lossy.map(\.layerName)).count
                    throw MCPToolError(.preconditionFailed,
                        "Photoshop can't hold everything in '\(title)': saving it as a .psd would change \(layers == 1 ? "a layer" : "\(layers) layers").",
                        hint: "Pass allow_lossy: true to save it with these changes (the result lists them), or save a .comp project, which keeps everything.",
                        guard: "lossy", details: ["warnings": warnings(lossy)])
                }
            }
            return try await PSDExporter.shared.export(plan, to: url)
        } catch let error as PSDWriteError {
            throw photoshopFailure(error, url: url)
        }
    }

    /// A Photoshop save's warnings as tools return them.
    private static func warnings(_ warnings: [PSDWriteWarning]) -> Value {
        .array(warnings.map { .object(["layer": .string($0.layerName), "message": .string($0.message), "lossy": .bool($0.lossy)]) })
    }

    private static func photoshopFailure(_ error: PSDWriteError, url: URL) -> MCPToolError {
        let message = error.errorDescription ?? "The Photoshop file could not be saved."
        switch error {
        case .tooLarge:
            return MCPToolError(.preconditionFailed, message, hint: "Save a .comp project instead, which has no such limits.",
                                guard: "photoshop_limits")
        case .unsupportedAdjustment, .invalidText:
            return MCPToolError(.unsupported, message, hint: "Save a .comp project instead, which keeps everything.")
        case .sink:
            return MCPToolError(.ioError, message, hint: "Check the folder is writable, or choose another path.",
                                details: ["path": .string(url.path)])
        case .render:
            return MCPToolError(.internalError, message,
                                hint: "Retry the save; if it fails again, save a .comp project, which keeps everything.")
        }
    }

    // MARK: Exporting

    static func exportImage(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let session = ctx.session
        let document = try ctx.document()
        try MCPGuards.requireProjectOperation(session)
        var url = try await MCPPaths.resolveReachable(try ctx.args.string("path"))
        let overwrite = try ctx.args.bool("overwrite", default: false)
        let ext = url.pathExtension.lowercased()
        let named = (try ctx.args.optionalString("format") ?? ext).lowercased()
        let format: MCPRender.Format
        switch named {
        case "png", "": format = .png
        case "jpg", "jpeg": format = .jpeg
        default: throw MCPToolError.invalidArgument("Unsupported format '\(named)'; use png or jpeg (or a .png/.jpg path).")
        }
        if ext.isEmpty { url.appendPathExtension(format.fileExtension) }
        if format == .jpeg && url.pathExtension.lowercased() != "jpg" && url.pathExtension.lowercased() != "jpeg" {
            url.appendPathExtension("jpg")
        }
        let quality = try ctx.args.double("quality", default: MCPRenderOptions.defaultQuality)
        guard (0...1).contains(quality) else { throw MCPToolError.invalidArgument("quality must be 0–1.") }
        let maxSize = try ctx.args.optionalInt("max_size")
        if let maxSize, !(MCPRenderOptions.maxSizeRange.lowerBound...canvasSideLimit).contains(maxSize) {
            throw MCPToolError.invalidArgument("max_size must be \(MCPRenderOptions.maxSizeRange.lowerBound)–\(canvasSideLimit).")
        }
        let background = try MCPRenderOptions.background(ctx.args, format: format)
        let region = try exportRegion(ctx.args, in: document)
        let scale = try ctx.args.optionalDouble("scale")
        if let scale {
            guard exportScaleRange.contains(scale) else {
                throw MCPToolError.invalidArgument("scale must be \(exportScaleRange.lowerBound)–\(exportScaleRange.upperBound).")
            }
            let area = region?.size ?? document.size
            let width = scaledLength(Int(area.width), by: scale), height = scaledLength(Int(area.height), by: scale)
            guard width <= canvasSideLimit, height <= canvasSideLimit, width * height <= canvasPixelBudget else {
                throw MCPToolError(.preconditionFailed,
                                   "At scale \(scale) the image would be \(width)×\(height) pixels; exports are limited to \(canvasSideLimit) pixels per side and \(DocumentLimits.maxSurfaceMegapixels) megapixels.",
                                   hint: "Use a smaller scale or region.", guard: "pixel_budget")
            }
        }
        try await MCPPaths.checkForWriting(url, overwrite: overwrite)
        // Checked again: the app may have started an edit while access was checked, which must not be exported half-done.
        try MCPGuards.requireProjectOperation(session)
        try MCPPaths.createParentFolder(of: url)
        guard let snapshot = session.projectSnapshot() else {
            throw MCPToolError(.internalError, "The document could not be prepared for export.")
        }
        let destination = url
        let exported = try await MCPGuards.withProjectBusy(session) {
            try await Task.detached(priority: .userInitiated) {
                let raster = try await ImageExporter.shared.render(snapshot)
                var source = raster.image
                if let region {
                    guard let cropped = source.cropping(to: region) else { throw ExportError.render }
                    source = cropped
                }
                var image = source
                var factor = 1.0
                if let scale {
                    image = try resampled(image, by: scale)
                    factor = scale
                }
                if let maxSize {
                    let (fitted, fit) = try MCPRender.downscaled(image, maxSize: maxSize)
                    image = fitted
                    factor *= Double(fit)
                }
                let data = try MCPRender.encode(image, format: format, quality: quality, background: background,
                                                resolution: raster.resolution)
                try await ImageExporter.shared.write(data, to: destination)
                return MCPRender.Preview(data: data, width: image.width, height: image.height, scale: factor,
                                         sourceWidth: source.width, sourceHeight: source.height)
            }.value
        }
        DocumentLog.exported(url, format: format.rawValue, bytes: exported.data.count, width: exported.width,
                             height: exported.height, via: "mcp")
        var out: [String: Value] = [
            "path": .string(url.path),
            "format": .string(format.rawValue),
            "bytes": .int(exported.data.count),
            "width": .int(exported.width),
            "height": .int(exported.height),
            "scale": .double(exported.scale),
            "scale_x": .double(exported.scaleX),
            "scale_y": .double(exported.scaleY),
            "document_width": .int(snapshot.manifest.width),
            "document_height": .int(snapshot.manifest.height),
        ]
        if let region { out["region"] = MCPValues.rect(region) }
        return ok(out)
    }

    /// export_image's `region`: whole pixels, clamped to the canvas; nil when absent.
    private static func exportRegion(_ args: Args, in document: CanvasDocument) throws -> CGRect? {
        guard let value = args["region"] else { return nil }
        guard let rect = MCPValues.rect(from: value), rect.width > 0, rect.height > 0,
              [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy({ abs($0) <= 1_000_000 }) else {
            throw MCPToolError.invalidArgument("'region' must be {x, y, width, height} with a positive width and height.")
        }
        let area = rect.integral.intersection(CGRect(x: 0, y: 0, width: document.width, height: document.height))
        guard !area.isNull, area.width >= 1, area.height >= 1 else {
            throw MCPToolError.invalidArgument("The region lies outside the \(document.width)×\(document.height) canvas.")
        }
        return area
    }

    /// A side of `length` pixels resized by `factor`, as `resampled` sizes it.
    private nonisolated static func scaledLength(_ length: Int, by factor: Double) -> Int {
        max(1, Int((Double(length) * factor).rounded()))
    }

    /// `image` resized by `factor` with high-quality interpolation.
    private nonisolated static func resampled(_ image: CGImage, by factor: Double) throws -> CGImage {
        let width = scaledLength(image.width, by: factor), height = scaledLength(image.height, by: factor)
        guard width != image.width || height != image.height else { return image }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ExportError.render
        }
        context.interpolationQuality = .high
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw ExportError.render }
        return scaled
    }

    /// An opaque `width` × `height` layer of one sRGB color, for new_document's `fill`.
    private nonisolated static func solidImage(width: Int, height: Int, color: (red: Double, green: Double, blue: Double)) throws -> ImportedImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ExportError.render
        }
        context.setFillColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw ExportError.render }
        return ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: "Layer 1")
    }

    // MARK: Shared checks and shapes

    /// The call's `name` for a document's title, when given: blank or only spaces is `invalid_argument`.
    private static func documentName(_ args: Args) throws -> String? {
        guard let value = args["name"] else { return nil }
        guard let name = value.stringValue else { throw MCPToolError.invalidArgument("'name' must be a string.") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPToolError.invalidArgument("'name' is blank; a document's title needs a character that isn't a space.",
                                               hint: "Leave 'name' out for the default title.")
        }
        return name
    }

    /// Switching the visible tab is allowed (`ProjectWorkspace.canSwitch`); `busy` with guard `can_switch` otherwise.
    /// A free transform or crop frame in progress on the current tab also refuses it (`precondition_failed`): the
    /// switch would commit the owner's half-finished transform (or leave the crop behind), and an agent's call doesn't
    /// settle the owner's edits behind their back, as the canvas tools don't.
    private static func requireSwitch(_ workspace: ProjectWorkspace) throws {
        let session = workspace.current.session
        if session.transformEdit != nil || session.cropRect != nil {
            let reason = MCPGuards.blockingReason(session) ?? "An edit is in progress in the app."
            throw MCPToolError(.preconditionFailed, "The current document can't be switched away from right now: \(reason)",
                               hint: "Commit or cancel it with settle_pending_edits (or finish it in Compositor), then retry.",
                               guard: "can_switch")
        }
        guard !workspace.canSwitch else { return }
        let reason = MCPGuards.blockingReason(workspace.current.session) ?? "another document operation is in progress."
        throw MCPToolError(.busy, "The current document can't be switched away from right now: \(reason)",
                           hint: "Wait for it to finish (or call settle_pending_edits on it), then retry.", guard: "can_switch")
    }

    /// No open, close or save the app started is in progress (`ProjectWorkspace.isManaging`).
    private static func requireIdleWorkspace(_ workspace: ProjectWorkspace) throws {
        guard workspace.isManaging else { return }
        throw MCPToolError(.busy, "Compositor is opening, closing or saving documents.", hint: "Wait for it to finish, then retry.",
                           guard: "can_switch")
    }

    /// `[{layer, message}]`: what opening a Photoshop file converted.
    private static func conversions(_ conversions: [PSDConversion]) -> Value {
        .array(conversions.map { .object(["layer": .string($0.layerName), "message": .string($0.message)]) })
    }

    /// Why opening (or reverting to) `url` failed, as a tool error naming the path.
    private static func openFailure(_ error: Error, url: URL) -> MCPToolError {
        var failure: MCPToolError
        switch error {
        case let error as MCPToolError:
            failure = error
        case let error as PSDError:
            failure = MCPToolError(error == .truncated ? .ioError : .unsupported, error.localizedDescription)
        case let error as ImageImportError:
            switch error {
            case .unreadable:
                failure = MCPToolError(.ioError, error.localizedDescription)
            case .unsupported:
                failure = MCPToolError(.unsupported, error.localizedDescription,
                                       hint: "Compositor opens .comp projects, 8-bit RGB .psd files, and PNG, JPEG, HEIC, TIFF and camera raw images.")
            case .tooLarge:
                failure = MCPToolError(.preconditionFailed, error.localizedDescription,
                                       hint: "Compositor opens files up to \(DocumentLimits.documentBudgetMegapixels) megapixels in all and \(DocumentLimits.maxSide.formatted()) pixels a side; make it smaller first.",
                                       guard: "pixel_budget")
            }
        default:
            failure = MCPToolError.from(error)
        }
        failure.details["path"] = .string(url.path)
        return failure
    }
}
