import AppKit

/// What a headless stroke (`EditorSession.paintStroke`) does: the Brush painting or erasing, Spot Healing in one of
/// its modes, Clone Stamp copying from `source` (where the stroke's first point copies from), Blur, Smudge or Liquify.
nonisolated enum StrokeMode: Equatable, Sendable {
    case paint, erase, heal(SpotHealingMode), clone(source: CGPoint, sampleAll: Bool), blur, smudge, liquify
}

/// Why a headless pixel edit (`paintStroke`, `applyGradient`, `pasteImage`, `replaceLayerPixels`) couldn't run.
nonisolated struct PixelEditError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }

    /// The layer or its mask can't take paint right now (see `EditorSession.canPaint(_:mask:)`).
    static let cannotPaint = PixelEditError(
        "That layer can't be painted right now: it must be visible, have pixels (or an enabled mask) of its own, and the selection mustn't be empty.")
}

extension EditorSession {
    /// An explicitly empty selection leaves nothing paintable, so painting never starts.
    var canPaint: Bool {
        // A folder has no pixels of its own, so only its mask can be painted.
        canEditLayers && selectedLayerIDs.count == 1 && (activeLayer?.isGroup == false || isMaskSelected) && selection?.isEmpty != true
            && activeLayerID.map { document?.effectiveVisibleIDs.contains($0) == true } == true
            && (!isMaskSelected || activeLayer?.mask?.isEnabled == true)
            && (isMaskSelected || activeLayer?.adjustment == nil)
            // Kept only to be written back to Photoshop, like a locked layer.
            && activeLayer?.isPhotoshopPlaceholder != true
    }
    /// Why a stroke can't start on the target, for the alert, as Photoshop explains a brush it refuses. Nil when
    /// nothing about the target is in the way; while the editor is busy (a transform, a dialog) a press just waits.
    var paintRefusal: String? {
        guard canEditLayers, let layer = activeLayer, !canPaint else { return nil }
        if selectedLayerIDs.count > 1 { return "Several layers are selected. Select just one to paint on it." }
        if layer.isGroup, !isMaskSelected {
            return "“\(layer.name)” is a folder, which has no pixels of its own. Paint on a layer inside it, or on the folder’s mask."
        }
        if document?.effectiveVisibleIDs.contains(layer.id) != true {
            return "“\(layer.name)” is hidden, or inside a hidden folder. Show it to paint on it."
        }
        if isMaskSelected, layer.mask?.isEnabled != true {
            return "The layer mask is turned off. Shift-click its thumbnail to turn it on, then paint."
        }
        if !isMaskSelected, layer.adjustment != nil {
            return "“\(layer.name)” is an adjustment layer, with no pixels to paint. Paint on its mask instead."
        }
        if selection?.isEmpty == true {
            return "Nothing is selected, so there’s nowhere to paint. Choose Select › Deselect (⌘D) to paint anywhere."
        }
        return nil
    }
    /// Tiled raster edit of the active layer's pixels or mask, within the shared pixel budgets.
    /// Tiled raster edit of a layer's pixels or, with `mask` (by default whether the mask is targeted), its mask,
    /// within the shared pixel budgets. Throws `LayerLockedError` when the layer's locks keep that target from changing.
    func makeRasterEdit(for layer: ImageLayer, settings: BrushSettings = BrushSettings(), mask: Bool? = nil,
                        growsMask: Bool = false) throws -> BrushStroke {
        guard let document else { throw ProjectError.tooLarge }
        let isMask = mask ?? isMaskSelected
        try checkUnlocked(layer, mask: isMask)
        let stroke = try BrushStroke(layer: layer, mask: isMask, settings: settings, canvas: document.size, growsMask: growsMask)
        let used = document.layers.filter { $0.id != layer.id }.reduce(0) { total, layer in
            let image = isMask ? layer.mask?.asset.image : layer.asset?.image
            return total + (image.map { $0.width * $0.height } ?? 0)
        }
        stroke.pixelLimit = DocumentLimits.documentPixelBudget - used
        stroke.selectionClip = try selection?.clip(canvas: document.size)
        if !isMask, layer.mask != nil {
            let maskPixels = document.layers.filter { $0.id != layer.id }.reduce(0) { $0 + ($1.mask.map { $0.asset.image.width * $0.asset.image.height } ?? 0) }
            stroke.pixelLimit = min(stroke.pixelLimit, DocumentLimits.documentPixelBudget - maskPixels)
        }
        return stroke
    }
    /// Whether a layer's pixels, or with `mask` its mask, can be painted right now, whichever layer is active: what
    /// `canPaint` asks of the active layer, for the headless edits (`paintStroke`, `applyGradient`, `pasteImage`).
    func canPaint(_ id: UUID, mask: Bool) -> Bool {
        guard canEditLayers, selection?.isEmpty != true, let layer = document?.layers.first(where: { $0.id == id }),
              document?.effectiveVisibleIDs.contains(id) == true, !layer.isPhotoshopPlaceholder else { return false }
        // A folder has no pixels of its own, so only its mask can be painted.
        return mask ? layer.mask?.isEnabled == true : !layer.isGroup && layer.adjustment == nil
    }

    /// Paints one stroke through `points` (document pixels) on a layer's pixels or, with `mask`, its mask, without the
    /// pointer or the tools' settings: `settings` is the whole tip and color (on a mask `red` is the gray it paints),
    /// with no smoothing. Limited to the selection when there is one. One undo step, named as the app names that
    /// tool's stroke ("Brush Stroke", "Erase", "Spot Healing", "Clone Stamp", "Blur", "Smudge", "Liquify", or
    /// "Paint Mask"); a stroke that paints nothing (off the canvas, or a Smudge that never moves) records none. Masks
    /// take `.paint` and `.blur` only.
    func paintStroke(_ points: [CGPoint], on id: UUID, mask: Bool, settings: BrushSettings, mode: StrokeMode) throws {
        guard let first = points.first, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw PixelEditError("A stroke needs at least one point, each of finite numbers.")
        }
        guard canPaint(id, mask: mask), let document, let layer = document.layers.first(where: { $0.id == id }) else {
            throw PixelEditError.cannotPaint
        }
        guard !mask || mode == .paint || mode == .blur else {
            throw PixelEditError("Only painting and Blur work on a layer mask; the other strokes work on a layer's pixels.")
        }
        finishOpacityEdit()
        if mode == .smudge || mode == .liquify {
            // Nothing to push around on a layer without pixels.
            guard let image = layer.asset?.image else { return }
            let warp = try WarpStroke(layer: layer, image: image, transform: displayedTransform(for: layer), canvas: document.size,
                                      mode: mode == .smudge ? .smudge : .liquify, settings: settings)
            for point in points { warp.append(point) }
            try commitWarp(warp, settings: settings)
            return
        }
        var tip = settings
        tip.smoothing = 0
        tip.erasing = mode == .erase
        tip.healing = false
        if case .heal(let healing) = mode {
            tip.healing = true
            tip.healingMode = healing
        }
        let stroke = try makeRasterEdit(for: layer, settings: tip, mask: mask)
        switch mode {
        case .clone(let source, let sampleAll):
            guard let sample = cloneSample(document, layer: layer, sampleAll: sampleAll) else { throw ExportError.render }
            // The first point copies from the source, and the stroke keeps that whole-pixel offset.
            stroke.clone = (sample, CGSize(width: (source.x - first.x).rounded(), height: (source.y - first.y).rounded()))
        case .blur:
            guard let sample = blurSample(document, mask: mask, layer: layer, diameter: tip.diameter) else { throw ExportError.render }
            stroke.clone = (sample, .zero)
            stroke.isBlur = true
        default:
            break
        }
        for point in points { try stroke.append(point) }
        try stroke.flush()
        if tip.healing { try stroke.heal() }
        if !stroke.patches.isEmpty { try commitPaintSnapshot(stroke) }
    }

    func beginBrush(at point: CGPoint) {
        // Spot Healing and Clone Stamp rework image pixels; they have nothing to do on a mask.
        if tool == .blur, blurMode != .blur { beginWarp(at: point); return }
        guard tool == .brush || tool == .blur || (tool.isBrushTool && !isMaskSelected) else { return }
        guard canPaint, let layer = activeLayer, let document else { brushError = paintRefusal; return }
        var sourceOffset: CGSize?
        if tool == .cloneStamp {
            guard let offset = cloneStrokeOffset(at: point) else {
                brushError = "Option-click where Clone Stamp should copy from first."
                return
            }
            sourceOffset = offset
        }
        finishOpacityEdit()
        do {
            var settings = brushSettings
            settings.healing = tool == .spotHealing
            settings.erasing = tool == .brush && brushMode == .erase && !isMaskSelected
            settings.healingMode = spotHealingMode
            if isMaskSelected { settings.red = maskPaintWhite ? 1 : 0; settings.green = settings.red; settings.blue = settings.red }
            let stroke = try makeRasterEdit(for: layer, settings: settings, growsMask: tool == .brush)
            if let offset = sourceOffset {
                guard let sample = cloneSample(document, for: stroke, offset: offset) else { return }
                cloneOffset = offset
                stroke.clone = sample
            }
            // Blur paints a softened copy of the layer, in place, through the brush tip.
            if tool == .blur {
                guard let sample = blurSample(for: stroke) else { return }
                stroke.clone = sample
            }
            stroke.isBlur = tool == .blur
            brushStroke = stroke
            try stroke.append(point)
            brushAnchor = point
            brushPointer = point
            lastBrushPoint = (point, layer.id, isMaskSelected)
            brushRevision += 1
        } catch { cancelBrush(); brushError = error.localizedDescription }
    }
    func continueBrush(at point: CGPoint) {
        if let warpStroke { warpStroke.append(point); lastBrushPoint?.point = point; brushRevision += 1; return }
        guard let brushStroke else { return }
        brushPointer = point
        guard let painted = smoothed(point) else { return }
        do { try brushStroke.append(painted); lastBrushPoint?.point = painted; brushRevision += 1 }
        catch { cancelBrush(); brushError = error.localizedDescription }
    }
    /// Where the brush actually is, with Smoothing on: it trails the pointer on a string, and only
    /// moves once the pointer pulls that string taut — the model Photoshop uses. The string's length
    /// is in screen points, so it feels the same however far the canvas is zoomed in. Nil while the
    /// string is still slack, which is the whole point: those jitters never reach the stroke.
    private func smoothed(_ point: CGPoint) -> CGPoint? {
        guard tool == .brush, brushSettings.smoothing > 0, let anchor = brushAnchor else { return point }
        let radius = brushSettings.smoothing / max(0.01, viewport.zoom)
        let delta = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y)
        let distance = hypot(delta.x, delta.y)
        guard distance > radius else { return nil }
        let step = (distance - radius) / distance
        let moved = CGPoint(x: anchor.x + delta.x * step, y: anchor.y + delta.y * step)
        brushAnchor = moved
        return moved
    }
    /// Where a Shift-click paints a line from: the end of the last stroke, while the same layer (or mask) is the target.
    func shiftLineStart() -> CGPoint? {
        guard let last = lastBrushPoint, last.layerID == activeLayerID, last.mask == isMaskSelected else { return nil }
        return last.point
    }
    func cancelBrush() {
        warpStroke = nil
        brushStroke = nil
        brushAnchor = nil
        brushPointer = nil
        brushRevision += 1
    }
    /// Called directly by mouse-up, before the next input event can be handled.
    @discardableResult
    func finishBrushImmediately() -> Bool {
        if warpStroke != nil {
            guard !isProjectBusy else { return false }
            finishWarp()
            return true
        }
        guard let stroke = brushStroke else { return true }
        guard !isProjectBusy else { return false }
        defer { cancelBrush() }
        do {
            // Smoothing leaves the brush short of the pointer; the stroke ends where the hand did.
            if let pointer = brushPointer, let anchor = brushAnchor, pointer != anchor,
               tool == .brush, brushSettings.smoothing > 0 {
                try stroke.append(pointer)
            }
            try stroke.flush()
            if stroke.settings.healing { try stroke.heal() }
            if !stroke.patches.isEmpty { try commitPaintSnapshot(stroke) }
        } catch { brushError = error.localizedDescription }
        return true
    }

    func finishBrush() async { finishBrushImmediately() }

    /// Install immutable tiles immediately, including the undo entry. The next
    /// stroke and other tools can start without awaiting full-image assembly.
    func commitPaintSnapshot(_ stroke: BrushStroke) throws {
        let result = try stroke.paintSnapshot()
        guard result.transform.isValid,
              let index = document?.layers.firstIndex(where: { $0.id == stroke.layer.id }),
              let current = document?.layers[index], current.asset?.image === stroke.layer.asset?.image,
              current.transform == stroke.layer.transform else { return }
        var mask = current.mask
        if !stroke.isMask, let original = mask, original.placement == nil, result.bounds != stroke.sourceRect {
            let raster = RasterSnapshot.replacing(source: original.asset, sourceRect: stroke.sourceRect,
                patches: [], crop: result.bounds, isMask: true)
            mask = original.replacing(ImportedImage(image: try raster.makeImage(), thumbnail: try raster.thumbnail(),
                name: original.asset.name, raster: raster))
        }
        beginEdit(stroke.editName ?? (stroke.isMask ? "Paint Mask" : stroke.settings.erasing ? "Erase" : stroke.isBlur ? "Blur" : stroke.clone != nil ? "Clone Stamp" : stroke.settings.healing ? "Spot Healing" : "Brush Stroke"))
        if stroke.isMask {
            document?.layers[index].mask = current.mask.map { mask in
                var painted = mask.replacing(result.asset)
                // Grown past its layer, or already placed on its own: the mask keeps its place on the document. A linked
                // one still moves with its layer.
                if mask.placement != nil || result.bounds != stroke.sourceRect { painted.placement = result.transform }
                return painted
            } ?? LayerMask(asset: result.asset)
        } else {
            document?.layers[index] = current.replacingPixels(result.asset, transform: result.transform, mask: mask)
        }
        endEdit()
    }

    /// Assembles a raster edit off the main thread and replaces the layer's pixels or
    /// mask as one undo step. Other layer properties are read at commit time.
    func commitRasterEdit(_ stroke: BrushStroke, name: String, alsoApply: (() -> Void)? = nil) async throws {
        isProjectBusy = true
        defer { isProjectBusy = false }
        guard stroke.committedTransform.isValid else { throw ProjectError.tooLarge }
        let input = stroke.commitInput()
        let result = try await BrushCommit.shared.render(input)
        let asset = result.asset
        let transform = stroke.transform(for: result.pixelBounds.offsetBy(dx: stroke.committedBounds.minX, dy: stroke.committedBounds.minY))
        guard transform.isValid else { throw ProjectError.tooLarge }
        var mask = stroke.layer.mask
        if !stroke.isMask, let originalMask = mask, originalMask.placement == nil {
            mask = originalMask.replacing(try await BrushCommit.shared.expandMask(originalMask.asset, for: input, croppedTo: result.pixelBounds))
        }
        // The raster was built from this layer's pixels, transform, and mask; never
        // write it over content that changed underneath it.
        guard let index = document?.layers.firstIndex(where: { $0.id == stroke.layer.id }),
              let current = document?.layers[index], current.asset?.image === stroke.layer.asset?.image,
              current.transform == stroke.layer.transform,
              current.mask?.asset.image === stroke.layer.mask?.asset.image else { return }
        beginEdit(name)
        if stroke.isMask {
            let bounds = result.pixelBounds.offsetBy(dx: stroke.committedBounds.minX, dy: stroke.committedBounds.minY)
            document?.layers[index].mask = current.mask.map { mask in
                var edited = mask.replacing(asset)
                // Grown past its layer, or already placed on its own: the mask keeps its place on the document.
                if mask.placement != nil || bounds != stroke.sourceRect { edited.placement = transform }
                return edited
            } ?? LayerMask(asset: asset)
        } else {
            document?.layers[index] = current.replacingPixels(asset, transform: transform,
                mask: mask.map { mask -> LayerMask in
                    var kept = mask
                    kept.isEnabled = current.mask?.isEnabled ?? mask.isEnabled
                    return kept
                })
        }
        alsoApply?()
        endEdit()
    }
    /// Tools where number keys set opacity: the brush or gradient opacity, or with
    /// Move/Transform the opacity of the selected layers.
    var usesOpacityKeys: Bool { tool.isBrushTool || tool == .gradient || tool == .move }

    /// Photoshop-style opacity keys: 1 = 10% … 9 = 90%, 0 = 100%.
    /// Two digits typed quickly set an exact value (4 then 5 = 45%, 0 then 5 = 5%).
    func typeOpacityDigit(_ digit: Int, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard usesOpacityKeys, brushStroke == nil, !isProjectBusy, (0...9).contains(digit) else { return }
        var percent = digit == 0 ? 100 : digit * 10
        if let pending = pendingOpacityDigit, time - pending.time < 0.6 {
            percent = max(1, pending.digit * 10 + digit)
            pendingOpacityDigit = nil
        } else {
            pendingOpacityDigit = (digit, time)
        }
        let value = CGFloat(percent) / 100
        switch tool {
        case .brush, .spotHealing, .cloneStamp, .blur: brushSettings.opacity = value
        case .gradient: gradientSettings.opacity = value
        default: setSelectedLayersOpacity(Double(value))
        }
    }
    /// Shift-[ / Shift-]: hardness in Photoshop's 25% steps (0, 25, 50, 75, 100%).
    func changeBrushHardness(increase: Bool) {
        guard brushStroke == nil else { return }
        // Snap to the next step up or down, so 80% goes to 100% or 75%.
        let quarter = brushSettings.hardness * 4
        let step = increase ? floor(quarter + 0.001) + 1 : ceil(quarter - 0.001) - 1
        brushSettings.hardness = min(4, max(0, step)) / 4
    }
    func changeBrushSize(increase: Bool) {
        guard brushStroke == nil else { return }
        // A step of a fifth, but always at least one pixel: 2 shrunk by a fifth would otherwise round back to 2,
        // leaving the smallest brushes out of reach.
        let current = brushSettings.diameter
        let stepped = increase ? max(current + 1, (current * 1.2).rounded()) : min(current - 1, (current / 1.2).rounded())
        brushSettings.diameter = min(2000, max(1, stepped))
    }
}
