import AppKit
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import Compositor

@MainActor
struct ImageSizeTests {
    @Test func resizePreservesLayerIdentityAndUndoRestoresSource() async throws {
        let url = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let original = try #require(session.document)
        let layer = try #require(original.layers.first)
        let result = try await ImageResizer.shared.resize(try #require(session.projectSnapshot()),
            to: ImageSizeOptions(width: 128, height: 96, resolution: 300, sampling: .nearest))
        session.applyImageSize(result)
        #expect(session.document?.width == 128 && session.document?.height == 96)
        #expect(session.document?.resolution == 300)
        #expect(session.activeLayerID == layer.id)
        let asset = try #require(session.document?.layers.first?.asset)
        #expect(asset.image.width == 128 && asset.image.height == 96)
        let bitmap = NSBitmapImageRep(cgImage: asset.image)
        #expect(try #require(bitmap.colorAt(x: 0, y: 0)).redComponent > 0.95)
        #expect(try #require(bitmap.colorAt(x: 127, y: 0)).alphaComponent == 0)
        session.undo()
        #expect(session.document == original)
        #expect(session.document?.layers.first?.asset?.image === layer.asset?.image)
        session.redo()
        #expect(session.document?.resolution == 300)
    }

    @Test func resolutionOnlyRetainsPixelsAndSurvivesSaveAndExport() async throws {
        let session = EditorSession()
        session.createDocument(width: 32, height: 16)
        session.addBlankLayer()
        let before = try #require(session.projectSnapshot())
        let resized = try await ImageResizer.shared.resize(before,
            to: ImageSizeOptions(width: 32, height: 16, resolution: 300))
        #expect(resized.manifest.layers.first?.transform == before.manifest.layers.first?.transform)
        session.applyImageSize(resized)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Size-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(resized, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.resolution == 300)
        let png = try await ImageExporter.shared.pngData(loaded)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(abs((properties[kCGImagePropertyDPIWidth] as? Double ?? 0) - 300) < 1)
        session.undo()
        #expect(session.document?.resolution == 72)
    }

    @Test func rotatedHiddenLayerScalesInDocumentAxesAndInvalidSizeIsRejected() async throws {
        let url = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let snapshot = try #require(session.projectSnapshot())
        let record = try #require(snapshot.manifest.layers.first)
        var manifest = snapshot.manifest
        let transform = LayerTransform(origin: CGPoint(x: -16, y: 4), size: CGSize(width: 64, height: 32), rotation: 90)
        manifest.layers = [ProjectLayerRecord(id: record.id, name: record.name, isVisible: false,
            transform: transform, imageFile: record.imageFile)]
        let input = ProjectSnapshot(manifest: manifest, images: snapshot.images)
        let result = try await ImageResizer.shared.resize(input,
            to: ImageSizeOptions(width: 128, height: 96, resolution: 72, sampling: .nearest))
        let output = try #require(result.manifest.layers.first)
        #expect(!output.isVisible)
        #expect(output.transform.rotation == 0)
        // A 90-degree 64×32 layer becomes 32×64, then scales 2× horizontally and 3× vertically.
        #expect(abs(output.transform.size.width - 64) <= 1)
        #expect(abs(output.transform.size.height - 192) <= 1)
        #expect(output.transform.origin.y < 0)
        await #expect(throws: ProjectError.self) {
            try await ImageResizer.shared.resize(input, to: ImageSizeOptions(width: 30_000, height: 30_000, resolution: 72))
        }
        #expect(session.document?.width == 64)
    }
}

/// A 400×200 document holding point text, box text and a rounded rectangle, each carrying layer effects: what
/// Image Size, Canvas Size, Crop and copies must keep editable.
@MainActor
struct EditableLayers {
    let session: EditorSession
    let text: UUID, box: UUID, shape: UUID

    init() throws {
        let session = EditorSession()
        session.createDocument(width: 400, height: 200, emptyLayer: true)
        session.beginText(at: CGPoint(x: 10, y: 10))
        var draft = try #require(session.textDraft)
        draft.style.content = "Hi"; draft.style.fontSize = 20; draft.style.leading = 30; draft.style.tracking = 2
        try #require(session.applyText(draft))
        text = try #require(session.activeLayerID)
        session.beginText(in: CGRect(x: 10, y: 100, width: 100, height: 50))
        draft = try #require(session.textDraft)
        draft.style.content = "Box"; draft.style.fontSize = 12
        try #require(session.applyText(draft))
        box = try #require(session.activeLayerID)
        session.selectTool(.shape)
        session.shapeCornerRadius = 4
        session.beginShape(at: CGPoint(x: 200, y: 50))
        session.dragShape(to: CGPoint(x: 260, y: 90), square: false, fromCenter: false)
        session.finishShape()
        shape = try #require(session.activeLayerID)
        var effects = LayerEffects()
        effects.stroke = StrokeEffect(size: 6)
        effects.shadow = ShadowEffect(distance: 5, blur: 7)
        effects.innerShadow = InnerShadowEffect(distance: 2, blur: 4)
        effects.outerGlow = OuterGlowEffect(size: 3)
        effects.innerGlow = InnerGlowEffect(size: 5)
        session.setEffects(effects, on: shape, name: "Effects")
        var textEffects = LayerEffects()
        textEffects.stroke = StrokeEffect(size: 3)
        session.setEffects(textEffects, on: text, name: "Stroke")
        var boxEffects = LayerEffects()
        boxEffects.stroke = StrokeEffect(size: 300)
        session.setEffects(boxEffects, on: box, name: "Stroke")
        self.session = session
        let live = try layer(shape).liveShape != nil && layer(text).liveText != nil && layer(box).liveText != nil
        try #require(live)
    }

    func layer(_ id: UUID) throws -> ImageLayer { try #require(session.document?.layers.first { $0.id == id }) }
}

extension ImageSizeTests {
    @Test func imageSizeKeepsEditableTextShapesAndEffectsAtTheNewScale() async throws {
        let fixture = try EditableLayers()
        let session = fixture.session
        let before = try #require(session.document)
        let oldText = try fixture.layer(fixture.text)
        let resized = try await ImageResizer.shared.resize(try #require(session.projectSnapshot()),
            to: ImageSizeOptions(width: 800, height: 400, resolution: 72))
        session.applyImageSize(resized)

        let textLayer = try fixture.layer(fixture.text)
        let text = try #require(textLayer.liveText)
        #expect(text.style.fontSize == 40 && text.style.leading == 60 && text.style.tracking == 4)
        #expect(text.style.content == "Hi")
        // Drawn again at the new size (see imageSizeDrawsLiveTextAgainAtTheNewSize), not resampled.
        #expect(textLayer.asset?.image.width == Int(EditorSession.textBoxSize(text.style).width))
        #expect(oldText.asset?.image.width != nil)
        #expect(textLayer.effects?.stroke?.size == 6)

        let box = try #require(try fixture.layer(fixture.box).liveText)
        // The text's area (the box less its 12-pixel padding) doubles.
        #expect(box.style.boxSize == CGSize(width: 176, height: 76))
        #expect(box.style.fontSize == 24)
        // Effects scale with the image but stay within what each effect supports.
        #expect(try fixture.layer(fixture.box).effects?.stroke?.size == StrokeEffect.maxSize)

        let shapeLayer = try fixture.layer(fixture.shape)
        let shape = try #require(shapeLayer.liveShape)
        #expect(shape.style.cornerRadius == 8)
        #expect(shapeLayer.transform.origin == CGPoint(x: 400, y: 100))
        #expect(shapeLayer.transform.size == CGSize(width: 120, height: 80))
        #expect(shapeLayer.asset?.image.width == 120 && shapeLayer.asset?.image.height == 80)
        let effects = try #require(shapeLayer.effects)
        #expect(effects.stroke?.size == 12)
        #expect(effects.shadow?.distance == 10 && effects.shadow?.blur == 14)
        #expect(effects.innerShadow?.distance == 4 && effects.innerShadow?.blur == 8)
        #expect(effects.outerGlow?.size == 6)
        #expect(effects.innerGlow?.size == 10)

        // Still live, so saving writes the scaled sources.
        let saved = try #require(session.projectSnapshot()).manifest.layers
        #expect(saved.first { $0.id == fixture.text }?.text?.fontSize == 40)
        #expect(saved.first { $0.id == fixture.shape }?.shape?.cornerRadius == 8)

        session.undo()
        #expect(session.document == before)
    }

    /// Live text is typeset again from its scaled style, so it stays sharp: its pixels are exactly what the text draws at
    /// the new size, and its letters stay where the resize took them (the first baseline's alignment point for point
    /// text, the text area's corner for a paragraph). One undo step puts it all back.
    @Test func imageSizeDrawsLiveTextAgainAtTheNewSize() async throws {
        let fixture = try EditableLayers()
        let session = fixture.session
        let before = try #require(session.document)
        func anchor(_ layer: ImageLayer) throws -> CGPoint {
            let metrics = EditorSession.textMetrics(try #require(layer.liveText?.style))
            return layer.transform.point(CGPoint(x: metrics.alignmentX / metrics.size.width, y: metrics.firstBaseline / metrics.size.height))
        }
        let oldAnchor = try anchor(try fixture.layer(fixture.text))
        let resized = try await ImageResizer.shared.resize(try #require(session.projectSnapshot()),
            to: ImageSizeOptions(width: 800, height: 400, resolution: 72))
        session.applyImageSize(resized)

        for id in [fixture.text, fixture.box] {
            let layer = try fixture.layer(id)
            let text = try #require(layer.liveText)
            let fresh = try EditorSession.textImage(text.style)
            #expect(text.image.width == fresh.width && text.image.height == fresh.height)
            #expect(text.image.dataProvider?.data as Data? == fresh.dataProvider?.data as Data?)
            #expect(layer.transform.size == CGSize(width: fresh.width, height: fresh.height))
        }
        let newAnchor = try anchor(try fixture.layer(fixture.text))
        #expect(abs(newAnchor.x - 2 * oldAnchor.x) < 0.01 && abs(newAnchor.y - 2 * oldAnchor.y) < 0.01, "\(newAnchor) vs \(oldAnchor)")
        // The box's text area started at (10, 100) + 12; doubled, it starts at (44, 224).
        let padding = LayerTextStyle.padding
        #expect(try fixture.layer(fixture.box).transform.origin == CGPoint(x: 44 - padding, y: 224 - padding))

        session.undo()
        #expect(session.document == before)
    }

    @Test func imageSizeResamplesAnEditableLayersOwnMaskWithItsPixels() async throws {
        let fixture = try EditableLayers()
        let session = fixture.session
        session.selectLayer(fixture.shape)
        session.applySelection(CGPath(rect: CGRect(x: 200, y: 50, width: 30, height: 40), transform: nil), mode: .replace, name: "Select")
        session.addMask(revealing: true)
        #expect(try fixture.layer(fixture.shape).mask?.asset.image.width == 60)
        let resized = try await ImageResizer.shared.resize(try #require(session.projectSnapshot()),
            to: ImageSizeOptions(width: 800, height: 400, resolution: 72))
        session.applyImageSize(resized)
        let layer = try fixture.layer(fixture.shape)
        let mask = try #require(layer.mask)
        #expect(mask.placement == nil)
        #expect(mask.asset.image.width == 120 && mask.asset.image.height == 80)
        #expect(layer.liveShape != nil)
    }

    /// A 40×20 opaque pixel layer at the origin of a 100×100 document, carrying `effects`, placed by `transform`.
    private func pixelLayer(effects: LayerEffects, transform: (inout LayerTransform) -> Void) throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100)
        let context = try BrushRaster.context(width: 40, height: 20, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Pixels"))
        let index = try #require(session.document?.layers.firstIndex { $0.id == session.activeLayerID })
        transform(&session.document!.layers[index].transform)
        session.setEffects(effects)
        #expect(session.activeLayer?.effects == effects)
        return session
    }

    @Test func imageSizeScalesBakedEffectsByTheLayersOwnPixelScale() async throws {
        var effects = LayerEffects()
        effects.stroke = StrokeEffect(size: 10)
        effects.shadow = ShadowEffect(angle: 90, distance: 10, blur: 8)
        // Shown at 50%: the 10-pixel stroke is 5 document pixels wide, 10 once the document doubles.
        let session = try pixelLayer(effects: effects) { $0.size = CGSize(width: 20, height: 10) }
        let resized = try await ImageResizer.shared.resize(try #require(session.projectSnapshot()),
            to: ImageSizeOptions(width: 200, height: 200, resolution: 72))
        session.applyImageSize(resized)
        let layer = try #require(session.activeLayer)
        #expect(layer.asset?.image.width == 40 && layer.asset?.image.height == 20)
        let baked = try #require(layer.effects)
        #expect(abs((baked.stroke?.size ?? 0) - 10) < 0.0001)
        #expect(abs((baked.shadow?.blur ?? 0) - 8) < 0.0001)
        #expect(abs((baked.shadow?.distance ?? 0) - 10) < 0.0001)
        #expect(abs((baked.shadow?.angle ?? 0) - 90) < 0.0001)
    }

    @Test func imageSizeKeepsARotatedFlippedLayersShadowFallingTheSameWay() async throws {
        var effects = LayerEffects()
        // Lit from the right in the layer's own pixels: the shadow falls to the layer's left.
        effects.shadow = ShadowEffect(angle: 0, distance: 10, blur: 4)
        effects.innerShadow = InnerShadowEffect(angle: 0, distance: 6, blur: 2)
        effects.innerGlow = InnerGlowEffect(size: 3)
        let session = try pixelLayer(effects: effects) { $0.rotation = 90; $0.flipX = true }
        let resized = try await ImageResizer.shared.resize(try #require(session.projectSnapshot()),
            to: ImageSizeOptions(width: 200, height: 200, resolution: 72))
        session.applyImageSize(resized)
        let layer = try #require(session.activeLayer)
        #expect(layer.transform.rotation == 0 && !layer.transform.flipX)
        // Flipped, the shadow falls to the layer's right; turned 90° clockwise, that is straight down the document,
        // twice as far: a light from straight above (90°) in the baked pixels.
        let shadow = try #require(layer.effects?.shadow)
        #expect(abs(shadow.angle - 90) < 0.0001 && abs(shadow.distance - 20) < 0.0001 && abs(shadow.blur - 8) < 0.0001)
        let inner = try #require(layer.effects?.innerShadow)
        #expect(abs(inner.angle - 90) < 0.0001 && abs(inner.distance - 12) < 0.0001 && abs(inner.blur - 4) < 0.0001)
        // Sizes scale with the baked pixels too: the glow is twice as wide in a raster twice the size.
        #expect(abs((layer.effects?.innerGlow?.size ?? 0) - 6) < 0.0001)
        #expect(layer.effects?.isValid == true)
    }

    @Test func recordScalingClampsEffectsAndDropsTextItCannotHold() {
        var text = LayerTextStyle(); text.fontSize = 1500
        var effects = LayerEffects()
        effects.outerGlow = OuterGlowEffect(size: 400)
        effects.innerGlow = InnerGlowEffect(size: 300)
        effects.shadow = ShadowEffect(distance: 3000, blur: 10)
        let transform = LayerTransform(origin: .zero, size: CGSize(width: 10, height: 10))
        let record = ProjectLayerRecord(id: UUID(), name: "Text", isVisible: true, transform: transform,
            imageFile: nil, effects: effects, text: text)
        let scaled = record.scaled(x: 2, y: 2, transform: transform, maskPlacement: nil)
        #expect(scaled.text == nil)
        #expect(scaled.effects?.outerGlow?.size == OuterGlowEffect.maxSize)
        #expect(scaled.effects?.innerGlow?.size == InnerGlowEffect.maxSize)
        #expect(scaled.effects?.shadow?.distance == ShadowEffect.maxDistance && scaled.effects?.shadow?.blur == 20)
        #expect(scaled.effects?.isValid == true)
        let moved = record.translated(by: CGPoint(x: 5, y: -3))
        #expect(moved.transform.origin == CGPoint(x: 5, y: -3) && moved.text == text && moved.effects == effects)
    }

    @Test func imageSizeKeepsRotatedTextEditableWhenScaledEvenly() async throws {
        let fixture = try EditableLayers()
        let session = fixture.session
        session.selectLayer(fixture.text)
        session.beginTransform()
        var transform = try #require(session.transformEdit?.draft)
        transform.rotation = 30
        session.previewTransform(transform)
        session.commitTransform()
        // The first baseline's alignment point, in the document.
        func anchor(_ layer: ImageLayer) throws -> CGPoint {
            let metrics = EditorSession.textMetrics(try #require(layer.liveText?.style))
            return layer.transform.point(CGPoint(x: metrics.alignmentX / metrics.size.width, y: metrics.firstBaseline / metrics.size.height))
        }
        let rotated = try anchor(try fixture.layer(fixture.text))
        let resized = try await ImageResizer.shared.resize(try #require(session.projectSnapshot()),
            to: ImageSizeOptions(width: 800, height: 400, resolution: 72))
        session.applyImageSize(resized)
        let layer = try fixture.layer(fixture.text)
        let style = try #require(layer.liveText?.style)
        #expect(style.fontSize == 40)
        #expect(layer.transform.rotation == 30)
        // Typeset again at the new size, turned as it was, its letters where the resize took them.
        #expect(layer.transform.size == EditorSession.textBoxSize(style))
        let moved = try anchor(layer)
        #expect(abs(moved.x - rotated.x * 2) < 0.001 && abs(moved.y - rotated.y * 2) < 0.001)
    }
}
