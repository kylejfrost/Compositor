import CoreGraphics
import Foundation

/// One layer record as it will be written.
nonisolated struct PSDLayerRecord {
    var name: String
    var rect = CGRect.zero
    /// `rect`'s pixels; nil for a record without any (folder, divider, adjustment, empty layer).
    var image: CGImage?
    /// A Photoshop Background layer: opaque over the whole canvas, so written without a transparency channel.
    var isBackground = false
    var mask: PSDLayerBaker.Mask?
    /// Bit 0 unlinked, bit 1 disabled, bit 4 `maskParameters` follow; other bits as the file had them.
    var maskFlags: UInt8 = 0
    /// The mask's density and feather, as the file had them (Adobe's mask parameters: a flags byte, then each value).
    var maskParameters = Data()
    var blendKey = "norm"
    var opacity: UInt8 = 255
    var clipping: UInt8 = 0
    var flags: UInt8 = 0x08
    var filler: UInt8 = 0
    var blendingRanges = PSDLayerRecordWriter.defaultBlendingRanges
    var blocks: [PSDTaggedBlock] = []
    /// Bytes after the last block, written back as they were read.
    var trailingBytes = Data()
    /// Photoshop's layer ID (`lyid`).
    var layerID: Int32 = 0
    /// The layer the record writes; nil for a folder's section divider.
    var sourceID: UUID?

    /// Transparency, red, green and blue, then the user mask. A record without pixels still lists the four color
    /// channels, empty.
    var channelIDs: [Int16] {
        (image != nil && isBackground ? [0, 1, 2] : [-1, 0, 1, 2]) + (mask != nil ? [-2] : [])
    }
}

/// Turns a document's layers into layer records (bottom to top; a folder as its section divider, its contents, then
/// the folder) and writes them with their channel data.
///
/// A layer the document was opened with keeps its Photoshop data: its tagged blocks in their order (written without
/// padding between them, then the bytes that followed them, as read), blending ranges, flags, and its blend key,
/// clipping and filler bytes while the layer still matches them. Blocks Compositor models are rewritten in place
/// only where the layer no longer matches them (`luni` after a rename, `lspf`, `iOpa`, `lclr`), and a layer that is
/// no longer a folder loses its section blocks. A layer Photoshop never saw gets the blocks Photoshop writes.
nonisolated enum PSDLayerRecordWriter {
    /// The composite's and each channel's blending range, source and destination: all of 0…255 (40 bytes).
    static let defaultBlendingRanges = Data(Array(repeating: [0, 0, 0xFF, 0xFF, 0, 0, 0xFF, 0xFF] as [UInt8], count: 5).joined())

    static let dividerName = "</Layer group>"

    struct Plan {
        var records: [PSDLayerRecord]
        var warnings: [PSDWriteWarning]
        /// Every type layer the file had is written with the type data it was read with, and no other, so the
        /// document's `Txt2` still holds.
        var keepsTextEngineData = true
        /// Besides, no type layer was renamed: the XMP packet's `photoshop:TextLayers` (each type layer's name and text)
        /// still holds.
        var keepsTextLayersMetadata = true
        /// The smart objects' contents, one linked-layer entry each.
        var linkedEntries: [PSDSmartObjectWriter.Entry] = []
    }

    // MARK: Planning

    static func plan(_ request: PSDWriteRequest, options: PSDWriteOptions) throws -> Plan {
        // Adjustments Photoshop has no layer for are written as pixel layers of their result, when the save allows it.
        let (snapshot, rasterized) = try PSDAdjustmentWriter.rasterizingUnwritable(request.snapshot, allowLossy: options.allowLossy)
        let manifest = snapshot.manifest
        let canvas = CGRect(x: 0, y: 0, width: manifest.width, height: manifest.height)
        let children = Dictionary(grouping: manifest.layers, by: \.parentID)
        func extras(_ layer: ProjectLayerRecord) -> PSDLayerExtras? {
            options.preserveExtras ? (request.sidecars[layer.id] ?? PSDLayerSidecar(record: layer)).extras : nil
        }
        var ids = LayerIDs(preserved: manifest.layers.flatMap { layer in
            [extras(layer)?.layerID, extras(layer)?.sectionDividerExtras?.layerID].compactMap { $0 }
        })
        var records: [PSDLayerRecord] = []
        var warnings = rasterized
        var textIndices = PSDTextIndices(preserved: manifest.layers.compactMap { extras($0)?.textIndex })
        var keepsTextEngineData = true
        // The type layers written as the file had them, by `TextIndex`, and whether any of them was renamed.
        var writtenAsRead: Set<Int32> = []
        var renamedText = false
        var links = PSDSmartObjectWriter.Links()
        // Crop, Canvas Size, Trim, Image Size or Flip Canvas since the file was read: adjustments' vector masks, which
        // hold fractions of its canvas, would confine them elsewhere.
        let canvasMoved = options.preserveExtras && request.document.extras?.canvasMoved(onto: canvas.size) == true

        /// `shown`: every folder around these layers is visible, so a visible layer among them is in the merged image.
        func visit(_ parent: UUID?, depth: Int, shown: Bool) throws {
            guard depth <= 64 else { return }
            // What a clipped record above would clip to in Photoshop: the nearest record below written unclipped.
            var base = ClippingBase.none
            for layer in children[parent] ?? [] {
                let sidecar = request.sidecars[layer.id] ?? PSDLayerSidecar(record: layer)
                let preserved = extras(layer)
                if layer.isGroup == true {
                    records.append(divider(preserved?.sectionDividerExtras, ids: &ids))
                    try visit(layer.id, depth: depth + 1, shown: shown && layer.isVisible)
                    // Compositor doesn't clip folders, so a folder keeps the file's clipping byte; clipped, it leaves
                    // the clipping group below it open, as the importer reads it.
                    let clipping = preserved?.clippingByte ?? 0
                    var record = common(layer, sidecar: sidecar, extras: preserved, clipping: clipping, ids: &ids,
                                        section: options.collapsedGroupIDs.contains(layer.id) ? 2 : 1)
                    // Folders are pass-through; a blend Compositor can't show on a folder stays as the file had it.
                    record.blendKey = preserved.flatMap { PSDBlockFile.isFourCharacterCode($0.blendKey) ? $0.blendKey : nil } ?? "pass"
                    try attachMask(of: layer, to: &record, extras: preserved, snapshot: snapshot, canvas: canvas)
                    records.append(record)
                    if clipping == 0 { base = .unmodeled }
                    continue
                }
                if let preserved, preserved.placeholder != nil {
                    // Kept only to be written back: its clipping byte stays, and it leaves a clipping chain as it was.
                    var record = common(layer, sidecar: sidecar, extras: preserved, clipping: preserved.clippingByte,
                                        ids: &ids, section: nil)
                    if !layer.isVisible, preserved.importedVisible == true { record.flags &= ~0x02 }
                    if record.flags & 0x02 == 0, shown {
                        warnings.append(PSDWriteWarning(layerName: layer.name, message: "Compositor can’t draw this Photoshop layer, so the file’s merged image, which apps without layers show, leaves it out. Photoshop draws it from the layer."))
                    }
                    warnings += PSDVectorWriter.updateVectorMask(&record, layerName: layer.name, extras: preserved,
                                                                 canvas: canvas.size, canvasMoved: canvasMoved)
                    try attachMask(of: layer, to: &record, extras: preserved, snapshot: snapshot, canvas: canvas)
                    records.append(record)
                    if preserved.clippingByte == 0 { base = .unmodeled }
                    continue
                }
                var clipping: UInt8 = 0
                var pixels = snapshot.images[layer.id]?.image
                if layer.maskSourceID == nil, base == .unmodeled, let preserved, preserved.clippingByte != 0 {
                    // Clipped in the file to a folder, an adjustment or a placeholder, which the importer leaves
                    // unclipped because Compositor can't clip to them: the byte stays, and so does the clipping group.
                    // (Releasing a clip Compositor did model clears the byte; see `ImageLayer.releaseClipping`.)
                    clipping = preserved.clippingByte
                } else if let source = layer.maskSourceID {
                    if base == .layer(source) {
                        clipping = 1
                    } else if layer.adjustment == nil, pixels != nil {
                        pixels = try LiveMaskBaker.bake(snapshot, target: layer.id)?.image ?? pixels
                        warnings.append(PSDWriteWarning(layerName: layer.name, message: "Its clipping base isn’t the layer directly below it, as Photoshop requires, so the clipping was applied to its pixels.", lossy: true))
                    } else {
                        // Photoshop shows the layer unclipped: a visible change, agreed to first.
                        warnings.append(PSDWriteWarning(layerName: layer.name, message: "Its clipping base isn’t the layer directly below it, as Photoshop requires, so the clipping was left out.", lossy: true))
                    }
                }
                var record = common(layer, sidecar: sidecar, extras: preserved, clipping: clipping, ids: &ids, section: nil)
                if layer.adjustment != nil {
                    warnings += PSDAdjustmentWriter.update(&record.blocks, for: layer)
                } else if let pixels, let placed = try PSDLayerBaker.pixels(pixels, transform: layer.transform, canvas: canvas) {
                    record.rect = placed.rect
                    record.image = placed.image
                    if placed.clipped {
                        warnings.append(PSDWriteWarning(layerName: layer.name, message: "The layer is larger than a Photoshop layer can be, so only its part on the canvas was saved."))
                    }
                    // Photoshop's Background, as import marked it: only the bottom record (a copy keeps the mark, so
                    // this writes at most one), still opaque across the canvas.
                    if records.isEmpty, parent == nil, preserved?.isBackground == true, placed.rect == canvas,
                       try PSDLayerBaker.isOpaque(placed.image) {
                        record.isBackground = true
                        record.flags |= 0x01
                    }
                }
                if layer.adjustment == nil {
                    PSDEffectsWriter.update(&record.blocks, for: layer, image: snapshot.images[layer.id]?.image, extras: preserved)
                    // Photoshop draws these from the layer; the merged image, rendered by Compositor, can't.
                    if shown, layer.isVisible,
                       let effects = record.blocks.last(where: { $0.key == "lmfx" }) ?? record.blocks.last(where: { $0.key == "lfx2" }),
                       case let undrawn = PSDEffectsReader.undrawn(effects.data), !undrawn.isEmpty {
                        let list = ListFormatter.localizedString(byJoining: undrawn)
                        warnings.append(PSDWriteWarning(layerName: layer.name, message: "Compositor doesn’t draw its \(list), so the file’s merged image, which apps without layers show, leaves \(undrawn.count == 1 ? "it" : "them") out. Photoshop draws \(undrawn.count == 1 ? "it" : "them") from the layer."))
                    }
                }
                // A clip applied to the pixels: Photoshop must draw those, not the text, contents or shape again.
                let baked = pixels !== snapshot.images[layer.id]?.image
                let asRead = try PSDTextWriter.apply(to: &record, layer: layer, raster: snapshot.images[layer.id]?.image,
                    sidecar: sidecar, extras: preserved, options: options, baked: baked, indices: &textIndices)
                keepsTextEngineData = asRead && keepsTextEngineData
                if record.blocks.contains(where: { $0.key == "TySh" }) {
                    if asRead, let index = preserved?.textIndex { writtenAsRead.insert(index) }
                    if layer.name != preserved?.importedName { renamedText = true }
                }
                if let warning = PSDSmartObjectWriter.apply(to: &record, layer: layer, sidecar: sidecar, baked: baked,
                                                            links: &links) {
                    warnings.append(warning)
                }
                warnings += PSDVectorWriter.update(&record, for: layer, extras: preserved, canvas: canvas.size,
                                                   canvasMoved: canvasMoved, resolution: request.document.resolution,
                                                   baked: baked)
                try attachMask(of: layer, to: &record, extras: preserved, snapshot: snapshot, canvas: canvas)
                records.append(record)
                if clipping == 0 { base = layer.adjustment == nil ? .layer(layer.id) : .unmodeled }
            }
        }
        try visit(nil, depth: 0, shown: true)
        // The file's alpha and spot channels aren't kept, so the file written has none (and no resources naming them).
        if options.preserveExtras, let document = request.document.extras, document.alphaChannelCount > 0 {
            let count = document.alphaChannelCount
            let channels = count == 1 ? "alpha or spot channel (a saved selection) isn’t" : "\(count) alpha or spot channels (saved selections) aren’t"
            warnings.append(PSDWriteWarning(layerName: document.sourceFileName ?? "Document",
                                            message: "The file’s \(channels) saved: Compositor doesn’t keep \(count == 1 ? "it" : "them").",
                                            lossy: true))
        }
        // A type layer deleted since the file was read leaves its text in `Txt2`: then it is left out too.
        let imported = options.preserveExtras ? request.document.extras?.importedTextIndices : nil
        keepsTextEngineData = keepsTextEngineData && imported.map { Set($0) == writtenAsRead } == true
        return Plan(records: records, warnings: warnings, keepsTextEngineData: keepsTextEngineData,
                    keepsTextLayersMetadata: keepsTextEngineData && !renamedText, linkedEntries: links.entries)
    }

    /// The record fields every layer and folder shares: name, ID, blend, opacity, clipping, flags and blocks.
    private static func common(_ layer: ProjectLayerRecord, sidecar: PSDLayerSidecar, extras: PSDLayerExtras?,
                               clipping: UInt8, ids: inout LayerIDs, section: UInt32?) -> PSDLayerRecord {
        var record = PSDLayerRecord(name: layer.name)
        record.sourceID = layer.id
        record.layerID = ids.claim(extras?.layerID)
        let modeled = layer.blendMode ?? .normal
        if let raw = extras?.blendKey, PSDBlockFile.isFourCharacterCode(raw), (LayerBlendMode.fromPSD(raw) ?? .normal) == modeled {
            record.blendKey = raw
        } else {
            record.blendKey = modeled.psdKey
        }
        let opacity = layer.opacity ?? 1
        record.opacity = UInt8((min(1, max(0, opacity.isFinite ? opacity : 1)) * 255).rounded())
        if let extras, (extras.clippingByte != 0) == (clipping != 0) {
            record.clipping = extras.clippingByte
        } else {
            record.clipping = clipping
        }
        let lockedTransparency: UInt8 = sidecar.locks.locksTransparency ? 0x01 : 0
        let hidden: UInt8 = layer.isVisible ? 0 : 0x02
        let pixelless = layer.isGroup == true || layer.adjustment != nil
        record.flags = (extras.map { $0.flags & ~0x03 } ?? (pixelless ? 0x10 : 0)) | 0x08 | hidden | lockedTransparency
        record.filler = extras?.fillerByte ?? 0
        if let ranges = extras?.blendingRanges, !ranges.isEmpty { record.blendingRanges = ranges }
        record.trailingBytes = extras?.trailingBytes ?? Data()
        record.blocks = blocks(name: layer.name, layerID: record.layerID, section: section, sidecar: sidecar, extras: extras)
        return record
    }

    /// The layer's mask, over the record's pixels when it has some (see `PSDLayerBaker.mask`). A mask the file had
    /// keeps the flag bits Compositor doesn't model (invert and the undocumented ones) and its parameters; it loses
    /// the "from rendering" bit, since the mask written is the one Compositor shows.
    private static func attachMask(of layer: ProjectLayerRecord, to record: inout PSDLayerRecord, extras: PSDLayerExtras?,
                                   snapshot: ProjectSnapshot, canvas: CGRect) throws {
        guard let mask = snapshot.mask(for: layer) else { return }
        record.maskFlags = (mask.isLinked ? 0 : 0x01) | (mask.isEnabled ? 0 : 0x02)
        if let extras, let flags = extras.maskFlags {
            record.maskFlags |= flags & ~0x1B
            if let parameters = maskParameters(extras) {
                record.maskFlags |= 0x10
                record.maskParameters = parameters
            }
        }
        // A mask import padded goes back to the rectangle the file stored it in, when that loses nothing.
        let stored = extras?.importedMaskRect.map { (rect: $0, defaultColor: extras?.maskDefaultColor ?? 255) }
        record.mask = try PSDLayerBaker.mask(mask, layer: layer.transform, rect: record.image == nil ? nil : record.rect,
                                             canvas: canvas, stored: stored)
    }

    /// The mask parameters among the mask bytes the file had after the flags (`maskParameters`): at their start, or
    /// after the 18 bytes of a real user mask (the mask Photoshop combines from the vector and pixel masks, stored with
    /// its own channel). A save writes neither that channel nor its header, so Photoshop combines the masks again.
    /// Nil when the flags say there are none, or none can be framed with at most padding after them.
    private static func maskParameters(_ extras: PSDLayerExtras) -> Data? {
        guard let flags = extras.maskFlags, flags & 0x10 != 0, let bytes = extras.maskParameters else { return nil }
        let tail = Data(bytes)
        func framed(at offset: Int) -> Data? {
            // A flags byte: user mask density (u8), user mask feather (f64), vector mask density, vector mask feather.
            guard offset < tail.count, tail[offset] & 0xF0 == 0 else { return nil }
            let present = tail[offset]
            let size = 1 + (present & 0x01 != 0 ? 1 : 0) + (present & 0x02 != 0 ? 8 : 0) + (present & 0x04 != 0 ? 1 : 0)
                + (present & 0x08 != 0 ? 8 : 0)
            guard offset + size <= tail.count, tail.count - offset - size <= 3,
                  tail[(offset + size)...].allSatisfy({ $0 == 0 }) else { return nil }
            return tail.subdata(in: offset ..< offset + size)
        }
        return framed(at: 0) ?? framed(at: 18)
    }

    /// A folder's section divider: the one the file had, or the one Photoshop writes.
    private static func divider(_ extras: PSDLayerExtras?, ids: inout LayerIDs) -> PSDLayerRecord {
        var record = PSDLayerRecord(name: dividerName)
        record.layerID = ids.claim(extras?.layerID)
        guard let extras else {
            record.flags = 0x18
            record.blocks = freshBlocks(name: dividerName, layerID: record.layerID, section: 3, locks: [], fillOpacity: 1,
                                        label: .none)
            return record
        }
        if let name = extras.importedName, !name.isEmpty { record.name = name }
        if PSDBlockFile.isFourCharacterCode(extras.blendKey) { record.blendKey = extras.blendKey }
        record.flags = extras.flags | 0x08
        record.clipping = extras.clippingByte
        record.filler = extras.fillerByte
        if !extras.blendingRanges.isEmpty { record.blendingRanges = extras.blendingRanges }
        record.trailingBytes = extras.trailingBytes
        var blocks = extras.blocks
        setBlock("lyid", u32(UInt32(bitPattern: record.layerID)), in: &blocks, insertingAt: insertionAfterName(blocks))
        record.blocks = blocks
        return record
    }

    // MARK: Blocks

    /// The `lspf` bits Compositor models. Artboard nesting and bits it doesn't know only come from a file, so they're
    /// written only with the layer's Photoshop data.
    private static let modeledLocks: LayerLocks = [.transparency, .pixels, .position, .all]

    /// The record's tagged blocks: the file's own, adjusted to the layer, or a fresh set.
    private static func blocks(name: String, layerID: Int32, section: UInt32?, sidecar: PSDLayerSidecar,
                               extras: PSDLayerExtras?) -> [PSDTaggedBlock] {
        guard let extras else {
            return freshBlocks(name: name, layerID: layerID, section: section,
                               locks: sidecar.locks.intersection(modeledLocks), fillOpacity: sidecar.fillOpacity,
                               label: .none)
        }
        let label = extras.colorLabel
        var blocks = extras.blocks
        if section == nil { blocks.removeAll { $0.key == "lsct" || $0.key == "lsdk" } }
        if name != extras.importedName || !blocks.contains(where: { $0.key == "luni" }) {
            setBlock("luni", luni(name), in: &blocks, insertingAt: 0)
        }
        setBlock("lyid", u32(UInt32(bitPattern: layerID)), in: &blocks, insertingAt: insertionAfterName(blocks))
        if let section, !blocks.contains(where: { $0.key == "lsct" || $0.key == "lsdk" }) {
            let lyid = blocks.firstIndex { $0.key == "lyid" }.map { $0 + 1 } ?? blocks.count
            blocks.insert(PSDTaggedBlock(key: "lsct", data: sectionPayload(section)), at: lyid)
        }
        // Locks, Fill and the color label: rewritten where the file's block says otherwise, added (last) where the
        // file has none and the layer isn't at the default.
        func keep(_ key: String, _ payload: Data, isDefault: Bool, matches: (Data) -> Bool) {
            if let existing = blocks.firstIndex(where: { $0.key == key }) {
                if !matches(blocks[existing].data) { blocks[existing].data = payload }
            } else if !isDefault {
                blocks.append(PSDTaggedBlock(key: key, data: payload))
            }
        }
        let locks = sidecar.locks, fill = fillByte(sidecar.fillOpacity)
        keep("lspf", u32(locks.rawValue), isDefault: locks.isEmpty) { $0.count >= 4 && LayerLocks(rawValue: readU32($0)) == locks }
        keep("iOpa", Data([fill, 0, 0, 0]), isDefault: fill == 255) { $0.first == fill }
        keep("lclr", labelPayload(label), isDefault: label == .none) { colorLabel(of: $0) == label }
        return blocks
    }

    /// The label an `lclr` payload reads as; a color Compositor doesn't know reads as none, as on import.
    private static func colorLabel(of payload: Data) -> LayerColorLabel? {
        guard payload.count >= 2 else { return nil }
        return LayerColorLabel(rawValue: payload.prefix(2).reduce(0) { $0 << 8 | UInt16($1) }) ?? LayerColorLabel.none
    }

    /// The blocks Photoshop 2026 writes on a layer it creates, in its order.
    private static func freshBlocks(name: String, layerID: Int32, section: UInt32?, locks: LayerLocks, fillOpacity: Double,
                                    label: LayerColorLabel) -> [PSDTaggedBlock] {
        var blocks = [PSDTaggedBlock(key: "luni", data: luni(name)),
                      PSDTaggedBlock(key: "lyid", data: u32(UInt32(bitPattern: layerID)))]
        if let section { blocks.append(PSDTaggedBlock(key: "lsct", data: sectionPayload(section))) }
        blocks += [PSDTaggedBlock(key: "clbl", data: Data([1, 0, 0, 0])),
                   PSDTaggedBlock(key: "infx", data: Data(count: 4)),
                   PSDTaggedBlock(key: "knko", data: Data(count: 4)),
                   PSDTaggedBlock(key: "lspf", data: u32(locks.rawValue)),
                   PSDTaggedBlock(key: "lclr", data: labelPayload(label)),
                   PSDTaggedBlock(key: "fxrp", data: Data(count: 16))]
        let fill = fillByte(fillOpacity)
        if fill < 255 { blocks.append(PSDTaggedBlock(key: "iOpa", data: Data([fill, 0, 0, 0]))) }
        return blocks
    }

    /// Replaces the payload of the first `key` block when it differs, or inserts the block at `index`.
    private static func setBlock(_ key: String, _ payload: Data, in blocks: inout [PSDTaggedBlock], insertingAt index: Int) {
        if let existing = blocks.firstIndex(where: { $0.key == key }) {
            if blocks[existing].data != payload { blocks[existing].data = payload }
        } else {
            blocks.insert(PSDTaggedBlock(key: key, data: payload), at: min(max(0, index), blocks.count))
        }
    }

    private static func insertionAfterName(_ blocks: [PSDTaggedBlock]) -> Int {
        blocks.firstIndex { $0.key == "luni" }.map { $0 + 1 } ?? 0
    }

    /// `u32` count of UTF-16 units, then the units big-endian, without a terminating NUL.
    private static func luni(_ name: String) -> Data {
        var writer = PSDByteWriter()
        writer.unicode(name, nulTerminated: false)
        return writer.data
    }

    /// Folder type (1 open, 2 closed, 3 divider), then `8BIM` and the pass-through blend key.
    private static func sectionPayload(_ type: UInt32) -> Data {
        u32(type) + PSDBlockFile.code("8BIM") + PSDBlockFile.code("pass")
    }

    private static func labelPayload(_ label: LayerColorLabel) -> Data {
        Data([UInt8(label.rawValue >> 8), UInt8(label.rawValue & 0xFF), 0, 0, 0, 0, 0, 0])
    }

    private static func fillByte(_ fillOpacity: Double) -> UInt8 {
        UInt8((min(1, max(0, fillOpacity.isFinite ? fillOpacity : 1)) * 255).rounded())
    }

    private static func u32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    private static func readU32(_ data: Data) -> UInt32 {
        data.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    // MARK: Writing

    /// Every record, then every record's channel data in the same order. Channel lengths are patched in as each
    /// channel is written, so only one layer's channel planes are made at a time; the pixels they are made from are
    /// the records' (a layer's own image, or the baked one the plan made for a turned layer or a clip).
    static func write(_ records: [PSDLayerRecord], into writer: inout PSDByteWriter) throws {
        var lengthOffsets: [[Int]] = []
        lengthOffsets.reserveCapacity(records.count)
        for record in records {
            writeRect(record.rect, into: &writer)
            let ids = record.channelIDs
            writer.u16(UInt16(ids.count))
            var offsets: [Int] = []
            for id in ids {
                writer.i16(id)
                offsets.append(writer.reserveU32())
            }
            lengthOffsets.append(offsets)
            writer.code("8BIM")
            writer.code(record.blendKey)
            writer.u8(record.opacity)
            writer.u8(record.clipping)
            writer.u8(record.flags)
            writer.u8(record.filler)
            let extraLength = writer.reserveU32()
            let extraStart = writer.count
            if let mask = record.mask {
                // Rectangle, default color, flags, the parameters, then padding to 4 (20 bytes without parameters).
                let length = 18 + record.maskParameters.count
                writer.u32(UInt32(length + (4 - length % 4) % 4))
                let maskStart = writer.count
                writeRect(mask.rect, into: &writer)
                writer.u8(mask.defaultColor)
                writer.u8(record.maskFlags)
                writer.bytes(record.maskParameters)
                writer.pad(to: 4, from: maskStart)
            } else {
                writer.u32(0)
            }
            writer.u32(UInt32(record.blendingRanges.count))
            writer.bytes(record.blendingRanges)
            writer.pascal(record.name, pad: 4)
            for block in record.blocks { writer.taggedBlock(block, alignment: 1) }
            writer.bytes(record.trailingBytes)
            writer.pad(to: 2, from: extraStart)
            writer.patch(UInt32(writer.count - extraStart), at: extraLength)
        }
        for (record, offsets) in zip(records, lengthOffsets) {
            var planes: [Int16: (plane: [UInt8], width: Int, height: Int)] = [:]
            if let image = record.image {
                let straight = try PSDChannelEncoder.straightPlanes(image)
                for (id, plane) in [(-1, straight.a), (0, straight.r), (1, straight.g), (2, straight.b)] as [(Int16, [UInt8])] {
                    planes[id] = (plane, image.width, image.height)
                }
            }
            if let mask = record.mask {
                planes[-2] = (try PSDChannelEncoder.grayPlane(mask.image), mask.image.width, mask.image.height)
            }
            for (id, offset) in zip(record.channelIDs, offsets) {
                let start = writer.count
                if let channel = planes[id] {
                    writer.u16(1)
                    writer.bytes(PSDChannelEncoder.rle(channel.plane, width: channel.width, height: channel.height))
                } else {
                    writer.u16(0)
                }
                writer.patch(UInt32(writer.count - start), at: offset)
            }
        }
    }

    /// Top, left, bottom, right.
    private static func writeRect(_ rect: CGRect, into writer: inout PSDByteWriter) {
        writer.i32(Int32(clamping: Int(rect.minY)))
        writer.i32(Int32(clamping: Int(rect.minX)))
        writer.i32(Int32(clamping: Int(rect.maxY)))
        writer.i32(Int32(clamping: Int(rect.maxX)))
    }
}

/// Photoshop layer IDs: each layer keeps its own unless another record already has it; the rest count up from the
/// largest one kept.
nonisolated private struct LayerIDs {
    private var used: Set<Int32> = []
    private var next: Int32

    init(preserved: [Int32]) {
        let largest = preserved.max() ?? 0
        next = largest < Int32.max ? max(0, largest) + 1 : 1
    }

    mutating func claim(_ preferred: Int32?) -> Int32 {
        if let preferred, used.insert(preferred).inserted { return preferred }
        while used.contains(next) { next = next == Int32.max ? 1 : next + 1 }
        used.insert(next)
        return next
    }
}

/// The base of a Photoshop clipping group: the nearest record below, in the same folder, written unclipped. The
/// importer only clips to a layer with pixels; above a folder, an adjustment or a placeholder a clipped layer comes in
/// unclipped, and above nothing (the bottom of a folder) there is no group to join.
nonisolated private enum ClippingBase: Equatable {
    case none
    case layer(UUID)
    case unmodeled
}
