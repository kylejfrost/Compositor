import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Compositor

/// The synthetic profile fixtures in CompositorTests/Fixtures/Profiles, made by scripts/profiles/make_fixtures.py.
enum ProfileFixtureFiles {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Profiles")

    static func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }

    static func loaded(_ name: String) throws -> LoadedProfile { try LoadedProfile(data: data(name)) }

    /// A PNG's RGB bytes as stored, without colour management: 3 bytes per pixel, rows top to bottom.
    static func rgb(_ png: URL) throws -> (width: Int, height: Int, rgb: [UInt8]) {
        guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            throw Failure(description: "\(png.lastPathComponent) couldn't be read")
        }
        let bytesPerPixel = image.bitsPerPixel / 8
        let byteOrder = image.bitmapInfo.intersection(.byteOrderMask)
        guard image.bitsPerComponent == 8, bytesPerPixel == 3 || bytesPerPixel == 4,
              byteOrder == [] || byteOrder == .byteOrder32Big else {
            throw Failure(description: "\(png.lastPathComponent) has an unexpected layout")
        }
        let first: Int = switch image.alphaInfo {
        case .first, .premultipliedFirst, .noneSkipFirst: bytesPerPixel == 4 ? 1 : 0
        default: 0
        }
        var rgb: [UInt8] = []
        rgb.reserveCapacity(image.width * image.height * 3)
        for y in 0 ..< image.height {
            for x in 0 ..< image.width {
                let offset = y * image.bytesPerRow + x * bytesPerPixel + first
                rgb += [bytes[offset], bytes[offset + 1], bytes[offset + 2]]
            }
        }
        return (image.width, image.height, rgb)
    }

    /// An opaque sRGB image laid out as BrushRaster.context lays out pixels (RGBA8, premultipliedLast, big-endian).
    static func image(width: Int, height: Int, rgb: [UInt8]) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        guard let data = context.data else { throw Failure(description: "no bitmap memory") }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let source = (y * width + x) * 3, target = y * context.bytesPerRow + x * 4
                pixels[target] = rgb[source]
                pixels[target + 1] = rgb[source + 1]
                pixels[target + 2] = rgb[source + 2]
                pixels[target + 3] = 255
            }
        }
        guard let image = context.makeImage() else { throw Failure(description: "no image") }
        return image
    }

    /// An image's RGB bytes, read back by drawing it into a BrushRaster context; the image must be opaque.
    static func rgb(of image: CGImage) throws -> [UInt8] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false,
                         context: context)
        guard let data = context.data else { throw Failure(description: "no bitmap memory") }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var rgb: [UInt8] = []
        rgb.reserveCapacity(image.width * image.height * 3)
        for y in 0 ..< image.height {
            for x in 0 ..< image.width {
                let offset = y * context.bytesPerRow + x * 4
                rgb += [pixels[offset], pixels[offset + 1], pixels[offset + 2]]
            }
        }
        return rgb
    }

    static func probe() throws -> CGImage {
        let probe = try rgb(url("probe.png"))
        return try image(width: probe.width, height: probe.height, rgb: probe.rgb)
    }

    static func options(_ fixedLook: String) throws -> ProfileRenderOptions {
        switch fixedLook {
        case "full": ProfileRenderOptions(fixedLookTables: .full)
        case "scaled": ProfileRenderOptions(fixedLookTables: .scaledWithAmount)
        case "skipped": ProfileRenderOptions(fixedLookTables: .skipped)
        default: throw Failure(description: "unknown fixed-look policy \(fixedLook)")
        }
    }

    /// The largest channel difference, and how many channels differ at all.
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> (maximum: Int, differing: Int, mean: Double) {
        var maximum = 0, differing = 0, total = 0
        for (x, y) in zip(a, b) {
            let delta = abs(Int(x) - Int(y))
            maximum = max(maximum, delta)
            total += delta
            if delta != 0 { differing += 1 }
        }
        return (maximum, differing, Double(total) / Double(max(a.count, 1)))
    }
}

/// Compositor's renderer against the Python reference (scripts/profiles/reference/lrapply.py) on synthetic profiles.
struct ProfileGoldenTests {
    struct Case: Decodable, Sendable, CustomTestStringConvertible {
        let golden: String
        let profile: String
        let percent: Int
        let fixedLook: String
        var testDescription: String { golden }
    }

    static let cases: [Case] = (try? JSONDecoder().decode([Case].self, from: ProfileFixtureFiles.data("goldens.json"))) ?? []

    @Test func everyGoldenIsListed() {
        #expect(Self.cases.count == 25)
    }

    @Test(arguments: cases) func rendersLikeTheReference(_ golden: Case) throws {
        let profile = try ProfileFixtureFiles.loaded(golden.profile)
        let probe = try ProfileFixtureFiles.rgb(ProfileFixtureFiles.url("probe.png"))
        let input = try ProfileFixtureFiles.image(width: probe.width, height: probe.height, rgb: probe.rgb)
        let output = try ProfileRenderer.apply(input, profile: profile, percent: golden.percent,
                                               options: ProfileFixtureFiles.options(golden.fixedLook))
        let rendered = try ProfileFixtureFiles.rgb(of: output)
        let expected = try ProfileFixtureFiles.rgb(ProfileFixtureFiles.url(golden.golden))
        #expect(expected.width == probe.width && expected.height == probe.height)
        try #require(rendered.count == expected.rgb.count)

        let difference = ProfileFixtureFiles.difference(rendered, expected.rgb)
        if golden.golden == "golden-identity-srgb-100.png" {
            #expect(difference.maximum == 0)
            #expect(rendered == probe.rgb)
        } else {
            #expect(difference.maximum <= 1)
            #expect(Double(difference.differing) <= 0.005 * Double(rendered.count),
                    "\(difference.differing) of \(rendered.count) channels differ")
        }
    }
}
