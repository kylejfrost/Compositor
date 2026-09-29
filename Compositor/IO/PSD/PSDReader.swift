import CoreGraphics
import Foundation

/// Reads Photoshop `.psd` files from Adobe’s *Photoshop File Formats Specification*
/// (2019 HTML edition: File Header, Color Mode Data, Image Resources, Layer and
/// Mask Information, Image Data). Original implementation of the 8BPS header,
/// layer records, PackBits, and additional layer info. Not copied, transcribed,
/// or adapted from GIMP, psd-tools, or any other GPL-licensed PSD reader.
///
/// Nothing is thrown away: every image resource, every additional-layer-info block (in file order), each layer's
/// blending ranges, flags and mask fields, the global layer mask info and the document-level blocks are kept in
/// `PSDLayerExtras`/`PSDDocumentExtras` so the file can be written back whole. Blocks that can't be framed or
/// decoded are kept as bytes; they never cost a layer.
nonisolated enum PSDReader {
    static func matches(_ url: URL) -> Bool {
        matches(magicOf: url)
    }

    private static func matches(magicOf url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("8BPS".utf8)
    }

    static func matches(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4) == Data("8BPS".utf8)
    }

    /// `remainingPixels` bounds the layers' pixels and `remainingMaskPixels` their masks', each counted over the whole
    /// file as a project counts them (`ProjectStore`), so whatever opens can be saved. When the layers don't fit, every
    /// layer and mask is first cropped to the canvas (`PSDRecord.croppedToCanvas`); pixels that still don't fit fail the
    /// file, and a mask past its budget is left out unread (`PSDRecord.maskOverBudget`). Reads PSD (version 1) and
    /// Large Document PSB (version 2) files.
    static func read(from url: URL, remainingPixels: Int = DocumentLimits.documentPixelBudget,
                     remainingMaskPixels: Int = LayerMask.maximumProjectPixels) throws -> PSDDocument {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        var document = try read(data, remainingPixels: remainingPixels, remainingMaskPixels: remainingMaskPixels)
        document.extras?.sourceFileName = url.lastPathComponent
        return document
    }

    static func read(_ input: Data, remainingPixels: Int = DocumentLimits.documentPixelBudget,
                     remainingMaskPixels: Int = LayerMask.maximumProjectPixels) throws -> PSDDocument {
        // Offsets below count from zero.
        let data = input.startIndex == 0 ? input : Data(input)
        var cursor = PSDCursor(data: data)
        guard try cursor.string(4) == "8BPS" else { throw ImageImportError.unreadable }
        let version = try cursor.u16()
        guard version == 1 || version == 2 else { throw PSDError.unsupportedVersion }
        let isPSB = version == 2
        try cursor.skip(6)
        var extras = PSDDocumentExtras()
        extras.channelCount = Int(try cursor.u16())
        let canvasHeight = Int(try cursor.u32())
        let canvasWidth = Int(try cursor.u32())
        let depth = try cursor.u16()
        let mode = try cursor.u16()
        guard (1...DocumentLimits.maxSide).contains(canvasWidth), (1...DocumentLimits.maxSide).contains(canvasHeight),
              canvasWidth * canvasHeight <= DocumentLimits.maxSurfacePixels else {
            throw ImageImportError.tooLarge
        }
        guard depth == 8 else { throw PSDError.unsupportedDepth }
        guard mode == 3 else { throw PSDError.unsupportedColorMode }
        extras.canvasSize = CGSize(width: canvasWidth, height: canvasHeight)
        extras.canvasTransform = .identity
        extras.colorModeData = try cursor.bytes(Int(try cursor.u32()))
        let resourcesLength = Int(try cursor.u32())
        let resourcesEnd = cursor.offset + resourcesLength
        extras.resources = PSDBlockFile.scanResources(data, from: cursor.offset, to: resourcesEnd)
        let resolution = decodeResources(extras.resources, into: &extras)
        cursor.offset = resourcesEnd
        let layerSection = try checkedLength(isPSB ? cursor.u64() : UInt64(cursor.u32()))
        let layerSectionEnd = cursor.offset + layerSection
        guard layerSection >= 4 else {
            return PSDDocument(width: canvasWidth, height: canvasHeight, resolution: resolution, layers: [], extras: extras,
                               maskPixelBudget: remainingMaskPixels, isLargeDocument: isPSB)
        }
        let layerInfoLength = try checkedLength(isPSB ? cursor.u64() : UInt64(cursor.u32()))
        let layerInfoStart = cursor.offset
        var raw = [RawLayer]()
        if layerInfoLength > 0 {
            let rawCount = try cursor.i16()
            extras.layerCountNegative = rawCount < 0
            let count = abs(Int(rawCount))
            guard count <= LayerLimitError.maximum else { throw LayerLimitError() }
            raw.reserveCapacity(count)
            for _ in 0..<count { raw.append(try readRecord(&cursor, isPSB: isPSB)) }
            // A file whose layers reach far past the canvas may not fit as it is: cropped to the canvas, it shows the
            // same. Masks are cropped too, so fewer of them are left out.
            if !fitsBudget(raw, remainingPixels: remainingPixels, remainingMaskPixels: remainingMaskPixels) {
                for index in raw.indices { cropToCanvas(&raw[index], width: canvasWidth, height: canvasHeight) }
            }
            var usedPixels = 0, usedMaskPixels = 0
            for index in raw.indices {
                try decodeChannels(&cursor, layer: &raw[index], remainingPixels: remainingPixels - usedPixels,
                                   remainingMaskPixels: remainingMaskPixels - usedMaskPixels, isPSB: isPSB)
                if let image = raw[index].image { usedPixels += image.width * image.height }
                if let mask = raw[index].maskImage { usedMaskPixels += mask.width * mask.height }
            }
            var layers = try assemble(raw, canvas: CGSize(width: canvasWidth, height: canvasHeight),
                                      remainingPixels: remainingPixels - usedPixels,
                                      globalLightAngle: extras.globalLightAngle)
            // The layer info should be padded to even; some writers leave an odd length unpadded.
            if !readGlobalInfo(data, from: layerInfoStart + layerInfoLength + layerInfoLength % 2, to: layerSectionEnd,
                               isPSB: isPSB, into: &extras),
               layerInfoLength % 2 == 1 {
                readGlobalInfo(data, from: layerInfoStart + layerInfoLength, to: layerSectionEnd, isPSB: isPSB, into: &extras)
            }
            linkSmartObjects(&layers, &extras)
            cursor.offset = layerSectionEnd
            return PSDDocument(width: canvasWidth, height: canvasHeight, resolution: resolution, layers: layers, extras: extras,
                               maskPixelBudget: remainingMaskPixels, isLargeDocument: isPSB)
        }
        readGlobalInfo(data, from: layerInfoStart, to: layerSectionEnd, isPSB: isPSB, into: &extras)
        var layers: [PSDRecord] = []
        linkSmartObjects(&layers, &extras)
        return PSDDocument(width: canvasWidth, height: canvasHeight, resolution: resolution, layers: layers, extras: extras,
                           maskPixelBudget: remainingMaskPixels, isLargeDocument: isPSB)
    }

    /// Takes the linked-layer blocks out of the document's blocks: the entries layers' smart objects name become
    /// their contents, and the rest are kept as `orphanLinkedEntries`, so each entry is kept exactly once.
    private static func linkSmartObjects(_ layers: inout [PSDRecord], _ extras: inout PSDDocumentExtras) {
        extras.importedTextIndices = layers.compactMap { $0.extras?.textIndex }.sorted()
        let split = PSDSmartObjects.decompose(extras.globalBlocks)
        extras.globalBlocks = split.blocks
        extras.linkedBlockIndex = split.position
        let resolved = PSDSmartObjects.resolve(layers.map { $0.smartObject?.info }, entries: split.entries)
        for index in layers.indices { layers[index].smartObject = resolved.smartObjects[index] }
        extras.orphanLinkedEntries = resolved.orphans
    }

    /// The global layer mask info at `start` and the document-level tagged blocks after it, up to `end`. A length
    /// that doesn't fit leaves both empty rather than failing the file, and returns false.
    @discardableResult
    private static func readGlobalInfo(_ data: Data, from start: Int, to end: Int, isPSB: Bool,
                                       into extras: inout PSDDocumentExtras) -> Bool {
        let end = min(end, data.count)
        guard start >= 0, start + 4 <= end else { return false }
        let length = Int(u32(data, start))
        guard length <= end - start - 4 else { return false }
        extras.globalLayerMaskInfo = data.subdata(in: start + 4 ..< start + 4 + length)
        extras.globalBlocks = PSDBlockFile.scanBlocks(data, from: start + 4 + length, to: end, largeDocument: isPSB)
        return true
    }

    /// The document values the resources hold; returns the resolution (1005), 72 when absent or unusable. Guides
    /// (1032), the global light (1037/1049), alpha channel names (1006/1045) and the ICC description (1039) are
    /// decoded by `PSDResources`.
    private static func decodeResources(_ resources: [PSDImageResource], into extras: inout PSDDocumentExtras) -> Double {
        var resolution = 72.0
        for resource in resources where resource.id == 1005 && resource.data.count >= 4 {
            resolution = Double(u32(resource.data, 0)) / 65536
            if !resolution.isFinite || resolution < 1 { resolution = 72 }
            resolution = min(9600, max(1, resolution))
        }
        let light = PSDResources.globalLight(resources)
        extras.globalLightAngle = light.angle
        extras.globalLightAltitude = light.altitude
        extras.alphaChannelNames = PSDResources.alphaNames(resources)
        if let icc = resources.last(where: { $0.id == 1039 }) {
            extras.iccProfileDescription = PSDResources.iccDescription(icc.data)
        }
        return resolution
    }

    private struct RawLayer {
        var name = ""
        var top = 0, left = 0, bottom = 0, right = 0
        var sourceTop = 0, sourceLeft = 0, sourceBottom = 0, sourceRight = 0
        var opacity: UInt8 = 255
        var fill: UInt8 = 255
        var clipping = false
        var clippingByte: UInt8 = 0
        var fillerByte: UInt8 = 0
        var trailingBytes = Data()
        var hidden = false
        var blendKey = "norm"
        var flags: UInt8 = 0
        var blendingRanges = Data()
        var channels: [(id: Int, length: Int)] = []
        /// Every block, in file order.
        var blocks: [PSDTaggedBlock] = []
        /// The same blocks by key (the last of a repeated key), for the decoders that look one up.
        var extra: [String: Data] = [:]
        var maskTop = 0, maskLeft = 0, maskBottom = 0, maskRight = 0
        var sourceMaskTop = 0, sourceMaskLeft = 0, sourceMaskBottom = 0, sourceMaskRight = 0
        var maskDefault: UInt8 = 255
        var maskFlags: UInt8?
        var maskParameters: Data?
        var maskDisabled = false
        var maskLinked = true
        var maskFromRender = false
        var hasMask = false
        /// The mask was left out unread: it would take the file's masks past their budget.
        var maskOverBudget = false
        var section: Int?
        var locks: LayerLocks = []
        var colorLabel: LayerColorLabel = .none
        var layerID: Int32?
        var nameSource: String?
        var image: CGImage?
        var maskImage: CGImage?
        var imageCrop: PSDCrop?
        var maskCrop: PSDCrop?
        var cropped = false
    }

    private static func checkedLength(_ value: UInt64) throws -> Int {
        guard value <= UInt64(Int.max) else { throw ImageImportError.tooLarge }
        return Int(value)
    }

    private static func readRecord(_ cursor: inout PSDCursor, isPSB: Bool) throws -> RawLayer {
        var layer = RawLayer()
        layer.top = Int(try cursor.i32())
        layer.left = Int(try cursor.i32())
        layer.bottom = Int(try cursor.i32())
        layer.right = Int(try cursor.i32())
        layer.sourceTop = layer.top
        layer.sourceLeft = layer.left
        layer.sourceBottom = layer.bottom
        layer.sourceRight = layer.right
        let channelCount = Int(try cursor.u16())
        guard channelCount <= 56 else { throw ImageImportError.tooLarge }
        for _ in 0..<channelCount {
            let id = Int(try cursor.i16())
            let length = try checkedLength(isPSB ? cursor.u64() : UInt64(cursor.u32()))
            layer.channels.append((id, length))
        }
        guard try cursor.string(4) == "8BIM" else { throw PSDError.truncated }
        // Latin-1, one character per byte, so a key that isn't ASCII is kept (and saved) as the bytes it was.
        layer.blendKey = try cursor.code()
        layer.opacity = try cursor.u8()
        layer.clippingByte = try cursor.u8()
        layer.clipping = layer.clippingByte != 0
        layer.flags = try cursor.u8()
        layer.hidden = (layer.flags & 2) != 0
        layer.fillerByte = try cursor.u8()
        let extraLength = Int(try cursor.u32())
        let extraEnd = cursor.offset + extraLength
        let maskLength = Int(try cursor.u32())
        let maskEnd = cursor.offset + maskLength
        if maskLength >= 20 {
            layer.hasMask = true
            layer.maskTop = Int(try cursor.i32())
            layer.maskLeft = Int(try cursor.i32())
            layer.maskBottom = Int(try cursor.i32())
            layer.maskRight = Int(try cursor.i32())
            layer.sourceMaskTop = layer.maskTop
            layer.sourceMaskLeft = layer.maskLeft
            layer.sourceMaskBottom = layer.maskBottom
            layer.sourceMaskRight = layer.maskRight
            layer.maskDefault = try cursor.u8()
            let maskFlags = try cursor.u8()
            layer.maskFlags = maskFlags
            layer.maskDisabled = (maskFlags & 2) != 0
            layer.maskLinked = (maskFlags & 1) == 0
            layer.maskFromRender = (maskFlags & 8) != 0
            layer.maskParameters = try cursor.bytes(maskEnd - cursor.offset)
        }
        cursor.offset = maskEnd
        let ranges = Int(try cursor.u32())
        layer.blendingRanges = try cursor.bytes(ranges)
        let nameCount = Int(try cursor.u8())
        let nameBytes = try cursor.bytes(nameCount)
        layer.name = String(bytes: nameBytes, encoding: .macOSRoman) ?? String(bytes: nameBytes, encoding: .isoLatin1) ?? "Layer"
        let namePad = (4 - ((nameCount + 1) % 4)) % 4
        try cursor.skip(namePad)
        (layer.blocks, layer.trailingBytes) = PSDBlockFile.scanBlocksAndTail(cursor.data, from: cursor.offset, to: extraEnd,
                                                                             largeDocument: isPSB)
        for block in layer.blocks {
            let payload = block.data
            layer.extra[block.key] = payload
            switch block.key {
            case "luni": if let unicode = unicodeName(payload) { layer.name = unicode }
            case "iOpa": if let fill = payload.first { layer.fill = fill }
            case "lsct", "lsdk": if payload.count >= 4 { layer.section = Int(u32(payload, 0)) }
            case "lspf": if payload.count >= 4 { layer.locks = LayerLocks(rawValue: u32(payload, 0)) }
            case "lclr": if payload.count >= 2 { layer.colorLabel = LayerColorLabel(rawValue: UInt16(payload[0]) << 8 | UInt16(payload[1])) ?? .none }
            case "lyid": if payload.count >= 4 { layer.layerID = Int32(bitPattern: u32(payload, 0)) }
            case "lnsr": if payload.count >= 4 { layer.nameSource = String(data: payload.prefix(4), encoding: .isoLatin1) }
            default: break
            }
        }
        cursor.offset = extraEnd
        return layer
    }

    private static func unicodeName(_ data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let count = Int(u32(data, 0))
        guard count > 0, data.count >= 4 + count * 2 else { return nil }
        var units = [UInt16]()
        units.reserveCapacity(count)
        for i in 0..<count {
            let hi = data[4 + i * 2], lo = data[5 + i * 2]
            units.append(UInt16(hi) << 8 | UInt16(lo))
        }
        return String(utf16CodeUnits: units, count: count).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    /// Transparency, R, G, B, and the user mask. Spot and other extra IDs are skipped before decode.
    private static let unpackedChannelIDs: Set<Int> = [-1, 0, 1, 2, -2]

    /// Whether every layer's pixels fit `remainingPixels` and every mask read fits `remainingMaskPixels`, counted in
    /// file order, each within 30,000 pixels a side: what `decodeChannels` would accept as the records stand.
    private static func fitsBudget(_ layers: [RawLayer], remainingPixels: Int, remainingMaskPixels: Int) -> Bool {
        var usedPixels = 0, usedMaskPixels = 0
        for layer in layers {
            let width = max(0, layer.right - layer.left), height = max(0, layer.bottom - layer.top)
            if width > 0, height > 0 {
                guard fits(width: width, height: height, budget: remainingPixels - usedPixels) else { return false }
                usedPixels += width * height
            }
            let maskWidth = max(0, layer.maskRight - layer.maskLeft), maskHeight = max(0, layer.maskBottom - layer.maskTop)
            if layer.hasMask, !layer.maskFromRender, maskWidth > 0, maskHeight > 0 {
                guard fits(width: maskWidth, height: maskHeight, budget: remainingMaskPixels - usedMaskPixels) else { return false }
                usedMaskPixels += maskWidth * maskHeight
            }
        }
        return true
    }

    /// Within 30,000 pixels a side and `budget` pixels in all.
    private static func fits(width: Int, height: Int, budget: Int) -> Bool {
        width <= DocumentLimits.maxSide && height <= DocumentLimits.maxSide && width * height <= max(0, budget)
    }

    /// Crops the layer's pixels and mask to the canvas, when they reach past it; the channels are then decoded
    /// cropped (`imageCrop`, `maskCrop`).
    private static func cropToCanvas(_ layer: inout RawLayer, width: Int, height: Int) {
        let imageCrop = crop(left: layer.left, top: layer.top, right: layer.right, bottom: layer.bottom,
                             canvasWidth: width, canvasHeight: height)
        if imageCrop.x != 0 || imageCrop.y != 0 || imageCrop.width != layer.right - layer.left || imageCrop.height != layer.bottom - layer.top {
            layer.left += imageCrop.x
            layer.top += imageCrop.y
            layer.right = layer.left + imageCrop.width
            layer.bottom = layer.top + imageCrop.height
            layer.imageCrop = imageCrop
            layer.cropped = true
        }
        guard layer.hasMask else { return }
        let maskCrop = crop(left: layer.maskLeft, top: layer.maskTop, right: layer.maskRight, bottom: layer.maskBottom,
                            canvasWidth: width, canvasHeight: height)
        if maskCrop.x != 0 || maskCrop.y != 0 || maskCrop.width != layer.maskRight - layer.maskLeft || maskCrop.height != layer.maskBottom - layer.maskTop {
            layer.maskLeft += maskCrop.x
            layer.maskTop += maskCrop.y
            layer.maskRight = layer.maskLeft + maskCrop.width
            layer.maskBottom = layer.maskTop + maskCrop.height
            layer.maskCrop = maskCrop
            layer.cropped = true
        }
    }

    private static func crop(left: Int, top: Int, right: Int, bottom: Int, canvasWidth: Int, canvasHeight: Int) -> PSDCrop {
        let croppedLeft = min(canvasWidth, max(0, left))
        let croppedTop = min(canvasHeight, max(0, top))
        let croppedRight = max(croppedLeft, min(canvasWidth, right))
        let croppedBottom = max(croppedTop, min(canvasHeight, bottom))
        return PSDCrop(x: croppedLeft - left, y: croppedTop - top,
                       width: croppedRight - croppedLeft, height: croppedBottom - croppedTop)
    }

    /// The layer's pixels and user mask. The mask counts against `remainingMaskPixels` (and at most 30,000 pixels a
    /// side), as a project counts masks: one that doesn't fit is left out unread. A mask Photoshop rendered from other
    /// data, which import drops, is never read either.
    private static func decodeChannels(_ cursor: inout PSDCursor, layer: inout RawLayer, remainingPixels: Int,
                                       remainingMaskPixels: Int, isPSB: Bool) throws {
        var planes: [Int: [UInt8]] = [:]
        let width = max(0, layer.right - layer.left)
        let height = max(0, layer.bottom - layer.top)
        let maskWidth = max(0, layer.maskRight - layer.maskLeft)
        let maskHeight = max(0, layer.maskBottom - layer.maskTop)
        if width > 0, height > 0 {
            guard fits(width: width, height: height, budget: remainingPixels) else { throw ImageImportError.tooLarge }
        }
        var readsMask = layer.hasMask && !layer.maskFromRender && maskWidth > 0 && maskHeight > 0
        if readsMask, !fits(width: maskWidth, height: maskHeight, budget: remainingMaskPixels) {
            layer.maskOverBudget = true
            readsMask = false
        }
        // What the file stores; cropped layers decode only the part on the canvas.
        let sourceWidth = max(0, layer.sourceRight - layer.sourceLeft)
        let sourceHeight = max(0, layer.sourceBottom - layer.sourceTop)
        let sourceMaskWidth = max(0, layer.sourceMaskRight - layer.sourceMaskLeft)
        let sourceMaskHeight = max(0, layer.sourceMaskBottom - layer.sourceMaskTop)
        for channel in layer.channels {
            let start = cursor.offset
            defer { cursor.offset = start + max(0, channel.length) }
            guard unpackedChannelIDs.contains(channel.id), channel.length >= 2 else { continue }
            let isMask = channel.id == -2
            guard !isMask || readsMask else { continue }
            let compression = Int(try cursor.u16())
            let payload = try cursor.bytes(channel.length - 2)
            let sourceW = isMask ? sourceMaskWidth : sourceWidth
            let sourceH = isMask ? sourceMaskHeight : sourceHeight
            let targetW = isMask ? maskWidth : width
            let targetH = isMask ? maskHeight : height
            let crop = isMask ? layer.maskCrop : layer.imageCrop
            if targetW > 0, targetH > 0 {
                planes[channel.id] = try PSDChannelCoder.decode(compression: compression, width: sourceW, height: sourceH,
                                                                 data: payload, largeDocument: isPSB, crop: crop)
            }
        }
        if readsMask, let gray = planes[-2], gray.count >= maskWidth * maskHeight {
            layer.maskImage = try PSDChannelCoder.maskImage(width: maskWidth, height: maskHeight, gray: gray)
        }
        guard width > 0, height > 0 else { return }
        let opaque = [UInt8](repeating: 255, count: width * height)
        let black = [UInt8](repeating: 0, count: width * height)
        let red = planes[0] ?? black
        let green = planes[1] ?? black
        let blue = planes[2] ?? black
        let alpha = planes[-1] ?? opaque
        guard red.count >= width * height, green.count >= width * height, blue.count >= width * height, alpha.count >= width * height else {
            throw PSDError.truncated
        }
        layer.image = try PSDChannelCoder.rgbaImage(width: width, height: height, red: red, green: green, blue: blue, alpha: alpha)
    }

    private static func assemble(_ raw: [RawLayer], canvas: CGSize, remainingPixels: Int,
                                 globalLightAngle: Double?) throws -> [PSDRecord] {
        var result: [PSDRecord] = []
        var groups: [UUID] = []
        // Each open folder's section-divider record, attached to the folder when it closes.
        var dividers: [PSDLayerExtras] = []
        var remaining = max(0, remainingPixels)
        for layer in raw {
            // Photoshop stores groups bottom-to-top: type 3 divider, then children, then the folder (type 1/2).
            if layer.section == 3 {
                groups.append(UUID())
                dividers.append(Self.extras(of: layer))
                continue
            }
            let isGroup = layer.section == 1 || layer.section == 2
            let id = isGroup ? (groups.popLast() ?? UUID()) : UUID()
            var record = PSDRecord(id: id, name: layer.name.isEmpty ? "Layer" : layer.name)
            record.parentID = groups.last
            record.isGroup = isGroup
            record.isVisible = !layer.hidden
            record.blendKey = isGroup && (layer.blendKey == "pass" || layer.blendKey == "norm") ? "pass" : layer.blendKey
            record.clipping = layer.clipping
            record.kind = kind(layer, isGroup: isGroup)
            record.croppedToCanvas = layer.cropped
            // Fill opacity stays apart from opacity: Photoshop applies it to the pixels but not to layer effects.
            record.opacity = Double(layer.opacity) / 255
            record.fillOpacity = Double(layer.fill) / 255
            record.locks = layer.locks
            var extras = Self.extras(of: layer)
            if isGroup { extras.sectionDividerExtras = dividers.popLast() }
            record.bounds = isGroup
                ? CGRect(origin: .zero, size: canvas)
                : CGRect(x: layer.left, y: layer.top,
                         width: max(0, layer.right - layer.left), height: max(0, layer.bottom - layer.top))
            record.image = isGroup ? nil : layer.image
            // A live shape's pixels take the place of Photoshop's, which were counted when read; a shape too large to
            // draw keeps Photoshop's pixels (or, without any, stays empty) rather than failing the file.
            let stored = layer.image.map { $0.width * $0.height } ?? 0
            do {
                if !isGroup, let live = try PSDVector.live(extra: layer.extra, canvas: canvas, remainingPixels: remaining + stored) {
                    record.image = live.image
                    record.bounds = live.bounds
                    record.shape = live.style
                    record.shapeNotes = live.notes
                    record.kind = .vector
                    extras.importedShape = live.style
                    remaining = max(0, remaining + stored - live.image.width * live.image.height)
                } else if record.image == nil, !isGroup, let raster = try PSDVector.raster(extra: layer.extra, canvas: canvas, remainingPixels: remaining) {
                    record.image = raster.image
                    record.bounds = raster.bounds
                    record.kind = .vector
                    remaining = max(0, remaining - raster.image.width * raster.image.height)
                }
            } catch is PSDVector.TooLargeToDraw {
                record.shapeNotes = [record.image == nil
                    ? "This shape is too large to draw within the document’s pixel budget, so the layer is empty. Its shape data is kept."
                    : "This shape is too large to draw again within the document’s pixel budget, so it keeps Photoshop’s pixels. Its shape data is kept."]
            }
            if record.kind == .vector, record.shape == nil, record.shapeNotes.isEmpty, let note = PSDVector.rasterNote(extra: layer.extra) {
                record.shapeNotes = [note]
            }
            // Type is decoded here and mapped onto Compositor text by the document builder; data that can't be read
            // leaves the layer as its pixels, its blocks kept.
            if record.kind == .text, let payload = layer.extra["TySh"] { record.typeLayer = try? PSDTypeReader.parse(payload) }
            // Effects become Compositor's by the document builder, which decides where they can be shown. Effects
            // that can't be read leave only a note; their blocks are kept either way.
            if let payload = layer.extra["lfx2"] {
                if let parsed = try? PSDEffectsReader.parse(payload, globalLightAngle: globalLightAngle) {
                    record.effects = parsed.effects.isEmpty ? nil : parsed.effects
                    record.effectNotes = parsed.notes
                } else {
                    record.effectNotes = ["This layer’s effects couldn’t be read, so they aren’t shown. The data is kept."]
                }
            }
            // A smart object's settings, placed against the layer's pixels; its contents are found among the
            // document's linked-layer entries once they have been read (`linkSmartObjects`).
            if !isGroup, record.shape == nil, record.kind != .text,
               let block = PSDSmartObjects.placementKeys.lazy.compactMap({ layer.extra[$0] }).first {
                record.kind = .smartObject
                if let info = try? PSDSmartObjects.placement(block, in: record.pixelTransform(canvas: canvas)) {
                    record.smartObject = LayerSmartObject(info: info, payload: nil)
                }
            }
            record.extras = extras
            record.mask = layer.maskImage
            record.maskOverBudget = layer.maskOverBudget
            if record.mask != nil {
                record.maskBounds = CGRect(x: layer.maskLeft, y: layer.maskTop,
                                           width: layer.maskRight - layer.maskLeft, height: layer.maskBottom - layer.maskTop)
            }
            record.maskEnabled = !layer.maskDisabled
            record.maskLinked = layer.maskLinked
            if !isGroup, let parsed = PSDAdjustments.parse(layer.extra) {
                record.adjustment = parsed.adjustment
                record.adjustmentNotes = parsed.notes
            }
            if record.adjustment != nil { record.kind = .adjustment }
            result.append(record)
        }
        guard groups.isEmpty else { throw PSDError.truncated }
        return result
    }

    /// Everything the record held beyond what Compositor models, every block included, in file order.
    private static func extras(of layer: RawLayer) -> PSDLayerExtras {
        PSDLayerExtras(blocks: layer.blocks, blendingRanges: layer.blendingRanges, blendKey: layer.blendKey,
                       flags: layer.flags, clippingByte: layer.clippingByte, fillerByte: layer.fillerByte,
                       maskFlags: layer.maskFlags, maskDefaultColor: layer.hasMask ? layer.maskDefault : nil,
                       maskParameters: layer.maskParameters, layerID: layer.layerID, colorLabel: layer.colorLabel,
                       nameSource: layer.nameSource, textIndex: layer.extra["TySh"].flatMap(PSDTypeReader.textIndex),
                       isBackground: layer.nameSource == "bgnd" && !layer.channels.contains { $0.id == -1 },
                       importedName: layer.name, trailingBytes: layer.trailingBytes)
    }

    private static func kind(_ layer: RawLayer, isGroup: Bool) -> PSDLayerKind {
        if isGroup { return .group }
        if layer.extra.keys.contains(where: { ["TySh", "tySh", "txt2"].contains($0) }) { return .text }
        if layer.extra.keys.contains(where: { Self.vectorKeys.contains($0) }) { return .vector }
        if layer.extra.keys.contains(where: { PSDSmartObjects.placementKeys.contains($0) }) { return .smartObject }
        if layer.extra.keys.contains(where: { ["lfx2", "lrFX", "lmfx"].contains($0) }) { return .effects }
        if layer.extra.keys.contains(where: { Self.adjustmentKeys.contains($0) }) { return .adjustment }
        return .raster
    }

    static let adjustmentKeys: Set<String> = [
        "levl", "curv", "hue2", "hue ", "expA", "grdm", "brit", "blnc", "nvrt",
        "thrs", "post", "mixr", "selc", "blwh", "phfl", "vibA", "clrL"
    ]

    /// Fill-layer contents (solid color, gradient, pattern). With vector data they are a shape layer's fill.
    static let fillKeys: Set<String> = ["SoCo", "GdFl", "PtFl"]
    /// Vector mask and shape origination blocks: a layer with one is a shape (or has a vector mask).
    static let vectorKeys: Set<String> = ["vmsk", "vsms", "vogk"]

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }
}

nonisolated private struct PSDCursor: Sendable {
    let data: Data
    var offset = 0

    mutating func need(_ count: Int) throws {
        guard offset >= 0, offset + count <= data.count else { throw PSDError.truncated }
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0 else { throw PSDError.truncated }
        try need(count)
        offset += count
    }

    mutating func u8() throws -> UInt8 {
        try need(1)
        defer { offset += 1 }
        return data[offset]
    }

    mutating func u16() throws -> UInt16 {
        try need(2)
        defer { offset += 2 }
        return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }

    mutating func u32() throws -> UInt32 {
        try need(4)
        defer { offset += 4 }
        return UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }

    mutating func u64() throws -> UInt64 {
        try need(8)
        defer { offset += 8 }
        return UInt64(data[offset]) << 56 | UInt64(data[offset + 1]) << 48 | UInt64(data[offset + 2]) << 40 | UInt64(data[offset + 3]) << 32 |
            UInt64(data[offset + 4]) << 24 | UInt64(data[offset + 5]) << 16 | UInt64(data[offset + 6]) << 8 | UInt64(data[offset + 7])
    }

    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    mutating func bytes(_ count: Int) throws -> Data {
        try need(count)
        defer { offset += count }
        return data.subdata(in: offset ..< offset + count)
    }

    mutating func string(_ count: Int) throws -> String {
        let bytes = try bytes(count)
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    /// A four-character code, one Latin-1 character per byte: any four bytes read back as a four-character string.
    mutating func code() throws -> String {
        String(try bytes(4).map { Character(Unicode.Scalar($0)) })
    }
}
