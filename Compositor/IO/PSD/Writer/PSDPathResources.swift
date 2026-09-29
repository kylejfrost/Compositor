import CoreGraphics
import Foundation

/// Photoshop's saved paths (image resources 2000–2997 and the work path, 1025) placed on a document whose canvas was
/// cropped, extended, resized or flipped since the file was read (Adobe's *Photoshop File Formats Specification*, "Path
/// resource format"). Original implementation.
///
/// A path resource is a run of 26-byte records: a `u16` selector, then 24 bytes. Knot records (1, 2, 4, 5) hold three
/// points (the control point before the anchor, the anchor, the one after it), each `y` then `x` as signed 8.24
/// fractions of the canvas height and width; the clipboard record (7) holds the path's bounds (top, left, bottom,
/// right) as the same fractions, then the resolution. The others (subpath lengths, fill rules) hold no position.
nonisolated enum PSDPathResources {
    /// The image resources that are paths, their points fractions of the canvas.
    static func isPath(_ id: UInt16) -> Bool { (2000...2997).contains(id) || id == 1025 }

    /// `data`, a path on a canvas `from` in size whose pixels `transform` took to a canvas `to` in size, with every
    /// point placed there. Nil when it isn't whole records.
    static func placed(_ data: Data, from: CGSize, through transform: CGAffineTransform, onto to: CGSize) -> Data? {
        guard data.count % 26 == 0, from.width > 0, from.height > 0, to.width > 0, to.height > 0 else { return nil }
        var bytes = [UInt8](data)
        func fraction(_ at: Int) -> CGFloat {
            CGFloat(Int32(bitPattern: bytes[at ..< at + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })) / 0x1000000
        }
        func store(_ value: CGFloat, at: Int) {
            let scaled = (value * 0x1000000).rounded()
            let raw = UInt32(bitPattern: Int32(min(CGFloat(Int32.max), max(CGFloat(Int32.min), scaled.isFinite ? scaled : 0))))
            for index in 0 ..< 4 { bytes[at + index] = UInt8(truncatingIfNeeded: raw >> (24 - 8 * index)) }
        }
        /// The point whose `y` is at `at` (its `x` after it), moved.
        func moved(_ at: Int) -> CGPoint {
            CGPoint(x: fraction(at + 4) * from.width, y: fraction(at) * from.height).applying(transform)
        }
        for start in stride(from: 0, to: bytes.count, by: 26) {
            switch Int(bytes[start]) << 8 | Int(bytes[start + 1]) {
            case 1, 2, 4, 5:
                for point in 0 ..< 3 {
                    let at = start + 2 + point * 8, placed = moved(at)
                    store(placed.y / to.height, at: at)
                    store(placed.x / to.width, at: at + 4)
                }
            case 7:
                // Top-left (top +2, left +6) and bottom-right (bottom +10, right +14); the resolution (+18) stays.
                let corners = [moved(start + 2), moved(start + 10)]
                store((corners.map(\.y).min() ?? 0) / to.height, at: start + 2)
                store((corners.map(\.x).min() ?? 0) / to.width, at: start + 6)
                store((corners.map(\.y).max() ?? 0) / to.height, at: start + 10)
                store((corners.map(\.x).max() ?? 0) / to.width, at: start + 14)
            default:
                break
            }
        }
        return Data(bytes)
    }
}
