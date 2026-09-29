import AppKit
import SwiftUI
import Testing
@testable import Compositor

/// The app's own layer edits follow the rules the MCP tools apply to locks: Merge Down rewrites pixels (held by Lock
/// Pixels and Lock All), deleting a layer, its mask, its clipping and its text are held by Lock All, each by the
/// layer's own lock or a folder's around it; a refused edit says why. The Layers panel's lock button clears only the
/// locks a person sets and leaves a layer inside a Lock All folder alone, as set_layer_locks does.
@MainActor struct AppLayerLockTests {
    // MARK: Helpers

    private func solid(_ gray: CGFloat) throws -> CGImage {
        let context = try BrushRaster.context(width: 20, height: 20, mask: false)
        context.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        return try #require(context.makeImage())
    }

    /// A 40 × 40 document holding "Bottom" and then "Top" (active), each a 20-pixel square.
    private func session() throws -> (session: EditorSession, bottom: UUID, top: UUID) {
        let session = EditorSession()
        session.createDocument(width: 40, height: 40)
        var ids: [UUID] = []
        for (name, gray) in [("Bottom", 0.2), ("Top", 0.8)] {
            let image = try solid(gray)
            var layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: image, name: name), origin: .zero)
            layer.name = name
            session.document?.layers.append(layer)
            ids.append(layer.id)
        }
        session.activeLayerID = ids[1]
        session.selectedLayerIDs = [ids[1]]
        return (session, ids[0], ids[1])
    }

    private func setLocks(_ session: EditorSession, _ id: UUID, _ locks: LayerLocks) throws {
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].locks = locks
    }

    private func layer(_ session: EditorSession, _ id: UUID) -> ImageLayer? {
        session.document?.layers.first { $0.id == id }
    }

    /// A folder "Folder" holding `id`, with `locks`.
    @discardableResult
    private func folder(_ session: EditorSession, holding id: UUID, locks: LayerLocks) throws -> UUID {
        var folder = ImageLayer(name: "Folder", blankSize: CGSize(width: 40, height: 40))
        folder.isGroup = true
        folder.locks = locks
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].parentID = folder.id
        session.document?.layers.append(folder)
        return folder.id
    }

    // MARK: Merge Down

    /// ⌘E into a pixel-locked layer is refused and says why; the lock stays. Unlocked, it merges.
    @Test func mergeDownIntoAPixelLockedLayerIsRefused() throws {
        let (session, bottom, _) = try session()
        try setLocks(session, bottom, [.pixels])
        let steps = session.history.undoCount
        session.mergeLayers()
        #expect(session.document?.layers.count == 2 && layer(session, bottom)?.locks == [.pixels])
        #expect(session.history.undoCount == steps)
        #expect(session.brushError == LayerLockedError(layerName: "Bottom").localizedDescription)

        try setLocks(session, bottom, [])
        session.brushError = nil
        session.mergeLayers()
        #expect(session.document?.layers.count == 1 && session.brushError == nil)
    }

    // MARK: Deleting

    /// Lock All, the layer's own or its folder's, holds deleting it; Lock Pixels doesn't, as in Photoshop.
    @Test func deletingALayerHeldByLockAllIsRefused() throws {
        let (session, bottom, top) = try session()
        try setLocks(session, top, [.all])
        session.deleteLayer(top)
        #expect(layer(session, top) != nil)
        #expect(session.brushError == LayerLockedError(layerName: "Top").localizedDescription)

        // Several selected: none goes when one of them is held.
        session.selectedLayerIDs = [bottom, top]
        session.deleteSelectedLayers()
        #expect(layer(session, bottom) != nil && layer(session, top) != nil)

        try setLocks(session, top, [])
        try folder(session, holding: bottom, locks: [.all])
        session.brushError = nil
        session.deleteLayer(bottom)
        #expect(layer(session, bottom) != nil)
        #expect(session.brushError == LayerLockedError(layerName: "Bottom", folderName: "Folder").localizedDescription)

        try setLocks(session, top, [.pixels])
        session.deleteLayer(top)
        #expect(layer(session, top) == nil)
    }

    // MARK: Masks, clipping and text

    /// Lock All holds adding, switching and deleting a layer's mask, and clipping it; a refused edit says why.
    @Test func masksAndClippingOnALockAllLayerAreRefused() throws {
        let (session, _, top) = try session()
        try setLocks(session, top, [.all])
        session.addLayerMask(revealing: true)
        #expect(layer(session, top)?.mask == nil)
        #expect(session.brushError == LayerLockedError(layerName: "Top").localizedDescription)
        session.toggleClippingMask(top)
        #expect(layer(session, top)?.maskSourceID == nil)

        try setLocks(session, top, [])
        session.addLayerMask(revealing: true)
        #expect(layer(session, top)?.mask != nil)
        try setLocks(session, top, [.all])
        session.toggleLayerMask()
        #expect(layer(session, top)?.mask?.isEnabled == true)
        session.deleteLayerMask()
        #expect(layer(session, top)?.mask != nil)

        // Lock Pixels leaves them alone, as in Photoshop and the MCP tools.
        try setLocks(session, top, [.pixels])
        session.toggleClippingMask(top)
        #expect(layer(session, top)?.maskSourceID != nil)
        session.deleteLayerMask()
        #expect(layer(session, top)?.mask == nil)
    }

    /// Lock All holds a text layer's text: the Type tool doesn't open it for editing, a draft already open doesn't
    /// apply, and Fill doesn't recolor it.
    @Test func textOnALockAllLayerIsRefused() throws {
        let session = EditorSession()
        session.createDocument(width: 200, height: 100)
        var style = LayerTextStyle()
        style.content = "Locked"
        let id = try session.addTextLayer(style, at: CGPoint(x: 20, y: 20))
        let text = try #require(layer(session, id)?.liveText)
        let draft = TextDraft(documentID: try #require(session.document?.id), layerID: id, origin: CGPoint(x: 20, y: 20),
                              style: { var changed = text.style; changed.content = "Changed"; return changed }())
        try setLocks(session, id, [.all])

        session.activeLayerID = id
        session.editActiveText()
        #expect(session.textDraft == nil)
        #expect(session.brushError == LayerLockedError(layerName: layer(session, id)?.name ?? "").localizedDescription)
        #expect(!session.applyText(draft))
        #expect(!session.recolorText(id, to: PaletteColor(red: 1, green: 0, blue: 0)))
        #expect(layer(session, id)?.liveText?.style == text.style)

        try setLocks(session, id, [])
        #expect(session.applyText(draft))
        #expect(layer(session, id)?.liveText?.style.content == "Changed")
    }

    // MARK: The Layers panel's lock button

    /// The lock button clears the locks a person sets and keeps Photoshop's artboard-nesting lock on a Background;
    /// inside a Lock All folder it is dimmed and does nothing, as set_layer_locks refuses there.
    @Test func theLockButtonClearsOnlyUserLocksAndRespectsLockAllFolders() throws {
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap { descendants($0) } }
        func locks(in session: EditorSession) throws -> [NSButton] {
            let host = NSHostingView(rootView: LayersPanel(session: session))
            host.frame = CGRect(x: 0, y: 0, width: 252, height: 600)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let table = try #require(descendants(host).compactMap { $0 as? NSTableView }.first)
            return (0..<table.numberOfRows).compactMap { table.view(atColumn: 0, row: $0, makeIfNecessary: true) }
                .flatMap { descendants($0).compactMap { $0 as? NSButton } }
                .filter { !$0.isHidden && $0.toolTip?.hasPrefix("Locked") == true }
        }

        let (background, bottom, top) = try session()
        background.document?.layers.removeAll { $0.id == top }
        try setLocks(background, bottom, [.all, .artboardNesting])
        try #require(try locks(in: background).first).performClick(nil)
        #expect(layer(background, bottom)?.locks == [.artboardNesting])
        // Only the artboard lock left: nothing to unlock, so the button can't be clicked.
        let nesting = try #require(try locks(in: background).first)
        #expect(!nesting.isEnabled)

        let (nested, inside, _) = try session()
        try setLocks(nested, inside, [.position])
        try folder(nested, holding: inside, locks: [.all])
        let shown = try locks(in: nested)
        #expect(shown.count == 2)
        let own = try #require(shown.first { $0.toolTip?.hasSuffix("(with the folder it’s in)") == true })
        #expect(!own.isEnabled)
        own.performClick(nil)
        #expect(layer(nested, inside)?.locks == [.position])
    }
}
