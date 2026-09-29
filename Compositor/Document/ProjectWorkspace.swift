import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
final class ProjectTab: Identifiable {
    let id = UUID()
    let session: EditorSession
    let controller: ProjectController
    /// The title while the document has no file: "Untitled N", or the name it was created or duplicated with.
    var defaultName: String
    var title: String { (session.projectURL ?? session.sourceURL)?.deletingPathExtension().lastPathComponent ?? defaultName }
    init(name: String) {
        defaultName = name
        session = EditorSession()
        controller = ProjectController(session: session)
    }
}

@MainActor @Observable
final class ProjectWorkspace {
    private(set) var tabs: [ProjectTab] = []
    private(set) var selectedID: UUID
    var isManaging = false
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var nextNumber = 2
    var current: ProjectTab { tabs.first { $0.id == selectedID } ?? tabs[0] }
    var canSwitch: Bool {
        let s = current.session
        return !isManaging && s.canStartProjectOperation && s.hueSaturation == nil && s.filterEdit == nil
            && s.gradientEdit == nil && s.pixelMove == nil && s.colorPicker == nil
    }
    init() {
        let first = ProjectTab(name: "Untitled")
        first.session.skipsInitialClipboardCanvasSize = true
        tabs = [first]; selectedID = first.id
        first.controller.workspace = self
    }
    @discardableResult
    func addTab(reuseEmpty: Bool = true) -> ProjectTab {
        if reuseEmpty, tabs.count == 1, current.session.document == nil { return current }
        let tab = ProjectTab(name: "Untitled \(nextNumber)")
        nextNumber += 1
        tab.controller.workspace = self; tab.controller.window = window
        tabs.append(tab); selectedID = tab.id
        return tab
    }
    /// Reorders a tab by dragging it in the strip. Chrome, not a document edit, so it never touches undo.
    /// `index` is where the tab should land in the final order, clamped to the array's bounds.
    func moveTab(_ id: UUID, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(0, index), tabs.count - 1)
        guard target != from else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: target)
    }
    func select(_ id: UUID) {
        guard id != selectedID, canSwitch, tabs.contains(where: { $0.id == id }) else { return }
        current.session.commitTransform()
        selectedID = id
        current.controller.window = window
        current.controller.resumeExternalChangeCheck()
    }
    func newCanvas() {
        guard canSwitch else { return }
        current.session.commitTransform()
        _ = addTab(reuseEmpty: false)
    }
    @discardableResult
    func open(_ suppliedURL: URL? = nil) async -> Bool {
        guard canSwitch else { return false }
        isManaging = true
        defer { isManaging = false }
        var urls = suppliedURL.map { [$0] } ?? []
        if urls.isEmpty {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.compositorProject, .photoshopImage, .photoshopLargeImage]
            panel.allowsMultipleSelection = true
            panel.treatsFilePackagesAsDirectories = false
            let response = if let window { await panel.beginSheetModal(for: window) } else { await panel.begin() }
            guard response == .OK else { return false }
            urls = panel.urls
        }
        var opened = false
        for url in urls {
            if url.pathExtension.lowercased() == "comp" { opened = await loadProject(url) || opened }
            else { opened = await openPhotoshop(url, into: nil) != nil || opened }
        }
        return opened
    }
    private func loadProject(_ url: URL) async -> Bool {
        // Compared by path: a .comp package's URL gains a trailing slash once the package exists on disk.
        let path = url.resolvingSymlinksInPath().path
        if let existing = tabs.first(where: { $0.session.projectURL?.resolvingSymlinksInPath().path == path }) {
            selectedID = existing.id; return true
        }
        // Load into an unattached session, so a failed open never leaves a broken tab.
        let tab = ProjectTab(name: url.deletingPathExtension().lastPathComponent)
        tab.controller.window = window
        guard await tab.controller.open(url) else { return false }
        if tabs.count == 1, current.session.document == nil { tabs.removeAll() }
        tab.controller.workspace = self; tabs.append(tab); selectedID = tab.id
        return true
    }
    /// The tab showing the file at `url`: its project, or the Photoshop file or image it was opened from. Compared by
    /// path: a .comp package's URL gains a trailing slash once the package exists on disk.
    func tab(showing url: URL) -> ProjectTab? {
        let target = url.resolvingSymlinksInPath().path
        return tabs.first { tab in
            [tab.session.projectURL, tab.session.sourceURL].contains { $0?.resolvingSymlinksInPath().path == target }
        }
    }

    /// Opens a .comp, .psd, or raster image in a new tab (selects the existing tab when that URL is already open),
    /// with no panels, sheets or alerts: Photoshop conversions are accepted and returned, a raw photo develops as
    /// shot. A Photoshop or image document records `sourceURL` and keeps `projectURL` nil, so a plain Save asks where
    /// to write rather than replacing the original. The lone empty starting tab is replaced, as opening a project
    /// does. Callers check `canSwitch` before asking for `select`; reading takes a while, so `validate` (given whether
    /// the new document will replace the lone empty tab) checks again once the file is read, before any tab changes,
    /// and what it throws fails the open. Throws ProjectError / PSDError / ImageImportError / LayerLimitError (or the
    /// file system's error for a file that can't be read); a failed open leaves the tabs as they were.
    func openDocument(at url: URL, select: Bool = true,
                      validate: ((_ replacesEmpty: Bool) throws -> Void)? = nil) async throws -> (tab: ProjectTab, conversions: [PSDConversion]) {
        if let existing = tab(showing: url) {
            if select { show(existing) }
            return (existing, [])
        }
        // A second open of a file still being read waits for the first and shares its tab.
        let key = url.resolvingSymlinksInPath()
        if let pending = opening[key] {
            let tab = try await pending.value.tab
            if select { show(tab) }
            return (tab, [])
        }
        let task = Task { try await self.openNewTab(at: url, select: select, validate: validate) }
        opening[key] = task
        defer { opening[key] = nil }
        return try await task.value
    }

    /// Opens the Photoshop file at `url` from the app (File > Open, the Dock, a drop on the tab bar or on an empty tab)
    /// as `openDocument` opens it: the file's document, remembering `sourceURL`, in the Photoshop format and with
    /// nothing to undo. The conversion sheet comes first, while the file is read, over `target` (selected first) or
    /// else the current tab. The document replaces `target`, an empty tab, or else opens in a new tab (the lone empty
    /// tab is replaced). A file already open selects its tab. Returns the document's tab; nil when cancelled or failed
    /// (the failure shown as an import error), with the tabs as they were.
    ///
    /// One file, one tab: an `openDocument` of the same file (an agent's open_document) that is still reading is
    /// waited for and its tab shown, and one that opened the file while this read it or while the sheet was up wins
    /// the same way. `openDocument` doesn't wait for this open in turn, since the sheet can stay up indefinitely.
    private func openPhotoshop(_ url: URL, into target: ProjectTab?) async -> ProjectTab? {
        if let existing = await tabOpening(url) {
            show(existing)
            return existing
        }
        // The conversion sheet shows over the current tab.
        if let target { show(target) }
        let presenter = (target ?? current).session
        presenter.isImporting = true
        defer { presenter.isImporting = false }
        presenter.beginPSDReading(title: "Open “\(url.lastPathComponent)”?", confirmTitle: "Open")
        let tab = ProjectTab(name: url.deletingPathExtension().lastPathComponent)
        do {
            let file = try await Self.read(url)
            let conversions = if case .photoshop(let imported) = file { imported.conversions } else { [PSDConversion]() }
            guard await presenter.finishPSDReading(conversions) else { return nil }
            // Opened meanwhile (by an agent): that is the file's tab. Nothing below waits, so no other open can start.
            if let existing = await tabOpening(url) {
                show(existing)
                return existing
            }
            // Into an unattached session, so a failed open never leaves a broken tab.
            _ = try Self.install(file, from: url, in: tab.session)
        } catch {
            presenter.endPSDReading()
            presenter.importError = "\(url.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
        tab.controller.workspace = self
        tab.controller.window = window
        if let target, let index = tabs.firstIndex(where: { $0 === target }) {
            tabs[index] = tab
        } else if tabs.count == 1, current.session.document == nil {
            tabs = [tab]
        } else {
            tabs.append(tab)
        }
        selectedID = tab.id
        // A project is watched for changes other apps make to it, as one opened from the menu is.
        await tab.controller.syncProjectWatch()
        return tab
    }

    /// Files `openDocument` is reading, by resolved URL.
    @ObservationIgnored private var opening: [URL: Task<(tab: ProjectTab, conversions: [PSDConversion]), Error>] = [:]

    /// The tab showing `url`, once any `openDocument` still reading it has finished; nil when there is none (or that
    /// open failed), with no open of `url` in progress.
    private func tabOpening(_ url: URL) async -> ProjectTab? {
        let key = url.resolvingSymlinksInPath()
        var waited: Task<(tab: ProjectTab, conversions: [PSDConversion]), Error>?
        // Another open can start while one is waited for; a failed one stays listed until its own caller resumes.
        while tab(showing: url) == nil, let pending = opening[key], pending != waited {
            waited = pending
            _ = try? await pending.value
        }
        return tab(showing: url)
    }

    /// Shows `tab`, committing the pending transform of the tab being left, as `select` does.
    private func show(_ tab: ProjectTab) {
        guard tab.id != selectedID, tabs.contains(where: { $0.id == tab.id }) else { return }
        current.session.commitTransform()
        selectedID = tab.id
        tab.controller.window = window
    }

    private func openNewTab(at url: URL, select: Bool,
                            validate: ((_ replacesEmpty: Bool) throws -> Void)?) async throws -> (tab: ProjectTab, conversions: [PSDConversion]) {
        let file = try await Self.read(url)
        // Only an idle empty tab is replaced: one waiting on an import (a dropped file's conversion sheet, say) is
        // about to get a document and must not be orphaned.
        let empty = current.session
        let replacesEmpty = tabs.count == 1 && empty.document == nil && empty.canStartProjectOperation && !isManaging
        try validate?(replacesEmpty)
        // Load into an unattached session, so a failed open never leaves a broken tab.
        let tab = ProjectTab(name: url.deletingPathExtension().lastPathComponent)
        let conversions = try Self.install(file, from: url, in: tab.session)
        tab.controller.workspace = self
        if replacesEmpty {
            tabs = [tab]
            selectedID = tab.id
            tab.controller.window = window
        } else {
            tabs.append(tab)
            if select { show(tab) }
        }
        await tab.controller.syncProjectWatch()
        return (tab, conversions)
    }

    /// Reloads `tab`'s document from its file, as `openDocument` reads it, in the same tab: its project, or else the
    /// Photoshop file or image it was opened from. Unsaved changes and the undo history go (callers ask first); where
    /// the document is saved and where it came from stay. Returns the Photoshop conversions. A failed read leaves the
    /// document as it was; a document with no file throws `CocoaError(.fileNoSuchFile)`.
    @discardableResult
    func revertDocument(_ tab: ProjectTab) async throws -> [PSDConversion] {
        let session = tab.session
        let (projectURL, sourceURL) = (session.projectURL, session.sourceURL)
        guard let url = projectURL ?? sourceURL else { throw CocoaError(.fileNoSuchFile) }
        let file = try await Self.read(url)
        let discarded = session.isModified
        session.clearProject()
        let conversions = try Self.install(file, from: url, in: session)
        session.projectURL = projectURL
        session.sourceURL = sourceURL
        await tab.controller.syncProjectWatch()
        DocumentLog.reverted(url, discardedChanges: discarded)
        return conversions
    }

    /// A file `openDocument` has read and checked, not yet shown in any session.
    private nonisolated enum OpenedFile: Sendable {
        case project(ProjectSnapshot)
        case photoshop(PSDImport)
        case image(ImportedImage)
    }

    /// `readFile`, logged: the file's format, size and conversions and how long reading took, or why it failed.
    @concurrent private nonisolated static func read(_ url: URL) async throws -> OpenedFile {
        let started = ContinuousClock.now
        do {
            let (file, format) = try await readFile(url)
            switch file {
            case .photoshop(let imported): DocumentLog.opened(url, format: format, conversions: imported.conversions, startedAt: started)
            case .project, .image: DocumentLog.opened(url, format: format, conversions: [], startedAt: started)
            }
            return file
        } catch {
            DocumentLog.openFailed(url, error: error)
            throw error
        }
    }

    /// Reads the .comp, .psd or raster image at `url`: everything opening does that can fail. Off the main actor
    /// throughout: checking a file's signature or a raw photo's size reads the file, and a cloud-only file downloads
    /// in full first, which must not freeze the window or an agent's other calls. `format` names what was read, for
    /// the log: `comp`, `psd` or `psb` (by the file's version, also when only its merged image opens), `svg`, or else
    /// the file's extension.
    @concurrent private nonisolated static func readFile(_ url: URL) async throws -> (file: OpenedFile, format: String) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let limit = DocumentLimits.documentPixelBudget
        if url.pathExtension.lowercased() == "comp" { return (.project(try await ProjectStore.shared.load(from: url)), "comp") }
        guard url.isFileURL else { throw ImageImportError.unsupported }
        if PSDReader.matches(url) {
            let parsed = try await ImageImporter.shared.loadPhotoshop(url, remainingPixels: limit)
            let format = parsed.isLargeDocument ? "psb" : "psd"
            // Only a background: Photoshop writes no layer records, just the merged image, so that is what opens.
            if parsed.layers.isEmpty {
                let merged = try await ImageImporter.shared.decode(url, remainingPixels: limit, flattenedPhotoshop: true)
                return (.image(merged), format)
            }
            let assets = try await ImageImporter.shared.photoshopAssets(parsed)
            // Building the layers is the one step on the main actor; the file is read by then.
            let imported = try await PSDDocumentBuilder.makeImport(parsed, assets: assets)
            // The layer limit `insertPhotoshop` enforces, checked before a revert clears anything.
            guard imported.layers.count <= LayerLimitError.maximum else { throw LayerLimitError() }
            return (.photoshop(imported), format)
        }
        // Drawn into pixels at the size the file gives, as importing one does.
        if ImageImporter.isSVG(url) {
            return (.image(try await ImageImporter.shared.decodeSVG(url, fitting: nil, remainingPixels: limit)), "svg")
        }
        if RawImporter.matches(url) {
            guard let size = RawImporter.pixelSize(url) else { throw ImageImportError.unreadable }
            guard size.width <= DocumentLimits.maxSide, size.height <= DocumentLimits.maxSide, size.width * size.height <= limit else {
                throw ImageImportError.tooLarge
            }
            let settings = RawImporter.asShot(url) ?? RawDevelopSettings()
            let developed = try RawImporter.develop(url, settings: settings)
            return (.image(ImportedImage(image: developed, thumbnail: try PixelAdjust.thumbnail(of: developed),
                                         name: url.deletingPathExtension().lastPathComponent)), url.pathExtension.lowercased())
        }
        return (.image(try await ImageImporter.shared.decode(url, remainingPixels: limit)), url.pathExtension.lowercased())
    }

    /// Shows `file`, read from `url`, in `session`, which has no document. A Photoshop or image document records
    /// `sourceURL` and keeps `projectURL` nil. Returns the Photoshop conversions.
    private static func install(_ file: OpenedFile, from url: URL, in session: EditorSession) throws -> [PSDConversion] {
        var conversions: [PSDConversion] = []
        switch file {
        case .project(let snapshot):
            session.installProject(snapshot, from: url)
            return []
        case .photoshop(let imported):
            try session.insertPhotoshop(imported, named: url.deletingPathExtension().lastPathComponent)
            conversions = imported.conversions
            session.documentFormat = .psd
        case .image(let asset):
            session.insert(asset)
        }
        guard session.document != nil else { throw ImageImportError.unreadable }
        session.sourceURL = url
        // Opening is not an edit: nothing to undo, nothing unsaved.
        session.history.reset()
        return conversions
    }

    func close(_ id: UUID) async {
        guard canSwitch, let tab = tabs.first(where: { $0.id == id }) else { return }
        isManaging = true
        defer { isManaging = false }
        tab.controller.window = window
        guard await tab.controller.confirmQuit() else { return }
        removeTab(id)
    }
    func removeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs[index].session
        DocumentLog.closed(closing.projectURL ?? closing.sourceURL, title: tabs[index].title,
                           discardedChanges: closing.isModified && closing.document != nil)
        tabs.remove(at: index)
        if tabs.isEmpty { _ = addTab(reuseEmpty: false) }
        else if selectedID == id { selectedID = tabs[min(index, tabs.count-1)].id }
    }
    /// The order Quit (and closing the window) asks about unsaved projects: the tab on screen first,
    /// then the rest left to right, so it never jumps to another project before the one you're viewing.
    var quitOrder: [ProjectTab] { [current] + tabs.filter { $0.id != current.id } }
    private func finishTextEditing() -> Bool {
        for tab in quitOrder where tab.session.textDraft != nil {
            guard tab.session.finishText() else { return false }
        }
        return true
    }
    func confirmQuit() async -> Bool {
        guard finishTextEditing() else { return false }
        guard canSwitch else { return false }
        isManaging = true; defer { isManaging = false }
        for tab in quitOrder {
            selectedID = tab.id; tab.controller.window = window
            guard await tab.controller.confirmQuit() else { return false }
        }
        return true
    }
    func closeWindow(_ window: NSWindow) async {
        guard await confirmQuit() else { return }
        tabs.removeAll(); _ = addTab(reuseEmpty: false)
        window.close()
    }

    /// Capture the destination before asynchronous provider loading. Dock/new-tab
    /// drops create one project per image; existing-tab drops add image layers.
    func receive(_ urls: [URL], into destination: UUID? = nil, at point: CGPoint? = nil) async {
        let files = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        defer { for (url, scoped) in files where scoped { url.stopAccessingSecurityScopedResource() } }
        while !canSwitch {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(30))
        }
        isManaging = true; defer { isManaging = false }
        var destination = destination
        for url in urls {
            if url.pathExtension.lowercased() == "comp" { _ = await loadProject(url); continue }
            // A Photoshop file dropped on the Dock, the tab bar or an empty tab opens as its own document, as File >
            // Open does; the files dropped with it on a tab go into it.
            let target = destination.flatMap { id in tabs.first { $0.id == id } }
            if target?.session.document == nil, destination == nil || target != nil, await FileProbe.isPhotoshop(url) {
                if let opened = await openPhotoshop(url, into: target), destination != nil { destination = opened.id }
                continue
            }
            let tab: ProjectTab
            if let destination {
                guard let existing = tabs.first(where: { $0.id == destination }) else { continue }
                tab = existing
            } else { tab = addTab() }
            selectedID = tab.id
            await tab.session.importImages([url], at: point)
        }
    }
    func receiveProviders(_ providers: [NSItemProvider], into destination: UUID? = nil, at point: CGPoint? = nil) async {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(Self.layerType) {
                let data: Data? = await withCheckedContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: Self.layerType) { data, _ in continuation.resume(returning: data) }
                }
                if let data, let value = String(data: data, encoding: .utf8), let id = UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    await copyLayer(id, into: destination, at: point)
                }
            } else {
                await ImageFileDrop.importProviders([provider], into: current.session, at: point, workspace: self, destination: destination)
            }
        }
    }
    static let layerType = "com.compositor.layer-row"
    /// Cmd-V with a whole layer copied: pastes it complete — a copy above it in its own project, or brought over as
    /// dragging it onto this tab does. False when there is none, and Paste goes on with pixels.
    func pasteCopiedLayer() -> Bool {
        // The pasteboard Paste reads (`EditorSession.pasteboard`): the system's, except in a test host.
        let count = current.session.pasteboard.changeCount
        guard let source = tabs.first(where: { $0.session.copiedLayer?.changeCount == count }),
              let copied = source.session.copiedLayer?.ids, let layers = source.session.document?.layers else { return false }
        let ids = copied.filter { id in layers.contains { $0.id == id } }
        guard !ids.isEmpty else { return false }
        if source.id == selectedID {
            guard source.session.canEditLayers else { return false }
            source.session.duplicateLayers(ids, editName: "Paste")
            return true
        }
        let destination = selectedID
        Task { await copyLayers(ids, into: destination) }
        return true
    }
    func copyLayer(_ id: UUID, into destination: UUID?, at point: CGPoint? = nil) async {
        await copyLayers([id], into: destination, at: point)
    }
    /// Copies layers (folders with all they hold) into another project, or a new one, as one undo step there. Several
    /// keep where they sit relative to each other, centered on `point` or the canvas as a whole.
    func copyLayers(_ ids: [UUID], into destination: UUID?, at point: CGPoint? = nil) async {
        guard let id = ids.first, canSwitch, let sourceTab = tabs.first(where: { $0.session.document?.layers.contains(where: { $0.id == id }) == true }),
              sourceTab.session.canEditLayers, let snapshot = sourceTab.session.projectSnapshot(),
              let sourceDocument = sourceTab.session.document else { return }
        if let destination, destination == sourceTab.id { return }
        let target: ProjectTab
        if let destination {
            guard let existing = tabs.first(where: { $0.id == destination }), existing.session.canStartProjectOperation else { return }
            target = existing
        } else { target = addTab(reuseEmpty: false) }
        guard target.session.document == nil || target.session.canEditLayers else { return }
        let included = ids.reduce(into: Set(ids)) { $0.formUnion(sourceTab.session.descendantIDs(of: $1)) }
        var copied = sourceDocument.layers.filter { included.contains($0.id) }
        let used = target.session.document?.layers.reduce(0) { $0 + ($1.asset.map { $0.image.width * $0.image.height } ?? 0) } ?? 0
        let added = copied.reduce(0) { $0 + ($1.asset.map { $0.image.width * $0.image.height } ?? 0) }
        guard used + added <= DocumentLimits.documentPixelBudget else { target.session.importError = "The copied layers exceed this project’s \(DocumentLimits.documentBudgetMegapixels)-megapixel limit."; return }
        isManaging = true
        sourceTab.session.isProjectBusy = true
        target.session.isProjectBusy = true
        defer {
            isManaging = false
            sourceTab.session.isProjectBusy = false
            target.session.isProjectBusy = false
        }
        do {
            for i in copied.indices where copied[i].maskSourceID.map({ !included.contains($0) }) == true {
                if copied[i].adjustment != nil { copied[i].releaseClipping(); continue }
                let layerID = copied[i].id
                let baked = try await Task.detached(priority: .userInitiated) { try LiveMaskBaker.bake(snapshot, target: layerID) }.value
                if let baked { copied[i] = copied[i].releasedIntoPixels(baked) } else { copied[i].releaseClipping() }
            }
            let mapping = Dictionary(uniqueKeysWithValues: copied.map { ($0.id, UUID()) })
            let size = target.session.document?.size ?? sourceDocument.size
            let pictured = copied.filter { !$0.isGroup }.map { CGRect(origin: $0.transform.origin, size: $0.transform.size) }
            let anchor = ids.count == 1 || pictured.isEmpty
                ? copied.first(where: { $0.id == id })?.transform.center ?? CGPoint(x: sourceDocument.size.width/2, y: sourceDocument.size.height/2)
                : { let r = pictured.dropFirst().reduce(pictured[0]) { $0.union($1) }; return CGPoint(x: r.midX, y: r.midY) }()
            let center = point ?? CGPoint(x: size.width/2, y: size.height/2)
            let layers = copied.map { layer -> ImageLayer in
                var transform = layer.transform
                transform.origin.x += center.x-anchor.x; transform.origin.y += center.y-anchor.y
                var copy = layer.copy(as: mapping[layer.id]!)
                copy.transform = transform
                copy.mask?.placement?.origin.x += center.x-anchor.x; copy.mask?.placement?.origin.y += center.y-anchor.y
                copy.parentID = layer.parentID.flatMap { mapping[$0] }
                copy.maskSourceID = layer.maskSourceID.flatMap { mapping[$0] }
                return copy
            }
            target.session.isProjectBusy = false
            target.session.beginEdit("Copy Layers from Project")
            if target.session.document == nil { target.session.createDocument(width: Int(size.width), height: Int(size.height)) }
            target.session.document?.layers.append(contentsOf: layers)
            target.session.activeLayerID = mapping[id]
            target.session.selectedLayerIDs = Set(ids.compactMap { mapping[$0] })
            target.session.endEdit()
            selectedID = target.id
        } catch { target.session.importError = error.localizedDescription }
    }
}
