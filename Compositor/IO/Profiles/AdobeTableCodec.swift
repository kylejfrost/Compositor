import Compression
import CryptoKit
import Foundation

/// Camera Raw's "big tables" as profiles embed them (DNG SDK 1.7.1, `dng_big_table`): a binary payload,
/// zlib-compressed behind its size, written in an 85-character text encoding. The fingerprint that names a table
/// is the MD5 of the uncompressed payload.
nonisolated enum AdobeTableCodec {
    static let alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?`'|()[]{}@%$#"
    static let maximumUncompressedBytes = 16 * 1024 * 1024

    private static let digits = Array(alphabet.utf8)
    /// The digit value of each ASCII byte; 0xFF marks a byte the decoder skips.
    private static let digitValues: [UInt8] = {
        var values = [UInt8](repeating: 0xFF, count: 128)
        for (value, character) in digits.enumerated() { values[Int(character)] = UInt8(value) }
        return values
    }()

    // MARK: Text

    /// Five digits make one little-endian u32, first digit least significant. Characters outside the alphabet are
    /// skipped; a final group of k digits gives k−1 bytes, so a lone digit gives none.
    static func decodeText(_ text: some StringProtocol) -> Data {
        if let data = text.utf8.withContiguousStorageIfAvailable(decode) { return data }
        return Array(text.utf8).withUnsafeBufferPointer(decode)
    }

    private static func decode(_ characters: UnsafeBufferPointer<UInt8>) -> Data {
        let values = digitValues
        var output: [UInt8] = []
        output.reserveCapacity(characters.count / 5 * 4 + 4)
        var value: UInt64 = 0, scale: UInt64 = 1, phase = 0
        for character in characters where character < 0x80 {
            let digit = values[Int(character)]
            guard digit != 0xFF else { continue }
            value += UInt64(digit) * scale
            phase += 1
            if phase == 5 {
                appendLittleEndian(UInt32(truncatingIfNeeded: value), byteCount: 4, to: &output)
                value = 0
                scale = 1
                phase = 0
            } else {
                scale *= 85
            }
        }
        if phase > 1 { appendLittleEndian(UInt32(truncatingIfNeeded: value), byteCount: phase - 1, to: &output) }
        return Data(output)
    }

    /// The inverse of `decodeText`: each 4-byte word gives five digits, and a final group of n bytes gives n+1.
    static func encodeText(_ bytes: Data) -> String {
        let input = [UInt8](bytes)
        var output: [UInt8] = []
        output.reserveCapacity(input.count / 4 * 5 + 5)
        var start = 0
        while start < input.count {
            let count = min(4, input.count - start)
            var word: UInt32 = 0
            for k in 0 ..< count { word |= UInt32(input[start + k]) << (8 * k) }
            for _ in 0 ..< (count == 4 ? 5 : count + 1) {
                output.append(digits[Int(word % 85)])
                word /= 85
            }
            start += 4
        }
        return String(decoding: output, as: UTF8.self)
    }

    // MARK: Compression

    /// `[u32 LE uncompressed size][zlib stream]` → the payload.
    static func inflate(_ block: Data) throws -> Data {
        let bytes = [UInt8](block)
        guard bytes.count >= 5 else { throw ProfileError.malformed("block") }
        let size = Int(littleEndianU32(bytes, at: 0))
        guard size <= maximumUncompressedBytes else { throw ProfileError.tooLarge }
        guard bytes.count >= 6, bytes[4] == 0x78, (UInt16(bytes[4]) << 8 | UInt16(bytes[5])) % 31 == 0,
              bytes[5] & 0x20 == 0 else { throw ProfileError.malformed("zlib header") }
        guard bytes.count >= 10 else { throw ProfileError.malformed("zlib data") }
        // COMPRESSION_ZLIB is raw DEFLATE: skip the size and the zlib header, and check the Adler-32 trailer here.
        // One spare byte in the buffer shows a stream that inflates to more than it declares.
        var output = [UInt8](repeating: 0, count: size + 1)
        let produced = bytes[6 ..< bytes.count - 4].withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination -> Int in
                guard let from = source.baseAddress, let into = destination.baseAddress else { return 0 }
                return compression_decode_buffer(into, destination.count, from, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        let trailer = UInt32(bytes[bytes.count - 4]) << 24 | UInt32(bytes[bytes.count - 3]) << 16
            | UInt32(bytes[bytes.count - 2]) << 8 | UInt32(bytes[bytes.count - 1])
        guard produced == size, output[..<size].withUnsafeBufferPointer(adler32) == trailer else {
            throw ProfileError.malformed("zlib data")
        }
        output.removeLast()
        return Data(output)
    }

    /// payload → `[u32 LE size][78 9C, raw deflate, Adler-32 BE]`. The bytes need not match Adobe's encoder.
    static func deflate(_ payload: Data) -> Data {
        let input = [UInt8](payload)
        var block: [UInt8] = []
        appendLittleEndian(UInt32(truncatingIfNeeded: input.count), byteCount: 4, to: &block)
        block += [0x78, 0x9C]
        block += rawDeflate(input)
        let checksum = input.withUnsafeBufferPointer(adler32)
        block += [UInt8(checksum >> 24), UInt8(checksum >> 16 & 0xFF), UInt8(checksum >> 8 & 0xFF), UInt8(checksum & 0xFF)]
        return Data(block)
    }

    private static func rawDeflate(_ input: [UInt8]) -> [UInt8] {
        if !input.isEmpty {
            var output = [UInt8](repeating: 0, count: input.count + input.count / 8 + 1024)
            let written = input.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination -> Int in
                    guard let from = source.baseAddress, let into = destination.baseAddress else { return 0 }
                    return compression_encode_buffer(into, destination.count, from, source.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 { return Array(output.prefix(written)) }
        }
        return storedBlocks(input)
    }

    /// Uncompressed DEFLATE blocks, for input the encoder does not take, such as none at all.
    private static func storedBlocks(_ input: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        var start = 0
        repeat {
            let count = min(65535, input.count - start)
            output.append(start + count == input.count ? 1 : 0)
            output += [UInt8(count & 0xFF), UInt8(count >> 8), UInt8(~count & 0xFF), UInt8(~count >> 8 & 0xFF)]
            output += input[start ..< start + count]
            start += count
        } while start < input.count
        return output
    }

    private static func adler32(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0, index = 0
        while index < bytes.count {
            // 5552 bytes is the most that can be summed before the 32-bit sums could overflow.
            let end = min(index + 5552, bytes.count)
            while index < end {
                a &+= UInt32(bytes[index])
                b &+= a
                index += 1
            }
            a %= 65521
            b %= 65521
        }
        return b << 16 | a
    }

    /// MD5 of the uncompressed payload, uppercase hex: the name a profile gives its table.
    static func fingerprint(_ payload: Data) -> String {
        Insecure.MD5.hash(data: payload).map { String(format: "%02X", $0) }.joined()
    }

    // MARK: Tables

    /// The SDK's identity ("nop") value for each of `divisions` RGB table nodes, integer arithmetic included:
    /// two divisions give [1, 0] because 65536 wraps. Fewer than two have no identity and give zeros.
    static func identityValues(divisions: Int) -> [UInt16] {
        guard divisions >= 2 else { return [UInt16](repeating: 0, count: max(divisions, 0)) }
        return (0 ..< divisions).map { UInt16(truncatingIfNeeded: ($0 * 65535 + (divisions >> 1)) / (divisions - 1)) }
    }

    static func hueSatMap(from payload: Data) throws -> HueSatMap {
        var reader = PayloadReader(bytes: [UInt8](payload), failure: .malformed("look table"))
        guard try reader.u32() == 0 else { throw reader.failure }
        let version = try reader.u32()
        guard version == 1 || version == 2 else { throw reader.failure }
        let hue = Int(try reader.u32()), saturation = Int(try reader.u32()), value = Int(try reader.u32())
        // The SDK accepts one saturation division, but interpolating between saturations needs two.
        guard (1...360).contains(hue), (2...256).contains(saturation), (1...256).contains(value),
              hue * saturation * value <= 18432 else { throw reader.failure }
        let count = hue * saturation * value * 3
        guard reader.remaining >= count * 4 else { throw reader.failure }
        var entries: [Float] = []
        entries.reserveCapacity(count)
        for _ in 0 ..< count {
            let entry = try reader.f32()
            guard entry.isFinite else { throw reader.failure }
            entries.append(entry)
        }
        guard let encoding = HueSatMap.Encoding(rawValue: try reader.u32()) else { throw reader.failure }
        var minimum = 1.0, maximum = 1.0
        if version == 2 {
            guard let range = amountRange(try reader.f64(), try reader.f64()) else { throw reader.failure }
            (minimum, maximum) = range
        }
        // Optional flags; anything after them is ignored, as the SDK ignores it.
        let flags = reader.remaining >= 4 ? try reader.u32() : nil
        return HueSatMap(hueDivisions: hue, saturationDivisions: saturation, valueDivisions: value, entries: entries,
                         encoding: encoding, minimumAmount: minimum, maximumAmount: maximum, flags: flags)
    }

    static func rgbTable(from payload: Data) throws -> RGBTable {
        var reader = PayloadReader(bytes: [UInt8](payload), failure: .malformed("rgb table"))
        guard try reader.u32() == 1, try reader.u32() == 1 else { throw reader.failure }
        let dimensions = Int(try reader.u32()), divisions = Int(try reader.u32())
        let count: Int
        switch dimensions {
        case 1 where (2...4096).contains(divisions): count = divisions
        case 3 where (2...32).contains(divisions): count = divisions * divisions * divisions
        default: throw reader.failure
        }
        guard reader.remaining >= count * 6 else { throw reader.failure }
        // Stored values are deltas from identity; R, G and B each take the identity of their own index.
        let nop = identityValues(divisions: divisions)
        var samples: [UInt16] = []
        samples.reserveCapacity(count * 3)
        for node in 0 ..< count {
            let (r, g, b) = nodeIndices(node, dimensions: dimensions, divisions: divisions)
            samples.append(try reader.u16() &+ nop[r])
            samples.append(try reader.u16() &+ nop[g])
            samples.append(try reader.u16() &+ nop[b])
        }
        guard let primaries = RGBTable.Primaries(rawValue: try reader.u32()),
              let gamma = RGBTable.Gamma(rawValue: try reader.u32()),
              let gamut = RGBTable.Gamut(rawValue: try reader.u32()) else { throw reader.failure }
        guard let range = amountRange(try reader.f64(), try reader.f64()) else { throw reader.failure }
        let (minimum, maximum) = range
        let flags = reader.remaining >= 4 ? try reader.u32() : nil
        return RGBTable(dimensions: dimensions, divisions: divisions, samples: samples, primaries: primaries, gamma: gamma,
                        gamut: gamut, minimumAmount: minimum, maximumAmount: maximum, flags: flags)
    }

    /// `dng_look_table::PutStream`: version 1 for a fixed amount, else version 2 with the range; flags only when set.
    static func payload(_ table: HueSatMap) -> Data {
        var writer = PayloadWriter()
        let version: UInt32 = table.isFixedAmount ? 1 : 2
        writer.u32(0)
        writer.u32(version)
        writer.u32(UInt32(truncatingIfNeeded: table.hueDivisions))
        writer.u32(UInt32(truncatingIfNeeded: table.saturationDivisions))
        writer.u32(UInt32(truncatingIfNeeded: table.valueDivisions))
        for entry in table.entries { writer.u32(entry.bitPattern) }
        writer.u32(table.encoding.rawValue)
        if version == 2 {
            writer.f64(table.minimumAmount)
            writer.f64(table.maximumAmount)
        }
        if let flags = table.flags, flags != 0 { writer.u32(flags) }
        return Data(writer.bytes)
    }

    /// `dng_rgb_table::PutStream`: samples are written as deltas from identity, wrapping.
    static func payload(_ table: RGBTable) -> Data {
        var writer = PayloadWriter()
        writer.u32(1)
        writer.u32(1)
        writer.u32(UInt32(truncatingIfNeeded: table.dimensions))
        writer.u32(UInt32(truncatingIfNeeded: table.divisions))
        let nop = identityValues(divisions: table.divisions)
        for (index, sample) in table.samples.enumerated() {
            let (r, g, b) = nodeIndices(index / 3, dimensions: table.dimensions, divisions: table.divisions)
            let axis = index % 3 == 0 ? r : index % 3 == 1 ? g : b
            writer.u16(sample &- (axis < nop.count ? nop[axis] : 0))
        }
        writer.u32(table.primaries.rawValue)
        writer.u32(table.gamma.rawValue)
        writer.u32(table.gamut.rawValue)
        writer.f64(table.minimumAmount)
        writer.f64(table.maximumAmount)
        if let flags = table.flags, flags != 0 { writer.u32(flags) }
        return Data(writer.bytes)
    }

    /// Text → block → payload, checked against the fingerprint that names it, then parsed by its type.
    static func decodeTable(fingerprint expected: String, text: some StringProtocol) throws -> AdobeTable {
        let payload = try inflate(decodeText(text))
        guard fingerprint(payload) == expected.uppercased() else { throw ProfileError.malformed("table fingerprint") }
        let bytes = [UInt8](payload.prefix(4))
        guard bytes.count == 4 else { throw ProfileError.malformed("table type") }
        switch littleEndianU32(bytes, at: 0) {
        case 0: return .look(try hueSatMap(from: payload))
        case 1: return .rgb(try rgbTable(from: payload))
        case let type: throw ProfileError.malformed("table type \(type)")
        }
    }

    static func encodeTable(_ table: AdobeTable) -> (fingerprint: String, text: String) {
        let bytes: Data
        switch table {
        case .look(let map): bytes = payload(map)
        case .rgb(let rgb): bytes = payload(rgb)
        }
        return (fingerprint(bytes), encodeText(deflate(bytes)))
    }

    // MARK: Helpers

    /// A table's amount range as the SDK's `SetAmountRange` keeps it: each end rounded to hundredths, the minimum
    /// pinned to 0…1 and the maximum to 1…2. nil when either end isn't finite.
    private static func amountRange(_ minimum: Double, _ maximum: Double) -> (Double, Double)? {
        guard minimum.isFinite, maximum.isFinite else { return nil }
        return (ProfileRenderer.sdkAmount(minimum, 0, 1), ProfileRenderer.sdkAmount(maximum, 1, 2))
    }

    /// The (r, g, b) axis indices of an RGB table node: r outer, b inner in 3D; the node itself in 1D.
    private static func nodeIndices(_ node: Int, dimensions: Int, divisions: Int) -> (Int, Int, Int) {
        guard dimensions == 3, divisions > 0 else { return (node, node, node) }
        return (node / (divisions * divisions), node / divisions % divisions, node % divisions)
    }

    private static func littleEndianU32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private static func appendLittleEndian(_ value: UInt32, byteCount: Int, to output: inout [UInt8]) {
        for k in 0 ..< byteCount { output.append(UInt8(truncatingIfNeeded: value >> (8 * k))) }
    }
}

/// Little-endian reads that throw `failure` on running out of bytes.
private nonisolated struct PayloadReader {
    let bytes: [UInt8]
    let failure: ProfileError
    var offset = 0
    var remaining: Int { bytes.count - offset }

    mutating func u16() throws -> UInt16 {
        guard remaining >= 2 else { throw failure }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw failure }
        defer { offset += 4 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    mutating func f64() throws -> Double {
        guard remaining >= 8 else { throw failure }
        let low = UInt64(try u32())
        return Double(bitPattern: UInt64(try u32()) << 32 | low)
    }
}

private nonisolated struct PayloadWriter {
    var bytes: [UInt8] = []

    mutating func u16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }
    mutating func u32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
    }
    mutating func f64(_ value: Double) {
        u32(UInt32(truncatingIfNeeded: value.bitPattern))
        u32(UInt32(truncatingIfNeeded: value.bitPattern >> 32))
    }
}
