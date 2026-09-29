import AppKit
import MCP
import SwiftUI
import Testing
@testable import Compositor

/// Photoshop's layer locks as editing enforces them, and Fill drawn apart from Opacity: the layer's own pixels at
/// its Fill, its effects at full strength.
@MainActor
struct LayerLockTests {
    /// A `size`-pixel square image, transparent, with an opaque white square `inner` pixels wide in its middle.
    private func square(size: Int = 40, inner: Int = 20) throws -> CGImage {
        let context = try BrushRaster.context(width: size, height: size, mask: false)
        let origin = (size - inner) / 2
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: origin, y: origin, width: inner, height: inner))
        return try #require(context.makeImage())
    }

    /// RGBA bytes (premultiplied) at `x`, `y`, rows counted from the top.
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let index = (y * image.width + x) * 4
        return (0..<4).map { Int(bytes[index + $0]) }
    }

    /// A 40 × 40 document holding one pixel layer (the square) with `locks`, selected.
    private func session(locks: LayerLocks) throws -> (EditorSession, UUID) {
        let session = EditorSession()
        session.createDocument(width: 40, height: 40)
        let image = try square()
        var layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: image, name: "Square"), origin: .zero)
        layer.locks = locks
        session.document?.layers = [layer]
        session.activeLayerID = layer.id
        return (session, layer.id)
    }

    // MARK: Position

    @Test func positionLockedLayerIgnoresNudge() throws {
        for locks in [LayerLocks.position, .all] {
            let (session, _) = try session(locks: locks)
            let before = try #require(session.document?.layers.first?.transform)
            let revision = session.history.revisionID
            #expect(!session.canTransform)
            // The lock is why, so the app beeps at a refused move.
            #expect(session.isTransformPositionLocked)
            session.nudgeLayer(dx: 5, dy: 3)
            #expect(session.document?.layers.first?.transform == before)
            #expect(session.transformEdit == nil)
            #expect(session.history.revisionID == revision)
            session.beginTransform()
            #expect(session.transformEdit == nil)
        }
        // Transparency and pixel locks leave the layer free to move.
        let (session, _) = try session(locks: [.transparency, .pixels])
        #expect(session.canTransform && !session.isTransformPositionLocked)
        session.nudgeLayer(dx: 5, dy: 3)
        #expect(session.document?.layers.first?.transform.origin == CGPoint(x: 5, y: 3))
        // A layer that can't move for another reason (it is hidden) isn't refused by a lock.
        session.document?.layers[0].isVisible = false
        session.document?.layers[0].locks = [.position]
        #expect(!session.canTransform && !session.isTransformPositionLocked)
    }

    @Test func aFoldersPositionLockHoldsWhatIsInside() throws {
        let (session, id) = try session(locks: [])
        var folder = ImageLayer(name: "Folder", blankSize: CGSize(width: 40, height: 40))
        folder.isGroup = true
        folder.locks = [.position]
        session.document?.layers[0].parentID = folder.id
        session.document?.layers.append(folder)
        #expect(session.document?.effectiveLocks(of: id) == [.position])
        session.activeLayerID = id
        session.nudgeLayer(dx: 4, dy: 0)
        #expect(session.document?.layers.first?.transform.origin == .zero)
        #expect(session.isTransformPositionLocked)
        // Selecting the folder moves nothing either.
        session.activeLayerID = folder.id
        #expect(!session.canTransform && session.isTransformPositionLocked)
        // A locked layer among several selected holds the whole selection.
        session.document?.layers.removeAll { $0.isGroup }
        session.document?.layers[0].parentID = nil
        session.document?.layers[0].locks = [.position]
        var free = ImageLayer(name: "Free", blankSize: CGSize(width: 40, height: 40))
        free.asset = session.document?.layers[0].asset
        session.document?.layers.append(free)
        session.selectLayers([id, free.id], primary: free.id)
        #expect(!session.canTransform)
    }

    // MARK: Pixels

    @Test func pixelLockedLayerRefusesABrushStroke() throws {
        let (session, id) = try session(locks: [.pixels])
        let original = session.document?.layers.first?.asset?.image
        let revision = session.history.revisionID
        session.selectTool(.brush)
        session.beginBrush(at: CGPoint(x: 20, y: 20))
        #expect(session.brushStroke == nil)
        let message = try #require(session.brushError)
        #expect(message.contains("Square") && message.contains("locked"))
        #expect(session.document?.layers.first?.asset?.image === original)
        #expect(session.history.revisionID == revision)
        // Lock Pixels leaves the layer's mask to be painted, as in Photoshop; Lock All doesn't.
        session.brushError = nil
        session.document?.layers[0].mask = LayerMask.solid(revealing: true)
        session.selectLayerTarget(id, mask: true)
        #expect(session.isMaskSelected)
        session.beginBrush(at: CGPoint(x: 20, y: 20))
        #expect(session.brushStroke != nil && session.brushError == nil)
        session.cancelBrush()
        session.document?.layers[0].locks = [.all]
        session.beginBrush(at: CGPoint(x: 20, y: 20))
        #expect(session.brushStroke == nil && session.brushError != nil)
    }

    /// A folder's pixel lock refuses edits to what is inside it, and the message names the folder that holds the lock.
    @Test func aFoldersPixelLockIsNamedWhenItRefusesAnEdit() async throws {
        let (session, id) = try session(locks: [])
        var folder = ImageLayer(name: "Artwork", blankSize: CGSize(width: 40, height: 40))
        folder.isGroup = true
        folder.locks = [.pixels]
        session.document?.layers[0].parentID = folder.id
        session.document?.layers.append(folder)
        session.activeLayerID = id
        let original = session.document?.layers.first?.asset?.image
        await session.fillSelection(with: .foreground)
        let message = try #require(session.brushError)
        #expect(message.contains("Square") && message.contains("Artwork"), "\(message)")
        #expect(session.document?.layers.first?.asset?.image === original)
        #expect(throws: LayerLockedError(layerName: "Square", folderName: "Artwork")) {
            try session.checkUnlocked(try #require(session.document?.layers.first), mask: false)
        }
        // The layer's own lock names only the layer.
        session.document?.layers[1].locks = []
        session.document?.layers[0].locks = [.pixels]
        #expect(throws: LayerLockedError(layerName: "Square")) {
            try session.checkUnlocked(try #require(session.document?.layers.first), mask: false)
        }
    }

    @Test func pixelLockedLayerRefusesFillsAndFilters() async throws {
        let (session, _) = try session(locks: [.pixels])
        let original = session.document?.layers.first?.asset?.image
        await session.fillSelection(with: .foreground)
        #expect(session.brushError != nil)
        #expect(session.document?.layers.first?.asset?.image === original)
        session.brushError = nil
        session.beginFilter(.gaussianBlur)
        #expect(session.filterEdit == nil)
        #expect(session.brushError != nil)
        // Unlocked, the same fill goes through.
        session.brushError = nil
        session.document?.layers[0].locks = []
        await session.fillSelection(with: .foreground)
        #expect(session.brushError == nil)
        #expect(session.document?.layers.first?.asset?.image !== original)
    }

    /// Distorting resamples the pixels, so Lock Pixels refuses it though the layer may still be moved and scaled:
    /// Cmd-dragging a handle leaves an ordinary transform, and Apply leaves the pixels as they were.
    @Test func pixelLockedLayerRefusesADistortion() throws {
        let (session, _) = try session(locks: [.pixels])
        let original = try #require(session.document?.layers.first?.asset?.image)
        let transform = try #require(session.document?.layers.first?.transform)
        var pulled = DistortWarp.corners(of: transform)
        pulled[0] = CGPoint(x: pulled[0].x + 6, y: pulled[0].y + 4)
        session.beginTransform()
        #expect(session.transformEdit != nil)
        #expect(!session.beginDistort())
        #expect(session.transformEdit?.corners == nil)
        let message = try #require(session.brushError)
        #expect(message.contains("Square") && message.contains("locked"))
        session.previewCorners(pulled)
        session.commitTransform()
        #expect(session.transformEdit == nil)
        #expect(session.document?.layers.first?.asset?.image === original)
        #expect(session.document?.layers.first?.transform == transform)

        // Locked while the distortion was under way: Apply still leaves the pixels alone.
        session.brushError = nil
        session.document?.layers[0].locks = []
        session.beginTransform()
        #expect(session.beginDistort())
        session.previewCorners(pulled)
        #expect(session.transformEdit?.corners == pulled)
        session.document?.layers[0].locks = [.pixels]
        session.commitTransform()
        #expect(session.brushError != nil)
        #expect(session.document?.layers.first?.asset?.image === original)

        // Unlocked, the same distortion resamples the layer.
        session.brushError = nil
        session.document?.layers[0].locks = []
        session.beginTransform()
        #expect(session.beginDistort())
        session.previewCorners(pulled)
        session.commitTransform()
        #expect(session.brushError == nil)
        #expect(session.document?.layers.first?.asset?.image !== original)
    }

    /// Several layers distorted together: one with its pixels locked refuses the whole distortion.
    @Test func aPixelLockedMemberRefusesAGroupDistortion() throws {
        let (session, id) = try session(locks: [.pixels])
        var free = ImageLayer(name: "Free", blankSize: CGSize(width: 40, height: 40))
        free.asset = session.document?.layers[0].asset
        session.document?.layers.append(free)
        session.selectLayers([id, free.id], primary: free.id)
        let originals = session.document?.layers.map { $0.asset?.image }
        session.beginTransform()
        #expect(session.transformEdit?.group != nil)
        #expect(!session.beginDistort())
        #expect(session.transformEdit?.corners == nil && session.brushError != nil)
        session.commitTransform()
        #expect(session.document?.layers.map { $0.asset?.image }.elementsEqual(originals ?? [], by: { $0 === $1 }) == true)
    }

    // MARK: Setting locks

    @Test func setLocksIsOneUndoStep() throws {
        let (session, id) = try session(locks: [])
        let steps = session.history.undoCount
        session.setLocks([.position, .pixels], on: id)
        #expect(session.document?.layers.first?.locks == [.position, .pixels])
        #expect(session.history.undoCount == steps + 1)
        // The same value again records nothing.
        session.setLocks([.position, .pixels], on: id)
        #expect(session.history.undoCount == steps + 1)
        session.undo()
        #expect(session.document?.layers.first?.locks == [])
        session.redo()
        #expect(session.document?.layers.first?.locks == [.position, .pixels])
        session.setLocks([], on: id)
        #expect(session.document?.layers.first?.locks == [])
        #expect(session.history.undoName == "Unlock Layer")
    }

    /// The Layers panel marks a locked layer at the end of its row; clicking the lock unlocks the layer, as one undo
    /// step. A layer locked only by its folder shows the lock dimmed, and it can't be clicked.
    @Test func layersPanelShowsTheLockAndUnlocksOnClick() throws {
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
        let (session, _) = try session(locks: [.position])
        let lock = try #require(try locks(in: session).first)
        #expect(lock.isEnabled && lock.toolTip == "Locked: position. Click to unlock.")
        lock.performClick(nil)
        #expect(session.document?.layers.first?.locks == [])
        #expect(session.history.undoName == "Unlock Layer")

        let (inherited, id) = try self.session(locks: [])
        var folder = ImageLayer(name: "Folder", blankSize: CGSize(width: 40, height: 40))
        folder.isGroup = true
        folder.locks = [.all]
        inherited.document?.layers[0].parentID = folder.id
        inherited.document?.layers.append(folder)
        let shown = try locks(in: inherited)
        #expect(shown.count == 2)
        let dimmed = try #require(shown.first { $0.toolTip?.hasSuffix("(with the folder it’s in)") == true })
        #expect(!dimmed.isEnabled)
        dimmed.performClick(nil)
        #expect(inherited.document?.layers.first(where: { $0.id == id })?.locks == [])
        #expect(inherited.document?.layers.last?.locks == [.all])
    }

    @Test func getLayerReportsFillAndLocks() throws {
        let (session, _) = try session(locks: [.transparency, .position])
        session.document?.layers[0].fillOpacity = 0.25
        let document = try #require(session.document)
        let value = MCPValues.layerDetail(document.layers[0], in: document, full: false).objectValue
        #expect(value?["fill_opacity"]?.doubleValue == 0.25)
        #expect(value?["locks"] == .array([.string("transparency"), .string("position")]))
    }

    // MARK: Fill

    /// Fill 0.5 halves the pixels' alpha; an outside stroke around them stays opaque. On the GPU and off it.
    @Test(arguments: [true, false]) func fillHalvesThePixelsButNotTheStroke(gpu: Bool) throws {
        let image = try square()
        let effects = LayerEffects(stroke: StrokeEffect(size: 4, red: 1, green: 0, blue: 0, opacity: 1))
        let full = try LayerEffectsRenderer.render(image, mask: nil, effects: effects, usingGPU: gpu)
        let half = try LayerEffectsRenderer.render(image, mask: nil, effects: effects, fill: 0.5, usingGPU: gpu)
        let inset = Int(half.inset), middle = inset + 20
        #expect(try pixel(full.image, x: middle, y: middle)[3] == 255)
        let faded = try pixel(half.image, x: middle, y: middle)
        #expect(abs(faded[3] - 128) <= 1 && abs(faded[0] - 128) <= 1)
        // The stroke, 2 px outside the square's left edge, is drawn exactly as at full fill.
        let stroke = try pixel(half.image, x: inset + 8, y: middle)
        #expect(stroke == [255, 0, 0, 255])
        #expect(try pixel(full.image, x: inset + 8, y: middle) == stroke)
    }

    /// Exported: a layer with a stroke at Fill 0.5 shows its pixels at half and its stroke whole; a layer without
    /// effects at Fill 0.5 is simply half as opaque.
    @Test func exportDrawsFillApartFromEffects() async throws {
        let (session, _) = try session(locks: [])
        session.document?.layers[0].fillOpacity = 0.5
        let plain = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        #expect(abs(try pixel(plain, x: 20, y: 20)[3] - 128) <= 1)
        session.document?.layers[0].effects = LayerEffects(stroke: StrokeEffect(size: 4, red: 1, green: 0, blue: 0, opacity: 1))
        let stroked = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        #expect(abs(try pixel(stroked, x: 20, y: 20)[3] - 128) <= 1)
        #expect(try pixel(stroked, x: 8, y: 20) == [255, 0, 0, 255])
        // Opacity still covers both.
        session.document?.layers[0].opacity = 0.5
        let dimmed = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        #expect(abs(try pixel(dimmed, x: 20, y: 20)[3] - 64) <= 1)
        #expect(abs(try pixel(dimmed, x: 8, y: 20)[3] - 128) <= 1)
    }

    /// A stroke around type at Fill 0: its pixels are at 0 whatever the opacity, but the stroke follows the layer's
    /// opacity and its folder's, so the canvas has to redraw when either changes, as when Fill does.
    @Test func canvasRedrawsWhenAFillZeroLayersOpacityChanges() throws {
        let (session, _) = try session(locks: [])
        var folder = ImageLayer(name: "Folder", blankSize: CGSize(width: 40, height: 40))
        folder.isGroup = true
        session.document?.layers[0].parentID = folder.id
        session.document?.layers.append(folder)
        session.document?.layers[0].fillOpacity = 0
        session.document?.layers[0].effects = LayerEffects(stroke: StrokeEffect(size: 4, red: 1, green: 0, blue: 0, opacity: 1))
        let view = CanvasView(session: session)
        #expect(view.synchronizeDisplay())
        #expect(!view.synchronizeDisplay())
        session.document?.layers[0].opacity = 0.5
        #expect(view.synchronizeDisplay())
        session.document?.layers[1].opacity = 0.5
        #expect(view.synchronizeDisplay())
        session.document?.layers[0].fillOpacity = 0.25
        #expect(view.synchronizeDisplay())
    }

    /// A folder's Fill dims what is inside it as its Opacity does (Compositor draws no folder effects); a layer's own
    /// Fill reaches only its pixels.
    @Test func pixelOpacityAddsTheLayersOwnFill() throws {
        var folder = ImageLayer(name: "Folder", blankSize: CGSize(width: 4, height: 4))
        folder.isGroup = true
        folder.opacity = 0.5
        folder.fillOpacity = 0.5
        var layer = ImageLayer(name: "Layer", blankSize: CGSize(width: 4, height: 4))
        layer.parentID = folder.id
        layer.opacity = 0.8
        layer.fillOpacity = 0.5
        let byID = [folder.id: folder, layer.id: layer]
        #expect(abs(layer.effectiveOpacity(in: byID) - 0.2) < 1e-9)
        #expect(abs(layer.pixelOpacity(in: byID) - 0.1) < 1e-9)
        let records = Dictionary(uniqueKeysWithValues: [folder, layer].map { ($0.id, ProjectLayerRecord(layer: $0)) })
        #expect(abs((records[layer.id]?.effectiveOpacity(in: records) ?? 0) - 0.2) < 1e-9)
        #expect(abs((records[layer.id]?.pixelOpacity(in: records) ?? 0) - 0.1) < 1e-9)
    }
}
