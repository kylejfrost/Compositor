import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated extension SmartObjectContents {
    /// These contents center-cropped to the proportions of a frame `frame` document pixels wide and tall, so that
    /// stretched over it they fill it exactly. Filling a smart object's frame must not grow the layer past it: the
    /// spill would show, and would move a layer whose position is locked.
    ///
    /// The crop becomes the contents, as an image kept losslessly: a PNG or TIFF stays one, and anything else becomes
    /// a PNG named for the file with a `.png` extension. Bitmaps and Photoshop documents are cropped at their own
    /// pixels; vector contents are drawn at a pixel a point, or as finely as the frame shows them when that is finer.
    /// Contents already of the frame's proportions, to the pixel, come back as they are. Runs off the caller's actor.
    @concurrent
    func cropped(toFill frame: CGSize) async throws -> SmartObjectContents {
        guard [frame.width, frame.height, size.width, size.height].allSatisfy({ $0.isFinite && $0 > 0 }) else { return self }
        let aspect = frame.width / frame.height
        let (whole, scale) = drawnSize(toFill: frame)
        guard Self.centerCrop(of: whole, aspect: aspect).size != whole else { return self }

        let image = kind == .bitmap
            ? try SmartObjectRasterizer.upright(payload.data, maxPixelSize: Int(max(whole.width, whole.height)))
            : try await SmartObjectRasterizer.rasterize(payload.data, kind: kind, pixelSize: whole, page: 1)
        guard let crop = image.cropping(to: Self.centerCrop(of: CGSize(width: image.width, height: image.height), aspect: aspect))
        else { throw ExportError.render }
        let resolution = scale == 1 ? self.resolution : (self.resolution ?? 72) * scale

        let keepsFormat = fileType == "png " || fileType == "TIFF"
        let type: UTType = fileType == "TIFF" ? .tiff : .png
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, type.identifier as CFString, 1, nil) else {
            throw ExportError.render
        }
        var properties: [CFString: Any] = [:]
        if let resolution {
            properties[kCGImagePropertyDPIWidth] = resolution
            properties[kCGImagePropertyDPIHeight] = resolution
        }
        if type == .tiff { properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] } // LZW
        CGImageDestinationAddImage(destination, crop, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.render }
        // Contents a project couldn't save.
        guard encoded.length <= SmartObjectFileRecord.maximumBytes else { throw ImageImportError.tooLarge }
        let data = encoded as Data
        return SmartObjectContents(payload: SmartObjectPayload(data: data), kind: .bitmap,
                                   fileType: SmartObjectRasterizer.fileType(kind: .bitmap, data: data),
                                   fileName: keepsFormat ? fileName : (fileName as NSString).deletingPathExtension + ".png",
                                   size: CGSize(width: crop.width, height: crop.height), resolution: resolution)
    }

    /// The whole pixels these contents are drawn at before `cropped(toFill:)` crops them, and the scale from their own
    /// size: their size for a bitmap, and for vector contents as finely as `frame` shows them. Drawn whole, so within
    /// what one image can be (`DocumentLimits`): 30,000 pixels a side and one surface's pixels, rounded down so that
    /// rounding never takes the drawing past either.
    func drawnSize(toFill frame: CGSize) -> (size: CGSize, scale: CGFloat) {
        var scale: CGFloat = kind == .svg || kind == .pdf ? max(1, frame.width / size.width, frame.height / size.height) : 1
        scale = min(scale, DocumentLimits.maxSideExtent / size.width, DocumentLimits.maxSideExtent / size.height,
                    (DocumentLimits.maxSurfaceExtent / (size.width * size.height)).squareRoot())
        let whole = CGSize(width: max(1, (size.width * scale).rounded(.down)), height: max(1, (size.height * scale).rounded(.down)))
        return (whole, scale)
    }

    /// The largest rectangle of `aspect` (width over height) in the middle of `size`, on whole pixels.
    private static func centerCrop(of size: CGSize, aspect: CGFloat) -> CGRect {
        var crop = size
        if size.width / size.height > aspect {
            crop.width = min(size.width, max(1, (size.height * aspect).rounded()))
        } else {
            crop.height = min(size.height, max(1, (size.width / aspect).rounded()))
        }
        return CGRect(x: ((size.width - crop.width) / 2).rounded(.down), y: ((size.height - crop.height) / 2).rounded(.down),
                      width: crop.width, height: crop.height)
    }
}
