import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum SmartObjectError: LocalizedError, Equatable {
    case largeDocument, unsupported, unreadable, notSmartObject, noDocument, changed, busy, invalidPlacement
    var errorDescription: String? {
        switch self {
        case .largeDocument: "Large Document (.psb) contents can’t be drawn. The smart object keeps its pixels."
        case .unsupported: "Compositor can’t draw these contents. Use a PNG, JPEG, TIFF, SVG, PDF or Photoshop (PSD) file."
        case .unreadable: "The smart object’s contents couldn’t be read. They may be damaged."
        case .notSmartObject: "That layer isn’t a smart object."
        case .noDocument: "Open or create a document to place the file in."
        case .changed: "The document changed while the contents were being drawn, so nothing was changed. Try again."
        case .busy: "Finish or cancel the current edit, then try again."
        case .invalidPlacement: "The contents can’t be placed that far outside the canvas."
        }
    }
}

/// Draws smart-object contents at the pixel size a layer needs: bitmaps through ImageIO, SVG through AppKit's
/// `NSImage`, PDF pages through Core Graphics, and Photoshop documents through `PSDReader` and the exporter's
/// compositing. Large Document (PSB) contents — Photoshop's own embedded smart objects — are never parsed: they keep
/// the pixels Photoshop saved. EPS is recognized but not drawn, as macOS 14 and later have no PostScript interpreter
/// (`NSEPSImageRep` can no longer be created).
nonisolated enum SmartObjectRasterizer {
    enum Kind: Equatable, Sendable { case bitmap, svg, pdf, eps, psd, psb, unknown }

    /// What the contents are: by Photoshop's file type, else by their first bytes, else by the file name's extension.
    static func kind(fileType: String, fileName: String, data: Data) -> Kind {
        switch fileType {
        case "8BPB": return .psb
        case "8BPS": return .psd
        case "SVG ": return .svg
        case "PDF ": return .pdf
        case "EPSF": return .eps
        case "png ", "PNGf", "JPEG", "TIFF", "GIFf": return .bitmap
        default: break
        }
        let head = Array(data.prefix(6))
        if head.starts(with: Array("8BPS".utf8)), head.count == 6 { return head[5] == 2 ? .psb : .psd }
        if head.starts(with: Array("%PDF".utf8)) { return .pdf }
        if head.starts(with: Array("%!PS".utf8)) || head.starts(with: [0xC5, 0xD0, 0xD3, 0xC6]) { return .eps }
        let text = String(decoding: data.prefix(4_096), as: UTF8.self)
        if text.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" }).hasPrefix("<"), text.contains("<svg") { return .svg }
        if let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
           let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }), type.conforms(to: .image) {
            return .bitmap
        }
        switch (fileName as NSString).pathExtension.lowercased() {
        case "psd": return .psd
        case "psb": return .psb
        case "pdf", "ai": return .pdf
        case "svg": return .svg
        case "eps": return .eps
        case "png", "jpg", "jpeg", "tif", "tiff", "gif", "heic", "webp", "bmp": return .bitmap
        default: return .unknown
        }
    }

    /// Photoshop's four-character file type for contents of `kind`; empty for a bitmap it has no code for.
    static func fileType(kind: Kind, data: Data) -> String {
        switch kind {
        case .svg: return "SVG "
        case .pdf: return "PDF "
        case .eps: return "EPSF"
        case .psd: return "8BPS"
        case .psb: return "8BPB"
        case .unknown: return ""
        case .bitmap:
            let type = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) }.flatMap { UTType($0 as String) }
            switch type {
            case .png?: return "png "
            case .jpeg?: return "JPEG"
            case .tiff?: return "TIFF"
            case .gif?: return "GIFf"
            default: return ""
            }
        }
    }

    /// The contents' own size — pixels for bitmaps and Photoshop documents, points for vector contents — and their
    /// resolution in pixels per inch when they say (vector contents are 72 points to the inch, and say nothing).
    /// `page` counts from 1 and matters only for PDF.
    static func naturalSize(_ data: Data, kind: Kind, page: Int) throws -> (size: CGSize, resolution: Double?) {
        switch kind {
        case .bitmap:
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0 else { throw SmartObjectError.unreadable }
            // Orientations 5–8 turn the picture a quarter, which swaps its sides.
            let turned = ((properties[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
            let dpi = (properties[kCGImagePropertyDPIWidth] as? Double).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            return (turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height), dpi)
        case .svg:
            guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
                throw SmartObjectError.unreadable
            }
            return (image.size, nil)
        case .pdf:
            let page = try pdfPage(data, page)
            return (pageSize(page), nil)
        case .psd:
            return try photoshopHeader(data)
        case .psb:
            throw SmartObjectError.largeDocument
        case .eps, .unknown:
            throw SmartObjectError.unsupported
        }
    }

    /// The contents drawn at `pixelSize` (rounded to whole pixels), stretched to fill it. Runs off the caller's actor.
    @concurrent
    static func rasterize(_ data: Data, kind: Kind, pixelSize: CGSize, page: Int) async throws -> CGImage {
        guard pixelSize.width.isFinite, pixelSize.height.isFinite else { throw ImageImportError.tooLarge }
        let width = max(1, Int(pixelSize.width.rounded())), height = max(1, Int(pixelSize.height.rounded()))
        guard width <= DocumentLimits.maxSide, height <= DocumentLimits.maxSide, width * height <= DocumentLimits.maxSurfacePixels else {
            throw ImageImportError.tooLarge
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw ExportError.render }
        context.interpolationQuality = .high
        switch kind {
        case .bitmap:
            // Decoded no larger than needed.
            context.draw(try upright(data, maxPixelSize: max(width, height)), in: bounds)
        case .svg:
            guard let image = NSImage(data: data) else { throw SmartObjectError.unreadable }
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        case .pdf:
            let page = try pdfPage(data, page)
            let size = pageSize(page)
            let box = page.getBoxRect(.cropBox)
            // The page, turned as it is shown (`/Rotate` is clockwise), stretched over the pixels.
            context.translateBy(x: bounds.midX, y: bounds.midY)
            context.scaleBy(x: bounds.width / size.width, y: bounds.height / size.height)
            context.rotate(by: -CGFloat(page.rotationAngle) * .pi / 180)
            context.translateBy(x: -box.midX, y: -box.midY)
            context.clip(to: box)
            context.drawPDFPage(page)
        case .psd:
            let document = try PSDReader.read(data)
            // The layers' assets are taken here, off the main actor; the snapshot is only composited, so they need
            // no thumbnails.
            let assets = try PSDDocumentBuilder.assets(from: document, thumbnails: false)
            let snapshot = try await MainActor.run { try snapshot(of: document, assets: assets) }
            context.draw(try await ImageExporter.shared.render(snapshot).image, in: bounds)
        case .psb:
            throw SmartObjectError.largeDocument
        case .eps, .unknown:
            throw SmartObjectError.unsupported
        }
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }

    /// A bitmap turned upright by its orientation, its longer side at most `maxPixelSize` pixels, in its own color
    /// space and depth.
    static func upright(_ data: Data, maxPixelSize: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary) else { throw SmartObjectError.unreadable }
        return image
    }

    // MARK: Helpers

    private static func pdfPage(_ data: Data, _ number: Int) throws -> CGPDFPage {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: number) else { throw SmartObjectError.unreadable }
        return page
    }

    /// The page's crop box as it is shown: a quarter turn swaps its sides.
    private static func pageSize(_ page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox).size
        return page.rotationAngle % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
    }

    /// A Photoshop document's size from its header and its resolution from resource 1005, without decoding it.
    private static func photoshopHeader(_ data: Data) throws -> (size: CGSize, resolution: Double?) {
        func u32(_ at: Int) -> Int {
            let i = data.startIndex + at
            return Int(data[i]) << 24 | Int(data[i + 1]) << 16 | Int(data[i + 2]) << 8 | Int(data[i + 3])
        }
        guard data.count >= 30, data.prefix(4).elementsEqual("8BPS".utf8), u32(4) >> 16 == 1 else {
            throw SmartObjectError.unreadable
        }
        let height = u32(14), width = u32(18)
        guard width > 0, height > 0 else { throw SmartObjectError.unreadable }
        let resourcesAt = 26 + 4 + u32(26)
        var resolution: Double?
        if resourcesAt + 4 <= data.count {
            let start = resourcesAt + 4
            let resources = PSDBlockFile.scanResources(data, from: start, to: min(data.count, start + u32(resourcesAt)))
            if let info = resources.last(where: { $0.id == 1005 }), info.data.count >= 4 {
                let fixed = Double(UInt32(info.data[info.data.startIndex]) << 24 | UInt32(info.data[info.data.startIndex + 1]) << 16
                    | UInt32(info.data[info.data.startIndex + 2]) << 8 | UInt32(info.data[info.data.startIndex + 3])) / 65536
                resolution = fixed.isFinite && fixed >= 1 ? fixed : nil
            }
        }
        return (CGSize(width: width, height: height), resolution)
    }

    /// A Photoshop document as a project snapshot, for the exporter to composite, its layers' pixels the `assets`
    /// taken off the main actor (`PSDDocumentBuilder.assets(from:thumbnails:)`).
    @MainActor
    static func snapshot(of document: PSDDocument, assets: [UUID: ImportedImage]) throws -> ProjectSnapshot {
        let imported = try PSDDocumentBuilder.makeImport(document, assets: assets)
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        for layer in imported.layers {
            images[layer.id] = layer.asset
            masks[layer.id] = layer.mask?.asset
        }
        let manifest = ProjectManifest(documentID: UUID(), width: imported.width, height: imported.height, activeLayerID: nil,
                                       layers: imported.layers.map(ProjectLayerRecord.init(layer:)))
        return ProjectSnapshot(manifest: manifest, images: images, masks: masks)
    }
}
