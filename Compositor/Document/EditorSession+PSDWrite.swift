import AppKit

extension EditorSession {
    /// The document as a PSD writer takes it, from the live session (not a resized or cropped project record, which
    /// may have left the Photoshop data behind): the project snapshot, each layer's Photoshop data, and the
    /// document's. Nil without a document.
    @MainActor
    func psdWriteRequest() -> PSDWriteRequest? {
        guard let document, let snapshot = projectSnapshot() else { return nil }
        var sidecars: [UUID: PSDLayerSidecar] = [:]
        for layer in document.layers {
            let font = layer.liveText.flatMap { NSFont(name: $0.style.fontName, size: $0.style.fontSize)?.fontName }
            sidecars[layer.id] = PSDLayerSidecar(locks: layer.locks, fillOpacity: layer.fillOpacity, extras: layer.psdExtras,
                                                 fontPostScriptName: font,
                                                 textMetrics: layer.liveText.map { PSDTextMetrics.measure($0.style) },
                                                 smartObject: layer.smartObject)
        }
        return PSDWriteRequest(snapshot: snapshot, sidecars: sidecars,
                               document: PSDDocumentSidecar(extras: document.psdExtras, activeLayerID: activeLayerID,
                                                            resolution: document.resolution, guides: document.guides))
    }
}
