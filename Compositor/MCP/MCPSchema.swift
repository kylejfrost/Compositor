import Foundation
import MCP

/// JSON Schema builders for tool input schemas, so every tool describes selectors,
/// colors, points and rectangles the same way.
nonisolated enum MCPSchema {
    static func object(_ properties: [String: Value], required: [String] = [], description: String? = nil) -> Value {
        var out: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty { out["required"] = .array(required.map { .string($0) }) }
        if let description { out["description"] = .string(description) }
        return .object(out)
    }

    static func str(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    static func enumString(_ description: String, _ values: [String], default fallback: String? = nil) -> Value {
        var out: [String: Value] = [
            "type": .string("string"),
            "description": .string(description),
            "enum": .array(values.map { .string($0) }),
        ]
        if let fallback { out["default"] = .string(fallback) }
        return .object(out)
    }

    /// A number, at least `min` (or above `exclusiveMin`) and at most `max`.
    static func num(_ description: String, min: Double? = nil, exclusiveMin: Double? = nil, max: Double? = nil,
                    default fallback: Double? = nil) -> Value {
        var out: [String: Value] = ["type": .string("number"), "description": .string(description)]
        if let min { out["minimum"] = .double(min) }
        if let exclusiveMin { out["exclusiveMinimum"] = .double(exclusiveMin) }
        if let max { out["maximum"] = .double(max) }
        if let fallback { out["default"] = .double(fallback) }
        return .object(out)
    }

    static func int(_ description: String, min: Int? = nil, max: Int? = nil, default fallback: Int? = nil) -> Value {
        var out: [String: Value] = ["type": .string("integer"), "description": .string(description)]
        if let min { out["minimum"] = .int(min) }
        if let max { out["maximum"] = .int(max) }
        if let fallback { out["default"] = .int(fallback) }
        return .object(out)
    }

    static func bool(_ description: String, default fallback: Bool? = nil) -> Value {
        var out: [String: Value] = ["type": .string("boolean"), "description": .string(description)]
        if let fallback { out["default"] = .bool(fallback) }
        return .object(out)
    }

    static func arr(_ description: String, items: Value, minItems: Int? = nil, maxItems: Int? = nil) -> Value {
        var out: [String: Value] = ["type": .string("array"), "description": .string(description), "items": items]
        if let minItems { out["minItems"] = .int(minItems) }
        if let maxItems { out["maxItems"] = .int(maxItems) }
        return .object(out)
    }

    static func oneOf(_ schemas: [Value], description: String? = nil) -> Value {
        combined("oneOf", schemas, description: description)
    }

    static func anyOf(_ schemas: [Value], description: String? = nil) -> Value {
        combined("anyOf", schemas, description: description)
    }

    /// `schema` or `null` (where `null` means "remove" or "none"), described once, on the whole.
    static func nullable(_ schema: Value) -> Value {
        var inner = schema.objectValue ?? [:]
        let description = inner.removeValue(forKey: "description")
        var out: [String: Value] = ["anyOf": .array([.object(inner), .object(["type": .string("null")])])]
        if let description { out["description"] = description }
        return .object(out)
    }

    /// A number with no description of its own, where the object holding it says what it is.
    static func bareNumber(min: Double? = nil, max: Double? = nil) -> Value {
        var out: [String: Value] = ["type": .string("number")]
        if let min { out["minimum"] = .double(min) }
        if let max { out["maximum"] = .double(max) }
        return .object(out)
    }

    /// The `{r, g, b}` object form of a color, each 0–1 (tools clamp a component outside that).
    static let rgbObject = object(["r": bareNumber(), "g": bareNumber(), "b": bareNumber()], required: ["r", "g", "b"])

    /// The `"#rrggbb"` form of a color.
    static let hexColor: Value = .object(["type": .string("string"), "pattern": .string("^#[0-9A-Fa-f]{6}$")])

    /// `{r, g, b}` in 0–1, or `"#rrggbb"`; nil leaves the forms to the instructions.
    static func color(_ description: String?) -> Value {
        anyOf([rgbObject, hexColor], description: description.map { $0 + " {r, g, b} in 0–1, or \"#rrggbb\"." })
    }

    /// `{x, y}` in document pixels, origin top-left.
    static func point(_ description: String) -> Value {
        object(["x": bareNumber(), "y": bareNumber()], required: ["x", "y"], description: description)
    }

    /// `{x, y, width, height}` in document pixels, origin top-left.
    static func rect(_ description: String) -> Value {
        object(["x": bareNumber(), "y": bareNumber(), "width": bareNumber(min: 0), "height": bareNumber(min: 0)],
               required: ["x", "y", "width", "height"], description: description)
    }

    static let documentSelectorDescription = "Default: the current tab."

    /// The optional `document` argument every document tool takes.
    static var documentSelector: Value { documentSelector(documentSelectorDescription) }

    /// A tab index (from 0) or a tab id, document id or exact title.
    static func documentSelector(_ description: String) -> Value {
        anyOf([.object(["type": .string("integer"), "minimum": .int(0)]), .object(["type": .string("string")])], description: description)
    }

    /// How a layer selector names a layer, as the instructions explain.
    static let layerSelectorForms = "id, name, \"Group/Child\" path, or \"@active\""

    /// A layer selector; the plain `layer` argument spells out the forms, others say only what the layer is for.
    static func layerSelector(_ description: String? = nil) -> Value {
        str(description.map { $0 + "." } ?? "The layer: " + layerSelectorForms + ".")
    }

    static func layerSelectors(_ description: String = "The layers") -> Value {
        arr(description + ".", items: .object(["type": .string("string")]), minItems: 1)
    }

    /// The success envelope every tool returns: `ok: true` plus tool-specific fields
    /// (and `undo: {name, count}` from mutating tools).
    static let okEnvelope: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "ok": .object(["type": .string("boolean"), "const": .bool(true)]),
            "undo": object(["name": str("Name of the newest undo entry."), "count": int("Undo entries in the document's history.")]),
        ]),
        "required": .array([.string("ok")]),
    ])

    private static func combined(_ keyword: String, _ schemas: [Value], description: String?) -> Value {
        var out: [String: Value] = [keyword: .array(schemas)]
        if let description { out["description"] = .string(description) }
        return .object(out)
    }
}
