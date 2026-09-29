import CoreGraphics

/// Where an image actually has pixels.
nonisolated enum ContentBounds {
    /// The smallest rectangle, in the image's pixel grid (top-left origin), holding every pixel whose alpha is not
    /// zero; nil when the image is entirely transparent. Found by the same scan `PixelFilter.trimmed` crops with.
    static func pixelBounds(of image: CGImage) throws -> CGRect? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: full, mask: false, context: context)
        guard let data = context.data else { throw ExportError.render }
        var edges = [Int](repeating: 0, count: 4)
        brush_alpha_bounds(data.assumingMemoryBound(to: UInt8.self), width, height, context.bytesPerRow, &edges)
        guard edges[2] > edges[0], edges[3] > edges[1] else { return nil }
        return CGRect(x: edges[0], y: edges[1], width: edges[2] - edges[0], height: edges[3] - edges[1])
    }
}
