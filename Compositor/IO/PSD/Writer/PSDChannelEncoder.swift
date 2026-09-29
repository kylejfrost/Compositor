import CoreGraphics
import Foundation

/// Packs 8-bit planes into Photoshop channel image data (Adobe's *Photoshop File Formats Specification*,
/// compression 1: PackBits per row after a big-endian `u16` byte count per row). The inverse of
/// `PSDChannelCoder`.
nonisolated enum PSDChannelEncoder {
    /// PackBits (Apple TN1023): a run of 2–128 equal bytes as header `1 - n` and the byte; 1–128 other bytes
    /// as header `n - 1` and the bytes.
    static func packBits(_ row: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(row.count + row.count / 128 + 1)
        var i = 0
        while i < row.count {
            if i + 1 < row.count, row[i] == row[i + 1] {
                var run = 2
                while i + run < row.count, row[i + run] == row[i], run < 128 { run += 1 }
                output.append(UInt8(bitPattern: Int8(1 - run)))
                output.append(row[i])
                i += run
            } else {
                let start = i
                i += 1
                while i < row.count, i - start < 128 {
                    if i + 1 < row.count, row[i] == row[i + 1] { break }
                    i += 1
                }
                output.append(UInt8(i - start - 1))
                output.append(contentsOf: row[start ..< i])
            }
        }
        return output
    }

    /// `height` row byte counts (`u16`), then the rows PackBits-encoded; `plane` holds `width × height` bytes,
    /// top row first. Empty when either side is zero.
    static func rle(_ plane: [UInt8], width: Int, height: Int) -> Data {
        guard width > 0, height > 0 else { return Data() }
        precondition(plane.count >= width * height, "PSD channel plane smaller than its rect")
        var counts = Data(capacity: height * 2)
        var rows = Data(capacity: plane.count + plane.count / 128 + height)
        for row in 0 ..< height {
            let packed = packBits(Array(plane[row * width ..< (row + 1) * width]))
            counts.append(UInt8(truncatingIfNeeded: packed.count >> 8))
            counts.append(UInt8(truncatingIfNeeded: packed.count))
            rows.append(contentsOf: packed)
        }
        counts.append(rows)
        return counts
    }

    /// Straight (unpremultiplied) sRGB color planes and the alpha plane, top row first: the image drawn
    /// premultiplied, alpha copied out (`layer_extract_alpha`), then color divided by alpha
    /// (`layer_unpremultiply_opaque`). Fully transparent pixels are black.
    static func straightPlanes(_ image: CGImage) throws -> (r: [UInt8], g: [UInt8], b: [UInt8], a: [UInt8]) {
        let width = image.width, height = image.height, count = width * height
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ExportError.render }
        let stride = context.bytesPerRow
        var alpha = [UInt8](repeating: 0, count: count)
        alpha.withUnsafeMutableBufferPointer { layer_extract_alpha(pixels, stride, $0.baseAddress, width, width, height) }
        layer_unpremultiply_opaque(pixels, stride, width, height)
        var red = [UInt8](repeating: 0, count: count)
        var green = [UInt8](repeating: 0, count: count)
        var blue = [UInt8](repeating: 0, count: count)
        for y in 0 ..< height {
            let row = pixels + y * stride
            for x in 0 ..< width {
                let i = y * width + x
                red[i] = row[x * 4]
                green[i] = row[x * 4 + 1]
                blue[i] = row[x * 4 + 2]
            }
        }
        return (red, green, blue, alpha)
    }

    /// A mask's coverage, one gray byte per pixel, top row first.
    static func grayPlane(_ image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: true, context: context)
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ExportError.render }
        let stride = context.bytesPerRow
        var plane = [UInt8](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width { plane[y * width + x] = pixels[y * stride + x] }
        }
        return plane
    }
}
