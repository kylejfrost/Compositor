import CoreGraphics
import Foundation

/// Photoshop smart objects: a layer's placed-layer descriptor (`SoLd`, or `SoLE` for a linked file) and the
/// document-level linked-layer entries (`lnk2`, `lnkD`, `lnk3`, `lnkE`) that hold the contents. Original
/// implementation from Adobe's *Photoshop File Formats Specification* ("Linked Layer", "Placed Layer Data"), with the
/// field order psd-tools' `LinkedLayer.read` uses.
///
/// A linked-layer block is a run of entries, each a `u64` length, its bytes and zero padding to 4. An entry is
/// `kind(4) u32 version`, a Pascal uuid, a Unicode file name, `fileType(4) creator(4) u64 dataSize u8 hasOpenFile`
/// and, when set, a descriptor block; then by kind — `liFE`: a descriptor block, from version 4 a 16-byte timestamp,
/// `u64` file size, from version 3 the data; `liFA`: 8 zero bytes; `liFD`: the data — then from version 5 a Unicode
/// child ID, from 6 an `f64` modification time, from 7 a `u8` lock state, and for `liFE` version 2 the data last.
///
/// Contents are never copied: entries and payloads are slices of the block that was read.
nonisolated enum PSDSmartObjects {
    static let linkedBlockKeys: Set<String> = ["lnk2", "lnkD", "lnk3", "lnkE"]
    /// The placed-layer blocks a smart object's settings are read from, in order of preference.
    static let placementKeys = ["SoLd", "SoLE"]

    /// One linked-layer entry, parsed.
    struct Entry {
        var uniqueID: String
        var fileName: String
        var fileType: String
        var link: LinkedEntryInfo
        /// The contents, a slice of the entry. Nil for an alias, or a linked file stored without a copy.
        var data: Data?
    }

    // MARK: Linked-layer entries

    /// The entries in a linked-layer block's payload, as slices of it. Nil when the payload isn't whole entries.
    static func entries(inBlock payload: Data) -> [Data]? {
        var entries: [Data] = []
        var offset = payload.startIndex
        while offset < payload.endIndex {
            guard payload.endIndex - offset >= 8 else { return nil }
            let high = u32(payload, offset), low = u32(payload, offset + 4)
            offset += 8
            guard high == 0, Int(low) <= payload.endIndex - offset else { return nil }
            let length = Int(low)
            entries.append(payload[offset ..< offset + length])
            offset += length
            let pad = min((4 - length % 4) % 4, payload.endIndex - offset)
            guard payload[offset ..< offset + pad].allSatisfy({ $0 == 0 }) else { return nil }
            offset += pad
        }
        return entries
    }

    static func parseEntry(_ entry: Data) throws -> Entry {
        var reader = Reader(data: entry)
        let kind = try reader.code()
        guard LinkedEntryInfo.kinds.contains(kind) else { throw PSDError.truncated }
        let version = Int(try reader.u32())
        guard (1...8).contains(version) else { throw PSDError.truncated }
        let uuidBytes = try reader.bytes(Int(try reader.u8()))
        let uniqueID = String(data: uuidBytes, encoding: .macOSRoman) ?? ""
        var fileName = try reader.unicode()
        var nulCount = 0
        while fileName.hasSuffix("\0") {
            fileName.removeLast()
            nulCount += 1
        }
        let fileType = try reader.code()
        let creator = try reader.code()
        let dataSize = try reader.u64()
        guard dataSize <= UInt64(entry.count) else { throw PSDError.truncated }
        let size = Int(dataSize)
        var link = LinkedEntryInfo(kind: kind, version: version, creator: creator)
        if nulCount != 1 { link.fileNameNULCount = nulCount }
        if try reader.u8() != 0 { link.openFileDescriptor = try reader.descriptorBlock() }
        var data: Data?
        switch kind {
        case "liFE":
            link.externalDescriptor = try reader.descriptorBlock()
            if version > 3 { link.timestamp = try reader.bytes(16) }
            let fileSize = try reader.u64()
            guard fileSize <= UInt64(Int64.max) else { throw PSDError.truncated }
            link.externalFileSize = Int64(fileSize)
            if version > 2 { data = try reader.bytes(size) }
        case "liFA":
            try reader.skip(8)
        default:
            data = try reader.bytes(size)
        }
        if version >= 5 { link.childID = try reader.unicode() }
        if version >= 6 { link.modTime = Double(bitPattern: try reader.u64()) }
        if version >= 7 { link.lockState = try reader.u8() }
        if kind == "liFE", version == 2 { data = try reader.bytes(size) }
        // Bytes no version documents are kept to be written back, unless they're more than a project keeps inline.
        let rest = entry.count - reader.offset
        if rest > 0, rest <= LinkedEntryInfo.maximumDescriptorBytes { link.trailingBytes = Data(try reader.bytes(rest)) }
        return Entry(uniqueID: uniqueID, fileName: fileName, fileType: fileType, link: link, data: data)
    }

    /// `blocks` without the linked-layer blocks, every entry those held (slices, in file order), and where the first
    /// of them was: the index in the returned blocks of the block that followed it (their count when it came last).
    /// A linked-layer block whose payload isn't whole entries is left among the blocks as it was.
    static func decompose(_ blocks: [PSDTaggedBlock]) -> (blocks: [PSDTaggedBlock], entries: [Data], position: Int?) {
        var kept: [PSDTaggedBlock] = []
        var entries: [Data] = []
        var position: Int?
        for block in blocks {
            if linkedBlockKeys.contains(block.key), let split = self.entries(inBlock: block.data) {
                entries += split
                if position == nil { position = kept.count }
            } else {
                kept.append(block)
            }
        }
        return (kept, entries, position)
    }

    // MARK: Placement

    /// The settings in a `SoLd`/`SoLE` block (`"soLD"`, `u32` version, descriptor block), with its quads (document
    /// pixels in the file) in `transform`'s unit coordinates. The file name, type and link come from the entry
    /// (`resolve`). Throws when the settings can't be read or aren't usable.
    static func placement(_ block: Data, in transform: LayerTransform) throws -> SmartObjectInfo {
        guard block.count >= 8, String(data: block.prefix(4), encoding: .isoLatin1) == "soLD" else {
            throw PSDError.truncated
        }
        var offset = 8
        let descriptor = try PSDDescriptorReader.readBlock(block, at: &offset)
        guard let uniqueID = descriptor.string("Idnt"),
              let placed = quad(descriptor.list("Trnf")),
              let size = descriptor.object("Sz  "),
              let width = number(size["Wdth"]), let height = number(size["Hght"]) else { throw PSDError.truncated }
        let nonAffine = quad(descriptor.list("nonAffineTransform")).flatMap { $0 == placed ? nil : $0 }
        var info = SmartObjectInfo(
            uniqueID: uniqueID, placedID: descriptor.string("placed") ?? "", fileType: "", fileName: "",
            naturalSize: CGSize(width: width, height: height), resolution: number(descriptor["Rslt"]) ?? 72,
            quad: placed.unitQuad(in: transform), nonAffineQuad: nonAffine?.unitQuad(in: transform),
            placedType: descriptor.int("Type") ?? 2, isEmbedded: false)
        info.pageNumber = descriptor.int("PgNm") ?? 1
        info.pageCount = descriptor.int("totalPages") ?? 1
        info.antiAlias = descriptor.int("Annt") ?? 16
        info.crop = descriptor.int("Crop") ?? 1
        guard info.isValid else { throw PSDError.truncated }
        return info
    }

    /// Each smart object's contents found among `entries` by `uniqueID`: the entry's file name, type and link go into
    /// its settings, and its contents become the payload, one shared by every smart object naming the entry.
    /// Settings with no entry keep no payload and aren't embedded. Returns the smart objects, index for index
    /// (nil where `placements` is nil, or where the entry's fields aren't usable), and the entries no smart object
    /// names, verbatim — those are kept to be written back.
    static func resolve(_ placements: [SmartObjectInfo?], entries: [Data]) -> (smartObjects: [LayerSmartObject?], orphans: [Data]) {
        var byID: [String: (index: Int, entry: Entry)] = [:]
        for (index, raw) in entries.enumerated() {
            guard let entry = try? parseEntry(raw), byID[entry.uniqueID] == nil else { continue }
            byID[entry.uniqueID] = (index, entry)
        }
        var used = Set<Int>()
        var payloads: [Int: SmartObjectPayload] = [:]
        let smartObjects = placements.map { placement -> LayerSmartObject? in
            guard var info = placement else { return nil }
            guard let match = byID[info.uniqueID] else { return LayerSmartObject(info: info, payload: nil) }
            info.fileName = match.entry.fileName
            info.fileType = match.entry.fileType
            info.link = match.entry.link
            info.isEmbedded = match.entry.link.kind == "liFD"
            guard info.isValid else { return nil }
            used.insert(match.index)
            guard let data = match.entry.data else { return LayerSmartObject(info: info, payload: nil) }
            let payload = payloads[match.index] ?? SmartObjectPayload(data: data)
            payloads[match.index] = payload
            return LayerSmartObject(info: info, payload: payload)
        }
        let orphans = entries.enumerated().filter { !used.contains($0.offset) }.map(\.element)
        return (smartObjects, orphans)
    }

    // MARK: Helpers

    /// Eight numbers, top-left, top-right, bottom-right, bottom-left, as a quad.
    private static func quad(_ values: [PSDDescriptorValue]?) -> PlacementQuad? {
        guard let values, values.count == 8 else { return nil }
        let numbers = values.compactMap(number)
        guard numbers.count == 8, numbers.allSatisfy(\.isFinite) else { return nil }
        return PlacementQuad(topLeft: CGPoint(x: numbers[0], y: numbers[1]), topRight: CGPoint(x: numbers[2], y: numbers[3]),
                             bottomRight: CGPoint(x: numbers[4], y: numbers[5]), bottomLeft: CGPoint(x: numbers[6], y: numbers[7]))
    }

    private static func number(_ value: PSDDescriptorValue?) -> Double? {
        switch value {
        case .double(let number)?: number
        case .unitFloat(_, let number)?: number
        case .integer(let number)?: Double(number)
        default: nil
        }
    }

    private static func u32(_ data: Data, _ at: Int) -> UInt32 {
        UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3])
    }

    /// Bounds-checked reads of an entry; offsets count from its start. `bytes` returns slices.
    private struct Reader {
        let data: Data
        var offset = 0

        mutating func need(_ count: Int) throws {
            guard count >= 0, count <= data.count - offset else { throw PSDError.truncated }
        }

        mutating func bytes(_ count: Int) throws -> Data {
            try need(count)
            let start = data.startIndex + offset
            offset += count
            return data[start ..< start + count]
        }

        mutating func skip(_ count: Int) throws {
            try need(count)
            offset += count
        }

        mutating func u8() throws -> UInt8 {
            try need(1)
            defer { offset += 1 }
            return data[data.startIndex + offset]
        }

        mutating func u32() throws -> UInt32 {
            try need(4)
            defer { offset += 4 }
            return PSDSmartObjects.u32(data, data.startIndex + offset)
        }

        mutating func u64() throws -> UInt64 {
            let high = UInt64(try u32())
            return high << 32 | UInt64(try u32())
        }

        /// Four bytes, one Latin-1 character each.
        mutating func code() throws -> String {
            String(String.UnicodeScalarView(try bytes(4).map { Unicode.Scalar($0) }))
        }

        /// `u32` UTF-16 code-unit count, then UTF-16BE, kept whole (a trailing NUL included).
        mutating func unicode() throws -> String {
            let count = Int(try u32())
            guard count <= (data.count - offset) / 2 else { throw PSDError.truncated }
            let raw = try bytes(count * 2)
            var units: [UInt16] = []
            units.reserveCapacity(count)
            var index = raw.startIndex
            while index < raw.endIndex {
                units.append(UInt16(raw[index]) << 8 | UInt16(raw[index + 1]))
                index += 2
            }
            return String(decoding: units, as: UTF16.self)
        }

        /// A descriptor block (`u32` version, descriptor), as its bytes.
        mutating func descriptorBlock() throws -> Data {
            let start = offset
            try skip(4)
            // The reader counts from the slice's start, so the rest of the entry (its contents) isn't copied.
            var length = 0
            _ = try PSDDescriptorReader.read(data[(data.startIndex + offset)...], at: &length)
            offset = start
            return try bytes(4 + length)
        }
    }
}
