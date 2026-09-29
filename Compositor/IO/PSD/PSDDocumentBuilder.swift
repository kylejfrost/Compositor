import CoreGraphics
import Foundation

nonisolated struct PSDImport: @unchecked Sendable {
    let width: Int
    let height: Int
    let resolution: Double
    let layers: [ImageLayer]
    let conversions: [PSDConversion]
    /// The file's own Photoshop data (resources, global blocks…), fitted to what a project can store. Becomes the
    /// document's `psdExtras` when the import creates the document.
    var extras: PSDDocumentExtras? = nil
    /// Resource 1032's guides. Becomes the document's `guides` when the import creates the document; inserting
    /// into an existing document leaves its guides untouched.
    var guides: [CanvasGuide] = []
}

nonisolated enum PSDDocumentBuilder {
    /// Each layer's pixels as an asset, off the main actor so `makeImport` needn't build them there. Without
    /// `thumbnails` an asset's thumbnail is its image, for a document that is only composited, never shown in the
    /// Layers panel.
    static func assets(from document: PSDDocument, thumbnails: Bool = true) throws -> [UUID: ImportedImage] {
        var result: [UUID: ImportedImage] = [:]
        for record in document.layers {
            guard let image = record.image else { continue }
            result[record.id] = thumbnails ? try imported(image, name: record.name)
                : ImportedImage(image: image, thumbnail: image, name: record.name)
        }
        return result
    }

    /// `limits` are what a project stores of the file's Photoshop data: what goes beyond them is noted, since only a
    /// Photoshop file can keep it.
    @MainActor
    static func makeImport(_ document: PSDDocument, assets: [UUID: ImportedImage] = [:],
                           limits: PSDProjectLimits = PSDProjectLimits()) throws -> PSDImport {
        var conversions: [PSDConversion] = []
        var layers: [ImageLayer] = []
        let canvas = CGSize(width: document.width, height: document.height)
        // What padding may add to the masks: what the document's masks may hold altogether (a project's, less those
        // of a document the file is placed into), less every mask as Photoshop stored it, since a mask left unpadded
        // still counts. Padding then never takes the document past what it can save.
        let storedMaskPixels = document.layers.reduce(0) { total, record in
            guard let mask = record.mask, LayerMask.isValid(mask) else { return total }
            return total + mask.width * mask.height
        }
        var paddingBudget = max(0, document.maskPixelBudget - storedMaskPixels)
        for record in document.layers {
            if record.croppedToCanvas {
                conversions.append(PSDConversion(layerName: record.name,
                                                 message: "Cropped to the canvas so the file fits in memory. Pixels outside the canvas weren’t imported."))
            }
            var notes: [String] = []
            let placeholderTag = placeholderTag(for: record)
            // A smart object keeps showing Photoshop's pixels; its contents and placement come along, so they can be
            // replaced and written back.
            if placeholderTag == nil, record.kind == .smartObject {
                if record.smartObject == nil {
                    notes.append("This smart object’s settings couldn’t be read, so it was imported as pixels. Its Photoshop data is kept.")
                } else if record.smartObject?.payload == nil {
                    notes.append("This smart object’s contents aren’t stored in the file, so it keeps the pixels Photoshop saved. Its settings are kept.")
                }
            }
            if placeholderTag == nil, record.kind == .vector {
                if record.shape != nil || !record.shapeNotes.isEmpty {
                    notes.append(contentsOf: record.shapeNotes)
                } else {
                    notes.append("Vector shape was rasterized to pixels.")
                }
            }
            if placeholderTag == nil, record.kind == .other {
                notes.append("This Photoshop layer type isn’t supported and was imported as pixels.")
            }
            // Type becomes editable text that keeps showing Photoshop's own pixels until it is edited. Type that
            // can't be read or edited stays pixels; its blocks are kept either way.
            var importedText: (style: LayerTextStyle, origin: CGPoint)?
            if placeholderTag == nil, record.kind == .text, !record.isGroup, record.adjustment == nil, record.image != nil {
                if let type = record.typeLayer {
                    if let reason = PSDTypeReader.unsupportedReason(type) {
                        notes.append(reason)
                    } else if let mapped = PSDTypeReader.style(type, fontResolver: FontResolver.self) {
                        importedText = (mapped.style, mapped.origin)
                        notes.append(contentsOf: mapped.notes)
                    } else {
                        notes.append("This text’s settings are beyond what Compositor’s text supports, so the layer keeps Photoshop’s pixels. Its type settings are kept.")
                    }
                } else {
                    notes.append("This text’s type data couldn’t be read, so the layer keeps Photoshop’s pixels. The data is kept.")
                }
            }
            if let placeholderTag {
                // An adjustment Compositor has whose settings it couldn't read, or a kind (or fill) it lacks.
                let unread = PSDAdjustments.readableKeys.contains { placeholderTag == "adjustment:\($0)" }
                let what = unread ? "adjustment’s settings couldn’t be read"
                    : placeholderTag.hasPrefix("fill:") ? "fill layer isn’t supported" : "adjustment type isn’t supported"
                notes.append("This \(what). The layer is kept hidden with its Photoshop settings, so nothing is lost.")
            } else if record.isGroup {
                if record.blendKey != "pass" && record.blendKey != "norm" {
                    notes.append("Folder blend mode “\(record.blendKey)” isn’t supported. The folder will be pass-through.")
                }
            } else if record.blendMode == nil, record.blendKey != "pass" {
                notes.append("Blend mode “\(record.blendKey.trimmingCharacters(in: .whitespaces))” isn’t supported and will be applied as Normal.")
            }
            if record.adjustment != nil {
                notes.append("Adjustment parameters may not match Photoshop exactly.")
                notes.append(contentsOf: record.adjustmentNotes)
            }
            // Effects are live on a layer that draws pixels. Compositor has no folder effects; placeholders and
            // adjustments keep theirs only in their Photoshop data.
            if placeholderTag == nil, record.adjustment == nil {
                if !record.isGroup {
                    notes.append(contentsOf: record.effectNotes)
                } else if record.effects?.visible.isEmpty == false || !record.effectNotes.isEmpty {
                    notes.append("Effects on a folder aren’t supported, so they aren’t shown. Their Photoshop settings are kept.")
                }
            }
            let name = layerName(record.name)
            var extras = record.extras.map(PSDLayerExtrasRecord.fitted)
            if let dropped = extras?.dropped, !dropped.isEmpty {
                notes.append("Some Photoshop data on this layer was too large to keep in a Compositor project and was dropped (\(dropped.joined(separator: ", "))).")
            }
            // A name shortened or filled in to fit a project counts as the imported name, so an unrenamed layer
            // still writes its original `luni` back.
            if name != record.name { extras?.extras.importedName = name }
            if let kept = extras?.extras, [kept.blocks, kept.sectionDividerExtras?.blocks ?? []]
                .contains(where: { PSDBlockFile.encodedCount($0) > limits.layerBlocksBytes }) {
                notes.append("This layer’s Photoshop data is more than a Compositor project can store, so the document can’t be saved as a project. Save it as a Photoshop file to keep it.")
            }
            if placeholderTag == nil, !record.isGroup, record.adjustment == nil,
               let payload = record.smartObject?.payload, payload.data.count > limits.smartObjectBytes {
                notes.append("This smart object’s contents are more than a Compositor project can store, so the document can’t be saved as a project. Save it as a Photoshop file to keep them.")
            }
            for note in notes {
                conversions.append(PSDConversion(layerName: record.name, message: note))
            }
            var layer: ImageLayer
            if let placeholderTag {
                // Kept only to be written back: hidden, with no pixels; how it was shown is remembered.
                layer = ImageLayer(id: record.id, asset: nil, name: name, isVisible: false,
                                   transform: LayerTransform(origin: .zero, size: canvas), parentID: record.parentID,
                                   opacity: min(1, max(0, record.opacity)), blendMode: record.blendMode ?? .normal)
                if extras == nil { extras = (PSDLayerExtras(blendKey: PSDBlockFile.isFourCharacterCode(record.blendKey) ? record.blendKey : "norm"), []) }
                extras?.extras.placeholder = placeholderTag
                extras?.extras.importedVisible = record.isVisible
            } else if record.isGroup {
                // Folders carry an opacity of their own (1.1.6), which multiplies into what's inside
                // them just as Photoshop's group opacity does.
                layer = ImageLayer(id: record.id, asset: nil, name: name, isVisible: record.isVisible,
                                   transform: LayerTransform(origin: .zero, size: canvas), parentID: record.parentID,
                                   isGroup: true, opacity: min(1, max(0, record.opacity)))
            } else if let adjustment = record.adjustment {
                layer = ImageLayer(id: record.id, asset: nil, name: name, isVisible: record.isVisible,
                                   transform: LayerTransform(origin: .zero, size: canvas), parentID: record.parentID,
                                   opacity: min(1, max(0, record.opacity)),
                                   blendMode: record.blendMode ?? .normal, adjustment: adjustment)
            } else if let image = record.image {
                let asset = try assets[record.id] ?? imported(image, name: record.name)
                layer = ImageLayer(id: record.id, asset: asset, name: name, isVisible: record.isVisible,
                                   transform: record.pixelTransform(canvas: canvas), parentID: record.parentID,
                                   opacity: min(1, max(0, record.opacity)),
                                   blendMode: record.blendMode ?? .normal,
                                   shape: record.shape.map { LayerShape(style: $0, image: image) })
            } else {
                layer = ImageLayer(id: record.id, asset: nil, name: name, isVisible: record.isVisible,
                                   transform: LayerTransform(origin: .zero, size: canvas), parentID: record.parentID,
                                   opacity: min(1, max(0, record.opacity)),
                                   blendMode: record.blendMode ?? .normal)
            }
            layer.locks = record.locks
            layer.fillOpacity = record.fillOpacity.isFinite ? min(1, max(0, record.fillOpacity)) : 1
            layer.psdExtras = extras?.extras
            if placeholderTag == nil, !record.isGroup, record.adjustment == nil, let effects = record.effects {
                layer.effects = effects
                // What import made of `lfx2`, so a writer can tell untouched effects from edited ones.
                if layer.psdExtras == nil { layer.psdExtras = PSDLayerExtras() }
                layer.psdExtras?.importedEffects = effects
            }
            // Shape or vector-mask blocks Compositor keeps without drawing them: where they describe the layer. An
            // adjustment's vector mask (a placeholder adjustment's too) is placed by the canvas alone, not its layer box;
            // a fill placeholder's block (no vector mask) fills any canvas, so it has no place to record.
            if !record.isGroup, record.shape == nil {
                if placeholderTag == nil, record.adjustment == nil {
                    if layer.psdExtras?.hasBlock(in: PSDVectorWriter.shapeKeys) == true {
                        layer.psdExtras?.importedShapeFrame = CGRect(origin: layer.transform.origin, size: layer.transform.size)
                        layer.psdExtras?.importedShapeCanvas = canvas
                    }
                } else if layer.psdExtras?.hasBlock(in: PSDReader.vectorKeys) == true {
                    layer.psdExtras?.importedShapeCanvas = canvas
                }
            }
            // Its quads are in the unit coordinates of `pixelTransform`, which is this layer's transform.
            if placeholderTag == nil, !record.isGroup, record.adjustment == nil, let smartObject = record.smartObject {
                layer.smartObject = smartObject
                if layer.psdExtras == nil { layer.psdExtras = PSDLayerExtras() }
                layer.psdExtras?.importedSmartObject = smartObject.info
            }
            if let importedText, let asset = layer.asset {
                // The same image as the layer's pixels, so the text stays live and draws exactly as Photoshop did.
                layer.text = LayerText(style: importedText.style, image: asset.image)
                if layer.psdExtras == nil { layer.psdExtras = PSDLayerExtras() }
                layer.psdExtras?.importedText = importedText.style
                layer.psdExtras?.importedTextIsBox = importedText.style.boxSize != nil
                layer.psdExtras?.importedTextAnchor = layer.transform.unit(of: importedText.origin)
                layer.psdExtras?.importedTextPixelSize = CGSize(width: asset.image.width, height: asset.image.height)
            }
            if let maskImage = record.mask, LayerMask.isValid(maskImage),
               case let fitted = layerMask(maskImage, bounds: record.maskBounds, defaultColor: record.extras?.maskDefaultColor ?? 255,
                                           layer: layer.transform, budget: paddingBudget),
               let maskAsset = try? LayerMask.asset(from: fitted.image) {
                // Only what padding added; the stored pixels were counted up front.
                paddingBudget -= fitted.image.width * fitted.image.height - maskImage.width * maskImage.height
                layer.mask = LayerMask(asset: maskAsset, isEnabled: record.maskEnabled, placement: fitted.placement,
                                       isLinked: record.maskLinked)
                if let stored = fitted.stored {
                    if layer.psdExtras == nil { layer.psdExtras = PSDLayerExtras() }
                    layer.psdExtras?.importedMaskRect = stored
                }
                if fitted.unpadded {
                    conversions.append(PSDConversion(layerName: record.name, message: "The document’s masks are too large to extend over their layers, so this mask keeps Photoshop’s rectangle. Beyond it, the layer may show differently than in Photoshop."))
                }
            } else if record.mask != nil {
                conversions.append(PSDConversion(layerName: record.name, message: "The layer mask couldn’t be converted to 8-bit grayscale and was skipped."))
            } else if record.maskOverBudget {
                conversions.append(PSDConversion(layerName: record.name, message: "This layer’s mask was left out: it would take the document’s masks past what a project holds (\(DocumentLimits.documentBudgetMegapixels) megapixels in all, \(DocumentLimits.maxSide.formatted()) pixels a side)."))
            }
            layers.append(layer)
        }
        let idToIndex = Dictionary(uniqueKeysWithValues: layers.enumerated().map { ($0.element.id, $0.offset) })
        var baseForParent: [UUID?: UUID] = [:]
        for record in document.layers {
            guard let index = idToIndex[record.id] else { continue }
            // A placeholder draws nothing: clipped, it keeps its clipping byte and leaves the chain as it was.
            if layers[index].isPhotoshopPlaceholder {
                if !record.clipping { baseForParent[record.parentID] = nil }
                continue
            }
            if record.clipping {
                if layers[index].isGroup {
                    // Compositor can't clip a folder; its clipping byte stays with its Photoshop data, so a save
                    // writes it clipped again.
                    conversions.append(PSDConversion(layerName: record.name, message: "Compositor can’t clip a folder, so this folder’s clipping was skipped."))
                } else if let source = baseForParent[record.parentID],
                   let sourceLayer = layers.first(where: { $0.id == source }),
                   !sourceLayer.isGroup, sourceLayer.adjustment == nil {
                    layers[index].maskSourceID = source
                } else {
                    conversions.append(PSDConversion(layerName: record.name, message: "This clipping mask’s base isn’t supported, so clipping was skipped."))
                }
            } else if let layer = idToIndex[record.id].map({ layers[$0] }), !layer.isGroup, layer.adjustment == nil {
                baseForParent[record.parentID] = record.id
            } else {
                baseForParent[record.parentID] = nil
            }
        }
        var documentExtras = document.extras
        var guides: [CanvasGuide] = []
        if let extras = document.extras {
            let fitted = PSDDocumentExtrasRecord.fitted(extras)
            documentExtras = fitted.extras
            if !fitted.dropped.isEmpty {
                conversions.append(PSDConversion(layerName: extras.sourceFileName ?? "Document",
                                                 message: "Some of the file’s Photoshop data was too large to keep in a Compositor project and was dropped (\(fitted.dropped.joined(separator: ", ")))."))
            }
            if extras.alphaChannelCount > 0 {
                let count = extras.alphaChannelCount
                let channels = count == 1 ? "alpha or spot channel (a saved selection) isn’t" : "\(count) alpha or spot channels (saved selections) aren’t"
                conversions.append(PSDConversion(layerName: extras.sourceFileName ?? "Document",
                                                 message: "The file’s \(channels) supported: not shown, and left out when the document is saved."))
            }
            // Beyond what a project stores, the document saves only as a Photoshop file.
            var payloads: [ObjectIdentifier: Int] = [:]
            for layer in layers { if let payload = layer.smartObject?.payload { payloads[ObjectIdentifier(payload)] = payload.data.count } }
            let beyond = [
                ("image resources", PSDBlockFile.encodedCount(documentExtras?.resources ?? []) > limits.resourcesBytes),
                ("document-level Photoshop data",
                 PSDBlockFile.encodedCount(documentExtras?.globalBlocks ?? [], alignment: 4) > limits.documentBlocksBytes),
                ("linked smart-object data",
                 PSDBlockFile.encodedCount(linkedEntries: documentExtras?.orphanLinkedEntries ?? []) > limits.linkedBytes),
                ("smart objects’ contents", payloads.values.reduce(0, +) > limits.smartObjectTotalBytes),
            ].filter(\.1).map(\.0)
            if let first = beyond.first {
                let plural = beyond.count > 1 || first.hasSuffix("s")
                let list = ListFormatter.localizedString(byJoining: beyond)
                conversions.append(PSDConversion(layerName: extras.sourceFileName ?? "Document",
                                                 message: "The file’s \(list) \(plural ? "are" : "is") more than a Compositor project can store, so the document can’t be saved as a project. Save it as a Photoshop file to keep \(plural ? "them" : "it")."))
            }
            if let guideResource = extras.resources.last(where: { $0.id == 1032 }) {
                // What a project can save; the resource itself stays with the file's data.
                let read = PSDResources.guides(guideResource.data, limit: PSDResources.maximumGuides)
                guides = read.guides
                if PSDResources.guidesAreMalformed(guideResource.data) {
                    conversions.append(PSDConversion(layerName: extras.sourceFileName ?? "Document",
                                                     message: "The file’s guides couldn’t be read and were skipped."))
                } else if read.total > read.guides.count {
                    let total = read.total.formatted(), skipped = (read.total - read.guides.count).formatted()
                    conversions.append(PSDConversion(layerName: extras.sourceFileName ?? "Document",
                                                     message: "\(skipped) of the file’s \(total) guides were left out: a Compositor document holds \(PSDResources.maximumGuides.formatted()). The first \(read.guides.count.formatted()) are kept."))
                }
            }
        }
        return PSDImport(width: document.width, height: document.height, resolution: document.resolution,
                         layers: layers, conversions: conversions, extras: documentExtras, guides: guides)
    }

    /// A note for the confirmation sheet when a PSD is placed into an existing document at a different resolution
    /// than the one it was saved at (guides and the document's own resolution are never changed by an insert):
    /// "Placed at pixel size; the file was N ppi." Nil when the two round to the same ppi.
    static func resolutionMismatchNote(fileName: String, importedResolution: Double, existingResolution: Double) -> PSDConversion? {
        let imported = Int(importedResolution.rounded())
        let existing = Int(existingResolution.rounded())
        guard imported != existing else { return nil }
        return PSDConversion(layerName: fileName, message: "Placed at pixel size; the file was \(imported) ppi.")
    }

    /// The placeholder tag of a layer Compositor keeps only to write back: `adjustment:<key>` for an adjustment
    /// layer whose kind it can't apply (or whose settings it couldn't read), `fill:<key>` for a fill layer (solid
    /// color, gradient or pattern) with no vector data. Nil for every other layer; a shape's `SoCo` is its fill.
    private static func placeholderTag(for record: PSDRecord) -> String? {
        guard !record.isGroup, record.adjustment == nil, let blocks = record.extras?.blocks else { return nil }
        if let key = blocks.first(where: { PSDReader.adjustmentKeys.contains($0.key) })?.key { return "adjustment:\(key)" }
        guard !blocks.contains(where: { PSDReader.vectorKeys.contains($0.key) }),
              let key = blocks.first(where: { PSDReader.fillKeys.contains($0.key) })?.key else { return nil }
        return "fill:\(key)"
    }

    /// A layer name a project can store: not blank, and at most 16 KiB.
    private static func layerName(_ name: String) -> String {
        let fitted = PSDLayerExtrasRecord.truncated(name, toBytes: PSDLayerExtrasRecord.maximumImportedNameBytes)
        return fitted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Layer" : fitted
    }

    /// A Photoshop mask as its layer at `layer` takes it. Photoshop trims a mask's rectangle (`bounds`, document
    /// pixels) to what differs from its default color, and shows that color everywhere else; so the mask is padded
    /// with it to cover the layer as well. It then covers the layer (placement nil), as Compositor's own masks do,
    /// and is painted in the layer's grid; reaching past the layer, it sits over both. `stored` is where Photoshop's
    /// rectangle lies in the padded pixels (nil when nothing was padded). Padding would add more than `budget` pixels
    /// to the stored ones (`unpadded`), or it lies beside a layer that isn't upright (never so on import): it sits in
    /// its own rectangle instead.
    static func layerMask(_ image: CGImage, bounds: CGRect?, defaultColor: UInt8, layer: LayerTransform, budget: Int)
        -> (image: CGImage, placement: LayerTransform?, stored: CGRect?, unpadded: Bool) {
        guard let bounds, bounds.width >= 1, bounds.height >= 1,
              CGFloat(image.width) == bounds.width, CGFloat(image.height) == bounds.height else { return (image, nil, nil, false) }
        let own = LayerTransform(origin: bounds.origin, size: bounds.size)
        guard !own.samePlacement(as: layer) else { return (image, nil, nil, false) }
        let area = CGRect(origin: layer.origin, size: layer.size)
        let minX = floor(min(area.minX, bounds.minX)), minY = floor(min(area.minY, bounds.minY))
        let width = Int(ceil(max(area.maxX, bounds.maxX)) - minX), height = Int(ceil(max(area.maxY, bounds.maxY)) - minY)
        let offset = (x: Int(bounds.minX - minX), y: Int(bounds.minY - minY))
        let fits = (1...DocumentLimits.maxSide).contains(width) && (1...DocumentLimits.maxSide).contains(height)
            && width * height - image.width * image.height <= budget
        guard layer.isValid, layer.radians == 0, !layer.flipX, !layer.flipY, fits,
              let padded = try? paddedMask(image, width: width, height: height, at: offset, fill: defaultColor) else {
            return (image, own.isValid ? own : nil, nil, !fits)
        }
        let outer = LayerTransform(origin: CGPoint(x: minX, y: minY), size: CGSize(width: width, height: height))
        return (padded, outer.samePlacement(as: layer) ? nil : outer,
                CGRect(x: offset.x, y: offset.y, width: image.width, height: image.height), false)
    }

    /// `image`'s gray values, byte for byte, at `offset` in a `width` × `height` grid of `fill`.
    private static func paddedMask(_ image: CGImage, width: Int, height: Int, at offset: (x: Int, y: Int), fill: UInt8) throws -> CGImage {
        let w = image.width, h = image.height
        guard offset.x >= 0, offset.y >= 0, offset.x + w <= width, offset.y + h <= height else { throw PSDError.truncated }
        var gray = [UInt8](repeating: fill, count: width * height)
        func copyRows(from base: UnsafeRawPointer, bytesPerRow: Int) {
            gray.withUnsafeMutableBytes { target in
                for row in 0..<h {
                    (target.baseAddress! + (offset.y + row) * width + offset.x).copyMemory(from: base + row * bytesPerRow, byteCount: w)
                }
            }
        }
        if image.bitsPerComponent == 8, image.bitsPerPixel == 8, image.decode == nil, let data = image.dataProvider?.data as Data?,
           image.bytesPerRow >= w, data.count >= image.bytesPerRow * (h - 1) + w {
            // A Photoshop mask as read: its own bytes.
            data.withUnsafeBytes { copyRows(from: $0.baseAddress!, bytesPerRow: image.bytesPerRow) }
        } else {
            guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
                  let pixels = context.data else { throw ExportError.render }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            copyRows(from: UnsafeRawPointer(pixels), bytesPerRow: context.bytesPerRow)
        }
        return try PSDChannelCoder.maskImage(width: width, height: height, gray: gray)
    }

    private static func imported(_ image: CGImage, name: String) throws -> ImportedImage {
        ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: name)
    }
}
