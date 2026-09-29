import Foundation
import Observation

/// A location macOS guards with its Files & Folders privacy controls (TCC).
///
/// Leaving out the App Sandbox doesn't lift these: the first read of one blocks inside
/// `open()` until the owner answers a consent prompt, which would hang an unattended agent
/// indefinitely. `FolderAccess` finds, probes and reports them.
nonisolated enum ProtectedRoot: String, CaseIterable, Sendable {
    case documents
    case desktop
    case downloads
    /// iCloud Drive and apps' iCloud folders: `~/Library/Mobile Documents`.
    case iCloudDrive = "icloud_drive"
    /// File Provider locations such as Google Drive or Dropbox: `~/Library/CloudStorage`.
    case cloudStorage = "cloud_storage"
    /// Removable and network volumes: `/Volumes`.
    case removableVolumes = "removable_volumes"

    /// Where the root is on this Mac, whether or not it exists. Computing it touches nothing
    /// on disk.
    var location: URL { location(home: FileManager.default.homeDirectoryForCurrentUser) }

    /// Where the root is for a user whose home folder is `home` (`/Volumes` doesn't depend
    /// on it).
    func location(home: URL) -> URL {
        switch self {
        case .documents: home.appendingPathComponent("Documents", isDirectory: true)
        case .desktop: home.appendingPathComponent("Desktop", isDirectory: true)
        case .downloads: home.appendingPathComponent("Downloads", isDirectory: true)
        case .iCloudDrive: home.appendingPathComponent("Library/Mobile Documents", isDirectory: true)
        case .cloudStorage: home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        case .removableVolumes: URL(fileURLWithPath: "/Volumes", isDirectory: true)
        }
    }

    /// The root, or nil when it doesn't exist on this Mac. Only the folder itself is looked
    /// at, never what's inside it, so this never waits on a prompt.
    var url: URL? { FileManager.default.fileExists(atPath: location.path) ? location : nil }

    /// The root's name in Settings and in error messages.
    var displayName: String {
        switch self {
        case .documents: "Documents"
        case .desktop: "Desktop"
        case .downloads: "Downloads"
        case .iCloudDrive: "iCloud Drive"
        case .cloudStorage: "Cloud storage"
        case .removableVolumes: "Removable and network volumes"
        }
    }

    /// Whether each folder directly inside the root is guarded on its own — an app's iCloud
    /// folder, a File Provider (macOS asks about "files managed by Google Drive"), a mounted
    /// volume — so access is decided per folder rather than once for the whole root.
    var guardsEachFolder: Bool {
        switch self {
        case .documents, .desktop, .downloads: false
        case .iCloudDrive, .cloudStorage, .removableVolumes: true
        }
    }
}

/// Whether Compositor may read a protected root, as a probe found it.
nonisolated enum FolderAccessState: String, Sendable {
    /// The listing succeeded.
    case granted
    /// macOS refused the listing (`EPERM`/`EACCES`).
    case denied
    /// The listing didn't finish in time: macOS is waiting for the owner to answer a prompt
    /// (or the location isn't responding).
    case notDetermined = "not_determined"
    /// Nothing there to guard: the root doesn't exist, or holds no provider or volume.
    case absent
}

/// What probing a root found: its state and, for a root macOS guards folder by folder
/// (iCloud Drive, cloud storage, volumes), which folders inside it macOS refused or is still
/// asking about.
nonisolated struct RootAccess: Equatable, Sendable {
    /// Denied when any folder inside was refused, otherwise not determined when one is still
    /// waiting, otherwise granted when any was reached.
    let state: FolderAccessState
    /// Folders directly inside the root that macOS refused, by name.
    var deniedFolders: [String] = []
    /// Folders directly inside the root still waiting on a prompt (or not answering), by
    /// name. A probe stops at the first, so it names one at most; tools checking their own
    /// paths can add others.
    var pendingFolders: [String] = []
}

/// Why a tool can't reach a path right now, and what the owner can do about it.
nonisolated struct FolderAccessError: LocalizedError, Sendable {
    enum Reason: Sendable {
        /// macOS refused access to the root.
        case denied
        /// A macOS permission prompt (or a location that isn't answering) is holding access up.
        case pending
    }

    let reason: Reason
    let root: ProtectedRoot
    /// The path the tool was about to read or write, spelled as tools report paths (see
    /// `FolderAccess.Checker.reportedPath(of:)`).
    let path: String

    /// The machine-readable code, for an error's `details.code`.
    var code: String {
        switch reason {
        case .denied: "folder_access_denied"
        case .pending: "folder_access_pending"
        }
    }

    var hint: String {
        switch reason {
        case .denied:
            "Grant Compositor access in System Settings > Privacy & Security > Files and Folders (or Full Disk Access), or copy the file to the Agent folder"
        case .pending:
            "A macOS permission prompt is waiting on this Mac; approve it and retry."
        }
    }

    var errorDescription: String? {
        switch reason {
        case .denied:
            "Compositor can't reach \(path): macOS denied it access to \(root.displayName)."
        case .pending:
            "Compositor can't reach \(path) yet: macOS is waiting for permission to access \(root.displayName) (or the location isn't responding), so the call stopped instead of waiting."
        }
    }
}

/// Finds which protected root a path is under, probes roots without ever blocking the
/// caller past a timeout, and turns what a probe finds into a `FolderAccessError`.
///
/// Tools call `ensureReachable` before reading or writing a path; Settings shows
/// `lastKnownAccess` and calls `probeAccess` when the owner asks for access.
enum FolderAccess {
    /// How long a tool waits on macOS before reporting access as pending.
    nonisolated static let defaultTimeout: Duration = .seconds(2)

    /// The checker the app uses. Test seam: tests install one with temporary roots and a
    /// fake lister, so nothing reads the real protected folders from the test host.
    static var checker = Checker()

    /// A checker for the current task and the tasks it starts, used in place of `checker`.
    /// Test seam for suites that run alongside others: a checker set for one test's calls
    /// never reaches another suite's, as swapping the process-wide one would (their
    /// get_app_info would probe the first test's fake roots).
    @TaskLocal static var taskChecker: Checker?

    /// The checker in effect: the task's, else the app's.
    static var activeChecker: Checker { taskChecker ?? checker }

    /// The places one tool call has found it can reach, so that it asks macOS about each once however many of its
    /// paths lie there (a path, the folder a file is written into, a document's own file). `MCPToolRegistry.call`
    /// gives each call its own; `ensureReachable` outside a call remembers nothing between checks.
    @TaskLocal static var reachedThisCall: ReachedPlaces?

    /// Places (a root, or a folder inside one guarded folder by folder) found reachable, by `Checker`'s place key.
    final class ReachedPlaces {
        fileprivate var keys: Set<String> = []
    }

    /// The protected root `url` is under, resolving symlinks (and the Data volume's
    /// `/System/Volumes/Data` spelling); nil when it's under none.
    ///
    /// This never reads anything that could wait, so a link directly inside a root that
    /// guards each folder — the startup disk's `/Volumes/Macintosh HD` → `/` — counts as
    /// under that root here. `ensureReachable` reads such a link on a probe thread and checks
    /// the path where it leads; tools call that, not this.
    static func root(containing url: URL) -> ProtectedRoot? {
        activeChecker.root(containing: url)
    }

    /// Non-blocking probe: lists `root` on a background thread and waits `timeout` at most.
    /// granted = the listing succeeded; denied = `EPERM`/`EACCES`; notDetermined = timed out
    /// (a consent prompt is pending); absent = the root is missing.
    static func probe(_ root: ProtectedRoot, timeout: Duration = defaultTimeout) async -> FolderAccessState {
        await activeChecker.probe(root, timeout: timeout)
    }

    /// `probe`, also naming the folders inside a root guarded folder by folder that are
    /// denied or still waiting. A probe that runs out of time before asking anything records
    /// nothing and reports what was already known (not determined, when nothing was).
    static func probeAccess(_ root: ProtectedRoot, timeout: Duration = defaultTimeout) async -> RootAccess {
        await activeChecker.probeAccess(root, timeout: timeout)
    }

    /// Checks the root that contains `url` (if any) before a tool reads or writes it, and
    /// throws a `FolderAccessError` within `timeout` instead of hanging. Call it before any
    /// stat, open or read of `url`: each of those can wait on a prompt. What it finds is
    /// recorded in `lastKnownAccess`, as a probe's is. With no time left (a zero `timeout`) it
    /// asks nothing, records nothing and throws `.pending`.
    static func ensureReachable(_ url: URL, timeout: Duration = defaultTimeout) async throws {
        try await activeChecker.ensureReachable([url], timeout: timeout)
    }

    /// `ensureReachable` for several paths — a file and the folder it's written into —
    /// sharing one timeout.
    static func ensureReachable(_ urls: [URL], timeout: Duration = defaultTimeout) async throws {
        try await activeChecker.ensureReachable(urls, timeout: timeout)
    }

    /// Every existing root's access, for reporting: the latest probe's for a root checked
    /// this session, and a fresh probe for the rest, all at once — so this waits `timeout`
    /// at most, however many roots are probed.
    static func currentAccess(timeout: Duration = defaultTimeout) async -> [ProtectedRoot: RootAccess] {
        await activeChecker.currentAccess(timeout: timeout)
    }

    /// The folders a walk through the file system must check before reading inside them.
    static var guardedFolders: GuardedFolders { activeChecker.guardedFolders }

    /// Each root's state from its latest probe this session; roots not probed yet are missing.
    static var lastKnownStates: [ProtectedRoot: FolderAccessState] { activeChecker.lastKnownStates }

    /// Each root's latest probe this session, with the folders inside it that are denied or
    /// waiting; roots not probed yet are missing.
    static var lastKnownAccess: [ProtectedRoot: RootAccess] { activeChecker.lastKnownAccess }

    /// The roots that exist on this Mac.
    static var existingRoots: [ProtectedRoot] { activeChecker.existingRoots }

    /// What a failed listing says about access. Only a refusal is a privacy problem; any
    /// other failure is left for the tool's own read to report.
    nonisolated static func state(for error: any Error) -> FolderAccessState {
        let error = error as NSError
        let posix = error.domain == NSPOSIXErrorDomain ? error : error.userInfo[NSUnderlyingErrorKey] as? NSError
        guard let posix, posix.domain == NSPOSIXErrorDomain else { return .granted }
        switch Int32(posix.code) {
        case EPERM, EACCES: return .denied
        case ENOENT, ENOTDIR: return .absent
        default: return .granted
        }
    }
}

extension FolderAccess {
    /// The probing machinery behind `FolderAccess`, with the roots and the directory
    /// listing injectable for tests.
    ///
    /// A listing macOS holds up for a consent prompt blocks its thread in the kernel until
    /// the owner answers — possibly forever — and nothing can cancel it. So each listing
    /// runs on a thread of its own, callers stop waiting at their timeout, and a folder
    /// whose listing is still outstanding never gets a second one: later callers wait on
    /// (and time out on) the same listing. No listing starts once its caller's deadline has
    /// passed, and a check that asked nothing records nothing: what's known stays.
    ///
    /// Observable: Settings shows `lastKnownAccess` as probes and tools' own checks update it.
    @Observable
    final class Checker {
        /// Lists `directory`, returning the names of the visible folders directly inside
        /// it. Runs on a background thread, where it may block indefinitely.
        typealias Lister = @Sendable (URL) throws -> [String]
        /// Where the item at a URL leads when it's a symlink; nil when it isn't one. Runs on
        /// a background thread: the item may be a mount point, and looking at one can wait
        /// on its volume (or its prompt).
        typealias LinkReader = @Sendable (URL) -> String?

        /// How many symlinks a path may pass through before it counts as a loop.
        private static let maxLinks = 32

        let locations: [ProtectedRoot: URL]
        private let lister: Lister
        private let linkReader: LinkReader
        /// Listings still running, by kind and folder path (ignoring case, as APFS does).
        @ObservationIgnored private var outstanding: [String: Listing] = [:]
        private(set) var lastKnownAccess: [ProtectedRoot: RootAccess] = [:]

        init(locations: [ProtectedRoot: URL] = Dictionary(uniqueKeysWithValues: ProtectedRoot.allCases.map { ($0, $0.location) }),
             lister: @escaping Lister = { try Checker.listFolders(in: $0) },
             linkReader: @escaping LinkReader = { Checker.symlinkTarget(of: $0) }) {
            self.locations = locations
            self.lister = lister
            self.linkReader = linkReader
        }

        var lastKnownStates: [ProtectedRoot: FolderAccessState] { lastKnownAccess.mapValues(\.state) }

        /// The root, or nil when it doesn't exist (only the folder itself is looked at).
        func url(of root: ProtectedRoot) -> URL? {
            guard let location = locations[root], FileManager.default.fileExists(atPath: location.path) else { return nil }
            return location
        }

        var existingRoots: [ProtectedRoot] { ProtectedRoot.allCases.filter { url(of: $0) != nil } }

        func root(containing url: URL) -> ProtectedRoot? {
            guard url.isFileURL else { return nil }
            return place(of: url.path)?.root
        }

        func probe(_ root: ProtectedRoot, timeout: Duration) async -> FolderAccessState {
            await probeAccess(root, timeout: timeout).state
        }

        func probeAccess(_ root: ProtectedRoot, timeout: Duration) async -> RootAccess {
            await report(root, until: .now + timeout)
        }

        func ensureReachable(_ url: URL, timeout: Duration) async throws {
            try await ensureReachable([url], timeout: timeout)
        }

        func ensureReachable(_ urls: [URL], timeout: Duration) async throws {
            let deadline = ContinuousClock.now + timeout
            // A file and the folder it's written into are nearly always in the same place: that place is checked
            // once, so a slow first check can't leave the second out of time. So is a place the tool call already
            // checked (`FolderAccess.reachedThisCall`).
            let call = FolderAccess.reachedThisCall
            var reached = call?.keys ?? []
            defer { call?.keys.formUnion(reached) }
            do {
                for url in urls { try await ensureReachable(url, until: deadline, reached: &reached) }
            } catch let error as FolderAccessError {
                DocumentLog.blocked(error)
                throw error
            }
        }

        /// Checks `url`, skipping a place in `reached` (a root, or a folder inside one guarded folder by folder)
        /// and adding each place it finds reachable.
        private func ensureReachable(_ url: URL, until deadline: ContinuousClock.Instant, reached: inout Set<String>) async throws {
            guard url.isFileURL else { return }
            // Standardized without touching the disk (which is the point): absolute, with "."
            // and empty components gone. ".." stays for `place(of:)`, which steps back out the
            // way the kernel does, through symlinks, as the spelling alone can't tell.
            let standardized = "/" + Self.components(of: url.absoluteURL.path).joined(separator: "/")
            // An error names the path as a tool that went through reports it (`standardizedFileURL`'s spelling,
            // ".." taken back a component), still without touching the disk.
            let reported = Self.reportedPath(of: url)
            var path = standardized
            // A link directly inside a root that guards each folder can lead anywhere — the
            // startup disk's /Volumes/Macintosh HD → / leads back to ~/Documents — so it's
            // read (on a probe thread) and the path checked again from where it leads.
            for _ in 0...Self.maxLinks {
                guard let place = place(of: path) else { return }
                let placeKey = place.root.rawValue + (place.folder.map { " " + Self.key(Self.components(of: $0.path)) } ?? "")
                if reached.contains(placeKey) { return }
                // Out of time before anything could be asked (a nil listing below): nothing was learned, so
                // nothing is recorded (a root known to be granted stays granted), and the tool is told to retry.
                let outOfTime = FolderAccessError(reason: .pending, root: place.root, path: reported)
                let state: FolderAccessState
                if let folder = place.folder {
                    guard let outcome = await list(folder, readingLink: true, until: deadline) else { throw outOfTime }
                    if let target = outcome.link {
                        let base = target.hasPrefix("/") ? target : folder.deletingLastPathComponent().path + "/" + target
                        path = ([base] + place.rest).joined(separator: "/")
                        continue
                    }
                    state = outcome.state
                    record(state, folder: folder.lastPathComponent, in: place.root)
                } else if place.root.guardsEachFolder, let location = locations[place.root] {
                    // The root itself: its own listing decides.
                    guard let listing = await list(location, until: deadline) else { throw outOfTime }
                    state = listing.state
                    recordListing(state, ofRoot: place.root)
                } else {
                    guard let access = await probeAccess(place.root, until: deadline) else { throw outOfTime }
                    state = access.state
                }
                switch state {
                case .granted, .absent:
                    reached.insert(placeKey)
                    return
                case .denied: throw FolderAccessError(reason: .denied, root: place.root, path: reported)
                case .notDetermined: throw FolderAccessError(reason: .pending, root: place.root, path: reported)
                }
            }
            // The links loop: the tool's own open fails at once with ELOOP.
        }

        func currentAccess(timeout: Duration) async -> [ProtectedRoot: RootAccess] {
            let deadline = ContinuousClock.now + timeout
            let roots = existingRoots
            var access = lastKnownAccess.filter { roots.contains($0.key) }
            let unchecked = roots.filter { access[$0] == nil }
            await withTaskGroup(of: (ProtectedRoot, RootAccess).self) { group in
                for root in unchecked {
                    group.addTask { (root, await self.report(root, until: deadline)) }
                }
                for await (root, found) in group { access[root] = found }
            }
            return access
        }

        var guardedFolders: GuardedFolders {
            let keys = rootKeys()
            return GuardedFolders(roots: Set(keys.map(\.key)),
                                  foldersGuardedOneByOne: Set(keys.filter { $0.root.guardsEachFolder }.map(\.key)))
        }

        /// Folds what `ensureReachable` found for one folder directly inside a root guarded
        /// folder by folder into that root's last known access. A refusal or a prompt still
        /// waiting is recorded — the root is then denied or waiting, whatever its other folders
        /// say — and a folder reached clears its own earlier refusal or wait. A folder reached
        /// before anything is known about the root says nothing about the rest, so it leaves
        /// the root unchecked.
        private func record(_ state: FolderAccessState, folder name: String, in root: ProtectedRoot) {
            let previous = lastKnownAccess[root]
            let others = { (names: [String]) in names.filter { $0.lowercased() != name.lowercased() } }
            var denied = others(previous?.deniedFolders ?? [])
            var pending = others(previous?.pendingFolders ?? [])
            switch state {
            case .denied: denied.append(name)
            case .notDetermined: pending.append(name)
            case .granted: guard previous != nil else { return }
            case .absent: return
            }
            let aggregate: FolderAccessState = !denied.isEmpty ? .denied : !pending.isEmpty ? .notDetermined : .granted
            lastKnownAccess[root] = RootAccess(state: aggregate, deniedFolders: denied.sorted(), pendingFolders: pending.sorted())
        }

        /// Records a root guarded folder by folder that couldn't be listed at all. A listing
        /// that worked says nothing about the folders inside, so it leaves what's known alone.
        private func recordListing(_ state: FolderAccessState, ofRoot root: ProtectedRoot) {
            guard state == .denied || state == .notDetermined else { return }
            let previous = lastKnownAccess[root]
            lastKnownAccess[root] = RootAccess(state: state, deniedFolders: previous?.deniedFolders ?? [],
                                               pendingFolders: previous?.pendingFolders ?? [])
        }

        /// A probe's result, for whoever asked: what's already known about `root` when the probe ran out of time
        /// before it could ask anything.
        private func report(_ root: ProtectedRoot, until deadline: ContinuousClock.Instant) async -> RootAccess {
            let started = ContinuousClock.now
            let access = await probeAccess(root, until: deadline) ?? lastKnownAccess[root] ?? RootAccess(state: .notDetermined)
            DocumentLog.probed(root, access, startedAt: started)
            return access
        }

        /// Probes `root` and records what it found. Nil, recording nothing, when `deadline` passed before the root
        /// itself could be listed: nothing was asked, so nothing is known.
        private func probeAccess(_ root: ProtectedRoot, until deadline: ContinuousClock.Instant) async -> RootAccess? {
            guard let location = url(of: root) else { return remember(RootAccess(state: .absent), for: root) }
            guard let listing = await list(location, until: deadline) else { return nil }
            guard root.guardsEachFolder, listing.state == .granted else { return remember(RootAccess(state: listing.state), for: root) }
            // One folder at a time. A refusal comes back at once, so probing carries on past
            // it: one denied provider or volume mustn't keep the owner from being asked about
            // the rest. It stops at the first still waiting, so at most one listing per root
            // is left blocked on a prompt.
            var reachedAny = false
            var denied: [String] = []
            var pending: [String] = []
            var asked: [(name: String, state: FolderAccessState)] = []
            folders: for name in listing.folders.sorted() {
                guard let folder = await list(location.appendingPathComponent(name, isDirectory: true), readingLink: true, until: deadline) else {
                    // Out of time before this folder could be asked about: only the folders asked about are news.
                    // They're folded into what was known, as a tool's own checks are; the rest keep theirs.
                    for answer in asked { record(answer.state, folder: answer.name, in: root) }
                    return lastKnownAccess[root] ?? RootAccess(state: denied.isEmpty ? .notDetermined : .denied, deniedFolders: denied)
                }
                // A link leads somewhere else (the startup disk's /Volumes/Macintosh HD → /),
                // not to a folder of this root.
                guard folder.link == nil else { continue }
                asked.append((name, folder.state))
                switch folder.state {
                case .granted: reachedAny = true
                case .denied: denied.append(name)
                case .notDetermined:
                    pending.append(name)
                    break folders
                case .absent: continue
                }
            }
            let state: FolderAccessState = if !denied.isEmpty {
                .denied
            } else if !pending.isEmpty {
                .notDetermined
            } else {
                reachedAny ? .granted : .absent
            }
            return remember(RootAccess(state: state, deniedFolders: denied, pendingFolders: pending), for: root)
        }

        /// Records a whole probe's result as `root`'s last known access, replacing what was known.
        private func remember(_ access: RootAccess, for root: ProtectedRoot) -> RootAccess {
            lastKnownAccess[root] = access
            return access
        }

        // MARK: Listing

        fileprivate nonisolated struct Outcome: Sendable {
            let state: FolderAccessState
            let folders: [String]
            /// Where the folder leads when it's a symlink; it isn't listed then.
            var link: String?

            /// A listing that hadn't finished by its caller's deadline.
            static let timedOut = Outcome(state: .notDetermined, folders: [])
        }

        /// Lists `directory` on a thread of its own — or joins the listing already
        /// outstanding for it — and waits until `deadline` at most: `.notDetermined` if it
        /// hasn't finished by then. With `readingLink`, that thread first reads `directory` as
        /// a symlink and reports where a link leads instead of listing it.
        ///
        /// Nil once `deadline` has passed: no listing starts (nobody would wait for it, and one
        /// held up by a prompt would leave its thread blocked for good) and none is joined, so
        /// nothing was asked and callers record nothing.
        private func list(_ directory: URL, readingLink: Bool = false, until deadline: ContinuousClock.Instant) async -> Outcome? {
            guard deadline > .now else { return nil }
            // Keyed without touching the disk, and ignoring case as APFS does, so every spelling
            // of a folder shares its one listing.
            let key = (readingLink ? "link " : "list ") + Self.key(Self.components(of: directory.path))
            if let listing = outstanding[key] {
                return await listing.wait(until: deadline) ?? .timedOut
            }
            let listing = Listing()
            outstanding[key] = listing
            let lister = lister
            let linkReader = linkReader
            let thread = Thread {
                let outcome: Outcome
                if readingLink, let target = linkReader(directory) {
                    outcome = Outcome(state: .granted, folders: [], link: target)
                } else {
                    do {
                        outcome = Outcome(state: .granted, folders: try lister(directory))
                    } catch {
                        outcome = Outcome(state: FolderAccess.state(for: error), folders: [])
                    }
                }
                Task { @MainActor in
                    if self.outstanding[key] === listing { self.outstanding[key] = nil }
                    listing.finish(outcome)
                }
            }
            thread.name = "Compositor folder access probe"
            // Someone is waiting on it (a tool call, a click in Settings): background work mustn't starve it.
            thread.qualityOfService = .userInitiated
            thread.start()
            return await listing.wait(until: deadline) ?? .timedOut
        }

        /// The names of the visible folders directly inside `directory`, from the directory
        /// entries alone (nothing inside them is touched, and symlinks are skipped).
        nonisolated static func listFolders(in directory: URL) throws -> [String] {
            guard let stream = opendir(directory.path) else { throw Self.currentPOSIXError() }
            defer { closedir(stream) }
            var names: [String] = []
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 { throw Self.currentPOSIXError() }
                    return names
                }
                guard entry.pointee.d_type == DT_DIR else { continue }
                let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                    String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
                }
                if !name.hasPrefix(".") { names.append(name) }
            }
        }

        nonisolated private static func currentPOSIXError() -> POSIXError {
            POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        /// Where the item at `url` leads when it's a symlink; nil when it isn't one or can't
        /// be read.
        nonisolated static func symlinkTarget(of url: URL) -> String? {
            try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        }

        // MARK: Where a path is

        /// Where a path is, as far as can be told without looking inside a protected root.
        private struct Place {
            let root: ProtectedRoot
            /// For a root that guards each folder inside it separately, the folder directly
            /// inside it the path goes through, which decides access; nil when the root is
            /// guarded as a whole or the path is the root itself.
            let folder: URL?
            /// The path's components after `folder`.
            let rest: [String]
        }

        /// The protected root `path` is under and, for a root that guards each folder inside
        /// it separately, which of those folders decides access.
        ///
        /// Symlinks are resolved component by component, and folder names compared
        /// ignoring case as APFS does. Resolution stops as soon as it reaches a root:
        /// nothing inside a protected root is ever looked at from here, since that alone
        /// could wait on a prompt — not even `folder`, which could be a link (read on a
        /// probe thread by `ensureReachable`).
        private func place(of path: String) -> Place? {
            let roots = rootKeys()
            var found: ProtectedRoot?
            let walk = Self.resolveSymlinks(in: path) { prefix in
                let key = Self.key(prefix)
                found = roots.first { $0.key == key }?.root
                return found != nil
            }
            guard let walk, let root = found, let location = locations[root] else { return nil }
            guard root.guardsEachFolder, let name = walk.rest.first else { return Place(root: root, folder: nil, rest: []) }
            return Place(root: root, folder: location.appendingPathComponent(name, isDirectory: true), rest: Array(walk.rest.dropFirst()))
        }

        /// Each root's path as a comparison key: spelled as given, with symlinks in its
        /// parent folders resolved (the root folder itself is never looked at), and that
        /// resolved path on the Data volume, which firmlinks join into / — so
        /// /System/Volumes/Data/Users/… is the same folder as /Users/….
        private func rootKeys() -> [(key: String, root: ProtectedRoot)] {
            ProtectedRoot.allCases.flatMap { root -> [(key: String, root: ProtectedRoot)] in
                guard let location = locations[root]?.standardizedFileURL else { return [] }
                var keys = [Self.key(Self.components(of: location.path))]
                if let parent = Self.resolveSymlinks(in: location.deletingLastPathComponent().path, stoppingAt: { _ in false }) {
                    let resolved = parent.resolved + [location.lastPathComponent]
                    keys.append(Self.key(resolved))
                    keys.append(Self.key(Self.dataVolume + resolved))
                }
                return keys.map { (key: $0, root: root) }
            }
        }

        /// Where the Data volume is mounted: its folders are also at /, through firmlinks.
        private static let dataVolume = ["System", "Volumes", "Data"]

        /// Resolves the symlinks in `path` one component at a time, returning as soon as the
        /// resolved prefix is one `stop` accepts — before looking at it — along with the
        /// components not yet resolved. Nil when the links loop.
        private static func resolveSymlinks(in path: String, stoppingAt stop: ([String]) -> Bool) -> (resolved: [String], rest: [String])? {
            var resolved: [String] = []
            var rest = components(of: path)
            var links = 0
            while !rest.isEmpty {
                let name = rest.removeFirst()
                if name == ".." {
                    if !resolved.isEmpty { resolved.removeLast() }
                    continue
                }
                resolved.append(name)
                if stop(resolved) {
                    // Stepping straight back out (Documents/..) never reaches inside it.
                    guard rest.first == ".." else { return (resolved, rest) }
                    rest.removeFirst()
                    resolved.removeLast()
                    continue
                }
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/" + resolved.joined(separator: "/")) else {
                    continue
                }
                links += 1
                if links > maxLinks { return nil }
                resolved.removeLast()
                if target.hasPrefix("/") { resolved = [] }
                rest = components(of: target) + rest
            }
            return (resolved, [])
        }

        fileprivate nonisolated static func components(of path: String) -> [String] {
            path.split(separator: "/").map(String.init).filter { $0 != "." }
        }

        /// `url`'s absolute path as `URL.standardizedFileURL` spells it — without "." and empty components, each
        /// ".." taking back the component before it — worked out from the spelling alone, never the disk.
        nonisolated static func reportedPath(of url: URL) -> String {
            var kept: [String] = []
            for component in components(of: url.absoluteURL.path) {
                if component == ".." { _ = kept.popLast() } else { kept.append(component) }
            }
            return "/" + kept.joined(separator: "/")
        }

        fileprivate nonisolated static func key(_ components: [String]) -> String {
            "/" + components.joined(separator: "/").lowercased()
        }
    }

    /// The folders a walk through the file system has to check with `ensureReachable` before
    /// reading anything inside them: each protected root, and each folder directly inside a
    /// root macOS guards folder by folder (a volume, a cloud storage provider, an app's iCloud
    /// folder). Everything else inside a root shares the root's access, so a walk that got
    /// into a root reads on without asking again.
    nonisolated struct GuardedFolders: Sendable {
        /// Each root's comparison keys (see `Checker.rootKeys`).
        fileprivate let roots: Set<String>
        /// The keys of the roots guarded folder by folder.
        fileprivate let foldersGuardedOneByOne: Set<String>

        /// Whether the folder at `path` — a real path, with no symlinks in it — must be checked
        /// before anything inside it is read. Compared ignoring case, as APFS does.
        func contains(_ path: String) -> Bool {
            let components = Checker.components(of: path)
            if roots.contains(Checker.key(components)) { return true }
            return !components.isEmpty && foldersGuardedOneByOne.contains(Checker.key(Array(components.dropLast())))
        }
    }

    /// One listing on its own thread, and the callers waiting for it.
    private final class Listing {
        private var outcome: Checker.Outcome?
        private var waiters: [Int: (continuation: CheckedContinuation<Checker.Outcome?, Never>, timer: Task<Void, Never>)] = [:]
        private var nextWaiter = 0

        func finish(_ outcome: Checker.Outcome) {
            self.outcome = outcome
            let waiting = waiters.values
            waiters.removeAll()
            for waiter in waiting {
                waiter.timer.cancel()
                waiter.continuation.resume(returning: outcome)
            }
        }

        /// The outcome, or nil if it hasn't arrived by `deadline`.
        func wait(until deadline: ContinuousClock.Instant) async -> Checker.Outcome? {
            if let outcome { return outcome }
            guard deadline > .now else { return nil }
            let id = nextWaiter
            nextWaiter += 1
            return await withCheckedContinuation { continuation in
                let timer = Task {
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    guard !Task.isCancelled else { return }
                    waiters.removeValue(forKey: id)?.continuation.resume(returning: nil)
                }
                waiters[id] = (continuation, timer)
            }
        }
    }
}
