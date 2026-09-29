import AppKit
import Foundation
import MCP

/// File paths tools accept, and the Agent folder they default to.
///
/// A path may be:
/// - absolute (`/Users/me/Desktop/hero.png`), used as is;
/// - tilde-prefixed (`~/Desktop/hero.png`), expanded to the user's home folder;
/// - relative (`photos/input.jpg`), resolved against the Agent folder (or the directory
///   a tool passes as `defaultDirectory`).
///
/// **Tools turn path arguments into URLs with `resolveReachable`, and touch no file any other
/// way.** macOS privacy (TCC) makes the first stat, open or read in Documents, Desktop,
/// Downloads, iCloud Drive, cloud storage or on another volume wait until the owner answers a
/// prompt — forever, for an agent working unattended. `resolveReachable` checks
/// `FolderAccess` before anything on disk is touched and fails within
/// `FolderAccess.defaultTimeout` instead: `io_error` with `details.code` `folder_access_denied`,
/// or `busy` with `folder_access_pending` (`MCPToolError.from` maps them). A URL a tool
/// already holds — a document's own file, a path it added an extension to — goes through
/// `ensureReachable`, `exists`, `checkForWriting` or `prepareForWriting`, which check the same way first.
/// `MCPFolderAccessTests` scans Compositor/MCP for file-system calls anywhere else.
///
/// Writing tools never replace an existing file unless the call passes `overwrite: true`;
/// otherwise they fail with `io_error` and `details.code == "file_exists"`.
@MainActor
enum MCPPaths {
    /// One file or folder in a `list(in:recursive:extensions:limit:)` listing.
    nonisolated struct Entry: Codable, Sendable {
        /// Path relative to the listed folder ("sub/photo.png").
        let name: String
        /// Absolute path, for passing to another tool or reading the file from the host.
        let path: String
        /// Bytes, for files (a symbolic link's target's); nil for folders and packages.
        let size: Int64?
        /// A folder that can be listed. Packages such as `.comp` projects, and symbolic links, are files.
        let isDirectory: Bool
    }

    /// A folder a listing didn't enter because macOS hasn't let Compositor in, or hasn't been asked.
    nonisolated struct Skipped: Equatable, Sendable {
        /// The listing's time for asking macOS ran out before it reached the folder, so it wasn't asked about.
        static let uncheckedCode = "folder_access_unchecked"

        /// Absolute path, spelled as the listing's entries are.
        let path: String
        /// Why: `folder_access_denied`, `folder_access_pending`, or `uncheckedCode`.
        let code: String
    }

    /// What `list(in:recursive:extensions:limit:)` found.
    nonisolated struct Listing: Sendable {
        var entries: [Entry] = []
        /// More was left out: `limit` entries were found, or `listScanLimit` items looked at.
        var truncated = false
        /// Folders listed but not entered, in the order they were reached.
        var skipped: [Skipped] = []
    }

    /// The Agent folder, created if missing.
    static func agentFolder() throws -> URL {
        let root = MCPSettings.agentRootURL
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                throw MCPToolError(.ioError, "Could not create the Agent folder at \(root.path): \(error.localizedDescription)")
            }
        } else if !isDirectory.boolValue {
            throw MCPToolError(.ioError, "The Agent folder exists but is not a directory: \(root.path)")
        }
        return root
    }

    /// Resolves a tool-supplied path (see the type comment) and checks that macOS lets
    /// Compositor reach it: the way every tool turns a path argument into a URL. A nil or
    /// empty `raw` is `defaultDirectory` itself; a nil `defaultDirectory` is the Agent folder.
    ///
    /// The path is expanded and made absolute without touching the file system, checked with
    /// `ensureReachable` (for a write, with the folder it goes in), and only then looked at:
    /// - `mustExist`: fail with `not_found` when nothing is at the path.
    /// - `forWriting`: fail with `io_error` (`details.code == "file_exists"`) when something
    ///   is already at the path and `overwrite` is false; otherwise create the parent folder.
    ///
    /// Throws `FolderAccessError` within `FolderAccess.defaultTimeout` when macOS denies access
    /// or is waiting on a prompt.
    static func resolveReachable(_ raw: String?, defaultDirectory: URL? = nil, mustExist: Bool = false,
                                 forWriting: Bool = false, overwrite: Bool = false) async throws -> URL {
        let expanded = raw.flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
        let isAbsolute = expanded?.hasPrefix("/") == true
        let base = defaultDirectory ?? MCPSettings.agentRootURL
        let given = isAbsolute ? (expanded ?? "/") : base.path + "/" + (expanded ?? "")
        // With `isDirectory` given, making the URL doesn't look at the disk.
        let unchecked = URL(fileURLWithPath: given, isDirectory: given.hasSuffix("/"))
        try await ensureReachable(unchecked, forWriting: forWriting)
        // The Agent folder is made the first time a relative path (or the default) needs it.
        if defaultDirectory == nil, !isAbsolute { _ = try agentFolder() }
        // Standardizing can read the disk (".." is resolved through symlinks): only now.
        let url = unchecked.standardizedFileURL
        if mustExist, !FileManager.default.fileExists(atPath: url.path) {
            throw MCPToolError(.notFound, "Nothing exists at \(url.path).",
                               hint: "Relative paths resolve inside the Agent folder; list_files shows what is there.",
                               details: ["path": .string(url.path)])
        }
        if forWriting {
            try refuseExisting(url, overwrite: overwrite)
            try createParentFolder(of: url)
        }
        return url
    }

    /// Checks that macOS lets Compositor reach `url` — and, for a write, the folder it goes
    /// in — before a tool stats, opens, reads or writes it. For a URL a tool already holds
    /// (a document's own file); path arguments go through `resolveReachable`. Throws
    /// `FolderAccessError` within `FolderAccess.defaultTimeout` otherwise.
    static func ensureReachable(_ url: URL, forWriting: Bool = false) async throws {
        try await FolderAccess.ensureReachable(forWriting ? [url, url.deletingLastPathComponent()] : [url])
    }

    /// Whether anything is at `url`, once `ensureReachable` has let it through.
    static func exists(_ url: URL) async throws -> Bool {
        try await ensureReachable(url)
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Whether `url` and `other` are the same file, following symlinks. Both are checked with
    /// `ensureReachable` first (`other` may be a document's own file anywhere); one macOS won't
    /// let Compositor reach counts as a different file.
    static func isSameFile(_ url: URL, as other: URL?) async -> Bool {
        guard let other, (try? await FolderAccess.ensureReachable([url, other])) != nil else { return false }
        return url.resolvingSymlinksInPath().path == other.resolvingSymlinksInPath().path
    }

    /// Checks `url` for writing with `ensureReachable`, then refuses to replace an existing
    /// item unless `overwrite` and makes sure the parent folder exists. For a URL a tool
    /// adjusted after `resolveReachable` (adding an extension) or already holds.
    static func prepareForWriting(_ url: URL, overwrite: Bool) async throws {
        try await checkForWriting(url, overwrite: overwrite)
        try createParentFolder(of: url)
    }

    /// `prepareForWriting` without making the folder: for a tool that checks its guards again once macOS has
    /// answered, and calls `createParentFolder` only when they pass, so a refused call leaves no empty folder behind.
    static func checkForWriting(_ url: URL, overwrite: Bool) async throws {
        try await ensureReachable(url, forWriting: true)
        try refuseExisting(url, overwrite: overwrite)
    }

    /// Refuses to replace an existing item at `url`, already checked, unless `overwrite`.
    private static func refuseExisting(_ url: URL, overwrite: Bool) throws {
        if !overwrite, FileManager.default.fileExists(atPath: url.path) {
            throw MCPToolError(.ioError, "A file already exists at \(url.path).",
                               hint: "Pass overwrite: true to replace it, or choose another path.",
                               details: ["code": .string("file_exists"), "path": .string(url.path)])
        }
    }

    /// Makes the folder `url` goes in, once `url` is checked (`checkForWriting`).
    static func createParentFolder(of url: URL) throws {
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw MCPToolError(.ioError, "Could not create the folder \(parent.path): \(error.localizedDescription)",
                               details: ["path": .string(parent.path)])
        }
    }

    /// The most files and folders one listing looks at, so a recursive listing of a large tree ends in bounded time.
    nonisolated static let listScanLimit = 100_000

    /// The files and folders in `folder`, in name order; with `recursive`, each folder is followed by its contents.
    /// Hidden items and `.tmp` files are skipped. Packages (`.comp` projects) and symbolic links are listed as files
    /// and never entered; a link's size is its target's. With `extensions` (lowercased, no dot) only files with one
    /// of them are listed, though folders are still searched. Stops once `limit` entries are found, or after
    /// `listScanLimit` items, reporting `truncated`, and throws `CancellationError` once the calling task is
    /// cancelled. Fails with `invalid_argument` when `folder` is a file or a package, and `io_error` when it can't be
    /// read.
    ///
    /// `folder` must come from `resolveReachable`. Nothing else is read before macOS access to it is checked: a
    /// folder that is a protected root — or a volume, provider or iCloud folder directly inside one — is entered only
    /// once `FolderAccess` lets it through (otherwise it's listed, not entered, and named in `skipped`), and a link's
    /// target is checked before its size is read. The checks share one `FolderAccess.defaultTimeout`, so a listing
    /// never waits on macOS longer than that. Once it's used up (say, a prompt held one check that long), macOS isn't
    /// asked again: each guarded folder still ahead is listed, not entered, and named in `skipped` as
    /// `Skipped.uncheckedCode`, and a link into a protected root gets no size. A check with no time to wait learns
    /// nothing, and asking anyway would only report folders nobody asked about as waiting.
    ///
    /// Names are built from the path components walked, never by cutting the folder's path off a child's, so a
    /// folder reached through a symbolic link (`/var` is `/private/var`) still gets names relative to itself.
    @concurrent nonisolated static func list(in folder: URL, recursive: Bool, extensions: Set<String>?,
                                             limit: Int) async throws -> Listing {
        // The folder itself, symlinks followed (a link to a folder, or /var -> /private/var).
        let real = realPath(of: folder) ?? folder.path
        let folderValues = try? URL(fileURLWithPath: real, isDirectory: true).resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        guard let folderValues, folderValues.isDirectory == true else {
            throw MCPToolError.invalidArgument("\(folder.path) is a file, not a folder.", hint: "get_file_info describes a single file.")
        }
        if isPackage(folder, folderValues) {
            throw MCPToolError.invalidArgument("\(folder.path) is a package, which the Finder shows as a single file, not a folder.",
                                               hint: "get_file_info describes it, and open_document opens a .comp project.")
        }
        let guarded = await FolderAccess.guardedFolders
        var budget = FolderAccess.defaultTimeout
        var listing = Listing()
        var scanned = 0
        // Depth first, children in name order: the stack holds each folder's remaining children, reversed, with
        // their names and real paths.
        var stack: [(url: URL, name: String, real: String)] = try contents(of: folder).reversed().map {
            ($0, $0.lastPathComponent, real + "/" + $0.lastPathComponent)
        }
        while let (url, name, childReal) = stack.popLast() {
            try Task.checkCancellation()
            scanned += 1
            if scanned > listScanLimit {
                listing.truncated = true
                return listing
            }
            let values = try? url.resourceValues(forKeys: Set(entryKeys))
            let isLink = values?.isSymbolicLink == true
            let isDirectory = !isLink && (values.map { $0.isDirectory == true && !isPackage(url, $0) } ?? false)
            let listed = isDirectory ? extensions == nil : extensions?.contains(url.pathExtension.lowercased()) ?? true
            if listed {
                if listing.entries.count == limit {
                    listing.truncated = true
                    return listing
                }
                let size = isLink ? await targetSize(of: url, budget: &budget)
                    : values?.isDirectory == true ? nil : values?.fileSize.map { Int64($0) }
                listing.entries.append(Entry(name: name, path: folder.appendingPathComponent(name).path, size: size,
                                             isDirectory: isDirectory))
            }
            guard recursive, isDirectory else { continue }
            if guarded.contains(childReal),
               let refusal = await accessRefusal(URL(fileURLWithPath: childReal, isDirectory: true), budget: &budget) {
                listing.skipped.append(Skipped(path: folder.appendingPathComponent(name).path, code: refusal))
                continue
            }
            if let children = try? contents(of: url) {
                stack.append(contentsOf: children.reversed().map {
                    ($0, name + "/" + $0.lastPathComponent, childReal + "/" + $0.lastPathComponent)
                })
            }
        }
        return listing
    }

    /// What a listing reads about each item.
    private nonisolated static let entryKeys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .isSymbolicLinkKey]

    /// `directory`'s visible items, `.tmp` files left out, in name order.
    private nonisolated static func contents(of directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: entryKeys, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() != "tmp" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// `url`'s path with every symlink resolved, as the kernel sees it; nil when it can't be resolved.
    private nonisolated static func realPath(of url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The size in bytes of the file the symbolic link at `link` leads to: nil when it leads to a folder, nowhere, or
    /// somewhere macOS hasn't let Compositor in (checked before anything there is read).
    private nonisolated static func targetSize(of link: URL, budget: inout Duration) async -> Int64? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return nil }
        let target = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination, isDirectory: false)
            : link.deletingLastPathComponent().appendingPathComponent(destination, isDirectory: false)
        guard await accessRefusal(target, budget: &budget) == nil else { return nil }
        var info = stat()
        guard stat(target.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Int64(info.st_size)
    }

    /// Why a listing can't read `url`, as a `skipped` code; nil when it can. Within what's left of `budget` (which the
    /// wait uses up), that's macOS's answer: `folder_access_denied` or `folder_access_pending`. Once `budget` is spent,
    /// macOS isn't asked (`FolderAccess` would have no time to find anything out): a path in a protected root is
    /// `Skipped.uncheckedCode`, and one outside every root needs no asking.
    private nonisolated static func accessRefusal(_ url: URL, budget: inout Duration) async -> String? {
        guard budget > .zero else {
            return await FolderAccess.root(containing: url) == nil ? nil : Skipped.uncheckedCode
        }
        let clock = ContinuousClock()
        let start = clock.now
        defer { budget -= start.duration(to: clock.now) }
        do {
            try await FolderAccess.ensureReachable(url, timeout: budget)
            return nil
        } catch {
            return (error as? FolderAccessError)?.code
        }
    }

    /// A folder the Finder shows as a file, such as a `.comp` project (one even where Launch Services doesn't know
    /// the type). `values` holds at least `isDirectoryKey` and `isPackageKey`.
    nonisolated static func isPackage(_ url: URL, _ values: URLResourceValues) -> Bool {
        values.isDirectory == true && (values.isPackage == true || url.pathExtension.lowercased() == "comp")
    }

    /// Opens the Agent folder in Finder.
    @discardableResult
    static func reveal() throws -> URL {
        let root = try agentFolder()
        NSWorkspace.shared.activateFileViewerSelecting([root])
        return root
    }
}
