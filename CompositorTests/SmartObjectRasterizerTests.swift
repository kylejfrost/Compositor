import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Compositor

/// Smart-object contents are told apart by type, measured, and drawn at the size a layer needs.
@MainActor
struct SmartObjectRasterizerTests {
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = y * context.bytesPerRow + x * 4
        return (0..<4).map { data[offset + $0] }
    }

    /// Within 3 of `expected` in every channel (color matching may round a step either way).
    private func near(_ pixel: [UInt8], _ expected: [UInt8]) -> Bool {
        pixel.count == 4 && zip(pixel, expected).allSatisfy { abs(Int($0) - Int($1)) <= 3 }
    }

    private func png(width: Int, height: Int, dpi: Double? = nil) throws -> Data {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        let properties = dpi.map { [kCGImagePropertyDPIWidth: $0, kCGImagePropertyDPIHeight: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), properties)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func pdf(width: CGFloat, height: CGFloat) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private let svg = Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" viewBox="0 0 10 10"><rect width="10" height="10" fill="#ff0000"/></svg>"##.utf8)

    @Test func contentsAreToldApartByTypeThenBytesThenName() throws {
        let png = try png(width: 2, height: 2)
        #expect(SmartObjectRasterizer.kind(fileType: "8BPB", fileName: "", data: Data()) == .psb)
        #expect(SmartObjectRasterizer.kind(fileType: "8BPS", fileName: "", data: Data()) == .psd)
        #expect(SmartObjectRasterizer.kind(fileType: "png ", fileName: "", data: png) == .bitmap)
        #expect(SmartObjectRasterizer.kind(fileType: "SVG ", fileName: "", data: svg) == .svg)
        #expect(SmartObjectRasterizer.kind(fileType: "PDF ", fileName: "", data: Data()) == .pdf)
        #expect(SmartObjectRasterizer.kind(fileType: "EPSF", fileName: "", data: Data()) == .eps)
        #expect(SmartObjectRasterizer.kind(fileType: "", fileName: "Logo", data: png) == .bitmap)
        #expect(SmartObjectRasterizer.kind(fileType: "", fileName: "", data: svg) == .svg)
        #expect(SmartObjectRasterizer.kind(fileType: "", fileName: "", data: try pdf(width: 4, height: 4)) == .pdf)
        #expect(SmartObjectRasterizer.kind(fileType: "", fileName: "", data: Data("8BPS\0\u{2}".utf8)) == .psb)
        #expect(SmartObjectRasterizer.kind(fileType: "", fileName: "", data: Data("%!PS-Adobe-3.0 EPSF-3.0".utf8)) == .eps)
        #expect(SmartObjectRasterizer.kind(fileType: "", fileName: "Art.svg", data: Data("  ".utf8)) == .svg)
        #expect(SmartObjectRasterizer.kind(fileType: "", fileName: "notes.txt", data: Data("hello".utf8)) == .unknown)
    }

    @Test func aPNGsNaturalSizeIsItsPixels() async throws {
        let data = try png(width: 10, height: 8, dpi: 144)
        let natural = try SmartObjectRasterizer.naturalSize(data, kind: .bitmap, page: 1)
        #expect(natural.size == CGSize(width: 10, height: 8))
        #expect(natural.resolution == 144)
        let image = try await SmartObjectRasterizer.rasterize(data, kind: .bitmap, pixelSize: CGSize(width: 20, height: 16), page: 1)
        #expect(image.width == 20 && image.height == 16)
        let center = try pixel(image, x: 10, y: 8)
        #expect(near(center, [0, 255, 0, 255]), "\(center)")
    }

    /// Doubles as the check that AppKit draws SVG on this macOS.
    @Test func aTenPixelSVGRectDrawsRed() async throws {
        let natural = try SmartObjectRasterizer.naturalSize(svg, kind: .svg, page: 1)
        #expect(natural.size == CGSize(width: 10, height: 10))
        #expect(natural.resolution == nil)
        let image = try await SmartObjectRasterizer.rasterize(svg, kind: .svg, pixelSize: CGSize(width: 10, height: 10), page: 1)
        #expect(image.width == 10 && image.height == 10)
        let center = try pixel(image, x: 5, y: 5)
        #expect(near(center, [255, 0, 0, 255]), "\(center)")
    }

    @Test func aPDFsNaturalSizeIsItsPage() async throws {
        let data = try pdf(width: 200, height: 100)
        let natural = try SmartObjectRasterizer.naturalSize(data, kind: .pdf, page: 1)
        #expect(natural.size == CGSize(width: 200, height: 100))
        #expect(natural.resolution == nil)
        let image = try await SmartObjectRasterizer.rasterize(data, kind: .pdf, pixelSize: CGSize(width: 20, height: 10), page: 1)
        #expect(image.width == 20 && image.height == 10)
        let center = try pixel(image, x: 10, y: 5)
        #expect(near(center, [0, 0, 255, 255]), "\(center)")
        #expect(throws: SmartObjectError.unreadable) { try SmartObjectRasterizer.naturalSize(data, kind: .pdf, page: 2) }
    }

    @Test func aPhotoshopDocumentDrawsItsLayers() async throws {
        let context = try BrushRaster.context(width: 6, height: 4, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 6, height: 4))
        var record = PSDRecord(id: UUID(), name: "Red")
        record.bounds = CGRect(x: 0, y: 0, width: 6, height: 4)
        let red = try #require(context.makeImage())
        record.image = red
        let data = try PSDFixture.data(PSDDocument(width: 6, height: 4, resolution: 150, layers: [record]), composite: red)
        #expect(SmartObjectRasterizer.kind(fileType: "", fileName: "", data: data) == .psd)
        let natural = try SmartObjectRasterizer.naturalSize(data, kind: .psd, page: 1)
        #expect(natural.size == CGSize(width: 6, height: 4) && natural.resolution == 150)
        let image = try await SmartObjectRasterizer.rasterize(data, kind: .psd, pixelSize: CGSize(width: 12, height: 8), page: 1)
        #expect(image.width == 12 && image.height == 8)
        let center = try pixel(image, x: 6, y: 4)
        #expect(near(center, [255, 0, 0, 255]), "\(center)")
    }

    /// The layers of Photoshop contents are drawn from images taken off the main actor, with no thumbnails (the
    /// snapshot is only composited): what the main actor builds uses those images as they are.
    @Test func photoshopContentsAreSnapshottedFromImagesTakenOffTheMainActor() throws {
        let context = try BrushRaster.context(width: 6, height: 4, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 6, height: 4))
        let red = try #require(context.makeImage())
        var record = PSDRecord(id: UUID(), name: "Red")
        record.bounds = CGRect(x: 0, y: 0, width: 6, height: 4)
        record.image = red
        let document = try PSDReader.read(try PSDFixture.data(PSDDocument(width: 6, height: 4, resolution: 72, layers: [record]),
                                                              composite: red))
        let assets = try PSDDocumentBuilder.assets(from: document, thumbnails: false)
        let id = try #require(document.layers.first?.id)
        let asset = try #require(assets[id])
        #expect(asset.thumbnail === asset.image)
        let snapshot = try SmartObjectRasterizer.snapshot(of: document, assets: assets)
        #expect(snapshot.images[id]?.image === asset.image && snapshot.images[id]?.thumbnail === asset.image)
    }

    @Test func largeDocumentsAndUnknownContentsAreNotDrawn() async throws {
        let psb = Data("8BPS\0\u{2}".utf8) + Data(count: 40)
        #expect(throws: SmartObjectError.largeDocument) { try SmartObjectRasterizer.naturalSize(psb, kind: .psb, page: 1) }
        await #expect(throws: SmartObjectError.largeDocument) {
            try await SmartObjectRasterizer.rasterize(psb, kind: .psb, pixelSize: CGSize(width: 4, height: 4), page: 1)
        }
        await #expect(throws: SmartObjectError.unsupported) {
            try await SmartObjectRasterizer.rasterize(Data("hello".utf8), kind: .unknown, pixelSize: CGSize(width: 4, height: 4), page: 1)
        }
        // macOS no longer interprets PostScript, so EPS contents keep their pixels.
        let eps = Data("%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 10 10\n0 0 10 10 rectfill\n%%EOF\n".utf8)
        #expect(throws: SmartObjectError.unsupported) { try SmartObjectRasterizer.naturalSize(eps, kind: .eps, page: 1) }
        #expect(throws: SmartObjectError.unreadable) { try SmartObjectRasterizer.naturalSize(Data("nope".utf8), kind: .bitmap, page: 1) }
        await #expect(throws: ImageImportError.self) {
            try await SmartObjectRasterizer.rasterize(try png(width: 2, height: 2), kind: .bitmap,
                                                      pixelSize: CGSize(width: 40_000, height: 2), page: 1)
        }
    }
}
