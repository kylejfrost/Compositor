import CryptoKit
import Foundation

/// A field value in a diagnostic log event (`CompositorLog`): the shapes JSON has. Call sites build these on the
/// thread they run on; turning them into text, and every redaction, happens later on the log's own queue.
nonisolated enum LogValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([LogValue])
    case object([String: LogValue])
    case null

    /// `string`, or `null` for nil.
    static func text(_ value: String?) -> LogValue { value.map(LogValue.string) ?? .null }

    /// A duration in milliseconds, to a tenth: event timings.
    static func milliseconds(_ duration: Duration) -> LogValue {
        let (seconds, attoseconds) = duration.components
        let milliseconds = Double(seconds) * 1000 + Double(attoseconds) / 1e15
        return .double((milliseconds * 10).rounded() / 10)
    }

    /// Milliseconds since `start`, to a tenth.
    static func milliseconds(since start: ContinuousClock.Instant) -> LogValue {
        milliseconds(ContinuousClock.now - start)
    }
}

nonisolated extension LogValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: LogValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, LogValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// Turns one event into a line of JSON, applying the log's privacy rules to every value whoever built it:
///
/// - A field whose name mentions a token, secret, password, authorization, API key or cookie is written as
///   `"[redacted]"`, whatever it holds.
/// - `Bearer <credential>` becomes `Bearer [redacted]`, anywhere in any text.
/// - Image and other binary payloads (a `data:` URL, or a long run of base64) become their size and a SHA-256 prefix.
/// - Outside file paths, a run of 40 or more letters, digits, `_` and `-` that mixes letters with digits or cases
///   (the shape of an access token or API key) becomes `[redacted]`. Plain lowercase hex (digests) is kept.
/// - Text is cut at `textLimit` characters, paths at `pathLimit`, arrays at `arrayLimit` items, objects at
///   `objectLimit` members and nesting at `depthLimit` levels, each saying how much was left out.
///
/// The line starts `{"ts":…,"level":…,"cat":…,"event":…` so tools can filter by time with plain text
/// comparisons (scripts/collect-logs.sh does), then the fields in name order.
nonisolated enum LogEncoding {
    static let textLimit = 300
    static let pathLimit = 1024
    static let arrayLimit = 20
    static let objectLimit = 50
    static let depthLimit = 6
    /// Base64 at least this long is taken for a binary payload rather than a word.
    static let binaryThreshold = 200
    /// The shortest run of token characters taken for a credential.
    static let tokenRunLength = 40
    static let redacted = "[redacted]"

    /// The line for one event, without its newline.
    static func line(date: Date, level: String, category: String, event: String, fields: [String: LogValue]) -> String {
        var out = "{\"ts\":\"" + timestamp(date) + "\",\"level\":"
        appendQuoted(level, to: &out)
        out += ",\"cat\":"
        appendQuoted(category, to: &out)
        out += ",\"event\":"
        appendQuoted(clean(event, isPath: false), to: &out)
        for key in fields.keys.sorted() where !reservedKeys.contains(key) {
            out += ","
            appendQuoted(key, to: &out)
            out += ":"
            append(fields[key] ?? .null, key: key, depth: 0, to: &out)
        }
        return out + "}"
    }

    /// Names the line itself sets; a field by one of these names is dropped rather than written twice.
    static let reservedKeys: Set<String> = ["ts", "level", "cat", "event"]

    /// ISO 8601 in UTC with milliseconds, fixed width: `2026-09-24T14:03:05.123Z`.
    static func timestamp(_ date: Date) -> String {
        // To the nearest millisecond, from the whole count: the fraction alone loses a millisecond to rounding error.
        let total = Int64((date.timeIntervalSince1970 * 1000).rounded())
        var seconds = time_t(total / 1000)
        let milliseconds = Int(total - Int64(seconds) * 1000)
        var parts = tm()
        gmtime_r(&seconds, &parts)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", Int(parts.tm_year) + 1900, Int(parts.tm_mon) + 1,
                      Int(parts.tm_mday), Int(parts.tm_hour), Int(parts.tm_min), Int(parts.tm_sec), milliseconds)
    }

    // MARK: Field names

    /// Whether a field by this name holds a credential: its value is never written.
    static func isSecretKey(_ key: String) -> Bool {
        let name = key.lowercased()
        return ["token", "secret", "password", "passwd", "authorization", "api_key", "apikey", "cookie", "credential"]
            .contains { name.contains($0) }
    }

    /// Whether a field by this name holds file paths or URLs: kept whole (to `pathLimit`), never taken for a token.
    static func isPathKey(_ key: String) -> Bool {
        let name = key.lowercased()
        return ["path", "paths", "file", "files", "folder", "directory", "dir", "save_to", "url", "endpoint",
                "endpoint_file"].contains(name) || name.hasSuffix("_path") || name.hasSuffix("_paths")
            || name.hasSuffix("_file") || name.hasSuffix("_url")
    }

    // MARK: Values

    private static func append(_ value: LogValue, key: String, depth: Int, to out: inout String) {
        if isSecretKey(key) {
            appendQuoted(redacted, to: &out)
            return
        }
        switch value {
        case .string(let text):
            appendQuoted(clean(text, isPath: isPathKey(key)), to: &out)
        case .int(let number):
            out += String(number)
        case .double(let number):
            out += number.isFinite ? String(number) : "null"
        case .bool(let flag):
            out += flag ? "true" : "false"
        case .null:
            out += "null"
        case .array(let items):
            guard depth < depthLimit else { appendQuoted("[…]", to: &out); return }
            out += "["
            for (index, item) in items.prefix(arrayLimit).enumerated() {
                if index > 0 { out += "," }
                // Items take their array's name: a list of paths stays paths.
                append(item, key: key, depth: depth + 1, to: &out)
            }
            if items.count > arrayLimit {
                out += ","
                appendQuoted("…(+\(items.count - arrayLimit) more)", to: &out)
            }
            out += "]"
        case .object(let members):
            guard depth < depthLimit else { appendQuoted("{…}", to: &out); return }
            out += "{"
            let names = members.keys.sorted()
            for (index, name) in names.prefix(objectLimit).enumerated() {
                if index > 0 { out += "," }
                appendQuoted(name, to: &out)
                out += ":"
                append(members[name] ?? .null, key: name, depth: depth + 1, to: &out)
            }
            if names.count > objectLimit {
                out += ",\"…\":"
                appendQuoted("(+\(names.count - objectLimit) more)", to: &out)
            }
            out += "}"
        }
    }

    /// `text` as it may be written: binary summarized, credentials redacted, then cut to length.
    static func clean(_ text: String, isPath: Bool) -> String {
        if let binary = binarySummary(text) { return binary }
        let limit = isPath ? pathLimit : textLimit
        // Only the part that can survive the cut is examined; a run cut short here lies past the limit anyway.
        let examined = text.count > limit * 4 ? String(text.prefix(limit * 4)) : text
        var cleaned = redactingBearer(examined)
        // A path isn't searched for token-shaped runs: long file names would be mangled, and a path only names a
        // file on the owner's own Mac.
        if !isPath { cleaned = redactingTokenRuns(cleaned) }
        return truncated(cleaned, originalCount: text.count, limit: limit)
    }

    /// `[binary N chars sha256:…]` for a `data:` URL or a long run of base64; nil for anything else.
    static func binarySummary(_ text: String) -> String? {
        let utf8 = text.utf8
        let isDataURL = text.hasPrefix("data:") && text.prefix(100).contains(";base64,")
        guard isDataURL || (utf8.count >= binaryThreshold && utf8.allSatisfy(isBase64Byte)) else { return nil }
        let digest = SHA256.hash(data: Data(utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "[binary \(utf8.count) chars sha256:\(digest)]"
    }

    private static func isBase64Byte(_ byte: UInt8) -> Bool {
        isTokenByte(byte) || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "/") || byte == UInt8(ascii: "=")
            || byte == 0x0A || byte == 0x0D
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
            || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
    }

    /// Replaces what follows `Bearer ` (any case) up to the next space.
    static func redactingBearer(_ text: String) -> String {
        guard text.range(of: "bearer ", options: .caseInsensitive) != nil else { return text }
        var result = ""
        var rest = Substring(text)
        while let found = rest.range(of: "bearer ", options: .caseInsensitive) {
            result += rest[..<found.upperBound]
            rest = rest[found.upperBound...]
            let end = rest.firstIndex(where: { $0 == " " || $0 == "\"" || $0 == "\n" || $0 == "," }) ?? rest.endIndex
            if end > rest.startIndex { result += redacted }
            rest = rest[end...]
        }
        return result + rest
    }

    /// Replaces each credential-shaped run (see the type's summary) with `[redacted]`.
    static func redactingTokenRuns(_ text: String) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count >= tokenRunLength else { return text }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        var changed = false
        while index < bytes.count {
            guard isTokenByte(bytes[index]) else {
                output.append(bytes[index])
                index += 1
                continue
            }
            var end = index
            while end < bytes.count, isTokenByte(bytes[end]) { end += 1 }
            let run = bytes[index..<end]
            if run.count >= tokenRunLength, looksLikeCredential(run) {
                output.append(contentsOf: Array(redacted.utf8))
                changed = true
            } else {
                output.append(contentsOf: run)
            }
            index = end
        }
        return changed ? String(decoding: output, as: UTF8.self) : text
    }

    /// Letters mixed with digits, or both cases: random, not a word. Lowercase hex (a digest) doesn't count.
    private static func looksLikeCredential(_ run: ArraySlice<UInt8>) -> Bool {
        var lower = false, upper = false, digit = false, nonHexLower = false
        for byte in run {
            switch byte {
            case 0x30...0x39: digit = true
            case 0x41...0x5A: upper = true
            case 0x61...0x7A:
                lower = true
                if byte > UInt8(ascii: "f") { nonHexLower = true }
            default: break
            }
        }
        if lower, !upper, digit, !nonHexLower { return false }
        return [lower, upper, digit].filter { $0 }.count >= 2
    }

    /// `text` cut to `limit` characters, saying how long the original was when anything was left out (`text` may
    /// be the original's examined prefix, redacted).
    private static func truncated(_ text: String, originalCount: Int, limit: Int) -> String {
        guard text.count > limit || originalCount > limit * 4 else { return text }
        return text.prefix(limit) + "…(\(originalCount) chars in all)"
    }

    // MARK: JSON text

    static func appendQuoted(_ text: String, to out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}
