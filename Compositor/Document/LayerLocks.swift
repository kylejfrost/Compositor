import Foundation

/// Photoshop's layer locks, bit for bit as the `lspf` block stores them (psd-tools `ProtectedSetting`), so a
/// file's value comes back out unchanged. `.all` is Photoshop's "Lock All", which implies every other lock.
nonisolated struct LayerLocks: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }

    static let transparency = LayerLocks(rawValue: 0x01)
    static let pixels = LayerLocks(rawValue: 0x02)
    static let position = LayerLocks(rawValue: 0x04)
    /// Keeps the layer from moving into or out of an artboard. Photoshop sets it on a Background layer.
    static let artboardNesting = LayerLocks(rawValue: 0x08)
    static let all = LayerLocks(rawValue: 0x8000_0000)

    var locksPosition: Bool { contains(.position) || contains(.all) }
    var locksPixels: Bool { contains(.pixels) || contains(.all) }
    var locksTransparency: Bool { contains(.transparency) || contains(.all) }
}

extension LayerLocks {
    /// Which of these locks stop an edit that `lock` stands for: `.position` moving or transforming the layer,
    /// `.pixels` changing its pixels, `.transparency` its transparent pixels, `.all` any other change (everything but
    /// showing, hiding and selecting it). Lock All stops every one of them.
    func blocking(_ lock: LayerLocks) -> LayerLocks {
        contains(.all) ? .all : intersection(lock.subtracting(.all))
    }
}

/// An edit refused because the layer (or a folder it sits in) is locked against it.
nonisolated struct LayerLockedError: LocalizedError, Equatable {
    let layerName: String
    /// The folder whose lock holds the layer, when the lock isn't the layer's own.
    var folderName: String? = nil

    var errorDescription: String? {
        guard let folderName else { return "“\(layerName)” is locked. Unlock it in the Layers panel to change it." }
        return "“\(layerName)” is inside the folder “\(folderName)”, which is locked. Unlock the folder in the Layers panel to change it."
    }
}

/// The locks in force on a document's layers, indexed once so that many layers can be asked about in one pass. As in
/// Photoshop, a folder's locks hold everything inside it: the locks in force on a layer are its own together with
/// those of every folder it sits in. The app's edits and the MCP tools both ask this.
struct LayerLockIndex {
    /// What stops an edit: the layer, or the innermost folder around it, whose locks do, and those of its locks.
    struct Blocker: Equatable {
        let id: UUID
        let name: String
        let locks: LayerLocks
    }

    private struct Node {
        let locks: LayerLocks
        let parentID: UUID?
        let name: String
    }

    private let nodes: [UUID: Node]

    init(_ layers: [ImageLayer]) {
        nodes = Dictionary(layers.map { ($0.id, Node(locks: $0.locks, parentID: $0.parentID, name: $0.name)) },
                           uniquingKeysWith: { first, _ in first })
    }

    /// `id`'s own locks together with those of every folder it sits in.
    func locks(of id: UUID) -> LayerLocks {
        holders(of: id).reduce(into: []) { $0.formUnion($1.node.locks) }
    }

    /// What stops an edit `lock` stands for (see `LayerLocks.blocking`) on `id`, or nil when nothing does.
    func blocker(of lock: LayerLocks, on id: UUID) -> Blocker? {
        for (holder, node) in holders(of: id) {
            let blocking = node.locks.blocking(lock)
            if !blocking.isEmpty { return Blocker(id: holder, name: node.name, locks: blocking) }
        }
        return nil
    }

    /// `id`, then each folder it sits in, outward; the depth bound matches LayerHierarchy's.
    private func holders(of id: UUID) -> [(id: UUID, node: Node)] {
        var chain: [(id: UUID, node: Node)] = [], current: UUID? = id
        while let next = current, chain.count <= 64, let node = nodes[next] {
            chain.append((next, node))
            current = node.parentID
        }
        return chain
    }
}

extension CanvasDocument {
    /// The locks in force on this document's layers (see `LayerLockIndex`).
    var lockIndex: LayerLockIndex { LayerLockIndex(layers) }

    /// `id`'s own locks together with those of every folder it sits in: as in Photoshop, locking a folder locks
    /// what is inside it.
    func effectiveLocks(of id: UUID) -> LayerLocks { lockIndex.locks(of: id) }

    /// `effectiveLocks(of:)` for every layer at once (empty when nothing is locked), for the Layers panel.
    var effectiveLocksByID: [UUID: LayerLocks] {
        guard layers.contains(where: { !$0.locks.isEmpty }) else { return [:] }
        let index = lockIndex
        var result: [UUID: LayerLocks] = [:]
        for layer in layers {
            let locks = index.locks(of: layer.id)
            if !locks.isEmpty { result[layer.id] = locks }
        }
        return result
    }
}

extension EditorSession {
    /// Whether any of `ids` (or a folder one sits in) has its position locked, so they can't be moved or transformed.
    func isPositionLocked(_ ids: [UUID]) -> Bool {
        guard let document, !ids.isEmpty else { return false }
        let index = document.lockIndex
        return ids.contains { index.blocker(of: .position, on: $0) != nil }
    }

    /// Throws `LayerLockedError` when `layer`'s pixels — or, with `mask`, its mask — are locked: pixels by Lock Pixels
    /// or Lock All, a mask only by Lock All (Photoshop's Lock Pixels leaves the mask editable), the layer's own or a
    /// folder's around it. An inherited lock is named by its folder.
    func checkUnlocked(_ layer: ImageLayer, mask: Bool) throws {
        guard let blocker = document?.lockIndex.blocker(of: mask ? .all : .pixels, on: layer.id) else { return }
        throw LayerLockedError(layerName: layer.name, folderName: blocker.id == layer.id ? nil : blocker.name)
    }

    /// Whether Lock All holds `id`, its own or a folder's around it: what keeps its effects and adjustment settings,
    /// among everything but showing, hiding and selecting it, from changing (a pixel lock leaves those editable).
    func isHeldByLockAll(_ id: UUID) -> Bool {
        document?.lockIndex.blocker(of: .all, on: id) != nil
    }

    /// `checkUnlocked` for an edit about to start: false, with the reason in `brushError`, when it must not.
    func pixelsUnlocked(_ layer: ImageLayer, mask: Bool) -> Bool {
        do { try checkUnlocked(layer, mask: mask); return true }
        catch { brushError = error.localizedDescription; return false }
    }

    /// Whether an edit `lock` stands for (see `LayerLocks.blocking`) may change every one of `ids`: false, with the
    /// reason in `brushError`, when a layer's own lock or a folder's around it holds one. The app asks what the MCP
    /// tools ask of the same edit: `.pixels` for one that rewrites pixels (Merge Down), `.all` for the others
    /// (deleting a layer, its mask, its clipping, its text).
    func unlocked(_ ids: [UUID], for lock: LayerLocks) -> Bool {
        guard let document else { return false }
        let index = document.lockIndex
        for id in ids {
            guard let blocker = index.blocker(of: lock, on: id) else { continue }
            let name = document.layers.first { $0.id == id }?.name ?? ""
            brushError = LayerLockedError(layerName: name, folderName: blocker.id == id ? nil : blocker.name).localizedDescription
            return false
        }
        return true
    }

    /// Whether `ids` may be deleted: Lock All holds each and everything inside it, and a layer that stays but is
    /// clipped to one of them has its pixels rewritten (the clip baked in), which Lock Pixels holds too.
    func deletionUnlocked(_ ids: [UUID]) -> Bool {
        guard let layers = document?.layers else { return false }
        let removed = ids.reduce(into: Set<UUID>()) { $0.formUnion(descendantIDs(of: $1).union([$1])) }
        let clipped = layers.filter { !removed.contains($0.id) && $0.maskSourceID.map(removed.contains) == true }
        return unlocked(layers.map(\.id).filter(removed.contains), for: .all) && unlocked(clipped.map(\.id), for: .pixels)
    }
}

/// The color Photoshop tags a layer with in its Layers panel (`lclr`). Values Photoshop may add later read as
/// `.none`; the block itself is kept with the layer's other Photoshop data.
nonisolated enum LayerColorLabel: UInt16, Codable, Sendable, CaseIterable {
    case none = 0, red, orange, yellow, green, blue, violet, gray
}

extension EditorSession {
    /// The Layers panel's lock button: clears the locks a person sets (transparency, pixels, position, Lock All) and
    /// keeps Photoshop's artboard-nesting lock, which a Background has. Like set_layer_locks, it leaves a layer inside
    /// a Lock All folder alone until the folder is unlocked.
    func unlockUserLocks(on id: UUID) {
        guard let layer = document?.layers.first(where: { $0.id == id }), canUnlockUserLocks(of: layer) else { return }
        setLocks(layer.locks.intersection(.artboardNesting), on: id)
    }

    /// Whether `unlockUserLocks` would change `layer`: it has a lock a person sets, and no folder around it is under
    /// Lock All.
    func canUnlockUserLocks(of layer: ImageLayer) -> Bool {
        guard !layer.locks.subtracting(.artboardNesting).isEmpty else { return false }
        return layer.parentID.map { document?.lockIndex.blocker(of: .all, on: $0) == nil } ?? true
    }

    /// Sets a layer's (or folder's) locks as one undo step, "Lock Layer" ("Unlock Layer" when clearing them all).
    /// Setting the locks it already has records nothing.
    func setLocks(_ locks: LayerLocks, on id: UUID) {
        guard canEditLayers, let index = document?.layers.firstIndex(where: { $0.id == id }),
              document?.layers[index].locks != locks else { return }
        finishOpacityEdit()
        beginEdit(locks.isEmpty ? "Unlock Layer" : "Lock Layer")
        document?.layers[index].locks = locks
        endEdit()
    }
}
