import CoreGraphics
import Foundation
import Testing
@testable import Compositor

@Suite
struct PSDChannelEncoderTests {
    /// Deterministic rows mixing literal stretches with runs of every length up to past 128.
    private func samplePlane(width: Int, height: Int) -> [UInt8] {
        var state: UInt32 = 0x1234_5678
        func next() -> UInt32 {
            state = state &* 1_664_525 &+ 1_013_904_223
            return state >> 8
        }
        var plane: [UInt8] = []
        while plane.count < width * height {
            let value = UInt8(truncatingIfNeeded: next())
            let length = next() % 4 == 0 ? Int(next() % 300) + 1 : 1
            plane.append(contentsOf: repeatElement(value, count: length))
        }
        return Array(plane.prefix(width * height))
    }

    @Test func packBitsSplitsRunsAt128() {
        #expect(PSDChannelEncoder.packBits([]) == [])
        #expect(PSDChannelEncoder.packBits([7]) == [0, 7])
        #expect(PSDChannelEncoder.packBits([7, 7]) == [0xFF, 7])
        #expect(PSDChannelEncoder.packBits(Array(repeating: 9, count: 128)) == [0x81, 9])
        // 200 equal bytes: a run of 128 (header −127), then one of 72 (header −71).
        #expect(PSDChannelEncoder.packBits(Array(repeating: 9, count: 200)) == [0x81, 9, 0xB9, 9])
        // 130 distinct bytes: a literal of 128 (header 127), then one of 2 (header 1).
        let distinct = (0 ..< 130).map { UInt8($0) }
        #expect(PSDChannelEncoder.packBits(distinct) == [127] + distinct.prefix(128) + [1, 128, 129])
        #expect(PSDChannelEncoder.packBits([1, 2, 3, 3, 3, 4]) == [1, 1, 2, 0xFE, 3, 0, 4])
    }

    @Test func rleRoundTripsThroughTheChannelDecoder() throws {
        for (width, height) in [(1, 1), (3, 2), (128, 3), (129, 4), (300, 5), (1000, 2)] {
            let plane = samplePlane(width: width, height: height)
            let encoded = PSDChannelEncoder.rle(plane, width: width, height: height)
            let counts = (0 ..< height).map { Int(encoded[$0 * 2]) << 8 | Int(encoded[$0 * 2 + 1]) }
            #expect(encoded.count == height * 2 + counts.reduce(0, +))
            let rows = (0 ..< height).map { Array(plane[$0 * width ..< ($0 + 1) * width]) }
            #expect(counts == rows.map { PSDChannelEncoder.packBits($0).count })
            let decoded = try PSDChannelCoder.decode(compression: 1, width: width, height: height, data: encoded)
            #expect(decoded == plane, "\(width)×\(height)")
        }
        #expect(PSDChannelEncoder.rle([], width: 0, height: 3).isEmpty)
    }

    @Test func straightPlanesUnpremultiplyTopRowFirst() throws {
        // Premultiplied: half-transparent (128, 64, 0), then fully transparent, then opaque blue.
        let image = try PSDChannelCoder.image(width: 1, height: 3, rgba: [128, 64, 0, 128, 0, 0, 0, 0, 0, 0, 255, 255])
        let planes = try PSDChannelEncoder.straightPlanes(image)
        #expect(planes.r == [255, 0, 0])
        #expect(planes.g == [128, 0, 0])
        #expect(planes.b == [0, 0, 255])
        #expect(planes.a == [128, 0, 255])
    }

    @Test func grayPlaneKeepsMaskValuesTopRowFirst() throws {
        let mask = try PSDChannelCoder.maskImage(width: 2, height: 2, gray: [0, 64, 128, 255])
        #expect(try PSDChannelEncoder.grayPlane(mask) == [0, 64, 128, 255])
    }
}
