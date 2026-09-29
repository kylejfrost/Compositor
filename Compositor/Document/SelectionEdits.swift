import AppKit

/// Carries a CGImage out of a detached task.
nonisolated private struct Box: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Selected pixels being dragged: the lifted raster plus the outline it started from.
final class PixelMove {
    let raster: BrushStroke
    let origin: DocumentSelection
    let duplicate: Bool
    var offset = CGSize.zero
    /// The offset the raster's tiles were last rebuilt for. They're rebuilt only when something reads them — the Core
    /// Graphics canvas, or the commit — as the GPU canvas draws the move from the lifted pixels as they are.
    private var applied = CGSize.zero
    func applyOffset() throws {
        guard offset != applied else { return }
        try raster.moveLifted(by: offset, duplicate: duplicate)
        applied = offset
    }
    /// Whether the GPU canvas can draw this move: not a layer with a mask or effects, which the Core Graphics canvas draws.
    var drawsOnGPU: Bool {
        raster.layer.mask == nil && raster.layer.effects?.visible.isEmpty != false
            && (duplicate ? raster.original : raster.holed) != nil
    }
    var movedSelection: DocumentSelection {
        var shift = CGAffineTransform(translationX: offset.width, y: offset.height)
        guard let path = origin.path.copy(using: &shift) else { return origin }
        return DocumentSelection(path: path, antialiased: origin.antialiased, feather: origin.feather)
    }
    init(raster: BrushStroke, origin: DocumentSelection, duplicate: Bool = false) {
        self.raster = raster
        self.origin = origin
        self.duplicate = duplicate
    }
}

nonisolated extension PaletteColor {
    /// The gray this color paints on a layer mask: a neutral color's own level, otherwise its Rec. 601 luma.
    var maskGray: CGFloat {
        red == green && green == blue ? red : min(1, max(0, 0.299 * red + 0.587 * green + 0.114 * blue))
    }
}

/// Where `EditorSession.replaceLayerPixels` puts the new pixels: stretched over the layer's box, at their own size
/// from its top-left corner, or at their own size, upright, centered where the layer was.
nonisolated enum PixelPlacement: Sendable {
    case keepBounds, keepOrigin, natural
}

extension EditorSession {
    /// A palette color, or any color. On a mask the palette is the mask's black and white, and a color paints as gray.
    nonisolated enum FillSource: Equatable, Sendable { case foreground, background, color(PaletteColor) }

    /// Whether the active layer (or its mask) can take a fill or clear right now.
    var canEditPixels: Bool { canPaint }

    /// Fills the selection with the foreground or background color, or a color of its own, as one undo step.
    /// With no selection it fills the whole layer; an empty selection fills nothing.
    /// On a mask the palette is black/white, so this reveals or hides.
    func fillSelection(with source: FillSource) async {
        guard canEditPixels, let layer = activeLayer, pixelsUnlocked(layer, mask: isMaskSelected) else { return }
        let value = switch source {
        case .foreground: paletteColor(background: false)
        case .background: paletteColor(background: true)
        case .color(let color): color
        }
        // A text layer that is still text takes the color as its own, rather than being painted over: the letters
        // change color and stay editable.
        if !isMaskSelected, selection == nil, layer.liveText != nil, recolorText(layer.id, to: value) { return }
        let color = isMaskSelected
            ? CGColor(gray: value.maskGray, alpha: 1)
            : CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [value.red, value.green, value.blue, 1])!
        await applyPixelEdit(to: layer, name: isMaskSelected ? "Fill Mask" : "Fill") { try $0.fill(color) }
    }

    /// Delete with a selection: image pixels become transparent; on a mask the
    /// selection fills with the background color, as in Photoshop.
    func clearSelectedPixels() async {
        guard selection != nil, canEditPixels, let layer = activeLayer else { return }
        if isMaskSelected { await fillSelection(with: .background); return }
        guard layer.asset != nil else { return }
        await applyPixelEdit(to: layer, name: "Clear") { try $0.clearPixels() }
    }

    /// The Delete key: clears the selection when there is one; otherwise deletes the
    /// targeted mask, or the layer when its pixels are targeted.
    func deleteKeyPressed() {
        if selectedEffect != nil { removeSelectedEffect(); return }
        if selection != nil { Task { await clearSelectedPixels() } }
        else { deleteLayerOrMask() }
    }

    /// The trash button and Delete without a selection: with one layer's mask thumbnail targeted
    /// only the mask goes; otherwise every selected layer does, in one undo step.
    func deleteLayerOrMask() {
        if selectedEffect != nil { removeSelectedEffect(); return }
        if isMaskSelected, activeLayer?.mask != nil, selectedLayerIDs.count <= 1 { deleteLayerMask() }
        else { deleteSelectedLayers() }
    }

    /// Cmd-I: inverts the layer's colors (transparency kept) or its mask, inside the
    /// selection or across the whole layer without one. Runs off the main thread in one
    /// vectorized pass; one undo step.
    /// Invert is available in every tool: a pending gradient or transform is applied
    /// first, and the Crop tool's rectangle doesn't block it.
    var canInvert: Bool {
        _ = showsBusy
        guard document != nil, textDraft == nil, let layer = activeLayer, !isProjectBusy, !isImporting, !isHeldByAgentBatch, brushStroke == nil, pixelMove == nil,
              renamingLayerID == nil, !showsNewDocument, !showsImporter, selectedLayerIDs.count == 1, !layer.isGroup || isMaskSelected,
              document?.effectiveVisibleIDs.contains(layer.id) == true, selection?.isEmpty != true else { return false }
        return isMaskSelected ? layer.mask?.isEnabled == true : layer.asset != nil
    }

    func invertPixels() async {
        guard canInvert else { return }
        commitTransform()
        if gradientEdit != nil { await commitGradient() }
        guard canInvert, let document, let layer = activeLayer,
              let index = document.layers.firstIndex(where: { $0.id == layer.id }),
              pixelsUnlocked(layer, mask: isMaskSelected) else { return }
        let mask = isMaskSelected
        guard var image = mask ? layer.mask?.asset.image : layer.asset?.image else { return }
        finishOpacityEdit()
        isProjectBusy = true
        defer { isProjectBusy = false }
        do {
            let clip = try selection?.clip(canvas: document.size)
            // A uniform 1×1 mask can't hold a partial selection; give it the layer's pixel grid first.
            if mask, clip != nil, image.width == 1, image.height == 1 {
                image = try Self.expandedUniformMask(image, width: layer.asset?.image.width ?? Int(layer.size.width.rounded()),
                                                     height: layer.asset?.image.height ?? Int(layer.size.height.rounded()))
            }
            let job = PixelInvert.Job(image: image, isMask: mask,
                pixelToDocument: BrushRaster.pixelToDocument(mask ? layer.maskTransform : layer.transform, width: image.width, height: image.height), selection: clip)
            let result = try await Task.detached(priority: .userInitiated) { Box(try PixelInvert.run(job)) }.value.image
            let asset = mask ? try LayerMask.asset(from: result)
                             : ImportedImage(image: result, thumbnail: try PixelInvert.thumbnail(of: result), name: layer.name)
            // Only write over the layer the invert was computed from.
            guard let current = self.document?.layers[safe: index], current.id == layer.id,
                  current.asset?.image === layer.asset?.image, current.mask?.asset.image === layer.mask?.asset.image else { return }
            beginEdit(mask ? "Invert Mask" : "Invert")
            if mask {
                self.document?.layers[index].mask = current.mask.map { $0.replacing(asset) } ?? LayerMask(asset: asset)
            } else {
                self.document?.layers[index] = current.replacingPixels(asset, transform: current.transform, mask: current.mask)
            }
            endEdit()
            brushRevision += 1
        } catch { brushError = error.localizedDescription }
    }

    /// Replaces a layer's pixels with `asset`, as one "Replace Pixels" undo step, placed by `placement`: `.keepBounds`
    /// stretches it over the layer's current box, `.keepOrigin` puts it at its own pixel size from the box's top-left
    /// corner (both keep rotation and flips), and `.natural` at its own size, upright, centered where the layer was.
    /// A mask stays where it is on the document; one painted in the layer's pixel grid is pinned to the old box when
    /// the box or the grid's size changes. A text or shape layer becomes plain pixels.
    func replaceLayerPixels(_ id: UUID, with asset: ImportedImage, placement: PixelPlacement) throws {
        guard canEditLayers, let index = document?.layers.firstIndex(where: { $0.id == id }), let layer = document?.layers[index] else {
            throw PixelEditError("That layer can't be changed right now.")
        }
        guard !layer.isGroup, layer.adjustment == nil, !layer.isPhotoshopPlaceholder else {
            throw PixelEditError("'\(layer.name)' has no pixels of its own to replace.")
        }
        let width = asset.image.width, height = asset.image.height
        guard width <= DocumentLimits.maxSide, height <= DocumentLimits.maxSide, width * height <= DocumentLimits.maxSurfacePixels else {
            throw ProjectError.tooLarge
        }
        let size = CGSize(width: width, height: height)
        var transform = layer.transform
        switch placement {
        case .keepBounds:
            break
        case .keepOrigin:
            transform.size = size
        case .natural:
            let center = layer.transform.center
            transform = LayerTransform(origin: CGPoint(x: floor(center.x - size.width / 2), y: floor(center.y - size.height / 2)),
                                       size: size, sampling: layer.transform.sampling)
        }
        guard transform.isValid else { throw ProjectError.tooLarge }
        var mask = layer.mask
        // A mask covering the layer's own pixel grid stays where it was on the document while that grid changes: it
        // would follow a new box, and in a grid of a new size (keep_bounds with another pixel size) later strokes and
        // pastes would read it 1:1 in the wrong grid.
        let gridWidth = layer.asset?.image.width ?? Int(layer.size.width.rounded())
        let gridHeight = layer.asset?.image.height ?? Int(layer.size.height.rounded())
        if transform != layer.transform || gridWidth != width || gridHeight != height, let owned = mask, owned.placement == nil,
           owned.asset.image.width > 1 || owned.asset.image.height > 1 {
            mask?.placement = layer.transform
        }
        finishOpacityEdit()
        beginEdit("Replace Pixels")
        document?.layers[index] = layer.replacingPixels(asset, transform: transform, mask: mask)
        endEdit()
        brushRevision += 1
    }

    /// Draws `image` into a layer's pixels with its top-left corner at `origin` (document pixels, one image pixel per
    /// document pixel), inside the canvas and the selection: over what is there, or `replacing` it, transparency and
    /// all. One "Paste Image" undo step; an image wholly outside the canvas or selection records none.
    func pasteImage(_ image: CGImage, into id: UUID, at origin: CGPoint, replacing: Bool) throws {
        guard origin.x.isFinite, origin.y.isFinite else { throw PixelEditError("The paste position must be finite.") }
        guard canPaint(id, mask: false), let document, let layer = document.layers.first(where: { $0.id == id }) else {
            throw PixelEditError.cannotPaint
        }
        let rect = CGRect(origin: origin, size: CGSize(width: image.width, height: image.height))
        var area = rect.intersection(CGRect(origin: .zero, size: document.size))
        if let selection { area = area.intersection(selection.path.boundingBoxOfPath) }
        guard !area.isNull, !area.isEmpty else { return }
        finishOpacityEdit()
        let edit = try makeRasterEdit(for: layer, mask: false)
        edit.editName = "Paste Image"
        try edit.drawImage(image, in: rect, replacing: replacing)
        if !edit.patches.isEmpty { try commitPaintSnapshot(edit) }
        brushRevision += 1
    }

    private static func expandedUniformMask(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0, width * height <= DocumentLimits.maxSurfacePixels else { throw ProjectError.tooLarge }
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: true, context: context)
        guard let expanded = context.makeImage() else { throw ExportError.render }
        return expanded
    }

    // MARK: Moving selected pixels (Cmd-drag / Cmd-arrow)

    /// Starts moving the selected image pixels; false when there is nothing to move
    /// (no selection, a mask target, or no pixels under the selection).
    func beginPixelMove(duplicate: Bool = false) -> Bool {
        guard pixelMove == nil, let selection, !selection.isEmpty, canPaint, !isMaskSelected,
              let layer = activeLayer, layer.asset != nil else { return false }
        do {
            let raster = try makeRasterEdit(for: layer)
            guard try raster.liftSelection() else { return false }
            finishOpacityEdit()
            pixelMove = PixelMove(raster: raster, origin: selection, duplicate: duplicate)
            return true
        } catch { brushError = error.localizedDescription; return false }
    }

    /// Previews the pixels `offset` document pixels (whole pixels) away. The stored
    /// selection stays put until commit; the outline is drawn from `displayedSelection`.
    func movePixels(by offset: CGSize) {
        guard let move = pixelMove else { return }
        move.offset = CGSize(width: offset.width.rounded(), height: offset.height.rounded())
        brushRevision += 1
    }

    /// The outline to draw: during a pixel move, the original shifted by the drag.
    var displayedSelection: DocumentSelection? {
        if let moved = pixelMove?.movedSelection { return moved }
        // While transforming selected pixels the outline follows the handles.
        if let edit = transformEdit, var matrix = floatingSelectionTransform(edit), let selection,
           let path = selection.path.copy(using: &matrix) {
            return DocumentSelection(path: path, antialiased: selection.antialiased, feather: selection.feather)
        }
        return selection
    }

    /// Commits the pixels and the moved outline together as one "Move Pixels" undo step.
    /// The outline keeps showing at its new place throughout, so nothing jumps back.
    func finishPixelMove() async {
        guard let move = pixelMove, !isProjectBusy else { return }
        if move.offset != .zero {
            let moved = move.movedSelection
            do {
                try move.applyOffset()
                try await commitRasterEdit(move.raster, name: move.duplicate ? "Duplicate Pixels" : "Move Pixels") { self.document?.selection = moved }
            } catch { brushError = error.localizedDescription }
        }
        pixelMove = nil
        brushRevision += 1
    }

    func cancelPixelMove() {
        guard pixelMove != nil else { return }
        pixelMove = nil
        brushRevision += 1
    }

    /// Cmd-arrow: moves the selected pixels 1 px (10 px with Shift) as one undo step.
    func nudgePixels(dx: CGFloat, dy: CGFloat) async {
        guard beginPixelMove() else { NSSound.beep(); return }
        movePixels(by: CGSize(width: dx, height: dy))
        await finishPixelMove()
    }

    private func applyPixelEdit(to layer: ImageLayer, name: String, _ paint: (BrushStroke) throws -> Void) async {
        finishOpacityEdit()
        do {
            // On a mask, a fill covers the whole canvas, past the mask's own area, as the brush can.
            let edit = try makeRasterEdit(for: layer, growsMask: true)
            try paint(edit)
            guard !edit.patches.isEmpty else { return }
            try await commitRasterEdit(edit, name: name)
            brushRevision += 1
        } catch { brushError = error.localizedDescription }
    }
}
