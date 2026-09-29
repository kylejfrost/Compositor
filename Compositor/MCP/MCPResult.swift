import Foundation
import MCP

// MARK: - Errors

/// The machine-readable class of a failed tool call, sent as `error.code`.
nonisolated enum MCPErrorCode: String, Sendable, CaseIterable {
    /// An argument is missing, has the wrong type, or is out of range.
    case invalidArgument = "invalid_argument"
    /// The tool, document, layer or file named does not exist.
    case notFound = "not_found"
    /// A selector matched more than one thing; `details.candidates` lists them.
    case ambiguous
    /// The document is not in a state that allows the call; `guard` names the check.
    case preconditionFailed = "precondition_failed"
    /// Something else is running (an import, a long operation, a full queue); retry later.
    case busy
    /// Reading or writing a file failed, or a file already exists (`details.code`).
    case ioError = "io_error"
    /// The request is understood but not supported by this version of Compositor.
    case unsupported
    /// An unexpected failure inside Compositor.
    case internalError = "internal"
}

/// A failed tool call. The MCP layer turns it into a result with `isError: true` and the
/// envelope `{"ok": false, "error": {"code", "message", "guard"?, "hint"?, "details"?}}`,
/// never a JSON-RPC failure, so the agent can read and react to it.
nonisolated struct MCPToolError: LocalizedError, Sendable {
    let code: MCPErrorCode
    let message: String
    /// What the agent can do about it, e.g. which tool to call first.
    var hint: String?
    /// The precondition that failed (e.g. `"document"`, `"can_edit_layers"`, `"max_tabs"`).
    var guardName: String?
    var details: [String: Value]

    init(_ code: MCPErrorCode, _ message: String, hint: String? = nil, guard guardName: String? = nil, details: [String: Value] = [:]) {
        self.code = code
        self.message = message
        self.hint = hint
        self.guardName = guardName
        self.details = details
    }

    var errorDescription: String? { message }

    /// The `error` object of the failure envelope.
    var value: Value {
        var error: [String: Value] = ["code": .string(code.rawValue), "message": .string(message)]
        if let guardName { error["guard"] = .string(guardName) }
        if let hint { error["hint"] = .string(hint) }
        if !details.isEmpty { error["details"] = .object(details) }
        return .object(error)
    }

    static func invalidArgument(_ message: String, hint: String? = nil) -> MCPToolError {
        MCPToolError(.invalidArgument, message, hint: hint)
    }

    static func notFound(_ message: String, hint: String? = nil) -> MCPToolError {
        MCPToolError(.notFound, message, hint: hint)
    }

    /// Classifies any error a handler lets escape: tool errors pass through, file-system
    /// errors become `io_error`, a cancelled call is `busy`, and anything else is `internal`.
    ///
    /// Folder access, which every file-touching tool checks first: macOS denying it is
    /// `io_error`, and a permission prompt still waiting (or a location not answering) is
    /// `busy`, with `details` `{code: "folder_access_denied" | "folder_access_pending", path,
    /// root}` and a hint saying what the owner can do.
    static func from(_ error: Error) -> MCPToolError {
        if let error = error as? MCPToolError { return error }
        if let error = error as? FolderAccessError {
            return MCPToolError(error.reason == .denied ? .ioError : .busy, error.errorDescription ?? error.code, hint: error.hint,
                                details: ["code": .string(error.code), "path": .string(error.path), "root": .string(error.root.rawValue)])
        }
        if error is MCPQueueFull { return MCPToolError(.busy, error.localizedDescription) }
        // The call stopped part way through (a list_files walk checks between items), not because of a fault.
        if error is CancellationError {
            return MCPToolError(.busy, "The call was cancelled before it finished.", hint: "Retry the call.")
        }
        if error is LayerLimitError {
            return MCPToolError(.preconditionFailed, error.localizedDescription,
                                hint: "Delete, merge or flatten layers first, or work in a file with fewer layers.", guard: "max_layers")
        }
        let budgetHint = "Keep to \(DocumentLimits.maxSurfaceMegapixels) megapixels (\(DocumentLimits.documentBudgetMegapixels) in all a document's layers) and \(DocumentLimits.maxSide.formatted()) pixels a side: use a smaller canvas, image, region or scale."
        if let error = error as? ExportError, case .tooLarge = error {
            return MCPToolError(.preconditionFailed, error.localizedDescription, hint: budgetHint, guard: "pixel_budget")
        }
        if let error = error as? ProjectError {
            if case .tooLarge = error {
                return MCPToolError(.preconditionFailed, error.localizedDescription, hint: budgetHint, guard: "pixel_budget")
            }
            return MCPToolError(.ioError, error.localizedDescription)
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSPOSIXErrorDomain {
            return MCPToolError(.ioError, error.localizedDescription,
                                details: ["domain": .string(nsError.domain), "error_code": .int(nsError.code)])
        }
        return MCPToolError(.internalError, error.localizedDescription)
    }
}

// MARK: - Tool results

/// Result builders every tool handler returns through, and the argument reader they
/// parse their input with. Every result carries the same JSON twice: as text content
/// (for clients that only read text) and as `structuredContent`.
extension MCPToolRegistry {
    /// A result carrying `value`. `isError` is omitted (nil) unless given.
    static func result(_ value: Value, isError: Bool? = nil) -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        // `CallTool.Result` has a non-throwing `Value?` init and a throwing generic
        // `Codable` one; an explicitly typed `Value?` selects the non-throwing init.
        let structured: Value? = value
        return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)],
                               structuredContent: structured, isError: isError)
    }

    static func failure(_ error: MCPToolError) -> CallTool.Result {
        result(.object(["ok": .bool(false), "error": error.value]), isError: true)
    }

    static func failure(_ message: String, code: MCPErrorCode = .internalError) -> CallTool.Result {
        failure(MCPToolError(code, message))
    }

    static func ok(_ fields: [String: Value] = [:]) -> CallTool.Result {
        var out: [String: Value] = ["ok": .bool(true)]
        out.merge(fields) { _, new in new }
        return result(.object(out))
    }

    // MARK: - Value reading helpers

    /// Typed access to a tool's arguments. Absent and `null` arguments read as missing;
    /// a present argument of the wrong type is an `invalid_argument` error, never
    /// silently replaced by a default.
    struct Args {
        let values: [String: Value]
        init(_ values: [String: Value]) { self.values = values }

        /// The raw value, treating `null` as absent.
        subscript(key: String) -> Value? {
            guard let value = values[key], value != .null else { return nil }
            return value
        }

        func has(_ key: String) -> Bool { self[key] != nil }

        func string(_ key: String) throws -> String {
            guard let value = try optionalString(key) else { throw MCPToolError.invalidArgument("Missing string argument '\(key)'.") }
            return value
        }
        func string(_ key: String, default fallback: String) throws -> String { try optionalString(key) ?? fallback }
        /// A non-empty string, or nil when absent, null or empty.
        func optionalString(_ key: String) throws -> String? {
            guard let value = self[key] else { return nil }
            guard let text = value.stringValue else { throw MCPToolError.invalidArgument("'\(key)' must be a string.") }
            return text.isEmpty ? nil : text
        }

        func optionalDouble(_ key: String) throws -> Double? {
            guard let value = self[key] else { return nil }
            guard let number = value.doubleValue ?? value.intValue.map(Double.init), number.isFinite else {
                throw MCPToolError.invalidArgument("'\(key)' must be a finite number.")
            }
            return number
        }
        func double(_ key: String) throws -> Double {
            guard let value = try optionalDouble(key) else { throw MCPToolError.invalidArgument("Missing number argument '\(key)'.") }
            return value
        }
        func double(_ key: String, default fallback: Double) throws -> Double { try optionalDouble(key) ?? fallback }

        func optionalInt(_ key: String) throws -> Int? {
            guard let value = self[key] else { return nil }
            if let int = value.intValue { return int }
            guard let number = value.doubleValue, number.isFinite, number.rounded() == number, abs(number) < 1e15 else {
                throw MCPToolError.invalidArgument("'\(key)' must be an integer.")
            }
            return Int(number)
        }
        func int(_ key: String) throws -> Int {
            guard let value = try optionalInt(key) else { throw MCPToolError.invalidArgument("Missing integer argument '\(key)'.") }
            return value
        }
        func int(_ key: String, default fallback: Int) throws -> Int { try optionalInt(key) ?? fallback }

        func optionalBool(_ key: String) throws -> Bool? {
            guard let value = self[key] else { return nil }
            guard let bool = value.boolValue else { throw MCPToolError.invalidArgument("'\(key)' must be true or false.") }
            return bool
        }
        func bool(_ key: String) throws -> Bool {
            guard let value = try optionalBool(key) else { throw MCPToolError.invalidArgument("Missing boolean argument '\(key)'.") }
            return value
        }
        func bool(_ key: String, default fallback: Bool) throws -> Bool { try optionalBool(key) ?? fallback }

        func object(_ key: String) throws -> [String: Value]? {
            guard let value = self[key] else { return nil }
            guard let object = value.objectValue else { throw MCPToolError.invalidArgument("'\(key)' must be an object.") }
            return object
        }

        /// A color given as `{r, g, b}` (0–1, `red`/`green`/`blue` also accepted) or
        /// `"#rrggbb"`. Components are clamped to 0–1.
        func color(_ key: String) throws -> (red: Double, green: Double, blue: Double)? {
            guard let value = self[key] else { return nil }
            if let extra = value.objectValue?.keys.sorted().first(where: { !MCPValues.colorChannelKeys.contains($0) }) {
                throw MCPToolError(.invalidArgument, "Unknown field '\(key).\(extra)'; a color has only r, g and b.",
                                   hint: "A color is {\"r\", \"g\", \"b\"} in 0–1, or \"#rrggbb\".", details: ["field": .string("\(key).\(extra)")])
            }
            guard let color = MCPValues.color(from: value) else {
                throw MCPToolError.invalidArgument("'\(key)' must be a color: {\"r\", \"g\", \"b\"} in 0–1, or \"#rrggbb\".")
            }
            return color
        }
    }
}
