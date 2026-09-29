import AppKit
import UniformTypeIdentifiers
import SwiftUI

@MainActor
final class ProjectController {
    let session: EditorSession
    weak var window: NSWindow?
    weak var workspace: ProjectWorkspace?
    private var saveGeneration = 0
    /// Keeps the document in step with its package when something else writes it. See ProjectController+ExternalChanges.
    let externalChanges = ExternalChangeState()
    var canStart: Bool {
        session.canStartProjectOperation && workspace?.isManaging != true
    }
    /// Tests assign this to answer the Photoshop save report (`PSDWriteReportSheet`) without showing it.
    var confirmPhotoshopReport: (([PSDWriteWarning]) async -> Bool)?
    init(session: EditorSession) { self.session = session }

    private func begin() -> Bool {
        guard session.canStartProjectOperation else { return false }
        session.cancelCrop()
        session.commitTransform()
        session.isProjectBusy = true
        return true
    }

    @discardableResult
    func save(asNew: Bool = false) async -> Bool {
        guard session.document != nil else { return false }
        // Another save still writing finishes first; then this one saves whatever has changed since.
        await finishWriting()
        guard begin() else { return false }
        return await saveCurrent(asNew: asNew, releasesToolsWhileWriting: true)
    }

    /// The save still writing, if any. Close, quit and replacing the document wait for it.
    private var writing: Task<Bool, Never>?
    func finishWriting() async { if let writing { _ = await writing.value } }

    func exportPNG() async {
        guard session.document != nil, begin() else { return }
        defer { session.isProjectBusy = false }
        guard let snapshot = session.projectSnapshot() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export PNG"
        panel.nameFieldStringValue = (session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".png"
        let response: NSApplication.ModalResponse
        if let window { response = await panel.beginSheetModal(for: window) }
        else { response = await panel.begin() }
        guard response == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try await ImageExporter.shared.exportPNG(snapshot, to: url)
            DocumentLog.exported(url, format: "png", bytes: DocumentLog.size(of: url), width: snapshot.manifest.width,
                                 height: snapshot.manifest.height, via: "app")
        } catch { await showError("Couldn’t export PNG", error: error) }
    }

    func canvasSize() async {
        guard let window, let document = session.document, begin() else { return }
        defer { session.isProjectBusy = false }
        let options: CanvasSizeOptions? = await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = "Canvas Size"
            sheet.contentViewController = NSHostingController(rootView: CanvasSizeSheet(document: document, session: session) { options in
                window.endSheet(sheet)
                sheet.orderOut(nil)
                sheet.contentViewController = nil
                continuation.resume(returning: options)
            })
            window.beginSheet(sheet)
        }
        guard let options, let snapshot = session.projectSnapshot() else { return }
        do {
            let resized = try await CanvasResizer.shared.resize(snapshot, to: options)
            session.applyDocumentSize(resized, actionName: "Canvas Size")
        } catch { await showError("Couldn’t change canvas size", error: error) }
    }

    func imageSize() async {
        guard let window, let document = session.document, begin() else { return }
        defer { session.isProjectBusy = false }
        let options: ImageSizeOptions? = await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = "Image Size"
            sheet.contentViewController = NSHostingController(rootView: ImageSizeSheet(document: document) { options in
                window.endSheet(sheet)
                sheet.orderOut(nil)
                sheet.contentViewController = nil
                continuation.resume(returning: options)
            })
            window.beginSheet(sheet)
        }
        guard let options, let snapshot = session.projectSnapshot() else { return }
        do {
            let resized = try await ImageResizer.shared.resize(snapshot, to: options)
            session.applyImageSize(resized)
        } catch { await showError("Couldn’t resize the image", error: error) }
    }

    func trim() async {
        guard let window, session.document != nil, begin() else { return }
        defer { session.isProjectBusy = false }
        let options: TrimOptions? = await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = "Trim"
            sheet.contentViewController = NSHostingController(rootView: TrimSheet { options in
                window.endSheet(sheet)
                sheet.orderOut(nil)
                sheet.contentViewController = nil
                continuation.resume(returning: options)
            })
            window.beginSheet(sheet)
        }
        guard let options, let snapshot = session.projectSnapshot() else { return }
        do {
            guard let resized = try await ImageTrim.trim(snapshot, options: options) else {
                return
            }
            session.applyDocumentSize(resized, actionName: "Trim")
        } catch { await showError("Couldn’t trim image", error: error) }
    }

    /// View > Grid Settings…: changes only how the grid is drawn and snapped to, so nothing is saved or undone. The
    /// grid shows while the sheet is open, changing as it's edited, and goes back to how it was on Cancel.
    func gridSettings() async {
        guard let window, window.attachedSheet == nil else { return }
        let original = (grid: session.layoutGrid, appearance: session.gridAppearance, shown: session.showsGrid)
        session.showsGrid = true
        let settings: (LayoutGrid, GridAppearance)? = await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = "Grid"
            sheet.contentViewController = NSHostingController(rootView: GridSettingsSheet(
                session: session, grid: original.grid, appearance: original.appearance,
                preview: { [session] grid, appearance in
                    session.layoutGrid = grid
                    session.gridAppearance = appearance
                }) { settings in
                    window.endSheet(sheet)
                    sheet.orderOut(nil)
                    sheet.contentViewController = nil
                    continuation.resume(returning: settings)
                })
            window.beginSheet(sheet)
        }
        session.showsGrid = original.shown
        session.layoutGrid = settings?.0 ?? original.grid
        session.gridAppearance = settings?.1 ?? original.appearance
    }

    func exportJPEG() async {
        guard let window, session.document != nil, begin() else { return }
        defer { session.isProjectBusy = false }
        guard let snapshot = session.projectSnapshot() else { return }
        do {
            let raster = try await ImageExporter.shared.render(snapshot)
            let data: Data? = await withCheckedContinuation { continuation in
                let sheet = NSWindow()
                sheet.styleMask = [.titled, .fullSizeContentView]
                sheet.title = "Export JPEG"
                sheet.contentViewController = NSHostingController(rootView: JPEGExportSheet(raster: raster, session: session) { data in
                    window.endSheet(sheet)
                    sheet.orderOut(nil)
                    // Release the hosted view and its closure after dismissal.
                    sheet.contentViewController = nil
                    continuation.resume(returning: data)
                })
                window.beginSheet(sheet)
            }
            guard let data else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.jpeg]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.title = "Export JPEG"
            panel.nameFieldStringValue = (session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".jpg"
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try await ImageExporter.shared.write(data, to: url)
            DocumentLog.exported(url, format: "jpeg", bytes: data.count, width: raster.image.width, height: raster.image.height, via: "app")
        } catch { await showError("Couldn’t export JPEG", error: error) }
    }

    /// Save and Save As: to the document's own file in its format (⌘S on a Photoshop document rewrites the PSD), or
    /// where and as what the Save panel says. A Photoshop file first lists what it can't hold exactly when that
    /// includes something lossy (`PSDWriteReportSheet`), and is written only once that is agreed to.
    private func saveCurrent(asNew: Bool = false, releasesToolsWhileWriting: Bool = false) async -> Bool {
        // `save` hands over its hold on the tools (`begin`): a project's package is written with them free again.
        var holdsTools = releasesToolsWhileWriting
        defer { if holdsTools { session.isProjectBusy = false } }
        guard session.document != nil else { return true }
        var target = asNew ? nil : session.projectURL.map { (url: $0, format: session.documentFormat) }
        if target == nil { target = await chooseSaveDestination(asNew: asNew) }
        guard let (url, format) = target else { return false }
        if format == .comp {
            let revision = session.history.currentRevision
            guard let snapshot = session.projectSnapshot() else { return false }
            // Only the snapshot (and the Save panel) holds the tools. The document is captured, so editing can go on
            // while the package is written in the background, as in Photoshop.
            if holdsTools { session.isProjectBusy = false; holdsTools = false }
            return await write(snapshot, to: url, revision: revision)
        }
        var options = PSDWriteOptions()
        var plan: PSDWritePlan?
        guard let request = session.psdWriteRequest() else { return true }
        options.allowLossy = true
        options.collapsedGroupIDs.formUnion(session.collapsedGroupIDs)
        let revision = session.history.revisionID
        do {
            let planned = try await PSDExporter.shared.plan(request, options: options)
            let warnings = planned.warnings
            if warnings.contains(where: \.lossy), !(await approvePhotoshopReport(warnings, fileName: url.lastPathComponent)) {
                return false
            }
            // Written as planned unless the document changed while the report was up; then it is planned again.
            if session.history.revisionID == revision, !session.history.isEditing { plan = planned }
        } catch {
            await showError("Couldn’t save the Photoshop file", error: error)
            return false
        }
        do {
            try await saveDocument(to: url, format: format, options: options, plan: plan)
            return true
        } catch {
            await showError("Couldn’t save the Photoshop file", error: error)
            return false
        }
    }

    /// Writes a captured project in the background. Only that captured version counts as saved.
    private func write(_ snapshot: ProjectSnapshot, to destination: URL, revision: UUID) async -> Bool {
        let task = Task { @MainActor [self] () -> Bool in
            let scoped = destination.startAccessingSecurityScopedResource()
            defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
            let started = ContinuousClock.now
            let kind = DocumentLog.saveKind(to: destination, current: session.projectURL, adopts: true)
            do {
                let quickLook = await ImageExporter.shared.quickLookImages(snapshot)
                try await savingProject(to: destination, adopt: true) {
                    try await ProjectStore.shared.save(snapshot, to: destination, quickLook: quickLook)
                    finishSave(to: destination, format: .comp, revision: revision)
                }
                DocumentLog.saved(destination, format: .comp, kind: kind, via: "app", report: nil, startedAt: started)
                return true
            } catch {
                await showError("Couldn’t save the project", error: error)
                return false
            }
        }
        writing = task
        let saved = await task.value
        if writing == task { writing = nil }
        return saved
    }

    /// Writes the document to `url` as `format`, with no panels or sheets, and makes `url` the document's file
    /// (`finishSave`). A Photoshop file is written with `options` (the collapsed folders written closed) and its report
    /// returned, or as `plan` when the document was planned already as it is; a project returns nil. Callers keep the
    /// session from changing until it returns, so the document marked saved is the one written. A failure throws the
    /// writer's error and leaves the document, and whatever was at `url`, as they were.
    @discardableResult
    func saveDocument(to url: URL, format: ProjectFileFormat, options: PSDWriteOptions = PSDWriteOptions(),
                      plan: PSDWritePlan? = nil) async throws -> PSDWriteReport? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let started = ContinuousClock.now, kind = DocumentLog.saveKind(to: url, current: session.projectURL, adopts: true)
        let revision = session.history.currentRevision
        var report: PSDWriteReport?
        switch format {
        case .comp:
            guard let snapshot = session.projectSnapshot() else { throw ProjectError.invalid }
            let quickLook = await ImageExporter.shared.quickLookImages(snapshot)
            try await savingProject(to: url, adopt: true) {
                try await ProjectStore.shared.save(snapshot, to: url, quickLook: quickLook)
                finishSave(to: url, format: format, revision: revision)
            }
        case .psd:
            if let plan {
                report = try await PSDExporter.shared.export(plan, to: url)
            } else {
                guard let request = session.psdWriteRequest() else { throw PSDWriteError.render }
                var options = options
                options.collapsedGroupIDs.formUnion(session.collapsedGroupIDs)
                report = try await PSDExporter.shared.export(request, to: url, options: options)
            }
            finishSave(to: url, format: format, revision: revision)
            await syncProjectWatch()
        }
        DocumentLog.saved(url, format: format, kind: kind, via: "app", report: report, startedAt: started)
        return report
    }

    /// A save made `url`, in `format`, the document's file: ⌘S writes it from now on, the document reads as saved, and
    /// the file joins the recent documents. Only `revision`, the document as it was written, counts as saved: edits
    /// made while a project was writing in the background leave it modified.
    private func finishSave(to url: URL, format: ProjectFileFormat, revision: UUID) {
        session.projectURL = url
        session.documentFormat = format
        session.history.markSaved(revision)
        saveGeneration += 1
        noteRecentDocument(url)
    }

    /// The test host is the app itself: its saves and opens stay out of the Recent Documents the app shows.
    private func noteRecentDocument(_ url: URL) {
        guard !CompositorApplicationDelegate.isHostingTests else { return }
        RecentProjects.shared.note(url)
    }

    /// The Save panel, with a Format pop-up starting at the document's format: where to save and as what, or nil
    /// when cancelled. Choosing an existing file asks to replace it, the Photoshop file the document came from too.
    private func chooseSaveDestination(asNew: Bool) async -> (url: URL, format: ProjectFileFormat)? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = asNew ? "Save As" : "Save"
        let accessory = SaveFormatAccessory(panel: panel, format: session.documentFormat)
        let name = (session.projectURL ?? session.sourceURL)?.deletingPathExtension().lastPathComponent ?? "Untitled"
        panel.nameFieldStringValue = name + "." + accessory.format.rawValue
        let response: NSApplication.ModalResponse
        if let window { response = await panel.beginSheetModal(for: window) }
        else { response = await panel.begin() }
        guard response == .OK, let url = panel.url else { return nil }
        return (url, accessory.format)
    }

    /// Lists what a Photoshop save changes (`PSDWriteReportSheet`) and waits for Save (true) or Cancel.
    private func approvePhotoshopReport(_ warnings: [PSDWriteWarning], fileName: String) async -> Bool {
        if let confirmPhotoshopReport { return await confirmPhotoshopReport(warnings) }
        guard let window else {
            let alert = NSAlert()
            alert.messageText = "Save “\(fileName)” as a Photoshop file?"
            alert.informativeText = warnings.filter(\.lossy).map { "\($0.layerName): \($0.message)" }.joined(separator: "\n\n")
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            return await show(alert) == .alertFirstButtonReturn
        }
        return await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = "Save as Photoshop"
            sheet.contentViewController = NSHostingController(rootView: PSDWriteReportSheet(fileName: fileName, warnings: warnings) { save in
                window.endSheet(sheet)
                sheet.orderOut(nil)
                sheet.contentViewController = nil
                continuation.resume(returning: save)
            })
            window.beginSheet(sheet)
        }
    }

    @discardableResult
    func open(_ suppliedURL: URL? = nil) async -> Bool {
        if let workspace { return await workspace.open(suppliedURL) }
        guard begin() else { return false }
        defer { session.isProjectBusy = false }
        var source = suppliedURL
        if source == nil {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.compositorProject]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.treatsFilePackagesAsDirectories = false
            panel.title = "Open Project"
            let response: NSApplication.ModalResponse
            if let window { response = await panel.beginSheetModal(for: window) }
            else { response = await panel.begin() }
            guard response == .OK, let url = panel.url else { return false }
            source = url
        }
        guard let source else { return false }
        // A recent project deleted in Finder: name the project, not the manifest inside it the load would miss.
        guard FileManager.default.fileExists(atPath: source.path) else {
            RecentProjects.shared.refresh()
            await showError("Couldn’t open the project", error: CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path]))
            return false
        }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let started = ContinuousClock.now
        do {
            // Validate first. A corrupt project never discards the live document.
            var snapshot = try await ProjectStore.shared.load(from: source)
            DocumentLog.opened(source, format: "comp", conversions: [], startedAt: started)
            let previousSave = saveGeneration
            guard await confirmReplacement() else { return false }
            // Saving in the confirmation can replace the very file being opened. Compared by path: a package's URL
            // gains a trailing slash once it exists.
            if saveGeneration != previousSave,
               session.projectURL?.resolvingSymlinksInPath().path == source.resolvingSymlinksInPath().path {
                snapshot = try await ProjectStore.shared.load(from: source)
            }
            session.installProject(snapshot, from: source)
            noteRecentDocument(source)
            await rememberProjectDigest(for: source)
            watchProject(at: source)
            return true
        } catch {
            await showError("Couldn’t open the project", error: error)
            return false
        }
    }

    func newCanvas() async {
        if let workspace { workspace.newCanvas(); return }
        guard begin() else { return }
        let proceed = await confirmReplacement()
        session.isProjectBusy = false
        if proceed { session.clearProject(); stopWatchingProject() }
    }

    func close(_ window: NSWindow) async {
        if let workspace, let tab = workspace.tabs.first(where: { $0.controller === self }) {
            await workspace.close(tab.id); return
        }
        guard begin() else { return }
        let proceed = await confirmReplacement()
        session.isProjectBusy = false
        if proceed {
            session.clearProject()
            stopWatchingProject()
            window.close()
        }
    }

    func confirmQuit() async -> Bool {
        guard begin() else { return false }
        defer { session.isProjectBusy = false }
        return await confirmReplacement()
    }

    private func confirmReplacement() async -> Bool {
        // A save still writing finishes before the project can be closed or replaced, so its file is never cut short.
        await finishWriting()
        guard session.isModified, session.document != nil else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(session.projectURL?.lastPathComponent ?? "Untitled")?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        let response = await show(alert)
        if response == .alertFirstButtonReturn { return await saveCurrent() }
        return response == .alertThirdButtonReturn
    }

    private func showError(_ title: String, error: Error) async {
        AppLog.alert(title, error: error)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        _ = await show(alert)
    }

    private func show(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let window { return await alert.beginSheetModal(for: window) }
        return alert.runModal()
    }

    private struct Incoming {
        let files: [(URL, Bool)]
        let point: CGPoint?
        let completion: CheckedContinuation<Void, Never>
    }
    private var incoming: [Incoming] = []
    private var processing = false

    func receive(_ urls: [URL], at point: CGPoint? = nil) async {
        if let workspace, let tab = workspace.tabs.first(where: { $0.controller === self }) {
            await workspace.receive(urls, into: tab.id, at: point); return
        }
        guard !urls.isEmpty else { return }
        let files = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        await withCheckedContinuation { completion in
            incoming.append(Incoming(files: files, point: point, completion: completion))
            if !processing {
                processing = true
                Task { await drainIncoming() }
            }
        }
    }

    private func drainIncoming() async {
        while !incoming.isEmpty {
            let request = incoming.removeFirst()
            await session.waitForFileRequest()
            let urls = request.files.map(\.0)
            let projects = urls.filter { $0.pathExtension.lowercased() == "comp" }
            if projects.count > 1 {
                await showError("Open one project at a time", error: ProjectError.invalid)
            } else {
                var proceed = true
                if let project = projects.first { proceed = await open(project) }
                if proceed {
                    await session.importImages(urls.filter { $0.pathExtension.lowercased() != "comp" },
                                               at: projects.isEmpty ? request.point : nil)
                }
            }
            for (url, scoped) in request.files where scoped { url.stopAccessingSecurityScopedResource() }
            request.completion.resume()
        }
        processing = false
    }
}

/// The Save panel's Format pop-up: a Compositor project or a Photoshop file. Choosing one sets the panel's type, which
/// gives the name its extension.
@MainActor
private final class SaveFormatAccessory: NSObject {
    private weak var panel: NSSavePanel?
    private(set) var format: ProjectFileFormat
    private static let formats: [(format: ProjectFileFormat, title: String, type: UTType)] = [
        (.comp, "Compositor Project", .compositorProject),
        (.psd, "Photoshop", .photoshopImage),
    ]

    init(panel: NSSavePanel, format: ProjectFileFormat) {
        self.panel = panel
        self.format = format
        super.init()
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.addItems(withTitles: Self.formats.map(\.title))
        popUp.selectItem(at: Self.formats.firstIndex { $0.format == format } ?? 0)
        popUp.target = self
        popUp.action = #selector(choose(_:))
        let row = NSStackView(views: [NSTextField(labelWithString: "Format:"), popUp])
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        panel.accessoryView = row
        panel.allowedContentTypes = [Self.formats.first { $0.format == format }?.type ?? .compositorProject]
    }

    @objc private func choose(_ popUp: NSPopUpButton) {
        let choice = Self.formats[max(0, popUp.indexOfSelectedItem)]
        format = choice.format
        panel?.allowedContentTypes = [choice.type]
    }
}
