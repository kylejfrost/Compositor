import CoreGraphics
import CryptoKit
import Foundation

// A Photoshop smart object: contents kept whole (a PNG, a PDF, an embedded Photoshop document…) and placed on the
// layer through a quad, while the layer shows pixels drawn from them. Compositor never re-renders untouched contents:
// an imported smart object keeps showing Photoshop's own pixels until its contents are replaced.

/// Where a smart object's contents are placed: the corners of the placed rectangle, top-left, top-right,
/// bottom-right and bottom-left. A layer keeps them in its transform's unit coordinates (fractions of the layer's own
/// pixels, as `LayerTransform.unit(of:)` gives them), so every move, scale, rotation, flip, Canvas Size and Crop of
/// the layer carries the quad with it; Image Size, which redraws a layer upright on a new pixel grid, re-expresses it
/// on that grid (`carried(from:by:to:)`). The corners in document pixels are derived when needed. The quad is
/// independent of the raster: Photoshop trims transparent margins from the pixels, never from the placement.
nonisolated struct PlacementQuad: Codable, Equatable, Sendable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    /// Top-left, top-right, bottom-right, bottom-left.
    var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    /// The whole of the layer's own pixels.
    static let unitSquare = PlacementQuad(topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: 1, y: 0),
                                          bottomRight: CGPoint(x: 1, y: 1), bottomLeft: CGPoint(x: 0, y: 1))

    /// This quad, in `transform`'s unit coordinates, in document pixels.
    func documentQuad(for transform: LayerTransform) -> PlacementQuad {
        mapped { transform.documentPoint(ofUnit: $0) }
    }

    /// This quad, in document pixels, in `transform`'s unit coordinates: the inverse of `documentQuad(for:)`.
    func unitQuad(in transform: LayerTransform) -> PlacementQuad {
        mapped { transform.unit(of: $0) }
    }

    /// The document rectangle `r` in `transform`'s unit coordinates.
    static func rect(_ r: CGRect, in transform: LayerTransform) -> PlacementQuad {
        PlacementQuad(topLeft: CGPoint(x: r.minX, y: r.minY), topRight: CGPoint(x: r.maxX, y: r.minY),
                      bottomRight: CGPoint(x: r.maxX, y: r.maxY), bottomLeft: CGPoint(x: r.minX, y: r.maxY))
            .unitQuad(in: transform)
    }

    /// Every coordinate finite and within ±10,000,000 (a unit coordinate is a document distance over the layer's
    /// size, which is at least one pixel).
    var isValid: Bool {
        corners.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 10_000_000 && abs($0.y) <= 10_000_000 }
    }

    func mapped(_ transform: (CGPoint) -> CGPoint) -> PlacementQuad {
        PlacementQuad(topLeft: transform(topLeft), topRight: transform(topRight),
                      bottomRight: transform(bottomRight), bottomLeft: transform(bottomLeft))
    }

    /// This quad, in `old`'s unit coordinates, once the document is mapped by `map` and the layer is placed by `new`
    /// instead: in `new`'s unit coordinates. For edits that redraw a layer on a new pixel grid (Image Size draws a
    /// turned or flipped layer upright), where keeping the unit coordinates would move the placement.
    func carried(from old: LayerTransform, by map: CGAffineTransform, to new: LayerTransform) -> PlacementQuad {
        mapped { new.unit(of: old.documentPoint(ofUnit: $0).applying(map)) }
    }
}

/// A linked-layer entry's own fields beyond the contents' identity, name, type and bytes (which `SmartObjectInfo`
/// and `SmartObjectPayload` hold), kept so a writer can emit the entry as it was read. Descriptor fields are their
/// bytes as stored (`u32` version and descriptor).
nonisolated struct LinkedEntryInfo: Codable, Equatable, Sendable {
    /// `liFD` contents in the document, `liFE` a linked file (with a copy of its data), `liFA` an alias (no data).
    var kind: String
    var version: Int
    var creator: String
    var openFileDescriptor: Data?
    /// `liFE`: the linked file's descriptor.
    var externalDescriptor: Data?
    /// `liFE` from version 4: `u32 year`, month, day, hour, minute bytes, `f64` seconds (16 bytes).
    var timestamp: Data?
    var externalFileSize: Int64?
    /// From version 5.
    var childID: String?
    /// From version 6.
    var modTime: Double?
    /// From version 7.
    var lockState: UInt8?
    /// How many NULs ended the stored file name (which `SmartObjectInfo.fileName` holds without them). Nil for
    /// Photoshop's usual one.
    var fileNameNULCount: Int?
    /// Bytes after the fields the entry's version defines, verbatim (up to 64 KiB). Nil when there were none.
    var trailingBytes: Data?

    static let kinds: Set<String> = ["liFD", "liFE", "liFA"]
    static let maximumDescriptorBytes = 65_536

    var isValid: Bool {
        Self.kinds.contains(kind) && (1...8).contains(version)
            && (creator.isEmpty || PSDBlockFile.isFourCharacterCode(creator))
            && [openFileDescriptor, externalDescriptor, trailingBytes].allSatisfy { ($0?.count ?? 0) <= Self.maximumDescriptorBytes }
            && (fileNameNULCount.map { (0...1_024).contains($0) } ?? true)
            && (timestamp.map { $0.count == 16 } ?? true)
            && (externalFileSize.map { $0 >= 0 } ?? true)
            && (childID?.utf8.count ?? 0) <= 4_096
            && (modTime?.isFinite ?? true)
    }
}

/// A smart object's settings: Photoshop's placed-layer descriptor (`SoLd`) and its linked-layer entry, less the
/// contents themselves.
nonisolated struct SmartObjectInfo: Codable, Equatable, Sendable {
    /// `Idnt`: the linked-layer entry holding the contents. Duplicates of one smart object share it.
    var uniqueID: String
    /// `placed`: this placement's own ID.
    var placedID: String
    /// The contents' four-character type: `"8BPB"`, `"png "`, `"SVG "`, `"JPEG"`, `"EPSF"`, `"8BPS"`, `"PDF "`…
    /// Empty when the file doesn't say (its entry is missing).
    var fileType: String
    var fileName: String
    /// `Sz  `: the contents' own size (pixels, or points for vector contents).
    var naturalSize: CGSize
    /// `Rslt`: the contents' resolution, pixels per inch.
    var resolution: Double
    /// Where the contents are placed, in the layer transform's unit coordinates (`Trnf`).
    var quad: PlacementQuad
    /// `nonAffineTransform`, when it differs from `quad` (a perspective or distortion), also in unit coordinates.
    var nonAffineQuad: PlacementQuad?
    /// `Type`: 1 vector, 2 raster (0 unknown, 3 image stack).
    var placedType: Int
    var pageNumber = 1, pageCount = 1, antiAlias = 16, crop = 1
    /// The linked-layer entry's other fields, as read. Nil for contents Compositor placed or replaced.
    var link: LinkedEntryInfo?
    /// 0 as imported; each replacement of the contents adds one, so a writer knows the contents changed.
    var contentsRevision = 0
    /// Whether the document holds the contents (`liFD`, or contents Compositor placed), rather than naming a file.
    var isEmbedded: Bool

    /// The extension the contents are saved under: from the file type, else the file name's own, else `bin`.
    var fileExtension: String {
        switch fileType {
        case "png ", "PNGf": return "png"
        case "JPEG": return "jpg"
        case "TIFF": return "tif"
        case "GIFf": return "gif"
        case "SVG ": return "svg"
        case "PDF ": return "pdf"
        case "EPSF": return "eps"
        case "8BPS": return "psd"
        case "8BPB": return "psb"
        default:
            let own = (fileName as NSString).pathExtension.lowercased()
            return Self.isSafeExtension(own) ? own : "bin"
        }
    }

    /// One to eight lowercase ASCII letters and digits.
    static func isSafeExtension(_ string: String) -> Bool {
        (1...8).contains(string.utf8.count) && string.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) }
    }

    var isValid: Bool {
        let int32 = Int(Int32.min)...Int(Int32.max)
        return uniqueID.utf8.count <= 1_024 && placedID.utf8.count <= 1_024 && fileName.utf8.count <= 4_096
            && (fileType.isEmpty || PSDBlockFile.isFourCharacterCode(fileType))
            && [naturalSize.width, naturalSize.height].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 10_000_000 }
            && resolution.isFinite && resolution > 0 && resolution <= 1_000_000
            && quad.isValid && (nonAffineQuad?.isValid ?? true)
            && [placedType, pageNumber, pageCount, antiAlias, crop].allSatisfy(int32.contains)
            && contentsRevision >= 0 && (link?.isValid ?? true)
    }
}

/// A smart object's contents: the file's bytes, never copied once read (slices of what was read, or a mapped file),
/// and their SHA-256. Shared by reference: duplicated smart objects, undo history and copies hold the same payload.
nonisolated final class SmartObjectPayload: @unchecked Sendable {
    let data: Data
    /// Lowercase hex.
    let sha256: String

    init(data: Data) {
        self.data = data
        sha256 = Self.digest(data)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A layer's smart object: its settings and, when the document holds them, its contents.
nonisolated struct LayerSmartObject: Equatable, @unchecked Sendable {
    var info: SmartObjectInfo
    let payload: SmartObjectPayload?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.info == rhs.info && lhs.payload === rhs.payload
    }
}
