import AppKit
import Foundation
import MCP

// MARK: - Handler plumbing

/// Everything a tool handler works with: the workspace, the tab its `document` argument
/// selected (the current tab by default), that tab's session, and the arguments.
@MainActor
struct MCPCallContext {
    let workspace: ProjectWorkspace
    let tab: ProjectTab
    let args: MCPToolRegistry.Args
    /// The tab's history point when the call began, to tell whether it recorded a step.
    let startRevision: UUID

    init(workspace: ProjectWorkspace, tab: ProjectTab, args: MCPToolRegistry.Args) {
        self.workspace = workspace
        self.tab = tab
        self.args = args
        startRevision = tab.session.history.revisionID
    }

    var session: EditorSession { tab.session }
    var tabIndex: Int { MCPValues.tabIndex(tab, in: workspace) }

    /// The tab's document; `precondition_failed` (`guard: "document"`) when none is open.
    func document() throws -> CanvasDocument { try MCPGuards.requireDocument(session) }

    /// The tab's document, once layer edits are allowed (`canEditLayers`).
    func editableDocument() throws -> CanvasDocument {
        try MCPGuards.requireEditable(session)
        return try document()
    }

    /// The layer named by the `key` selector argument (required).
    func layer(_ key: String = "layer", in document: CanvasDocument) throws -> ImageLayer {
        guard let value = args[key] else {
            throw MCPToolError.invalidArgument("Missing layer selector '\(key)'.", hint: legacyHint(for: key))
        }
        return try MCPSelectors.layer(value, in: document, active: session.activeLayerID)
    }

    /// The layer named by `key`, or nil when the argument is absent.
    func optionalLayer(_ key: String, in document: CanvasDocument) throws -> ImageLayer? {
        guard let value = args[key] else { return nil }
        return try MCPSelectors.layer(value, in: document, active: session.activeLayerID)
    }

    /// The layers named by the `key` selector list (required, at least one).
    func layers(_ key: String = "layers", in document: CanvasDocument) throws -> [ImageLayer] {
        guard let value = args[key] else {
            throw MCPToolError.invalidArgument("Missing layer list '\(key)'.", hint: legacyHint(for: key))
        }
        return try MCPSelectors.layers(value, in: document, active: session.activeLayerID)
    }

    /// A success result for a mutating tool: `fields` plus `undo: {name, count, recorded}`.
    /// `recorded` defaults to whether the tab's history moved to a new point during the call.
    func mutated(_ fields: [String: Value] = [:], recorded: Bool? = nil) -> CallTool.Result {
        var out = fields
        out["undo"] = MCPValues.undo(session, recorded: recorded ?? (session.history.revisionID != startRevision))
        return MCPToolRegistry.ok(out)
    }

    /// Points callers still using the pre-selector argument names at the new ones.
    private func legacyHint(for key: String) -> String? {
        switch key {
        case "layer" where args.has("id"): "Layers are now addressed with 'layer' (an id, name, path or \"@active\"), not 'id'."
        case "layers" where args.has("ids"): "Layers are now addressed with 'layers' (ids, names or paths), not 'ids'."
        default: nil
        }
    }
}

typealias MCPToolHandler = @MainActor (MCPCallContext) async throws -> CallTool.Result

/// A tool definition and the handler that runs it.
struct MCPToolEntry {
    let tool: Tool
    let handler: MCPToolHandler
    /// The tool takes a `document` selector; tools that don't always run against the
    /// current tab, ignoring any stray `document` value.
    let takesDocument: Bool
    /// The arguments its schema lists, plus `document` (which every tool accepts; see `takesDocument`).
    let argumentNames: Set<String>
}

/// The side effects a tool declares through its MCP annotations.
enum MCPToolEffect {
    /// Reads only; calling it again changes nothing.
    case readOnly
    /// Changes the document or app, but only additively (undoable, nothing lost).
    case additive(idempotent: Bool)
    /// May discard data or files (undoable within a document, or not at all).
    case destructive(idempotent: Bool)

    var annotations: Tool.Annotations {
        switch self {
        case .readOnly:
            Tool.Annotations(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        case .additive(let idempotent):
            Tool.Annotations(readOnlyHint: false, destructiveHint: false, idempotentHint: idempotent, openWorldHint: false)
        case .destructive(let idempotent):
            Tool.Annotations(readOnlyHint: false, destructiveHint: true, idempotentHint: idempotent, openWorldHint: false)
        }
    }
}

// MARK: - Tool registry

/// Definitions and handlers for every MCP tool, assembled from the per-domain arrays in
/// `MCPTools+<Domain>.swift`.
///
/// The app's whole document model sits behind `@MainActor` sessions, so every handler
/// runs on the main actor and can touch `EditorSession` directly. Mutating tools funnel
/// their edits through the same `beginEdit`/`endEdit` undo path the UI uses, so an
/// agent's change is one ⌘Z undo step.
@MainActor
enum MCPToolRegistry {
    /// Sent in the initialize result: a compact operating manual every agent reads before its first call (kept within
    /// 4 KB by `MCPToolListBudgetTests`). docs/mcp.md says the same at length.
    static let instructions = """
    Compositor is a macOS image editor: 8-bit RGB documents with layers, folders, masks, live text and shapes, \
    adjustment and Profile layers, effects and smart objects, and Photoshop .psd round trips. These tools drive the \
    running app, where the user may be working too.

    Start with get_app_info (version, limits, Agent folder, folder_access) and list_documents; get_document shows \
    the layer tree, get_layer one layer.

    Selectors: 'document' is a tab index, tab or document id, or exact title (default: the current tab). \
    'layer'/'layers' take a layer id, exact name, folder path "Group/Child" ("\\/" escapes a slash in a name) or \
    "@active". A selector matching several fails with ambiguous and details.candidates: use an id.

    Units: document pixels, origin top-left, y down; angles in clockwise degrees; opacity 0–1. Colors are {r, g, b} \
    in 0–1 (clamped) or "#rrggbb". Enum values are snake_case and match loosely.

    Undo: every mutating call is one undo step and returns undo {name, count, recorded}; recorded: false means \
    this call added no undo entry. run_batch runs up to 200 calls as one step; it can't hold undo, redo, run_batch, \
    settle_pending_edits or tools that open, close, switch, duplicate or revert documents, and it refuses while the \
    app holds the history. When something open in the app blocks edits (guard can_edit_layers: a transform, typed \
    text, a crop, a dialog), settle_pending_edits commits or cancels it; each settled edit may record its own step.

    Seeing: render_document, render_region and render_layer return images and change nothing; get_layer_pixels \
    returns a layer's own pixels (save_to also writes a PNG); export_image writes PNG or JPEG files. Render after \
    visual changes.

    Files: paths are absolute, ~/…, or relative to the Agent folder (list_files). Nothing replaces an existing file \
    without overwrite: true (save_document rewrites the document's own file), and close_document or revert_document \
    drop unsaved changes only with discard_changes: true. macOS guards Documents, Desktop, Downloads, iCloud Drive, \
    cloud storage and volumes: folder_access_denied (io_error) needs the owner to grant access, or the file copied to \
    the Agent folder; folder_access_pending (busy) means a permission prompt is waiting for the owner. \
    get_app_info.folder_access shows each location.

    Locks: set_layer_locks sets position, pixels, transparency and all; a folder's locks hold everything inside it \
    (get_layer reports effective_locks), and a refusal (guard layer_locked) names the holder. Layers of kind \
    placeholder are Photoshop layers kept only to write back: leave them be.

    Text stays live (set_text, set_text_style, fit_text); point text keeps its alignment anchor through edits. Call \
    check_fonts before editing imported text: a missing font is drawn with a substitute.

    Photoshop: open_document opens a .psd headlessly and lists its conversions. Save work as a new file with \
    save_document_as, never over the source template: a .comp keeps everything, and where \
    get_app_info.features.photoshop_save is true a .psd is a working Photoshop file (pass allow_lossy to accept \
    rasterized parts; read the warnings).

    Also: selections (select_rect, select_subject, modify_selection); painting and filters on a layer or its mask \
    (stroke_path, fill_selection, draw_gradient, apply_filter, apply_levels); masks (add_layer_mask); effects \
    (set_layer_effects); adjustment layers (add_adjustment_layer, set_adjustment); creative profiles (list_profiles, \
    then kind profile); shapes (add_shape); smart objects (place_smart_object); canvas and guides (resize_canvas, \
    crop, add_guide); transforms (set_layer_transform, align_layers); view (set_zoom, select_tool). Pixel, mask and \
    filter tools make their layer active.

    Failures return {ok: false, error: {code, message, guard?, hint?, details?}}: follow the hint. The server \
    listens on IPv4 loopback only (127.0.0.1).
    """

    /// The tools by domain, in the order `tools/list` gives them and docs/mcp.md documents them.
    static let domains: [(name: String, entries: [MCPToolEntry])] = [
        ("Documents", documentTools), ("Render and inspect", renderTools), ("Files", fileTools), ("Layers", layerTools),
        ("Transforms", transformTools), ("Canvas and guides", canvasTools), ("Adjustment layers", adjustmentTools),
        ("History and batches", historyTools), ("View, tools and palette", viewTools), ("Layer effects", effectTools),
        ("Selection", selectionTools), ("Painting and pixels", paintTools), ("Filters", filterTools), ("Masks", maskTools),
        ("Profiles", profileTools), ("Text and fonts", textTools), ("Shapes", shapeTools), ("Smart objects", smartObjectTools),
    ]

    static let entries: [MCPToolEntry] = domains.flatMap(\.entries)

    static let tools: [Tool] = entries.map(\.tool)

    static let entriesByName: [String: MCPToolEntry] =
        Dictionary(entries.map { ($0.tool.name, $0) }, uniquingKeysWith: { first, _ in first })

    /// Builds an entry. `targetsDocument` adds the optional `document` selector argument.
    static func tool(
        _ name: String, title: String, description: String,
        properties: [String: Value] = [:], required: [String] = [],
        targetsDocument: Bool = true, effect: MCPToolEffect,
        handler: @escaping MCPToolHandler
    ) -> MCPToolEntry {
        var properties = properties
        if targetsDocument, properties["document"] == nil { properties["document"] = MCPSchema.documentSelector }
        return MCPToolEntry(
            tool: Tool(name: name, title: title, description: description,
                       inputSchema: MCPSchema.object(properties, required: required),
                       annotations: effect.annotations),
            handler: handler,
            takesDocument: properties["document"] != nil,
            argumentNames: Set(properties.keys).union(["document"]))
    }
}

// MARK: - Dispatch

extension MCPToolRegistry {
    /// Runs a tool call against the tab its `document` argument selects. Serialized by
    /// the server so one session mutation is never interleaved with another. Every
    /// failure comes back as a result with the structured error envelope. Each call is one
    /// `tool_call` event in the diagnostic log (`MCPCallLog`).
    static func call(_ name: String, _ args: [String: Value], workspace: ProjectWorkspace) async -> CallTool.Result {
        await MCPCallLog.record(name, args) { await dispatch(name, args, workspace: workspace) }
    }

    private static func dispatch(_ name: String, _ args: [String: Value], workspace: ProjectWorkspace) async -> CallTool.Result {
        do {
            guard let entry = entriesByName[name] else {
                throw MCPToolError(.notFound, "Unknown tool '\(name)'.", hint: "tools/list shows every tool Compositor offers.")
            }
            if let unknown = unknownArgument(args, of: entry) { throw unknown }
            let arguments = Args(args)
            let tab = entry.takesDocument ? try MCPSelectors.tab(arguments["document"], in: workspace) : workspace.current
            // Each call asks macOS about a location once, however many of its paths lie there.
            return try await FolderAccess.$reachedThisCall.withValue(FolderAccess.ReachedPlaces()) {
                try await entry.handler(MCPCallContext(workspace: workspace, tab: tab, args: arguments))
            }
        } catch {
            return failure(MCPToolError.from(error))
        }
    }

    /// `invalid_argument` for the first of `args` (by name) that `entry` doesn't take, or nil when it takes them all.
    /// Refused rather than ignored, as settings patches are: a misspelled argument (set_as_curent) would otherwise
    /// silently take its default. The hint names the argument meant when one is close, or lists the tool's own.
    static func unknownArgument(_ args: [String: Value], of entry: MCPToolEntry) -> MCPToolError? {
        guard let name = args.keys.sorted().first(where: { !entry.argumentNames.contains($0) }) else { return nil }
        let tool = entry.tool.name
        let own = entry.argumentNames.subtracting(["document"]).sorted()
        let hint: String
        if let replacement = legacyArguments[name], entry.argumentNames.contains(replacement) {
            hint = "'\(name)' was replaced by '\(replacement)'."
        } else if let meant = closestArgument(to: name, in: own) {
            hint = "Did you mean '\(meant)'?"
        } else {
            hint = own.isEmpty ? "\(tool) takes no arguments but 'document'."
                : "\(tool) takes " + own.map { "'\($0)'" }.joined(separator: ", ") + "."
        }
        return MCPToolError(.invalidArgument, "\(tool) has no argument '\(name)'.", hint: hint, details: ["field": .string(name)])
    }

    /// Argument names from before layer selectors and points, and what replaced them.
    private static let legacyArguments = ["id": "layer", "ids": "layers", "center_x": "center", "center_y": "center"]

    /// The one of `names` `name` most likely misspells: the same once case, `_` and `-` are ignored, or within two
    /// edits of it; nil when none is.
    private static func closestArgument(to name: String, in names: [String]) -> String? {
        func folded(_ text: String) -> [Character] { Array(text.lowercased().filter { $0 != "_" && $0 != "-" }) }
        let target = folded(name)
        func distance(_ a: [Character], _ b: [Character]) -> Int {
            var previous = Array(0...b.count)
            for (i, x) in a.enumerated() {
                var current = [i + 1]
                for (j, y) in b.enumerated() { current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1))) }
                previous = current
            }
            return previous[b.count]
        }
        let scored = names.map { (name: $0, distance: distance(target, folded($0))) }.filter { $0.distance <= 2 }
        return scored.min { $0.distance < $1.distance }?.name
    }
}
