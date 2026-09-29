import Foundation

/// What the diagnostic log (`CompositorLog`) records about documents (`document` category), macOS folder access
/// (`folder_access`) and the profile library (`profile`). The hooks in the workspace, the project controller, the MCP
/// document tools, `FolderAccess` and `ProfileLibrary` each call one function here.
nonisolated enum DocumentLog {
    // MARK: Documents

    /// A file read to open (or revert) a document: its format, size, how long reading took, and the Photoshop
    /// conversions it needed (how many, and their notes, each named once).
    static func opened(_ url: URL, format: String, conversions: [PSDConversion], startedAt started: ContinuousClock.Instant) {
        let log = CompositorLog.active
        guard log.isRecording else { return }
        var fields: [String: LogValue] = ["path": .string(url.path), "format": .string(format),
                                          "duration_ms": .milliseconds(since: started), "conversions": .int(conversions.count)]
        var seen = Set<String>()
        let notes = conversions.map(\.message).filter { seen.insert($0).inserted }
        if !notes.isEmpty { fields["conversion_notes"] = .array(notes.map { .string(String($0.prefix(120))) }) }
        logMeasuring(url, .info, "open", fields, log: log)
    }

    static func openFailed(_ url: URL, error: any Error) {
        CompositorLog.active.warning(.document, "open_failed", ["path": .string(url.path), "error": .string(error.localizedDescription)])
    }

    /// A document written to `url`. `kind` is `save` (its own file), `save_as` (a new file it now lives in) or `copy`
    /// (a new file, the document left where it was); `via` is `app` or `mcp`. A Photoshop file lists the writer's
    /// warnings and whether any changed the document (`lossy`); a project's package is measured after the fact, off
    /// the main actor.
    static func saved(_ url: URL, format: ProjectFileFormat, kind: String, via: String, report: PSDWriteReport?,
                      startedAt started: ContinuousClock.Instant) {
        let log = CompositorLog.active
        guard log.isRecording else { return }
        var fields: [String: LogValue] = ["path": .string(url.path), "format": .string(format.rawValue),
                                          "kind": .string(kind), "via": .string(via),
                                          "duration_ms": .milliseconds(since: started)]
        guard let report else {
            logMeasuring(url, .info, "save", fields, log: log)
            return
        }
        fields["bytes"] = .int(report.byteCount)
        fields["layer_records"] = .int(report.layerRecordCount)
        fields["lossy"] = .bool(report.warnings.contains(where: \.lossy))
        fields["warnings"] = .array(report.warnings.map {
            .object(["layer": .string($0.layerName), "message": .string($0.message), "lossy": .bool($0.lossy)])
        })
        log.info(.document, "save", fields)
    }

    /// What kind of save writing to `url` is (`saved`'s `kind`), asked before the document's file changes.
    static func saveKind(to url: URL, current: URL?, adopts: Bool) -> String {
        if let current, current.standardizedFileURL.path == url.standardizedFileURL.path { return "save" }
        return adopts ? "save_as" : "copy"
    }

    /// An image written from a document.
    static func exported(_ url: URL, format: String, bytes: Int, width: Int, height: Int, via: String) {
        CompositorLog.active.info(.document, "export", ["path": .string(url.path), "format": .string(format), "bytes": .int(bytes),
                                                         "width": .int(width), "height": .int(height), "via": .string(via)])
    }

    static func reverted(_ url: URL, discardedChanges: Bool) {
        CompositorLog.active.info(.document, "revert", ["path": .string(url.path), "discarded_changes": .bool(discardedChanges)])
    }

    /// A document's tab closed; `url` is nil for a document never saved or opened from a file.
    static func closed(_ url: URL?, title: String, discardedChanges: Bool) {
        CompositorLog.active.info(.document, "close", ["path": .text(url?.path), "title": .string(title),
                                                        "discarded_changes": .bool(discardedChanges)])
    }

    /// A preview an agent asked for (verbose only): the size drawn, the document's layer count, the encoded size and
    /// how long drawing, scaling and encoding took.
    static func rendered(width: Int, height: Int, layers: Int, bytes: Int, startedAt started: ContinuousClock.Instant) {
        CompositorLog.active.debug(.document, "render", ["width": .int(width), "height": .int(height), "layers": .int(layers),
                                                          "bytes": .int(bytes), "duration_ms": .milliseconds(since: started)])
    }

    /// Logs `event` with the size of `url` as `bytes`. A package (a .comp is a folder of files) is measured off the
    /// main actor, and logged once measured; a file's size is read at once.
    private static func logMeasuring(_ url: URL, _ level: CompositorLog.Level, _ event: String, _ fields: [String: LogValue],
                                     log: CompositorLog) {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            var fields = fields
            fields["bytes"] = .int(size(of: url))
            log.log(level, .document, event, fields)
            return
        }
        Task.detached(priority: .utility) {
            var fields = fields
            fields["bytes"] = .int(size(of: url))
            log.log(level, .document, event, fields)
        }
    }

    /// A file's size, or a package's (a .comp is a folder): the sum of the files inside.
    static func size(of url: URL) -> Int {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return 0 }
        guard info.st_mode & S_IFMT == S_IFDIR else { return Int(info.st_size) }
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let file = files?.nextObject() as? URL {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    // MARK: Folder access

    /// A probe of a protected location: what macOS answered and how long it took.
    static func probed(_ root: ProtectedRoot, _ access: RootAccess, startedAt started: ContinuousClock.Instant) {
        CompositorLog.active.info(.folderAccess, "probe", {
            var fields: [String: LogValue] = ["root": .string(root.rawValue), "state": .string(access.state.rawValue),
                                              "duration_ms": .milliseconds(since: started)]
            if !access.deniedFolders.isEmpty { fields["denied_folders"] = .array(access.deniedFolders.map(LogValue.string)) }
            if !access.pendingFolders.isEmpty { fields["pending_folders"] = .array(access.pendingFolders.map(LogValue.string)) }
            return fields
        }())
    }

    /// A path Compositor couldn't reach: macOS refused, or its permission prompt is still waiting.
    static func blocked(_ error: FolderAccessError) {
        CompositorLog.active.warning(.folderAccess, "blocked", ["path": .string(error.path), "root": .string(error.root.rawValue),
                                                                 "code": .string(error.code)])
    }

    // MARK: Profiles

    static func scanned(_ index: ProfileIndex, startedAt started: ContinuousClock.Instant) {
        CompositorLog.active.info(.profile, "scan", ["profiles": .int(index.profiles.count), "usable": .int(index.usable.count),
                                                      "hidden": .int(index.hidden.total), "groups": .int(index.groups.count),
                                                      "duration_ms": .milliseconds(since: started)])
    }

    static func imported(_ report: ProfileImportReport) {
        CompositorLog.active.info(.profile, "import", {
            var fields: [String: LogValue] = ["imported": .int(report.imported.count),
                                              "already_imported": .int(report.alreadyImported.count),
                                              "skipped": .int(report.skipped.count)]
            if !report.skipped.isEmpty {
                fields["skipped_files"] = .array(report.skipped.map {
                    .object(["path": .string($0.url.path), "reason": .string(String(describing: $0.error))])
                })
            }
            return fields
        }())
    }
}
