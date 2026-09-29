import AppKit
import SwiftUI
import Testing
@testable import Compositor

@MainActor
struct TypeToolTests {
    private func makeSession() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 800, height: 600, emptyLayer: true)
        session.selectTool(.type)
        return session
    }

    private func beginEditingText(in session: EditorSession) {
        session.beginText(at: CGPoint(x: 100, y: 100))
        session.textDraft?.style.content = "Editing"
    }

    @Test func createEditCancelAndUndo() throws {
        let session = makeSession()
        let before = session.history.undoCount
        session.beginText(at: CGPoint(x: 30, y: 40))
        // A click starts the first letter on the pointer: the box sits its padding to the left and its first
        // baseline's height above.
        let start = try #require(session.textDraft)
        let style = start.style
        let descent = abs((EditorSession.textAttributes(style)[.font] as? NSFont)?.descender ?? 0)
        #expect(start.origin == CGPoint(x: 30 - LayerTextStyle.padding, y: 40 - (LayerTextStyle.padding + style.lineHeight - descent)))
        session.textDraft?.style.content = "Text"
        #expect(session.document?.layers.count == 1)
        var draft = try #require(session.textDraft)
        draft.style.content = "Hello\nCompositor"
        draft.style.fontSize = 48
        #expect(session.applyText(draft))
        #expect(session.activeLayer?.liveText?.style == draft.style)
        #expect(session.activeLayer?.origin == start.origin)
        #expect(session.history.undoCount == before + 1)
        session.editActiveText()
        session.textDraft = nil
        #expect(session.history.undoCount == before + 1)
        session.editActiveText()
        draft = try #require(session.textDraft)
        draft.style.content = "Changed"
        #expect(session.applyText(draft))
        session.undo()
        #expect(session.activeLayer?.liveText?.style.content == "Hello\nCompositor")
        session.undo()
        #expect(session.document?.layers.count == 1)
        session.redo()
        #expect(session.activeLayer?.liveText != nil)
    }

    @Test func textColorPickerPreviewsAndRestoresDraft() throws {
        let session = makeSession()
        session.beginText(at: CGPoint(x: 30, y: 40))
        let original = try #require(session.textDraft?.style)

        session.openTextColorPicker()
        try #require(session.colorPicker).hsb.setRGB(PaletteColor(red: 1, green: 0, blue: 0))
        session.previewTextColor()
        #expect(session.textDraft?.style.red == 1)
        #expect(session.textDraft?.style.green == 0)
        #expect(session.foregroundColor == .black)

        session.closeColorPicker(commit: false)
        #expect(session.textDraft?.style == original)
        #expect(session.foregroundColor == .black)

        session.openTextColorPicker()
        try #require(session.colorPicker).hsb.setRGB(PaletteColor(red: 0, green: 0, blue: 1))
        session.previewTextColor()
        session.closeColorPicker(commit: true)
        #expect(session.textDraft?.style.blue == 1)
        #expect(session.foregroundColor == PaletteColor(red: 0, green: 0, blue: 1))
    }

    @Test func transformsDuplicatesAndClippingKeepTextEditable() throws {
        let session = makeSession()
        session.beginText(at: CGPoint(x: 20, y: 20))
        session.textDraft?.style.content = "Text"
        #expect(session.applyText(try #require(session.textDraft)))
        let id = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex(where: { $0.id == id }))
        session.document?.layers[index].transform.rotation = 30
        session.document?.layers[index].transform.size.width *= 2
        let old = try #require(session.activeLayer?.transform)
        session.editActiveText()
        var draft = try #require(session.textDraft)
        draft.style.content = "Longer text"
        #expect(session.applyText(draft))
        let updated = try #require(session.activeLayer?.transform)
        #expect(updated.rotation == 30)
        #expect(abs(updated.point(.zero).x - old.point(.zero).x) < 0.001)
        #expect(abs(updated.point(.zero).y - old.point(.zero).y) < 0.001)
        session.duplicateActiveLayer()
        #expect(session.activeLayer?.liveText?.style.content == "Longer text")
        let target = try #require(session.activeLayerID)
        #expect(session.linkMask(source: id, target: target))
        #expect(session.activeLayer?.maskSourceID == id)
        #expect(session.document?.layers.first(where: { $0.id == id })?.liveText != nil)
    }

    @Test func saveReopenAndRasterize() async throws {
        let session = makeSession()
        session.beginText(at: .zero)
        session.textDraft?.style.content = "Text"
        var draft = try #require(session.textDraft)
        draft.style.content = "Café 日本語\nSecond line"
        draft.style.alignment = .right
        draft.style.tracking = 3
        #expect(session.applyText(draft))
        let snapshot = try #require(session.projectSnapshot())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".compositor")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let reopened = makeSession()
        reopened.installProject(loaded, from: url)
        #expect(reopened.activeLayer?.liveText?.style == draft.style)
        let index = try #require(reopened.document?.layers.firstIndex(where: { $0.id == reopened.activeLayerID }))
        let replacement = try EditorSession.shapeImage(.rectangle, size: CGSize(width: 10, height: 10), color: PaletteColor(red: 1, green: 0, blue: 0))
        reopened.document?.layers[index].asset = ImportedImage(image: replacement, thumbnail: replacement, name: "Painted")
        #expect(reopened.activeLayer?.liveText == nil)
        #expect(reopened.projectSnapshot()?.manifest.layers[index].text == nil)
    }

    @Test func rasterHasTransparentBackgroundAndColoredGlyphs() throws {
        var style = LayerTextStyle()
        style.content = "TYPE"
        style.red = 1
        let image = try EditorSession.textImage(style)
        let bytes = try #require(image.dataProvider?.data) as Data
        var ink = 0, clear = 0
        for i in stride(from: 0, to: bytes.count - 3, by: 4) {
            if bytes[i + 3] == 0 { clear += 1 }
            else { ink += 1; #expect(bytes[i] > 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0) }
        }
        #expect(ink > 100 && clear > 100)
    }

    @Test func clippingToTextExportsColoredGlyphsOnTransparency() async throws {
        let session = makeSession()
        session.beginText(at: .zero)
        // The box on the canvas's corner, where the clipped fill below is placed.
        session.textDraft?.origin = .zero
        session.textDraft?.style.content = "Text"
        #expect(session.applyText(try #require(session.textDraft)))
        let source = try #require(session.activeLayerID)
        let size = try #require(session.activeLayer?.size)
        let fill = try EditorSession.shapeImage(.rectangle, size: size, color: PaletteColor(red: 1, green: 0, blue: 0))
        session.addPixelLayer(fill, at: .zero, name: "Clipped color", editName: "Fill")
        #expect(session.linkMask(source: source, target: try #require(session.activeLayerID)))
        let exported = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let context = try #require(CGContext(data: nil, width: exported.width, height: exported.height,
            bitsPerComponent: 8, bytesPerRow: exported.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(exported, in: CGRect(x: 0, y: 0, width: exported.width, height: exported.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var ink = 0, clear = 0
        for i in stride(from: 0, to: exported.width * exported.height * 4, by: 4) {
            if bytes[i + 3] == 0 { clear += 1 }
            else if bytes[i + 3] == 255 { ink += 1; #expect(bytes[i] == 255 && bytes[i + 1] == 0) }
        }
        #expect(ink > 100 && clear > 100)
    }

    @Test func paragraphBoxAndToolSwitchCommitEditableText() throws {
        let session = makeSession()
        session.beginText(in: CGRect(x: 40, y: 60, width: 200, height: 120))
        #expect(session.textDraft?.style.content == "")
        session.textDraft?.style.content = "Text that wraps inside its paragraph box"
        session.selectTool(.brush)
        #expect(session.textDraft == nil && session.tool == .brush)
        #expect(session.activeLayer?.size == CGSize(width: 200, height: 120))
        #expect(session.activeLayer?.liveText?.style.boxSize == CGSize(width: 200, height: 120))
        session.selectTool(.type)
        session.editActiveText()
        session.textDraft?.style.content = "Edited on canvas"
        session.cancelText()
        #expect(session.activeLayer?.liveText?.style.content == "Text that wraps inside its paragraph box")
    }

    @Test func emptyNewParagraphIsDiscarded() {
        let session = makeSession()
        let count = session.document?.layers.count
        session.beginText(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        session.selectTool(.brush)
        #expect(session.document?.layers.count == count)
        #expect(session.textDraft == nil)
    }

    /// The headless commands agents use: each is one undo step, and none of them changes the Type tool's own settings.
    @Test func addUpdateAndFitTextAreOneStepEach() throws {
        let session = makeSession()
        var style = LayerTextStyle()
        style.content = "Session text"
        style.fontSize = 48
        style.leading = 60
        let before = session.history.undoCount
        let id = try session.addTextLayer(style, at: CGPoint(x: 30, y: 40))
        #expect(session.activeLayerID == id)
        #expect(session.activeLayer?.liveText?.style == style && session.activeLayer?.name == "Session text")
        #expect(session.activeLayer?.origin == CGPoint(x: 30, y: 40))
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "New Text Layer")

        try session.updateTextStyle(id) { $0.content = "Changed text"; $0.red = 1 }
        #expect(session.activeLayer?.liveText?.style.content == "Changed text" && session.activeLayer?.liveText?.style.red == 1)
        #expect(session.activeLayer?.origin == CGPoint(x: 30, y: 40))
        #expect(session.history.undoCount == before + 2 && session.history.undoName == "Edit Text")
        try session.updateTextStyle(id) { $0.red = 1 }
        #expect(session.history.undoCount == before + 2)
        #expect(throws: ProjectError.self) { try session.updateTextStyle(id) { $0.fontSize = 0 } }

        let size = try session.fitText(id, maxWidth: 100)
        let fitted = try #require(session.activeLayer?.liveText?.style)
        #expect(size == fitted.fontSize && size < 48 && size >= 1)
        #expect(abs(fitted.leading - 60 * size / 48) < 0.0001)
        #expect(EditorSession.textBoxSize(fitted).width - 2 * LayerTextStyle.padding <= 100)
        #expect(session.history.undoCount == before + 3 && session.history.undoName == "Fit Text")
        #expect(try session.fitText(id, maxWidth: 10_000) == size)
        #expect(session.history.undoCount == before + 3)
        #expect(throws: TextLayerError.self) { try session.fitText(id, maxWidth: 1) }
        #expect(session.textDefaults == LayerTextStyle())

        try session.updateTextStyle(id) { $0.boxSize = CGSize(width: 200, height: 100) }
        #expect(throws: TextLayerError.paragraphText) { try session.fitText(id, maxWidth: 100) }
        let blank = try #require(session.document?.layers.first { $0.liveText == nil }?.id)
        #expect(throws: TextLayerError.notText) { try session.updateTextStyle(blank) { $0.content = "No" } }
        session.beginText(at: .zero)
        #expect(throws: TextLayerError.notEditable) { _ = try session.addTextLayer(style, at: .zero) }
    }

    /// Point text keeps the point it hangs from — its first baseline at its alignment point — through an edit, as in
    /// Photoshop, on a turned and scaled layer too: through the headless commands and through the app's own editor,
    /// which shows the text being typed where the commit puts it.
    @Test func editingPointTextKeepsItsAlignmentAnchor() throws {
        let session = makeSession()
        var style = LayerTextStyle()
        style.content = "Centered"
        style.fontSize = 40
        style.alignment = .center
        let id = try session.addTextLayer(style, at: CGPoint(x: 200, y: 150))
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].transform.rotation = 30
        session.document?.layers[index].transform.size.width *= 1.5
        session.document?.layers[index].transform.size.height *= 1.5
        func anchor() throws -> CGPoint {
            let layer = try #require(session.document?.layers.first { $0.id == id })
            let text = try #require(layer.liveText)
            let local = EditorSession.textAnchor(text.style)
            return layer.transform.documentPoint(ofUnit: CGPoint(x: local.x / CGFloat(text.image.width),
                                                                 y: local.y / CGFloat(text.image.height)))
        }
        func expectNear(_ a: CGPoint, _ b: CGPoint, _ step: String) {
            #expect(abs(a.x - b.x) < 0.001 && abs(a.y - b.y) < 0.001, "\(step): \(a) vs \(b)")
        }
        let start = try anchor()

        try session.updateTextStyle(id) { $0.content = "Centered, and a lot longer" }
        expectNear(try anchor(), start, "updateTextStyle")
        try session.fitText(id, maxWidth: 200)
        expectNear(try anchor(), start, "fitText")

        session.editActiveText()
        var draft = try #require(session.textDraft)
        draft.style.content = "Short"
        let shown = session.textDraftTransform(draft, size: EditorSession.textBoxSize(draft.style))
        #expect(session.applyText(draft))
        expectNear(try anchor(), start, "the app's editor")
        let committed = try #require(session.document?.layers.first { $0.id == id }?.transform)
        expectNear(committed.origin, shown.origin, "shown while typing vs committed (origin)")
        #expect(abs(committed.size.width - shown.size.width) < 0.001 && abs(committed.size.height - shown.size.height) < 0.001)
        #expect(committed.rotation == 30)
    }

    /// Image Size scales type by the height: a canvas stretched more one way than the other widens (or narrows) the
    /// letters by the difference, as Photoshop's type is scaled unevenly.
    @Test func unevenImageSizeScalesTheWidthOfType() throws {
        var style = LayerTextStyle()
        style.content = "Wide"
        style.fontSize = 20
        let wider = try #require(style.scaled(x: 3, y: 1.5))
        #expect(wider.fontSize == 30 && wider.horizontalScale == 2)
        style.horizontalScale = 2
        let evened = try #require(style.scaled(x: 1, y: 2))
        #expect(evened.fontSize == 40 && evened.horizontalScale == nil)
        #expect(style.scaled(x: 2, y: 2)?.horizontalScale == 2)
        // 2 × 20 / 2 is beyond the 10× Compositor's text supports.
        #expect(style.scaled(x: 20, y: 2) == nil)
    }

    /// A paragraph's box holds its text inside a fixed padding: Image Size scales the text's area, so the text
    /// wraps as it did.
    @Test func imageSizeScalesAParagraphsTextArea() throws {
        var style = LayerTextStyle()
        style.boxSize = CGSize(width: 100, height: 50)
        let padding = LayerTextStyle.padding
        #expect(style.scaled(x: 2, y: 3)?.boxSize == CGSize(width: (100 - 2 * padding) * 2 + 2 * padding,
                                                            height: (50 - 2 * padding) * 3 + 2 * padding))
        #expect(style.scaled(x: 0.5, y: 0.5)?.boxSize == CGSize(width: 62, height: 37))
    }

    /// The editor on the canvas lays unevenly scaled type out as wide as the layer draws it.
    @Test func theInlineEditorDrawsTypeAsWideAsItsLayer() throws {
        let session = makeSession()
        session.beginText(at: .zero)
        var draft = try #require(session.textDraft)
        draft.style.content = "HHHH HH"
        draft.style.fontSize = 40
        draft.style.tracking = 3
        draft.style.horizontalScale = 2
        #expect(session.applyText(draft))
        let canvas = CanvasView(session: session)
        session.editActiveText()
        canvas.synchronizeInlineText()
        let textView = try #require(canvas.inlineTextEditor?.textView)
        let layout = try #require(textView.layoutManager), container = try #require(textView.textContainer)
        layout.ensureLayout(for: container)
        var plain = draft.style
        plain.horizontalScale = nil
        let measured = NSAttributedString(string: plain.content, attributes: EditorSession.textAttributes(plain))
            .boundingRect(with: CGSize(width: 100_000, height: 100_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).width
        let shown = layout.usedRect(for: container).width
        #expect(abs(shown - 2 * measured) < 1, "\(shown) vs \(2 * measured)")
        // One line, as in the layer.
        #expect(layout.usedRect(for: container).height < draft.style.lineHeight * 1.5)
    }

    /// Letters colored on their own keep their colors through a change that leaves them be, and lose them, as the app's
    /// color swatch makes them, when the text or the whole text's color changes.
    @Test func newTextOrANewColorDropsLetterColors() throws {
        let session = makeSession()
        var style = LayerTextStyle()
        style.content = "Two tone"
        style.fontSize = 40
        let runs = [LayerTextColorRun(location: 0, length: 3, red: 1, green: 0, blue: 0)]
        style.colorRuns = runs
        let id = try session.addTextLayer(style, at: .zero)
        func current() -> [LayerTextColorRun]? { session.document?.layers.first { $0.id == id }?.liveText?.style.colorRuns }
        #expect(current() == runs)
        try session.updateTextStyle(id) { $0.fontSize = 48 }
        #expect(current() == runs)
        // Shorter than the runs: without dropping them the text would be refused as invalid.
        try session.updateTextStyle(id) { $0.content = "No" }
        #expect(current() == nil)
        try session.updateTextStyle(id) { $0.content = "Two tone"; $0.colorRuns = runs }
        #expect(current() == runs)
        try session.updateTextStyle(id) { $0.red = 0.5 }
        #expect(current() == nil)
    }

    @Test func closeButtonShouldCloseWindowWhileEditingText() async throws {
        let workspace = ProjectWorkspace()
        let session = workspace.current.session
        session.createDocument(width: 800, height: 600, emptyLayer: true)
        session.selectTool(.type)
        beginEditingText(in: session)

        let bridge = ProjectWindowView(controller: workspace.current.controller)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = bridge
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(50))

        window.standardWindowButton(.closeButton)?.performClick(nil)
        var alertWindow: NSWindow?
        for _ in 0..<20 where alertWindow == nil {
            alertWindow = window.attachedSheet
            if alertWindow == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let sheet = try #require(alertWindow)
        func button(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == "Don’t Save" { return button }
            for child in view.subviews {
                if let button = button(in: child) { return button }
            }
            return nil
        }
        let contentView = try #require(sheet.contentView)
        let discard = try #require(button(in: contentView))
        discard.performClick(nil)
        try await Task.sleep(for: .milliseconds(50))

        #expect(!window.isVisible)
        #expect(session.textDraft == nil)
    }

    @Test func commandQShouldTerminateWhileEditingText() async throws {
        let delegate = CompositorApplicationDelegate()
        let session = delegate.session
        session.createDocument(width: 800, height: 600, emptyLayer: true)
        session.selectTool(.type)
        beginEditingText(in: session)

        let bridge = ProjectWindowView(controller: delegate.projects)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = bridge
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(50))

        delegate.workspace.window = window
        delegate.projects.window = window
        let quitTask = Task { await delegate.workspace.confirmQuit() }
        var alertWindow: NSWindow?
        for _ in 0..<20 where alertWindow == nil {
            alertWindow = window.attachedSheet
            if alertWindow == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let sheet = try #require(alertWindow)
        func button(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == "Don’t Save" { return button }
            for child in view.subviews {
                if let button = button(in: child) { return button }
            }
            return nil
        }
        let contentView = try #require(sheet.contentView)
        let discard = try #require(button(in: contentView))
        discard.performClick(nil)
        #expect(await quitTask.value)

        #expect(window.attachedSheet == nil)
        #expect(session.textDraft == nil)
    }

    /// While text is open, the Type tool keeps its I-beam over the canvas, and the pointer goes back to the arrow, shown
    /// again, once it leaves the canvas for the toolbar. Tested on the view alone: no second window in the test host.
    @Test func theCursorFollowsThePointerWhileEditingText() throws {
        let session = makeSession()
        session.beginText(at: CGPoint(x: 20, y: 20))
        let view = CanvasView(session: session)
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        view.synchronizeDisplay()
        let editor = try #require(view.inlineTextEditor)
        func move(to point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                            context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        }
        defer { NSCursor.arrow.set() }

        NSCursor.arrow.set()
        editor.pointerMoved(try move(to: NSPoint(x: 780, y: 580)))
        #expect(NSCursor.current === NSCursor.iBeam, "over the canvas, away from the box, the Type tool's I-beam")

        NSCursor.setHiddenUntilMouseMoves(true)
        editor.pointerMoved(try move(to: NSPoint(x: -10, y: -10)))
        #expect(NSCursor.current === NSCursor.arrow, "off the canvas, the arrow")
    }

    @Test func invalidAndStaleDraftsDoNotChangeDocument() throws {
        let session = makeSession()
        session.beginText(at: .zero)
        session.textDraft?.style.content = "Text"
        var draft = try #require(session.textDraft)
        draft.style.fontSize = .nan
        #expect(!session.applyText(draft))
        draft.style.fontSize = 72
        draft.style.boxSize = CGSize(width: 0, height: 100)
        #expect(!session.applyText(draft))
        draft.style.boxSize = CGSize(width: 360, height: 160)
        draft.style.content = "Valid"
        session.textDraft = nil
        session.createDocument(width: 100, height: 100, emptyLayer: true)
        #expect(!session.applyText(draft))
        #expect(session.document?.layers.count == 1)
    }

    /// Zoomed in, text being typed shows as the pixels it will be committed as, so confirming it changes nothing on
    /// screen — at a zoom that smooths pixels and at one that shows them hard-edged.
    @Test(arguments: [1.5, 4] as [CGFloat])
    func textLooksTheSameWhileEditingAndOnceCommitted(zoom: CGFloat) throws {
        let session = makeSession()
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        session.viewport.resize(to: view.bounds.size, backingScale: 1, documentSize: CGSize(width: 800, height: 600))
        session.zoom(to: zoom)
        func snapshot() throws -> [UInt8] {
            // The canvas's own drawing, without the editor's box and handles over it.
            view.synchronizeDisplay()
            view.subviews.forEach { $0.isHidden = true }
            defer { view.subviews.forEach { $0.isHidden = false } }
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let data = try #require(rep.bitmapData)
            return Array(UnsafeBufferPointer(start: data, count: rep.bytesPerRow * rep.pixelsHigh))
        }
        let blank = try snapshot()
        session.beginText(at: CGPoint(x: 380, y: 300))
        session.textDraft?.style.content = "Sharp"
        session.textDraft?.style.fontSize = 24
        view.synchronizeDisplay()
        let editor = try #require(view.inlineTextEditor)
        #expect(editor.textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .clear)

        let editing = try snapshot()
        #expect(editing != blank, "the text being typed wasn't drawn on the canvas")
        #expect(session.finishText())
        #expect(session.activeLayer?.liveText != nil)
        let committed = try snapshot()
        #expect(editing.count == committed.count)
        let largest = zip(editing, committed).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(largest <= 2, "the canvas changed by up to \(largest) when the text was committed")
    }

    private let red = PaletteColor(red: 1, green: 0, blue: 0)

    @Test func colorAppliesToSelectionAndFollowsEdits() {
        var style = LayerTextStyle()
        style.content = "Hello world"
        style.setColor(red, in: NSRange(location: 6, length: 5))
        #expect(style.colorRuns == [LayerTextColorRun(location: 6, length: 5, red: 1, green: 0, blue: 0)])
        #expect(style.color(at: 5) == .black && style.color(at: 6) == red)
        // Painting next to a run in the same color joins it.
        style.setColor(red, in: NSRange(location: 5, length: 1))
        #expect(style.colorRuns?.count == 1 && style.colorRuns?.first?.location == 5)

        // Typed letters take the color of the one before them; deleted ones take their color away.
        style.replaceCharacters(in: NSRange(location: 11, length: 0), withLength: 1)
        style.content += "!"
        #expect(style.isValid && style.color(at: 11) == red)
        style.replaceCharacters(in: NSRange(location: 0, length: 2), withLength: 0)
        style.content.removeFirst(2)
        #expect(style.isValid && style.colorRuns?.first?.location == 3 && style.colorRuns?.first?.length == 7)

        // No selection, or all of it, recolors the whole text.
        style.setColor(red, in: NSRange(location: 4, length: 0))
        #expect(style.colorRuns == nil && style.red == 1)
    }

    @Test func invalidColorRunsAreRejected() {
        var style = LayerTextStyle()
        style.content = "Text"
        style.colorRuns = [LayerTextColorRun(location: 2, length: 3, red: 1, green: 0, blue: 0)]
        #expect(!style.isValid)
        style.colorRuns = [LayerTextColorRun(location: 0, length: 2, red: 1, green: 0, blue: 0),
                           LayerTextColorRun(location: 1, length: 2, red: 0, green: 1, blue: 0)]
        #expect(!style.isValid)
        style.colorRuns = [LayerTextColorRun(location: 0, length: 1, red: 2, green: 0, blue: 0)]
        #expect(!style.isValid)
    }

    /// Opaque pixels of `image` that are mostly red, and those that are dark.
    private func redAndDarkPixels(_ image: CGImage) -> (red: Int, dark: Int) {
        let rep = NSBitmapImageRep(cgImage: image)
        var red = 0, dark = 0
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.9 else { continue }
            if color.redComponent > 0.8, color.greenComponent < 0.2 { red += 1 }
            else if color.redComponent < 0.2 { dark += 1 }
        } }
        return (red, dark)
    }

    @Test func selectedColorPaintsOnlyThoseLettersAndSurvivesReopening() async throws {
        let session = makeSession()
        session.beginText(at: CGPoint(x: 30, y: 40))
        session.textDraft?.style.content = "AAAA BBBB"
        session.textDraft?.selection = NSRange(location: 5, length: 4)
        session.openTextColorPicker()
        try #require(session.colorPicker).hsb.setRGB(red)
        session.previewTextColor()
        session.closeColorPicker(commit: true)
        #expect(session.textDraft?.style.red == 0, "the letters outside the selection changed color")
        #expect(session.textDraft?.style.color(at: 5) == red)
        #expect(session.finishText())
        let image = try #require(session.activeLayer?.asset?.image)
        let pixels = redAndDarkPixels(image)
        #expect(pixels.red > 50 && pixels.dark > 50)

        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.version == 11)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TextColors-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(snapshot, to: url)
        let reopened = EditorSession()
        reopened.installProject(try await ProjectStore.shared.load(from: url), from: url)
        let text = try #require(reopened.document?.layers.last?.liveText)
        #expect(text.style == session.activeLayer?.liveText?.style)
        #expect(redAndDarkPixels(text.image) == pixels)

        var legacy = snapshot.manifest
        legacy.version = 9
        try JSONEncoder().encode(legacy).write(to: url.appendingPathComponent("manifest.json"))
        do {
            _ = try await ProjectStore.shared.load(from: url)
            Issue.record("Version 9 with color runs should be rejected")
        } catch ProjectError.invalid {}

        session.undo()
        #expect(session.activeLayer?.liveText == nil)

        legacy.version = 10
        let textIndex = try #require(legacy.layers.firstIndex { $0.text != nil })
        legacy.layers[textIndex].text?.fontRuns = [LayerTextFontRun(location: 0, length: 1, fontName: "Courier")]
        try JSONEncoder().encode(legacy).write(to: url.appendingPathComponent("manifest.json"))
        do {
            _ = try await ProjectStore.shared.load(from: url)
            Issue.record("Version 10 with font runs should be rejected")
        } catch ProjectError.invalid {}
    }

    @Test func fontAppliesToTheSelectionOnly() {
        var style = LayerTextStyle()
        style.content = "Hello"
        style.fontName = "Helvetica"
        style.setFont("Courier", in: NSRange(location: 0, length: 2))
        #expect(style.fontName == "Helvetica")
        #expect(style.fontRuns == [LayerTextFontRun(location: 0, length: 2, fontName: "Courier")])
        #expect(style.fontName(at: 0) == "Courier" && style.fontName(at: 2) == "Helvetica")
        #expect(style.uniformFontName(in: NSRange(location: 0, length: 2)) == "Courier")
        #expect(style.uniformFontName(in: NSRange(location: 0, length: 5)) == nil)
        style.setFont("Courier", in: NSRange(location: 0, length: 5))
        #expect(style.fontRuns == nil && style.fontName == "Courier")
        style.setFont("Helvetica", in: NSRange(location: 0, length: 2))
        #expect(style.fontRuns == [LayerTextFontRun(location: 0, length: 2, fontName: "Helvetica")])
        style.setFont("Courier", in: NSRange(location: 0, length: 0))
        #expect(style.fontRuns == nil && style.fontName == "Courier")
        style.setFont("Helvetica", in: NSRange(location: 1, length: 3))
        style.replaceCharacters(in: NSRange(location: 5, length: 0), withLength: 1)
        style.content += "!"
        #expect(style.isValid && style.fontName(at: 5) == "Courier")
    }

    @Test func selectedFontSurvivesReopening() async throws {
        let session = makeSession()
        session.beginText(at: CGPoint(x: 30, y: 40))
        session.textDraft?.style.content = "Hello"
        session.textDraft?.style.fontName = "Helvetica"
        session.textDraft?.selection = NSRange(location: 0, length: 2)
        session.changeTextStyle { $0.setFont("Courier", in: session.textDraft?.selection ?? NSRange()) }
        #expect(session.finishText())
        let snapshot = try #require(session.projectSnapshot())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TextFonts-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(snapshot, to: url)
        let reopened = EditorSession()
        reopened.installProject(try await ProjectStore.shared.load(from: url), from: url)
        let text = try #require(reopened.document?.layers.last?.liveText)
        #expect(text.style.fontRuns == [LayerTextFontRun(location: 0, length: 2, fontName: "Courier")])
        #expect(text.style.fontName == "Helvetica")
    }

    @Test func cancelingPickerRestoresSelectionColors() throws {
        let session = makeSession()
        session.beginText(at: CGPoint(x: 30, y: 40))
        session.textDraft?.style.content = "Two words"
        session.textDraft?.selection = NSRange(location: 0, length: 3)
        session.setPaletteColor(red, background: false)
        let colored = try #require(session.textDraft?.style)
        #expect(colored.colorRuns?.count == 1)
        session.openColorPicker(background: false)
        try #require(session.colorPicker).hsb.setRGB(PaletteColor(red: 0, green: 0, blue: 1))
        session.previewTextColor()
        #expect(session.textDraft?.style.color(at: 0).blue == 1)
        session.closeColorPicker(commit: false)
        #expect(session.textDraft?.style == colored)
    }
}
