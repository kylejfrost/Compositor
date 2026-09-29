import Foundation
import MCP

/// How tools address their targets.
///
/// **Documents** (`document` argument, optional on every document tool): absent, `null`
/// or `"@current"` is the current tab; an integer is a tab index from `list_documents`; a
/// UUID string matches a tab id or a document id (one two tabs share is `ambiguous`); any
/// other string is an exact tab title.
///
/// **Layers** (`layer` / `layers` arguments): `"@active"` is the active layer; a UUID
/// string is a layer id; otherwise the string is a layer name, or a folder path such as
/// `"Footer/Logo"`. A slash inside a name is written `\/` (and a backslash `\\`), exactly
/// as `path(of:in:)` and `get_document` spell it. A path matches from the root first,
/// then as a suffix, so `"Footer/Logo"` also finds `"Page/Footer/Logo"` when that is
/// the only match. A selector is also tried as a literal name (for a layer named
/// `Before/After` or `a\b`); when it matches more than one layer either way it is
/// `ambiguous`, listing candidates.
@MainActor
enum MCPSelectors {
    static let current = "@current"
    static let active = "@active"

    // MARK: Documents

    static func tab(_ value: Value?, in workspace: ProjectWorkspace) throws -> ProjectTab {
        guard let value, value != .null else { return workspace.current }
        let listHint = "list_documents shows the open tabs, their indexes and ids."
        if let index = integer(value) {
            guard workspace.tabs.indices.contains(index) else {
                throw MCPToolError(.notFound, "No document tab at index \(index); there are \(workspace.tabs.count).", hint: listHint)
            }
            return workspace.tabs[index]
        }
        guard let text = value.stringValue, !text.isEmpty else {
            throw MCPToolError.invalidArgument("'document' must be a tab index, a tab or document id, a tab title, or \"@current\".")
        }
        if text == current { return workspace.current }
        if let id = UUID(uuidString: text) {
            if let tab = workspace.tabs.first(where: { $0.id == id }) { return tab }
            // Tab ids are unique; a document id isn't always (the same .comp opened again after its first tab was
            // saved elsewhere, or a Finder copy of it).
            let matches = workspace.tabs.filter { $0.session.document?.id == id }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 {
                throw ambiguous(matches, "\(matches.count) open documents have the id \(text).", in: workspace,
                                hint: "Address the document by its tab_id or index instead.")
            }
            throw MCPToolError(.notFound, "No open document with id \(text).", hint: listHint)
        }
        let matches = workspace.tabs.filter { $0.title == text }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            throw ambiguous(matches, "\(matches.count) open documents are titled '\(text)'.", in: workspace,
                            hint: "Address the document by its index or id instead.")
        }
        throw MCPToolError(.notFound, "No open document titled '\(text)'.", hint: listHint)
    }

    /// `ambiguous`, listing `tabs` as candidates.
    private static func ambiguous(_ tabs: [ProjectTab], _ message: String, in workspace: ProjectWorkspace, hint: String) -> MCPToolError {
        MCPToolError(.ambiguous, message, hint: hint, details: ["candidates": .array(tabs.map { tab in
            .object([
                "index": .int(workspace.tabs.firstIndex { $0 === tab } ?? 0),
                "tab_id": .string(tab.id.uuidString),
                "document_id": tab.session.document.map { .string($0.id.uuidString) } ?? .null,
                "title": .string(tab.title),
            ])
        })])
    }

    // MARK: Layers

    static func layer(_ value: Value, in document: CanvasDocument, active activeID: UUID? = nil) throws -> ImageLayer {
        guard let text = value.stringValue, !text.isEmpty else {
            throw MCPToolError.invalidArgument("A layer selector must be a layer id, name, folder path like \"Folder/Layer\", or \"@active\".")
        }
        let hint = "get_document lists every layer's id and path."
        if text == active {
            guard let activeID, let layer = document.layers.first(where: { $0.id == activeID }) else {
                throw MCPToolError(.preconditionFailed, "There is no active layer.", hint: "Name the layer explicitly, or select one with select_layers.", guard: "active_layer")
            }
            return layer
        }
        if let id = UUID(uuidString: text) {
            guard let layer = document.layers.first(where: { $0.id == id }) else {
                throw MCPToolError(.notFound, "No layer with id \(text).", hint: hint)
            }
            return layer
        }
        let matches = layers(matching: text, in: document)
        switch matches.count {
        case 1: return matches[0]
        case 0: throw MCPToolError(.notFound, "No layer named '\(text)'.", hint: hint)
        default:
            throw MCPToolError(.ambiguous, "\(matches.count) layers match '\(text)'.",
                               hint: "Use a folder path (\"Folder/Layer\") or a layer id from details.candidates.",
                               details: ["candidates": .array(matches.reversed().map { MCPValues.candidate($0, in: document) })])
        }
    }

    /// A list of selectors (duplicates dropped, order kept), or a single selector.
    static func layers(_ value: Value, in document: CanvasDocument, active activeID: UUID? = nil) throws -> [ImageLayer] {
        guard let array = value.arrayValue else { return [try layer(value, in: document, active: activeID)] }
        guard !array.isEmpty else { throw MCPToolError.invalidArgument("The layer list is empty.") }
        var seen = Set<UUID>()
        return try array.compactMap { item in
            let layer = try layer(item, in: document, active: activeID)
            return seen.insert(layer.id).inserted ? layer : nil
        }
    }

    /// The layer's folder path from the root, e.g. `Footer/Logo`, with `/` and `\` in
    /// names escaped so the path is itself a selector for this layer.
    static func path(of layer: ImageLayer, in document: CanvasDocument) -> String {
        components(of: layer, byID: byID(document)).map(escape).joined(separator: "/")
    }

    // MARK: Matching

    private static func layers(matching selector: String, in document: CanvasDocument) -> [ImageLayer] {
        let wanted = split(selector)
        let index = byID(document)
        let paths = document.layers.map { (layer: $0, path: components(of: $0, byID: index)) }
        var matches: [ImageLayer]
        if wanted.count == 1 {
            matches = paths.filter { $0.path.last == wanted[0] }.map(\.layer)
        } else {
            let exact = paths.filter { $0.path == wanted }
            let suffix = paths.filter { $0.path.count > wanted.count && Array($0.path.suffix(wanted.count)) == wanted }
            matches = (exact.isEmpty ? suffix : exact).map(\.layer)
        }
        // The selector as a literal name, when escaping or slashes made it read differently:
        // "Before/After" or "a\b". Matching both ways is ambiguous, never a silent pick.
        if wanted != [selector] {
            let literal = document.layers.filter { $0.name == selector && !matches.map(\.id).contains($0.id) }
            matches += literal
        }
        return matches
    }

    private static func byID(_ document: CanvasDocument) -> [UUID: ImageLayer] {
        Dictionary(document.layers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Names from the root folder down to `layer`.
    private static func components(of layer: ImageLayer, byID: [UUID: ImageLayer]) -> [String] {
        var names = [layer.name]
        var parent = layer.parentID
        var steps = 0
        while let id = parent, let folder = byID[id], steps < 64 {
            names.append(folder.name)
            parent = folder.parentID
            steps += 1
        }
        return names.reversed()
    }

    private static func escape(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "/", with: "\\/")
    }

    /// Splits a path on unescaped slashes; a backslash makes the next character literal.
    private static func split(_ path: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var escaping = false
        for character in path {
            if escaping {
                current.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == "/" {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaping { current.append("\\") }
        parts.append(current)
        return parts
    }

    private static func integer(_ value: Value) -> Int? {
        if let int = value.intValue { return int }
        if let double = value.doubleValue, double.isFinite, double.rounded() == double, abs(double) < 1e9 { return Int(double) }
        return nil
    }
}
