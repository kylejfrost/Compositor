import CoreGraphics
import Foundation

/// A descriptor key, class ID or enum term. Photoshop writes most four-character terms
/// (charIDs) with length 0 but some (`warp`, `view`) as stringIDs with an explicit length of
/// 4; the two are different terms, so the form is kept for a byte-exact rewrite.
nonisolated struct PSDKey: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    var id: String
    /// True when the term is written with its byte length rather than length 0.
    var explicitLength: Bool

    /// A literal of exactly four characters is a charID (length 0); anything else has its length.
    init(_ id: String, explicitLength: Bool? = nil) {
        self.id = id
        self.explicitLength = explicitLength ?? (id.unicodeScalars.count != 4)
    }

    init(stringLiteral value: String) { self.init(value) }

    var description: String { id }
}

/// One value in a Photoshop action descriptor, from Adobe’s *Photoshop File Formats
/// Specification* (“Descriptor structure”). Original implementation.
nonisolated indirect enum PSDDescriptorValue: Equatable, Sendable {
    /// `Objc`.
    case object(PSDDescriptor)
    /// `GlbO`.
    case globalObject(PSDDescriptor)
    /// `VlLs`.
    case list([PSDDescriptorValue])
    /// `doub`.
    case double(Double)
    /// `UntF`: a four-character unit such as `#Pxl`, `#Prc`, `#Ang`, `#Pnt`.
    case unitFloat(unit: String, value: Double)
    /// `UnFl`.
    case unitFloats(unit: String, values: [Double])
    /// `TEXT`, without its trailing NUL.
    case string(String)
    /// `TEXT` whose UTF-16 code units (as written, including any NUL) don't survive decoding,
    /// such as lone surrogates or a missing trailing NUL.
    case unicodeUnits([UInt16])
    /// `enum`.
    case enumerated(type: PSDKey, value: PSDKey)
    /// `long`.
    case integer(Int32)
    /// `comp`.
    case largeInteger(Int64)
    /// `bool`.
    case bool(Bool)
    /// `type`.
    case classRef(name: String, id: PSDKey)
    /// `GlbC`.
    case globalClass(name: String, id: PSDKey)
    /// `alis`: the bytes after the length.
    case alias(Data)
    /// `tdta`: the bytes after the length.
    case rawData(Data)
    /// `obj `: reference items, each normally a `.referenceItem`.
    case reference([PSDDescriptorValue])
    /// `ObAr`: the undocumented object array, kept as its raw bytes (item count + descriptor body).
    case objectArray(Data)
    /// `Pth `: the bytes after the length.
    case path(Data)
    /// A reference form (`prop`, `Clss`, `Enmr`, `rele`, `Idnt`, `indx`, `name`), wherever it
    /// appears, kept as raw bytes so references survive a rewrite unchanged.
    case referenceItem(type: String, data: Data)
}

/// A Photoshop action descriptor: a Unicode name, a class ID, and ordered key/value items.
nonisolated struct PSDDescriptor: Equatable, Sendable {
    var name: String
    var classID: PSDKey
    var items: [(key: PSDKey, value: PSDDescriptorValue)]

    init(name: String = "", classID: PSDKey, items: [(key: PSDKey, value: PSDDescriptorValue)] = []) {
        self.name = name
        self.classID = classID
        self.items = items
    }

    static func == (lhs: PSDDescriptor, rhs: PSDDescriptor) -> Bool {
        lhs.name == rhs.name && lhs.classID == rhs.classID && lhs.items.count == rhs.items.count
            && zip(lhs.items, rhs.items).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }

    /// The first item with this key, in either length form.
    subscript(_ key: String) -> PSDDescriptorValue? {
        items.first { $0.key.id == key }?.value
    }

    func double(_ key: String) -> Double? {
        guard case .double(let value)? = self[key] else { return nil }
        return value
    }

    func unit(_ key: String) -> (unit: String, value: Double)? {
        guard case .unitFloat(let unit, let value)? = self[key] else { return nil }
        return (unit, value)
    }

    func int(_ key: String) -> Int? {
        switch self[key] {
        case .integer(let value)?: Int(value)
        case .largeInteger(let value)?: Int(exactly: value)
        default: nil
        }
    }

    func bool(_ key: String) -> Bool? {
        guard case .bool(let value)? = self[key] else { return nil }
        return value
    }

    func string(_ key: String) -> String? {
        switch self[key] {
        case .string(let value)?: value
        case .unicodeUnits(let units)?:
            String(decoding: units.last == 0 ? units.dropLast() : units[...], as: UTF16.self)
        default: nil
        }
    }

    func enumValue(_ key: String) -> String? {
        guard case .enumerated(_, let value)? = self[key] else { return nil }
        return value.id
    }

    func object(_ key: String) -> PSDDescriptor? {
        switch self[key] {
        case .object(let value)?, .globalObject(let value)?: value
        default: nil
        }
    }

    func list(_ key: String) -> [PSDDescriptorValue]? {
        guard case .list(let value)? = self[key] else { return nil }
        return value
    }

    /// An `RGBC` color object under `key`, as components in 0…255. Reads `Rd`/`Grn`/`Bl`,
    /// or the 0…1 `redFloat`/`greenFloat`/`blueFloat` form some Photoshop versions write.
    func rgb(_ key: String) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        guard let color = object(key) else { return nil }
        func clamp(_ value: Double) -> CGFloat? {
            guard value.isFinite else { return nil }
            return CGFloat(min(255, max(0, value)))
        }
        if let r = color.number("Rd  "), let g = color.number("Grn "), let b = color.number("Bl  "),
           let red = clamp(r), let green = clamp(g), let blue = clamp(b) {
            return (red, green, blue)
        }
        if let r = color.number("redFloat"), let g = color.number("greenFloat"), let b = color.number("blueFloat"),
           let red = clamp(r * 255), let green = clamp(g * 255), let blue = clamp(b * 255) {
            return (red, green, blue)
        }
        return nil
    }

    private func number(_ key: String) -> Double? {
        switch self[key] {
        case .double(let value)?: value
        case .integer(let value)?: Double(value)
        case .unitFloat(_, let value)?: value
        default: nil
        }
    }
}

/// Reads descriptors structurally. Every read is bounds-checked, nesting is limited to
/// `maxDepth`, and counts are checked against the bytes that remain, so malformed input
/// throws `PSDError.truncated` instead of trapping or allocating without bound.
/// Offsets are relative to `data.startIndex`.
nonisolated enum PSDDescriptorReader {
    static let maxDepth = 64

    /// `u32 descriptorVersion (16)` followed by a descriptor (`SoCo`, `vstk`, `TySh`, and after
    /// their own version fields `vogk`, `lfx2`, `SoLd`).
    static func readBlock(_ data: Data, at offset: inout Int) throws -> PSDDescriptor {
        var reader = Reader(data: data, offset: offset)
        guard try reader.u32() == 16 else { throw PSDError.truncated }
        let descriptor = try reader.descriptor(depth: 0)
        offset = reader.offset
        return descriptor
    }

    /// A bare descriptor (`vscg` after its key and version).
    static func read(_ data: Data, at offset: inout Int) throws -> PSDDescriptor {
        var reader = Reader(data: data, offset: offset)
        let descriptor = try reader.descriptor(depth: 0)
        offset = reader.offset
        return descriptor
    }

    private nonisolated struct Reader {
        let data: Data
        var offset: Int

        var remaining: Int { data.count - offset }

        mutating func need(_ count: Int) throws {
            guard count >= 0, offset >= 0, count <= remaining else { throw PSDError.truncated }
        }

        mutating func bytes(_ count: Int) throws -> Data {
            try need(count)
            let start = data.startIndex + offset
            offset += count
            return data.subdata(in: start ..< start + count)
        }

        mutating func u8() throws -> UInt8 {
            try need(1)
            defer { offset += 1 }
            return data[data.startIndex + offset]
        }

        mutating func u32() throws -> UInt32 {
            try need(4)
            let at = data.startIndex + offset
            offset += 4
            return UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3])
        }

        mutating func u64() throws -> UInt64 {
            let high = UInt64(try u32())
            return high << 32 | UInt64(try u32())
        }

        mutating func f64() throws -> Double { Double(bitPattern: try u64()) }

        /// Validates a count against the remaining bytes, given each element's minimum size.
        mutating func count(minimumElementSize: Int) throws -> Int {
            let count = Int(try u32())
            guard count <= remaining / minimumElementSize else { throw PSDError.truncated }
            return count
        }

        mutating func ascii(_ count: Int) throws -> String {
            // Byte-for-byte ISO Latin-1, so every key byte survives a read and rewrite.
            String(String.UnicodeScalarView(try bytes(count).map { Unicode.Scalar($0) }))
        }

        /// Length-prefixed key or class ID: length 0 means a four-character code follows.
        mutating func key() throws -> PSDKey {
            let length = Int(try u32())
            return PSDKey(try ascii(length == 0 ? 4 : length), explicitLength: length != 0)
        }

        /// `u32` UTF-16 code-unit count, then UTF-16BE; a trailing NUL is dropped.
        mutating func unicode() throws -> String {
            var units = try unicodeUnits()
            if units.last == 0 { units.removeLast() }
            return String(decoding: units, as: UTF16.self)
        }

        /// `TEXT`: a `String` when that re-encodes to the same code units, else the raw units.
        mutating func text() throws -> PSDDescriptorValue {
            let units = try unicodeUnits()
            if units.last == 0 {
                let body = units.dropLast()
                let string = String(decoding: body, as: UTF16.self)
                if string.utf16.elementsEqual(body) { return .string(string) }
            }
            return .unicodeUnits(units)
        }

        mutating func unicodeUnits() throws -> [UInt16] {
            let count = Int(try u32())
            guard count <= remaining / 2 else { throw PSDError.truncated }
            let raw = try bytes(count * 2)
            var units = [UInt16]()
            units.reserveCapacity(count)
            var index = raw.startIndex
            while index < raw.endIndex {
                units.append(UInt16(raw[index]) << 8 | UInt16(raw[index + 1]))
                index += 2
            }
            return units
        }

        mutating func descriptor(depth: Int) throws -> PSDDescriptor {
            guard depth < PSDDescriptorReader.maxDepth else { throw PSDError.truncated }
            let name = try unicode()
            let classID = try key()
            // Smallest item: u32 length + 1-byte key + OSType + 1-byte bool.
            let count = try count(minimumElementSize: 10)
            var items: [(key: PSDKey, value: PSDDescriptorValue)] = []
            items.reserveCapacity(count)
            for _ in 0 ..< count {
                let key = try key()
                let type = try ascii(4)
                items.append((key, try value(type: type, depth: depth + 1)))
            }
            return PSDDescriptor(name: name, classID: classID, items: items)
        }

        mutating func value(type: String, depth: Int) throws -> PSDDescriptorValue {
            guard depth < PSDDescriptorReader.maxDepth else { throw PSDError.truncated }
            switch type {
            case "Objc":
                return .object(try descriptor(depth: depth))
            case "GlbO":
                return .globalObject(try descriptor(depth: depth))
            case "VlLs":
                return .list(try list(depth: depth))
            case "obj ":
                return .reference(try list(depth: depth))
            case "doub":
                return .double(try f64())
            case "UntF":
                let unit = try ascii(4)
                return .unitFloat(unit: unit, value: try f64())
            case "UnFl":
                let unit = try ascii(4)
                let count = try count(minimumElementSize: 8)
                var values = [Double]()
                values.reserveCapacity(count)
                for _ in 0 ..< count { values.append(try f64()) }
                return .unitFloats(unit: unit, values: values)
            case "TEXT":
                return try text()
            case "enum":
                let type = try key()
                return .enumerated(type: type, value: try key())
            case "long":
                return .integer(Int32(bitPattern: try u32()))
            case "comp":
                return .largeInteger(Int64(bitPattern: try u64()))
            case "bool":
                return .bool(try u8() != 0)
            case "type":
                let name = try unicode()
                return .classRef(name: name, id: try key())
            case "GlbC":
                let name = try unicode()
                return .globalClass(name: name, id: try key())
            case "alis":
                return .alias(try lengthBlock())
            case "tdta":
                return .rawData(try lengthBlock())
            case "Pth ":
                return .path(try lengthBlock())
            case "ObAr":
                let start = offset
                _ = try u32()
                _ = try descriptor(depth: depth)
                return .objectArray(try slice(from: start))
            case "prop", "Clss", "Enmr", "rele", "Idnt", "indx", "name":
                let start = offset
                try skipReferenceForm(type)
                return .referenceItem(type: type, data: try slice(from: start))
            default:
                throw PSDError.truncated
            }
        }

        mutating func list(depth: Int) throws -> [PSDDescriptorValue] {
            // Smallest element: OSType + 1-byte bool.
            let count = try count(minimumElementSize: 5)
            var values = [PSDDescriptorValue]()
            values.reserveCapacity(count)
            for _ in 0 ..< count {
                let type = try ascii(4)
                values.append(try value(type: type, depth: depth + 1))
            }
            return values
        }

        mutating func lengthBlock() throws -> Data {
            try bytes(Int(try u32()))
        }

        mutating func slice(from start: Int) throws -> Data {
            let end = offset
            offset = start
            return try bytes(end - start)
        }

        mutating func skipReferenceForm(_ type: String) throws {
            switch type {
            case "prop":
                _ = try unicode(); _ = try key(); _ = try key()
            case "Clss":
                _ = try unicode(); _ = try key()
            case "Enmr":
                _ = try unicode(); _ = try key(); _ = try key(); _ = try key()
            case "rele":
                _ = try unicode(); _ = try key(); _ = try u32()
            case "Idnt", "indx":
                _ = try u32()
            case "name":
                _ = try unicode(); _ = try key(); _ = try unicode()
            default:
                throw PSDError.truncated
            }
        }
    }
}
