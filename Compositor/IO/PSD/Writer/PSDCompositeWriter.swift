import CoreGraphics
import Foundation

/// The merged image at the end of a PSD: the document as `ImageExporter` renders it (layer effects included, which
/// the layer records leave to Photoshop's `lfx2`), stored as PackBits rows, all row counts first.
nonisolated enum PSDCompositeWriter {
    struct Composite {
        let width: Int
        let height: Int
        /// Red, green and blue, then alpha only where some pixel isn't opaque; top row first. Color is stored over
        /// white where the image is transparent, as Photoshop stores its merged image (psd-tools removes the white
        /// the same way).
        let planes: [[UInt8]]
        var hasTransparency: Bool { planes.count == 4 }

        /// The same image with its transparency channel, fully opaque where it had none.
        func withTransparency() -> Composite {
            hasTransparency ? self : Composite(width: width, height: height,
                                               planes: planes + [[UInt8](repeating: 255, count: width * height)])
        }
    }

    static func render(_ snapshot: ProjectSnapshot) throws -> Composite {
        let raster: ExportRaster
        do {
            raster = try ImageExporter.composite(snapshot)
        } catch ExportError.tooLarge {
            throw PSDWriteError.tooLarge
        } catch {
            throw PSDWriteError.render
        }
        return try planes(of: raster.image)
    }

    static func planes(of image: CGImage) throws -> Composite {
        let width = image.width, height = image.height, count = width * height
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { throw PSDWriteError.render }
        let stride = context.bytesPerRow
        var red = [UInt8](repeating: 0, count: count), green = red, blue = red, alpha = red
        var opaque = true
        for y in 0 ..< height {
            let row = pixels + y * stride
            for x in 0 ..< width {
                let i = y * width + x, a = row[x * 4 + 3]
                // Premultiplied color plus the white showing through what isn't covered.
                let white = 255 - Int(a)
                red[i] = UInt8(min(255, Int(row[x * 4]) + white))
                green[i] = UInt8(min(255, Int(row[x * 4 + 1]) + white))
                blue[i] = UInt8(min(255, Int(row[x * 4 + 2]) + white))
                alpha[i] = a
                if a != 255 { opaque = false }
            }
        }
        return Composite(width: width, height: height, planes: opaque ? [red, green, blue] : [red, green, blue, alpha])
    }

    /// Compression 1, every channel's row byte counts, then every channel's rows.
    static func write(_ composite: Composite, into writer: inout PSDByteWriter) {
        let width = composite.width, height = composite.height
        writer.u16(1)
        let countsOffset = writer.count
        writer.bytes(Data(count: composite.planes.count * height * 2))
        var counts = Data(capacity: composite.planes.count * height * 2)
        for plane in composite.planes {
            for row in 0 ..< height {
                let packed = PSDChannelEncoder.packBits(Array(plane[row * width ..< (row + 1) * width]))
                counts.append(UInt8(truncatingIfNeeded: packed.count >> 8))
                counts.append(UInt8(truncatingIfNeeded: packed.count))
                writer.bytes(Data(packed))
            }
        }
        writer.patch(counts, at: countsOffset)
    }
}
