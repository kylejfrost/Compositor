import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Photoshop's "Layer Knocks Out Drop Shadow" (the drop shadow's `layerConceals`, on by default): the layer's own
/// shape hides its drop shadow, so a layer at Fill below 100 % (or with see-through pixels) shows the shadow only
/// outside its shape. On the GPU and off it, when exported, and as a Photoshop file sets it.
@MainActor
struct DropShadowKnockoutTests {
    /// A 40-pixel transparent image with a white square, 20 pixels wide and `alpha` opaque, in its middle.
    private func square(alpha: CGFloat = 1) throws -> CGImage {
        let context = try BrushRaster.context(width: 40, height: 40, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha))
        context.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
        return try #require(context.makeImage())
    }

    /// Premultiplied RGBA bytes of every pixel, rows from the top.
    private func bytes(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: data, count: image.width * image.height * 4))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
        let all = try bytes(image)
        let index = (y * image.width + x) * 4
        return (0..<4).map { Int(all[index + $0]) }
    }

    /// A black, unblurred drop shadow 6 pixels straight down.
    private func shadow(knocksOut: Bool? = nil) -> LayerEffects {
        var shadow = ShadowEffect(angle: 90, distance: 6, blur: 0, red: 0, green: 0, blue: 0, opacity: 1)
        shadow.knocksOut = knocksOut
        return LayerEffects(shadow: shadow)
    }

    // MARK: Rendering

    /// Fill 0 with Photoshop's default: inside the square (where the shadow lies under it) nothing shows; below the
    /// square, where the shadow falls past its edge, the shadow does.
    @Test(arguments: [true, false]) func atFillZeroTheShadowShowsOnlyOutsideTheShape(gpu: Bool) throws {
        let rendered = try LayerEffectsRenderer.render(square(), mask: nil, effects: shadow(), fill: 0, usingGPU: gpu)
        let inset = Int(rendered.inset)
        #expect(try pixel(rendered.image, x: inset + 20, y: inset + 20) == [0, 0, 0, 0])
        #expect(try pixel(rendered.image, x: inset + 20, y: inset + 33) == [0, 0, 0, 255])
    }

    /// Knockout turned off (as a Photoshop file can have it): the shadow shows through the faded layer.
    @Test(arguments: [true, false]) func withKnockoutOffTheShadowShowsThroughAFadedLayer(gpu: Bool) throws {
        let rendered = try LayerEffectsRenderer.render(square(), mask: nil, effects: shadow(knocksOut: false), fill: 0,
                                                       usingGPU: gpu)
        let inset = Int(rendered.inset)
        #expect(try pixel(rendered.image, x: inset + 20, y: inset + 20) == [0, 0, 0, 255])
    }

    /// At Fill 100 a half-transparent layer knocks out half of the shadow under it. The shadow there is 0.5 (the
    /// shape's own alpha), knocked out to 0.25, and 0.5 white over it gives alpha 0.625 (159); the shadow drawn whole
    /// under the layer would give 0.75 (191).
    @Test(arguments: [true, false]) func halfTransparentPixelsKnockOutHalfTheShadow(gpu: Bool) throws {
        let rendered = try LayerEffectsRenderer.render(square(alpha: 0.5), mask: nil, effects: shadow(), usingGPU: gpu)
        let inset = Int(rendered.inset)
        let inside = try pixel(rendered.image, x: inset + 20, y: inset + 20)
        #expect(abs(inside[3] - 159) <= 2 && abs(inside[0] - 128) <= 2, "\(inside)")
    }

    /// The Metal and CPU renderers draw the same knocked-out shadow, for faded and see-through layers, with the
    /// knockout on and off.
    @Test func metalAndCPURenderersAgree() throws {
        try #require(MetalLayerEffects.shared != nil)
        for alpha: CGFloat in [1, 0.5] {
            for fill in [0, 0.4, 1.0] {
                for knocksOut: Bool? in [nil, false] {
                    let image = try square(alpha: alpha)
                    let gpu = try LayerEffectsRenderer.render(image, mask: nil, effects: shadow(knocksOut: knocksOut),
                                                              fill: fill, usingGPU: true)
                    let cpu = try LayerEffectsRenderer.render(image, mask: nil, effects: shadow(knocksOut: knocksOut),
                                                              fill: fill, usingGPU: false)
                    #expect(gpu.inset == cpu.inset)
                    let difference = zip(try bytes(gpu.image), try bytes(cpu.image)).map { abs(Int($0) - Int($1)) }.max()
                    #expect((difference ?? 0) <= 2, "alpha \(alpha), fill \(fill), knocksOut \(String(describing: knocksOut))")
                }
            }
        }
    }

    /// Exported (as PNG/JPEG export and MCP previews render): a Fill 0 layer's shadow shows only outside the layer.
    @Test func exportKnocksTheShadowOutOfAFillZeroLayer() async throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 40)
        let image = try square()
        var layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: image, name: "Square"), origin: .zero)
        layer.fillOpacity = 0
        layer.effects = shadow()
        session.document?.layers = [layer]
        let rendered = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        #expect(try pixel(rendered, x: 20, y: 20)[3] == 0)
        #expect(try pixel(rendered, x: 20, y: 33) == [0, 0, 0, 255])
    }

    // MARK: Photoshop files

    /// `layerConceals` false imports as knockout off; true, or missing, as Photoshop's default.
    @Test func photoshopLayerConcealsImportsAsTheKnockout() throws {
        for (conceals, expected) in [(Bool?.some(false), Bool?.some(false)), (true, nil), (nil, nil)] {
            let entry = PSDFixture.shadowEffect(layerConceals: conceals)
            let result = try PSDEffectsReader.parse(PSDFixture.effectsBlock([(key: "DrSh", value: entry)]),
                                                    globalLightAngle: nil)
            #expect(result.effects.shadow?.knocksOut == expected, "\(String(describing: conceals))")
            #expect(result.effects.shadow?.isKnockedOut == (expected ?? true))
        }
    }

    /// A Photoshop file's knockout off survives an edit to its shadow: the writer changes only the edited value in
    /// the file's own `lfx2`, so `layerConceals` stays false, and the saved file opens with the knockout still off.
    @Test func knockoutOffSurvivesAnEditedShadowOnSave() throws {
        var record = PSDRecord(id: UUID(), name: "Ghost")
        record.bounds = CGRect(x: 10, y: 10, width: 40, height: 40)
        record.image = try square()
        let lfx2 = PSDFixture.effectsBlock([(key: "DrSh", value: PSDFixture.shadowEffect(layerConceals: false))])
        record.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "lfx2", data: lfx2)])
        let document = PSDDocument(width: 64, height: 64, resolution: 72, layers: [record])
        let session = EditorSession()
        try session.insertPhotoshop(try PSDDocumentBuilder.makeImport(try PSDReader.read(
            try PSDFixture.data(document, composite: try square()))), named: "Fixture")
        let index = try #require(session.document?.layers.firstIndex { $0.name == "Ghost" })
        #expect(session.document?.layers[index].effects?.shadow?.knocksOut == false)
        session.document?.layers[index].effects?.shadow?.distance = 9

        let records = try PSDLayerRecordWriter.plan(try #require(session.psdWriteRequest()), options: .init()).records
        let written = try #require(records.first { $0.name == "Ghost" }?.blocks.first { $0.key == "lfx2" }?.data)
        let reread = try PSDEffectsReader.parse(written, globalLightAngle: nil)
        #expect(reread.effects.shadow?.knocksOut == false)
        #expect(reread.effects.shadow?.distance == 9)
    }
}
