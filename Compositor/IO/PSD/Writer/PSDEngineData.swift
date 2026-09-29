import Foundation

/// Writes Photoshop's text EngineData (the `tdta` markup of a `TySh` text descriptor) laid out byte for byte as
/// Photoshop and psd-tools 1.19 (`psd_tools/psd/engine_data.py`) write it: two newlines, then `<<`; each `/Key value`
/// on its own line, tab-indented one level deeper than its dictionary; a dictionary value on the lines after its key;
/// an array of dictionaries likewise, closed by `]` on a line of its own; other arrays on one line (`[ 1.0 .5 ]`);
/// strings as UTF-16BE after an FE FF byte-order mark with `(`, `)` and `\` bytes escaped. The inverse of
/// `EngineDataParser`. Original implementation.
nonisolated enum PSDEngineDataWriter {
    /// `value`, a dictionary, as a complete EngineData document.
    static func data(_ value: EngineValue) -> Data {
        var data = Data()
        write(value, indent: 0, into: &data)
        return data
    }

    /// A number as psd-tools writes a float: `%.8f` without its trailing zeros, one zero kept after the point
    /// (`72.0`), and the zero before the point dropped between -1 and 1 (`.5`, `-.25`). Negative zero and non-finite
    /// values, which Photoshop never writes, are written as `0.0`.
    static func number(_ value: Double) -> String {
        let value = value.isFinite && value != 0 ? value : 0
        var text = String(format: "%.8f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text += "0" }
        if value != 0, abs(value) < 1 { text = text.replacingOccurrences(of: "0.", with: ".") }
        return text
    }

    /// `indent` is nil inside a one-line array, where psd-tools separates everything with single spaces.
    private static func write(_ value: EngineValue, indent: Int?, into data: inout Data) {
        switch value {
        case .dictionary(let items):
            let inner = indent.map { $0 + 1 }
            if indent == 0 { newline(indent, into: &data) }
            newline(indent, into: &data)
            tabs(indent, into: &data)
            append("<<", to: &data)
            newline(indent, into: &data)
            for item in items {
                tabs(inner, into: &data)
                data.append(UInt8(ascii: "/"))
                data.append(contentsOf: macRoman(item.key))
                switch item.value {
                case .dictionary:
                    write(item.value, indent: inner, into: &data)
                case .array(let elements):
                    data.append(UInt8(ascii: " "))
                    if case .dictionary? = elements.first {
                        write(item.value, indent: inner, into: &data)
                    } else {
                        write(item.value, indent: nil, into: &data)
                    }
                default:
                    data.append(UInt8(ascii: " "))
                    write(item.value, indent: indent, into: &data)
                }
                newline(indent, into: &data)
            }
            tabs(indent, into: &data)
            append(">>", to: &data)
        case .array(let elements):
            data.append(UInt8(ascii: "["))
            if let indent {
                for element in elements {
                    if case .dictionary = element {
                        write(element, indent: indent, into: &data)
                    } else {
                        data.append(UInt8(ascii: " "))
                        write(element, indent: nil, into: &data)
                    }
                }
                newline(indent, into: &data)
                tabs(indent, into: &data)
            } else {
                for element in elements {
                    // A dictionary here writes its own leading space.
                    if case .dictionary = element {} else { data.append(UInt8(ascii: " ")) }
                    write(element, indent: nil, into: &data)
                }
                data.append(UInt8(ascii: " "))
            }
            data.append(UInt8(ascii: "]"))
        case .string(let string):
            data.append(contentsOf: [UInt8(ascii: "("), 0xFE, 0xFF])
            for unit in string.utf16 {
                for byte in [UInt8(unit >> 8), UInt8(unit & 0xFF)] {
                    if byte == UInt8(ascii: "\\") || byte == UInt8(ascii: "(") || byte == UInt8(ascii: ")") {
                        data.append(UInt8(ascii: "\\"))
                    }
                    data.append(byte)
                }
            }
            data.append(UInt8(ascii: ")"))
        case .integer(let integer):
            append(String(integer), to: &data)
        case .number(let number):
            append(self.number(number), to: &data)
        case .bool(let flag):
            append(flag ? "true" : "false", to: &data)
        case .tag(let tag):
            data.append(contentsOf: macRoman(tag))
        }
    }

    /// A line break, except inside a one-line array.
    private static func newline(_ indent: Int?, into data: inout Data) {
        if indent != nil { data.append(UInt8(ascii: "\n")) }
    }

    /// `indent` tabs; inside a one-line array, the single space that separates tokens there.
    private static func tabs(_ indent: Int?, into data: inout Data) {
        if let indent {
            data.append(contentsOf: [UInt8](repeating: UInt8(ascii: "\t"), count: indent))
        } else {
            data.append(UInt8(ascii: " "))
        }
    }

    private static func append(_ text: String, to data: inout Data) {
        data.append(contentsOf: Array(text.utf8))
    }

    /// Keys and tags as psd-tools encodes them (Mac OS Roman); a character it can't hold becomes `?`.
    private static func macRoman(_ text: String) -> Data {
        text.data(using: .macOSRoman, allowLossyConversion: true) ?? Data(text.utf8)
    }
}
