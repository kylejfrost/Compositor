import AppKit
import MCP
import UniformTypeIdentifiers
import Testing
@testable import Compositor

@MainActor struct ProjectWorkspaceTests {
    // MARK: Reading off the main actor

    /// open_document on a file that takes a while to read (a cloud-only file downloading) reads it off the main actor,
    /// so the window and other agent calls go on meanwhile; the failed open leaves the tabs as they were.
    @Test func openDocumentReadsTheFileOffTheMainActor() async throws {
        let slow = try SlowFile(named: "cloud.png", delay: .seconds(120))
        let workspace = ProjectWorkspace()
        try await slow.expectMainActorStaysFree {
            await #expect(throws: (any Error).self) { _ = try await workspace.openDocument(at: slow.url) }
        }
        #expect(workspace.tabs.count == 1 && workspace.current.session.document == nil)
    }

    /// revert_document reads its file off the main actor too; the failed read leaves the document as it was.
    @Test func revertDocumentReadsTheFileOffTheMainActor() async throws {
        let slow = try SlowFile(named: "cloud.png", delay: .seconds(120))
        let workspace = ProjectWorkspace()
        let tab = workspace.current
        tab.session.createDocument(width: 10, height: 10)
        tab.session.sourceURL = slow.url
        try await slow.expectMainActorStaysFree {
            await #expect(throws: (any Error).self) { _ = try await workspace.revertDocument(tab) }
        }
        #expect(tab.session.document?.width == 10)
    }

    /// A file dropped on the Dock, the tab bar or an empty tab is checked for Photoshop's signature off the main actor.
    @Test func droppedFilesAreCheckedOffTheMainActor() async throws {
        let slow = try SlowFile(named: "cloud.png", delay: .seconds(120))
        let workspace = ProjectWorkspace()
        try await slow.expectMainActorStaysFree { await workspace.receive([slow.url]) }
    }

    /// Import Images… (and a drop on a tab) checks each file off the main actor before decoding it there too.
    @Test func importedImagesAreCheckedOffTheMainActor() async throws {
        let slow = try SlowFile(named: "cloud.png", delay: .seconds(120))
        let session = EditorSession()
        try await slow.expectMainActorStaysFree { await session.importImages([slow.url]) }
        #expect(session.importError != nil && session.document == nil)
    }

    @Test func newCanvasOpensAnEmptyTabWithoutAModal() {
        let workspace = ProjectWorkspace()
        let original = workspace.current
        original.session.createDocument(width: 4000, height: 3000)
        workspace.newCanvas()
        #expect(workspace.tabs.count == 2)
        #expect(workspace.current !== original)
        #expect(workspace.current.session.document == nil)
        #expect(!workspace.current.session.showsNewDocument)
        #expect(workspace.canSwitch)
        #expect(original.session.document?.size.width == 4000)
        workspace.newCanvas()
        #expect(workspace.tabs.count == 3)
        #expect(!workspace.current.session.showsNewDocument)
    }

    @Test func layerDropProviderCopiesIntoANewProject() async throws {
        let workspace = ProjectWorkspace()
        let source = workspace.current
        source.session.createDocument(width: 100, height: 100)
        source.session.insert(try LiveMaskTests().asset([255,255,255,255]))
        let id = try #require(source.session.activeLayerID)
        let provider = NSItemProvider(item: Data(id.uuidString.utf8) as NSData, typeIdentifier: ProjectWorkspace.layerType)
        await workspace.receiveProviders([provider])
        #expect(workspace.tabs.count == 2)
        #expect(workspace.current.id != source.id)
        #expect(workspace.current.session.document?.layers.count == 1)
        #expect(workspace.current.session.activeLayerID != id)
        #expect(source.session.document?.layers.first?.id == id)
    }

    @Test func tabsKeepIndependentDocumentsAndUndo() throws {
        let workspace = ProjectWorkspace()
        let first = workspace.current
        first.session.createDocument(width: 4000, height: 4000)
        first.session.addBlankLayer()
        let second = workspace.addTab()
        second.session.createDocument(width: 640, height: 480)
        second.session.addBlankLayer()
        second.session.undo()
        #expect(first.session.document?.layers.count == 1)
        #expect(second.session.document?.layers.isEmpty == true)
        workspace.select(first.id)
        #expect(workspace.current === first)
        #expect(first.session.document?.size.width == 4000)
        workspace.removeTab(second.id)
        #expect(workspace.current === first)
        workspace.removeTab(first.id)
        #expect(workspace.tabs.count == 1 && workspace.current.session.document == nil)
    }

    @Test func crossProjectCopyRemapsIdentityAndHasIndependentUndo() async throws {
        let workspace = ProjectWorkspace()
        let first = workspace.current
        first.session.createDocument(width: 100, height: 100)
        first.session.insert(try LiveMaskTests().asset([255,255,255,255]))
        let original = try #require(first.session.activeLayerID)
        let second = workspace.addTab()
        second.session.createDocument(width: 200, height: 200)
        await workspace.copyLayer(original, into: second.id)
        let copied = try #require(second.session.document?.layers.first)
        #expect(copied.id != original)
        #expect(copied.transform.center == CGPoint(x: 100, y: 100))
        #expect(first.session.document?.layers.count == 1)
        second.session.undo()
        #expect(second.session.document?.layers.isEmpty == true)
        #expect(first.session.document?.layers.count == 1)
        second.session.redo()
        #expect(second.session.document?.layers.first?.id == copied.id)
    }

    @Test func crossProjectCopyKeepsEffectsTextAndShapes() async throws {
        let workspace = ProjectWorkspace()
        let fixture = try EditableLayers()
        let first = workspace.current
        first.session.createDocument(width: 400, height: 200)
        first.session.document?.layers = try #require(fixture.session.document?.layers)
        let second = workspace.addTab()
        second.session.createDocument(width: 400, height: 200)
        for id in [fixture.text, fixture.shape] {
            await workspace.copyLayer(id, into: second.id)
            let original = try fixture.layer(id)
            let copied = try #require(second.session.document?.layers.last)
            #expect(copied.id != id)
            #expect(copied.effects == original.effects && copied.effects != nil)
            #expect(copied.liveText == original.liveText && copied.liveShape == original.liveShape)
        }
    }

    /// Upstream's Copy with no selection copies whole layers, and Paste in another project brings them over as dragging
    /// them onto its tab does. The layers keep everything our model adds (effects, text, shape, locks, Photoshop data,
    /// without the layer IDs), and the copy goes through the session's pasteboard, never the system's in a test host.
    @Test func copiedLayersPasteIntoAnotherProjectWithEverythingTheyHold() async throws {
        let workspace = ProjectWorkspace()
        let fixture = try EditableLayers()
        // A pasteboard of the test's own, shared by both projects: other tests copy to the test host's meanwhile.
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let first = workspace.current
        first.session.pasteboard = board
        first.session.createDocument(width: 400, height: 200)
        first.session.document?.layers = try #require(fixture.session.document?.layers)
        let index = try #require(first.session.document?.layers.firstIndex { $0.id == fixture.text })
        first.session.document?.layers[index].locks = [.position]
        var extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "lclr", data: Data([0, 2, 0, 0, 0, 0, 0, 0]))])
        extras.layerID = 7
        first.session.document?.layers[index].psdExtras = extras
        first.session.activeLayerID = fixture.text
        first.session.selectedLayerIDs = [fixture.text, fixture.shape]
        // Whether the system's pasteboard changed says nothing (any app may change it at any time), so the copy is
        // checked on the board the session writes: written, and the one Paste will match the copied layers against.
        let before = board.changeCount
        first.session.copySelection()
        #expect(board.changeCount != before && board.types?.isEmpty == false)
        #expect(first.session.copiedLayer?.changeCount == board.changeCount)
        #expect(first.session.copiedLayer?.ids == [fixture.text, fixture.shape])

        let second = workspace.addTab()
        second.session.pasteboard = board
        second.session.createDocument(width: 400, height: 200)
        workspace.select(second.id)
        #expect(workspace.pasteCopiedLayer())
        for _ in 0..<500 where (second.session.document?.layers.count ?? 0) < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let pasted = try #require(second.session.document?.layers)
        #expect(pasted.count == 2)
        let text = try #require(pasted.first { $0.liveText != nil }), shape = try #require(pasted.first { $0.liveShape != nil })
        let originalText = try #require(first.session.document?.layers[index])
        #expect(text.liveText == originalText.liveText && text.effects == originalText.effects && text.effects != nil)
        #expect(text.locks == [.position])
        #expect(text.psdExtras?.blocks == extras.blocks && text.psdExtras?.layerID == nil)
        #expect(shape.liveShape == (try fixture.layer(fixture.shape)).liveShape && shape.effects != nil)
        #expect(second.session.history.undoName == "Copy Layers from Project")

        // In its own project, Paste duplicates them in place.
        workspace.select(first.id)
        let count = first.session.document?.layers.count ?? 0
        #expect(workspace.pasteCopiedLayer())
        #expect(first.session.document?.layers.count == count + 2 && first.session.history.undoName == "Paste")
    }

    @Test func dockCreatesTabsAndTargetedImportUsesExistingTab() async throws {
        let url = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let workspace = ProjectWorkspace()
        await workspace.receive([url, url])
        #expect(workspace.tabs.count == 2)
        let first = workspace.tabs[0]
        await workspace.receive([url], into: first.id)
        #expect(workspace.tabs.count == 2)
        #expect(workspace.current === first)
        #expect(first.session.document?.layers.count == 2)
        #expect(workspace.tabs[1].session.document?.layers.count == 1)
    }

    @Test func moveTabReordersWithoutTouchingSelectionOrDocuments() {
        let workspace = ProjectWorkspace()
        let a = workspace.current
        let b = workspace.addTab(reuseEmpty: false)
        let c = workspace.addTab(reuseEmpty: false)
        #expect(workspace.tabs.map(\.id) == [a.id, b.id, c.id])
        workspace.moveTab(c.id, to: 0)
        #expect(workspace.tabs.map(\.id) == [c.id, a.id, b.id])
        workspace.moveTab(a.id, to: 2)
        #expect(workspace.tabs.map(\.id) == [c.id, b.id, a.id])
        // An out-of-range target clamps to the array's bounds instead of crashing.
        workspace.moveTab(c.id, to: 99)
        #expect(workspace.tabs.map(\.id) == [b.id, a.id, c.id])
        // Moving to where a tab already is, or moving an id that isn't a tab, does nothing.
        let unchanged = workspace.tabs.map(\.id)
        workspace.moveTab(c.id, to: 2)
        workspace.moveTab(UUID(), to: 0)
        #expect(workspace.tabs.map(\.id) == unchanged)
        #expect(workspace.current === c) // reordering is chrome — it never moves the selection
    }

    /// Quit asks about the project on screen first, then the others left to right.
    @Test @MainActor func quitAsksAboutTheActiveTabFirst() {
        let workspace = ProjectWorkspace()
        let first = workspace.current
        let second = workspace.addTab(reuseEmpty: false)
        let third = workspace.addTab(reuseEmpty: false)
        workspace.select(second.id)
        #expect(workspace.quitOrder.map(\.id) == [second.id, first.id, third.id])
        workspace.select(third.id)
        #expect(workspace.quitOrder.map(\.id) == [third.id, first.id, second.id])
        workspace.select(first.id)
        #expect(workspace.quitOrder.map(\.id) == [first.id, second.id, third.id])
    }

    // MARK: Headless open

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectWorkspaceTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func solid(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// A 4×2 Photoshop file: a pixel layer, a Dissolve layer (a conversion to report) and a Brightness/Contrast
    /// adjustment Compositor keeps as a placeholder.
    private func photoshopFile(in folder: URL, name: String = "Client Template.psd") throws -> URL {
        let fill = try solid(width: 2, height: 2)
        var sky = PSDRecord(id: UUID(), name: "Sky")
        sky.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        sky.image = fill
        var dissolved = PSDRecord(id: UUID(), name: "Dissolved")
        dissolved.bounds = CGRect(x: 2, y: 0, width: 2, height: 2)
        dissolved.image = fill
        dissolved.blendKey = "diss"
        var brightness = PSDRecord(id: UUID(), name: "Brightness/Contrast 1")
        brightness.extras = PSDLayerExtras(blocks: [PSDTaggedBlock(key: "brit", data: Data(count: 8))])
        let extras = PSDDocumentExtras(resources: [PSDImageResource(id: 4000, name: "", data: Data([1, 2]))])
        let data = try PSDFixture.data(PSDDocument(width: 4, height: 2, resolution: 144, layers: [sky, dissolved, brightness],
                                                   extras: extras), composite: try solid(width: 4, height: 2))
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test func openDocumentOpensAPhotoshopFileWithoutAnyUI() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try photoshopFile(in: root)
        let workspace = ProjectWorkspace()
        let empty = workspace.current
        let (tab, conversions) = try await workspace.openDocument(at: url)
        // The empty starting tab is replaced, as opening a project does.
        #expect(workspace.tabs.count == 1)
        #expect(workspace.current === tab && tab !== empty)
        let session = tab.session
        #expect(session.sourceURL == url)
        #expect(session.documentFormat == .psd)
        #expect(session.projectURL == nil)
        #expect(tab.title == "Client Template")
        #expect(session.document?.size == CGSize(width: 4, height: 2))
        #expect(session.document?.resolution == 144)
        #expect(session.document?.layers.map(\.name) == ["Sky", "Dissolved", "Brightness/Contrast 1"])
        #expect(session.document?.layers.last?.psdExtras?.placeholder == "adjustment:brit")
        #expect(session.document?.psdExtras?.resources.contains { $0.id == 4000 } == true)
        #expect(conversions.contains { $0.layerName == "Dissolved" })
        #expect(!session.showsConversionSheet && session.conversionRequest == nil)
        #expect(!session.isModified && !session.canUndo)
        #expect(session.importError == nil)
    }

    @Test func openingTheSameFileTwiceSelectsItsTab() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try photoshopFile(in: root)
        let workspace = ProjectWorkspace()
        let (first, _) = try await workspace.openDocument(at: url)
        let other = workspace.addTab(reuseEmpty: false)
        #expect(workspace.current === other)
        let (again, conversions) = try await workspace.openDocument(at: url)
        #expect(again === first)
        #expect(conversions.isEmpty)
        #expect(workspace.current === first)
        #expect(workspace.tabs.count == 2)
        // A path that reaches the same file another way is the same document.
        let link = root.appendingPathComponent("Link.psd")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        workspace.select(other.id)
        let (linked, _) = try await workspace.openDocument(at: link, select: false)
        #expect(linked === first)
        #expect(workspace.current === other)
    }

    @Test func openDocumentOpensProjectsAndImages() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = EditorSession()
        source.createDocument(width: 30, height: 20, emptyLayer: true)
        let project = root.appendingPathComponent("Saved.comp")
        try await ProjectStore.shared.save(try #require(source.projectSnapshot()), to: project)
        let workspace = ProjectWorkspace()
        let (comp, none) = try await workspace.openDocument(at: project)
        #expect(none.isEmpty)
        #expect(comp.session.projectURL == project)
        #expect(comp.session.sourceURL == nil)
        #expect(comp.session.documentFormat == .comp)
        #expect(comp.session.document?.size == CGSize(width: 30, height: 20))

        let png = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: png) }
        let (image, _) = try await workspace.openDocument(at: png, select: false)
        #expect(workspace.current === comp)
        #expect(workspace.tabs.count == 2)
        #expect(image.session.sourceURL == png)
        #expect(image.session.projectURL == nil)
        #expect(image.session.documentFormat == .comp)
        #expect(image.session.document?.size == CGSize(width: 64, height: 32))
        #expect(image.session.document?.layers.count == 1)
        #expect(!image.session.isModified)

        let text = root.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        await #expect(throws: ImageImportError.self) { _ = try await workspace.openDocument(at: text) }
        await #expect(throws: (any Error).self) { _ = try await workspace.openDocument(at: root.appendingPathComponent("Missing.comp")) }
        #expect(workspace.tabs.count == 2)
    }

    /// An empty tab waiting on an import (a dropped file's conversion sheet) is about to get a document: a
    /// headless open adds a tab beside it instead of replacing it.
    @Test func openDocumentKeepsAnEmptyTabThatIsImporting() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try photoshopFile(in: root)
        for busy in [\EditorSession.isImporting, \EditorSession.isProjectBusy] as [ReferenceWritableKeyPath<EditorSession, Bool>] {
            let workspace = ProjectWorkspace()
            let empty = workspace.current
            empty.session[keyPath: busy] = true
            let (tab, _) = try await workspace.openDocument(at: url, select: false)
            #expect(workspace.tabs.count == 2)
            #expect(workspace.tabs.first === empty && workspace.tabs.last === tab)
            #expect(workspace.current === empty)
            empty.session[keyPath: busy] = false
        }
    }

    @Test func concurrentOpensOfOneFileShareATab() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try photoshopFile(in: root)
        let workspace = ProjectWorkspace()
        let first = Task { try await workspace.openDocument(at: url) }
        let second = Task { try await workspace.openDocument(at: url) }
        let a = try await first.value, b = try await second.value
        #expect(a.tab === b.tab)
        #expect(workspace.tabs.count == 1)
        #expect(a.conversions.isEmpty != b.conversions.isEmpty)
    }

    // MARK: Opening Photoshop files from the app

    /// A Photoshop file opened from the app (the Dock or Finder, File > Open, a drop on the tab bar or on an empty
    /// tab) becomes that file's document, as openDocument opens it: it remembers its source and saves as Photoshop,
    /// once the conversions are agreed to.
    @Test func aPhotoshopFileOpenedFromTheAppIsThatFilesDocument() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try photoshopFile(in: root)
        func expectOpened(_ tab: ProjectTab) {
            #expect(tab.session.sourceURL == url && tab.session.documentFormat == .psd && tab.session.projectURL == nil)
            #expect(tab.session.document?.layers.map(\.name) == ["Sky", "Dissolved", "Brightness/Contrast 1"])
            #expect(!tab.session.isModified && !tab.session.canUndo)
            #expect(tab.title == "Client Template")
        }

        // The Dock: the lone empty tab is replaced.
        let dock = ProjectWorkspace()
        var reported: [[PSDConversion]] = []
        dock.current.session.confirmConversions = { reported.append($0); return true }
        await dock.receive([url])
        #expect(dock.tabs.count == 1)
        expectOpened(dock.current)
        #expect(reported.count == 1 && reported[0].contains { $0.layerName == "Dissolved" })

        // File > Open.
        let menu = ProjectWorkspace()
        menu.current.session.confirmConversions = { _ in true }
        #expect(await menu.open(url))
        #expect(menu.tabs.count == 1)
        expectOpened(menu.current)

        // A drop on an empty tab beside another document opens it there; images dropped with it join it as layers.
        let drop = ProjectWorkspace()
        let busy = drop.current
        busy.session.createDocument(width: 10, height: 10)
        let empty = drop.addTab(reuseEmpty: false)
        empty.session.confirmConversions = { _ in true }
        let png = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: png) }
        await drop.receive([url, png], into: empty.id)
        #expect(drop.tabs.count == 2 && drop.tabs[0] === busy)
        let opened = drop.tabs[1]
        #expect(drop.current === opened)
        #expect(opened.session.sourceURL == url && opened.session.documentFormat == .psd)
        #expect(opened.session.document?.layers.count == 4)
        #expect(busy.session.document?.layers.isEmpty == true)
    }

    /// One file, one tab, whichever opens it first. An agent's open_document of a Photoshop file the app is opening
    /// (its conversion sheet still up) opens it, and the app's open then shows that tab; an app open of a file an
    /// agent's open is still reading waits for that tab.
    @Test func anAppOpenAndAnAgentOpenOfOnePhotoshopFileShareATab() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try photoshopFile(in: root)
        func tabs(showing url: URL, in workspace: ProjectWorkspace) -> [ProjectTab] {
            workspace.tabs.filter { $0.session.sourceURL?.path == url.path }
        }

        // File > Open; while its conversions are on screen, open_document(select: false).
        let menu = ProjectWorkspace()
        var agent: [String: Value] = [:]
        menu.current.session.confirmConversions = { [weak menu] _ in
            if let menu {
                agent = (try? await MCPTestSupport.call("open_document", ["path": .string(url.path), "select": false], in: menu)) ?? [:]
            }
            return true
        }
        #expect(await menu.open(url))
        #expect(agent["already_open"] == .bool(false))
        #expect(tabs(showing: url, in: menu).count == 1)
        #expect(menu.current.id.uuidString == agent["tab_id"]?.stringValue)
        let again = try await MCPTestSupport.call("open_document", ["path": .string(url.path), "select": false], in: menu)
        #expect(again["already_open"] == .bool(true) && again["tab_id"] == agent["tab_id"])

        // The Dock, while an agent's open of the same file is still reading it.
        let dock = ProjectWorkspace()
        dock.current.session.confirmConversions = { _ in true }
        let reading = Task { try await dock.openDocument(at: url, select: false) }
        await Task.yield()
        await dock.receive([url])
        let read = try await reading.value
        #expect(tabs(showing: url, in: dock).count == 1)
        #expect(dock.current === read.tab)
    }

    @Test func cancellingTheConversionsOfAPhotoshopOpenLeavesTheTabsAlone() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try photoshopFile(in: root)
        let workspace = ProjectWorkspace()
        let empty = workspace.current
        empty.session.confirmConversions = { _ in false }
        await workspace.receive([url])
        #expect(workspace.tabs.count == 1 && workspace.current === empty)
        #expect(empty.session.document == nil && !empty.session.isImporting)
    }

    /// Dropped on a tab that has a document, a Photoshop file is still imported into it as a folder of layers.
    @Test func aPhotoshopFileDroppedOnADocumentIsImportedIntoIt() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try photoshopFile(in: root)
        let workspace = ProjectWorkspace()
        let tab = workspace.current
        tab.session.createDocument(width: 10, height: 10)
        tab.session.confirmConversions = { _ in true }
        await workspace.receive([url], into: tab.id)
        #expect(workspace.tabs.count == 1)
        #expect(tab.session.sourceURL == nil && tab.session.documentFormat == .comp)
        #expect(tab.session.document?.layers.first?.isGroup == true && tab.session.document?.layers.first?.name == "Client Template")
    }

    /// A .comp package's URL gains a trailing slash once it exists: opening it either way is the same document.
    @Test func openingAProjectComparesPathsNotURLs() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = EditorSession()
        source.createDocument(width: 30, height: 20, emptyLayer: true)
        let path = root.appendingPathComponent("Saved.comp").path
        try await ProjectStore.shared.save(try #require(source.projectSnapshot()), to: URL(fileURLWithPath: path))
        let workspace = ProjectWorkspace()
        #expect(await workspace.open(URL(fileURLWithPath: path, isDirectory: false)))
        let first = workspace.current
        workspace.addTab(reuseEmpty: false)
        #expect(await workspace.open(URL(fileURLWithPath: path, isDirectory: true)))
        #expect(workspace.current === first)
        #expect(workspace.tabs.count == 2)
    }

    /// Switching to the opened tab commits the transform left pending on the tab being left, as select does.
    @Test func openingCommitsThePendingTransformOfTheTabLeft() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try photoshopFile(in: root)
        let workspace = ProjectWorkspace()
        let first = workspace.current
        first.session.createDocument(width: 100, height: 100)
        first.session.insert(try LiveMaskTests().asset([255, 255, 255, 255]))
        let id = try #require(first.session.activeLayerID)
        let before = try #require(first.session.document?.layers.first { $0.id == id }?.transform)
        first.session.beginTransform()
        var moved = before
        moved.origin.x += 10
        first.session.previewTransform(moved)
        #expect(first.session.transformEdit != nil)
        let (tab, _) = try await workspace.openDocument(at: url)
        #expect(workspace.current === tab)
        #expect(first.session.transformEdit == nil)
        #expect(first.session.document?.layers.first { $0.id == id }?.transform.origin.x == before.origin.x + 10)
    }
}
