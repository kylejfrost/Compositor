import AppKit

/// Why Flatten Image or Rasterize Layer did not run.
nonisolated enum LayerCommandError: LocalizedError {
    /// The layer is gone, or layers can't be edited right now (a modal edit, import or long operation holds them).
    case unavailable
    /// Flattening would lose this many hidden layers, which the caller asked to keep.
    case hiddenLayers(Int)
    /// The named folder, adjustment layer or Photoshop placeholder has no pixels of its own.
    case noPixels(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "The layers can't be edited right now."
        case .hiddenLayers(let count): "Flattening would discard \(count) hidden layer\(count == 1 ? "" : "s")."
        case .noPixels(let name): "'\(name)' has no pixels of its own to rasterize."
        }
    }
}

extension EditorSession {
    /// What ⌘E merges, in stacking order, and where the result goes; nil when there is nothing to merge.
    /// One layer merges with the layer beneath it in the same folder; several selected layers merge together
    /// (with anything their folders hold); a folder merges its contents, and the folder goes.
    private func mergePlan() -> (ids: [UUID], removed: Set<UUID>, name: String, parent: UUID?, anchor: UUID, action: String)? {
        guard let plan = unguardedMergePlan(), let document else { return nil }
        // A Photoshop placeholder has no pixels to merge and would be lost with the merged layers.
        let placeholders = Set(document.layers.filter(\.isPhotoshopPlaceholder).map(\.id))
        guard plan.removed.isDisjoint(with: placeholders), Set(plan.ids).isDisjoint(with: placeholders) else { return nil }
        return plan
    }

    private func unguardedMergePlan() -> (ids: [UUID], removed: Set<UUID>, name: String, parent: UUID?, anchor: UUID, action: String)? {
        guard canEditLayers, let document, let active = activeLayer else { return nil }
        let layers = document.layers
        if selectedLayerIDs.count > 1 {
            var picked = selectedLayerIDs
            for id in selectedLayerIDs { picked.formUnion(descendantIDs(of: id)) }
            let ordered = layers.filter { picked.contains($0.id) }
            guard ordered.contains(where: { !$0.isGroup }),
                  let top = ordered.last(where: { selectedLayerIDs.contains($0.id) }) else { return nil }
            return (ordered.map(\.id), picked, top.name, top.parentID, top.id, "Merge Layers")
        }
        if active.isGroup {
            let inside = descendantIDs(of: active.id)
            guard layers.contains(where: { inside.contains($0.id) && !$0.isGroup }) else { return nil }
            let ids = layers.filter { inside.contains($0.id) || $0.id == active.id }.map(\.id)
            return (ids, Set(ids), active.name, active.parentID, active.id, "Merge Group")
        }
        guard let index = layers.firstIndex(where: { $0.id == active.id }),
              let below = layers[..<index].last(where: { $0.parentID == active.parentID }), !below.isGroup else { return nil }
        return ([below.id, active.id], [below.id, active.id], below.name, active.parentID, active.id, "Merge Down")
    }

    var canMergeLayers: Bool { mergePlan() != nil }
    var mergeTitle: String { mergePlan()?.action ?? "Merge Down" }
    /// Every layer ⌘E would merge away, folders included; empty when there is nothing to merge.
    var mergingLayerIDs: Set<UUID> { mergePlan()?.removed ?? [] }

    /// ⌘E: the layers composited as the canvas shows them — blend modes, opacity, masks, clipping and adjustments
    /// baked in — into one pixel layer, trimmed to what is there, in their place, as one undo step.
    func mergeLayers() {
        commitTransform()
        guard let plan = mergePlan(), let document,
              unlocked(document.layers.map(\.id).filter(plan.removed.contains), for: .pixels) else { return }
        let layers = document.layers
        let kept = Set(plan.ids)
        // Only the merged layers, cut loose from anything outside the merge.
        let subset = layers.filter { kept.contains($0.id) }.map { layer -> ImageLayer in
            var copy = layer
            if let parent = copy.parentID, !kept.contains(parent) { copy.parentID = nil }
            if let source = copy.maskSourceID, !kept.contains(source) { copy.maskSourceID = nil }
            return copy
        }
        let flat = CanvasDocument(id: document.id, width: document.width, height: document.height,
                                  layers: subset, resolution: document.resolution)
        guard let context = try? BrushRaster.context(width: document.width, height: document.height, mask: false) else { return }
        drawLiveComposite(flat, in: context)
        let canvas = LayerTransform(origin: .zero, size: CGSize(width: document.width, height: document.height))
        guard let full = context.makeImage(),
              let trimmed = try? PixelFilter.trimmed(full, placed: canvas),
              let thumbnail = try? PixelAdjust.thumbnail(of: trimmed.image) else { NSSound.beep(); return }
        var merged = ImageLayer(asset: ImportedImage(image: trimmed.image, thumbnail: thumbnail, name: plan.name),
                                origin: trimmed.transform.origin)
        merged.transform = trimmed.transform
        merged.name = plan.name
        merged.parentID = plan.parent
        var next = layers.filter { !plan.removed.contains($0.id) }
        // Layers clipped to anything that was merged now clip to the result.
        for i in next.indices where next[i].maskSourceID.map(plan.removed.contains) == true { next[i].maskSourceID = merged.id }
        let slot = layers.firstIndex { $0.id == plan.anchor } ?? layers.count
        let insertion = slot - layers[..<slot].filter { plan.removed.contains($0.id) }.count
        next.insert(merged, at: min(max(0, insertion), next.count))
        guard (try? LayerHierarchy.validate(next.map(\.hierarchyRecord))) != nil else { NSSound.beep(); return }
        finishOpacityEdit()
        beginEdit(plan.action)
        self.document?.layers = next
        activeLayerID = merged.id
        endEdit()
    }
}

extension EditorSession {
    /// Flatten Image: the canvas exactly as export renders it replaces every layer as one full-canvas pixel layer,
    /// "Background", with its transparency. Guides, the selection and the document's Photoshop data stay. Hidden
    /// layers are discarded; with `discardHidden` false a document that has any is refused instead. Renders off the
    /// main actor while the document is busy. One undo step, "Flatten Image".
    func flattenImage(discardHidden: Bool = true) async throws {
        guard canEditLayers, let document, let snapshot = projectSnapshot() else { throw LayerCommandError.unavailable }
        if !discardHidden {
            let visible = document.effectiveVisibleIDs
            let hidden = document.layers.filter { !$0.isGroup && !visible.contains($0.id) }.count
            guard hidden == 0 else { throw LayerCommandError.hiddenLayers(hidden) }
        }
        isProjectBusy = true
        defer { isProjectBusy = false }
        let raster = try await ImageExporter.shared.render(snapshot)
        guard self.document == document else { throw LayerCommandError.unavailable }
        let asset = ImportedImage(image: raster.image, thumbnail: try PixelAdjust.thumbnail(of: raster.image), name: "Background")
        var flat = ImageLayer(asset: asset, origin: .zero)
        flat.name = "Background"
        finishOpacityEdit()
        beginEdit("Flatten Image")
        self.document?.layers = [flat]
        collapsedGroupIDs = []
        activeLayerID = flat.id
        endEdit()
    }

    /// Rasterize Layer: a text or shape layer becomes the plain pixels it shows now, keeping its effects, mask, fill,
    /// locks and every other property (see `ImageLayer.replacingPixels`). A layer that is plain pixels already is left
    /// as it is. Folders, adjustment layers and Photoshop placeholders have no pixels of their own and throw. One undo
    /// step, "Rasterize Layer".
    func rasterizeLayer(_ id: UUID) throws {
        guard canEditLayers, let index = document?.layers.firstIndex(where: { $0.id == id }),
              let layer = document?.layers[index] else { throw LayerCommandError.unavailable }
        guard !layer.isGroup, layer.adjustment == nil, !layer.isPhotoshopPlaceholder else {
            throw LayerCommandError.noPixels(layer.name)
        }
        let raster = layer.replacingPixels(layer.asset, transform: layer.transform, mask: layer.mask)
        guard raster != layer else { return }
        finishOpacityEdit()
        beginEdit("Rasterize Layer")
        document?.layers[index] = raster
        endEdit()
    }
}
