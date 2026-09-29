import CoreGraphics
import Foundation

// How a project stores a document's Photoshop data (format 10). Scalars and small byte fields sit in the manifest
// (bytes as base64); tagged blocks, image resources and linked-layer entries go to sidecar files under `psd/` in
// Photoshop's own wire format (`PSDBlockFile`), so the manifest stays small and the bytes stay exactly as read.

/// A layer's Photoshop data as the manifest stores it. In memory it is the whole `PSDLayerExtras`; in the manifest
/// its blocks are the sidecar `psd/<layer UUID>.blocks` (`blocksFile`), and a folder's section divider is a nested
/// `sectionDivider` record whose blocks are `psd/<layer UUID>.divider.blocks`.
nonisolated struct PSDLayerExtrasRecord: Codable, Equatable, Sendable {
    var extras: PSDLayerExtras
    /// Nil when the layer has no blocks. Loading fills `extras.blocks` from it.
    var blocksFile: String?
    var dividerBlocksFile: String?

    /// Inline byte fields are capped so thousands of layers still fit the 4 MiB manifest.
    static let maximumInlineBytes = 4_096
    static let maximumTrailingBytes = 65_536
    /// Each blocks sidecar.
    static let maximumBlocksFileBytes = 64 * 1024 * 1024

    init(_ extras: PSDLayerExtras, layerID: UUID) {
        self.extras = extras
        blocksFile = extras.blocks.isEmpty ? nil : Self.blocksFile(for: layerID)
        dividerBlocksFile = (extras.sectionDividerExtras?.blocks.isEmpty ?? true) ? nil : Self.dividerBlocksFile(for: layerID)
    }

    static func blocksFile(for id: UUID) -> String { "\(id.uuidString).blocks" }
    static func dividerBlocksFile(for id: UUID) -> String { "\(id.uuidString).divider.blocks" }

    /// Names are exactly the layer's own; every field is within what a Photoshop layer record can hold.
    func isValid(for id: UUID) -> Bool {
        guard blocksFile == nil || blocksFile == Self.blocksFile(for: id),
              dividerBlocksFile == nil || dividerBlocksFile == Self.dividerBlocksFile(for: id),
              Self.isValid(extras) else { return false }
        guard let divider = extras.sectionDividerExtras else { return dividerBlocksFile == nil }
        return divider.sectionDividerExtras == nil && Self.isValid(divider)
    }

    private static func isValid(_ extras: PSDLayerExtras) -> Bool {
        fitsInlineLimits(extras)
            && PSDBlockFile.isFourCharacterCode(extras.blendKey)
            && extras.nameSource.map(PSDBlockFile.isFourCharacterCode) ?? true
            && extras.importedTextAnchor.map { $0.x.isFinite && $0.y.isFinite } ?? true
    }

    static let maximumImportedNameBytes = 16_384
    static let maximumPlaceholderBytes = 256

    /// Whether every inline field of `extras` (and of its section divider) is within the manifest's size limits:
    /// the part of validity a large Photoshop file, rather than a damaged project, can fail.
    static func fitsInlineLimits(_ extras: PSDLayerExtras) -> Bool {
        extras.blendingRanges.count <= maximumInlineBytes
            && (extras.maskParameters?.count ?? 0) <= maximumInlineBytes
            && extras.trailingBytes.count <= maximumTrailingBytes
            && (extras.importedName?.utf8.count ?? 0) <= maximumImportedNameBytes
            && (extras.placeholder?.utf8.count ?? 0) <= maximumPlaceholderBytes
            && (extras.sectionDividerExtras.map(fitsInlineLimits) ?? true)
    }

    /// `extras` cut down to what a project can store, so an imported Photoshop file can always be saved: byte fields
    /// over the inline limits are dropped (named in `dropped`, for a conversion note), a blend key or name source
    /// that isn't a four-character code is replaced, and an over-long imported name is shortened. A divider nested
    /// in the divider is dropped.
    static func fitted(_ extras: PSDLayerExtras) -> (extras: PSDLayerExtras, dropped: [String]) {
        var extras = extras
        var dropped: [String] = []
        if extras.blendingRanges.count > maximumInlineBytes {
            extras.blendingRanges = Data(); dropped.append("blending ranges")
        }
        if (extras.maskParameters?.count ?? 0) > maximumInlineBytes {
            extras.maskParameters = nil; dropped.append("mask parameters")
        }
        if extras.trailingBytes.count > maximumTrailingBytes {
            extras.trailingBytes = Data(); dropped.append("unrecognized record data")
        }
        if !PSDBlockFile.isFourCharacterCode(extras.blendKey) {
            extras.blendKey = "norm"; dropped.append("blend key")
        }
        if let source = extras.nameSource, !PSDBlockFile.isFourCharacterCode(source) { extras.nameSource = nil }
        extras.importedName = extras.importedName.map { truncated($0, toBytes: maximumImportedNameBytes) }
        if (extras.placeholder?.utf8.count ?? 0) > maximumPlaceholderBytes { extras.placeholder = nil }
        if let anchor = extras.importedTextAnchor, !anchor.x.isFinite || !anchor.y.isFinite { extras.importedTextAnchor = nil }
        if var divider = extras.sectionDividerExtras {
            divider.sectionDividerExtras = nil
            let fitted = fitted(divider)
            extras.sectionDividerExtras = fitted.extras
            dropped += fitted.dropped.map { "folder-end \($0)" }
        }
        return (extras, dropped)
    }

    /// `string` cut at a character boundary to at most `limit` UTF-8 bytes.
    static func truncated(_ string: String, toBytes limit: Int) -> String {
        guard string.utf8.count > limit else { return string }
        var result = ""
        var count = 0
        for character in string {
            let size = character.utf8.count
            guard count + size <= limit else { break }
            result.append(character)
            count += size
        }
        return result
    }

    /// Whether `blocks` can be written to a sidecar and read back unchanged.
    static func canWrite(_ blocks: [PSDTaggedBlock]) -> Bool {
        blocks.allSatisfy {
            PSDBlockFile.blockSignatures.contains($0.signature) && PSDBlockFile.isFourCharacterCode($0.key)
                && $0.data.count <= Int(UInt32.max)
        }
    }

    private enum Key: String, CodingKey {
        case blocksFile, blendingRanges, blendKey, flags, clippingByte, fillerByte, maskFlags, maskDefaultColor,
             maskParameters, layerID, colorLabel, nameSource, importedName, importedText, importedTextAnchor,
             importedTextIsBox, importedShape, importedEffects, importedSmartObject, importedVisible, placeholder,
             trailingBytes, sectionDivider, textIndex, isBackground, importedMaskRect, importedShapeFrame,
             importedShapeCanvas, importedTextPixelSize
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        (extras, blocksFile) = try Self.decodeFields(container)
        if container.contains(.sectionDivider), try !container.decodeNil(forKey: .sectionDivider) {
            let nested = try container.nestedContainer(keyedBy: Key.self, forKey: .sectionDivider)
            // A divider belongs to a folder; it has none of its own.
            guard !nested.contains(.sectionDivider) else {
                throw DecodingError.dataCorruptedError(forKey: .sectionDivider, in: nested, debugDescription: "Nested divider")
            }
            let (divider, file) = try Self.decodeFields(nested)
            extras.sectionDividerExtras = divider
            dividerBlocksFile = file
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try Self.encodeFields(extras, blocksFile: blocksFile, to: &container)
        if let divider = extras.sectionDividerExtras {
            var nested = container.nestedContainer(keyedBy: Key.self, forKey: .sectionDivider)
            try Self.encodeFields(divider, blocksFile: dividerBlocksFile, to: &nested)
        }
    }

    /// Everything but the blocks (a sidecar) and the divider (nested). Defaults are left out.
    private static func encodeFields(_ extras: PSDLayerExtras, blocksFile: String?, to c: inout KeyedEncodingContainer<Key>) throws {
        try c.encodeIfPresent(blocksFile, forKey: .blocksFile)
        if !extras.blendingRanges.isEmpty { try c.encode(extras.blendingRanges, forKey: .blendingRanges) }
        try c.encode(extras.blendKey, forKey: .blendKey)
        if extras.flags != 0 { try c.encode(extras.flags, forKey: .flags) }
        if extras.clippingByte != 0 { try c.encode(extras.clippingByte, forKey: .clippingByte) }
        if extras.fillerByte != 0 { try c.encode(extras.fillerByte, forKey: .fillerByte) }
        try c.encodeIfPresent(extras.maskFlags, forKey: .maskFlags)
        try c.encodeIfPresent(extras.maskDefaultColor, forKey: .maskDefaultColor)
        try c.encodeIfPresent(extras.maskParameters, forKey: .maskParameters)
        try c.encodeIfPresent(extras.importedMaskRect, forKey: .importedMaskRect)
        try c.encodeIfPresent(extras.layerID, forKey: .layerID)
        if extras.colorLabel != .none { try c.encode(extras.colorLabel, forKey: .colorLabel) }
        try c.encodeIfPresent(extras.nameSource, forKey: .nameSource)
        try c.encodeIfPresent(extras.textIndex, forKey: .textIndex)
        if extras.isBackground { try c.encode(true, forKey: .isBackground) }
        try c.encodeIfPresent(extras.importedName, forKey: .importedName)
        try c.encodeIfPresent(extras.importedText, forKey: .importedText)
        try c.encodeIfPresent(extras.importedTextAnchor, forKey: .importedTextAnchor)
        try c.encodeIfPresent(extras.importedTextPixelSize, forKey: .importedTextPixelSize)
        try c.encodeIfPresent(extras.importedTextIsBox, forKey: .importedTextIsBox)
        try c.encodeIfPresent(extras.importedShape, forKey: .importedShape)
        try c.encodeIfPresent(extras.importedShapeFrame, forKey: .importedShapeFrame)
        try c.encodeIfPresent(extras.importedShapeCanvas, forKey: .importedShapeCanvas)
        try c.encodeIfPresent(extras.importedEffects, forKey: .importedEffects)
        try c.encodeIfPresent(extras.importedSmartObject, forKey: .importedSmartObject)
        try c.encodeIfPresent(extras.importedVisible, forKey: .importedVisible)
        try c.encodeIfPresent(extras.placeholder, forKey: .placeholder)
        if !extras.trailingBytes.isEmpty { try c.encode(extras.trailingBytes, forKey: .trailingBytes) }
    }

    private static func decodeFields(_ c: KeyedDecodingContainer<Key>) throws -> (PSDLayerExtras, String?) {
        let maskRect = try c.decodeIfPresent(CGRect.self, forKey: .importedMaskRect)
        if let maskRect, ![maskRect.origin.x, maskRect.origin.y, maskRect.size.width, maskRect.size.height].allSatisfy({ $0.isFinite && $0 >= 0 }) {
            throw DecodingError.dataCorruptedError(forKey: .importedMaskRect, in: c, debugDescription: "Invalid mask rectangle")
        }
        let shapeFrame = try c.decodeIfPresent(CGRect.self, forKey: .importedShapeFrame)
        if let shapeFrame, ![shapeFrame.origin.x, shapeFrame.origin.y, shapeFrame.size.width, shapeFrame.size.height].allSatisfy(\.isFinite)
            || shapeFrame.size.width < 0 || shapeFrame.size.height < 0 {
            throw DecodingError.dataCorruptedError(forKey: .importedShapeFrame, in: c, debugDescription: "Invalid shape frame")
        }
        let textPixelSize = try c.decodeIfPresent(CGSize.self, forKey: .importedTextPixelSize)
        if let textPixelSize, !((1...DocumentLimits.maxSideExtent).contains(textPixelSize.width)
                                  && (1...DocumentLimits.maxSideExtent).contains(textPixelSize.height)) {
            throw DecodingError.dataCorruptedError(forKey: .importedTextPixelSize, in: c, debugDescription: "Invalid text pixel size")
        }
        let shapeCanvas = try c.decodeIfPresent(CGSize.self, forKey: .importedShapeCanvas)
        if let shapeCanvas, !(shapeCanvas.width.isFinite && shapeCanvas.height.isFinite && shapeCanvas.width > 0 && shapeCanvas.height > 0) {
            throw DecodingError.dataCorruptedError(forKey: .importedShapeCanvas, in: c, debugDescription: "Invalid shape canvas")
        }
        let extras = PSDLayerExtras(
            blendingRanges: try c.decodeIfPresent(Data.self, forKey: .blendingRanges) ?? Data(),
            blendKey: try c.decode(String.self, forKey: .blendKey),
            flags: try c.decodeIfPresent(UInt8.self, forKey: .flags) ?? 0,
            clippingByte: try c.decodeIfPresent(UInt8.self, forKey: .clippingByte) ?? 0,
            fillerByte: try c.decodeIfPresent(UInt8.self, forKey: .fillerByte) ?? 0,
            maskFlags: try c.decodeIfPresent(UInt8.self, forKey: .maskFlags),
            maskDefaultColor: try c.decodeIfPresent(UInt8.self, forKey: .maskDefaultColor),
            maskParameters: try c.decodeIfPresent(Data.self, forKey: .maskParameters),
            importedMaskRect: maskRect,
            layerID: try c.decodeIfPresent(Int32.self, forKey: .layerID),
            colorLabel: try c.decodeIfPresent(LayerColorLabel.self, forKey: .colorLabel) ?? .none,
            nameSource: try c.decodeIfPresent(String.self, forKey: .nameSource),
            textIndex: try c.decodeIfPresent(Int32.self, forKey: .textIndex),
            isBackground: try c.decodeIfPresent(Bool.self, forKey: .isBackground) ?? false,
            importedName: try c.decodeIfPresent(String.self, forKey: .importedName),
            importedText: try c.decodeIfPresent(LayerTextStyle.self, forKey: .importedText),
            importedTextAnchor: try c.decodeIfPresent(CGPoint.self, forKey: .importedTextAnchor),
            importedTextPixelSize: textPixelSize,
            importedTextIsBox: try c.decodeIfPresent(Bool.self, forKey: .importedTextIsBox),
            importedShape: try c.decodeIfPresent(LayerShapeStyle.self, forKey: .importedShape),
            importedShapeFrame: shapeFrame,
            importedShapeCanvas: shapeCanvas,
            importedEffects: try c.decodeIfPresent(LayerEffects.self, forKey: .importedEffects),
            importedSmartObject: try c.decodeIfPresent(SmartObjectInfo.self, forKey: .importedSmartObject),
            importedVisible: try c.decodeIfPresent(Bool.self, forKey: .importedVisible),
            placeholder: try c.decodeIfPresent(String.self, forKey: .placeholder),
            trailingBytes: try c.decodeIfPresent(Data.self, forKey: .trailingBytes) ?? Data())
        return (extras, try c.decodeIfPresent(String.self, forKey: .blocksFile))
    }
}

/// What a project stores of a Photoshop file's data at most (`ProjectStore`): a PSD can hold more, and an import notes
/// what only a Photoshop file can keep (`PSDDocumentBuilder.makeImport`).
nonisolated struct PSDProjectLimits: Sendable {
    /// Each layer's blocks sidecar, and its folder divider's.
    var layerBlocksBytes = PSDLayerExtrasRecord.maximumBlocksFileBytes
    var resourcesBytes = PSDDocumentExtrasRecord.maximumResourcesBytes
    var documentBlocksBytes = PSDDocumentExtrasRecord.maximumBlocksBytes
    var linkedBytes = PSDDocumentExtrasRecord.maximumLinkedBytes
    /// Each smart object's contents, and all of them together.
    var smartObjectBytes = SmartObjectFileRecord.maximumBytes
    var smartObjectTotalBytes = SmartObjectFileRecord.maximumTotalBytes
}

/// A document's Photoshop data as the manifest stores it: resources in `psd/document.resources`, document-level
/// blocks in `psd/document.blocks` (4-byte aligned, as Photoshop writes them), linked-layer entries no smart object
/// refers to in `psd/document.linked` (a `lnk2` payload); the rest inline.
nonisolated struct PSDDocumentExtrasRecord: Codable, Equatable, Sendable {
    var extras: PSDDocumentExtras
    var resourcesFile: String?
    var blocksFile: String?
    var linkedFile: String?

    static let resourcesFileName = "document.resources"
    static let blocksFileName = "document.blocks"
    static let linkedFileName = "document.linked"
    static let maximumResourcesBytes = 64 * 1024 * 1024
    static let maximumBlocksBytes = 256 * 1024 * 1024
    static let maximumLinkedBytes = 512 * 1024 * 1024
    static let maximumInlineBytes = 65_536

    init(_ extras: PSDDocumentExtras) {
        self.extras = extras
        resourcesFile = extras.resources.isEmpty ? nil : Self.resourcesFileName
        blocksFile = extras.globalBlocks.isEmpty ? nil : Self.blocksFileName
        linkedFile = extras.orphanLinkedEntries.isEmpty ? nil : Self.linkedFileName
    }

    var isValid: Bool {
        (resourcesFile == nil || resourcesFile == Self.resourcesFileName)
            && (blocksFile == nil || blocksFile == Self.blocksFileName)
            && (linkedFile == nil || linkedFile == Self.linkedFileName)
            && Self.fitsInlineLimits(extras)
            && (1...56).contains(extras.channelCount)
            && [extras.globalLightAngle, extras.globalLightAltitude].allSatisfy { $0?.isFinite ?? true }
            && (extras.linkedBlockIndex.map { (0...Int(Int32.max)).contains($0) } ?? true)
    }

    static let maximumAlphaChannels = 56
    static let maximumAlphaNameBytes = 1_024
    static let maximumICCDescriptionBytes = 16_384
    static let maximumSourceFileNameBytes = 4_096

    /// Whether every inline field is within the manifest's size limits (the part of validity a large Photoshop file,
    /// rather than a damaged project, can fail).
    static func fitsInlineLimits(_ extras: PSDDocumentExtras) -> Bool {
        extras.globalLayerMaskInfo.count <= maximumInlineBytes
            && extras.colorModeData.count <= maximumInlineBytes
            && extras.alphaChannelNames.count <= maximumAlphaChannels
            && extras.alphaChannelNames.allSatisfy { $0.utf8.count <= maximumAlphaNameBytes }
            && (extras.iccProfileDescription?.utf8.count ?? 0) <= maximumICCDescriptionBytes
            && (extras.sourceFileName?.utf8.count ?? 0) <= maximumSourceFileNameBytes
    }

    /// `extras` cut down to what a project can store (see `PSDLayerExtrasRecord.fitted`): over-limit byte fields
    /// are dropped and named in `dropped`; names and descriptions are shortened; the channel count is kept in range.
    static func fitted(_ extras: PSDDocumentExtras) -> (extras: PSDDocumentExtras, dropped: [String]) {
        var extras = extras
        var dropped: [String] = []
        if extras.globalLayerMaskInfo.count > maximumInlineBytes {
            extras.globalLayerMaskInfo = Data(); dropped.append("global layer mask info")
        }
        if extras.colorModeData.count > maximumInlineBytes {
            extras.colorModeData = Data(); dropped.append("color mode data")
        }
        extras.channelCount = min(56, max(1, extras.channelCount))
        extras.alphaChannelNames = extras.alphaChannelNames.prefix(maximumAlphaChannels).map {
            PSDLayerExtrasRecord.truncated($0, toBytes: maximumAlphaNameBytes)
        }
        extras.iccProfileDescription = extras.iccProfileDescription.map {
            PSDLayerExtrasRecord.truncated($0, toBytes: maximumICCDescriptionBytes)
        }
        extras.sourceFileName = extras.sourceFileName.map { PSDLayerExtrasRecord.truncated($0, toBytes: maximumSourceFileNameBytes) }
        if !(extras.globalLightAngle?.isFinite ?? true) { extras.globalLightAngle = nil }
        if !(extras.globalLightAltitude?.isFinite ?? true) { extras.globalLightAltitude = nil }
        return (extras, dropped)
    }

    /// Whether the resources can be written to a sidecar and read back unchanged.
    static func canWrite(_ resources: [PSDImageResource]) -> Bool {
        resources.allSatisfy {
            PSDBlockFile.resourceSignatures.contains($0.signature)
                && ($0.name.data(using: .macOSRoman)?.count).map { $0 <= 255 } ?? false
                && $0.data.count <= Int(UInt32.max)
        }
    }

    private enum Key: String, CodingKey {
        case resourcesFile, blocksFile, linkedFile, globalLayerMaskInfo, colorModeData, channelCount,
             alphaChannelNames, iccProfileDescription, globalLightAngle, globalLightAltitude, sourceFileName,
             layerCountNegative, linkedBlockIndex, importedTextIndices, canvasSize, canvasTransform
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        resourcesFile = try c.decodeIfPresent(String.self, forKey: .resourcesFile)
        blocksFile = try c.decodeIfPresent(String.self, forKey: .blocksFile)
        linkedFile = try c.decodeIfPresent(String.self, forKey: .linkedFile)
        extras = PSDDocumentExtras(
            globalLayerMaskInfo: try c.decodeIfPresent(Data.self, forKey: .globalLayerMaskInfo) ?? Data(),
            colorModeData: try c.decodeIfPresent(Data.self, forKey: .colorModeData) ?? Data(),
            channelCount: try c.decode(Int.self, forKey: .channelCount),
            alphaChannelNames: try c.decodeIfPresent([String].self, forKey: .alphaChannelNames) ?? [],
            iccProfileDescription: try c.decodeIfPresent(String.self, forKey: .iccProfileDescription),
            globalLightAngle: try c.decodeIfPresent(Double.self, forKey: .globalLightAngle),
            globalLightAltitude: try c.decodeIfPresent(Double.self, forKey: .globalLightAltitude),
            sourceFileName: try c.decodeIfPresent(String.self, forKey: .sourceFileName),
            layerCountNegative: try c.decodeIfPresent(Bool.self, forKey: .layerCountNegative) ?? false)
        extras.linkedBlockIndex = try c.decodeIfPresent(Int.self, forKey: .linkedBlockIndex)
        extras.importedTextIndices = try c.decodeIfPresent([Int32].self, forKey: .importedTextIndices)
        extras.canvasSize = try c.decodeIfPresent(CGSize.self, forKey: .canvasSize)
        if let size = extras.canvasSize, !((1...DocumentLimits.maxSideExtent).contains(size.width)
                                           && (1...DocumentLimits.maxSideExtent).contains(size.height)) {
            throw DecodingError.dataCorruptedError(forKey: .canvasSize, in: c, debugDescription: "Invalid canvas size")
        }
        if let values = try c.decodeIfPresent([Double].self, forKey: .canvasTransform) {
            guard values.count == 6, values.allSatisfy(\.isFinite) else {
                throw DecodingError.dataCorruptedError(forKey: .canvasTransform, in: c, debugDescription: "Invalid canvas transform")
            }
            extras.canvasTransform = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encodeIfPresent(resourcesFile, forKey: .resourcesFile)
        try c.encodeIfPresent(blocksFile, forKey: .blocksFile)
        try c.encodeIfPresent(linkedFile, forKey: .linkedFile)
        if !extras.globalLayerMaskInfo.isEmpty { try c.encode(extras.globalLayerMaskInfo, forKey: .globalLayerMaskInfo) }
        if !extras.colorModeData.isEmpty { try c.encode(extras.colorModeData, forKey: .colorModeData) }
        try c.encode(extras.channelCount, forKey: .channelCount)
        if !extras.alphaChannelNames.isEmpty { try c.encode(extras.alphaChannelNames, forKey: .alphaChannelNames) }
        try c.encodeIfPresent(extras.iccProfileDescription, forKey: .iccProfileDescription)
        try c.encodeIfPresent(extras.globalLightAngle, forKey: .globalLightAngle)
        try c.encodeIfPresent(extras.globalLightAltitude, forKey: .globalLightAltitude)
        try c.encodeIfPresent(extras.sourceFileName, forKey: .sourceFileName)
        if extras.layerCountNegative { try c.encode(true, forKey: .layerCountNegative) }
        try c.encodeIfPresent(extras.linkedBlockIndex, forKey: .linkedBlockIndex)
        try c.encodeIfPresent(extras.importedTextIndices, forKey: .importedTextIndices)
        try c.encodeIfPresent(extras.canvasSize, forKey: .canvasSize)
        try c.encodeIfPresent(extras.canvasTransform.map { [$0.a, $0.b, $0.c, $0.d, $0.tx, $0.ty].map(Double.init) },
                              forKey: .canvasTransform)
    }
}
