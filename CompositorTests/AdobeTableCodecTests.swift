import Foundation
import Testing
@testable import Compositor

struct AdobeTableCodecTests {
    static let vectors: [(String, String)] = [
        ("", ""), ("0b", "b0"), ("0b30", "XX1"), ("0b3055", "XY79"), ("0b30557a", "bT#qD"),
        ("0b30557a9f", "bT#qD|1"), ("0b30557a9fc4", "bT#qDf%6"), ("0b30557a9fc4e9", "bT#qD]B}o"),
        ("0b30557a9fc4e90e", "bT#qD7{y^4"), ("0b30557a9fc4e90e33", "bT#qD7{y^4P0"),
    ]
    static func bytes(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index ..< next], radix: 16)!)
            index = next
        }
        return data
    }

    /// Made by Python's zlib at level 6 from `lookPayload`.
    static let lookText = "`0000KZk$uBRLy1c*g$1R%Rj.pvL2V8fzrik.iosWqt/aIv7"
    static let lookFingerprint = "411084C8942597F055810255AC3D5581"
    /// Look table version 1: H 2, S 2, V 1; node 3 is (30°, 0.5, 1.25), the rest identity; linear encoding.
    static let lookPayload = bytes(
        "0000000001000000020000000200000001000000000000000000803f0000803f000000000000803f0000803f"
            + "000000000000803f0000803f0000f0410000003f0000a03f00000000")
    /// RGB table: 3³, AdobeRGB, γ2.2, clip, amount 0…2; node (1,1,1) is (40000, 32768, 30000).
    static let rgbText = "A2000OcImwBRLy1=4lyRXBtuvF878o(a'3U'Wb30Z^?h="
    static let rgbFingerprint = "090EA844DB9A527085EFFB138AA83864"
    static let rgbPayload = bytes(
        "0100000001000000030000000300000000000000000000000000000000000000000000000000000000000000"
            + "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
            + "000000000000401c000030f50000000000000000000000000000000000000000000000000000000000000000"
            + "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
            + "000001000000030000000000000000000000000000000000000000000040")

    static func patched(_ payload: Data, at offset: Int, u32 value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { patched(payload, at: offset, Data($0)) }
    }
    static func patched(_ payload: Data, at offset: Int, f32 value: Float) -> Data {
        patched(payload, at: offset, u32: value.bitPattern)
    }
    static func patched(_ payload: Data, at offset: Int, f64 value: Double) -> Data {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { patched(payload, at: offset, Data($0)) }
    }
    static func patched(_ payload: Data, at offset: Int, _ bytes: Data) -> Data {
        var result = [UInt8](payload)
        result.replaceSubrange(offset ..< offset + bytes.count, with: bytes)
        return Data(result)
    }
    /// The version-2 form of `lookPayload`: sRGB encoding, amount 0…2.
    static var lookPayloadV2: Data {
        var payload = patched(patched(lookPayload, at: 4, u32: 2), at: 68, u32: 1)
        withUnsafeBytes(of: Double(0).bitPattern.littleEndian) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: Double(2).bitPattern.littleEndian) { payload.append(contentsOf: $0) }
        return payload
    }

    @Test func alphabetIsAdobes() {
        #expect(AdobeTableCodec.alphabet == "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?`'|()[]{}@%$#")
        #expect(Set(AdobeTableCodec.alphabet).count == 85)
    }

    @Test(arguments: vectors) func textCodecMatchesTheSDK(_ vector: (String, String)) {
        #expect(AdobeTableCodec.encodeText(Self.bytes(vector.0)) == vector.1)
        #expect(AdobeTableCodec.decodeText(vector.1) == Self.bytes(vector.0))
    }

    @Test func decodingSkipsForeignCharactersWrapsAndDropsALoneDigit() {
        #expect(AdobeTableCodec.decodeText("#####") == Data([0xc4, 0x0e, 0x78, 0x08]))   // 85⁵−1 mod 2³²
        #expect(AdobeTableCodec.decodeText("b").isEmpty)
        #expect(AdobeTableCodec.decodeText("bT#qD\n |1") == Self.bytes("0b30557a9f"))
        #expect(AdobeTableCodec.decodeText("b\"T<#&q,D") == Self.bytes("0b30557a"))
        #expect(AdobeTableCodec.decodeText("b_T~#;q\\D>é") == Self.bytes("0b30557a"))
        #expect(AdobeTableCodec.decodeText("xxbT#qDxx".dropFirst(2).dropLast(2)) == Self.bytes("0b30557a"))
    }

    @Test func encodedLengthFollowsTheSDK() {
        for m in 0...12 {
            let text = AdobeTableCodec.encodeText(Data(repeating: 0xAB, count: m))
            #expect(text.count == 5 * (m / 4) + (m % 4 == 0 ? 0 : m % 4 + 1))
            #expect(AdobeTableCodec.decodeText(text) == Data(repeating: 0xAB, count: m))
        }
    }

    @Test func pythonMadeLookTableDecodes() throws {
        let payload = try AdobeTableCodec.inflate(AdobeTableCodec.decodeText(Self.lookText))
        #expect(payload == Self.lookPayload)
        #expect(AdobeTableCodec.fingerprint(payload) == Self.lookFingerprint)
        let table = try AdobeTableCodec.decodeTable(fingerprint: Self.lookFingerprint, text: Self.lookText)
        guard case .look(let look) = table else {
            Issue.record("expected a look table, got \(table)")
            return
        }
        #expect(look.hueDivisions == 2 && look.saturationDivisions == 2 && look.valueDivisions == 1)
        #expect(look.entries.count == 12)
        #expect(Array(look.entries[9...11]) == [30, 0.5, 1.25])
        for node in 0 ..< 3 {
            #expect(Array(look.entries[node * 3 ..< node * 3 + 3]) == [0, 1, 1])
        }
        #expect(look.encoding == .linear)
        #expect(look.minimumAmount == 1 && look.maximumAmount == 1 && look.isFixedAmount)
        #expect(look.flags == nil)
        #expect(throws: ProfileError.malformed("table fingerprint")) {
            try AdobeTableCodec.decodeTable(fingerprint: "00000000000000000000000000000000", text: Self.lookText)
        }
    }

    @Test func pythonMadeRGBTableDecodes() throws {
        let payload = try AdobeTableCodec.inflate(AdobeTableCodec.decodeText(Self.rgbText))
        #expect(payload.count == 206)
        #expect(payload == Self.rgbPayload)
        let table = try AdobeTableCodec.decodeTable(fingerprint: Self.rgbFingerprint, text: Self.rgbText)
        guard case .rgb(let rgb) = table else {
            Issue.record("expected an RGB table, got \(table)")
            return
        }
        #expect(rgb.dimensions == 3 && rgb.divisions == 3)
        #expect(rgb.primaries == .adobeRGB && rgb.gamma == .gamma22 && rgb.gamut == .clip)
        #expect(rgb.minimumAmount == 0 && rgb.maximumAmount == 2)
        #expect(rgb.flags == nil)
        #expect(rgb.samples.count == 81)
        #expect(Array(rgb.samples[0 ..< 3]) == [0, 0, 0])
        #expect(Array(rgb.samples[39 ..< 42]) == [40000, 32768, 30000])
        #expect(Array(rgb.samples[78 ..< 81]) == [65535, 65535, 65535])
    }

    @Test func identityValuesKeepTheSDKQuirk() {
        #expect(AdobeTableCodec.identityValues(divisions: 3) == [0, 32768, 65535])
        #expect(AdobeTableCodec.identityValues(divisions: 2) == [1, 0])
        let d32 = AdobeTableCodec.identityValues(divisions: 32)
        #expect(d32.count == 32)
        #expect(Array(d32.prefix(4)) == [0, 2114, 4228, 6342])
        #expect(Array(d32.suffix(2)) == [63421, 65535])
        #expect(Array(AdobeTableCodec.identityValues(divisions: 25).prefix(3)) == [0, 2731, 5461])
    }

    @Test func payloadsReserializeByteExactly() throws {
        #expect(AdobeTableCodec.payload(try AdobeTableCodec.hueSatMap(from: Self.lookPayload)) == Self.lookPayload)
        #expect(AdobeTableCodec.payload(try AdobeTableCodec.rgbTable(from: Self.rgbPayload)) == Self.rgbPayload)

        var version2 = try AdobeTableCodec.hueSatMap(from: Self.lookPayload)
        version2.encoding = .sRGB
        version2.minimumAmount = 0
        version2.maximumAmount = 2
        #expect(!version2.isFixedAmount)
        let v2Payload = AdobeTableCodec.payload(version2)
        #expect(v2Payload.count == 88)
        #expect(v2Payload == Self.lookPayloadV2)
        #expect(AdobeTableCodec.fingerprint(v2Payload) == "DB2C5630A21BF1249EFF33DD6D502B4C")
        #expect(try AdobeTableCodec.hueSatMap(from: v2Payload) == version2)

        let flagged = Self.lookPayload + Data([1, 0, 0, 0])
        let parsed = try AdobeTableCodec.hueSatMap(from: flagged)
        #expect(parsed.flags == 1)
        #expect(AdobeTableCodec.payload(parsed) == flagged)
        #expect(try AdobeTableCodec.hueSatMap(from: flagged + Data(repeating: 0xEE, count: 8)) == parsed)

        let rgbFlagged = Self.rgbPayload + Data([1, 0, 0, 0])
        let parsedRGB = try AdobeTableCodec.rgbTable(from: rgbFlagged + Data(repeating: 0xEE, count: 8))
        #expect(parsedRGB.flags == 1)
        #expect(AdobeTableCodec.payload(parsedRGB) == rgbFlagged)
    }

    @Test func inflateRejectsBadBlocks() throws {
        let block = [UInt8](AdobeTableCodec.deflate(Self.lookPayload))
        #expect(try AdobeTableCodec.inflate(Data(block)) == Self.lookPayload)
        #expect(throws: ProfileError.malformed("block")) { try AdobeTableCodec.inflate(Data(block.prefix(4))) }

        var wrongSize = block
        wrongSize[0] = 73
        #expect(throws: ProfileError.malformed("zlib data")) { try AdobeTableCodec.inflate(Data(wrongSize)) }
        wrongSize[0] = 71
        #expect(throws: ProfileError.malformed("zlib data")) { try AdobeTableCodec.inflate(Data(wrongSize)) }

        var badHeader = block
        badHeader[5] ^= 0x01
        #expect(throws: ProfileError.malformed("zlib header")) { try AdobeTableCodec.inflate(Data(badHeader)) }
        var dictionary = block
        dictionary[5] = 0xBB   // FDICT set; 0x78BB is a multiple of 31
        #expect(throws: ProfileError.malformed("zlib header")) { try AdobeTableCodec.inflate(Data(dictionary)) }

        var huge = block
        huge.replaceSubrange(0 ..< 4, with: [0x00, 0x00, 0x10, 0x01])   // 17 MiB
        #expect(throws: ProfileError.tooLarge) { try AdobeTableCodec.inflate(Data(huge)) }

        var badTrailer = block
        badTrailer[badTrailer.count - 1] ^= 0xFF
        #expect(throws: ProfileError.malformed("zlib data")) { try AdobeTableCodec.inflate(Data(badTrailer)) }
    }

    @Test func deflateRoundTrips() throws {
        var x: UInt64 = 0
        for count in [0, 1, 5, 10_000] {
            var bytes: [UInt8] = []
            for _ in 0 ..< count {
                x = x &* 6364136223846793005 &+ 1442695040888963407
                bytes.append(UInt8(x >> 56))
            }
            let payload = Data(bytes)
            let block = AdobeTableCodec.deflate(payload)
            let size = UInt32(count)
            #expect(Array(block.prefix(6)) == [UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 24), 0x78, 0x9C])
            #expect(try AdobeTableCodec.inflate(block) == payload)
        }
    }

    static let malformedPayloads: [(String, Data, String)] = [
        ("look version 3", patched(lookPayload, at: 4, u32: 3), "look table"),
        ("look S = 1", patched(lookPayload, at: 12, u32: 1), "look table"),
        ("look H = 361", patched(lookPayload, at: 8, u32: 361), "look table"),
        ("look 360·8·8 nodes", patched(patched(patched(lookPayload, at: 8, u32: 360), at: 12, u32: 8), at: 16, u32: 8), "look table"),
        ("look encoding 2", patched(lookPayload, at: 68, u32: 2), "look table"),
        ("look v2 maximum infinite", patched(lookPayloadV2, at: 80, f64: .infinity), "look table"),
        ("look v2 minimum NaN", patched(lookPayloadV2, at: 72, f64: .nan), "look table"),
        ("look truncated entries", lookPayload.prefix(40), "look table"),
        ("look NaN entry", patched(lookPayload, at: 20, f32: .nan), "look table"),
        ("rgb version 2", patched(rgbPayload, at: 4, u32: 2), "rgb table"),
        ("rgb dimensions 2", patched(rgbPayload, at: 8, u32: 2), "rgb table"),
        ("rgb 3D divisions 33", patched(rgbPayload, at: 12, u32: 33), "rgb table"),
        ("rgb 1D divisions 1", patched(patched(rgbPayload, at: 8, u32: 1), at: 12, u32: 1), "rgb table"),
        ("rgb primaries 5", patched(rgbPayload, at: 178, u32: 5), "rgb table"),
        ("rgb gamma 5", patched(rgbPayload, at: 182, u32: 5), "rgb table"),
        ("rgb gamut 2", patched(rgbPayload, at: 186, u32: 2), "rgb table"),
        ("rgb maximum NaN", patched(rgbPayload, at: 198, f64: .nan), "rgb table"),
        ("rgb maximum infinite", patched(rgbPayload, at: 198, f64: .infinity), "rgb table"),
        ("rgb truncated", rgbPayload.prefix(200), "rgb table"),
        ("table type 2", patched(lookPayload, at: 0, u32: 2), "table type 2"),
    ]

    @Test(arguments: malformedPayloads) func tablesRejectMalformedPayloads(_ item: (String, Data, String)) {
        let (_, payload, detail) = item
        let text = AdobeTableCodec.encodeText(AdobeTableCodec.deflate(payload))
        #expect(throws: ProfileError.malformed(detail)) {
            try AdobeTableCodec.decodeTable(fingerprint: AdobeTableCodec.fingerprint(payload), text: text)
        }
    }

    /// The SDK's `SetAmountRange`: each end rounded to hundredths, the minimum pinned to 0…1 and the maximum to 1…2.
    @Test func amountRangesArePinnedAndRoundedLikeTheSDK() throws {
        let cases: [(minimum: Double, maximum: Double, expected: (Double, Double))] = [
            (0, 2, (0, 2)),
            (-0.1, 5, (0, 2)),
            (1.5, 0.5, (1, 1)),
            (0.123, 1.456, (12 * 0.01, 146 * 0.01)),
            (0.126, 1.994, (13 * 0.01, 199 * 0.01)),
            (-1e300, 1e300, (0, 2)),
        ]
        for (minimum, maximum, expected) in cases {
            let label = "\(minimum)…\(maximum)"
            let rgbPayload = Self.patched(Self.patched(Self.rgbPayload, at: 190, f64: minimum), at: 198, f64: maximum)
            let rgb = try AdobeTableCodec.rgbTable(from: rgbPayload)
            #expect(rgb.minimumAmount == expected.0 && rgb.maximumAmount == expected.1, "rgb \(label)")
            let lookPayload = Self.patched(Self.patched(Self.lookPayloadV2, at: 72, f64: minimum), at: 80, f64: maximum)
            let look = try AdobeTableCodec.hueSatMap(from: lookPayload)
            #expect(look.minimumAmount == expected.0 && look.maximumAmount == expected.1, "look \(label)")
        }
        let pinnedToOne = try AdobeTableCodec.hueSatMap(from: Self.patched(Self.patched(Self.lookPayloadV2, at: 72, f64: 1.5),
                                                                          at: 80, f64: 0.5))
        #expect(pinnedToOne.isFixedAmount)
    }

    @Test func encodeTableRoundTrips() throws {
        let look = ProfileFixture.hueSatMap(hue: 12, saturation: 4, value: 4, encoding: .sRGB, amount: 0...2) { v, h, s in
            (Float(h) * 2.5 - 12, 1 + Float(s) * 0.125, 1 - Float(v) * 0.0625)
        }
        let warm = ProfileFixture.rgbTable(divisions: 9, primaries: .adobeRGB, gamma: .gamma22) { r, g, b in
            (r * 1.1 + 0.02, g, b * 0.85)
        }
        let curve = ProfileFixture.rgbTable(divisions: 17, dimensions: 1) { r, g, b in
            (pow(r, 0.8), pow(g, 0.9), pow(b, 1.1))
        }
        #expect(warm.samples.count == 9 * 9 * 9 * 3)
        #expect(curve.samples.count == 17 * 3)
        for table in [AdobeTable.look(look), .rgb(warm), .rgb(curve)] {
            let encoded = AdobeTableCodec.encodeTable(table)
            #expect(try AdobeTableCodec.decodeTable(fingerprint: encoded.fingerprint, text: encoded.text) == table)
            let payload: Data
            switch table {
            case .look(let map): payload = AdobeTableCodec.payload(map)
            case .rgb(let rgb): payload = AdobeTableCodec.payload(rgb)
            }
            #expect(AdobeTableCodec.fingerprint(payload) == encoded.fingerprint)
        }
        let identity = ProfileFixture.rgbTable(divisions: 16)
        let nop = AdobeTableCodec.identityValues(divisions: 16)
        #expect(Array(identity.samples[0 ..< 3]) == [nop[0], nop[0], nop[0]])
        #expect(Array(identity.samples[(1 * 256 + 2 * 16 + 3) * 3 ..< (1 * 256 + 2 * 16 + 3) * 3 + 3]) == [nop[1], nop[2], nop[3]])
    }
}
