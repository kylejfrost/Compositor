import CoreGraphics
import Foundation
import ImageIO
import MCP
import UniformTypeIdentifiers

/// Headless rendering for the MCP preview tools: the composite (whole or a region), one layer on its
/// own, downscaling, encoding to PNG/JPEG over a chosen background, and reading pixels back.
///
/// Everything here works on a `ProjectSnapshot` or plain images, never on a live session, so callers
/// run it off the main actor; the composite itself is drawn by the `ImageExporter` actor, exactly as
/// Export draws it.
nonisolated enum MCPRender {
    nonisolated enum Format: String, Sendable, CaseIterable {
        case png, jpeg
        var mimeType: String { self == .png ? "image/png" : "image/jpeg" }
        var fileExtension: String { self == .png ? "png" : "jpg" }
        var type: UTType { self == .png ? .png : .jpeg }
    }

    /// What shows through transparent pixels.
    nonisolated enum Background: String, Sendable, CaseIterable {
        case transparent, white, black, checkerboard
    }

    /// One encoded preview, ready to return.
    nonisolated struct Preview: Sendable {
        let data: Data
        let width: Int
        let height: Int
        /// Preview pixels per document pixel: the factor asked of the longer side.
        let scale: Double
        /// The size of what was rendered, before scaling.
        let sourceWidth: Int
        let sourceHeight: Int
        /// The exact factor on each axis once the size was rounded to whole pixels.
        var scaleX: Double { Double(width) / Double(max(1, sourceWidth)) }
        var scaleY: Double { Double(height) / Double(max(1, sourceHeight)) }
    }

    /// One pixel's unpremultiplied sRGB color, 0–255.
    nonisolated struct Sample: Equatable, Sendable {
        var red: UInt8 = 0, green: UInt8 = 0, blue: UInt8 = 0, alpha: UInt8 = 0
        var hex: String { String(format: "#%02x%02x%02x", red, green, blue) }
    }

    /// Checkerboard squares, in preview pixels.
    static let checkerSize = 8

    // MARK: Compositing

    /// The document's composite, or one layer by itself.
    ///
    /// - `isolating == nil`: the whole composite as Export draws it, cropped to `region` (document pixels,
    ///   whole numbers, inside the canvas) when given.
    /// - `isolating == id`: only that layer and its descendants (see `isolated(_:in:includeEffects:includeMask:)`),
    ///   drawn over `region` — which may reach past the canvas — or, when nil, over the box the layer draws in
    ///   (`drawnBounds`). An adjustment layer, or a folder with nothing to draw, is `unsupported`.
    static func composite(_ snapshot: ProjectSnapshot, region: CGRect?, isolating layer: UUID?,
                          includeEffects: Bool, includeMask: Bool) async throws -> CGImage {
        guard let layer else {
            let image = try await ImageExporter.shared.render(snapshot).image
            guard let region else { return image }
            guard let cropped = image.cropping(to: region) else { throw ExportError.render }
            return cropped
        }
        let records = try isolated(layer, in: snapshot, includeEffects: includeEffects, includeMask: includeMask)
        guard let area = (region ?? drawnBounds(records, images: snapshot.images)).map(pixelAligned),
              area.width >= 1, area.height >= 1 else {
            throw nothingToDraw(snapshot.manifest.layers.first { $0.id == layer }?.name ?? layer.uuidString)
        }
        let offset = CGPoint(x: -area.minX, y: -area.minY)
        let manifest = ProjectManifest(resolution: snapshot.manifest.resolution, documentID: snapshot.manifest.documentID,
                                       width: Int(area.width), height: Int(area.height), activeLayerID: nil,
                                       layers: records.map { $0.translated(by: offset) }, guides: nil)
        let alone = ProjectSnapshot(manifest: manifest, images: snapshot.images, masks: snapshot.masks)
        return try await ImageExporter.shared.render(alone).image
    }

    /// The records drawn when `id` is shown by itself: the layer and its descendants, the layer made a visible
    /// top-level layer with normal blending and no clipping; clipping inside the subtree is kept only where its base
    /// is also in it. `includeEffects`/`includeMask` false drop the layer's own effects or mask (its descendants
    /// keep theirs). Order is the document's.
    static func isolated(_ id: UUID, in snapshot: ProjectSnapshot, includeEffects: Bool, includeMask: Bool) throws -> [ProjectLayerRecord] {
        try isolated(id, in: snapshot.manifest.layers, includeEffects: includeEffects, includeMask: includeMask)
    }

    static func isolated(_ id: UUID, in records: [ProjectLayerRecord], includeEffects: Bool, includeMask: Bool) throws -> [ProjectLayerRecord] {
        guard let root = records.first(where: { $0.id == id }) else {
            throw MCPToolError.notFound("No layer with id \(id.uuidString).")
        }
        if root.adjustment != nil { throw adjustmentUnsupported(root.name) }
        let members = subtree(id, in: records)
        return records.filter { members.contains($0.id) }.map { record in
            var record = record
            if let source = record.maskSourceID, record.id == id || !members.contains(source) { record.maskSourceID = nil }
            guard record.id == id else { return record }
            record.parentID = nil
            record.isVisible = true
            record.blendMode = .normal
            if !includeEffects { record.effects = nil }
            if !includeMask {
                record.maskFile = nil
                record.maskEnabled = nil
                record.maskPlacement = nil
                record.maskLinked = nil
            }
            return record
        }
    }

    /// The upright box, in document pixels, that the visible pixel layers among `records` draw in — each layer's
    /// placement grown by its effects — or nil when none draws anything. Adjustment layers draw no box of their own.
    static func drawnBounds(_ records: [ProjectLayerRecord], images: [UUID: ImportedImage]) -> CGRect? {
        LayerHierarchy.visibleLayers(records).filter { $0.adjustment == nil }.reduce(CGRect?.none) { box, record in
            let drawn = drawnBox(record.transform, image: images[record.id]?.image, effects: record.effects)
            return box.map { $0.union(drawn) } ?? drawn
        }
    }

    /// `rect` rounded out to whole pixels, ignoring the rounding error a turn leaves behind (a corner at
    /// 11.999999999 is 12), so a quarter-turned layer doesn't gain a row of empty pixels.
    static func pixelAligned(_ rect: CGRect) -> CGRect {
        let tolerance: CGFloat = 1e-6
        let minX = (rect.minX + tolerance).rounded(.down), minY = (rect.minY + tolerance).rounded(.down)
        let maxX = (rect.maxX - tolerance).rounded(.up), maxY = (rect.maxY - tolerance).rounded(.up)
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// The upright box a layer placed at `transform` covers once `effects` (drawn around `image`) are added.
    static func drawnBox(_ transform: LayerTransform, image: CGImage?, effects: LayerEffects?) -> CGRect {
        box(of: grown(transform, image: image, effects: effects))
    }

    /// `transform` grown by the margin `effects` need around `image`, as the renderer places the bigger image
    /// (`LayerEffectsRenderer.placed`). Unchanged when there are no visible effects.
    static func grown(_ transform: LayerTransform, image: CGImage?, effects: LayerEffects?) -> LayerTransform {
        guard let image, image.width > 0, image.height > 0,
              let effects = effects?.visible, !effects.isEmpty, effects.isValid else { return transform }
        let inset = LayerEffectsRenderer.margin(for: effects)
        let width = CGFloat(image.width), height = CGFloat(image.height)
        var result = transform
        result.size = CGSize(width: transform.size.width * (width + inset * 2) / width,
                             height: transform.size.height * (height + inset * 2) / height)
        result.origin = CGPoint(x: transform.center.x - result.size.width / 2, y: transform.center.y - result.size.height / 2)
        return result
    }

    /// The four corners of a placement on the document: top-left, top-right, bottom-right, bottom-left of the
    /// unrotated box, turned with it.
    static func corners(of transform: LayerTransform) -> [CGPoint] {
        [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map(transform.point)
    }

    /// The upright box around a placement.
    static func box(of transform: LayerTransform) -> CGRect { box(around: corners(of: transform)) }

    /// The upright box, in document pixels, around a rectangle of a `width` × `height` layer's own pixels.
    static func documentBox(ofPixels rect: CGRect, transform: LayerTransform, width: Int, height: Int) -> CGRect {
        let map = BrushRaster.pixelToDocument(transform, width: width, height: height)
        return box(around: [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)].map { $0.applying(map) })
    }

    private static func box(around points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func subtree(_ id: UUID, in records: [ProjectLayerRecord]) -> Set<UUID> {
        let children = Dictionary(grouping: records, by: \.parentID)
        var result: Set<UUID> = [id], pending = [id]
        while let parent = pending.popLast() {
            for child in children[parent] ?? [] where result.insert(child.id).inserted { pending.append(child.id) }
        }
        return result
    }

    static func adjustmentUnsupported(_ name: String) -> MCPToolError {
        MCPToolError(.unsupported, "'\(name)' is an adjustment layer: it changes the layers below it and has no pixels to show by itself.",
                     hint: "Use render_document or render_region to see its effect.")
    }

    static func nothingToDraw(_ name: String) -> MCPToolError {
        MCPToolError(.unsupported, "'\(name)' has nothing to draw by itself (a folder holding only adjustment layers or hidden layers).",
                            hint: "Use render_document or render_region to see its effect.")
    }

    // MARK: Scaling and encoding

    /// `image` scaled so its longer side is at most `maxSize`, and the scale used (1 when it already fits;
    /// images are never scaled up).
    static func downscaled(_ image: CGImage, maxSize: Int) throws -> (image: CGImage, scale: CGFloat) {
        let longest = max(image.width, image.height)
        guard longest > maxSize, maxSize > 0 else { return (image, 1) }
        let scale = CGFloat(maxSize) / CGFloat(longest)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ExportError.render
        }
        context.interpolationQuality = .high
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw ExportError.render }
        return (scaled, scale)
    }

    /// `image` encoded as `format` over `background`. JPEG has no transparency, so a transparent background
    /// comes out white there. `quality` (0–1) applies to JPEG only; `resolution` (pixels per inch) is written
    /// when given.
    static func encode(_ image: CGImage, format: Format, quality: Double, background: Background,
                       resolution: Double? = nil) throws -> Data {
        let background = format == .jpeg && background == .transparent ? .white : background
        let flat = background == .transparent ? image : try flattened(image, on: background)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else {
            throw ExportError.encode
        }
        var properties: [CFString: Any] = [:]
        if format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = min(1, max(0, quality)) }
        if let resolution {
            properties[kCGImagePropertyDPIWidth] = resolution
            properties[kCGImagePropertyDPIHeight] = resolution
        }
        CGImageDestinationAddImage(destination, flat, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encode }
        return data as Data
    }

    /// An MCP image content block holding `data`.
    static func imageContent(_ data: Data, format: Format) -> Tool.Content {
        .image(data: data.base64EncodedString(), mimeType: format.mimeType, annotations: nil, _meta: nil)
    }

    private static func flattened(_ image: CGImage, on background: Background) throws -> CGImage {
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ExportError.render
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(gray: background == .black ? 0 : 1, alpha: 1)
        context.fill(bounds)
        if background == .checkerboard {
            // Squares counted from the top-left corner, as the image is read.
            context.saveGState()
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(gray: 0.8, alpha: 1)
            let size = checkerSize
            for row in 0..<(height + size - 1) / size {
                for column in 0..<(width + size - 1) / size where (row + column) % 2 == 1 {
                    context.fill(CGRect(x: column * size, y: row * size, width: size, height: size))
                }
            }
            context.restoreGState()
        }
        context.draw(image, in: bounds)
        guard let result = context.makeImage() else { throw ExportError.render }
        return result
    }

    // MARK: Reading pixels

    /// An image's pixels as premultiplied RGBA8, read once so any number of points can be looked up. An image
    /// already in that layout (as the exporter's composite is) is read as it is; anything else is drawn once
    /// into that layout.
    nonisolated struct Pixels {
        let width: Int
        let height: Int
        private let bytes: Data
        private let bytesPerRow: Int

        init(_ image: CGImage) throws {
            width = image.width
            height = image.height
            let alpha = CGImageAlphaInfo(rawValue: image.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
            let order = image.bitmapInfo.intersection(.byteOrderMask)
            if image.bitsPerComponent == 8, image.bitsPerPixel == 32, alpha == .premultipliedLast,
               order == [] || order == .byteOrder32Big, image.colorSpace?.name == CGColorSpace.sRGB,
               let data = image.dataProvider?.data as Data?, data.count >= image.bytesPerRow * height {
                bytes = data
                bytesPerRow = image.bytesPerRow
                return
            }
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw ExportError.render
            }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let data = context.data else { throw ExportError.render }
            bytes = Data(bytes: data, count: context.bytesPerRow * height)
            bytesPerRow = context.bytesPerRow
        }

        /// The pixel at column `x`, row `y` (top-left origin), unpremultiplied; nil outside the image.
        func sample(x: Int, y: Int) -> Sample? {
            guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
            let offset = y * bytesPerRow + x * 4
            let red = bytes[offset], green = bytes[offset + 1], blue = bytes[offset + 2], alpha = Int(bytes[offset + 3])
            guard alpha > 0 else { return Sample() }
            func channel(_ value: UInt8) -> UInt8 { UInt8(min(255, (Int(value) * 255 + alpha / 2) / alpha)) }
            return Sample(red: channel(red), green: channel(green), blue: channel(blue), alpha: UInt8(alpha))
        }
    }

    /// The pixel of a `width` × `height` layer placed at `transform` under the center of document pixel
    /// (`x`, `y`) — the pixel the canvas would show there with nearest sampling — or nil when that point is
    /// off the layer.
    static func layerPixel(x: Int, y: Int, transform: LayerTransform, width: Int, height: Int) -> (x: Int, y: Int)? {
        guard width > 0, height > 0 else { return nil }
        let toLayer = BrushRaster.pixelToDocument(transform, width: width, height: height).inverted()
        let local = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5).applying(toLayer)
        guard local.x.isFinite, local.y.isFinite else { return nil }
        let column = Int(floor(local.x)), row = Int(floor(local.y))
        guard (0..<width).contains(column), (0..<height).contains(row) else { return nil }
        return (column, row)
    }
}
