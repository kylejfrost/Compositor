import CoreGraphics
import Foundation

// What a Photoshop file carries beyond what Compositor models, kept so the file can be written back with every
// feature intact. Layers keep their additional-layer-info blocks and record fields; documents keep their image
// resources, global layer mask info and document-level blocks. Everything is stored as Photoshop wrote it.

/// One additional-layer-info block: `signature` (`8BIM` or `8B64`), four-character `key`, and the payload bytes
/// exactly as stored (without the length field or trailing pad).
nonisolated struct PSDTaggedBlock: Equatable, Sendable {
    var signature: String
    var key: String
    var data: Data

    init(signature: String = "8BIM", key: String, data: Data) {
        self.signature = signature
        self.key = key
        self.data = data
    }
}

/// A layer's Photoshop data. `blocks` is every additional-layer-info block in file order, `luni`, `lsct` and `lsdk`
/// included, so an untouched layer's blocks can be written back byte for byte. Blocks Compositor also decodes
/// (`lspf`, `lclr`, `iOpa`, `lyid`, `lnsr`…) stay in `blocks` as read; the decoded values sit alongside, and a
/// writer regenerates a block only when the layer no longer matches it (`importedName` for `luni`, for example).
nonisolated struct PSDLayerExtras: Equatable, Sendable {
    var blocks: [PSDTaggedBlock]
    /// The layer record's blending ranges, verbatim (without their length field).
    var blendingRanges: Data
    /// The layer record's four-character blend key, including keys Compositor has no mode for (`diss`, `dkCl`…).
    var blendKey: String
    /// The layer record's flags byte: 0x01 transparency protected, 0x02 hidden, 0x08/0x10 pixel data irrelevant.
    var flags: UInt8
    /// The layer record's clipping byte (0 base, 1 clipped) and the filler byte after the flags, as stored.
    var clippingByte: UInt8
    var fillerByte: UInt8
    /// The layer mask's flags byte (0x01 position relative, 0x02 disabled, 0x08 from render, 0x10 parameters follow).
    var maskFlags: UInt8?
    var maskDefaultColor: UInt8?
    /// Every mask-data byte after the flags byte, verbatim: mask parameters when flag 0x10 is set, then the real
    /// user mask fields (36-byte form) and padding.
    var maskParameters: Data?
    /// Where the rectangle Photoshop stored the mask in lies within the imported mask's own pixels. Photoshop trims
    /// a mask to what differs from `maskDefaultColor`; import pads it with that color to cover its layer as well,
    /// so an untouched mask crops back to exactly the pixels Photoshop stored (its document position is the mask's
    /// own origin plus this origin). Cropping loses nothing only while every pixel outside the rectangle is still
    /// the default color, which a writer checks. Nil when the mask's pixels are the stored rectangle itself.
    var importedMaskRect: CGRect?
    /// Photoshop's layer ID (`lyid`). Nil on a duplicate, so a writer allocates a new one.
    var layerID: Int32?
    var colorLabel: LayerColorLabel
    /// `lnsr`: where the layer's name came from (`layr`, `rend`, `lset`…).
    var nameSource: String?
    /// A type layer's `TySh` `TextIndex`: which of the document's `Txt2` texts is the layer's.
    var textIndex: Int32?
    /// Photoshop's Background: named by `lnsr` `bgnd`, with no transparency channel (-1).
    var isBackground: Bool
    /// The name as imported (`luni`, else the Pascal name): a different name means `luni` must be regenerated.
    var importedName: String?
    /// What import made of the layer's text, anchor and shape: a writer compares the live layer with these to
    /// tell an untouched Photoshop layer (write its blocks back) from an edited one (regenerate them).
    var importedText: LayerTextStyle?
    /// The first baseline (point text) or box top-left (paragraph text) in unit coordinates of the layer transform.
    var importedTextAnchor: CGPoint?
    /// The size of the pixels import read the text with: Photoshop's type data places the text on those, which Image
    /// Size may have resampled since (scaling `importedText` with them).
    var importedTextPixelSize: CGSize?
    var importedTextIsBox: Bool?
    var importedShape: LayerShapeStyle?
    /// On a layer whose shape (or vector mask) blocks Compositor keeps without modeling them: where its pixels lay on
    /// the document at import, and the size of the canvas the blocks' fractions are of. The blocks describe the layer
    /// only while it is still there, on such a canvas, its pixels unedited (a pixel edit clears the frame).
    var importedShapeFrame: CGRect?
    var importedShapeCanvas: CGSize?
    var importedEffects: LayerEffects?
    /// The smart object's settings as imported: equal to the live ones (and `contentsRevision` 0) while untouched.
    var importedSmartObject: SmartObjectInfo?
    var importedVisible: Bool?
    /// Set on layers kept only to be written back, such as `"adjustment:brit"` for an adjustment Compositor lacks.
    var placeholder: String?
    /// Bytes of the layer's extra-data region after the last block that could be framed (an unknown signature, or
    /// padding), verbatim.
    var trailingBytes: Data
    /// On a folder: the hidden section-divider record Photoshop stores below the folder's contents (`lsct` type 3,
    /// its own `luni`, `lyid`, `lclr`…), kept whole so the folder writes back as it was read.
    var sectionDividerExtras: PSDLayerExtras? {
        get { dividerStorage.first }
        set { dividerStorage = newValue.map { [$0] } ?? [] }
    }
    /// Heap storage for `sectionDividerExtras` (a struct can't hold an optional of itself inline).
    private var dividerStorage: [PSDLayerExtras]

    init(blocks: [PSDTaggedBlock] = [], blendingRanges: Data = Data(), blendKey: String = "norm", flags: UInt8 = 0,
         clippingByte: UInt8 = 0, fillerByte: UInt8 = 0, maskFlags: UInt8? = nil, maskDefaultColor: UInt8? = nil,
         maskParameters: Data? = nil, importedMaskRect: CGRect? = nil, layerID: Int32? = nil, colorLabel: LayerColorLabel = .none,
         nameSource: String? = nil, textIndex: Int32? = nil, isBackground: Bool = false,
         importedName: String? = nil, importedText: LayerTextStyle? = nil,
         importedTextAnchor: CGPoint? = nil, importedTextPixelSize: CGSize? = nil, importedTextIsBox: Bool? = nil,
         importedShape: LayerShapeStyle? = nil,
         importedShapeFrame: CGRect? = nil, importedShapeCanvas: CGSize? = nil,
         importedEffects: LayerEffects? = nil, importedSmartObject: SmartObjectInfo? = nil,
         importedVisible: Bool? = nil, placeholder: String? = nil,
         trailingBytes: Data = Data(), sectionDividerExtras: PSDLayerExtras? = nil) {
        self.blocks = blocks
        self.blendingRanges = blendingRanges
        self.blendKey = blendKey
        self.flags = flags
        self.clippingByte = clippingByte
        self.fillerByte = fillerByte
        self.maskFlags = maskFlags
        self.maskDefaultColor = maskDefaultColor
        self.maskParameters = maskParameters
        self.importedMaskRect = importedMaskRect
        self.layerID = layerID
        self.colorLabel = colorLabel
        self.nameSource = nameSource
        self.textIndex = textIndex
        self.isBackground = isBackground
        self.importedName = importedName
        self.importedText = importedText
        self.importedTextAnchor = importedTextAnchor
        self.importedTextPixelSize = importedTextPixelSize
        self.importedTextIsBox = importedTextIsBox
        self.importedShape = importedShape
        self.importedShapeFrame = importedShapeFrame
        self.importedShapeCanvas = importedShapeCanvas
        self.importedEffects = importedEffects
        self.importedSmartObject = importedSmartObject
        self.importedVisible = importedVisible
        self.placeholder = placeholder
        self.trailingBytes = trailingBytes
        self.dividerStorage = sectionDividerExtras.map { [$0] } ?? []
    }

    /// The same data for a new Photoshop layer (a duplicate): no layer ID and no `lyid` block, here or on the
    /// section divider, so a writer allocates new ones.
    var withoutLayerIDs: PSDLayerExtras {
        var extras = self
        extras.layerID = nil
        extras.blocks.removeAll { $0.key == "lyid" }
        extras.sectionDividerExtras = sectionDividerExtras?.withoutLayerIDs
        return extras
    }

    /// The payload of the first block with `key`.
    func block(_ key: String) -> Data? {
        blocks.first { $0.key == key }?.data
    }

    /// Whether any block has one of `keys`.
    func hasBlock(in keys: Set<String>) -> Bool {
        blocks.contains { keys.contains($0.key) }
    }

    /// Photoshop layer-effects blocks.
    static let effectKeys: Set<String> = ["lfx2", "lrFX", "lmfx"]
}

/// One image resource: `signature` is `8BIM` for all but a few old third-party resources.
nonisolated struct PSDImageResource: Equatable, Sendable {
    var id: UInt16
    var name: String
    var data: Data
    var signature = "8BIM"
}

/// A document's Photoshop data, in file order.
nonisolated struct PSDDocumentExtras: Equatable, Sendable {
    /// Every image resource, 1005 (resolution) included.
    var resources: [PSDImageResource] = []
    /// Document-level tagged blocks after the global layer mask info (`Patt`, `Txt2`, `lnk2`, `FMsk`…).
    var globalBlocks: [PSDTaggedBlock] = []
    /// Linked-layer entries (`lnk2`, `lnkD`, `lnk3`, `lnkE`) no smart object refers to, verbatim. The entries smart
    /// objects refer to are their layers' (`ImageLayer.smartObject`), and linked-layer blocks never stay in
    /// `globalBlocks`, so a writer emits each entry once.
    var orphanLinkedEntries: [Data] = []
    /// Where the file's linked-layer blocks were among `globalBlocks`: the index of the block that followed the first
    /// of them (`globalBlocks.count` when it came last), so a writer puts its one `lnk2` block back there. Nil when the
    /// file had none.
    var linkedBlockIndex: Int?
    /// The global layer mask info, verbatim (without its length field).
    var globalLayerMaskInfo = Data()
    var colorModeData = Data()
    /// The header's channel count (3 or 4 for RGB; more with extra alpha channels).
    var channelCount = 3
    var alphaChannelNames: [String] = []
    /// The file's alpha and spot channels (saved selections), which Compositor doesn't keep: the ones named (1006,
    /// 1045) that the header counts beyond red, green and blue.
    var alphaChannelCount: Int { min(alphaChannelNames.count, max(0, channelCount - 3)) }
    var iccProfileDescription: String?
    var globalLightAngle: Double?
    var globalLightAltitude: Double?
    var sourceFileName: String?
    /// The layer count was stored negative: the first alpha channel of the composite is its transparency.
    var layerCountNegative = false
    /// The `TextIndex` of every type layer the file had, sorted: the texts its `Txt2` describes. Nil when unknown (a
    /// project saved before it was kept).
    var importedTextIndices: [Int32]?
    /// The size of the canvas the file was saved with, and where its pixels are on the document's now: Crop, Canvas
    /// Size and Trim move them, Image Size scales them and Flip Canvas mirrors them, as they do guides (identity as
    /// read). The file's saved paths, fractions of its canvas, are placed through it. Nil when unknown (a project
    /// saved before they were kept).
    var canvasSize: CGSize?
    var canvasTransform: CGAffineTransform?

    /// The same data with the file's canvas taken where `change` takes the document's pixels.
    func placingCanvas(_ change: CGAffineTransform) -> PSDDocumentExtras {
        var extras = self
        extras.canvasTransform = canvasTransform?.concatenating(change)
        return extras
    }

    /// Whether a document of `size` no longer has the file's canvas: Crop, Canvas Size, Trim, Image Size or Flip
    /// Canvas took it elsewhere, or to another size. False when unknown.
    func canvasMoved(onto size: CGSize) -> Bool {
        canvasTransform.map { !$0.isIdentity } == true || canvasSize.map { $0 != size } == true
    }
}
