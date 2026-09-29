import CoreGraphics
import Foundation

/// How a document is written as a PSD.
nonisolated struct PSDWriteOptions: Sendable {
    /// Lets the writer replace what Photoshop can't hold with an approximation, reported as a warning, instead of
    /// refusing the document.
    var allowLossy = false
    /// Writes back the Photoshop data the document was opened with (tagged blocks, image resources, record bytes).
    /// Off, every layer is written only as Compositor models it.
    var preserveExtras = true
    /// Folders collapsed in the Layers panel, written closed.
    var collapsedGroupIDs: Set<UUID> = []
    /// The writer named in the version resource (1057).
    var writerName = "Compositor \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")"
    /// Writes every text layer as pixels only, leaving out Photoshop's type data (`TySh`), for text that must stay
    /// exactly as Compositor draws it. The rendered pixels are written either way.
    var textAsPixels = false
}

/// Something the file holds differently from the document, such as a live mask applied to a layer's pixels.
nonisolated struct PSDWriteWarning: Equatable, Sendable {
    let layerName: String
    let message: String
    /// The file changes the layer in a way the save should be agreed to first: an adjustment rasterized, a clipping
    /// applied to pixels or left out, a curve resampled, a shape saved as pixels or as a plain path, the file's alpha
    /// channels or an adjustment's vector mask left out. The app asks before writing one (`PSDWriteReportSheet`); MCP
    /// needs `allow_lossy`. Other warnings are notes.
    var lossy = false
}

nonisolated struct PSDWriteReport: Sendable {
    var warnings: [PSDWriteWarning]
    var byteCount: Int
    /// Layer records written, folders' section dividers included.
    var layerRecordCount: Int
    /// The merged image has a fourth, transparency channel (and the layer count is stored negative).
    var wroteTransparencyChannel: Bool
}

nonisolated enum PSDWriteError: LocalizedError, Equatable {
    case tooLarge, render
    case unsupportedAdjustment(layerName: String, kind: AdjustmentKind)
    case invalidText(layerName: String)
    case sink(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge:
            "A Photoshop (.psd) file holds canvases and layers up to \(DocumentLimits.maxSide.formatted()) pixels per side (Compositor writes up to \(DocumentLimits.maxSurfaceMegapixels) megapixels), up to 32,767 layers, and 4 GB of layer data."
        case .render:
            "The document could not be rendered for the Photoshop file."
        case .unsupportedAdjustment(let layerName, let kind):
            "The \(kind.rawValue) adjustment layer “\(layerName)” can’t be saved in a Photoshop file."
        case .invalidText(let layerName):
            "The text layer “\(layerName)” can’t be saved in a Photoshop file."
        case .sink(let message):
            "The Photoshop file could not be saved. \(message)"
        }
    }
}

/// Everything a PSD is written from, taken on the main actor: the document as a project snapshot, plus the
/// Photoshop data the snapshot's records don't carry whole.
nonisolated struct PSDWriteRequest: @unchecked Sendable {
    let snapshot: ProjectSnapshot
    /// By layer ID. A layer without one is written from its record's own fields.
    let sidecars: [UUID: PSDLayerSidecar]
    let document: PSDDocumentSidecar
}

/// A layer's Photoshop state beyond its project record.
nonisolated struct PSDLayerSidecar: @unchecked Sendable {
    var locks: LayerLocks
    var fillOpacity: Double
    var extras: PSDLayerExtras?
    /// A live text layer's font, as Photoshop names it.
    var fontPostScriptName: String?
    /// Where a live text layer's raster puts its text, measured on the main actor with the layout that drew it.
    var textMetrics: PSDTextMetrics?
    /// The layer's smart object, with its contents.
    var smartObject: LayerSmartObject?
}

extension PSDLayerSidecar {
    /// What a saved record holds, for a layer the request has no sidecar for.
    nonisolated init(record: ProjectLayerRecord) {
        self.init(locks: record.locks ?? [], fillOpacity: record.fillOpacity ?? 1, extras: record.psdExtras,
                  fontPostScriptName: nil,
                  smartObject: record.smartObject.map { LayerSmartObject(info: $0, payload: record.smartObjectFile?.payload) })
    }
}

nonisolated struct PSDDocumentSidecar: Sendable {
    var extras: PSDDocumentExtras?
    var activeLayerID: UUID?
    var resolution: Double
    var guides: [CanvasGuide]
}

/// A PSD save planned ahead: the request, its options and the writer's layer plan (records and warnings), so a save
/// whose warnings are checked first (`PSDExporter.plan`) is written without planning it again.
nonisolated struct PSDWritePlan: @unchecked Sendable {
    let request: PSDWriteRequest
    let options: PSDWriteOptions
    let layers: PSDLayerRecordWriter.Plan
    /// What the file will hold differently from the document.
    var warnings: [PSDWriteWarning] { layers.warnings }

    init(_ request: PSDWriteRequest, options: PSDWriteOptions = .init()) throws {
        self.request = request
        self.options = options
        do {
            layers = try PSDLayerRecordWriter.plan(request, options: options)
        } catch let error as PSDWriteError {
            throw error
        } catch {
            throw PSDWriteError.render
        }
    }
}

/// Writes a document as a layered Photoshop file (Adobe's *Photoshop File Formats Specification*, version 1,
/// 8-bit RGB): header, image resources, layer and mask information, then the merged image. Layers are written
/// bottom to top as records whose pixels sit in axis-aligned rectangles (`PSDLayerBaker`); what the document was
/// opened with is written back unless the layer no longer matches it (`PSDLayerRecordWriter`).
nonisolated enum PSDWriter {
    static func data(for request: PSDWriteRequest, options: PSDWriteOptions = .init()) throws -> (data: Data, report: PSDWriteReport) {
        try data(for: try PSDWritePlan(request, options: options))
    }

    static func data(for plan: PSDWritePlan) throws -> (data: Data, report: PSDWriteReport) {
        var writer = PSDByteWriter()
        let report = try write(plan, into: &writer)
        return (writer.data, report)
    }

    /// Streams the file into a temporary file beside `url` and moves it into place only once it is complete, under
    /// file coordination, so a failed save leaves whatever was at `url` untouched.
    static func write(_ request: PSDWriteRequest, to url: URL, options: PSDWriteOptions = .init()) throws -> PSDWriteReport {
        try write(try PSDWritePlan(request, options: options), to: url)
    }

    /// `write(_:to:options:)` for a save already planned.
    static func write(_ plan: PSDWritePlan, to url: URL) throws -> PSDWriteReport {
        var coordinationError: NSError?
        var result: Result<PSDWriteReport, any Error> = .failure(PSDWriteError.sink("The file couldn’t be reached."))
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            result = Result {
                let sink: PSDFileSink
                do { sink = try PSDFileSink(replacing: target) } catch { throw PSDWriteError.sink(error.localizedDescription) }
                do {
                    var writer = PSDByteWriter(sink: sink)
                    let report = try write(plan, into: &writer)
                    do { try sink.commit() } catch { throw PSDWriteError.sink(error.localizedDescription) }
                    return report
                } catch {
                    sink.discard()
                    throw error
                }
            }
        }
        if let coordinationError { throw PSDWriteError.sink(coordinationError.localizedDescription) }
        return try result.get()
    }

    /// The file for `plan`, into `writer`. The merged image is rendered (`render`) last, once every layer record is
    /// written, so its planes are never in memory beside the layers'; the channel count and the sign of the layer
    /// count, which depend on whether it has transparency, are filled in then.
    static func write(_ plan: PSDWritePlan, into writer: inout PSDByteWriter,
                      render: (ProjectSnapshot) throws -> PSDCompositeWriter.Composite = PSDCompositeWriter.render) throws
        -> PSDWriteReport {
        let request = plan.request, options = plan.options, layers = plan.layers
        let manifest = request.snapshot.manifest
        let width = manifest.width, height = manifest.height
        guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height),
              width * height <= DocumentLimits.maxSurfacePixels else {
            throw PSDWriteError.tooLarge
        }
        do {
            guard layers.records.count <= Int(Int16.max) else { throw PSDWriteError.tooLarge }
            let preserved = options.preserveExtras ? request.document.extras : nil

            // Header: signature, version 1, six reserved bytes, channels (3, or 4 with the merged image's transparency:
            // filled in with it), height, width, depth 8, mode 3 (RGB).
            writer.code("8BPS")
            writer.u16(1)
            writer.bytes(Data(count: 6))
            let channels = writer.count
            writer.u16(3)
            writer.u32(UInt32(height))
            writer.u32(UInt32(width))
            writer.u16(8)
            writer.u16(3)
            // Color mode data: none for RGB.
            writer.u32(0)

            let target = layers.records.firstIndex { $0.sourceID != nil && $0.sourceID == request.document.activeLayerID }
            let resources = PSDImageResourcesWriter.resources(
                resolution: request.document.resolution, recordCount: layers.records.count,
                target: target.map { ($0, layers.records[$0].layerID) }, guides: request.document.guides,
                writerName: options.writerName, preserved: preserved?.resources ?? [],
                keepsTextLayersMetadata: layers.keepsTextLayersMetadata,
                canvas: preserved.flatMap { extras in
                    extras.canvasSize.flatMap { file in extras.canvasTransform.map { (file, $0, CGSize(width: width, height: height)) } }
                })
            PSDImageResourcesWriter.write(resources, into: &writer)

            // Layer and mask information: layer info (count, records, channel data, padded to 4), the global layer
            // mask info, then the document's tagged blocks: the file's own as they were, and one `lnk2` block (the
            // smart objects' contents, then the entries no smart object refers to) where the file had its
            // linked-layer blocks, else first.
            let section = writer.reserveU32()
            let info = writer.reserveU32()
            let infoStart = writer.count
            let count = Int16(layers.records.count)
            if !layers.records.isEmpty {
                // Negative when the merged image's first alpha channel is its transparency: filled in with it.
                writer.i16(count)
                try PSDLayerRecordWriter.write(layers.records, into: &writer)
                writer.pad(to: 4, from: infoStart)
            }
            try patchLength(from: infoStart, at: info, in: &writer)
            let globalMask = preserved?.globalLayerMaskInfo ?? Data()
            writer.u32(UInt32(truncatingIfNeeded: globalMask.count))
            writer.bytes(globalMask)
            let globalBlocks = preserved?.globalBlocks ?? []
            let linked = layers.linkedEntries + (preserved?.orphanLinkedEntries ?? []).map { PSDSmartObjectWriter.Entry(parts: [$0]) }
            let linkedIndex = min(max(0, preserved?.linkedBlockIndex ?? 0), globalBlocks.count)
            for (index, block) in globalBlocks.enumerated() {
                if index == linkedIndex { try PSDSmartObjectWriter.writeLinkedBlock(linked, into: &writer) }
                // `Txt2` holds Photoshop's text engine data for every type layer: written back only while each type
                // layer is, as it was read (Photoshop rebuilds it from the layers' `TySh` blocks otherwise).
                if layers.keepsTextEngineData || block.key != "Txt2" { writer.taggedBlock(block, alignment: 4) }
            }
            if linkedIndex == globalBlocks.count { try PSDSmartObjectWriter.writeLinkedBlock(linked, into: &writer) }
            try patchLength(from: section + 4, at: section, in: &writer)

            var composite = try render(request.snapshot)
            // A file whose layer count was negative (no Background layer) keeps its merged transparency, opaque or not.
            if preserved?.layerCountNegative == true, !layers.records.isEmpty { composite = composite.withTransparency() }
            if composite.hasTransparency {
                writer.patch(Data([0, 4]), at: channels)
                if !layers.records.isEmpty {
                    writer.patch(Data([UInt8(truncatingIfNeeded: UInt16(bitPattern: -count) >> 8),
                                       UInt8(truncatingIfNeeded: UInt16(bitPattern: -count))]), at: infoStart)
                }
            }
            PSDCompositeWriter.write(composite, into: &writer)
            return PSDWriteReport(warnings: layers.warnings, byteCount: writer.count, layerRecordCount: layers.records.count,
                                  wroteTransparencyChannel: composite.hasTransparency)
        } catch let error as PSDWriteError {
            throw error
        } catch {
            throw PSDWriteError.render
        }
    }

    /// Fills the `u32` at `offset` with the byte count written since `start`.
    private static func patchLength(from start: Int, at offset: Int, in writer: inout PSDByteWriter) throws {
        let length = writer.count - start
        guard length <= Int(UInt32.max) else { throw PSDWriteError.tooLarge }
        writer.patch(UInt32(length), at: offset)
    }
}

extension PSDByteWriter {
    /// A tagged block: signature, key, `u32` length, payload, then zeros to `alignment` (1 inside a layer record,
    /// where blocks are written back as read; 4 for the document's blocks, as Photoshop writes them). This writes
    /// version-1 files, where every length is four bytes, so a block read as `8B64` (a PSB's) is written as `8BIM`:
    /// readers, ours included, take an `8B64` block's length as eight bytes (`PSDBlockFile.hasWideLength`).
    nonisolated mutating func taggedBlock(_ block: PSDTaggedBlock, alignment: Int) {
        code(block.signature == "8B64" ? "8BIM" : block.signature)
        code(block.key)
        u32(UInt32(truncatingIfNeeded: block.data.count))
        let start = count
        bytes(block.data)
        pad(to: alignment, from: start)
    }
}
