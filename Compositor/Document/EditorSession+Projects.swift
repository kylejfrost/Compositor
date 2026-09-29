import Foundation

extension EditorSession {
    func projectSnapshot() -> ProjectSnapshot? {
        guard let document else { return nil }
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        let layers = document.layers.map { layer in
            if let asset = layer.asset { images[layer.id] = asset }
            if let mask = layer.mask { masks[layer.id] = mask.asset }
            return ProjectLayerRecord(layer: layer)
        }
        return ProjectSnapshot(manifest: ProjectManifest(resolution: document.resolution, documentID: document.id, width: document.width,
            height: document.height, activeLayerID: activeLayerID, layers: layers,
            guides: document.guides.isEmpty ? nil : document.guides, psd: document.psdExtras.map(PSDDocumentExtrasRecord.init)),
            images: images, masks: masks)
    }

    /// Called only after the entire package has successfully validated and loaded.
    func installProject(_ snapshot: ProjectSnapshot, from url: URL) {
        collapsedGroupIDs = []
        isMaskSelected = false
        cancelCrop()
        guideDrag = nil
        let manifest = snapshot.manifest
        transformEdit = nil
        document = CanvasDocument(id: manifest.documentID, width: manifest.width, height: manifest.height,
            layers: manifest.layers.map { ImageLayer(record: $0, snapshot: snapshot) }, resolution: manifest.resolution ?? 72, guides: manifest.guides ?? [])
        document?.psdExtras = manifest.psd?.extras
        activeLayerID = manifest.activeLayerID
        projectURL = url
        documentFormat = .comp
        sourceURL = nil
        renamingLayerID = nil
        history.reset()
        viewport.fit(documentSize: document!.size)
    }

    /// Replaces the document with what its package holds now, after something else wrote it. Unlike `installProject`
    /// it keeps the viewport, the collapsed folders and the selection where those layers still exist, so the
    /// reload is invisible beyond the change itself. Undo history is session-only and starts over, as after an open.
    func reloadProject(_ snapshot: ProjectSnapshot) {
        guard let url = projectURL else { return }
        let viewport = self.viewport
        let collapsed = collapsedGroupIDs
        let active = activeLayerID
        let selected = selectedLayerIDs
        installProject(snapshot, from: url)
        self.viewport = viewport
        let ids = Set(snapshot.manifest.layers.map(\.id))
        collapsedGroupIDs = collapsed.intersection(ids)
        if let active, ids.contains(active) {
            activeLayerID = active
            selectedLayerIDs = selected.intersection(ids).union([active])
        }
    }

    func clearProject() {
        collapsedGroupIDs = []
        isMaskSelected = false
        cancelCrop()
        transformEdit = nil
        guideDrag = nil
        document = nil
        activeLayerID = nil
        renamingLayerID = nil
        projectURL = nil
        documentFormat = .comp
        sourceURL = nil
        history.reset()
    }

    func createNewProject(width: Int, height: Int) {
        guard !isProjectBusy, !isImporting, (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height) else { return }
        clearProject()
        createDocument(width: width, height: height, emptyLayer: true)
    }

    /// Shows a copy of `source` as a new document with no file (Duplicate). The copy gets a new document id and new
    /// layer ids, so it never shares an identity with the original (a layer dragged between tabs is found by its
    /// id); every layer property is carried, Photoshop layer data included, since a separate document may reuse
    /// its Photoshop layer IDs. There is no undo history, and the copy reads as unsaved until it is saved.
    func installCopy(of source: CanvasDocument, activeLayerID: UUID?) {
        let ids = Dictionary(source.layers.map { ($0.id, UUID()) }, uniquingKeysWith: { first, _ in first })
        let layers = source.layers.map { layer in
            var copy = layer.copy(as: ids[layer.id] ?? UUID())
            copy.psdExtras = layer.psdExtras
            copy.parentID = layer.parentID.flatMap { ids[$0] }
            copy.maskSourceID = layer.maskSourceID.flatMap { ids[$0] }
            return copy
        }
        var duplicate = CanvasDocument(width: source.width, height: source.height, layers: layers,
                                       resolution: source.resolution, guides: source.guides)
        duplicate.selection = source.selection
        duplicate.psdExtras = source.psdExtras
        clearProject()
        document = duplicate
        self.activeLayerID = activeLayerID.flatMap { ids[$0] }
        viewport.fit(documentSize: duplicate.size)
        history.markUnsaved()
    }

    /// What `settlePendingEdits` did: what it committed, cancelled or dismissed, in order, and each edit that could
    /// not be committed, with the reason.
    struct PendingEditSettlement: Equatable {
        struct Failure: Equatable {
            let edit: String
            let message: String
        }
        var settled: [String] = []
        var failed: [Failure] = []
    }

    /// Brings the session to rest so edits can run again, without showing an alert: every edit in progress is
    /// committed (`commit`) or cancelled, and a layer rename, the color picker, a dialog or an error alert (import,
    /// paint or crop) is dismissed. Each committed edit is its own undo step, as when committed in the app.
    /// An edit that fails is left out of `settled` and listed in `failed` with the message the app would have shown
    /// in its "Couldn't paint" or "Couldn't crop" alert; that alert is cleared so it never appears. Text or a crop
    /// that fails stays pending; a gradient or pixel move that fails is gone, as it is in the app. An edit that stays
    /// pending without a message (text that no longer validates, a crop frame that isn't valid) is listed in
    /// `failed` too. Imports and long operations are never touched: while `isImporting` or `isProjectBusy`, nothing
    /// is settled.
    func settlePendingEdits(commit: Bool) async -> PendingEditSettlement {
        guard !isImporting, !isProjectBusy else { return PendingEditSettlement() }
        var result = PendingEditSettlement()
        func settle(_ name: String, while pending: () -> Bool, _ action: () async -> Void) async {
            guard pending() else { return }
            brushError = nil
            cropError = nil
            await action()
            if let message = brushError ?? cropError {
                brushError = nil
                cropError = nil
                result.failed.append(.init(edit: name, message: message))
            } else if pending() {
                result.failed.append(.init(edit: name,
                    message: "It couldn't be \(commit ? "committed" : "cancelled") and is still in progress."))
            } else {
                result.settled.append(name)
            }
        }
        if renamingLayerID != nil { renamingLayerID = nil; result.settled.append("rename") }
        if selectionAmountOperation != nil { selectionAmountOperation = nil; result.settled.append("selection_dialog") }
        if showsNewDocument { showsNewDocument = false; result.settled.append("new_document_dialog") }
        if showsImporter { showsImporter = false; result.settled.append("open_dialog") }
        if importError != nil || brushError != nil || cropError != nil {
            importError = nil
            brushError = nil
            cropError = nil
            result.settled.append("error_alert")
        }
        await settle("color_picker", while: { colorPicker != nil }) { closeColorPicker(commit: commit) }
        await settle("adjustment", while: { adjustmentEditingID != nil }) { _ = finishAdjustmentEditing(commit: commit) }
        await settle("filter", while: { filterEdit != nil }) { if commit { await commitFilter() } else { cancelFilter() } }
        await settle("levels", while: { levels != nil }) { if commit { await commitLevels() } else { cancelLevels() } }
        await settle("hue_saturation", while: { hueSaturation != nil }) {
            if commit { await commitHueSaturation() } else { cancelHueSaturation() }
        }
        await settle("transform", while: { transformEdit != nil }) { if commit { commitTransform() } else { cancelTransform() } }
        await settle("pixel_move", while: { pixelMove != nil }) { if commit { await finishPixelMove() } else { cancelPixelMove() } }
        await settle("gradient", while: { gradientEdit != nil }) { if commit { await commitGradient() } else { cancelGradient() } }
        await settle("lasso", while: { lassoDraft != nil }) { if commit { finishLasso() } else { cancelLasso() } }
        await settle("shape", while: { shapeDraft != nil }) { if commit { finishShape() } else { cancelShape() } }
        await settle("crop", while: { cropRect != nil }) { if commit { await commitCrop() } else { cancelCrop() } }
        // Last: committing text needs every other edit out of the way.
        await settle("text", while: { textDraft != nil }) { if commit { _ = finishText() } else { cancelText() } }
        return result
    }
}
