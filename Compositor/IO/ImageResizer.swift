import Foundation
import CoreGraphics

nonisolated struct ImageSizeOptions: Sendable {
    var width: Int
    var height: Int
    var resolution: Double
    var sampling: LayerSampling = .high
}

actor ImageResizer {
    static let shared = ImageResizer()

    func resize(_ snapshot: ProjectSnapshot, to options: ImageSizeOptions) throws -> ProjectSnapshot {
        guard (1...DocumentLimits.maxSide).contains(options.width), (1...DocumentLimits.maxSide).contains(options.height),
              options.resolution.isFinite, (1...9600).contains(options.resolution) else { throw ProjectError.tooLarge }
        let old = snapshot.manifest
        var manifest = ProjectManifest(resolution: options.resolution, documentID: old.documentID,
            width: options.width, height: options.height, activeLayerID: old.activeLayerID, layers: [],
            guides: old.guides)
        if old.width == options.width && old.height == options.height {
            manifest.layers = old.layers
            return ProjectSnapshot(manifest: manifest, images: snapshot.images, masks: snapshot.masks)
        }
        guard options.width * options.height <= DocumentLimits.maxSurfacePixels else { throw ProjectError.tooLarge }
        let sx = CGFloat(options.width) / CGFloat(old.width)
        let sy = CGFloat(options.height) / CGFloat(old.height)
        manifest.guides = old.guides?.map { $0.scaled(x: sx, y: sy) }
        // The Photoshop file's canvas scales with the pixels, as the guides do (its saved paths are placed on it).
        let scaled = CGAffineTransform(scaleX: sx, y: sy)
        manifest.psd = old.psd.map { PSDDocumentExtrasRecord($0.extras.placingCanvas(scaled)) }
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        var usedPixels = 0, usedMaskPixels = 0
        for layer in old.layers {
            try Task.checkCancellation()
            let maskPlacement = layer.maskPlacement.map { $0.placing($0.unitToDocument.concatenating(CGAffineTransform(scaleX: sx, y: sy))) }
            if let editable = try resizeEditable(layer, snapshot: snapshot, sx: sx, sy: sy, sampling: options.sampling,
                                                  maskPlacement: maskPlacement, usedPixels: &usedPixels, usedMaskPixels: &usedMaskPixels) {
                images[layer.id] = editable.image
                if let mask = editable.mask { masks[layer.id] = mask }
                manifest.layers.append(editable.record)
                continue
            }
            // Rasterize each transformed layer independently. Nonuniform scaling of a
            // rotated rectangle can introduce shear, which width/height/angle cannot represent.
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
                .map { layer.transform.point($0) }.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
            let left = floor(corners.map(\.x).min()!), top = floor(corners.map(\.y).min()!)
            let width = Int(ceil(corners.map(\.x).max()!) - left)
            let height = Int(ceil(corners.map(\.y).max()!) - top)
            let transform = LayerTransform(origin: CGPoint(x: left, y: top),
                size: CGSize(width: width, height: height), sampling: options.sampling)
            guard transform.isValid else { throw ProjectError.tooLarge }
            if layer.imageFile != nil {
                guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height),
                      width * height <= DocumentLimits.documentPixelBudget - usedPixels else { throw ProjectError.tooLarge }
                usedPixels += width * height
                guard let source = snapshot.images[layer.id] else { throw ProjectError.missingImage }
                let asset = try autoreleasepool {
                    guard let context = CGContext(data: nil, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ExportError.render }
                    context.translateBy(x: 0, y: CGFloat(height))
                    context.scaleBy(x: 1, y: -1)
                    context.translateBy(x: -left, y: -top)
                    context.scaleBy(x: sx, y: sy)
                    var sourceTransform = layer.transform
                    sourceTransform.sampling = options.sampling
                    LayerRenderer.draw(source.image, transform: sourceTransform, center: sourceTransform.center, in: context)
                    guard let image = context.makeImage() else { throw ExportError.render }
                    return try Self.asset(image, name: source.name)
                }
                images[layer.id] = asset
            }
            if layer.maskFile != nil {
                guard let source = snapshot.masks[layer.id] else { throw ProjectError.missingImage }
                // Uniform masks are resolution independent; avoid allocating a full canvas for reveal/hide-all.
                // A mask on its own placement keeps its pixels; the placement scales with the canvas.
                if (source.image.width == 1 && source.image.height == 1) || layer.maskPlacement != nil { masks[layer.id] = source }
                else {
                    guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height),
                          width * height <= DocumentLimits.documentPixelBudget - usedMaskPixels else { throw ProjectError.tooLarge }
                    usedMaskPixels += width * height
                    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw ExportError.render }
                    context.translateBy(x: 0, y: CGFloat(height))
                    context.scaleBy(x: 1, y: -1)
                    context.translateBy(x: -left, y: -top)
                    context.scaleBy(x: sx, y: sy)
                    var sourceTransform = layer.transform
                    sourceTransform.sampling = options.sampling
                    LayerRenderer.drawCoverage(source.image, transform: sourceTransform, in: context)
                    guard let image = context.makeImage() else { throw ExportError.render }
                    masks[layer.id] = try LayerMask.asset(from: image)
                }
            }
            // The rotation and flips are now in the pixels, so a text or shape source no longer draws them.
            var record = layer.scaled(x: sx, y: sy, transform: transform, maskPlacement: maskPlacement)
            record.text = nil
            record.shape = nil
            // A smart object's placement is in the old grid's unit coordinates; the upright new grid has other ones.
            // Its corners go where the canvas scale takes them in the document, re-expressed on the new grid.
            if var info = record.smartObject {
                let scale = CGAffineTransform(scaleX: sx, y: sy)
                info.quad = info.quad.carried(from: layer.transform, by: scale, to: transform)
                info.nonAffineQuad = info.nonAffineQuad?.carried(from: layer.transform, by: scale, to: transform)
                guard info.isValid else { throw ProjectError.tooLarge }
                record.smartObject = info
            }
            // Effects were drawn in the old pixels and placed by the old transform; the new pixels are document pixels.
            let pixels = snapshot.images[layer.id]?.image
            var pixelMap = BrushRaster.pixelToDocument(layer.transform,
                width: pixels?.width ?? max(1, Int(layer.transform.size.width.rounded())),
                height: pixels?.height ?? max(1, Int(layer.transform.size.height.rounded())))
                .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            pixelMap.tx = 0; pixelMap.ty = 0
            record.effects = layer.effects?.baked(through: pixelMap)
            manifest.layers.append(record)
        }
        return ProjectSnapshot(manifest: manifest, images: images, masks: masks)
    }

    /// A live text or shape layer keeps its placement (rotation and flips included) and scales with the canvas, so
    /// it stays editable: a shape is drawn again at its new size, text is resampled and its type scaled to match.
    /// Nil for any other layer, and for a rotated one scaled unevenly (which would shear it); those are rasterized.
    private func resizeEditable(_ layer: ProjectLayerRecord, snapshot: ProjectSnapshot, sx: CGFloat, sy: CGFloat,
                                sampling: LayerSampling, maskPlacement: LayerTransform?, usedPixels: inout Int,
                                usedMaskPixels: inout Int) throws -> (record: ProjectLayerRecord, image: ImportedImage, mask: ImportedImage?)? {
        guard layer.imageFile != nil, layer.text != nil || layer.shape != nil, let source = snapshot.images[layer.id] else { return nil }
        let axisAligned = layer.transform.rotation.truncatingRemainder(dividingBy: 180) == 0
        guard axisAligned || abs(sx - sy) <= 0.01 * max(sx, sy) else { return nil }
        // Scale in the layer's own axes: the canvas's for an unrotated layer, the average for an evenly scaled one.
        let lx = axisAligned ? sx : (sx + sy) / 2, ly = axisAligned ? sy : (sx + sy) / 2
        var transform = layer.transform
        let center = CGPoint(x: transform.center.x * sx, y: transform.center.y * sy)
        transform.size = CGSize(width: transform.size.width * lx, height: transform.size.height * ly)
        transform.origin = CGPoint(x: center.x - transform.size.width / 2, y: center.y - transform.size.height / 2)
        guard transform.isValid else { throw ProjectError.tooLarge }
        let record = layer.scaled(x: lx, y: ly, transform: transform, maskPlacement: maskPlacement)
        let image: CGImage
        if let shape = record.shape {
            let width = max(1, Int(transform.size.width.rounded())), height = max(1, Int(transform.size.height.rounded()))
            try Self.reserve(width, height, in: &usedPixels)
            image = try EditorSession.shapeImage(shape, size: CGSize(width: width, height: height))
        } else {
            let width = max(1, Int((CGFloat(source.image.width) * lx).rounded()))
            let height = max(1, Int((CGFloat(source.image.height) * ly).rounded()))
            try Self.reserve(width, height, in: &usedPixels)
            image = try Self.resampled(source.image, width: width, height: height, mask: false, sampling: sampling)
        }
        var mask: ImportedImage?
        if layer.maskFile != nil {
            guard let owned = snapshot.masks[layer.id] else { throw ProjectError.missingImage }
            mask = owned
            // A mask over the layer's own pixel grid is resampled with it; uniform and separately placed masks keep their pixels.
            if layer.maskPlacement == nil, owned.image.width > 1 || owned.image.height > 1 {
                let width = max(1, Int((CGFloat(owned.image.width) * CGFloat(image.width) / CGFloat(source.image.width)).rounded()))
                let height = max(1, Int((CGFloat(owned.image.height) * CGFloat(image.height) / CGFloat(source.image.height)).rounded()))
                try Self.reserve(width, height, in: &usedMaskPixels)
                mask = try LayerMask.asset(from: Self.resampled(owned.image, width: width, height: height, mask: true, sampling: sampling))
            }
        }
        return (record, try Self.asset(image, name: source.name), mask)
    }

    private static func reserve(_ width: Int, _ height: Int, in used: inout Int) throws {
        guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height),
              width * height <= DocumentLimits.documentPixelBudget - used else {
            throw ProjectError.tooLarge
        }
        used += width * height
    }

    private static func resampled(_ image: CGImage, width: Int, height: Int, mask: Bool, sampling: LayerSampling) throws -> CGImage {
        try autoreleasepool {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: mask ? width : width * 4,
                space: mask ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: mask ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ExportError.render }
            context.interpolationQuality = sampling.quality
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let result = context.makeImage() else { throw ExportError.render }
            return result
        }
    }

    /// The image with a thumbnail of at most 96 pixels.
    private static func asset(_ image: CGImage, name: String) throws -> ImportedImage {
        let factor = min(1, 96 / CGFloat(max(image.width, image.height)))
        let tw = max(1, Int(CGFloat(image.width) * factor)), th = max(1, Int(CGFloat(image.height) * factor))
        guard let thumb = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8,
            bytesPerRow: tw * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ExportError.render }
        thumb.interpolationQuality = .high
        thumb.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let thumbnail = thumb.makeImage() else { throw ExportError.render }
        return ImportedImage(image: image, thumbnail: thumbnail, name: name)
    }
}

extension EditorSession {
    func applyImageSize(_ snapshot: ProjectSnapshot) {
        applyDocumentSize(snapshot, actionName: "Image Size")
    }

    func applyDocumentSize(_ snapshot: ProjectSnapshot, actionName: String) {
        guard let old = document, old.id == snapshot.manifest.documentID else { return }
        beginEdit(actionName)
        let m = snapshot.manifest
        // The resize carries the Photoshop data with its canvas placed anew; one that didn't keeps the document's.
        let psdExtras = m.psd?.extras ?? document?.psdExtras
        document = CanvasDocument(id: m.documentID, width: m.width, height: m.height,
            layers: m.layers.map { ImageLayer(record: $0, snapshot: snapshot) }, resolution: m.resolution ?? 72, guides: m.guides ?? [])
        document?.psdExtras = psdExtras
        redrawScaledText(from: old)
        endEdit()
        viewport.fit(documentSize: document!.size)
    }
}
