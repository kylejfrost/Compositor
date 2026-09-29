import Foundation

/// Encodes Photoshop action descriptors the way Photoshop writes them: descriptor and class
/// names as UTF-16BE with a counted trailing NUL, `TEXT` with a counted trailing NUL, and
/// keys and class IDs in the length form `PSDKey` carries (four-character charIDs with
/// length 0). The inverse of `PSDDescriptorReader`: parsed descriptors re-encode byte-exact.
nonisolated enum PSDDescriptorWriter {
    /// `u32 16` + descriptor (`SoCo`, `vstk`, `TySh` text and warp).
    static func block(_ descriptor: PSDDescriptor) -> Data {
        var data = Data()
        append(UInt32(16), to: &data)
        append(descriptor, to: &data)
        return data
    }

    /// `u32 version` + `u32 16` + descriptor (`vogk`, `lfx2`).
    static func block2(_ descriptor: PSDDescriptor, version: UInt32) -> Data {
        var data = Data()
        append(version, to: &data)
        data.append(block(descriptor))
        return data
    }

    /// The descriptor alone (`vscg` after its key and version).
    static func bare(_ descriptor: PSDDescriptor) -> Data {
        var data = Data()
        append(descriptor, to: &data)
        return data
    }

    private static func append(_ descriptor: PSDDescriptor, to data: inout Data) {
        appendUnicode(descriptor.name, to: &data)
        appendKey(descriptor.classID, to: &data)
        append(UInt32(truncatingIfNeeded: descriptor.items.count), to: &data)
        for item in descriptor.items {
            appendKey(item.key, to: &data)
            append(item.value, to: &data)
        }
    }

    /// OSType followed by the value's payload.
    private static func append(_ value: PSDDescriptorValue, to data: inout Data) {
        switch value {
        case .object(let descriptor):
            appendCode("Objc", to: &data)
            append(descriptor, to: &data)
        case .globalObject(let descriptor):
            appendCode("GlbO", to: &data)
            append(descriptor, to: &data)
        case .list(let values):
            appendCode("VlLs", to: &data)
            appendList(values, to: &data)
        case .reference(let values):
            appendCode("obj ", to: &data)
            appendList(values, to: &data)
        case .double(let number):
            appendCode("doub", to: &data)
            append(number.bitPattern, to: &data)
        case .unitFloat(let unit, let number):
            appendCode("UntF", to: &data)
            appendCode(unit, to: &data)
            append(number.bitPattern, to: &data)
        case .unitFloats(let unit, let numbers):
            appendCode("UnFl", to: &data)
            appendCode(unit, to: &data)
            append(UInt32(truncatingIfNeeded: numbers.count), to: &data)
            for number in numbers { append(number.bitPattern, to: &data) }
        case .string(let string):
            appendCode("TEXT", to: &data)
            appendUnicode(string, to: &data)
        case .unicodeUnits(let units):
            appendCode("TEXT", to: &data)
            append(UInt32(truncatingIfNeeded: units.count), to: &data)
            appendUnits(units, to: &data)
        case .enumerated(let type, let enumValue):
            appendCode("enum", to: &data)
            appendKey(type, to: &data)
            appendKey(enumValue, to: &data)
        case .integer(let number):
            appendCode("long", to: &data)
            append(UInt32(bitPattern: number), to: &data)
        case .largeInteger(let number):
            appendCode("comp", to: &data)
            append(UInt64(bitPattern: number), to: &data)
        case .bool(let flag):
            appendCode("bool", to: &data)
            data.append(flag ? 1 : 0)
        case .classRef(let name, let id):
            appendCode("type", to: &data)
            appendUnicode(name, to: &data)
            appendKey(id, to: &data)
        case .globalClass(let name, let id):
            appendCode("GlbC", to: &data)
            appendUnicode(name, to: &data)
            appendKey(id, to: &data)
        case .alias(let bytes):
            appendCode("alis", to: &data)
            appendLengthBlock(bytes, to: &data)
        case .rawData(let bytes):
            appendCode("tdta", to: &data)
            appendLengthBlock(bytes, to: &data)
        case .path(let bytes):
            appendCode("Pth ", to: &data)
            appendLengthBlock(bytes, to: &data)
        case .objectArray(let bytes):
            appendCode("ObAr", to: &data)
            data.append(bytes)
        case .referenceItem(let type, let bytes):
            appendCode(type, to: &data)
            data.append(bytes)
        }
    }

    private static func appendList(_ values: [PSDDescriptorValue], to data: inout Data) {
        append(UInt32(truncatingIfNeeded: values.count), to: &data)
        for value in values { append(value, to: &data) }
    }

    private static func appendLengthBlock(_ bytes: Data, to data: inout Data) {
        append(UInt32(truncatingIfNeeded: bytes.count), to: &data)
        data.append(bytes)
    }

    /// Key or class ID: a four-character charID is written with length 0, anything else
    /// (including an explicit-length four-character stringID) with its length.
    private static func appendKey(_ key: PSDKey, to data: inout Data) {
        let bytes = latin1(key.id)
        append(UInt32(bytes.count == 4 && !key.explicitLength ? 0 : bytes.count), to: &data)
        data.append(contentsOf: bytes)
    }

    /// Exactly four bytes (OSType or unit), space-padded or truncated.
    private static func appendCode(_ code: String, to data: inout Data) {
        let bytes = latin1(code)
        data.append(contentsOf: (bytes + [UInt8](repeating: 0x20, count: 4)).prefix(4))
    }

    /// UTF-16 code-unit count including a trailing NUL, then UTF-16BE, then the NUL.
    private static func appendUnicode(_ string: String, to data: inout Data) {
        let units = Array(string.utf16)
        append(UInt32(truncatingIfNeeded: units.count + 1), to: &data)
        appendUnits(units, to: &data)
        data.append(contentsOf: [0, 0])
    }

    private static func appendUnits(_ units: [UInt16], to data: inout Data) {
        for unit in units { data.append(UInt8(unit >> 8)); data.append(UInt8(unit & 0xFF)) }
    }

    private static func latin1(_ string: String) -> [UInt8] {
        string.unicodeScalars.map { $0.value <= 0xFF ? UInt8($0.value) : UInt8(ascii: "?") }
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}
