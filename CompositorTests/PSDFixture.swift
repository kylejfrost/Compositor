import CoreGraphics
import Foundation
@testable import Compositor

/// Builds tiny Photoshop files for reader tests. Not part of the app, and separate from the app's writer (`PSDWriter`),
/// so reader tests don't depend on it.
/// Beyond the modeled fields it writes `record.extras` (blocks, blending ranges, flags, clipping and filler bytes,
/// mask fields, trailing bytes; a folder's `sectionDividerExtras` on its divider), `fillOpacity`
/// (`iOpa`), `locks` (`lspf`), the color label (`lclr`), and `document.extras` resources, global layer mask info,
/// document-level blocks and a negative layer count. `largeDocument` writes a Large Document (PSB, version 2) file:
/// 8-byte section, channel and `PSDBlockFile.largeDocumentKeys` block lengths, 4-byte PackBits row counts. A block
/// signed `8B64` gets an 8-byte length in either version, as Photoshop files give it.
nonisolated enum PSDFixture {
    /// One more block written first in every layer record, before `luni`.
    struct AdditionalLayerInfo: Sendable {
        let key: String
        let payload: Data
    }

    static func data(_ document: PSDDocument, composite: CGImage, largeDocument: Bool = false,
                     additionalLayerInfo: AdditionalLayerInfo? = nil) throws -> Data {
        let width = document.width, height = document.height
        guard (1...30_000).contains(width), (1...30_000).contains(height) else { throw ImageImportError.tooLarge }
        var file = PSDBuffer()
        file.string("8BPS")
        file.u16(largeDocument ? 2 : 1)
        file.bytes(Data(count: 6))
        file.u16(4)
        file.u32(UInt32(height))
        file.u32(UInt32(width))
        file.u16(8)
        file.u16(3)
        file.u32(0)
        // Custom resources (`document.extras.resources`) follow the resolution, or replace it when they hold 1005.
        let custom = document.extras?.resources ?? []
        var resources = custom.contains { $0.id == 1005 } ? Data() : resolutionResource(document.resolution)
        resources.append(PSDBlockFile.encode(custom))
        file.u32(UInt32(resources.count))
        file.bytes(resources)
        let layers = try layerSection(document, largeDocument: largeDocument, additionalLayerInfo: additionalLayerInfo)
        if largeDocument { file.u64(UInt64(layers.count)) } else { file.u32(UInt32(layers.count)) }
        file.bytes(layers)
        try appendComposite(&file, composite, width: width, height: height, largeDocument: largeDocument)
        return file.data
    }

    private struct Prepared {
        var record: PSDRecord
        var isDivider: Bool
        var channels: [(id: Int16, payload: Data)]
        var top = 0, left = 0, bottom = 0, right = 0
        var maskTop = 0, maskLeft = 0, maskBottom = 0, maskRight = 0
    }

    private static func layerSection(_ document: PSDDocument, largeDocument: Bool,
                                     additionalLayerInfo: AdditionalLayerInfo?) throws -> Data {
        var prepared: [Prepared] = []
        func emit(_ parent: UUID?) throws {
            // File order is bottom-to-top. Photoshop groups are type 3, children, then type 1/2.
            for record in document.layers where record.parentID == parent {
                if record.isGroup {
                    prepared.append(try emptyLayer(name: "</Layer group>", blendKey: "norm", section: 3, parent: parent,
                                                   extras: record.extras?.sectionDividerExtras, largeDocument: largeDocument))
                    try emit(record.id)
                    prepared.append(try emptyLayer(name: record.name, blendKey: record.blendKey == "pass" ? "pass" : record.blendKey,
                                                   section: 1, visible: record.isVisible, opacity: record.opacity, parent: record.parentID, id: record.id, mask: record.mask, maskEnabled: record.maskEnabled,
                                                   extras: record.extras, clipping: record.clipping, largeDocument: largeDocument))
                } else {
                    prepared.append(try layer(record, largeDocument: largeDocument))
                }
            }
        }
        try emit(nil)
        guard prepared.count <= Int(Int16.max) else { throw ImageImportError.tooLarge }
        var records = PSDBuffer()
        records.i16(Int16(prepared.count) * (document.extras?.layerCountNegative == true ? -1 : 1))
        var payloads = PSDBuffer()
        for item in prepared {
            writeRecord(&records, item, largeDocument: largeDocument, additionalLayerInfo: additionalLayerInfo)
            for channel in item.channels { payloads.bytes(channel.payload) }
        }
        var info = PSDBuffer()
        info.bytes(records.data)
        info.bytes(payloads.data)
        if info.data.count % 2 == 1 { info.u8(0) }
        var section = PSDBuffer()
        if largeDocument { section.u64(UInt64(info.data.count)) } else { section.u32(UInt32(info.data.count)) }
        section.bytes(info.data)
        // Global layer mask info, then document-level blocks padded to four as Photoshop writes them.
        let globalMask = document.extras?.globalLayerMaskInfo ?? Data()
        section.u32(UInt32(globalMask.count))
        section.bytes(globalMask)
        section.bytes(encode(document.extras?.globalBlocks ?? [], alignment: 4, largeDocument: largeDocument))
        return section.data
    }

    private static func layer(_ record: PSDRecord, largeDocument: Bool) throws -> Prepared {
        let image = record.image
        let width = image?.width ?? 0
        let height = image?.height ?? 0
        let left = Int(record.bounds.minX.rounded())
        let top = Int(record.bounds.minY.rounded())
        var channels: [(id: Int16, payload: Data)] = []
        if let image, width > 0, height > 0 {
            let planes = try PSDChannelEncoder.straightPlanes(image)
            for (id, plane) in [(-1, planes.a), (0, planes.r), (1, planes.g), (2, planes.b)] as [(Int16, [UInt8])] {
                channels.append((id, channelPayload(plane, width: width, height: height, largeDocument: largeDocument)))
            }
        } else {
            channels = emptyChannels()
        }
        if let mask = record.mask {
            let plane = try PSDChannelEncoder.grayPlane(mask)
            channels.append((-2, channelPayload(plane, width: mask.width, height: mask.height, largeDocument: largeDocument)))
        }
        return Prepared(record: record, isDivider: false, channels: channels,
                        top: top, left: left, bottom: top + height, right: left + width,
                        maskTop: top, maskLeft: left,
                        maskBottom: top + (record.mask?.height ?? 0), maskRight: left + (record.mask?.width ?? 0))
    }

    private static func emptyLayer(name: String, blendKey: String, section: Int, visible: Bool = true, opacity: Double = 1, parent: UUID?, id: UUID? = nil, mask: CGImage? = nil, maskEnabled: Bool = true, extras: PSDLayerExtras? = nil, clipping: Bool = false,
                                   largeDocument: Bool) throws -> Prepared {
        var record = PSDRecord(id: id ?? UUID(), parentID: parent, name: name)
        record.extras = extras
        record.clipping = clipping
        record.isGroup = section != 3
        record.isVisible = visible
        record.opacity = opacity
        record.blendKey = blendKey
        record.mask = mask
        record.maskEnabled = maskEnabled
        record.kind = .group
        var channels = emptyChannels()
        var maskBottom = 0, maskRight = 0
        if let mask {
            let plane = try PSDChannelEncoder.grayPlane(mask)
            channels.append((-2, channelPayload(plane, width: mask.width, height: mask.height, largeDocument: largeDocument)))
            maskBottom = mask.height
            maskRight = mask.width
        }
        return Prepared(record: record, isDivider: section == 3, channels: channels,
                        maskBottom: maskBottom, maskRight: maskRight)
    }

    private static func emptyChannels() -> [(id: Int16, payload: Data)] {
        [(-1, Data([0, 0])), (0, Data([0, 0])), (1, Data([0, 0])), (2, Data([0, 0]))]
    }

    private static func channelPayload(_ plane: [UInt8], width: Int, height: Int, largeDocument: Bool) -> Data {
        var data = Data([0, 1]) // compression 1: PackBits
        data.append(rle(plane, width: width, height: height, largeDocument: largeDocument))
        return data
    }

    /// PackBits rows after their byte counts: two bytes each in a PSD, four in a PSB.
    private static func rle(_ plane: [UInt8], width: Int, height: Int, largeDocument: Bool) -> Data {
        let encoded = PSDChannelEncoder.rle(plane, width: width, height: height)
        guard largeDocument else { return encoded }
        var counts = Data()
        for row in 0..<height {
            counts.append(contentsOf: [0, 0, encoded[encoded.startIndex + row * 2], encoded[encoded.startIndex + row * 2 + 1]])
        }
        return counts + encoded.dropFirst(height * 2)
    }

    /// `PSDBlockFile.encode`, with the 8-byte lengths an `8B64` block has, and in a PSB `PSDBlockFile.largeDocumentKeys`.
    private static func encode(_ blocks: [PSDTaggedBlock], alignment: Int = 2, largeDocument: Bool) -> Data {
        var buffer = PSDBuffer()
        for block in blocks {
            buffer.string(block.signature)
            buffer.string(block.key)
            if block.signature == "8B64" || (largeDocument && PSDBlockFile.largeDocumentKeys.contains(block.key)) {
                buffer.u64(UInt64(block.data.count))
            } else { buffer.u32(UInt32(block.data.count)) }
            buffer.bytes(block.data)
            buffer.bytes(Data(count: (alignment - block.data.count % alignment) % alignment))
        }
        return buffer.data
    }

    private static func writeRecord(_ buffer: inout PSDBuffer, _ item: Prepared, largeDocument: Bool,
                                    additionalLayerInfo: AdditionalLayerInfo?) {
        let record = item.record
        buffer.i32(Int32(clamping: item.top))
        buffer.i32(Int32(clamping: item.left))
        buffer.i32(Int32(clamping: item.bottom))
        buffer.i32(Int32(clamping: item.right))
        buffer.u16(UInt16(item.channels.count))
        for channel in item.channels {
            buffer.i16(channel.id)
            if largeDocument { buffer.u64(UInt64(channel.payload.count)) } else { buffer.u32(UInt32(channel.payload.count)) }
        }
        buffer.string("8BIM")
        let key = (record.blendKey + "    ").prefix(4)
        buffer.string(String(key))
        buffer.u8(UInt8(clamping: Int((record.opacity * 255).rounded())))
        buffer.u8(record.clipping ? max(1, record.extras?.clippingByte ?? 1) : 0)
        buffer.u8(((record.extras?.flags ?? 0) & ~2) | (record.isVisible ? 0 : 2))
        buffer.u8(record.extras?.fillerByte ?? 0)
        let extra = extraData(item, largeDocument: largeDocument, additionalLayerInfo: additionalLayerInfo)
        buffer.u32(UInt32(extra.count))
        buffer.bytes(extra)
    }

    private static func extraData(_ item: Prepared, largeDocument: Bool, additionalLayerInfo: AdditionalLayerInfo?) -> Data {
        var extra = PSDBuffer()
        let extras = item.record.extras
        if item.record.mask != nil, item.maskRight > item.maskLeft, item.maskBottom > item.maskTop {
            let parameters = extras?.maskParameters ?? Data([0, 0])
            extra.u32(UInt32(18 + parameters.count))
            extra.i32(Int32(clamping: item.maskTop))
            extra.i32(Int32(clamping: item.maskLeft))
            extra.i32(Int32(clamping: item.maskBottom))
            extra.i32(Int32(clamping: item.maskRight))
            extra.u8(extras?.maskDefaultColor ?? 255)
            var flags: UInt8 = item.record.maskLinked ? 0 : 1
            if !item.record.maskEnabled { flags |= 2 }
            extra.u8(extras?.maskFlags ?? flags)
            extra.bytes(parameters)
        } else {
            extra.u32(0)
        }
        let ranges = extras?.blendingRanges ?? Data()
        extra.u32(UInt32(ranges.count))
        extra.bytes(ranges)
        let pascal = Array(item.record.name.utf8.prefix(255))
        extra.u8(UInt8(pascal.count))
        extra.bytes(Data(pascal))
        let nameBytes = 1 + pascal.count
        let pad = (4 - (nameBytes % 4)) % 4
        extra.bytes(Data(count: pad))
        // Name and section blocks are generated unless the record's own blocks carry them.
        let blocks = extras?.blocks ?? []
        func has(_ key: String) -> Bool { blocks.contains { $0.key == key } }
        if let additionalLayerInfo {
            writeAdditional(&extra, key: additionalLayerInfo.key, payload: additionalLayerInfo.payload, largeDocument: largeDocument)
        }
        if !has("luni") { writeAdditional(&extra, key: "luni", payload: luni(item.record.name), largeDocument: largeDocument) }
        if item.record.isGroup || item.isDivider, !has("lsct"), !has("lsdk") {
            let section: UInt32 = item.isDivider ? 3 : 1
            var payload = Data([0, 0, 0, UInt8(section)])
            payload.append(contentsOf: Array("8BIM".utf8))
            let blend = item.isDivider ? "norm" : ((item.record.blendKey == "pass" ? "pass" : item.record.blendKey) + "    ")
            payload.append(contentsOf: Array(blend.prefix(4).utf8))
            writeAdditional(&extra, key: "lsct", payload: payload, largeDocument: largeDocument)
        }
        // Fill, locks and color label from the record's fields, unless its own blocks already carry them; then
        // the record's blocks (`extras.blocks`) and trailing bytes verbatim.
        if item.record.fillOpacity != 1, !has("iOpa") {
            writeAdditional(&extra, key: "iOpa", payload: Data([UInt8(clamping: Int((item.record.fillOpacity * 255).rounded())), 0, 0, 0]),
                            largeDocument: largeDocument)
        }
        if !item.record.locks.isEmpty, !has("lspf") {
            var payload = Data()
            payload.appendUInt32(item.record.locks.rawValue)
            writeAdditional(&extra, key: "lspf", payload: payload, largeDocument: largeDocument)
        }
        if let label = extras?.colorLabel, label != .none, !has("lclr") {
            var payload = Data()
            payload.appendUInt16(label.rawValue)
            payload.append(Data(count: 6))
            writeAdditional(&extra, key: "lclr", payload: payload, largeDocument: largeDocument)
        }
        extra.bytes(encode(blocks, largeDocument: largeDocument))
        extra.bytes(extras?.trailingBytes ?? Data())
        return extra.data
    }

    private static func writeAdditional(_ buffer: inout PSDBuffer, key: String, payload: Data, largeDocument: Bool) {
        buffer.string("8BIM")
        buffer.string(key)
        if largeDocument, PSDBlockFile.largeDocumentKeys.contains(key) { buffer.u64(UInt64(payload.count)) }
        else { buffer.u32(UInt32(payload.count)) }
        buffer.bytes(payload)
        if payload.count % 2 == 1 { buffer.u8(0) }
    }

    private static func luni(_ name: String) -> Data {
        let units = Array(name.utf16)
        let count = UInt32(units.count)
        var data = Data()
        data.appendUInt32(count)
        for unit in units {
            data.append(UInt8(truncatingIfNeeded: unit >> 8))
            data.append(UInt8(truncatingIfNeeded: unit))
        }
        return data
    }

    private static func resolutionResource(_ resolution: Double) -> Data {
        var resource = PSDBuffer()
        resource.string("8BIM")
        resource.u16(1005)
        resource.u8(0)
        resource.u8(0)
        resource.u32(16)
        let fixed = UInt32((min(9600, max(1, resolution)) * 65536).rounded())
        resource.u32(fixed)
        resource.u16(1)
        resource.u16(1)
        resource.u32(fixed)
        resource.u16(1)
        resource.u16(1)
        return resource.data
    }

    /// Resource 1032's payload: `vertical`/`horizontal` are guide positions in document pixels.
    static func guidesResource(vertical: [Double] = [], horizontal: [Double] = []) -> PSDImageResource {
        var buffer = PSDBuffer()
        buffer.u32(1)
        buffer.u32(0)
        buffer.u32(0)
        buffer.u32(UInt32(vertical.count + horizontal.count))
        for position in vertical {
            buffer.i32(Int32((position * 32).rounded()))
            buffer.u8(0)
        }
        for position in horizontal {
            buffer.i32(Int32((position * 32).rounded()))
            buffer.u8(1)
        }
        return PSDImageResource(id: 1032, name: "", data: buffer.data)
    }

    /// Resource 1037: the global light angle, in degrees.
    static func globalLightAngleResource(_ angle: Int32) -> PSDImageResource {
        var buffer = PSDBuffer()
        buffer.i32(angle)
        return PSDImageResource(id: 1037, name: "", data: buffer.data)
    }

    /// Resource 1049: the global light altitude.
    static func globalLightAltitudeResource(_ altitude: Int32) -> PSDImageResource {
        var buffer = PSDBuffer()
        buffer.i32(altitude)
        return PSDImageResource(id: 1049, name: "", data: buffer.data)
    }

    /// Resource 1006: alpha channel names as Pascal strings.
    static func alphaChannelNamesResource(_ names: [String]) -> PSDImageResource {
        var buffer = PSDBuffer()
        for name in names {
            let bytes = Array(name.utf8)
            buffer.u8(UInt8(bytes.count))
            buffer.bytes(Data(bytes))
        }
        return PSDImageResource(id: 1006, name: "", data: buffer.data)
    }

    /// Resource 1045: alpha channel names as `u32 count` + UTF-16BE text.
    static func unicodeAlphaChannelNamesResource(_ names: [String]) -> PSDImageResource {
        var buffer = PSDBuffer()
        for name in names {
            let units = Array(name.utf16)
            buffer.u32(UInt32(units.count))
            for unit in units { buffer.u16(unit) }
        }
        return PSDImageResource(id: 1045, name: "", data: buffer.data)
    }

    /// Resource 1039: a minimal ICC profile whose `desc` tag holds `description`.
    static func iccProfileResource(description: String) -> PSDImageResource {
        var buffer = PSDBuffer()
        buffer.bytes(Data(count: 128))
        buffer.u32(1)
        buffer.string("desc")
        buffer.u32(144)
        let text = Data(description.utf8)
        buffer.u32(UInt32(12 + text.count))
        buffer.string("desc")
        buffer.bytes(Data(count: 4))
        buffer.u32(UInt32(text.count))
        buffer.bytes(text)
        return PSDImageResource(id: 1039, name: "", data: buffer.data)
    }

    // MARK: Type layers

    /// One style run of a fixture type layer: `length` UTF-16 units of the stored text (trailing `\r` included).
    struct TextRun {
        var length: Int
        var font: String
        var fontSize: Double
    }

    /// A `TySh` payload as Photoshop writes it: `u16 1 · 6×f64 transform · u16 50 · text descriptor · u16 1 · warp
    /// descriptor · 4×i32`. `text` is stored with Photoshop's trailing `\r`. EngineData holds one paragraph run with
    /// `justification`, and one style run (or `runs`) whose fill is `color` (`FillColor.Values = [1, r, g, b]`, of
    /// `fillType`). `leading` nil is Auto. `box` makes paragraph text with `BoxBounds` [l t r b]; nil is point text.
    static func typeToolBlock(text: String, font: String = "HelveticaNeue", fontSize: Double = 24,
                              color: (red: Double, green: Double, blue: Double) = (0, 0, 0), justification: Int = 0,
                              leading: Double? = nil, tracking: Double = 0, transform: [Double] = [1, 0, 0, 1, 0, 0],
                              box: CGRect? = nil, runs: [TextRun]? = nil, orientation: String = "Hrzn",
                              warpStyle: String = "warpNone", fillType: Int = 1) -> Data {
        let stored = text + "\r"
        let length = stored.utf16.count
        let styleRuns = runs ?? [TextRun(length: length, font: font, fontSize: fontSize)]
        var fonts: [String] = ["AdobeInvisFont"]
        for run in styleRuns where !fonts.contains(run.font) { fonts.append(run.font) }
        func number(_ value: Double) -> EngineValue { .number(value) }
        func fill() -> EngineValue {
            .dictionary([(key: "Type", value: .integer(fillType)),
                         (key: "Values", value: .array([number(1), number(color.red), number(color.green), number(color.blue)]))])
        }
        func styleData(_ run: TextRun) -> EngineValue {
            .dictionary([
                (key: "Font", value: .integer(fonts.firstIndex(of: run.font) ?? 0)),
                (key: "FontSize", value: number(run.fontSize)),
                (key: "FauxBold", value: .bool(false)),
                (key: "FauxItalic", value: .bool(false)),
                (key: "AutoLeading", value: .bool(leading == nil)),
                (key: "Leading", value: number(leading ?? 0.01)),
                (key: "HorizontalScale", value: number(1)),
                (key: "VerticalScale", value: number(1)),
                (key: "Tracking", value: .integer(Int(tracking))),
                (key: "FillColor", value: fill()),
            ])
        }
        let isBox = box != nil
        var cookie: [(key: String, value: EngineValue)] = [(key: "ShapeType", value: .integer(isBox ? 1 : 0))]
        if let box {
            cookie.append((key: "BoxBounds", value: .array([number(box.minX), number(box.minY), number(box.maxX), number(box.maxY)])))
        } else {
            cookie.append((key: "PointBase", value: .array([number(0), number(0)])))
        }
        let resources: EngineValue = .dictionary([
            (key: "FontSet", value: .array(fonts.map { name in
                .dictionary([(key: "Name", value: .string(name)), (key: "Script", value: .integer(0)),
                             (key: "FontType", value: .integer(1)), (key: "Synthetic", value: .integer(0))])
            })),
            (key: "StyleSheetSet", value: .array([.dictionary([
                (key: "Name", value: .string("Normal RGB")),
                (key: "StyleSheetData", value: .dictionary([
                    (key: "Font", value: .integer(0)), (key: "FontSize", value: number(12)),
                    (key: "AutoLeading", value: .bool(true)), (key: "Leading", value: number(0)),
                    (key: "Tracking", value: .integer(0)),
                    (key: "FillColor", value: .dictionary([(key: "Type", value: .integer(1)),
                                                           (key: "Values", value: .array([number(1), number(0), number(0), number(0)]))])),
                ])),
            ])])),
            (key: "ParagraphSheetSet", value: .array([.dictionary([
                (key: "Name", value: .string("Normal RGB")), (key: "DefaultStyleSheet", value: .integer(0)),
                (key: "Properties", value: .dictionary([(key: "Justification", value: .integer(0))])),
            ])])),
            (key: "TheNormalStyleSheet", value: .integer(0)),
            (key: "TheNormalParagraphSheet", value: .integer(0)),
        ])
        let engine: EngineValue = .dictionary([
            (key: "EngineDict", value: .dictionary([
                (key: "Editor", value: .dictionary([(key: "Text", value: .string(stored))])),
                (key: "ParagraphRun", value: .dictionary([
                    (key: "DefaultRunData", value: .dictionary([(key: "ParagraphSheet", value: .dictionary([
                        (key: "DefaultStyleSheet", value: .integer(0)), (key: "Properties", value: .dictionary([])),
                    ]))])),
                    (key: "RunArray", value: .array([.dictionary([(key: "ParagraphSheet", value: .dictionary([
                        (key: "DefaultStyleSheet", value: .integer(0)),
                        (key: "Properties", value: .dictionary([(key: "Justification", value: .integer(justification))])),
                    ]))])])),
                    (key: "RunLengthArray", value: .array([.integer(length)])),
                    (key: "IsJoinable", value: .integer(1)),
                ])),
                (key: "StyleRun", value: .dictionary([
                    (key: "DefaultRunData", value: .dictionary([(key: "StyleSheet", value: .dictionary([
                        (key: "StyleSheetData", value: .dictionary([])),
                    ]))])),
                    (key: "RunArray", value: .array(styleRuns.map { run in
                        .dictionary([(key: "StyleSheet", value: .dictionary([(key: "StyleSheetData", value: styleData(run))]))])
                    })),
                    (key: "RunLengthArray", value: .array(styleRuns.map { .integer($0.length) })),
                    (key: "IsJoinable", value: .integer(2)),
                ])),
                (key: "AntiAlias", value: .integer(4)),
                (key: "UseFractionalGlyphWidths", value: .bool(true)),
                (key: "Rendered", value: .dictionary([
                    (key: "Version", value: .integer(1)),
                    (key: "Shapes", value: .dictionary([
                        (key: "WritingDirection", value: .integer(orientation == "Vrtc" ? 2 : 0)),
                        (key: "Children", value: .array([.dictionary([
                            (key: "ShapeType", value: .integer(isBox ? 1 : 0)),
                            (key: "Procession", value: .integer(0)),
                            (key: "Lines", value: .dictionary([(key: "WritingDirection", value: .integer(0)),
                                                               (key: "Children", value: .array([]))])),
                            (key: "Cookie", value: .dictionary([(key: "Photoshop", value: .dictionary(cookie))])),
                        ])])),
                    ])),
                ])),
            ])),
            (key: "ResourceDict", value: resources),
            (key: "DocumentResources", value: resources),
        ])
        func rect(_ classID: String, _ r: CGRect) -> PSDDescriptorValue {
            .object(PSDDescriptor(classID: PSDKey(classID), items: [
                (key: "Left", value: .unitFloat(unit: "#Pnt", value: Double(r.minX))),
                (key: "Top ", value: .unitFloat(unit: "#Pnt", value: Double(r.minY))),
                (key: "Rght", value: .unitFloat(unit: "#Pnt", value: Double(r.maxX))),
                (key: "Btom", value: .unitFloat(unit: "#Pnt", value: Double(r.maxY))),
            ]))
        }
        let glyphs = box ?? CGRect(x: 0, y: -fontSize, width: fontSize * Double(text.count) * 0.6, height: fontSize * 1.2)
        let textDescriptor = PSDDescriptor(classID: "TxLr", items: [
            (key: "Txt ", value: .string(text)),
            (key: "textGridding", value: .enumerated(type: "textGridding", value: "None")),
            (key: "Ornt", value: .enumerated(type: "Ornt", value: PSDKey(orientation))),
            (key: "AntA", value: .enumerated(type: "Annt", value: "Anst")),
            (key: "bounds", value: rect("bounds", glyphs)),
            (key: "boundingBox", value: rect("boundingBox", glyphs)),
            (key: "TextIndex", value: .integer(0)),
            (key: "EngineData", value: .rawData(engineData(engine))),
        ])
        let warp = PSDDescriptor(classID: "warp", items: [
            (key: "warpStyle", value: .enumerated(type: "warpStyle", value: PSDKey(warpStyle))),
            (key: "warpValue", value: .double(warpStyle == "warpNone" ? 0 : 50)),
            (key: "warpPerspective", value: .double(0)),
            (key: "warpPerspectiveOther", value: .double(0)),
            (key: "warpRotate", value: .enumerated(type: "Ornt", value: "Hrzn")),
        ])
        var data = Data()
        data.appendUInt16(1)
        for value in transform { data.appendUInt64(value.bitPattern) }
        data.appendUInt16(50)
        data.append(PSDDescriptorWriter.block(textDescriptor))
        data.appendUInt16(1)
        data.append(PSDDescriptorWriter.block(warp))
        for _ in 0..<4 { data.appendUInt32(0) }
        return data
    }

    /// EngineData markup for `value`, laid out the way Photoshop writes it: tab-indented `/Key value` lines, UTF-16BE
    /// strings with a byte-order mark and `(`, `)` and `\` escaped byte by byte. Tests only; the PSD writer (Phase 4)
    /// brings the real serializer.
    static func engineData(_ value: EngineValue) -> Data {
        var data = Data("\n\n".utf8)
        func write(_ value: EngineValue, indent: Int) {
            let tabs = String(repeating: "\t", count: indent)
            switch value {
            case .dictionary(let items):
                data.append(contentsOf: Array("<<\n".utf8))
                for item in items {
                    data.append(contentsOf: Array("\(tabs)\t/\(item.key) ".utf8))
                    write(item.value, indent: indent + 1)
                    data.append(contentsOf: Array("\n".utf8))
                }
                data.append(contentsOf: Array("\(tabs)>>".utf8))
            case .array(let items):
                data.append(contentsOf: Array("[ ".utf8))
                for item in items {
                    write(item, indent: indent + 1)
                    data.append(contentsOf: Array(" ".utf8))
                }
                data.append(contentsOf: Array("]".utf8))
            case .string(let string):
                data.append(contentsOf: [0x28, 0xFE, 0xFF])
                for unit in string.utf16 {
                    for byte in [UInt8(unit >> 8), UInt8(unit & 0xFF)] {
                        if byte == 0x28 || byte == 0x29 || byte == 0x5C { data.append(0x5C) }
                        data.append(byte)
                    }
                }
                data.append(0x29)
            case .integer(let integer):
                data.append(contentsOf: Array("\(integer)".utf8))
            case .number(let number):
                data.append(contentsOf: Array(String(format: "%.5f", number).utf8))
            case .bool(let bool):
                data.append(contentsOf: Array((bool ? "true" : "false").utf8))
            case .tag(let tag):
                data.append(contentsOf: Array(tag.utf8))
            }
        }
        write(value, indent: 0)
        data.append(0)
        return data
    }

    private static func appendComposite(_ file: inout PSDBuffer, _ image: CGImage, width: Int, height: Int,
                                        largeDocument: Bool) throws {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let flattened = context.makeImage() else { throw ExportError.render }
        let planes = try PSDChannelEncoder.straightPlanes(flattened)
        file.u16(1)
        var counts = Data()
        var packed = Data()
        let countBytes = largeDocument ? 4 : 2
        for plane in [planes.r, planes.g, planes.b, planes.a] {
            let encoded = rle(plane, width: width, height: height, largeDocument: largeDocument)
            counts.append(encoded.prefix(height * countBytes))
            packed.append(encoded.dropFirst(height * countBytes))
        }
        file.bytes(counts)
        file.bytes(packed)
    }
}

nonisolated private struct PSDBuffer: Sendable {
    var data = Data()
    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { data.appendUInt16(value) }
    mutating func i16(_ value: Int16) { u16(UInt16(bitPattern: value)) }
    mutating func u32(_ value: UInt32) { data.appendUInt32(value) }
    mutating func u64(_ value: UInt64) { data.appendUInt64(value) }
    mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }
    mutating func bytes(_ value: Data) { data.append(value) }
    mutating func string(_ value: String) { data.append(contentsOf: Array(value.utf8)) }
}

extension Data {
    fileprivate mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
    fileprivate mutating func appendUInt64(_ value: UInt64) {
        appendUInt32(UInt32(truncatingIfNeeded: value >> 32))
        appendUInt32(UInt32(truncatingIfNeeded: value))
    }
    fileprivate mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}

nonisolated extension PSDFixture {
    /// `tySh`, a `typeToolBlock` payload, with the EngineData value at `path` (dot-separated dictionary keys and array
    /// indices, e.g. `EngineDict.ParagraphRun.RunLengthArray`) replaced by `value`, for type data Photoshop wouldn't
    /// write. The transform, the text descriptor's other items and the warp are kept as they are.
    static func typeToolBlock(_ tySh: Data, settingEngineData path: String, to value: EngineValue) throws -> Data {
        struct MissingPath: Error {}
        func setting(_ engine: EngineValue, _ keys: ArraySlice<Substring>) throws -> EngineValue {
            guard let key = keys.first else { return value }
            switch engine {
            case .dictionary(var items):
                guard let index = items.firstIndex(where: { $0.key == key }) else { throw MissingPath() }
                items[index].value = try setting(items[index].value, keys.dropFirst())
                return .dictionary(items)
            case .array(var items):
                guard let index = Int(key), items.indices.contains(index) else { throw MissingPath() }
                items[index] = try setting(items[index], keys.dropFirst())
                return .array(items)
            default:
                throw MissingPath()
            }
        }
        // `u16 1 · 6×f64 · u16 50` precede the text descriptor.
        var offset = 2 + 6 * 8 + 2
        let data = tySh.startIndex == 0 ? tySh : Data(tySh)
        var descriptor = try PSDDescriptorReader.readBlock(data, at: &offset)
        guard let index = descriptor.items.firstIndex(where: { $0.key == "EngineData" }),
              case .rawData(let bytes) = descriptor.items[index].value else { throw MissingPath() }
        let engine = try setting(try EngineDataParser.parse(bytes), path.split(separator: ".")[...])
        descriptor.items[index].value = .rawData(engineData(engine))
        var result = Data(data.prefix(2 + 6 * 8 + 2))
        result.append(PSDDescriptorWriter.block(descriptor))
        result.append(data.suffix(from: offset))
        return result
    }
}

// MARK: Layer effects

nonisolated extension PSDFixture {
    /// An `lfx2` payload as Photoshop writes it: `u32 0 · u32 16 · null {Scl , masterFXSwitch, effects…}`. Each
    /// effect is keyed as Photoshop keys it (`DrSh`, `dropShadowMulti`, `FrFX`, `ebbl`…) and built with
    /// `effect(_:…)` or one of its wrappers, or a `.list` of them for a `…Multi` key.
    static func effectsBlock(_ effects: [(key: String, value: PSDDescriptorValue)], masterFXSwitch: Bool = true,
                             scale: Double = 100) -> Data {
        var items: [(key: PSDKey, value: PSDDescriptorValue)] = [
            (key: "Scl ", value: .unitFloat(unit: "#Prc", value: scale)),
            (key: "masterFXSwitch", value: .bool(masterFXSwitch)),
        ]
        items += effects.map { (key: PSDKey($0.key), value: $0.value) }
        return PSDDescriptorWriter.block2(PSDDescriptor(classID: "null", items: items), version: 0)
    }

    /// One effect of class `classID` (`DrSh`, `IrSh`, `OrGl`, `SoFi`, `FrFX`, `ebbl`…): Photoshop's `enab`, `present`
    /// and `showInDialog` flags and blend mode, then `settings`.
    static func effect(_ classID: String, enabled: Bool = true, present: Bool = true, blendMode: String = "Nrml",
                       _ settings: [(key: String, value: PSDDescriptorValue)] = []) -> PSDDescriptorValue {
        var items: [(key: PSDKey, value: PSDDescriptorValue)] = [
            (key: "enab", value: .bool(enabled)),
            (key: "present", value: .bool(present)),
            (key: "showInDialog", value: .bool(true)),
            (key: "Md  ", value: .enumerated(type: "BlnM", value: PSDKey(blendMode))),
        ]
        items += settings.map { (key: PSDKey($0.key), value: $0.value) }
        return .object(PSDDescriptor(classID: PSDKey(classID), items: items))
    }

    /// An `RGBC` color, components 0–255 as Photoshop stores them.
    static func effectColor(_ red: Double, _ green: Double, _ blue: Double) -> PSDDescriptorValue {
        .object(PSDDescriptor(classID: "RGBC", items: [
            (key: "Rd  ", value: .double(red)), (key: "Grn ", value: .double(green)), (key: "Bl  ", value: .double(blue)),
        ]))
    }

    /// A drop (`DrSh`) or inner (`IrSh`) shadow. `angle` is `lagl`, `useGlobalLight` is `uglg`; `opacity` in percent,
    /// `color` 0–255. A drop shadow's `layerConceals` (Layer Knocks Out Drop Shadow) is left out when nil.
    static func shadowEffect(_ classID: String = "DrSh", enabled: Bool = true, present: Bool = true,
                             useGlobalLight: Bool = false, angle: Double = 120, distance: Double = 5, blur: Double = 5,
                             color: (Double, Double, Double) = (0, 0, 0), opacity: Double = 75,
                             layerConceals: Bool? = true) -> PSDDescriptorValue {
        var settings: [(key: String, value: PSDDescriptorValue)] = [
            (key: "Clr ", value: effectColor(color.0, color.1, color.2)),
            (key: "Opct", value: .unitFloat(unit: "#Prc", value: opacity)),
            (key: "uglg", value: .bool(useGlobalLight)),
            (key: "lagl", value: .unitFloat(unit: "#Ang", value: angle)),
            (key: "Dstn", value: .unitFloat(unit: "#Pxl", value: distance)),
            (key: "Ckmt", value: .unitFloat(unit: "#Pxl", value: 0)),
            (key: "blur", value: .unitFloat(unit: "#Pxl", value: blur)),
            (key: "Nose", value: .unitFloat(unit: "#Prc", value: 0)),
            (key: "AntA", value: .bool(false)),
        ]
        if classID == "DrSh", let layerConceals { settings.append((key: "layerConceals", value: .bool(layerConceals))) }
        return effect(classID, enabled: enabled, present: present, blendMode: "Mltp", settings)
    }

    /// A stroke (`FrFX`): `style` is `Styl` (`OutF`, `InsF`, `CtrF`), `paint` is `PntT` (`SClr`, `GrFl`, `Ptrn`).
    static func strokeEffect(enabled: Bool = true, style: String = "OutF", paint: String = "SClr", size: Double = 3,
                             color: (Double, Double, Double) = (0, 0, 0), opacity: Double = 100) -> PSDDescriptorValue {
        effect("FrFX", enabled: enabled, [
            (key: "Styl", value: .enumerated(type: "FStl", value: PSDKey(style))),
            (key: "PntT", value: .enumerated(type: "FrFl", value: PSDKey(paint))),
            (key: "Opct", value: .unitFloat(unit: "#Prc", value: opacity)),
            (key: "Sz  ", value: .unitFloat(unit: "#Pxl", value: size)),
            (key: "Clr ", value: effectColor(color.0, color.1, color.2)),
            (key: "overprint", value: .bool(false)),
        ])
    }

    /// A color overlay (`SoFi`).
    static func colorOverlayEffect(enabled: Bool = true, color: (Double, Double, Double) = (255, 0, 0),
                                   opacity: Double = 100) -> PSDDescriptorValue {
        effect("SoFi", enabled: enabled, [
            (key: "Clr ", value: effectColor(color.0, color.1, color.2)),
            (key: "Opct", value: .unitFloat(unit: "#Prc", value: opacity)),
        ])
    }

    /// An outer glow (`OrGl`): `size` is its `blur`.
    static func outerGlowEffect(enabled: Bool = true, size: Double = 5, color: (Double, Double, Double) = (255, 255, 190),
                                opacity: Double = 75) -> PSDDescriptorValue {
        effect("OrGl", enabled: enabled, blendMode: "Scrn", [
            (key: "Clr ", value: effectColor(color.0, color.1, color.2)),
            (key: "Opct", value: .unitFloat(unit: "#Prc", value: opacity)),
            (key: "GlwT", value: .enumerated(type: "BETE", value: "SfBL")),
            (key: "Ckmt", value: .unitFloat(unit: "#Pxl", value: 0)),
            (key: "blur", value: .unitFloat(unit: "#Pxl", value: size)),
            (key: "Nose", value: .unitFloat(unit: "#Prc", value: 0)),
            (key: "ShdN", value: .unitFloat(unit: "#Prc", value: 0)),
            (key: "AntA", value: .bool(false)),
            (key: "Inpr", value: .unitFloat(unit: "#Prc", value: 50)),
        ])
    }

    /// An inner glow (`IrGl`) as Photoshop writes one: an outer glow's keys and `glwS`, where it glows from (`SrcE` the
    /// edges, `SrcC` the center).
    static func innerGlowEffect(enabled: Bool = true, size: Double = 5, color: (Double, Double, Double) = (255, 255, 190),
                                opacity: Double = 75, source: String = "SrcE") -> PSDDescriptorValue {
        effect("IrGl", enabled: enabled, blendMode: "Scrn", [
            (key: "Clr ", value: effectColor(color.0, color.1, color.2)),
            (key: "Opct", value: .unitFloat(unit: "#Prc", value: opacity)),
            (key: "GlwT", value: .enumerated(type: "BETE", value: "SfBL")),
            (key: "Ckmt", value: .unitFloat(unit: "#Pxl", value: 0)),
            (key: "blur", value: .unitFloat(unit: "#Pxl", value: size)),
            (key: "Nose", value: .unitFloat(unit: "#Prc", value: 0)),
            (key: "ShdN", value: .unitFloat(unit: "#Prc", value: 0)),
            (key: "AntA", value: .bool(false)),
            (key: "Inpr", value: .unitFloat(unit: "#Prc", value: 50)),
            (key: "glwS", value: .enumerated(type: "IGSr", value: PSDKey(source))),
        ])
    }
}

// MARK: Smart objects

nonisolated extension PSDFixture {
    /// One linked-layer entry as Photoshop writes it into `lnk2` (the layout `PSDSmartObjects` reads).
    struct LinkedEntry {
        var kind = "liFD"
        var version: UInt32 = 7
        var uuid: String
        var fileName: String
        var fileType = "png "
        var creator = "\0\0\0\0"
        var data = Data()
        var openFile: PSDDescriptor? = nil
        /// `liFE`: the linked file's descriptor, its timestamp (version 4 on) and its size.
        var external = PSDDescriptor(classID: "ExternalFileLink", items: [(key: "fullPath", value: .string("/tmp/Linked.png"))])
        var timestamp = Data([0, 0, 0x07, 0xEA, 9, 23, 12, 30, 0x40, 0x3E, 0, 0, 0, 0, 0, 0])
        var externalFileSize: UInt64 = 0
        var childID = ""
        var modTime: Double = 0
        var lockState: UInt8 = 0
    }

    /// The bytes of `entry` (a block adds its `u64` length and padding).
    static func linkedEntry(_ entry: LinkedEntry) -> Data {
        func unicode(_ string: String, into buffer: inout PSDBuffer) {
            let units = Array(string.utf16)
            buffer.u32(UInt32(units.count))
            for unit in units { buffer.u16(unit) }
        }
        var buffer = PSDBuffer()
        buffer.string(entry.kind)
        buffer.u32(entry.version)
        let uuid = Array(entry.uuid.utf8)
        buffer.u8(UInt8(uuid.count))
        buffer.bytes(Data(uuid))
        // Photoshop counts the file name's trailing NUL.
        unicode(entry.fileName + "\0", into: &buffer)
        buffer.string(entry.fileType)
        buffer.string(entry.creator)
        buffer.data.appendUInt64(UInt64(entry.data.count))
        buffer.u8(entry.openFile == nil ? 0 : 1)
        if let openFile = entry.openFile { buffer.bytes(PSDDescriptorWriter.block(openFile)) }
        switch entry.kind {
        case "liFE":
            buffer.bytes(PSDDescriptorWriter.block(entry.external))
            if entry.version > 3 { buffer.bytes(entry.timestamp) }
            buffer.data.appendUInt64(entry.externalFileSize)
            if entry.version > 2 { buffer.bytes(entry.data) }
        case "liFA":
            buffer.bytes(Data(count: 8))
        default:
            buffer.bytes(entry.data)
        }
        if entry.version >= 5 { unicode(entry.childID, into: &buffer) }
        if entry.version >= 6 { buffer.data.appendUInt64(entry.modTime.bitPattern) }
        if entry.version >= 7 { buffer.u8(entry.lockState) }
        if entry.kind == "liFE", entry.version == 2 { buffer.bytes(entry.data) }
        return buffer.data
    }

    /// A document-level linked-layer block (`lnk2`, or `key`) holding `entries`.
    static func linkedLayersBlock(entries: [LinkedEntry], key: String = "lnk2") -> PSDTaggedBlock {
        PSDTaggedBlock(key: key, data: PSDBlockFile.encode(linkedEntries: entries.map(linkedEntry)))
    }

    /// A smart object's placed-layer blocks as Photoshop writes them, `PlLd` then `SoLd`: the contents named by `uuid`,
    /// `size` in their own pixels, placed on `quad` (document pixels: top-left, top-right, bottom-right, bottom-left).
    /// `type` 1 is vector contents, 2 raster.
    static func smartObjectBlocks(uuid: String, size: CGSize, quad: [CGPoint], type: Int32 = 2,
                                  placedID: String = "8f2c1a55-placed", resolution: Double = 72,
                                  nonAffine: [CGPoint]? = nil) -> [PSDTaggedBlock] {
        func numbers(_ points: [CGPoint]) -> PSDDescriptorValue {
            .list(points.flatMap { [PSDDescriptorValue.double(Double($0.x)), .double(Double($0.y))] })
        }
        func fraction(_ numerator: Int32) -> PSDDescriptorValue {
            .object(PSDDescriptor(classID: "null", items: [(key: "numerator", value: .integer(numerator)),
                                                          (key: "denominator", value: .integer(600))]))
        }
        let warp = PSDDescriptor(classID: "warp", items: [
            (key: "warpStyle", value: .enumerated(type: "warpStyle", value: "warpNone")),
            (key: "warpValue", value: .double(0)),
            (key: "warpPerspective", value: .double(0)),
            (key: "warpPerspectiveOther", value: .double(0)),
            (key: "warpRotate", value: .enumerated(type: "Ornt", value: "Hrzn")),
        ])
        let descriptor = PSDDescriptor(classID: "null", items: [
            (key: "Idnt", value: .string(uuid)),
            (key: "placed", value: .string(placedID)),
            (key: "PgNm", value: .integer(1)),
            (key: "totalPages", value: .integer(1)),
            (key: "Crop", value: .integer(1)),
            (key: "frameStep", value: fraction(0)),
            (key: "duration", value: fraction(0)),
            (key: "frameCount", value: .integer(1)),
            (key: "Annt", value: .integer(16)),
            (key: "Type", value: .integer(type)),
            (key: "Trnf", value: numbers(quad)),
            (key: "nonAffineTransform", value: numbers(nonAffine ?? quad)),
            (key: PSDKey("warp", explicitLength: true), value: .object(warp)),
            (key: "Sz  ", value: .object(PSDDescriptor(classID: "Pnt ", items: [
                (key: "Wdth", value: .double(Double(size.width))), (key: "Hght", value: .double(Double(size.height))),
            ]))),
            (key: "Rslt", value: .unitFloat(unit: "#Rsl", value: resolution)),
        ])
        var soLd = PSDBuffer()
        soLd.string("soLD")
        soLd.u32(4)
        soLd.bytes(PSDDescriptorWriter.block(descriptor))
        var plLd = PSDBuffer()
        plLd.string("plcL")
        plLd.u32(3)
        let id = Array(uuid.utf8)
        plLd.u8(UInt8(id.count))
        plLd.bytes(Data(id))
        for value in [UInt32(1), 1, 16, UInt32(type)] { plLd.u32(value) }
        for point in quad {
            plLd.data.appendUInt64(Double(point.x).bitPattern)
            plLd.data.appendUInt64(Double(point.y).bitPattern)
        }
        plLd.bytes(PSDDescriptorWriter.block2(warp, version: 0))
        while plLd.data.count % 4 != 0 { plLd.u8(0) }
        return [PSDTaggedBlock(key: "PlLd", data: plLd.data), PSDTaggedBlock(key: "SoLd", data: soLd.data)]
    }
}

// MARK: Vector shapes

nonisolated extension PSDFixture {
    /// A `vscg` payload as Photoshop writes a shape's fill: `key(4)` + `u32 16` + descriptor. `SoCo` carries
    /// `{Clr : RGBC}`, components 0–255; other keys (`GdFl`, `PtFl`) carry no single color.
    static func vectorContentBlock(key: String = "SoCo", red: Double, green: Double, blue: Double) -> Data {
        var data = Data(key.utf8)
        data.append(PSDDescriptorWriter.block(PSDDescriptor(classID: "null", items: [
            (key: "Clr ", value: effectColor(red, green, blue)),
        ])))
        return data
    }

    /// A `vogk` payload: `u32 1` + descriptor whose `keyDescriptorList` holds `items` (built with
    /// `rectangleOrigination` or `lineOrigination`).
    static func originationBlock(_ items: [PSDDescriptor]) -> Data {
        PSDDescriptorWriter.block2(PSDDescriptor(classID: "null", items: [
            (key: "keyDescriptorList", value: .list(items.map { .object($0) })),
        ]), version: 1)
    }

    /// One `keyDescriptorList` item for a rectangle (`type` 1, or 2 with `radii` top-left, top-right, bottom-right,
    /// bottom-left) or an ellipse (5), boxed by `rect` in document pixels.
    static func rectangleOrigination(type: Int32, rect: CGRect, radii: [Double] = [],
                                     invalidated: Bool? = nil) -> PSDDescriptor {
        var item = PSDDescriptor(classID: "null", items: [
            (key: "keyOriginType", value: .integer(type)),
            (key: "keyOriginResolution", value: .double(72)),
            (key: "keyOriginShapeBBox", value: originBox(rect)),
        ])
        if radii.count == 4 {
            let corners = zip(["topLeft", "topRight", "bottomRight", "bottomLeft"], radii).map {
                (key: PSDKey($0), value: PSDDescriptorValue.unitFloat(unit: "#Pxl", value: $1))
            }
            item.items.append((key: "keyOriginRRectRadii", value: .object(PSDDescriptor(classID: "radii", items:
                [(key: "unitValueQuadVersion", value: .integer(1))] + corners))))
        }
        if let invalidated { item.items.append((key: "keyShapeInvalidated", value: .bool(invalidated))) }
        return item
    }

    /// One `keyDescriptorList` item for a line (`keyOriginType` 4) from `start` to `end` in document pixels, `weight`
    /// pixels thick, with optional arrowheads.
    static func lineOrigination(start: CGPoint, end: CGPoint, weight: Double, arrowStart: Bool = false,
                                arrowEnd: Bool = false) -> PSDDescriptor {
        func point(_ p: CGPoint) -> PSDDescriptorValue {
            .object(PSDDescriptor(classID: "Pnt ", items: [
                (key: "Hrzn", value: .unitFloat(unit: "#Pxl", value: Double(p.x))),
                (key: "Vrtc", value: .unitFloat(unit: "#Pxl", value: Double(p.y))),
            ]))
        }
        let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                         width: abs(end.x - start.x), height: abs(end.y - start.y)).insetBy(dx: -weight / 2, dy: -weight / 2)
        return PSDDescriptor(classID: "null", items: [
            (key: "keyOriginType", value: .integer(4)),
            (key: "keyOriginResolution", value: .double(72)),
            (key: "keyOriginShapeBBox", value: originBox(box)),
            (key: "keyOriginLineStart", value: point(start)),
            (key: "keyOriginLineEnd", value: point(end)),
            (key: "keyOriginLineWeight", value: .unitFloat(unit: "#Pxl", value: weight)),
            (key: "keyOriginLineArrowSt", value: .bool(arrowStart)),
            (key: "keyOriginLineArrowEnd", value: .bool(arrowEnd)),
            (key: "keyOriginLineArrWdth", value: .double(500)),
            (key: "keyOriginLineArrLngth", value: .double(1000)),
            (key: "keyOriginLineArrConc", value: .integer(0)),
        ])
    }

    /// A `vstk` payload (`u32 16` + `strokeStyle`) in Photoshop's key order: a solid `color` stroke `width` pixels
    /// wide, `alignment` `strokeStyleAlignCenter`/`…Inside`/`…Outside`, `dashes` its dash set, `opacity` in percent.
    static func shapeStrokeBlock(enabled: Bool, fillEnabled: Bool = true, width: Double,
                                 color: (Double, Double, Double), alignment: String = "strokeStyleAlignCenter",
                                 dashes: [Double] = [], opacity: Double = 100) -> Data {
        func enumerated(_ type: String, _ value: String) -> PSDDescriptorValue {
            .enumerated(type: PSDKey(type), value: PSDKey(value))
        }
        return PSDDescriptorWriter.block(PSDDescriptor(classID: "strokeStyle", items: [
            (key: "strokeStyleVersion", value: .integer(2)),
            (key: "strokeEnabled", value: .bool(enabled)),
            (key: "fillEnabled", value: .bool(fillEnabled)),
            (key: "strokeStyleLineWidth", value: .unitFloat(unit: "#Pxl", value: width)),
            (key: "strokeStyleLineDashOffset", value: .unitFloat(unit: "#Pnt", value: 0)),
            (key: "strokeStyleMiterLimit", value: .double(100)),
            (key: "strokeStyleLineCapType", value: enumerated("strokeStyleLineCapType", "strokeStyleButtCap")),
            (key: "strokeStyleLineJoinType", value: enumerated("strokeStyleLineJoinType", "strokeStyleMiterJoin")),
            (key: "strokeStyleLineAlignment", value: enumerated("strokeStyleLineAlignment", alignment)),
            (key: "strokeStyleScaleLock", value: .bool(false)),
            (key: "strokeStyleStrokeAdjust", value: .bool(false)),
            (key: "strokeStyleLineDashSet", value: .list(dashes.map { .unitFloat(unit: "#Nne", value: $0) })),
            (key: "strokeStyleBlendMode", value: enumerated("BlnM", "Nrml")),
            (key: "strokeStyleOpacity", value: .unitFloat(unit: "#Prc", value: opacity)),
            (key: "strokeStyleContent", value: .object(PSDDescriptor(classID: "solidColorLayer", items: [
                (key: "Clr ", value: effectColor(color.0, color.1, color.2)),
            ]))),
            (key: "strokeStyleResolution", value: .double(72)),
        ]))
    }

    private static func originBox(_ rect: CGRect) -> PSDDescriptorValue {
        func pixels(_ value: CGFloat) -> PSDDescriptorValue { .unitFloat(unit: "#Pxl", value: Double(value)) }
        return .object(PSDDescriptor(classID: "unitRect", items: [
            (key: "unitValueQuadVersion", value: .integer(1)),
            (key: "Top ", value: pixels(rect.minY)), (key: "Left", value: pixels(rect.minX)),
            (key: "Btom", value: pixels(rect.maxY)), (key: "Rght", value: pixels(rect.maxX)),
        ]))
    }
}

// MARK: Vector paths and transformed shapes

nonisolated extension PSDFixture {
    /// A `vmsk`/`vsms` payload for a `canvas`-sized document: `u32 3`, `u32 flags` (1 inverted, 4 disabled), the
    /// path-fill and initial-fill records, then each polygon of `subpaths` as a length record (closed, or open when
    /// `open`) and its sharp knots. Points are document pixels, written as 8.24 fractions of the canvas.
    static func vectorPathBlock(canvas: CGSize, subpaths: [[CGPoint]], open: Bool = false, flags: UInt32 = 0) -> Data {
        var buffer = PSDBuffer()
        buffer.u32(3)
        buffer.u32(flags)
        func record(_ type: Int16, _ fields: (inout PSDBuffer) -> Void) {
            var body = PSDBuffer()
            fields(&body)
            buffer.i16(type)
            buffer.bytes(body.data + Data(count: 24 - body.data.count))
        }
        func fraction(_ value: CGFloat, of length: CGFloat) -> Int32 {
            Int32((Double(value) / Double(length) * 0x1000000).rounded())
        }
        record(6) { _ in }
        record(8) { _ in }
        for polygon in subpaths {
            record(open ? 3 : 0) { $0.i16(Int16(polygon.count)) }
            for point in polygon {
                record(open ? 4 : 1) { body in
                    for _ in 0..<3 {
                        body.i32(fraction(point.y, of: canvas.height))
                        body.i32(fraction(point.x, of: canvas.width))
                    }
                }
            }
        }
        return buffer.data
    }

    /// The corners of `rect` (top-left, top-right, bottom-right, bottom-left), turned `degrees` about its center:
    /// clockwise on screen, where y grows downward.
    static func turnedCorners(of rect: CGRect, degrees: Double) -> [CGPoint] {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let turn = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: degrees * .pi / 180).translatedBy(x: -center.x, y: -center.y)
        return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)].map { $0.applying(turn) }
    }

    /// The outline filled for a line: a `weight`-thick rectangle from `start` to `end`.
    static func lineOutline(start: CGPoint, end: CGPoint, weight: CGFloat) -> [CGPoint] {
        let length = hypot(end.x - start.x, end.y - start.y)
        let across = CGPoint(x: -(end.y - start.y) / length * weight / 2, y: (end.x - start.x) / length * weight / 2)
        return [CGPoint(x: start.x + across.x, y: start.y + across.y), CGPoint(x: end.x + across.x, y: end.y + across.y),
                CGPoint(x: end.x - across.x, y: end.y - across.y), CGPoint(x: start.x - across.x, y: start.y - across.y)]
    }

    /// A `vogk` item (from `rectangleOrigination` or `lineOrigination`) with Free Transform's records added: `Trnf`
    /// holding `transform` (`xx xy yx yy tx ty`) and `keyOriginBoxCorners` holding `corners` (A to D, document pixels).
    /// Its `keyOriginShapeBBox` is left as it was.
    static func transformedOrigination(_ item: PSDDescriptor, transform: CGAffineTransform? = nil,
                                       corners: [CGPoint]? = nil) -> PSDDescriptor {
        var item = item
        if let transform {
            item.items.append((key: "Trnf", value: .object(PSDDescriptor(classID: "Trnf", items: [
                (key: "xx", value: .double(Double(transform.a))), (key: "xy", value: .double(Double(transform.b))),
                (key: "yx", value: .double(Double(transform.c))), (key: "yy", value: .double(Double(transform.d))),
                (key: "tx", value: .double(Double(transform.tx))), (key: "ty", value: .double(Double(transform.ty))),
            ]))))
        }
        if let corners {
            let points = zip(["rectangleCornerA", "rectangleCornerB", "rectangleCornerC", "rectangleCornerD"], corners).map {
                (key: PSDKey($0), value: PSDDescriptorValue.object(PSDDescriptor(classID: "Pnt ", items: [
                    (key: "Hrzn", value: .double(Double($1.x))), (key: "Vrtc", value: .double(Double($1.y))),
                ])))
            }
            item.items.append((key: "keyOriginBoxCorners", value: .object(PSDDescriptor(classID: "null", items: points))))
        }
        return item
    }
}

// MARK: Records the document writer doesn't make

nonisolated extension PSDFixture {
    /// `tySh`, a `typeToolBlock` payload, with its text descriptor's `TextIndex` (which of the document's `Txt2`
    /// texts is the layer's) set to `index`. The transform, the other items and the warp are kept as they are.
    static func typeToolBlock(_ tySh: Data, textIndex index: Int32) throws -> Data {
        struct MissingTextIndex: Error {}
        // `u16 1 · 6×f64 · u16 50` precede the text descriptor.
        var offset = 2 + 6 * 8 + 2
        let data = tySh.startIndex == 0 ? tySh : Data(tySh)
        var descriptor = try PSDDescriptorReader.readBlock(data, at: &offset)
        guard let item = descriptor.items.firstIndex(where: { $0.key == "TextIndex" }) else { throw MissingTextIndex() }
        descriptor.items[item].value = .integer(index)
        var result = Data(data.prefix(2 + 6 * 8 + 2))
        result.append(PSDDescriptorWriter.block(descriptor))
        result.append(data.suffix(from: offset))
        return result
    }

    /// A file of one opaque layer covering the canvas in `color` (red, green, blue), written with exactly `channels`
    /// (raw) and `blocks` after its `luni`: records `data(_:composite:)` doesn't write, such as Photoshop's
    /// Background as the corpus stores it — no transparency channel (-1), `lnsr` `bgnd` and `lspf` 13.
    static func singleLayerFile(width: Int, height: Int, name: String, color: [UInt8], channels: [Int16] = [-1, 0, 1, 2],
                                blocks: [PSDTaggedBlock]) -> Data {
        let pixels = width * height
        var record = PSDBuffer()
        record.i32(0)
        record.i32(0)
        record.i32(Int32(height))
        record.i32(Int32(width))
        record.u16(UInt16(channels.count))
        var payloads = Data()
        for id in channels {
            let value = id >= 0 && Int(id) < color.count ? color[Int(id)] : 255
            record.i16(id)
            record.u32(UInt32(2 + pixels))
            payloads.append(contentsOf: [0, 0])
            payloads.append(Data(repeating: value, count: pixels))
        }
        record.string("8BIMnorm")
        record.bytes(Data([255, 0, 0, 0]))
        var extra = PSDBuffer()
        extra.u32(0)
        extra.u32(0)
        let pascal = Array(name.utf8.prefix(255))
        extra.u8(UInt8(pascal.count))
        extra.bytes(Data(pascal))
        extra.bytes(Data(count: (4 - (1 + pascal.count) % 4) % 4))
        writeAdditional(&extra, key: "luni", payload: luni(name), largeDocument: false)
        extra.bytes(PSDBlockFile.encode(blocks))
        record.u32(UInt32(extra.data.count))
        record.bytes(extra.data)
        var info = PSDBuffer()
        info.i16(1)
        info.bytes(record.data)
        info.bytes(payloads)
        if info.data.count % 2 == 1 { info.u8(0) }
        var section = PSDBuffer()
        section.u32(UInt32(info.data.count))
        section.bytes(info.data)
        section.u32(0)
        var file = PSDBuffer()
        file.string("8BPS")
        file.u16(1)
        file.bytes(Data(count: 6))
        file.u16(3)
        file.u32(UInt32(height))
        file.u32(UInt32(width))
        file.u16(8)
        file.u16(3)
        file.u32(0)
        file.u32(0)
        file.u32(UInt32(section.data.count))
        file.bytes(section.data)
        // The composite, raw: red, green and blue planes.
        file.u16(0)
        for channel in 0..<3 { file.bytes(Data(repeating: channel < color.count ? color[channel] : 0, count: pixels)) }
        return file.data
    }
}

// MARK: Adjustments

nonisolated extension PSDFixture {
    /// `expA`: `u16 version (1)`, then exposure, offset and gamma as big-endian `f32`.
    static func exposureBlock(exposure: Float, offset: Float, gamma: Float, version: UInt16 = 1) -> Data {
        var block = PSDBuffer()
        block.u16(version)
        for value in [exposure, offset, gamma] { block.u32(value.bitPattern) }
        return block.data
    }

    /// `blnc`: shadows, midtones and highlights, each cyan–red, magenta–green and yellow–blue as `i16` (−100…100), then
    /// a byte for Preserve Luminosity and a pad byte: Photoshop refuses a file whose `blnc` is 19 bytes long.
    static func colorBalanceBlock(shadows: [Int16], midtones: [Int16], highlights: [Int16], preserveLuminosity: Bool) -> Data {
        var block = PSDBuffer()
        for value in shadows + midtones + highlights { block.i16(value) }
        block.u8(preserveLuminosity ? 1 : 0)
        block.u8(0)
        return block.data
    }

    /// `blwh`: `u32 16` and a descriptor of each color's percentage (`Rd  `, `Yllw`, `Grn `, `Cyn `, `Bl  `, `Mgnt`),
    /// `useTint`, the tint as an `RGBC` color (0–255) and the preset Photoshop names.
    static func blackWhiteBlock(reds: Int32, yellows: Int32, greens: Int32, cyans: Int32, blues: Int32, magentas: Int32,
                                tint: Bool, tintColor: (Double, Double, Double)) -> Data {
        let items: [(key: PSDKey, value: PSDDescriptorValue)] = [
            (key: "Rd  ", value: .integer(reds)), (key: "Yllw", value: .integer(yellows)),
            (key: "Grn ", value: .integer(greens)), (key: "Cyn ", value: .integer(cyans)),
            (key: "Bl  ", value: .integer(blues)), (key: "Mgnt", value: .integer(magentas)),
            (key: "useTint", value: .bool(tint)),
            (key: "tintColor", value: effectColor(tintColor.0, tintColor.1, tintColor.2)),
            (key: "bwPresetKind", value: .integer(1)),
            (key: "blackAndWhitePresetFileName", value: .string("")),
        ]
        return PSDDescriptorWriter.block(PSDDescriptor(classID: "null", items: items))
    }

    /// `grdm`: `u16 version · u8 reversed · u8 dithered`; from version 3 the 4-byte interpolation `method` (`Gcls`,
    /// `Perc`, `Lnr `, `Smoo`); the gradient's name (`u32` count, UTF-16), the color stops (`i32 location` 0…4096 ·
    /// `i32 midpoint` % · `u16` color space (0, RGB) · 4×`u16` components · 2 pad bytes), the transparency stops
    /// (`i32 location · i32 midpoint · u16 opacity`), then Photoshop's fixed tail: expansion (2), interpolation, length
    /// (32), mode, seed, show transparency, vector color, roughness, color model, minimum and maximum colors and two
    /// unused bytes. `stops` colors are 16-bit RGB.
    static func gradientMapBlock(stops: [(location: Int32, color: (UInt16, UInt16, UInt16))], reversed: Bool = false,
                                 version: UInt16 = 1, method: String = "Gcls") -> Data {
        var block = PSDBuffer()
        block.u16(version)
        block.u8(reversed ? 1 : 0)
        block.u8(0)
        if version >= 3 { for byte in method.utf8.prefix(4) { block.u8(byte) } }
        let name = Array("Custom".utf16)
        block.u32(UInt32(name.count))
        for unit in name { block.u16(unit) }
        block.u16(UInt16(stops.count))
        for stop in stops {
            block.i32(stop.location)
            block.i32(50)
            block.u16(0)
            for component in [stop.color.0, stop.color.1, stop.color.2, 0] { block.u16(component) }
            block.u16(0)
        }
        block.u16(2)
        for location: Int32 in [0, 4096] {
            block.i32(location)
            block.i32(50)
            block.u16(255)
        }
        for value: UInt16 in [2, 4096, 32, 0] { block.u16(value) }
        block.u32(0)
        block.u16(0)
        block.u16(0)
        block.u32(2048)
        block.u16(3)
        for _ in 0..<4 { block.u16(0) }
        for _ in 0..<4 { block.u16(100) }
        block.u16(0)
        return block.data
    }
}
