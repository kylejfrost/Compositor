import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Plain values, read by the importers off the main actor as well as by the app.
nonisolated extension UTType {
    static let compositorProject = UTType(exportedAs: "com.compositor.project", conformingTo: .package)
    nonisolated static let photoshopImage = UTType(importedAs: "com.adobe.photoshop-image")
    nonisolated static let photoshopLargeImage = UTType(importedAs: "com.adobe.photoshop-large-image")
    static let importableImages: [UTType] = [.jpeg, .png, .heic, .tiff, .photoshopImage, .photoshopLargeImage, .rawImage, .svg]
}

nonisolated struct ProjectManifest: Codable, Sendable {
    /// The format version new saves write.
    static let current = 11
    /// Every version `load` accepts. The package-header check, the manifest check and the error
    /// message all read this, so they cannot drift apart when `current` is bumped.
    static let supported = 1...ProjectManifest.current

    var format = "com.compositor.project"
    var version = ProjectManifest.current
    var colorSpace = "sRGB"
    var resolution: Double? = nil // Older version-1 projects default to 72 pixels/inch.
    let documentID: UUID
    let width: Int
    let height: Int
    let activeLayerID: UUID?
    var layers: [ProjectLayerRecord]
    /// Alignment guides. Missing on versions 1–7.
    var guides: [CanvasGuide]? = nil
    /// What the Photoshop file the document came from held beyond its layers (version 10).
    var psd: PSDDocumentExtrasRecord? = nil
}

nonisolated struct ProjectLayerRecord: Codable, Sendable {
    let id: UUID
    let name: String
    var isVisible: Bool
    var transform: LayerTransform
    let imageFile: String?
    var parentID: UUID? = nil
    var isGroup: Bool? = nil
    var opacity: Double? = nil
    var blendMode: LayerBlendMode? = nil
    var maskFile: String? = nil
    var maskEnabled: Bool? = nil
    var maskSourceID: UUID? = nil
    var adjustment: LayerAdjustment? = nil
    /// A mask moved apart from its layer: where it sits on the document.
    var maskPlacement: LayerTransform? = nil
    /// Nil (older projects) is linked.
    var maskLinked: Bool? = nil
    /// A shape layer's shape, drawn again when the layer is scaled. Older versions ignore it and keep the pixels.
    var shape: LayerShapeStyle? = nil
    /// The stroke and drop shadow drawn around the layer.
    var effects: LayerEffects? = nil
    var text: LayerTextStyle? = nil
    /// Photoshop's layer locks (`lspf` bits) and Fill, version 10. Nil is no locks and full fill.
    var locks: LayerLocks? = nil
    var fillOpacity: Double? = nil
    /// The layer's Photoshop data, version 10; its blocks are a sidecar under `psd/`.
    var psd: PSDLayerExtrasRecord? = nil
    /// A smart object's settings, version 10. Its placement quad is in the unit coordinates of `transform`.
    var smartObject: SmartObjectInfo? = nil
    /// The smart object's contents, `smartobjects/<name>` (version 10). Nil when the document doesn't hold them.
    var smartObjectFile: SmartObjectFileRecord? = nil

    var psdExtras: PSDLayerExtras? { psd?.extras }
}

/// A smart object's contents as the manifest names them: the file `smartobjects/<name>` and its SHA-256. In memory the
/// record also holds the contents (`payload`), which saving writes and loading reads back, so every copy of a record
/// (undo, Image Size, Canvas Size, Crop) carries them without copying the bytes.
nonisolated struct SmartObjectFileRecord: Codable, Sendable {
    /// `<layer UUID>.<extension>`, the UUID of the first layer holding these contents: layers that share contents
    /// share one file.
    var name: String
    /// Lowercase hex.
    var sha256: String
    var payload: SmartObjectPayload?

    private enum CodingKeys: String, CodingKey { case name, sha256 }

    init(layerID: UUID, info: SmartObjectInfo, payload: SmartObjectPayload) {
        name = Self.name(layerID: layerID, info: info)
        sha256 = payload.sha256
        self.payload = payload
    }

    static func name(layerID: UUID, info: SmartObjectInfo) -> String { "\(layerID.uuidString).\(info.fileExtension)" }

    /// Each contents file.
    static let maximumBytes = 512 * 1024 * 1024
    /// All contents files together.
    static let maximumTotalBytes = 2 * 1024 * 1024 * 1024

    /// Named after one of `layerIDs` with a safe extension, and a SHA-256 in lowercase hex.
    func isValid(layerIDs: Set<UUID>) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])), id.uuidString == parts[0],
              layerIDs.contains(id), SmartObjectInfo.isSafeExtension(String(parts[1])) else { return false }
        return sha256.utf8.count == 64 && sha256.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}

nonisolated struct ProjectSnapshot: @unchecked Sendable {
    let manifest: ProjectManifest
    let images: [UUID: ImportedImage]
    var masks: [UUID: ImportedImage] = [:]
}

nonisolated enum ProjectError: LocalizedError {
    case invalid, version(Int), missingImage, tooLarge, encode
    var errorDescription: String? {
        switch self {
        case .invalid: "This is not a valid Compositor project, or its metadata is damaged."
        case .version(let version): "This project uses format version \(version). This app supports versions \(ProjectManifest.supported.lowerBound)–\(ProjectManifest.supported.upperBound)."
        case .missingImage: "An image inside the project is missing or damaged. The current document has not been replaced."
        case .tooLarge: "This project exceeds the supported canvas, layer, file-size, Photoshop data, or \(DocumentLimits.documentBudgetMegapixels)-megapixel document limit."
        case .encode: "An image could not be saved. The previous project has not been replaced."
        }
    }
}

actor ProjectStore {
    static let shared = ProjectStore()
    private struct Header: Decodable {
        let format: String
        let version: Int
    }

    func save(_ snapshot: ProjectSnapshot, to url: URL, quickLook: QuickLookImages? = nil) throws {
        var manifest = snapshot.manifest
        // Sidecar names are always the canonical ones for what is being written.
        for i in manifest.layers.indices {
            manifest.layers[i].psd = manifest.layers[i].psd.map { PSDLayerExtrasRecord($0.extras, layerID: manifest.layers[i].id) }
        }
        manifest.psd = manifest.psd.map { PSDDocumentExtrasRecord($0.extras) }
        // Photoshop data over the inline limits is too much to store, not a damaged project.
        guard manifest.layers.allSatisfy({ $0.psd.map { PSDLayerExtrasRecord.fitsInlineLimits($0.extras) } ?? true }),
              manifest.psd.map({ PSDDocumentExtrasRecord.fitsInlineLimits($0.extras) }) ?? true else {
            throw ProjectError.tooLarge
        }
        let smartObjectFiles = try smartObjectContents(&manifest)
        try validate(manifest)
        let sidecars = try photoshopSidecars(manifest)
        let profileFiles = try profileSidecars(manifest)
        var images: [String: FileWrapper] = [:]
        var pixels = 0, maskPixels = 0
        for layer in snapshot.manifest.layers {
          for isMask in [false, true] {
            guard let filename = isMask ? layer.maskFile : layer.imageFile else { continue }
            guard let asset = (isMask ? snapshot.masks : snapshot.images)[layer.id] else { throw ProjectError.missingImage }
            if isMask {
                guard LayerMask.isValid(asset.image) else { throw ProjectError.invalid }
                try checkSize(width: asset.image.width, height: asset.image.height, used: &maskPixels)
            } else { try checkSize(width: asset.image.width, height: asset.image.height, used: &pixels) }
            let data = try autoreleasepool {
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                    throw ProjectError.encode
                }
                CGImageDestinationAddImage(destination, asset.image, nil)
                guard CGImageDestinationFinalize(destination) else { throw ProjectError.encode }
                return data as Data
            }
            images[filename] = FileWrapper(regularFileWithContents: data)
          }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadata = try encoder.encode(manifest)
        guard metadata.count <= 4 * 1024 * 1024 else { throw ProjectError.tooLarge }
        var contents = [
            "manifest.json": FileWrapper(regularFileWithContents: metadata),
            "images": FileWrapper(directoryWithFileWrappers: images)
        ]
        if !sidecars.isEmpty {
            contents["psd"] = FileWrapper(directoryWithFileWrappers: sidecars.mapValues { FileWrapper(regularFileWithContents: $0) })
        }
        if !smartObjectFiles.isEmpty {
            contents["smartobjects"] = FileWrapper(directoryWithFileWrappers: smartObjectFiles.mapValues {
                FileWrapper(regularFileWithContents: $0)
            })
        }
        if !profileFiles.isEmpty {
            contents["profiles"] = FileWrapper(directoryWithFileWrappers: profileFiles.mapValues { FileWrapper(regularFileWithContents: $0) })
        }
        // Quick Look reads this by name; loading a project ignores it.
        if let quickLook {
            contents["QuickLook"] = FileWrapper(directoryWithFileWrappers: [
                "Preview.jpg": FileWrapper(regularFileWithContents: quickLook.preview),
            ])
        }
        let package = FileWrapper(directoryWithFileWrappers: contents)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { destination in
            do {
                // Foundation stages a sibling package and atomically replaces the
                // destination only once the complete package has been written.
                try package.write(to: destination, options: .atomic, originalContentsURL: nil)
            } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError as NSError? { throw error }
    }

    func load(from url: URL) throws -> ProjectSnapshot {
        var coordinationError: NSError?
        var result: Result<ProjectSnapshot, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { source in
            result = Result { try readPackage(source) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ProjectError.invalid }
        return try result.get()
    }

    private func readPackage(_ url: URL) throws -> ProjectSnapshot {
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw ProjectError.invalid }
        let metadataURL = url.appendingPathComponent("manifest.json")
        try checkFile(metadataURL, inside: url, maximumBytes: 4 * 1024 * 1024)
        let manifest: ProjectManifest
        let metadata = try Data(contentsOf: metadataURL)
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: metadata) }
        catch { throw ProjectError.invalid }
        guard header.format == "com.compositor.project" else { throw ProjectError.invalid }
        guard ProjectManifest.supported.contains(header.version) else { throw ProjectError.version(header.version) }
        do { manifest = try JSONDecoder().decode(ProjectManifest.self, from: metadata) }
        catch { throw ProjectError.invalid }
        try validate(manifest)
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        var pixels = 0, maskPixels = 0
        for layer in manifest.layers {
          for isMask in [false, true] {
            guard let filename = isMask ? layer.maskFile : layer.imageFile else { continue }
            let file = url.appendingPathComponent("images").appendingPathComponent(filename)
            try checkFile(file, inside: url, maximumBytes: 512 * 1024 * 1024)
            let asset = try autoreleasepool {
                // Decoded from the file's bytes in memory, not from the file: an image made from a file source stays tied
                // to it, and the next save replaces that file (ImageIO: "mmapped file changed"), so an image kept for undo
                // could later read someone else's pixels.
                let bytes = try Data(contentsOf: file)
                guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      CGImageSourceGetType(source) as String? == UTType.png.identifier,
                      CGImageSourceGetCount(source) == 1,
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      (properties[kCGImagePropertyDepth] as? Int ?? 8) <= 8 else { throw ProjectError.missingImage }
                if isMask { try checkSize(width: width, height: height, used: &maskPixels) }
                else { try checkSize(width: width, height: height, used: &pixels) }
                guard let image = CGImageSourceCreateImageAtIndex(source, 0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 96,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { throw ProjectError.missingImage }
                if isMask, !LayerMask.isValid(image) { throw ProjectError.invalid }
                return ImportedImage(image: image, thumbnail: thumbnail, name: layer.name)
            }
            if isMask { masks[layer.id] = asset } else { images[layer.id] = asset }
          }
        }
        try loadProfileSidecars(manifest, from: url)
        let withSidecars = try loadingPhotoshopSidecars(manifest, from: url)
        let withContents = try loadingSmartObjects(withSidecars, from: url)
        return ProjectSnapshot(manifest: linkingSmartObjects(withContents), images: images, masks: masks)
    }

    /// The contents to write under `smartobjects/`: one file per distinct contents (by SHA-256), named after the first
    /// layer holding them. Each smart object's record in `manifest` is given its file's name and SHA-256.
    private func smartObjectContents(_ manifest: inout ProjectManifest) throws -> [String: Data] {
        var names: [String: String] = [:]
        var files: [String: Data] = [:]
        var total = 0
        for index in manifest.layers.indices {
            guard var file = manifest.layers[index].smartObjectFile else { continue }
            guard let info = manifest.layers[index].smartObject else { throw ProjectError.invalid }
            guard let payload = file.payload else { throw ProjectError.missingImage }
            if let name = names[payload.sha256] {
                file.name = name
            } else {
                file.name = SmartObjectFileRecord.name(layerID: manifest.layers[index].id, info: info)
                total += payload.data.count
                guard payload.data.count <= SmartObjectFileRecord.maximumBytes,
                      total <= SmartObjectFileRecord.maximumTotalBytes else { throw ProjectError.tooLarge }
                names[payload.sha256] = file.name
                files[file.name] = payload.data
            }
            file.sha256 = payload.sha256
            manifest.layers[index].smartObjectFile = file
        }
        return files
    }

    /// `manifest` with each smart object's contents read from `smartobjects/` (mapped, not copied) and checked
    /// against its SHA-256. Layers naming one file share one payload. A missing, oversized or altered file makes the
    /// package invalid.
    private func loadingSmartObjects(_ manifest: ProjectManifest, from package: URL) throws -> ProjectManifest {
        var manifest = manifest
        var loaded: [String: SmartObjectPayload] = [:]
        var total = 0
        for index in manifest.layers.indices {
            guard var file = manifest.layers[index].smartObjectFile else { continue }
            let payload: SmartObjectPayload
            if let shared = loaded[file.name] {
                payload = shared
            } else {
                let url = package.appendingPathComponent("smartobjects").appendingPathComponent(file.name)
                guard FileManager.default.fileExists(atPath: url.path) else { throw ProjectError.invalid }
                try checkFile(url, inside: package, maximumBytes: SmartObjectFileRecord.maximumBytes)
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                total += data.count
                guard total <= SmartObjectFileRecord.maximumTotalBytes else { throw ProjectError.tooLarge }
                payload = SmartObjectPayload(data: data)
                loaded[file.name] = payload
            }
            guard payload.sha256 == file.sha256 else { throw ProjectError.invalid }
            file.payload = payload
            manifest.layers[index].smartObjectFile = file
        }
        return manifest
    }

    /// Version 10 projects saved before smart objects were modeled kept the file's linked-layer blocks (`lnk2`…)
    /// among the document's blocks, and each smart object only as its layer's `SoLd`. Their entries are taken out as
    /// a PSD import takes them: the ones a layer's settings name become its smart object's contents, the rest
    /// orphans, so each entry is kept once. The quads are placed against the layer as it is now. Import made pixels
    /// of those layers, which may have been painted since, so they get no `importedSmartObject`: a PSD writer can't
    /// take their pixels for the contents' and writes them as pixels until their contents are replaced.
    private func linkingSmartObjects(_ manifest: ProjectManifest) -> ProjectManifest {
        guard var psd = manifest.psd,
              psd.extras.globalBlocks.contains(where: { PSDSmartObjects.linkedBlockKeys.contains($0.key) }) else { return manifest }
        var manifest = manifest
        let split = PSDSmartObjects.decompose(psd.extras.globalBlocks)
        let placements = manifest.layers.map { record -> SmartObjectInfo? in
            guard record.smartObject == nil, record.isGroup != true, record.adjustment == nil, record.text == nil,
                  record.shape == nil, let extras = record.psd?.extras, extras.importedSmartObject == nil,
                  extras.placeholder == nil,
                  let block = PSDSmartObjects.placementKeys.lazy.compactMap({ extras.block($0) }).first else { return nil }
            return try? PSDSmartObjects.placement(block, in: record.transform)
        }
        let resolved = PSDSmartObjects.resolve(placements, entries: split.entries)
        for (index, smartObject) in resolved.smartObjects.enumerated() {
            guard let smartObject else { continue }
            let id = manifest.layers[index].id
            manifest.layers[index].smartObject = smartObject.info
            manifest.layers[index].smartObjectFile = smartObject.payload.map {
                SmartObjectFileRecord(layerID: id, info: smartObject.info, payload: $0)
            }
        }
        psd.extras.globalBlocks = split.blocks
        psd.extras.linkedBlockIndex = psd.extras.linkedBlockIndex ?? split.position
        psd.extras.orphanLinkedEntries += resolved.orphans
        manifest.psd = psd
        return manifest
    }

    /// Total bytes of every sidecar under `psd/`.
    private static let maximumPhotoshopBytes = 2 * 1024 * 1024 * 1024

    /// The `psd/` sidecars for `manifest` (already validated), in Photoshop's wire format.
    private func photoshopSidecars(_ manifest: ProjectManifest) throws -> [String: Data] {
        var files: [String: Data] = [:]
        var total = 0
        func add(_ name: String?, _ data: @autoclosure () -> Data, limit: Int) throws {
            guard let name else { return }
            let data = data()
            total += data.count
            guard data.count <= limit, total <= Self.maximumPhotoshopBytes else { throw ProjectError.tooLarge }
            files[name] = data
        }
        for layer in manifest.layers {
            guard let psd = layer.psd else { continue }
            let divider = psd.extras.sectionDividerExtras?.blocks ?? []
            guard PSDLayerExtrasRecord.canWrite(psd.extras.blocks), PSDLayerExtrasRecord.canWrite(divider) else {
                throw ProjectError.invalid
            }
            try add(psd.blocksFile, PSDBlockFile.encode(psd.extras.blocks), limit: PSDLayerExtrasRecord.maximumBlocksFileBytes)
            try add(psd.dividerBlocksFile, PSDBlockFile.encode(divider), limit: PSDLayerExtrasRecord.maximumBlocksFileBytes)
        }
        if let psd = manifest.psd {
            guard PSDDocumentExtrasRecord.canWrite(psd.extras.resources),
                  PSDLayerExtrasRecord.canWrite(psd.extras.globalBlocks) else { throw ProjectError.invalid }
            try add(psd.resourcesFile, PSDBlockFile.encode(psd.extras.resources), limit: PSDDocumentExtrasRecord.maximumResourcesBytes)
            try add(psd.blocksFile, PSDBlockFile.encode(psd.extras.globalBlocks, alignment: 4),
                    limit: PSDDocumentExtrasRecord.maximumBlocksBytes)
            try add(psd.linkedFile, PSDBlockFile.encode(linkedEntries: psd.extras.orphanLinkedEntries),
                    limit: PSDDocumentExtrasRecord.maximumLinkedBytes)
        }
        return files
    }

    /// `manifest` with every sidecar it names read from `psd/`. A missing, oversized or malformed sidecar makes
    /// the whole package invalid.
    private func loadingPhotoshopSidecars(_ manifest: ProjectManifest, from package: URL) throws -> ProjectManifest {
        var manifest = manifest
        var total = 0
        func read<T>(_ name: String, limit: Int, _ decode: (Data) throws -> T) throws -> T {
            let file = package.appendingPathComponent("psd").appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { throw ProjectError.invalid }
            try checkFile(file, inside: package, maximumBytes: limit)
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            total += data.count
            guard total <= Self.maximumPhotoshopBytes else { throw ProjectError.tooLarge }
            do { return try decode(data) } catch { throw ProjectError.invalid }
        }
        let blocksLimit = PSDLayerExtrasRecord.maximumBlocksFileBytes
        for i in manifest.layers.indices {
            guard var psd = manifest.layers[i].psd else { continue }
            if let name = psd.blocksFile {
                psd.extras.blocks = try read(name, limit: blocksLimit) { try PSDBlockFile.decodeBlocks($0, limit: blocksLimit) }
            }
            if let name = psd.dividerBlocksFile {
                psd.extras.sectionDividerExtras?.blocks = try read(name, limit: blocksLimit) {
                    try PSDBlockFile.decodeBlocks($0, limit: blocksLimit)
                }
            }
            manifest.layers[i].psd = psd
        }
        if var psd = manifest.psd {
            if let name = psd.resourcesFile {
                let limit = PSDDocumentExtrasRecord.maximumResourcesBytes
                psd.extras.resources = try read(name, limit: limit) { try PSDBlockFile.decodeResources($0, limit: limit) }
            }
            if let name = psd.blocksFile {
                let limit = PSDDocumentExtrasRecord.maximumBlocksBytes
                psd.extras.globalBlocks = try read(name, limit: limit) { try PSDBlockFile.decodeBlocks($0, limit: limit, alignment: 4) }
            }
            if let name = psd.linkedFile {
                let limit = PSDDocumentExtrasRecord.maximumLinkedBytes
                psd.extras.orphanLinkedEntries = try read(name, limit: limit) { try PSDBlockFile.decodeLinkedEntries($0, limit: limit) }
            }
            manifest.psd = psd
        }
        return manifest
    }

    private func validate(_ manifest: ProjectManifest) throws {
        guard manifest.format == "com.compositor.project" else { throw ProjectError.invalid }
        guard ProjectManifest.supported.contains(manifest.version) else { throw ProjectError.version(manifest.version) }
        guard manifest.colorSpace == "sRGB" else { throw ProjectError.invalid }
        if let resolution = manifest.resolution {
            guard resolution.isFinite, (1...9600).contains(resolution) else { throw ProjectError.invalid }
        }
        guard (1...DocumentLimits.maxSide).contains(manifest.width), (1...DocumentLimits.maxSide).contains(manifest.height) else { throw ProjectError.tooLarge }
        guard manifest.layers.count <= LayerLimitError.maximum else { throw LayerLimitError() }
        for layer in manifest.layers {
            if let text = layer.text {
                // Per-letter colors arrived in version 10, per-letter faces in version 11.
                guard text.isValid,
                      text.colorRuns == nil || manifest.version >= 10,
                      text.fontRuns == nil || manifest.version >= 11,
                      layer.imageFile != nil, layer.isGroup != true, layer.adjustment == nil else { throw ProjectError.invalid }
            }
            if let adjustment = layer.adjustment {
                guard manifest.version >= 7, layer.isGroup != true, layer.imageFile == nil, adjustment.isValid else { throw ProjectError.invalid }
                if adjustment.kind == .gaussianBlur || adjustment.kind == .motionBlur || adjustment.kind == .addNoise {
                    guard manifest.version >= 9 else { throw ProjectError.invalid }
                }
                // Profile layers arrived in version 10; `isValid` covers their amount and reference.
                if adjustment.kind == .profile || adjustment.profileSettings != nil {
                    guard manifest.version >= 10, adjustment.kind == .profile else { throw ProjectError.invalid }
                }
            }
            // Layer masks arrived in version 4, folder masks in version 6.
            guard layer.maskFile == nil || (manifest.version >= (layer.isGroup == true ? 6 : 4)
                && layer.maskFile == "\(layer.id.uuidString).mask.png"),
                layer.maskEnabled == nil || layer.maskFile != nil,
                layer.maskPlacement.map({ $0.isValid && layer.maskFile != nil }) ?? true else { throw ProjectError.invalid }
            let opacity = layer.opacity ?? 1
            let blend = layer.blendMode ?? .normal
            // Folders took an opacity of their own in version 8, which multiplies into what is inside
            // them; their blend mode is still pass-through, so it stays Normal.
            guard opacity.isFinite, (0...1).contains(opacity),
                  (manifest.version >= 3 || (opacity == 1 && blend == .normal)),
                  (layer.isGroup != true || (blend == .normal && (manifest.version >= 8 || opacity == 1))) else { throw ProjectError.invalid }
            // Photoshop locks, fill and data arrived in version 10. Locks keep every bit, known or not.
            if layer.locks != nil || layer.fillOpacity != nil || layer.psd != nil {
                guard manifest.version >= 10 else { throw ProjectError.invalid }
            }
            if let fill = layer.fillOpacity {
                guard fill.isFinite, (0...1).contains(fill) else { throw ProjectError.invalid }
            }
            if let psd = layer.psd {
                guard psd.isValid(for: layer.id) else { throw ProjectError.invalid }
            }
            // Shape strokes arrived in version 10: at most 500 pixels wide.
            if let stroke = layer.shape?.stroke {
                guard manifest.version >= 10, stroke.isValid else { throw ProjectError.invalid }
            }
            // Smart objects arrived in version 10. One is a layer of pixels: not a folder, adjustment, text or shape.
            if layer.smartObject != nil || layer.smartObjectFile != nil {
                guard manifest.version >= 10, let info = layer.smartObject, info.isValid, layer.isGroup != true,
                      layer.adjustment == nil, layer.text == nil, layer.shape == nil else { throw ProjectError.invalid }
            }
        }
        if let psd = manifest.psd {
            guard manifest.version >= 10, psd.isValid else { throw ProjectError.invalid }
        }
        try LayerHierarchy.validate(manifest.layers)
        try LiveMaskGraph.validate(manifest.layers)
        if manifest.version < 5, manifest.layers.contains(where: { $0.maskSourceID != nil }) { throw ProjectError.invalid }
        if manifest.version == 1, manifest.layers.contains(where: { $0.parentID != nil || $0.isGroup == true }) { throw ProjectError.invalid }
        var ids = Set<UUID>()
        for layer in manifest.layers {
            guard ids.insert(layer.id).inserted, layer.transform.isValid,
                  !layer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  layer.name.utf8.count <= 16_384,
                  layer.imageFile == nil || layer.imageFile == "\(layer.id.uuidString).png" else { throw ProjectError.invalid }
        }
        if let id = manifest.activeLayerID, !ids.contains(id) { throw ProjectError.invalid }
        // Contents files are named after a layer; layers naming one file agree on its SHA-256.
        var digests: [String: String] = [:]
        for file in manifest.layers.compactMap(\.smartObjectFile) {
            guard file.isValid(layerIDs: ids), digests.updateValue(file.sha256, forKey: file.name).map({ $0 == file.sha256 }) ?? true else {
                throw ProjectError.invalid
            }
        }
        try validateGuides(manifest)
    }

    private func validateGuides(_ manifest: ProjectManifest) throws {
        let guides = manifest.guides ?? []
        if manifest.version < 8 {
            guard guides.isEmpty else { throw ProjectError.invalid }
            return
        }
        guard guides.count <= 1_000 else { throw ProjectError.tooLarge }
        var ids = Set<UUID>()
        for guide in guides {
            guard ids.insert(guide.id).inserted, guide.position.isFinite, abs(guide.position) <= 1_000_000 else {
                throw ProjectError.invalid
            }
        }
    }

    private func checkSize(width: Int, height: Int, used: inout Int) throws {
        guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height), width * height <= DocumentLimits.documentPixelBudget - used else {
            throw ProjectError.tooLarge
        }
        used += width * height
    }

    func checkFile(_ file: URL, inside package: URL, maximumBytes: Int) throws {
        let root = package.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { throw ProjectError.invalid }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= maximumBytes else { throw ProjectError.tooLarge }
    }
}
