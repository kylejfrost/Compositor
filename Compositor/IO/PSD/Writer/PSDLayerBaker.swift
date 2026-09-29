import CoreGraphics
import Foundation

/// Places a layer's pixels and mask the way a PSD layer record holds them: axis-aligned rectangles of whole document
/// pixels, one image pixel to each. A layer drawn upright at its own size is written as its own image, losslessly;
/// any other transform is drawn exactly as `ImageExporter` draws it (`LayerRenderer.draw`) into the box around its
/// corners, then trimmed to the pixels that are there.
nonisolated enum PSDLayerBaker {
    /// Limits on a layer's rectangle: PSD (version 1) sides, and one surface Compositor draws (`DocumentLimits`).
    static let maximumSide: CGFloat = DocumentLimits.maxSideExtent
    static let maximumArea: CGFloat = DocumentLimits.maxSurfaceExtent

    struct Pixels {
        let rect: CGRect
        /// `rect`'s size.
        let image: CGImage
        /// The layer was larger than a record can hold, so only its part on the canvas was kept.
        let clipped: Bool
    }

    struct Mask {
        let rect: CGRect
        /// Gray coverage, `rect`'s size.
        let image: CGImage
        /// What the mask is beyond `rect`: 255 reveals, 0 hides.
        let defaultColor: UInt8
    }

    /// Whether `transform` draws a `width` × `height` image one pixel to a document pixel on the whole-pixel grid,
    /// unrotated and unflipped.
    static func isUpright(_ transform: LayerTransform, width: Int, height: Int) -> Bool {
        transform.rotation.truncatingRemainder(dividingBy: 360) == 0 && !transform.flipX && !transform.flipY
            && transform.size == CGSize(width: width, height: height)
            && transform.origin.x == transform.origin.x.rounded() && transform.origin.y == transform.origin.y.rounded()
    }

    /// `image` placed by `transform`, as a record's pixels; nil when none of it can be kept.
    static func pixels(_ image: CGImage, transform: LayerTransform, canvas: CGRect) throws -> Pixels? {
        if isUpright(transform, width: image.width, height: image.height) {
            let rect = CGRect(origin: transform.origin, size: transform.size)
            if fits(rect) { return Pixels(rect: rect, image: image, clipped: false) }
        }
        guard let box = box(around: transform, canvas: canvas) else { return nil }
        let context = try BrushRaster.context(width: Int(box.rect.width), height: Int(box.rect.height), mask: false)
        var placed = transform
        placed.origin.x -= box.rect.minX
        placed.origin.y -= box.rect.minY
        LayerRenderer.draw(image, transform: placed, center: placed.center, in: context)
        guard let drawn = context.makeImage() else { throw PSDWriteError.render }
        let trimmed = try PixelFilter.trimmed(drawn, placed: LayerTransform(origin: box.rect.origin, size: box.rect.size))
        let origin = CGPoint(x: trimmed.transform.origin.x.rounded(), y: trimmed.transform.origin.y.rounded())
        return Pixels(rect: CGRect(origin: origin, size: CGSize(width: trimmed.image.width, height: trimmed.image.height)),
                      image: trimmed.image, clipped: box.clipped)
    }

    /// `mask` as a record holds it. A mask placed upright at its own size keeps its own pixels and rectangle (so does
    /// one covering an upright layer at the layer's size); any other is resampled into `rect` — the layer's pixel
    /// rectangle, or for a layer without pixels the box around `transform`. Beyond the mask's rectangle, its default
    /// color shows: white or black, whichever most of its edge is (`LayerMask.background`).
    ///
    /// `stored` is where a mask import padded was stored in the file (within the mask's own pixels) and the default
    /// color it was padded with (`PSDLayerExtras.importedMaskRect`, `maskDefaultColor`). A mask that keeps its own
    /// pixels is cropped back to that rectangle when every pixel outside it is still that color, which loses nothing.
    static func mask(_ mask: LayerMask, layer transform: LayerTransform, rect: CGRect?, canvas: CGRect,
                     stored: (rect: CGRect, defaultColor: UInt8)? = nil) throws -> Mask? {
        let image = mask.asset.image
        let background = LayerMask.background(of: mask.asset.thumbnail)
        let defaultColor: UInt8 = background >= 0.5 ? 255 : 0
        let placement = mask.placement ?? transform
        if isUpright(placement, width: image.width, height: image.height) {
            let own = CGRect(origin: placement.origin, size: placement.size)
            if let stored, let cropped = try cropped(image, to: stored.rect, outsideAll: stored.defaultColor) {
                return Mask(rect: stored.rect.offsetBy(dx: own.minX, dy: own.minY), image: cropped, defaultColor: stored.defaultColor)
            }
            if fits(own) { return Mask(rect: own, image: image, defaultColor: defaultColor) }
        }
        guard let target = rect ?? box(around: transform, canvas: canvas)?.rect else { return nil }
        let resampled = try LayerMask.placed(width: Int(target.width), height: Int(target.height),
                                             layer: LayerTransform(origin: target.origin, size: target.size),
                                             placement: placement, maskWidth: image.width, maskHeight: image.height,
                                             background: background) { context in
            LayerMask.drawSmooth(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), context: context)
        }
        return Mask(rect: target, image: resampled, defaultColor: defaultColor)
    }

    /// The part of the gray `image` inside `rect` (whole pixels, within the image), when every pixel outside it is
    /// `value`; nil otherwise.
    private static func cropped(_ image: CGImage, to rect: CGRect, outsideAll value: UInt8) throws -> CGImage? {
        guard rect == rect.integral, !rect.isEmpty, rect.minX >= 0, rect.minY >= 0,
              rect.maxX <= CGFloat(image.width), rect.maxY <= CGFloat(image.height), fits(rect) else { return nil }
        let plane = try PSDChannelEncoder.grayPlane(image)
        let inside = (x: Int(rect.minX) ..< Int(rect.maxX), y: Int(rect.minY) ..< Int(rect.maxY))
        for y in 0 ..< image.height {
            for x in 0 ..< image.width where plane[y * image.width + x] != value && !(inside.x.contains(x) && inside.y.contains(y)) {
                return nil
            }
        }
        return image.cropping(to: rect)
    }

    /// Whether every pixel of `image` is opaque.
    static func isOpaque(_ image: CGImage) throws -> Bool {
        if [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) { return true }
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { throw PSDWriteError.render }
        for y in 0 ..< image.height {
            let row = pixels + y * context.bytesPerRow
            for x in 0 ..< image.width where row[x * 4 + 3] != 255 { return false }
        }
        return true
    }

    /// The whole-pixel box around `transform`'s corners; past a record's limits, only its part on the canvas.
    /// Nil when nothing is left.
    static func box(around transform: LayerTransform, canvas: CGRect) -> (rect: CGRect, clipped: Bool)? {
        let corners = DistortWarp.corners(of: transform)
        guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let minX = corners.map(\.x).min(), let maxX = corners.map(\.x).max(),
              let minY = corners.map(\.y).min(), let maxY = corners.map(\.y).max() else { return nil }
        var rect = CGRect(x: minX.rounded(.down), y: minY.rounded(.down), width: 0, height: 0)
        rect.size = CGSize(width: maxX.rounded(.up) - rect.minX, height: maxY.rounded(.up) - rect.minY)
        var clipped = false
        if !fits(rect) {
            rect = rect.intersection(canvas)
            clipped = true
        }
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        return (rect, clipped)
    }

    private static func fits(_ rect: CGRect) -> Bool {
        rect.width <= maximumSide && rect.height <= maximumSide && rect.width * rect.height <= maximumArea
    }
}
