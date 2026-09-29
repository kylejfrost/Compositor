import CoreGraphics
import Foundation

/// How replaced contents fill a smart object's placement: `.fit` inside it keeping their proportions, `.fill` covering
/// it exactly, their middle cropped to its proportions (`SmartObjectContents.cropped(toFill:)`), `.stretch` corner to
/// corner. Fitted contents are centered.
nonisolated enum SmartObjectFit: String, Codable, Sendable {
    case fit, fill, stretch
}

/// A file read to become smart-object contents: its bytes (hashed once), what they are, its name and their own size.
nonisolated struct SmartObjectContents: Sendable {
    let payload: SmartObjectPayload
    let kind: SmartObjectRasterizer.Kind
    let fileType: String
    let fileName: String
    let size: CGSize
    let resolution: Double?

    /// Photoshop's placed-layer type: 1 for vector contents, 2 for raster.
    var placedType: Int { [.svg, .pdf, .eps].contains(kind) ? 1 : 2 }

    /// Reads and measures `url` off the caller's actor. Contents a project couldn't save (over 512 MiB) are too large.
    /// The file is read, not mapped: another app may rewrite it while the smart object keeps its contents.
    @concurrent
    static func load(_ url: URL) async throws -> SmartObjectContents {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > SmartObjectFileRecord.maximumBytes {
            throw ImageImportError.tooLarge
        }
        let data = try Data(contentsOf: url)
        guard data.count <= SmartObjectFileRecord.maximumBytes else { throw ImageImportError.tooLarge }
        let kind = SmartObjectRasterizer.kind(fileType: "", fileName: url.lastPathComponent, data: data)
        let natural = try SmartObjectRasterizer.naturalSize(data, kind: kind, page: 1)
        guard [natural.size.width, natural.size.height].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 10_000_000 }) else {
            throw SmartObjectError.unreadable
        }
        return SmartObjectContents(payload: SmartObjectPayload(data: data), kind: kind,
                                   fileType: SmartObjectRasterizer.fileType(kind: kind, data: data),
                                   fileName: url.lastPathComponent, size: natural.size, resolution: natural.resolution)
    }
}

extension PlacementQuad {
    /// The lengths of the quad's top and left sides: its width and height, turned or not.
    nonisolated var sideLengths: CGSize {
        CGSize(width: hypot(topRight.x - topLeft.x, topRight.y - topLeft.y),
               height: hypot(bottomLeft.x - topLeft.x, bottomLeft.y - topLeft.y))
    }

    /// Contents of `natural` size placed in this quad (document pixels) as `fit` says: filling contents cover it as
    /// stretched ones do, as they were cropped to its proportions first. A perspective quad counts as the
    /// parallelogram on its top-left, top-right and bottom-left corners.
    nonisolated func placing(_ natural: CGSize, _ fit: SmartObjectFit) -> PlacementQuad {
        let across = CGVector(dx: topRight.x - topLeft.x, dy: topRight.y - topLeft.y)
        let down = CGVector(dx: bottomLeft.x - topLeft.x, dy: bottomLeft.y - topLeft.y)
        let width = sideLengths.width, height = sideLengths.height
        // The share of each side the contents span.
        var spanAcross: CGFloat = 1, spanDown: CGFloat = 1
        if fit == .fit, width > 0, height > 0, natural.width > 0, natural.height > 0 {
            let scale = min(width / natural.width, height / natural.height)
            spanAcross = natural.width * scale / width
            spanDown = natural.height * scale / height
        }
        func point(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
            CGPoint(x: topLeft.x + across.dx * a + down.dx * b, y: topLeft.y + across.dy * a + down.dy * b)
        }
        let left = (1 - spanAcross) / 2, top = (1 - spanDown) / 2
        return PlacementQuad(topLeft: point(left, top), topRight: point(left + spanAcross, top),
                             bottomRight: point(left + spanAcross, top + spanDown), bottomLeft: point(left, top + spanDown))
    }

    /// The map taking the unit square to this quad's top-left, top-right and bottom-left corners.
    nonisolated var unitSquareMap: CGAffineTransform {
        CGAffineTransform(a: topRight.x - topLeft.x, b: topRight.y - topLeft.y,
                          c: bottomLeft.x - topLeft.x, d: bottomLeft.y - topLeft.y, tx: topLeft.x, ty: topLeft.y)
    }
}

extension EditorSession {
    /// Photoshop's form of a new unique ID (`Idnt`, `placed`): a lowercase UUID.
    nonisolated static func newPhotoshopUUID() -> String { UUID().uuidString.lowercased() }

    /// Replaces a smart object's contents with the file at `url`, as one undo step: new IDs, file type and contents,
    /// and pixels drawn from them where the smart object places its contents, as `fitting` says (filling it keeps the
    /// crop that covers it as the contents). The layer is placed on the new contents, so their quad is its whole pixel
    /// grid; its name, effects, Photoshop data and mask (which stays where it was) are kept, and `contentsRevision`
    /// goes up by one. Contents that land where the layer already is (filled or stretched over a quad that is its
    /// whole grid, say) keep its transform exactly. Throws, changing nothing, when the file can't be read or drawn (a
    /// PSB, say), when the contents would place the layer beyond what a document holds, (`LayerLockedError`) when the
    /// layer's pixels are locked or its position is and the contents would move or resize it, and (`busy`) while
    /// another edit holds the document.
    ///
    /// Like other layer commands it commits a pending transform first. While the file is read and drawn the project
    /// is busy (`isProjectBusy`), so no transform, stroke or other edit starts meanwhile; callers must not already
    /// hold it.
    func replaceSmartObjectContents(_ id: UUID, with url: URL, fitting: SmartObjectFit = .fit) async throws {
        commitTransform()
        guard let layer = document?.layers.first(where: { $0.id == id }), let smartObject = layer.smartObject else {
            throw SmartObjectError.notSmartObject
        }
        guard canEditLayers else { throw SmartObjectError.busy }
        try checkUnlocked(layer, mask: false)
        let (contents, quad, transform, image) = try await whileProjectBusy {
            let frame = smartObject.info.quad.documentQuad(for: layer.transform)
            let contents = try await Self.contents(url, filling: fitting == .fill ? frame.sideLengths : nil)
            let quad = frame.placing(contents.size, fitting)
            var transform = Self.atLeastOnePixel(layer.transform.placing(quad.unitSquareMap))
            // A quad Photoshop placed beyond what a document holds places the layer there too; a project with such a
            // layer couldn't be saved.
            guard transform.isValid else { throw ImageImportError.tooLarge }
            if Self.placesAlike(transform, layer.transform) {
                transform = layer.transform
            } else if let blocker = document?.lockIndex.blocker(of: .position, on: id) {
                throw LayerLockedError(layerName: layer.name, folderName: blocker.id == id ? nil : blocker.name)
            }
            let image = try await SmartObjectRasterizer.rasterize(contents.payload.data, kind: contents.kind,
                                                                  pixelSize: contentsPixelSize(transform.size, replacing: id), page: 1)
            return (contents, quad, transform, image)
        }
        // Only over the layer the contents were placed against, and only while no other edit has started.
        guard let index = document?.layers.firstIndex(where: { $0.id == id }), let current = document?.layers[index],
              current.transform == layer.transform, current.smartObject == smartObject,
              current.asset?.image === layer.asset?.image else { throw SmartObjectError.changed }
        guard canEditLayers else { throw SmartObjectError.busy }
        var info = smartObject.info
        info.uniqueID = Self.newPhotoshopUUID()
        info.placedID = Self.newPhotoshopUUID()
        info.fileType = contents.fileType
        info.fileName = contents.fileName
        info.naturalSize = contents.size
        info.resolution = contents.resolution ?? 72
        info.quad = quad.unitQuad(in: transform)
        info.nonAffineQuad = nil
        info.placedType = contents.placedType
        info.pageNumber = 1
        info.pageCount = 1
        info.link = nil
        info.contentsRevision += 1
        info.isEmbedded = true
        var replaced = current
        replaced.asset = ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: current.name)
        if current.mask?.placement == nil, transform != current.transform { replaced.mask?.placement = current.transform }
        replaced.transform = transform
        replaced.smartObject = LayerSmartObject(info: info, payload: contents.payload)
        beginEdit("Replace Smart Object Contents")
        document?.layers[index] = replaced
        endEdit()
    }

    /// Places the file at `url` as a new smart-object layer above the active layer, as one undo step: its own size at
    /// the document's resolution (contents that don't say count as 72 pixels per inch), shrunk to fit the canvas and
    /// centered on `point`, or the canvas. Given `rect` (document pixels), the contents are placed in it instead, as
    /// `fitting` says (filling it keeps the crop that covers it as the contents), and `point` is not used. Returns the
    /// new layer's ID. Throws `invalidPlacement` for a point or rect that isn't finite or would put the layer beyond
    /// ±1,000,000 pixels, `ImageImportError.tooLarge` when the file is too large to keep or the layer would be larger
    /// than a document holds, `LayerLimitError` when the document already has `LayerLimitError.maximum` layers, and
    /// `busy` while another edit holds the document; like `replaceSmartObjectContents`, it commits a pending transform
    /// first and keeps the project busy while the file is read and drawn.
    @discardableResult
    func placeSmartObject(from url: URL, at point: CGPoint? = nil, fitting: SmartObjectFit = .fit,
                          in rect: CGRect? = nil) async throws -> UUID {
        commitTransform()
        guard let document else { throw SmartObjectError.noDocument }
        guard canEditLayers else { throw SmartObjectError.busy }
        if let point, rect == nil {
            guard point.x.isFinite, point.y.isFinite, abs(point.x) <= 1_000_000, abs(point.y) <= 1_000_000 else {
                throw SmartObjectError.invalidPlacement
            }
        }
        if let rect {
            guard rect.width > 0, rect.height > 0,
                  [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else {
                throw SmartObjectError.invalidPlacement
            }
        }
        guard document.layers.count < LayerLimitError.maximum else { throw LayerLimitError() }
        let (contents, transform, image) = try await whileProjectBusy {
            let contents = try await Self.contents(url, filling: fitting == .fill ? rect?.size : nil)
            let transform: LayerTransform
            if let rect {
                let box = PlacementQuad(topLeft: CGPoint(x: rect.minX, y: rect.minY), topRight: CGPoint(x: rect.maxX, y: rect.minY),
                                        bottomRight: CGPoint(x: rect.maxX, y: rect.maxY), bottomLeft: CGPoint(x: rect.minX, y: rect.maxY))
                    .placing(contents.size, fitting)
                transform = Self.atLeastOnePixel(LayerTransform(origin: box.topLeft, size: CGSize(width: box.topRight.x - box.topLeft.x,
                                                                                              height: box.bottomLeft.y - box.topLeft.y)))
                guard transform.isValid else { throw ImageImportError.tooLarge }
            } else {
                let scale = document.resolution / (contents.resolution ?? 72)
                let natural = CGSize(width: contents.size.width * scale, height: contents.size.height * scale)
                let fit = min(1, CGFloat(document.width) / natural.width, CGFloat(document.height) / natural.height)
                let size = CGSize(width: max(1, natural.width * fit), height: max(1, natural.height * fit))
                let center = point ?? CGPoint(x: CGFloat(document.width) / 2, y: CGFloat(document.height) / 2)
                transform = LayerTransform(origin: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), size: size)
                guard transform.isValid else { throw SmartObjectError.invalidPlacement }
            }
            let image = try await SmartObjectRasterizer.rasterize(contents.payload.data, kind: contents.kind,
                                                                  pixelSize: contentsPixelSize(transform.size, replacing: nil), page: 1)
            return (contents, transform, image)
        }
        guard self.document?.id == document.id else { throw SmartObjectError.changed }
        guard canEditLayers else { throw SmartObjectError.busy }
        let name = url.deletingPathExtension().lastPathComponent
        var layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: name),
                               origin: transform.origin)
        layer.transform = transform
        let info = SmartObjectInfo(uniqueID: Self.newPhotoshopUUID(), placedID: Self.newPhotoshopUUID(),
                                   fileType: contents.fileType, fileName: contents.fileName, naturalSize: contents.size,
                                   resolution: contents.resolution ?? 72, quad: .unitSquare,
                                   placedType: contents.placedType, isEmbedded: true)
        layer.smartObject = LayerSmartObject(info: info, payload: contents.payload)
        beginEdit("Place Smart Object")
        insertAboveActiveLayer(&layer)
        endEdit()
        return layer.id
    }

    /// Makes a smart object plain pixels, as one undo step: the pixels stay, the contents and settings go.
    func rasterizeSmartObject(_ id: UUID) {
        guard let index = document?.layers.firstIndex(where: { $0.id == id }), document?.layers[index].smartObject != nil else {
            return
        }
        beginEdit("Rasterize Smart Object")
        document?.layers[index].smartObject = nil
        endEdit()
    }

    /// The file at `url` read as contents, center-cropped to fill a frame of `frame` size when given
    /// (`SmartObjectContents.cropped(toFill:)`).
    private nonisolated static func contents(_ url: URL, filling frame: CGSize?) async throws -> SmartObjectContents {
        let contents = try await SmartObjectContents.load(url)
        guard let frame else { return contents }
        return try await contents.cropped(toFill: frame)
    }

    /// Runs `body` with the project busy, as filters and other long edits are, so no other edit starts while it
    /// awaits. The project is free again when it returns or throws.
    private func whileProjectBusy<T>(_ body: () async throws -> T) async rethrows -> T {
        isProjectBusy = true
        defer { isProjectBusy = false }
        return try await body()
    }

    /// Pixels for contents shown at `size` document pixels: one per document pixel, fewer beyond 30,000 a side, one
    /// surface's pixels, or what the document's budget has left (the layer being replaced gives its pixels back)
    /// (`DocumentLimits`).
    private func contentsPixelSize(_ size: CGSize, replacing id: UUID?) -> CGSize {
        let used = document?.layers.reduce(0) { total, layer in
            guard layer.id != id, let image = layer.asset?.image else { return total }
            return total + image.width * image.height
        } ?? 0
        let width = max(1, size.width.rounded()), height = max(1, size.height.rounded())
        let budget = CGFloat(max(1, min(DocumentLimits.maxSurfacePixels, DocumentLimits.documentPixelBudget - used)))
        let side = DocumentLimits.maxSideExtent
        let scale = min(1, side / width, side / height, (budget / (width * height)).squareRoot())
        guard scale < 1 else { return CGSize(width: width, height: height) }
        return CGSize(width: max(1, (width * scale).rounded(.down)), height: max(1, (height * scale).rounded(.down)))
    }

    /// `transform` at least a pixel each way, about its middle (a degenerate quad would otherwise make it invalid).
    private static func atLeastOnePixel(_ transform: LayerTransform) -> LayerTransform {
        guard transform.size.width < 1 || transform.size.height < 1 else { return transform }
        var result = transform
        let center = transform.center
        result.size = CGSize(width: max(1, transform.size.width), height: max(1, transform.size.height))
        result.origin = CGPoint(x: center.x - result.size.width / 2, y: center.y - result.size.height / 2)
        return result
    }

    /// Whether `a` and `b` put a layer's pixels in the same place: their corners within a thousandth of a pixel, so
    /// the rounding of re-placing a layer on its own quad doesn't count as moving it.
    private static func placesAlike(_ a: LayerTransform, _ b: LayerTransform) -> Bool {
        [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)].allSatisfy { unit in
            let p = a.documentPoint(ofUnit: unit), q = b.documentPoint(ofUnit: unit)
            return abs(p.x - q.x) <= 0.001 && abs(p.y - q.y) <= 0.001
        }
    }

    /// Puts `layer` above the active layer (at the top of the active folder) and makes it active.
    private func insertAboveActiveLayer(_ layer: inout ImageLayer) {
        guard let document else { return }
        layer.parentID = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
        if let parent = layer.parentID { collapsedGroupIDs.remove(parent) }
        // Worked out first: it reads the document, which the insert below has open for writing.
        let insertion = insertionIndex(above: activeLayerID, in: document.layers)
        self.document?.layers.insert(layer, at: insertion)
        activeLayerID = layer.id
    }
}
