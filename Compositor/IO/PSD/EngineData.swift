import Foundation

/// One value in Photoshop's text EngineData, the PostScript-like markup stored as the `tdta`
/// raw data of a `TySh` descriptor (and in the document-level `Txt2` block). Original
/// implementation, cross-checked against psd-tools' `engine_data.py`.
nonisolated indirect enum EngineValue: Equatable, Sendable {
    /// `<< /Key value … >>`, in file order; duplicate keys are kept.
    case dictionary([(key: String, value: EngineValue)])
    /// `[ value … ]`.
    case array([EngineValue])
    /// `( … )`: UTF-16BE after an FE FF byte-order mark, otherwise Latin-1.
    case string(String)
    /// `-?\d+`.
    case integer(Int)
    /// `-?\d*\.\d+` such as `.5` or `-1.0`, and integers too large for `Int`.
    case number(Double)
    /// `true` or `false`.
    case bool(Bool)
    /// A token with no known meaning, verbatim: a parenthesized word without a byte-order mark
    /// such as `(hwid)`, a bare word such as `--(.-0` (both Latin-1), or a name used as a
    /// value such as `/CoolTypeFont` (Mac OS Roman, slash kept).
    case tag(String)

    /// The first value stored under `key`, when this is a dictionary.
    subscript(_ key: String) -> EngineValue? {
        guard case .dictionary(let items) = self else { return nil }
        return items.first { $0.key == key }?.value
    }

    /// Follows dot-separated components such as `"EngineDict.StyleRun.RunArray"`: each is a
    /// dictionary key, or a zero-based index when the value there is an array
    /// (`"StyleRun.RunArray.0.StyleSheet"`). An empty path is the value itself.
    subscript(path path: String) -> EngineValue? {
        guard !path.isEmpty else { return self }
        var value = self
        for component in path.split(separator: ".", omittingEmptySubsequences: false) {
            switch value {
            case .dictionary:
                guard let next = value[String(component)] else { return nil }
                value = next
            case .array(let items):
                guard let index = Int(component), items.indices.contains(index) else { return nil }
                value = items[index]
            default:
                return nil
            }
        }
        return value
    }

    var array: [EngineValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    /// A `.number`, or an `.integer` widened.
    var double: Double? {
        switch self {
        case .number(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }

    var int: Int? {
        if case .integer(let value) = self { return value }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    static func == (lhs: EngineValue, rhs: EngineValue) -> Bool {
        switch (lhs, rhs) {
        case (.dictionary(let left), .dictionary(let right)):
            return left.count == right.count
                && zip(left, right).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case (.array(let left), .array(let right)): return left == right
        case (.string(let left), .string(let right)): return left == right
        case (.integer(let left), .integer(let right)): return left == right
        case (.number(let left), .number(let right)): return left == right
        case (.bool(let left), .bool(let right)): return left == right
        case (.tag(let left), .tag(let right)): return left == right
        default: return false
        }
    }
}

/// Byte offsets count from the start of the data passed to the parser.
nonisolated enum EngineDataError: Error, Equatable, Sendable {
    /// Unexpected byte at `offset`, or input that ends early (`offset` is then its length).
    /// An odd-length UTF-16 string reports the offset of its `(`.
    case malformed(offset: Int)
    /// A string opened at `offset` has no closing `)`.
    case unterminatedString(offset: Int)
    /// Containers nest deeper than `EngineDataParser.maxDepth`; `offset` is the opening `<<` or
    /// `[` of the container that exceeded the limit.
    case depth(offset: Int)
}

/// Parses EngineData in one linear pass. Whitespace is space, tab, CR, LF and NUL (Photoshop
/// pads the closing `>>` with NULs). `<<`, `>>`, `[` and `]` delimit themselves; other tokens
/// end at whitespace or one of `/ < > [ ]`.
nonisolated enum EngineDataParser {
    static let maxDepth = 64

    /// The top level is one dictionary, optionally surrounded by whitespace.
    static func parse(_ data: Data) throws -> EngineValue {
        var parser = Parser(bytes: [UInt8](data))
        return try parser.document()
    }

    /// The exact content bytes of the string whose `(` is at `offset` (counted from the start
    /// of `data`): escapes removed, byte-order mark kept. `end` is the offset after its `)`.
    /// Lets a caller recover text that decodes lossily, such as a lone UTF-16 surrogate.
    static func stringBytes(in data: Data, at offset: Int) throws -> (bytes: [UInt8], end: Int) {
        var parser = Parser(bytes: [UInt8](data))
        guard parser.bytes.indices.contains(offset), parser.bytes[offset] == UInt8(ascii: "(") else {
            throw EngineDataError.malformed(offset: offset)
        }
        parser.offset = offset
        let bytes = try parser.stringContent()
        return (bytes, parser.offset)
    }

    private struct Parser {
        let bytes: [UInt8]
        var offset = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func document() throws -> EngineValue {
            skipWhitespace()
            guard peek(0) == UInt8(ascii: "<"), peek(1) == UInt8(ascii: "<") else {
                throw EngineDataError.malformed(offset: offset)
            }
            let value = try self.value(depth: 1)
            skipWhitespace()
            guard offset == bytes.count else { throw EngineDataError.malformed(offset: offset) }
            return value
        }

        /// Parses the value at `offset` (whitespace already skipped). `depth` counts the
        /// container this value would open, the top-level dictionary being 1.
        mutating func value(depth: Int) throws -> EngineValue {
            guard let byte = peek(0) else { throw EngineDataError.malformed(offset: offset) }
            switch byte {
            case UInt8(ascii: "<"):
                guard peek(1) == UInt8(ascii: "<") else { throw EngineDataError.malformed(offset: offset) }
                guard depth <= EngineDataParser.maxDepth else { throw EngineDataError.depth(offset: offset) }
                offset += 2
                return try dictionary(depth: depth)
            case UInt8(ascii: "["):
                guard depth <= EngineDataParser.maxDepth else { throw EngineDataError.depth(offset: offset) }
                offset += 1
                return try array(depth: depth)
            case UInt8(ascii: "("):
                return try string()
            case UInt8(ascii: "/"):
                // A PostScript name used as a value, as in `Txt2`'s `/99 /CoolTypeFont`.
                return .tag("/" + (try name()))
            case UInt8(ascii: ">"), UInt8(ascii: "]"), UInt8(ascii: ")"):
                throw EngineDataError.malformed(offset: offset)
            default:
                return bareword()
            }
        }

        mutating func dictionary(depth: Int) throws -> EngineValue {
            var items: [(key: String, value: EngineValue)] = []
            while true {
                skipWhitespace()
                guard let byte = peek(0) else { throw EngineDataError.malformed(offset: offset) }
                if byte == UInt8(ascii: ">") {
                    guard peek(1) == UInt8(ascii: ">") else { throw EngineDataError.malformed(offset: offset) }
                    offset += 2
                    return .dictionary(items)
                }
                guard byte == UInt8(ascii: "/") else { throw EngineDataError.malformed(offset: offset) }
                let key = try name()
                skipWhitespace()
                items.append((key, try value(depth: depth + 1)))
            }
        }

        /// Reads `/Name` at `offset` and returns the name without its slash. Names end at
        /// whitespace or one of `/ < > [ ] ( )`; psd-tools decodes them as Mac OS Roman.
        mutating func name() throws -> String {
            let start = offset
            offset += 1
            while let next = peek(0), !Self.endsToken(next), next != UInt8(ascii: "("), next != UInt8(ascii: ")") {
                offset += 1
            }
            guard offset > start + 1 else { throw EngineDataError.malformed(offset: start) }
            let name = bytes[(start + 1) ..< offset]
            return String(bytes: name, encoding: .macOSRoman) ?? Self.latin1(name)
        }

        mutating func array(depth: Int) throws -> EngineValue {
            var items: [EngineValue] = []
            while true {
                skipWhitespace()
                guard let byte = peek(0) else { throw EngineDataError.malformed(offset: offset) }
                if byte == UInt8(ascii: "]") {
                    offset += 1
                    return .array(items)
                }
                items.append(try value(depth: depth + 1))
            }
        }

        mutating func string() throws -> EngineValue {
            let start = offset
            let content = try stringContent()
            if content.count >= 2, content[0] == 0xFE, content[1] == 0xFF {
                guard content.count % 2 == 0 else { throw EngineDataError.malformed(offset: start) }
                var units: [UInt16] = []
                units.reserveCapacity(content.count / 2 - 1)
                var index = 2
                while index < content.count {
                    units.append(UInt16(content[index]) << 8 | UInt16(content[index + 1]))
                    index += 2
                }
                return .string(String(decoding: units, as: UTF16.self))
            }
            if content.allSatisfy(Self.isAlphanumeric) {
                // psd-tools' "unknown tag": `(hwid)`, `(fwid)`, `()`.
                return .tag(Self.latin1(bytes[start ..< offset]))
            }
            return .string(Self.latin1(content))
        }

        /// Reads from `(` to the first unescaped `)`, returning the bytes between with each
        /// `\(`, `\)` and `\\` pair reduced to its second byte. Any other `\` pair is kept whole,
        /// as psd-tools does. Escapes are byte-wise, so they can split a UTF-16 code unit.
        mutating func stringContent() throws -> [UInt8] {
            let start = offset
            offset += 1
            var content: [UInt8] = []
            while offset < bytes.count {
                let byte = bytes[offset]
                if byte == UInt8(ascii: ")") {
                    offset += 1
                    return content
                }
                if byte == UInt8(ascii: "\\") {
                    guard offset + 1 < bytes.count else { break }
                    let escaped = bytes[offset + 1]
                    if escaped != UInt8(ascii: "\\"), escaped != UInt8(ascii: "("), escaped != UInt8(ascii: ")") {
                        content.append(byte)
                    }
                    content.append(escaped)
                    offset += 2
                    continue
                }
                content.append(byte)
                offset += 1
            }
            throw EngineDataError.unterminatedString(offset: start)
        }

        /// A number, boolean or unknown bare word.
        mutating func bareword() -> EngineValue {
            let start = offset
            while let byte = peek(0), !Self.endsToken(byte) { offset += 1 }
            let token = bytes[start ..< offset]
            if let value = Self.number(token) { return value }
            if token.elementsEqual("true".utf8) { return .bool(true) }
            if token.elementsEqual("false".utf8) { return .bool(false) }
            return .tag(Self.latin1(token))
        }

        /// `-?\d+` as an integer (a double when it overflows `Int`), `-?\d*\.\d+` as a double.
        static func number(_ token: ArraySlice<UInt8>) -> EngineValue? {
            var digits = token[...]
            if digits.first == UInt8(ascii: "-") { digits = digits.dropFirst() }
            let isDigit = { (byte: UInt8) in byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }
            let text = String(decoding: token, as: UTF8.self)
            if let dot = digits.firstIndex(of: UInt8(ascii: ".")) {
                let whole = digits[..<dot], fraction = digits[(dot + 1)...]
                guard whole.allSatisfy(isDigit), !fraction.isEmpty, fraction.allSatisfy(isDigit),
                      let value = Double(text) else { return nil }
                return .number(value)
            }
            guard !digits.isEmpty, digits.allSatisfy(isDigit) else { return nil }
            if let value = Int(text) { return .integer(value) }
            return Double(text).map(EngineValue.number)
        }

        mutating func skipWhitespace() {
            while let byte = peek(0), Self.isWhitespace(byte) { offset += 1 }
        }

        func peek(_ distance: Int) -> UInt8? {
            let index = offset + distance
            return index < bytes.count ? bytes[index] : nil
        }

        static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 || byte == 0x00
        }

        static func endsToken(_ byte: UInt8) -> Bool {
            isWhitespace(byte) || byte == UInt8(ascii: "/") || byte == UInt8(ascii: "<") || byte == UInt8(ascii: ">")
                || byte == UInt8(ascii: "[") || byte == UInt8(ascii: "]")
        }

        static func isAlphanumeric(_ byte: UInt8) -> Bool {
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
        }

        static func latin1<Bytes: Sequence<UInt8>>(_ bytes: Bytes) -> String {
            String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
        }
    }
}
