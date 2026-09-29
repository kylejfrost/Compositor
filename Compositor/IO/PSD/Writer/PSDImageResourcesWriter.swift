import CoreGraphics
import Foundation

/// The image resources section: the file's own resources in their original order, with the ones the writer derives
/// from the document regenerated where the file had them, the thumbnails left out, and derived resources the file
/// lacked placed where Photoshop writes them. The XMP packet (1060) loses Photoshop's `photoshop:TextLayers` (each type
/// layer's name and text as the file had them) once they no longer hold.
nonisolated enum PSDImageResourcesWriter {
    /// Resolution (1005), target layer (1024), layer group info (1026), grid and guides (1032), version info (1057),
    /// layer selection IDs (1069) and layer groups enabled (1072).
    static let modeledIDs: Set<UInt16> = [1005, 1024, 1026, 1032, 1057, 1069, 1072]
    /// The thumbnails (1036, and Photoshop 4's 1033), which would show the document as the file had it, and what
    /// describes alpha and spot channels, which the file written doesn't have: their names (1006, 1045), identifiers
    /// (1053), display information (1007, 1077), alternate spot colors (1067) and the Quick Mask channel (1022).
    static let droppedIDs: Set<UInt16> = [1033, 1036, 1006, 1007, 1022, 1045, 1053, 1067, 1077]
    /// The order Photoshop 2026 writes its resources in.
    static let photoshopOrder: [UInt16] = [1061, 1060, 1082, 1083, 1005, 1062, 1037, 1049, 1011, 10000, 1013, 1016,
                                           1024, 1026, 1072, 1069, 1032, 1092, 1097, 1054, 1050, 1064, 1039, 1044,
                                           1036, 1057, 1058]

    /// `target` is the active layer's record index (bottom first, dividers counted) and its Photoshop layer ID.
    /// `keepsTextLayersMetadata` says every type layer is written as the file had it, name and text. `canvas` is where
    /// the file's canvas (its size, then how its pixels map onto the document's) lies on a document of `size`: saved
    /// paths are placed through it, and the slices (pixels on the old canvas) left out, once they differ.
    static func resources(resolution: Double, recordCount: Int, target: (index: Int, layerID: Int32)?,
                          guides: [CanvasGuide], writerName: String, preserved: [PSDImageResource],
                          keepsTextLayersMetadata: Bool = true,
                          canvas: (file: CGSize, transform: CGAffineTransform, size: CGSize)? = nil) -> [PSDImageResource] {
        let moved = canvas.map { !$0.transform.isIdentity || $0.file != $0.size } ?? false
        var modeled: [UInt16: Data] = [1005: resolutionInfo(resolution)]
        if let target {
            modeled[1024] = bytes { $0.u16(UInt16(clamping: target.index)) }
            modeled[1069] = bytes {
                $0.u16(1)
                $0.i32(target.layerID)
            }
        }
        if recordCount > 0 {
            // No linked-layer groups; every record's group enabled.
            modeled[1026] = Data(count: recordCount * 2)
            modeled[1072] = Data(repeating: 1, count: recordCount)
        }
        let fileGuides = preserved.first { $0.id == 1032 }
        if !guides.isEmpty || fileGuides != nil { modeled[1032] = guidesInfo(guides, file: fileGuides?.data) }
        modeled[1057] = bytes {
            $0.u32(1)
            $0.u8(1) // hasRealMergedData
            $0.unicode(writerName, nulTerminated: false)
            $0.unicode("Adobe Photoshop", nulTerminated: false)
            $0.u32(1)
        }

        // The file's own, a regenerated resource taking the place of the file's first copy.
        var resources: [PSDImageResource] = []
        var placed: Set<UInt16> = []
        for resource in preserved where !droppedIDs.contains(resource.id) {
            if moved, let canvas {
                if resource.id == 1050 { continue }
                if PSDPathResources.isPath(resource.id) {
                    // A path that can't be read can't be placed: left out.
                    if let path = PSDPathResources.placed(resource.data, from: canvas.file, through: canvas.transform,
                                                          onto: canvas.size) {
                        resources.append(PSDImageResource(id: resource.id, name: resource.name, data: path,
                                                          signature: resource.signature))
                    }
                    continue
                }
            }
            if resource.id == 1060, !keepsTextLayersMetadata {
                // A packet that isn’t UTF-8 can’t be cleaned of that text: left out.
                if let xmp = withoutTextLayers(resource.data) {
                    resources.append(PSDImageResource(id: 1060, name: resource.name, data: xmp, signature: resource.signature))
                }
                continue
            }
            guard modeledIDs.contains(resource.id) else {
                resources.append(resource)
                continue
            }
            if placed.insert(resource.id).inserted, let data = modeled[resource.id] {
                resources.append(PSDImageResource(id: resource.id, name: "", data: data))
            }
        }
        // The rest before the first resource Photoshop writes after them.
        func rank(_ id: UInt16) -> Int? { photoshopOrder.firstIndex(of: id) }
        for id in photoshopOrder where !placed.contains(id) {
            guard let data = modeled[id], let own = rank(id) else { continue }
            let index = resources.firstIndex { rank($0.id).map { $0 > own } ?? false } ?? resources.count
            resources.insert(PSDImageResource(id: id, name: "", data: data), at: index)
        }
        return resources
    }

    /// The XMP packet `xmp` without its `TextLayers` bag (Photoshop's list of each type layer's name and text), in
    /// whatever prefix it is bound to; the rest as it was. Nil when the packet isn't UTF-8.
    static func withoutTextLayers(_ xmp: Data) -> Data? {
        guard let text = String(data: xmp, encoding: .utf8),
              let pattern = try? NSRegularExpression(
                pattern: #"[ \t]*<([A-Za-z_][\w.-]*):TextLayers\b[^>]*?(?:/>|>.*?</\1:TextLayers\s*>)[ \t]*\r?\n?"#,
                options: [.dotMatchesLineSeparators]) else { return nil }
        let stripped = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        return Data(stripped.utf8)
    }

    /// `u32` length, then the resources.
    static func write(_ resources: [PSDImageResource], into writer: inout PSDByteWriter) {
        let encoded = PSDBlockFile.encode(resources)
        writer.u32(UInt32(truncatingIfNeeded: encoded.count))
        writer.bytes(encoded)
    }

    /// Horizontal and vertical resolution as 16.16 fixed point in pixels per inch, each with inches as its unit.
    private static func resolutionInfo(_ resolution: Double) -> Data {
        let ppi = resolution.isFinite && resolution >= 1 ? min(resolution, 9600) : 72
        let fixed = UInt32((ppi * 65536).rounded())
        return bytes {
            for _ in 0 ..< 2 {
                $0.u32(fixed)
                $0.u16(1)
                $0.u16(1)
            }
        }
    }

    /// Resource 1032: version 1, the grid cycle (the file's, else Photoshop's default of 576 = 18 px in 1/32 px),
    /// then each guide as its position in 1/32 px and its direction, 0 vertical and 1 horizontal. Guides the reader
    /// would drop (beyond ±1,000,000 px) are left out.
    private static func guidesInfo(_ guides: [CanvasGuide], file: Data?) -> Data {
        let grid = file.flatMap { $0.count >= 12 && $0.prefix(4) == Data([0, 0, 0, 1]) ? Data($0.dropFirst(4).prefix(8)) : nil }
        let kept = guides.filter { $0.position > -1_000_000 && $0.position < 1_000_000 }
        return bytes {
            $0.u32(1)
            if let grid {
                $0.bytes(grid)
            } else {
                $0.u32(576)
                $0.u32(576)
            }
            $0.u32(UInt32(kept.count))
            for guide in kept {
                $0.i32(Int32((guide.position * 32).rounded()))
                $0.u8(guide.axis == .horizontal ? 1 : 0)
            }
        }
    }

    private static func bytes(_ write: (inout PSDByteWriter) -> Void) -> Data {
        var writer = PSDByteWriter()
        write(&writer)
        return writer.data
    }
}
