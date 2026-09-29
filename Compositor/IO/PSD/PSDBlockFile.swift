import Foundation

/// The wire format of Photoshop tagged blocks and image resources, shared by the reader, the test fixtures, the
/// project sidecars and the writer. Original implementation from Adobe's *Photoshop File Formats Specification*.
///
/// Tagged block: `signature(4) key(4) u32 length payload`, zero-padded to `alignment` (2 inside a layer record;
/// Photoshop uses 4 for document-level blocks). In a Photoshop file an `8B64` block's length takes eight bytes, and so
/// does a `largeDocumentKeys` block's in a Large Document (PSB); `encode`/`decodeBlocks` (the project sidecars) always
/// use four, and the writer, which writes version 1, writes `8B64` blocks as `8BIM`. Image resource:
/// `signature(4) u16 id`, a Pascal name padded to an even length, `u32 length payload`, padded to even.
///
/// `decodeBlocks`/`decodeResources`/`decodeLinkedEntries` are strict (sidecars must decode fully); `scanBlocks`/`scanResources` are the
/// reader's lenient forms: they keep every block they can frame, keep a block that runs past the region as the
/// bytes that are there, and stop at the first bytes that aren't a block. Neither ever reads outside its range.
nonisolated enum PSDBlockFile {
    static let blockSignatures: Set<String> = ["8BIM", "8B64"]
    static let resourceSignatures: Set<String> = ["8BIM", "MeSa", "PHUT", "AgHg", "DCSR"]
    /// The keys whose blocks have an 8-byte length in a Large Document (PSB, version 2) file, whatever their signature.
    /// A block signed `8B64` has one in any file, whatever its key.
    static let largeDocumentKeys: Set<String> = [
        "LMsk", "Lr16", "Lr32", "Layr", "Mt16", "Mt32", "Mtrn", "Alph", "FMsk", "lnk2", "FEid", "FXid", "PxSD",
    ]

    // MARK: Tagged blocks

    /// The bytes `encode(_:alignment:)` writes, counted without writing them.
    static func encodedCount(_ blocks: [PSDTaggedBlock], alignment: Int = 2) -> Int {
        let align = max(1, alignment)
        return blocks.reduce(0) { $0 + 12 + $1.data.count + (align - $1.data.count % align) % align }
    }

    /// The bytes `encode(_:)` writes for `resources`, counted without writing them.
    static func encodedCount(_ resources: [PSDImageResource]) -> Int {
        resources.reduce(0) { total, resource in
            let name = pascalBytes(resource.name).count
            return total + 6 + 1 + name + (name + 1) % 2 + 4 + resource.data.count + resource.data.count % 2
        }
    }

    /// The bytes `encode(linkedEntries:)` writes, counted without writing them.
    static func encodedCount(linkedEntries entries: [Data]) -> Int {
        entries.reduce(0) { $0 + 8 + $1.count + (4 - $1.count % 4) % 4 }
    }

    static func encode(_ blocks: [PSDTaggedBlock], alignment: Int = 2) -> Data {
        var data = Data()
        let align = max(1, alignment)
        for block in blocks {
            data.append(code(block.signature))
            data.append(code(block.key))
            appendU32(UInt32(truncatingIfNeeded: block.data.count), to: &data)
            data.append(block.data)
            let pad = (align - block.data.count % align) % align
            if pad > 0 { data.append(Data(count: pad)) }
        }
        return data
    }

    /// Every block in `data`, which must hold whole blocks and nothing else. Throws `ImageImportError.tooLarge`
    /// when `data` exceeds `limit` bytes and `PSDError.truncated` for anything malformed.
    static func decodeBlocks(_ data: Data, limit: Int, alignment: Int = 2) throws -> [PSDTaggedBlock] {
        guard data.count <= limit else { throw ImageImportError.tooLarge }
        let align = max(1, alignment)
        var bytes = Bytes(data)
        var blocks: [PSDTaggedBlock] = []
        while bytes.offset < bytes.count {
            guard bytes.has(12) else { throw PSDError.truncated }
            let signature = bytes.code()
            guard blockSignatures.contains(signature) else { throw PSDError.truncated }
            let key = bytes.code()
            let length = Int(bytes.u32())
            guard bytes.has(length) else { throw PSDError.truncated }
            let payload = bytes.take(length)
            let pad = (align - length % align) % align
            guard bytes.has(pad), bytes.isZero(pad) else { throw PSDError.truncated }
            bytes.offset += pad
            blocks.append(PSDTaggedBlock(signature: signature, key: key, data: payload))
        }
        return blocks
    }

    /// The blocks framed in `data[start..<end]` (offsets from `data.startIndex`), leniently. An `8B64` block has an
    /// 8-byte length; `largeDocument` reads a PSB's blocks, whose `largeDocumentKeys` have one too.
    static func scanBlocks(_ data: Data, from start: Int, to end: Int, largeDocument: Bool = false) -> [PSDTaggedBlock] {
        scanBlocksAndTail(data, from: start, to: end, largeDocument: largeDocument).blocks
    }

    /// `scanBlocks`, plus the bytes after the last framed block (padding, or whatever couldn't be framed).
    /// Photoshop pads layer blocks inconsistently (odd lengths with or without a pad byte; 4-byte alignment for
    /// document blocks), so up to three zero bytes are skipped before each block rather than assuming a pad.
    static func scanBlocksAndTail(_ data: Data, from start: Int, to end: Int,
                                  largeDocument: Bool = false) -> (blocks: [PSDTaggedBlock], tail: Data) {
        var bytes = Bytes(data, from: start, to: end)
        var blocks: [PSDTaggedBlock] = []
        while true {
            let blockEnd = bytes.offset
            bytes.skipZeros(upTo: 3)
            guard bytes.has(12), blockSignatures.contains(bytes.peekCode()) else {
                bytes.offset = blockEnd
                break
            }
            let signature = bytes.code()
            let key = bytes.code()
            let length: Int
            // Upstream's rule: an `8B64` signature alone makes the length wide, so such a block frames whatever its
            // key, and a PSB also widens its listed keys, whatever their signature.
            if hasWideLength(signature: signature, key: key, largeDocument: largeDocument) {
                guard bytes.has(8) else {
                    bytes.offset = blockEnd
                    break
                }
                let wide = UInt64(bytes.u32()) << 32 | UInt64(bytes.u32())
                length = wide > UInt64(bytes.remaining) ? bytes.remaining + 1 : Int(wide)
            } else {
                length = Int(bytes.u32())
            }
            guard bytes.has(length) else {
                blocks.append(PSDTaggedBlock(signature: signature, key: key, data: bytes.take(bytes.remaining)))
                break
            }
            blocks.append(PSDTaggedBlock(signature: signature, key: key, data: bytes.take(length)))
        }
        return (blocks, bytes.take(bytes.remaining))
    }

    /// Whether a block's length takes eight bytes in a Photoshop file (`scanBlocks`).
    static func hasWideLength(signature: String, key: String, largeDocument: Bool) -> Bool {
        signature == "8B64" || (largeDocument && largeDocumentKeys.contains(key))
    }

    // MARK: Image resources

    static func encode(_ resources: [PSDImageResource]) -> Data {
        var data = Data()
        for resource in resources {
            data.append(code(resource.signature))
            data.append(UInt8(truncatingIfNeeded: resource.id >> 8))
            data.append(UInt8(truncatingIfNeeded: resource.id))
            let name = pascalBytes(resource.name)
            data.append(UInt8(name.count))
            data.append(name)
            if (name.count + 1) % 2 == 1 { data.append(0) }
            appendU32(UInt32(truncatingIfNeeded: resource.data.count), to: &data)
            data.append(resource.data)
            if resource.data.count % 2 == 1 { data.append(0) }
        }
        return data
    }

    /// Every resource in `data`, which must hold whole resources and nothing else.
    static func decodeResources(_ data: Data, limit: Int) throws -> [PSDImageResource] {
        guard data.count <= limit else { throw ImageImportError.tooLarge }
        var bytes = Bytes(data)
        var resources: [PSDImageResource] = []
        while bytes.offset < bytes.count {
            guard bytes.has(7) else { throw PSDError.truncated }
            let signature = bytes.code()
            guard resourceSignatures.contains(signature) else { throw PSDError.truncated }
            let id = bytes.u16()
            let nameLength = Int(bytes.u8())
            let namePad = (nameLength + 1) % 2
            guard bytes.has(nameLength + namePad + 4) else { throw PSDError.truncated }
            let name = pascalString(bytes.take(nameLength))
            guard bytes.isZero(namePad) else { throw PSDError.truncated }
            bytes.offset += namePad
            let length = Int(bytes.u32())
            let pad = length % 2
            guard bytes.has(length + pad) else { throw PSDError.truncated }
            let payload = bytes.take(length)
            guard bytes.isZero(pad) else { throw PSDError.truncated }
            bytes.offset += pad
            resources.append(PSDImageResource(id: id, name: name, data: payload, signature: signature))
        }
        return resources
    }

    /// The resources framed in `data[start..<end]` (offsets from `data.startIndex`), leniently.
    static func scanResources(_ data: Data, from start: Int, to end: Int) -> [PSDImageResource] {
        var bytes = Bytes(data, from: start, to: end)
        var resources: [PSDImageResource] = []
        while bytes.has(12) {
            let signature = bytes.peekCode()
            guard resourceSignatures.contains(signature) else { break }
            bytes.offset += 4
            let id = bytes.u16()
            let nameLength = Int(bytes.u8())
            let namePad = (nameLength + 1) % 2
            guard bytes.has(nameLength + namePad + 4) else { break }
            let name = pascalString(bytes.take(nameLength))
            bytes.offset += namePad
            let length = Int(bytes.u32())
            guard bytes.has(length) else {
                resources.append(PSDImageResource(id: id, name: name, data: bytes.take(bytes.remaining), signature: signature))
                break
            }
            resources.append(PSDImageResource(id: id, name: name, data: bytes.take(length), signature: signature))
            if length % 2 == 1, bytes.has(1) { bytes.offset += 1 }
        }
        return resources
    }

    // MARK: Linked-layer entries

    /// Entries framed as in a `lnk2` block's payload: each a `u64` length, its bytes, then zero padding to 4.
    static func encode(linkedEntries entries: [Data]) -> Data {
        var data = Data()
        for entry in entries {
            appendU32(UInt32(truncatingIfNeeded: UInt64(entry.count) >> 32), to: &data)
            appendU32(UInt32(truncatingIfNeeded: entry.count), to: &data)
            data.append(entry)
            let pad = (4 - entry.count % 4) % 4
            if pad > 0 { data.append(Data(count: pad)) }
        }
        return data
    }

    /// Every entry in `data`, which must hold whole entries and nothing else (strict, like `decodeBlocks`).
    static func decodeLinkedEntries(_ data: Data, limit: Int) throws -> [Data] {
        guard data.count <= limit else { throw ImageImportError.tooLarge }
        var bytes = Bytes(data)
        var entries: [Data] = []
        while bytes.offset < bytes.count {
            guard bytes.has(8) else { throw PSDError.truncated }
            let high = bytes.u32(), low = bytes.u32()
            guard high == 0, bytes.has(Int(low)) else { throw PSDError.truncated }
            let length = Int(low)
            entries.append(bytes.take(length))
            let pad = (4 - length % 4) % 4
            guard bytes.has(pad), bytes.isZero(pad) else { throw PSDError.truncated }
            bytes.offset += pad
        }
        return entries
    }

    // MARK: Helpers

    /// Whether `string` is four characters that `code(_:)` writes as themselves (one Latin-1 byte each).
    static func isFourCharacterCode(_ string: String) -> Bool {
        string.unicodeScalars.count == 4 && string.unicodeScalars.allSatisfy { $0.value <= 0xFF }
    }

    /// A four-character code as its bytes: Latin-1 (one byte per character, so any byte round-trips), padded with
    /// spaces or cut to four.
    static func code(_ string: String) -> Data {
        var bytes = Array(string.data(using: .isoLatin1) ?? Data(string.utf8)).prefix(4)
        while bytes.count < 4 { bytes.append(0x20) }
        return Data(bytes)
    }

    private static func pascalBytes(_ string: String) -> Data {
        (string.data(using: .macOSRoman, allowLossyConversion: true) ?? Data()).prefix(255)
    }

    private static func pascalString(_ data: Data) -> String {
        String(data: data, encoding: .macOSRoman) ?? String(decoding: data, as: UTF8.self)
    }

    private static func appendU32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    /// A bounds-checked view of `data[start..<end]`. Callers check `has(_:)` before reading.
    private struct Bytes {
        let data: Data
        let base: Int
        let count: Int
        var offset: Int

        init(_ data: Data) { self.init(data, from: 0, to: data.count) }

        init(_ data: Data, from start: Int, to end: Int) {
            self.data = data
            base = data.startIndex
            count = min(max(0, end), data.count)
            offset = min(max(0, start), count)
        }

        var remaining: Int { count - offset }
        func has(_ n: Int) -> Bool { n >= 0 && n <= remaining }
        func isZero(_ n: Int) -> Bool { (0..<n).allSatisfy { data[base + offset + $0] == 0 } }

        mutating func skipZeros(upTo limit: Int) {
            var skipped = 0
            while skipped < limit, offset < count, data[base + offset] == 0 { offset += 1; skipped += 1 }
        }

        mutating func u8() -> UInt8 {
            defer { offset += 1 }
            return data[base + offset]
        }

        mutating func u16() -> UInt16 { UInt16(u8()) << 8 | UInt16(u8()) }
        mutating func u32() -> UInt32 { UInt32(u16()) << 16 | UInt32(u16()) }

        func peekCode() -> String {
            String(data: data.subdata(in: base + offset ..< base + offset + 4), encoding: .isoLatin1) ?? ""
        }

        mutating func code() -> String {
            defer { offset += 4 }
            return peekCode()
        }

        mutating func take(_ n: Int) -> Data {
            defer { offset += n }
            return data.subdata(in: base + offset ..< base + offset + n)
        }
    }
}
