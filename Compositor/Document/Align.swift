import CoreGraphics
import Foundation

/// The edge (or middle) of each layer's box that Align lines up.
nonisolated enum AlignEdge: String, Codable, Sendable { case left, centerX = "center_x", right, top, centerY = "center_y", bottom }
/// What layers align to: the selection's bounds, the canvas, or the box around the layers themselves.
nonisolated enum AlignTarget: String, Codable, Sendable { case selection, canvas, layers }
nonisolated enum DistributeAxis: String, Codable, Sendable { case horizontal, vertical }

/// Why layers could not be aligned or distributed.
nonisolated enum AlignError: LocalizedError, Equatable, Sendable {
    /// Aligning to the selection with nothing selected.
    case noSelection
    /// Fewer distinct layers than the operation needs.
    case tooFewLayers(needed: Int)
    /// A layer with nothing to line up: no pixels, or (measured by content) only transparent ones.
    case noBounds(String)
    /// Moving this layer (or something in this folder) would take it beyond ±1,000,000 pixels.
    case tooFar(String)

    var errorDescription: String? {
        switch self {
        case .noSelection: "There is no selection to align to."
        case .tooFewLayers(let needed): "This needs at least \(needed) layers (a layer inside a folder that is also listed moves with it)."
        case .noBounds(let name): "'\(name)' has no pixels to line up."
        case .tooFar(let name): "Moving '\(name)' there would take a layer beyond ±1,000,000 pixels, so nothing moved."
        }
    }
}

extension AlignEdge {
    /// How far `box` moves so this edge of it meets the same edge of `reference`.
    func offset(moving box: CGRect, to reference: CGRect) -> CGPoint {
        switch self {
        case .left: CGPoint(x: reference.minX - box.minX, y: 0)
        case .centerX: CGPoint(x: reference.midX - box.midX, y: 0)
        case .right: CGPoint(x: reference.maxX - box.maxX, y: 0)
        case .top: CGPoint(x: 0, y: reference.minY - box.minY)
        case .centerY: CGPoint(x: 0, y: reference.midY - box.midY)
        case .bottom: CGPoint(x: 0, y: reference.maxY - box.maxY)
        }
    }
}

extension EditorSession {
    /// Moves each layer so its `edge` meets the same edge of the canvas, the selection's bounds, or the box around all
    /// the layers, as one undo step "Align Layers". Each layer is measured by the upright box around its corners, or
    /// with `useContentBounds` around its pixels that aren't transparent; a folder by the box around the pixel layers
    /// shown inside it, and everything in it moves along. A layer inside a folder that is also listed moves with it.
    func alignLayers(_ ids: [UUID], _ edge: AlignEdge, to target: AlignTarget, useContentBounds: Bool = false) throws {
        commitTransform()
        guard canEditLayers, let document else { return }
        let roots = alignRoots(ids)
        if target == .layers, roots.count < 2 { throw AlignError.tooFewLayers(needed: 2) }
        let boxes = try roots.map { try alignBounds(of: $0, contentOnly: useContentBounds) }
        let reference: CGRect
        switch target {
        case .canvas: reference = CGRect(origin: .zero, size: document.size)
        case .selection:
            guard let selection = document.selection, !selection.isEmpty else { throw AlignError.noSelection }
            reference = selection.path.boundingBoxOfPath
        case .layers: reference = boxes.reduce(CGRect.null) { $0.union($1) }
        }
        try moveRoots(Array(zip(roots, boxes.map { edge.offset(moving: $0, to: reference) })), name: "Align Layers")
    }

    /// Spaces three or more layers evenly along `axis`, as one undo step "Distribute Layers": the gaps between their
    /// boxes (measured as `alignLayers` does) become equal, the first and last in line staying put; or, given a
    /// `spacing`, each gap is that many pixels, laid out from the first. Layers are taken in order of their middles.
    func distributeLayers(_ ids: [UUID], axis: DistributeAxis, spacing: CGFloat? = nil) throws {
        commitTransform()
        guard canEditLayers, document != nil, spacing?.isFinite != false else { return }
        let roots = alignRoots(ids)
        guard roots.count >= 3 else { throw AlignError.tooFewLayers(needed: 3) }
        let horizontal = axis == .horizontal
        func start(_ box: CGRect) -> CGFloat { horizontal ? box.minX : box.minY }
        func length(_ box: CGRect) -> CGFloat { horizontal ? box.width : box.height }
        func middle(_ box: CGRect) -> CGFloat { horizontal ? box.midX : box.midY }
        let line = try zip(roots, roots.map { try alignBounds(of: $0, contentOnly: false) }).enumerated()
            .sorted { (middle($0.element.1), $0.offset) < (middle($1.element.1), $1.offset) }.map(\.element)
        guard let first = line.first?.1, let last = line.last?.1 else { return }
        let gap = spacing ?? (start(last) + length(last) - start(first) - line.map { length($0.1) }.reduce(0, +)) / CGFloat(line.count - 1)
        var position = start(first) + length(first) + gap
        var moves: [(UUID, CGPoint)] = []
        // With even gaps the last one is where it is already.
        for (id, box) in line.dropFirst().dropLast(spacing == nil ? 1 : 0) {
            let move = position - start(box)
            moves.append((id, horizontal ? CGPoint(x: move, y: 0) : CGPoint(x: 0, y: move)))
            position += length(box) + gap
        }
        try moveRoots(moves, name: "Distribute Layers")
    }

    /// Moves each layer (a folder with its contents) by its own offset, as one undo step. Offsets under a millionth
    /// of a pixel are rounding left over from measuring a turned layer, and move nothing, so aligning twice records
    /// nothing the second time. Every layer moves or none does: an offset that would take any layer beyond ±1,000,000
    /// pixels throws `AlignError.tooFar` before anything moves.
    private func moveRoots(_ moves: [(UUID, CGPoint)], name: String) throws {
        let moves = moves.filter { abs($0.1.x) >= 1e-6 || abs($0.1.y) >= 1e-6 }
        guard !moves.isEmpty, let document else { return }
        let byID = Dictionary(document.layers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, offset) in moves {
            for moved in descendantIDs(of: id).union([id]) {
                guard var transform = byID[moved]?.transform else { continue }
                transform.origin.x += offset.x
                transform.origin.y += offset.y
                guard transform.isValid else { throw AlignError.tooFar(byID[id]?.name ?? "") }
            }
        }
        finishOpacityEdit()
        beginEdit(name)
        for (id, offset) in moves { translateLayers([id], by: offset, name: name) }
        endEdit()
    }

    /// `ids` that exist, once each and in order, leaving out any inside a folder that is also listed.
    private func alignRoots(_ ids: [UUID]) -> [UUID] {
        guard let document else { return [] }
        let byID = Dictionary(document.layers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let listed = Set(ids)
        var seen = Set<UUID>()
        return ids.filter { id in
            guard byID[id] != nil, seen.insert(id).inserted else { return false }
            var parent = byID[id]?.parentID, depth = 0
            while let folder = parent, depth <= 64 {
                if listed.contains(folder) { return false }
                parent = byID[folder]?.parentID
                depth += 1
            }
            return true
        }
    }

    /// The upright box, in document pixels, a layer lines up by: around its corners, or with `contentOnly` around its
    /// pixels that aren't transparent. A folder's is the box around the pixel layers shown inside it (its own
    /// transform is only the canvas it was made on), which is also what placing a folder by x, y and an anchor uses.
    func alignBounds(of id: UUID, contentOnly: Bool) throws -> CGRect {
        guard let document, let layer = document.layers.first(where: { $0.id == id }) else { throw AlignError.noBounds("") }
        var points: [CGPoint] = []
        for member in layer.isGroup ? shownPixelLayers(in: layer.id, of: document) : [layer] {
            guard let image = member.asset?.image else { continue }
            guard contentOnly else {
                points += DistortWarp.corners(of: member.transform)
                continue
            }
            guard let pixels = try ContentBounds.pixelBounds(of: image) else { continue }
            let map = BrushRaster.pixelToDocument(member.transform, width: image.width, height: image.height)
            points += [CGPoint(x: pixels.minX, y: pixels.minY), CGPoint(x: pixels.maxX, y: pixels.minY),
                       CGPoint(x: pixels.maxX, y: pixels.maxY), CGPoint(x: pixels.minX, y: pixels.maxY)].map { $0.applying(map) }
        }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { throw AlignError.noBounds(layer.name) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The pixel layers inside `folder` that show when it does: each one visible, and every folder between it and
    /// `folder` too.
    func shownPixelLayers(in folder: UUID, of document: CanvasDocument) -> [ImageLayer] {
        let byID = Dictionary(document.layers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let inside = descendantIDs(of: folder)
        return document.layers.filter { layer in
            guard inside.contains(layer.id), !layer.isGroup, layer.asset != nil else { return false }
            var node: ImageLayer? = layer, depth = 0
            while let current = node, current.id != folder, depth <= 64 {
                guard current.isVisible else { return false }
                node = current.parentID.flatMap { byID[$0] }
                depth += 1
            }
            return true
        }
    }
}
