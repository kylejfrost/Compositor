import CoreGraphics
import Foundation
import UniformTypeIdentifiers

nonisolated enum PSDError: LocalizedError, Equatable {
    case truncated, unsupportedVersion, unsupportedColorMode, unsupportedDepth, unsupportedCompression
    var errorDescription: String? {
        switch self {
        case .truncated: "The Photoshop file could not be read. It may be damaged or incomplete."
        case .unsupportedVersion: "This Photoshop file uses a format version Compositor can’t read."
        case .unsupportedColorMode: "Only 8-bit RGB Photoshop files can be imported."
        case .unsupportedDepth: "Only 8-bit RGB Photoshop files can be imported."
        case .unsupportedCompression: "This Photoshop file uses a layer compression method that isn’t supported."
        }
    }
}

nonisolated struct PSDConversion: Identifiable, Equatable, Sendable {
    let id: UUID
    let layerName: String
    let message: String
    init(id: UUID = UUID(), layerName: String, message: String) {
        self.id = id
        self.layerName = layerName
        self.message = message
    }
}

nonisolated struct PSDDocument: @unchecked Sendable {
    var width: Int
    var height: Int
    var resolution: Double
    /// Bottom to top, including folders. Hidden section dividers are not stored.
    var layers: [PSDRecord]
    /// Everything else the file holds, kept to be written back. Nil only on documents built by hand.
    var extras: PSDDocumentExtras? = nil
    /// The mask pixels the document's masks may take altogether, as stored and as import pads them: what the reader
    /// was given (a project's masks, less those of a document the file is placed into).
    var maskPixelBudget = LayerMask.maximumProjectPixels
    /// Read from a Large Document (PSB, version 2) file; what the log reports opening. Compositor writes version 1.
    var isLargeDocument = false
}

nonisolated struct PSDRecord: @unchecked Sendable {
    var id: UUID
    var parentID: UUID?
    var name: String
    var isGroup = false
    var isVisible = true
    var opacity: Double = 1
    var blendKey = "norm"
    var clipping = false
    var croppedToCanvas = false
    var bounds = CGRect.zero
    var image: CGImage?
    var mask: CGImage?
    /// The mask's rectangle on the document as stored, its own size and where it sits; nil without a mask. The
    /// document builder places the mask there when it isn't the layer's rectangle.
    var maskBounds: CGRect?
    var maskEnabled = true
    var maskLinked = true
    /// The layer's mask was left out unread: it would have taken the document's masks past `maskPixelBudget`.
    var maskOverBudget = false
    var adjustment: LayerAdjustment?
    /// What the adjustment's settings lose in Compositor, for the conversion report.
    var adjustmentNotes: [String] = []
    var kind = PSDLayerKind.raster
    var shape: LayerShapeStyle?
    /// Notes on the live shape, or on why a vector layer stayed pixels when there's more to say than that.
    var shapeNotes: [String] = []
    /// The layer's `lfx2`, as Compositor effects (`PSDEffectsReader`). Nil when it has none or they couldn't be read.
    var effects: LayerEffects?
    /// What those effects lose in Compositor, for the conversion report.
    var effectNotes: [String] = []
    /// A type layer's `TySh`, decoded. Nil when the layer isn't text or its type data couldn't be read.
    var typeLayer: PSDTypeLayer?
    /// Photoshop's Fill (`iOpa`), apart from `opacity`.
    var fillOpacity: Double = 1
    var locks: LayerLocks = []
    /// The layer's blocks and record fields, kept to be written back.
    var extras: PSDLayerExtras?
    /// The layer's smart object (`SoLd`/`SoLE`), its quads in the unit coordinates of `pixelTransform(canvas:)` and
    /// its contents from the document's linked-layer entries. Nil when the layer isn't one or its settings couldn't be
    /// read.
    var smartObject: LayerSmartObject?
}

extension PSDRecord {
    /// Where the layer's pixels are placed: their bounds (the image's own size when the bounds are empty), or the
    /// whole canvas for a layer without pixels.
    nonisolated func pixelTransform(canvas: CGSize) -> LayerTransform {
        guard let image else { return LayerTransform(origin: .zero, size: canvas) }
        let size = bounds.width > 0 && bounds.height > 0 ? bounds.size : CGSize(width: image.width, height: image.height)
        return LayerTransform(origin: CGPoint(x: bounds.minX, y: bounds.minY), size: size)
    }
}

nonisolated enum PSDLayerKind: Equatable, Sendable {
    case raster, group, adjustment, text, smartObject, effects, vector, other
}

extension LayerBlendMode {
    nonisolated static func fromPSD(_ key: String) -> LayerBlendMode? {
        switch key {
        case "norm": .normal
        case "mul ": .multiply
        case "scrn": .screen
        case "over": .overlay
        case "sLit": .softLight
        case "dark": .darken
        case "lite": .lighten
        case "diff": .difference
        case "div ": .colorDodge
        case "idiv": .colorBurn
        case "hue ": .hue
        case "sat ": .saturation
        case "colr": .color
        case "lum ": .luminosity
        case "lbrn": .linearBurn
        case "lddg": .linearDodge
        case "hLit": .hardLight
        case "vLit": .vividLight
        case "lLit": .linearLight
        case "pLit": .pinLight
        case "hMix": .hardMix
        case "smud": .exclusion
        case "fsub": .subtract
        case "fdiv": .divide
        // Dissolve, Darker Color and Lighter Color are deliberately absent: Compositor has no
        // equivalent, so they fall through to Normal and say so in the conversion report.
        default: nil
        }
    }

    /// The blend key a PSD writer stores: the inverse of `fromPSD`.
    nonisolated var psdKey: String {
        switch self {
        case .normal: "norm"
        case .darken: "dark"
        case .multiply: "mul "
        case .colorBurn: "idiv"
        case .linearBurn: "lbrn"
        case .lighten: "lite"
        case .screen: "scrn"
        case .colorDodge: "div "
        case .linearDodge: "lddg"
        case .overlay: "over"
        case .softLight: "sLit"
        case .hardLight: "hLit"
        case .vividLight: "vLit"
        case .linearLight: "lLit"
        case .pinLight: "pLit"
        case .hardMix: "hMix"
        case .difference: "diff"
        case .exclusion: "smud"
        case .subtract: "fsub"
        case .divide: "fdiv"
        case .hue: "hue "
        case .saturation: "sat "
        case .color: "colr"
        case .luminosity: "lum "
        }
    }
}

extension PSDRecord {
    nonisolated var blendMode: LayerBlendMode? { LayerBlendMode.fromPSD(blendKey) }
}
