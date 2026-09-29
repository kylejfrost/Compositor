import CoreGraphics
import Foundation

/// Writes smart objects: each layer's placed-layer blocks (`PlLd`, then `SoLd`, or `SoLE` for a linked file) beside
/// its pixels, and the document's linked-layer entries holding the contents, in one `lnk2` block. Original
/// implementation from Adobe's *Photoshop File Formats Specification* ("Placed Layer", "Placed Layer Data", "Linked
/// Layer"), with psd-tools' `LinkedLayer.read` field order.
///
/// Contents that are still the ones imported (the same `uniqueID` and `contentsRevision`) keep Photoshop's own blocks
/// and entry, byte for byte: only the placement's corners follow the layer (rewritten when they are more than 0.01 px
/// from the file's), and a duplicate gets a placement ID of its own. Contents placed or replaced in Compositor get
/// blocks generated from the smart object and a version 7 `liFD` entry. A layer that is no longer a smart object
/// (rasterized, painted, a clip baked in) is written as pixels, as is one a project saved before smart objects were
/// kept: its pixels may have been painted then.
nonisolated enum PSDSmartObjectWriter {
    /// Every key a layer's placement is stored under.
    static let blockKeys: Set<String> = ["PlLd", "plLd", "SoLd", "SoLE"]

    /// A linked-layer entry as the pieces it is written from, so its contents are never copied.
    struct Entry {
        var parts: [Data]

        var count: Int { parts.reduce(0) { $0 + $1.count } }
        var data: Data { parts.reduce(into: Data()) { $0.append($1) } }
    }

    /// The document's entries as its layers are written: each contents' entry once (duplicates share it), and every
    /// placement ID handed out, so that a duplicate gets its own.
    struct Links {
        private(set) var entries: [Entry] = []
        private var uniqueIDs: Set<String> = []
        private var placedIDs: Set<String> = []

        /// `id`, unless it is empty or another placement has it already; then a new one.
        mutating func claimPlacedID(_ id: String) -> String {
            if !id.isEmpty, placedIDs.insert(id).inserted { return id }
            var fresh = UUID().uuidString.lowercased()
            while !placedIDs.insert(fresh).inserted { fresh = UUID().uuidString.lowercased() }
            return fresh
        }

        /// The entry for `smartObject`'s contents, unless one is in already or the file had none.
        mutating func add(_ smartObject: LayerSmartObject) {
            guard smartObject.payload != nil || smartObject.info.link != nil,
                  uniqueIDs.insert(smartObject.info.uniqueID).inserted else { return }
            entries.append(PSDSmartObjectWriter.entry(smartObject.info, payload: smartObject.payload))
        }
    }

    // MARK: Layers

    /// Adds, rewrites or removes `record`'s placed-layer blocks for `layer`, and adds its contents to `links`. `baked`
    /// says the record's pixels aren't the layer's own (the writer applied a clip to them, and warned): the layer is
    /// written as those pixels, without its contents. Returns a warning when a smart object is written as pixels.
    static func apply(to record: inout PSDLayerRecord, layer: ProjectLayerRecord, sidecar: PSDLayerSidecar,
                      baked: Bool = false, links: inout Links) -> PSDWriteWarning? {
        let imported = sidecar.extras?.importedSmartObject
        if baked, sidecar.smartObject != nil {
            record.blocks.removeAll { blockKeys.contains($0.key) }
            return nil
        }
        guard let smartObject = sidecar.smartObject else {
            // Its pixels are all that's left of a smart object. Placed-layer blocks Compositor couldn't read stay as
            // Photoshop wrote them, their entry among the orphans.
            if let stored = record.blocks.first(where: { PSDSmartObjects.placementKeys.contains($0.key) }),
               imported != nil || (try? PSDSmartObjects.placement(stored.data, in: layer.transform)) != nil {
                record.blocks.removeAll { blockKeys.contains($0.key) }
            }
            return nil
        }
        let info = smartObject.info
        if imported == nil, info.contentsRevision == 0, sidecar.extras?.hasBlock(in: Set(PSDSmartObjects.placementKeys)) == true {
            // A layer import made pixels of before smart objects were kept, and a project then made one again.
            record.blocks.removeAll { blockKeys.contains($0.key) }
            return PSDWriteWarning(layerName: layer.name, message: "It was saved in a project before Compositor kept smart objects and may have been painted since, so it was saved as pixels. Replace its contents to save it as a smart object.")
        }
        let quad = info.quad.documentQuad(for: layer.transform)
        let nonAffine = (info.nonAffineQuad ?? info.quad).documentQuad(for: layer.transform)
        let placedID = links.claimPlacedID(info.placedID)
        links.add(smartObject)
        if let imported, imported.uniqueID == info.uniqueID, imported.contentsRevision == info.contentsRevision,
           let index = record.blocks.firstIndex(where: { PSDSmartObjects.placementKeys.contains($0.key) }),
           let placed = placing(record.blocks[index].data, quad: quad, nonAffine: nonAffine, placedID: placedID) {
            record.blocks[index].data = placed
            if let legacy = record.blocks.firstIndex(where: { $0.key == "PlLd" }),
               let moved = placing(placedLayer: record.blocks[legacy].data, quad: quad) {
                record.blocks[legacy].data = moved
            }
            return nil
        }
        // New or replaced contents (or Photoshop data left out): generated where the file had its placement, else
        // first, as Photoshop puts a layer's content blocks.
        let generated = [
            PSDTaggedBlock(key: "PlLd", data: placedLayerBlock(info, quad: quad)),
            PSDTaggedBlock(key: info.isEmbedded ? "SoLd" : "SoLE",
                           data: placedLayerDataBlock(info, placedID: placedID, quad: quad, nonAffine: nonAffine)),
        ]
        let index = record.blocks.firstIndex { blockKeys.contains($0.key) } ?? 0
        record.blocks.removeAll { blockKeys.contains($0.key) }
        record.blocks.insert(contentsOf: generated, at: min(index, record.blocks.count))
        return nil
    }

    /// A stored `SoLd`/`SoLE` payload placed on `quad` (`Trnf`) and `nonAffine` (`nonAffineTransform`), both in
    /// document pixels, with `placedID`: its own bytes while it says so already (corners within 0.01 px), else its
    /// descriptor written again with only those items changed. Nil when it can't be read.
    static func placing(_ block: Data, quad: PlacementQuad, nonAffine: PlacementQuad, placedID: String) -> Data? {
        let data = Data(block)
        guard data.count >= 8, data.prefix(4) == Data("soLD".utf8) else { return nil }
        var end = 8
        guard var descriptor = try? PSDDescriptorReader.readBlock(data, at: &end) else { return nil }
        var changed = false
        for (key, target) in [("Trnf", quad), ("nonAffineTransform", nonAffine)] {
            guard let index = descriptor.items.firstIndex(where: { $0.key.id == key }) else { continue }
            let stored = numbers(descriptor.items[index].value)
            let wanted = target.corners.flatMap { [Double($0.x), Double($0.y)] }
            if stored.count != 8 || zip(stored, wanted).contains(where: { abs($0 - $1) > 0.01 }) {
                descriptor.items[index].value = .list(wanted.map { .double($0) })
                changed = true
            }
        }
        if let index = descriptor.items.firstIndex(where: { $0.key.id == "placed" }), descriptor.string("placed") != placedID {
            descriptor.items[index].value = .string(placedID)
            changed = true
        }
        guard changed else { return block }
        var result = data.prefix(8) + PSDDescriptorWriter.block(descriptor)
        let rest = data.suffix(from: end)
        if data.count % 4 == 0, rest.count < 4, rest.allSatisfy({ $0 == 0 }) {
            // Photoshop's padding to 4, for the new length.
            result.append(Data(count: (4 - result.count % 4) % 4))
        } else {
            result.append(rest)
        }
        return result
    }

    /// A stored `PlLd` payload with its eight corner numbers set to `quad`'s, when they differ by more than 0.01 px.
    /// Nil when it can't be read.
    static func placing(placedLayer block: Data, quad: PlacementQuad) -> Data? {
        var data = Data(block)
        guard data.count >= 9, data.prefix(4) == Data("plcL".utf8) else { return nil }
        // `plcL`, version, the Pascal uuid, then page, pages, anti-aliasing and type before the corners.
        let start = 8 + 1 + Int(data[8]) + 16
        guard data.count >= start + 64 else { return nil }
        let stored = (0..<8).map { index in
            Double(bitPattern: data[(start + index * 8) ..< (start + index * 8 + 8)].reduce(0) { $0 << 8 | UInt64($1) })
        }
        let wanted = quad.corners.flatMap { [Double($0.x), Double($0.y)] }
        guard zip(stored, wanted).contains(where: { abs($0 - $1) > 0.01 }) else { return block }
        var corners = PSDByteWriter()
        wanted.forEach { corners.f64($0) }
        data.replaceSubrange(start ..< start + 64, with: corners.data)
        return data
    }

    // MARK: Blocks

    /// `SoLd`/`SoLE`: `"soLD"`, version 4, then the placement descriptor, padded to 4.
    static func placedLayerDataBlock(_ info: SmartObjectInfo, placedID: String, quad: PlacementQuad,
                                     nonAffine: PlacementQuad) -> Data {
        func fraction() -> PSDDescriptorValue {
            .object(PSDDescriptor(classID: "null", items: [(key: "numerator", value: .integer(0)),
                                                          (key: "denominator", value: .integer(600))]))
        }
        let descriptor = PSDDescriptor(classID: "null", items: [
            (key: "Idnt", value: .string(info.uniqueID)),
            (key: "placed", value: .string(placedID)),
            (key: "PgNm", value: .integer(int32(info.pageNumber))),
            (key: "totalPages", value: .integer(int32(info.pageCount))),
            (key: "Crop", value: .integer(int32(info.crop))),
            (key: "frameStep", value: fraction()),
            (key: "duration", value: fraction()),
            (key: "frameCount", value: .integer(1)),
            (key: "Annt", value: .integer(int32(info.antiAlias))),
            (key: "Type", value: .integer(int32(info.placedType))),
            (key: "Trnf", value: corners(quad)),
            (key: "nonAffineTransform", value: corners(nonAffine)),
            (key: PSDKey("warp", explicitLength: true), value: .object(warp(info.naturalSize))),
            (key: "Sz  ", value: .object(PSDDescriptor(classID: "Pnt ", items: [
                (key: "Wdth", value: .double(Double(info.naturalSize.width))),
                (key: "Hght", value: .double(Double(info.naturalSize.height))),
            ]))),
            (key: "Rslt", value: .unitFloat(unit: "#Rsl", value: info.resolution)),
        ])
        var writer = PSDByteWriter()
        writer.code("soLD")
        writer.u32(4)
        writer.bytes(PSDDescriptorWriter.block(descriptor))
        writer.pad(to: 4)
        return writer.data
    }

    /// `PlLd`: `"plcL"`, version 3, the contents' uuid, page, pages, anti-aliasing, type, the corners, then the warp
    /// (version 0), padded to 4.
    static func placedLayerBlock(_ info: SmartObjectInfo, quad: PlacementQuad) -> Data {
        var writer = PSDByteWriter()
        writer.code("plcL")
        writer.u32(3)
        writer.pascal(info.uniqueID, pad: 1)
        for value in [info.pageNumber, info.pageCount, info.antiAlias, info.placedType] {
            writer.u32(UInt32(bitPattern: int32(value)))
        }
        for corner in quad.corners {
            writer.f64(Double(corner.x))
            writer.f64(Double(corner.y))
        }
        writer.bytes(PSDDescriptorWriter.block2(warp(info.naturalSize), version: 0))
        writer.pad(to: 4)
        return writer.data
    }

    /// No warp over contents of `size`.
    private static func warp(_ size: CGSize) -> PSDDescriptor {
        PSDDescriptor(classID: PSDKey("warp", explicitLength: true), items: [
            (key: "warpStyle", value: .enumerated(type: "warpStyle", value: "warpNone")),
            (key: "warpValue", value: .double(0)),
            (key: "warpPerspective", value: .double(0)),
            (key: "warpPerspectiveOther", value: .double(0)),
            (key: "warpRotate", value: .enumerated(type: "Ornt", value: "Hrzn")),
            (key: "bounds", value: .object(PSDDescriptor(classID: "classFloatRect", items: [
                (key: "Top ", value: .double(0)),
                (key: "Left", value: .double(0)),
                (key: "Btom", value: .double(Double(size.height))),
                (key: "Rght", value: .double(Double(size.width))),
            ]))),
            (key: "uOrder", value: .integer(4)),
            (key: "vOrder", value: .integer(4)),
        ])
    }

    // MARK: Entries

    /// The linked-layer entry for `info`'s contents: from its `link` (the entry as imported, written back field for
    /// field) or, for contents placed or replaced in Compositor, a version 7 `liFD` entry — `u32` version, the uuid
    /// (Pascal), the file name (Unicode, its NUL counted), type, creator (`8BIM` for Photoshop documents), `u64` size,
    /// no open-file descriptor, the contents, an empty child ID, time 0 and no lock. Version 7 is the newest whose
    /// fields are all known: Photoshop 2026 refuses a file whose version 8 entry has only these fields.
    static func entry(_ info: SmartObjectInfo, payload: SmartObjectPayload?) -> Entry {
        let link = info.link
        let kind = link?.kind ?? "liFD"
        let version = link?.version ?? 7
        let contents = payload?.data ?? Data()
        var head = PSDByteWriter()
        head.code(kind)
        head.u32(UInt32(version))
        head.pascal(info.uniqueID, pad: 1)
        head.unicode(info.fileName + String(repeating: "\0", count: link?.fileNameNULCount ?? 1), nulTerminated: false)
        head.code(info.fileType)
        head.code(link?.creator ?? (["8BPS", "8BPB"].contains(info.fileType) ? "8BIM" : "\0\0\0\0"))
        u64(UInt64(contents.count), into: &head)
        if let open = link?.openFileDescriptor {
            head.u8(1)
            head.bytes(open)
        } else {
            head.u8(0)
        }
        var parts: [Data] = []
        var tail = PSDByteWriter()
        switch kind {
        case "liFE":
            head.bytes(link?.externalDescriptor ?? Data())
            if version > 3 { head.bytes(link?.timestamp ?? Data(count: 16)) }
            u64(UInt64(max(0, link?.externalFileSize ?? 0)), into: &head)
            parts = version > 2 ? [head.data, contents] : [head.data]
        case "liFA":
            head.bytes(Data(count: 8))
            parts = [head.data]
        default:
            parts = [head.data, contents]
        }
        if version >= 5 { tail.unicode(link?.childID ?? "", nulTerminated: false) }
        if version >= 6 { tail.f64(link?.modTime ?? 0) }
        if version >= 7 { tail.u8(link?.lockState ?? 0) }
        parts.append(tail.data)
        if kind == "liFE", version == 2 { parts.append(contents) }
        if let trailing = link?.trailingBytes { parts.append(trailing) }
        return Entry(parts: parts.filter { !$0.isEmpty })
    }

    /// The document's `lnk2` block holding `entries`, each a `u64` length, its bytes and zeros to 4.
    static func writeLinkedBlock(_ entries: [Entry], into writer: inout PSDByteWriter) throws {
        guard !entries.isEmpty else { return }
        let lengths = entries.map(\.count)
        let total = lengths.reduce(0) { $0 + 8 + $1 + (4 - $1 % 4) % 4 }
        guard total <= Int(UInt32.max) else { throw PSDWriteError.tooLarge }
        writer.code("8BIM")
        writer.code("lnk2")
        writer.u32(UInt32(total))
        for (entry, length) in zip(entries, lengths) {
            u64(UInt64(length), into: &writer)
            entry.parts.forEach { writer.bytes($0) }
            writer.bytes(Data(count: (4 - length % 4) % 4))
        }
    }

    // MARK: Helpers

    private static func corners(_ quad: PlacementQuad) -> PSDDescriptorValue {
        .list(quad.corners.flatMap { [PSDDescriptorValue.double(Double($0.x)), .double(Double($0.y))] })
    }

    private static func numbers(_ value: PSDDescriptorValue) -> [Double] {
        guard case .list(let items) = value else { return [] }
        return items.compactMap { item in
            switch item {
            case .double(let number): number
            case .unitFloat(_, let number): number
            default: nil
            }
        }
    }

    private static func int32(_ value: Int) -> Int32 { Int32(clamping: value) }

    private static func u64(_ value: UInt64, into writer: inout PSDByteWriter) {
        writer.u32(UInt32(truncatingIfNeeded: value >> 32))
        writer.u32(UInt32(truncatingIfNeeded: value))
    }
}
