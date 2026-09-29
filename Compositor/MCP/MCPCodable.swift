import Foundation
import MCP

/// A settings struct agents change through `MCPCodable.decodeMerged`: `Codable`, with the model's own validity
/// check, and the supported range of its numeric fields so a rejected patch can name the field that broke it.
nonisolated protocol MCPPatchable: Codable {
    /// Whether every field is within the range the app supports.
    var isValid: Bool { get }
    /// The supported range of each numeric field, keyed by its snake_case path from this value (`"size"`,
    /// `"stroke.size"`, and `"points[].x"` for every element of an array). Only consulted to explain a value
    /// `isValid` rejects.
    static var mcpFieldRanges: [String: ClosedRange<Double>] { get }
    /// Members that hold a Swift enum's raw values, keyed by snake_case path, each with every raw value of its enum.
    /// Agents see and send such a value by its snake_case name (`"Black & White"` is `black_white`), in any case and
    /// punctuation. A path ending in `.*` names the keys of a dictionary keyed by the enum, which `Codable` writes as
    /// an array alternating key and value; agents see and patch it as an object keyed by those names.
    static var mcpEnumMembers: [String: [String]] { get }
    /// Why `isValid` rejects this value when no field is outside its `mcpFieldRanges` range (a field that must stay
    /// above another, say), or nil to leave a general message.
    var mcpInvalidReason: String? { get }
}

nonisolated extension MCPPatchable {
    static var mcpFieldRanges: [String: ClosedRange<Double>] { [:] }
    static var mcpEnumMembers: [String: [String]] { [:] }
    var mcpInvalidReason: String? { nil }
}

/// Settings travel as the models' own `Codable` form with snake_case keys, so a tool changes any settings
/// struct the same way: encode what the layer has, merge the agent's patch in, decode, validate.
nonisolated enum MCPCodable {
    /// `value` as JSON with snake_case keys, as tools report settings.
    static func encode<T: Encodable>(_ value: T) throws -> Value {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try JSONDecoder().decode(Value.self, from: encoder.encode(value))
    }

    /// `value` as tools report it and agents patch it: `encode`, with each of `T.mcpEnumMembers` by its
    /// snake_case name and each enum-keyed dictionary as an object.
    static func agentForm<T: MCPPatchable>(_ value: T) throws -> Value {
        agentForm(try encode(value), members: enumMembers(T.mcpEnumMembers))
    }

    /// How agents name an enum's raw value: its words, lowercased and joined by `_` (`"Black & White"` is
    /// `black_white`).
    static func enumName(_ raw: String) -> String {
        raw.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "_")
    }

    /// `current` with `patch` (snake_case keys) merged in. Objects merge field by field, `null` removes an
    /// optional member, and arrays and scalars replace what was there. A member the patch introduces starts
    /// from the same member of `template` (a value with every optional member at its defaults), so a partial
    /// patch fills in the rest. Where a struct stores its color flat as `red`/`green`/`blue`, `color` given as
    /// `{r, g, b}` in 0–1 or `"#rrggbb"` sets them; a nested member that is just a color (`{red, green, blue}`)
    /// takes the same shorthand in its place. Enum members are patched in `agentForm`, by name. Fails with
    /// `invalid_argument` naming the field: unknown (even when set to `null`) or mistyped, an enum name the enum
    /// lacks, required but removed, or outside the range `isValid` accepts.
    static func decodeMerged<T: MCPPatchable>(_ current: T, _ patch: Value, template: T? = nil) throws -> T {
        guard patch.objectValue != nil else {
            throw MCPToolError.invalidArgument("Settings must be an object of the fields to change.")
        }
        let members = enumMembers(T.mcpEnumMembers)
        let base = try agentForm(current)
        let defaults = try template.map { try agentForm($0) }
        let changes = try expandingColors(try namingEnums(patch, members: members), base: base, template: defaults, path: "")
        let (merged, entries) = modelForm(merge(base, changes, template: defaults), members: members)
        let result: T
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            result = try decoder.decode(T.self, from: JSONEncoder().encode(merged))
        } catch let error as DecodingError {
            throw invalidField(error, entries: entries)
        }
        let decoded = try agentForm(result)
        try requireKnownFields(changes, in: decoded, base: base, template: defaults, model: result, path: "")
        guard result.isValid else { throw outOfRange(decoded, ranges: T.mcpFieldRanges, reason: result.mcpInvalidReason) }
        return result
    }

    // MARK: Merging

    private static func merge(_ base: Value?, _ patch: Value, template: Value?) -> Value {
        guard let fields = patch.objectValue else { return patch }
        var out = base?.objectValue ?? template?.objectValue ?? [:]
        for (key, value) in fields {
            if value == .null {
                out[key] = nil
            } else {
                out[key] = merge(base?.objectValue?[key], value, template: template?.objectValue?[key])
            }
        }
        return .object(out)
    }

    // MARK: Enums

    /// One of a type's `mcpEnumMembers`: where it is, whether it is the keys of a dictionary, and its enum's raw values.
    private struct EnumMember {
        let path: [String]
        let isKeys: Bool
        let raws: [String]

        init(_ declared: String, raws: [String]) {
            isKeys = declared.hasSuffix(".*")
            path = (isKeys ? String(declared.dropLast(2)) : declared).split(separator: ".").map(String.init)
            self.raws = raws
        }

        var field: String { path.joined(separator: ".") }
        var names: String { raws.map(MCPCodable.enumName).joined(separator: ", ") }

        /// The raw value `name` means, ignoring case, spaces and punctuation.
        func raw(for name: String) -> String? {
            let target = MCPCodable.loose(name)
            return raws.first { MCPCodable.loose($0) == target }
        }
    }

    private static func enumMembers(_ declared: [String: [String]]) -> [EnumMember] {
        declared.sorted { $0.key < $1.key }.map { EnumMember($0.key, raws: $0.value) }
    }

    private static func loose(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// `value` with the member at `path` replaced by what `change` makes of it, or unchanged where it has none.
    private static func updating(_ value: Value, at path: ArraySlice<String>, _ change: (Value) throws -> Value) rethrows -> Value {
        guard let key = path.first else { return try change(value) }
        guard var fields = value.objectValue, let member = fields[key] else { return value }
        fields[key] = try updating(member, at: path.dropFirst(), change)
        return .object(fields)
    }

    /// The encoded `value` with each enum member by name and each enum-keyed dictionary as an object.
    private static func agentForm(_ value: Value, members: [EnumMember]) -> Value {
        members.reduce(value) { value, member in
            updating(value, at: member.path[...]) { stored in
                guard member.isKeys else { return stored.stringValue.map { .string(enumName($0)) } ?? stored }
                guard let items = stored.arrayValue, items.count.isMultiple(of: 2) else { return stored }
                var fields: [String: Value] = [:]
                for index in stride(from: 0, to: items.count, by: 2) {
                    guard let raw = items[index].stringValue else { return stored }
                    fields[enumName(raw)] = items[index + 1]
                }
                return .object(fields)
            }
        }
    }

    /// `patch` with each enum value and enum-keyed dictionary key it gives named as `agentForm` names it. Fails
    /// naming the field for a name the enum lacks, or a dictionary key given twice.
    private static func namingEnums(_ patch: Value, members: [EnumMember]) throws -> Value {
        try members.reduce(patch) { patch, member in
            try updating(patch, at: member.path[...]) { given in
                guard member.isKeys else {
                    guard let name = given.stringValue else { return given }
                    guard let raw = member.raw(for: name) else {
                        throw fieldError(member.field, "'\(member.field)' must be one of: \(member.names).")
                    }
                    return .string(enumName(raw))
                }
                guard let fields = given.objectValue else { return given }
                var named: [String: Value] = [:]
                for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
                    let field = join(member.field, key)
                    guard let raw = member.raw(for: key) else {
                        throw fieldError(field, "Unknown field '\(field)'.", hint: "Fields here: \(member.names).")
                    }
                    guard named[enumName(raw)] == nil else {
                        throw fieldError(field, "'\(member.field)' gives \(enumName(raw)) twice.")
                    }
                    named[enumName(raw)] = value
                }
                return .object(named)
            }
        }
    }

    /// `value`, in agent form, back in the encoded form: enum names as raw values, and each enum-keyed dictionary
    /// as an array alternating key and value in the enum's order. Also returns each dictionary's keys in that
    /// order, by field, so a failure decoding one of its entries can name it.
    private static func modelForm(_ value: Value, members: [EnumMember]) -> (Value, [String: [String]]) {
        var entries: [String: [String]] = [:]
        let model = members.reduce(value) { value, member in
            updating(value, at: member.path[...]) { shown in
                func raw(_ name: String) -> String { member.raws.first { enumName($0) == name } ?? name }
                guard member.isKeys else { return shown.stringValue.map { .string(raw($0)) } ?? shown }
                guard let fields = shown.objectValue else { return shown }
                let order = member.raws.map(enumName)
                let keys = fields.keys.sorted { (order.firstIndex(of: $0) ?? order.count, $0) < (order.firstIndex(of: $1) ?? order.count, $1) }
                entries[member.field] = keys
                return .array(keys.flatMap { [.string(raw($0)), fields[$0] ?? .null] })
            }
        }
        return (model, entries)
    }

    /// `patch` with color shorthand spelled out as the `red`/`green`/`blue` fields the models store: `color` on
    /// a struct that stores its color flat, and a whole color given for a member that is just a color. Anything
    /// else, stray `r`/`g`/`b` included, stays as sent, so a key the model lacks fails as an unknown field.
    private static func expandingColors(_ patch: Value, base: Value?, template: Value?, path: String) throws -> Value {
        guard var fields = patch.objectValue else { return patch }
        let baseFields = base?.objectValue, templateFields = template?.objectValue
        if let shorthand = fields["color"], storesFlatColor(baseFields, templateFields) {
            let field = join(path, "color")
            guard shorthand != .null else { throw fieldError(field, "'\(field)' can't be null.", hint: colorHint) }
            if let channel = ["red", "green", "blue"].first(where: { fields[$0] != nil }) {
                throw fieldError(field, "'\(field)' and '\(join(path, channel))' both set the color; give one of them.")
            }
            fields["color"] = nil
            fields.merge(try colorFields(shorthand, field: field)) { $1 }
        }
        for (key, value) in fields where value != .null {
            let existing = baseFields?[key] ?? templateFields?[key]
            if isColorObject(existing), isShorthand(value) {
                // Merged into the member, so a channel the model keeps beside red/green/blue (alpha) stays.
                fields[key] = .object(try colorFields(value, field: join(path, key)))
            } else {
                fields[key] = try expandingColors(value, base: baseFields?[key], template: templateFields?[key], path: join(path, key))
            }
        }
        return .object(fields)
    }

    private static let colorHint = "A color is {\"r\", \"g\", \"b\"} in 0–1, or \"#rrggbb\"."

    /// The `red`/`green`/`blue` fields `value` gives as a color: `"#rrggbb"`, or an object of `r`/`g`/`b` (or
    /// `red`/`green`/`blue`) in 0–1, with nothing else in it.
    private static func colorFields(_ value: Value, field: String) throws -> [String: Value] {
        if let object = value.objectValue, let extra = object.keys.filter({ !shorthandKeys.contains($0) }).sorted().first {
            let path = join(field, extra)
            throw fieldError(path, "Unknown field '\(path)'; a color has only r, g and b.", hint: colorHint)
        }
        guard value.objectValue?.isEmpty != true, let rgb = MCPValues.color(from: value) else {
            throw fieldError(field, "'\(field)' must be a color: {\"r\", \"g\", \"b\"} in 0–1, or \"#rrggbb\".")
        }
        return ["red": .double(rgb.red), "green": .double(rgb.green), "blue": .double(rgb.blue)]
    }

    private static let shorthandKeys: Set<String> = ["r", "g", "b", "red", "green", "blue"]

    /// Whether the struct at this level stores its color as flat `red`/`green`/`blue` fields and has no `color`
    /// member, so `color` there is shorthand. A level neither `base` nor `template` describes is taken to.
    private static func storesFlatColor(_ base: [String: Value]?, _ template: [String: Value]?) -> Bool {
        let described = [base, template].compactMap { $0 }
        guard !described.isEmpty else { return true }
        return described.allSatisfy { $0["color"] == nil }
            && described.contains { level in ["red", "green", "blue"].allSatisfy { level[$0] != nil } }
    }

    /// Whether `value` is a color and nothing else: exactly `red`/`green`/`blue`, plus `alpha` if it has one.
    /// An effect stores its color flat beside its other fields, so it isn't one.
    private static func isColorObject(_ value: Value?) -> Bool {
        guard let keys = value?.objectValue.map({ Set($0.keys) }) else { return false }
        return keys == ["red", "green", "blue"] || keys == ["red", "green", "blue", "alpha"]
    }

    /// Whether `value` is a whole color in shorthand: `"#rrggbb"`, or an object of only color channels with at
    /// least one of `r`/`g`/`b`. An object of `red`/`green`/`blue` alone is the model's own form, which merges.
    private static func isShorthand(_ value: Value) -> Bool {
        if value.stringValue != nil { return true }
        guard let keys = value.objectValue?.keys, !keys.isEmpty else { return false }
        return keys.allSatisfy { shorthandKeys.contains($0) } && keys.contains { ["r", "g", "b"].contains($0) }
    }

    // MARK: Errors

    /// Every field the patch sets must survive decoding; one that doesn't is a field the model doesn't have.
    /// A field the patch removes with `null` must be one the model has: in `base` or `template` as they were,
    /// in `decoded`, or among the stored properties of `model` (the decoded value at this level), which lists
    /// an optional member even while it is unset.
    private static func requireKnownFields(_ patch: Value, in decoded: Value, base: Value?, template: Value?, model: Any?,
                                           path: String) throws {
        guard let fields = patch.objectValue, let known = decoded.objectValue else { return }
        let properties = model.map { codedProperties(of: $0) } ?? [:]
        let names = Set(known.keys).union(properties.keys)
            .union(base?.objectValue.map { Array($0.keys) } ?? []).union(template?.objectValue.map { Array($0.keys) } ?? [])
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            let field = join(path, key)
            let decodedValue = known[key]
            guard value == .null ? names.contains(key) : decodedValue != nil else {
                var hint = "Fields here: \(names.sorted().joined(separator: ", "))."
                if ["r", "g", "b"].contains(key), names.contains("red") { hint += " Give a color as \"color\". " + colorHint }
                throw fieldError(field, "Unknown field '\(field)'.", hint: hint)
            }
            if let decodedValue {
                try requireKnownFields(value, in: decodedValue, base: base?.objectValue?[key], template: template?.objectValue?[key],
                                       model: properties[key] ?? nil, path: field)
            }
        }
    }

    /// The stored properties of `model`, keyed as the encoder names them (snake_case), with optionals unwrapped:
    /// nil for an unset one.
    private static func codedProperties(of model: Any) -> [String: Any?] {
        let mirror = Mirror(reflecting: model)
        guard mirror.displayStyle == .struct || mirror.displayStyle == .class else { return [:] }
        var out: [String: Any?] = [:]
        for case let (label?, value) in mirror.children {
            out[codedName(label)] = unwrapped(value)
        }
        return out
    }

    private static func unwrapped(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        return mirror.children.first.map { unwrapped($0.value) } ?? nil
    }

    /// `name` as `encode` writes a property of that name, through the encoder's own snake_case conversion.
    private static func codedName(_ name: String) -> String {
        (try? encode(PropertyName(name: name)))?.objectValue?.keys.first ?? name
    }

    nonisolated private struct PropertyName: Encodable {
        nonisolated struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
        let name: String
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(true, forKey: Key(stringValue: name))
        }
    }

    private static func outOfRange(_ decoded: Value, ranges: [String: ClosedRange<Double>], reason: String?) -> MCPToolError {
        for (field, number) in numbers(in: decoded, path: "").sorted(by: { $0.field < $1.field }) {
            guard let range = ranges[field] ?? ranges[anyIndex(field)], !range.contains(number) else { continue }
            var error = fieldError(field, "'\(field)' is \(format(number)), outside its range \(format(range.lowerBound))–\(format(range.upperBound)).")
            error.details["value"] = .double(number)
            error.details["min"] = .double(range.lowerBound)
            error.details["max"] = .double(range.upperBound)
            return error
        }
        return MCPToolError.invalidArgument(reason ?? "The settings are outside the ranges Compositor supports.")
    }

    private static func numbers(in value: Value, path: String) -> [(field: String, value: Double)] {
        if let fields = value.objectValue {
            return fields.flatMap { numbers(in: $0.value, path: join(path, $0.key)) }
        }
        if let items = value.arrayValue {
            return items.enumerated().flatMap { numbers(in: $0.element, path: path + "[\($0.offset)]") }
        }
        if let number = MCPValues.number(value) { return [(path, number)] }
        return []
    }

    /// `field` with each array index written `[]`, as `mcpFieldRanges` names an array's elements.
    private static func anyIndex(_ field: String) -> String {
        var out = "", inIndex = false
        for character in field {
            if character == "[" { inIndex = true } else if character == "]" { inIndex = false } else if inIndex { continue }
            out.append(character)
        }
        return out
    }

    /// The error for a patch that doesn't decode, naming the field; `entries` lists the keys of each enum-keyed
    /// dictionary in the order `modelForm` wrote them, to name an entry by its key rather than its position.
    private static func invalidField(_ error: DecodingError, entries: [String: [String]]) -> MCPToolError {
        func named(_ codingPath: [any CodingKey]) -> String { naming(fieldPath(codingPath), entries: entries) }
        switch error {
        case .typeMismatch(let type, let context):
            let field = named(context.codingPath)
            return fieldError(field, "'\(field)' must be \(describe(type)).")
        case .valueNotFound(_, let context):
            let field = named(context.codingPath)
            return fieldError(field, "'\(field)' can't be null.")
        case .keyNotFound(let key, let context):
            let field = named(context.codingPath + [key])
            return fieldError(field, "'\(field)' is required; it can't be removed or left out.")
        case .dataCorrupted(let context):
            let field = named(context.codingPath)
            return field.isEmpty
                ? MCPToolError.invalidArgument("The settings are malformed: \(context.debugDescription)")
                : fieldError(field, "'\(field)' is invalid: \(context.debugDescription)")
        @unknown default:
            return MCPToolError.invalidArgument(error.localizedDescription)
        }
    }

    private static func fieldError(_ field: String, _ message: String, hint: String? = nil) -> MCPToolError {
        MCPToolError(.invalidArgument, message, hint: hint, details: ["field": .string(field)])
    }

    private static func describe(_ type: Any.Type) -> String {
        if type is Bool.Type { return "true or false" }
        if type is String.Type { return "a string" }
        if type is any BinaryInteger.Type { return "an integer" }
        if type is any BinaryFloatingPoint.Type { return "a number" }
        if type is [Any].Type { return "an array" }
        return "an object"
    }

    /// A decoding path as the snake_case field names agents send (`stroke.size`, `points[2]`).
    private static func fieldPath(_ codingPath: [any CodingKey]) -> String {
        codingPath.reduce("") { path, key in
            if let index = key.intValue { return path + "[\(index)]" }
            return join(path, snakeCase(key.stringValue))
        }
    }

    /// `field` with a position in an enum-keyed dictionary's encoded array (`amounts[3]`, the second entry's value)
    /// named by that entry's key (`amounts.highlights`).
    private static func naming(_ field: String, entries: [String: [String]]) -> String {
        for (dictionary, keys) in entries where field.hasPrefix(dictionary + "[") {
            let rest = field.dropFirst(dictionary.count + 1)
            guard let close = rest.firstIndex(of: "]"), let index = Int(rest[..<close]), keys.indices.contains(index / 2) else { continue }
            return join(dictionary, keys[index / 2]) + rest[rest.index(after: close)...]
        }
        return field
    }

    private static func snakeCase(_ name: String) -> String {
        var out = ""
        for character in name {
            if character.isUppercase, !out.isEmpty { out += "_" }
            out += character.lowercased()
        }
        return out
    }

    private static func join(_ path: String, _ key: String) -> String {
        path.isEmpty ? key : path + "." + key
    }

    private static func format(_ number: Double) -> String {
        number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
    }
}
