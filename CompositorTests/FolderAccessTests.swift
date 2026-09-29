import Foundation
import Testing
@testable import Compositor

/// Folder access: finding which macOS-protected root a path is under, probing a root
/// without ever blocking the caller past a timeout, and turning what a probe finds into the
/// errors tools report.
///
/// Every test builds a fake home folder in the temporary directory and hands the checker
/// those roots and a fake lister. Nothing here touches the real ~/Documents, ~/Desktop,
/// ~/Downloads, iCloud Drive, cloud storage or /Volumes: from the test host, reading one
/// could wait forever on a consent prompt.
///
/// Probes that should finish get `plenty` of time: deadlines are wall-clock, and other suites
/// running in parallel can hold the main actor for most of a minute. Timeout tests hold
/// their listing until the test ends, so getting any answer back proves the timeout path;
/// they also bound how long it took, less what the machine held the test up (`timed`).
/// Fake homes are removed when each test ends.
@MainActor @Suite(.timeLimit(.minutes(5)))
struct FolderAccessTests {
    private static let plenty: Duration = .seconds(120)

    private func checker(_ home: FakeHome, _ lister: FakeLister, links: LinkReader = LinkReader()) -> FolderAccess.Checker {
        FolderAccess.Checker(locations: home.locations, lister: { try lister.list($0) }, linkReader: { links.read($0) })
    }

    /// `path` with every symlink resolved (`/var/…` → `/private/var/…`), as the kernel sees it.
    private func realPath(_ url: URL) throws -> String {
        let resolved = try #require(realpath(url.path, nil))
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Roots

    @Test func rootsLiveWhereMacOSPutsThem() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        #expect(ProtectedRoot.documents.location(home: home).path == "/Users/someone/Documents")
        #expect(ProtectedRoot.desktop.location(home: home).path == "/Users/someone/Desktop")
        #expect(ProtectedRoot.downloads.location(home: home).path == "/Users/someone/Downloads")
        #expect(ProtectedRoot.iCloudDrive.location(home: home).path == "/Users/someone/Library/Mobile Documents")
        #expect(ProtectedRoot.cloudStorage.location(home: home).path == "/Users/someone/Library/CloudStorage")
        #expect(ProtectedRoot.removableVolumes.location(home: home).path == "/Volumes")

        // The names agents see in errors and reports.
        #expect(ProtectedRoot.allCases.map(\.rawValue)
                == ["documents", "desktop", "downloads", "icloud_drive", "cloud_storage", "removable_volumes"])
        #expect([FolderAccessState.granted, .denied, .notDetermined, .absent].map(\.rawValue)
                == ["granted", "denied", "not_determined", "absent"])
    }

    @Test(arguments: ProtectedRoot.allCases)
    func rootContainingFindsEachRoot(_ root: ProtectedRoot) {
        let home = FakeHome()
        let checker = checker(home, FakeLister())
        let location = home[root]

        #expect(checker.root(containing: location) == root)
        #expect(checker.root(containing: location.appendingPathComponent("Client/Final/hero.psd")) == root)
        // APFS ignores case, so a differently cased path still reaches the root.
        let recased = location.deletingLastPathComponent().appendingPathComponent(location.lastPathComponent.lowercased())
        #expect(checker.root(containing: recased.appendingPathComponent("hero.psd")) == root)
        // Whole folder names, not string prefixes.
        #expect(checker.root(containing: URL(fileURLWithPath: location.path + " old/hero.psd")) == nil)
    }

    @Test func pathsOutsideEveryRootHaveNone() {
        let home = FakeHome()
        let checker = checker(home, FakeLister())
        #expect(checker.root(containing: home.url.appendingPathComponent("Pictures/hero.png")) == nil)
        #expect(checker.root(containing: home.url) == nil)
        #expect(checker.root(containing: URL(string: "https://example.com/Documents/hero.png")!) == nil)
    }

    @Test func rootContainingFollowsSymlinksOutsideTheRoots() throws {
        let home = FakeHome()
        let checker = checker(home, FakeLister())
        let fileManager = FileManager.default
        let links = home.url.appendingPathComponent("Links", isDirectory: true)
        try fileManager.createDirectory(at: links, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: links.appendingPathComponent("docs").path,
                                           withDestinationPath: home[.documents].path)
        try fileManager.createSymbolicLink(atPath: links.appendingPathComponent("drive").path,
                                           withDestinationPath: "../Library/CloudStorage/GoogleDrive-a")
        try fileManager.createSymbolicLink(atPath: links.appendingPathComponent("chain").path, withDestinationPath: "docs")
        try fileManager.createSymbolicLink(atPath: links.appendingPathComponent("loop").path, withDestinationPath: "loop")

        #expect(checker.root(containing: links.appendingPathComponent("docs/hero.psd")) == .documents)
        #expect(checker.root(containing: links.appendingPathComponent("drive/My Drive/hero.psd")) == .cloudStorage)
        #expect(checker.root(containing: links.appendingPathComponent("chain/Client/hero.psd")) == .documents)
        #expect(checker.root(containing: links.appendingPathComponent("loop/hero.psd")) == nil)

        // The temporary folder is itself behind the /var → /private/var link: the same root
        // spelled the other way round is still found.
        let desktop = home[.desktop].path
        let otherSpelling = desktop.hasPrefix("/private/var/") ? String(desktop.dropFirst("/private".count)) : "/private" + desktop
        #expect(checker.root(containing: URL(fileURLWithPath: otherSpelling + "/hero.psd")) == .desktop)
    }

    @Test func linksInsideARootAreNeverFollowed() throws {
        // Looking inside a protected root is exactly what could wait on a prompt, so the
        // root decides even when a link inside it points somewhere unprotected.
        let home = FakeHome()
        let checker = checker(home, FakeLister())
        let elsewhere = home.url.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home[.documents].appendingPathComponent("out").path,
                                                   withDestinationPath: elsewhere.path)
        #expect(checker.root(containing: home[.documents].appendingPathComponent("out/hero.psd")) == .documents)

        // Stepping straight back out of a root never reaches inside it.
        #expect(checker.root(containing: home[.documents].appendingPathComponent("../Pictures/hero.png")) == nil)
        #expect(checker.root(containing: home[.removableVolumes].appendingPathComponent("../Downloads/hero.png")) == .downloads)
    }

    @Test func theDataVolumeSpellingReachesTheSameRoots() async throws {
        // Firmlinks join the Data volume's folders into /, so /System/Volumes/Data/Users/…
        // is the same folder as /Users/…: it must reach the same root, and the walk must stop
        // there instead of reading on into the protected folder.
        let home = FakeHome()
        let lister = FakeLister(["Documents": .failure(POSIXError(.EPERM))])
        let checker = checker(home, lister)
        let data = "/System/Volumes/Data"

        let file = URL(fileURLWithPath: data + (try realPath(home[.documents])) + "/Client/hero.psd")
        #expect(checker.root(containing: file) == .documents)
        #expect(checker.root(containing: URL(fileURLWithPath: data + (try realPath(home[.cloudStorage])) + "/GoogleDrive-a/hero.psd"))
                == .cloudStorage)
        #expect(checker.root(containing: URL(fileURLWithPath: data + (try realPath(home[.removableVolumes])) + "/USB/hero.psd"))
                == .removableVolumes)
        #expect(checker.root(containing: URL(fileURLWithPath: data + (try realPath(home.url)) + "/Pictures/hero.png")) == nil)

        let error = await #expect(throws: FolderAccessError.self) {
            try await checker.ensureReachable(file, timeout: Self.plenty)
        }
        #expect(error?.code == "folder_access_denied" && error?.root == .documents && error?.path == file.path)
        #expect(lister.listed == ["Documents"])
    }

    @Test func aLinkInsideVolumesIsCheckedWhereItLeads() async throws {
        // /Volumes/Macintosh HD → / is the startup disk: a file reached through it is under
        // whatever root the rest of its path is under, so listing the "volume" (that is, /)
        // would pass and the real open would then wait on the Documents prompt.
        let home = FakeHome()
        let lister = FakeLister(["Documents": .failure(POSIXError(.EPERM)),
                                 "GoogleDrive-a": .failure(POSIXError(.EPERM))])
        let links = LinkReader()
        let checker = checker(home, lister, links: links)
        let volumes = home[.removableVolumes]
        try FileManager.default.createSymbolicLink(atPath: volumes.appendingPathComponent("Startup").path, withDestinationPath: "/")
        try FileManager.default.createSymbolicLink(atPath: volumes.appendingPathComponent("Drive").path,
                                                   withDestinationPath: "../Library/CloudStorage/GoogleDrive-a")

        let file = URL(fileURLWithPath: volumes.path + "/Startup" + home[.documents].path + "/Client/hero.psd")
        // Reading that link could wait on a volume (it might be a mount point), so the
        // synchronous lookup leaves it to `ensureReachable`, which reads it on a probe thread.
        #expect(checker.root(containing: file) == .removableVolumes)
        let error = await #expect(throws: FolderAccessError.self) {
            try await checker.ensureReachable(file, timeout: Self.plenty)
        }
        #expect(error?.code == "folder_access_denied" && error?.root == .documents && error?.path == file.path)
        // Only Documents was listed: never the startup disk's root the link leads to.
        #expect(lister.listed == ["Documents"])
        #expect(links.reads == [LinkReader.Read(name: "Startup", onMainThread: false)])

        // The link then the Data volume spelling, and a relative link into cloud storage.
        let throughData = URL(fileURLWithPath: volumes.path + "/Startup/System/Volumes/Data" + (try realPath(home[.documents])) + "/hero.psd")
        await #expect(throws: FolderAccessError.self) { try await checker.ensureReachable(throughData, timeout: Self.plenty) }
        let driveFile = volumes.appendingPathComponent("Drive/My Drive/hero.psd")
        let driveError = await #expect(throws: FolderAccessError.self) {
            try await checker.ensureReachable(driveFile, timeout: Self.plenty)
        }
        #expect(driveError?.root == .cloudStorage)
        #expect(lister.listed == ["Documents", "Documents", "GoogleDrive-a"])
        // A link to somewhere unprotected needs nothing.
        try FileManager.default.createSymbolicLink(atPath: volumes.appendingPathComponent("Home").path, withDestinationPath: home.url.path)
        try await checker.ensureReachable(volumes.appendingPathComponent("Home/Pictures/hero.png"), timeout: Self.plenty)
        #expect(lister.listed == ["Documents", "Documents", "GoogleDrive-a"])

        // A probe of the volumes skips the link: it's the startup disk, not a volume of its own.
        let mounted = FakeLister(["Volumes": .folders(["Startup"])])
        #expect(await self.checker(home, mounted).probe(.removableVolumes, timeout: Self.plenty) == .absent)
        #expect(mounted.listed == ["Volumes"])
    }

    @Test func aVolumeThatDoesNotAnswerIsPendingAndAskedOnce() async throws {
        // Reading /Volumes/NAS itself can wait on a network volume that stopped answering.
        let home = FakeHome()
        let lister = FakeLister()
        let links = LinkReader(hanging: "NAS")
        defer { links.release() }
        let checker = checker(home, lister, links: links)
        let file = home[.removableVolumes].appendingPathComponent("NAS/hero.psd")

        for _ in 0..<2 {
            let error = await #expect(throws: FolderAccessError.self) {
                try await checker.ensureReachable(file, timeout: .milliseconds(100))
            }
            #expect(error?.code == "folder_access_pending" && error?.root == .removableVolumes)
        }
        #expect(lister.listed.isEmpty)
        // The volume answers again. The next call joins the read still outstanding (it's
        // looked up before this test lets the main actor go), so every call shared one.
        links.release()
        try await checker.ensureReachable(file, timeout: Self.plenty)
        #expect(links.reads.map(\.name) == ["NAS"])
        #expect(lister.listed == ["NAS"])
    }

    // MARK: - Probing

    @Test func aListingThatSucceedsIsGranted() async {
        let home = FakeHome()
        let lister = FakeLister()
        let checker = checker(home, lister)
        #expect(await checker.probe(.documents, timeout: Self.plenty) == .granted)
        #expect(lister.listed == ["Documents"])
    }

    @Test(arguments: [EPERM, EACCES])
    func aListingMacOSRefusesIsDenied(_ code: Int32) async throws {
        let home = FakeHome()
        let refusal = POSIXError(try #require(POSIXErrorCode(rawValue: code)))
        let checker = checker(home, FakeLister(["Desktop": .failure(refusal)]))
        #expect(await checker.probe(.desktop, timeout: Self.plenty) == .denied)
    }

    @Test func aListingThatNeverReturnsIsNotDeterminedWithinTheTimeout() async {
        let home = FakeHome()
        let lister = FakeLister(["Downloads": .hang])
        defer { lister.release() }
        let checker = checker(home, lister)

        let (state, elapsed, stall) = await timed { await checker.probe(.downloads, timeout: .milliseconds(200)) }

        #expect(state == .notDetermined)
        #expect(elapsed >= .milliseconds(200))
        #expect(elapsed < .seconds(1) + stall, "took \(elapsed) with the main actor held \(stall)")
    }

    @Test func anOutstandingListingIsSharedNeverRepeated() async {
        // A listing held up by a prompt leaves its thread blocked in the kernel, so later
        // probes of the same root wait on that listing instead of blocking another thread.
        let home = FakeHome()
        let lister = FakeLister(["Documents": .hang])
        let checker = checker(home, lister)

        #expect(await checker.probe(.documents, timeout: .milliseconds(100)) == .notDetermined)
        #expect(await checker.probe(.documents, timeout: .milliseconds(100)) == .notDetermined)
        async let first = checker.probe(.documents, timeout: .milliseconds(100))
        async let second = checker.probe(.documents, timeout: .milliseconds(100))
        #expect(await [first, second] == [.notDetermined, .notDetermined])

        // The owner answers "Allow": the outstanding listing finishes and the next probe,
        // which joins it (it's looked up before this test lets the main actor go), sees it.
        lister.release()
        #expect(await checker.probe(.documents, timeout: Self.plenty) == .granted)
        #expect(lister.listed == ["Documents"])
    }

    @Test func aMissingRootIsAbsentWithoutBeingListed() async throws {
        let home = FakeHome()
        let lister = FakeLister()
        let checker = checker(home, lister)
        try FileManager.default.removeItem(at: home[.iCloudDrive])

        #expect(await checker.probe(.iCloudDrive, timeout: Self.plenty) == .absent)
        #expect(lister.listed.isEmpty)
        #expect(checker.existingRoots == [.documents, .desktop, .downloads, .cloudStorage, .removableVolumes])
    }

    @Test func cloudStorageIsCheckedPerProvider() async throws {
        // macOS asks about each File Provider on its own ("files managed by Google Drive"),
        // so the root's state is its providers', and a file needs only its own provider.
        let home = FakeHome()
        let lister = FakeLister(["CloudStorage": .folders(["GoogleDrive-a", "Dropbox"]),
                                 "Dropbox": .failure(POSIXError(.EPERM))])
        let checker = checker(home, lister)

        #expect(await checker.probe(.cloudStorage, timeout: Self.plenty) == .denied)
        #expect(lister.listed == ["CloudStorage", "Dropbox", "GoogleDrive-a"])

        let driveFile = home[.cloudStorage].appendingPathComponent("GoogleDrive-a/My Drive/hero.psd")
        try await checker.ensureReachable(driveFile, timeout: Self.plenty)
        #expect(lister.listed == ["CloudStorage", "Dropbox", "GoogleDrive-a", "GoogleDrive-a"])

        let dropboxFile = home[.cloudStorage].appendingPathComponent("Dropbox/hero.psd")
        let error = await #expect(throws: FolderAccessError.self) {
            try await checker.ensureReachable(dropboxFile, timeout: Self.plenty)
        }
        #expect(error?.code == "folder_access_denied" && error?.root == .cloudStorage)
    }

    @Test func aDeniedProviderDoesNotKeepTheOthersFromBeingAsked() async {
        // Dropbox sorts first and was refused. A refusal comes back at once, so probing goes
        // on and asks about Google Drive, not asked yet: "Request access" raises its prompt
        // while the owner is at the Mac, and the result names which provider is denied.
        let home = FakeHome()
        let lister = FakeLister(["CloudStorage": .folders(["GoogleDrive-a", "Dropbox", "OneDrive"]),
                                 "Dropbox": .failure(POSIXError(.EPERM))])
        let checker = checker(home, lister)

        let access = await checker.probeAccess(.cloudStorage, timeout: Self.plenty)
        #expect(access == RootAccess(state: .denied, deniedFolders: ["Dropbox"]))
        #expect(lister.listed == ["CloudStorage", "Dropbox", "GoogleDrive-a", "OneDrive"])
        #expect(checker.lastKnownAccess[.cloudStorage] == access)
        #expect(checker.lastKnownStates[.cloudStorage] == .denied)

        // Every volume refused: each is named.
        let refused = FakeLister(["Volumes": .folders(["USB", "NAS"]),
                                  "USB": .failure(POSIXError(.EPERM)), "NAS": .failure(POSIXError(.EACCES))])
        #expect(await self.checker(home, refused).probeAccess(.removableVolumes, timeout: Self.plenty)
                == RootAccess(state: .denied, deniedFolders: ["NAS", "USB"]))
    }

    @Test func probingStopsAtTheFirstProviderStillWaitingAndNamesIt() async throws {
        // Probing goes past a refusal but stops at a prompt that's still up, so at most one
        // listing per root is ever left blocked; the result names both.
        let home = FakeHome()
        let lister = FakeLister(["CloudStorage": .folders(["GoogleDrive-a", "Dropbox", "OneDrive"]),
                                 "Dropbox": .failure(POSIXError(.EPERM)),
                                 "GoogleDrive-a": .hang])
        defer { lister.release() }
        let checker = checker(home, lister)

        // The deadline is wall-clock and shared by every listing, and other suites can hold the
        // main actor past a short one before the root's own listing is back. Asking again
        // joins Google Drive's held listing instead of starting another, so retry until the
        // listings ahead of it made it in time.
        var access = RootAccess(state: .absent)
        for _ in 0..<10 where access.pendingFolders != ["GoogleDrive-a"] {
            access = await checker.probeAccess(.cloudStorage, timeout: .seconds(1))
        }
        #expect(access == RootAccess(state: .denied, deniedFolders: ["Dropbox"], pendingFolders: ["GoogleDrive-a"]))
        #expect(!lister.listed.contains("OneDrive"))
        // The owner answers "Allow". A file there joins the listing still outstanding (it's
        // looked up before this test lets the main actor go), so every probe above shared one.
        lister.release()
        try await checker.ensureReachable(home[.cloudStorage].appendingPathComponent("GoogleDrive-a/hero.psd"), timeout: Self.plenty)
        #expect(lister.listed.filter { $0 == "GoogleDrive-a" }.count == 1)

        // Nothing refused: the root is waiting on that prompt.
        let waiting = FakeLister(["CloudStorage": .folders(["GoogleDrive-a", "OneDrive"]), "GoogleDrive-a": .hang])
        defer { waiting.release() }
        let other = self.checker(home, waiting)
        var alone = RootAccess(state: .absent)
        for _ in 0..<10 where alone.pendingFolders != ["GoogleDrive-a"] {
            alone = await other.probeAccess(.cloudStorage, timeout: .seconds(1))
        }
        #expect(alone == RootAccess(state: .notDetermined, pendingFolders: ["GoogleDrive-a"]))
    }

    @Test func volumesAreCheckedPerVolume() async {
        let home = FakeHome()
        let mounted = FakeLister(["Volumes": .folders(["USB", "NAS"])])
        #expect(await checker(home, mounted).probe(.removableVolumes, timeout: Self.plenty) == .granted)
        #expect(mounted.listed == ["Volumes", "NAS", "USB"])

        // Nothing mounted besides the startup disk: nothing to grant.
        let nothingMounted = FakeLister(["Volumes": .folders([])])
        #expect(await checker(home, nothingMounted).probe(.removableVolumes, timeout: Self.plenty) == .absent)
    }

    @Test func probesRememberEachRootsLastKnownState() async throws {
        let home = FakeHome()
        let checker = checker(home, FakeLister(["Desktop": .failure(POSIXError(.EPERM))]))
        try FileManager.default.removeItem(at: home[.downloads])
        #expect(checker.lastKnownStates.isEmpty)

        _ = await checker.probe(.documents, timeout: Self.plenty)
        _ = await checker.probe(.desktop, timeout: Self.plenty)
        _ = await checker.probe(.downloads, timeout: Self.plenty)
        #expect(checker.lastKnownStates == [.documents: .granted, .desktop: .denied, .downloads: .absent])
    }

    // MARK: - Failing fast

    @Test func ensureReachableReportsADeniedRoot() async {
        let home = FakeHome()
        let checker = checker(home, FakeLister(["Documents": .failure(POSIXError(.EPERM))]))
        let file = home[.documents].appendingPathComponent("Client/hero.psd")

        let error = await #expect(throws: FolderAccessError.self) {
            try await checker.ensureReachable(file, timeout: Self.plenty)
        }
        #expect(error?.reason == .denied && error?.root == .documents && error?.path == file.path)
        #expect(error?.code == "folder_access_denied")
        #expect(error?.hint == "Grant Compositor access in System Settings > Privacy & Security > Files and Folders (or Full Disk Access), or copy the file to the Agent folder")
        #expect(error?.errorDescription?.contains(file.path) == true)
    }

    @Test func ensureReachableReportsAPendingPromptWithinTheTimeout() async {
        let home = FakeHome()
        let lister = FakeLister(["Desktop": .hang])
        defer { lister.release() }
        let checker = checker(home, lister)
        let file = home[.desktop].appendingPathComponent("hero.psd")

        let (error, elapsed, stall) = await timed {
            await #expect(throws: FolderAccessError.self) {
                try await checker.ensureReachable(file, timeout: .milliseconds(200))
            }
        }

        #expect(elapsed >= .milliseconds(200))
        #expect(elapsed < .seconds(1) + stall, "took \(elapsed) with the main actor held \(stall)")
        #expect(error?.reason == .pending && error?.root == .desktop)
        #expect(error?.code == "folder_access_pending")
        #expect(error?.hint == "A macOS permission prompt is waiting on this Mac; approve it and retry.")
    }

    @Test func ensureReachablePassesWhenNothingStandsInTheWay() async throws {
        let home = FakeHome()
        let lister = FakeLister()
        let checker = checker(home, lister)

        try await checker.ensureReachable(home[.downloads].appendingPathComponent("hero.png"), timeout: Self.plenty)
        #expect(lister.listed == ["Downloads"])

        // Not under any protected root: nothing to probe.
        try await checker.ensureReachable(home.url.appendingPathComponent("Pictures/hero.png"), timeout: Self.plenty)
        // A root this Mac doesn't have: the tool's own read reports the missing file.
        try FileManager.default.removeItem(at: home[.desktop])
        try await checker.ensureReachable(home[.desktop].appendingPathComponent("hero.png"), timeout: Self.plenty)
        #expect(lister.listed == ["Downloads"])
    }

    @Test func ensureReachableReportsAStandardizedPath() async {
        // Spelled with "." and doubled slashes, or relative to a folder: the error names the plain absolute path.
        let home = FakeHome()
        let checker = checker(home, FakeLister(["Documents": .failure(POSIXError(.EPERM))]))
        let plain = home[.documents].path + "/Client/hero.psd"
        for spelling in [URL(fileURLWithPath: home[.documents].path + "/./Client//hero.psd"),
                         URL(fileURLWithPath: "Client/./hero.psd", relativeTo: home[.documents]),
                         URL(fileURLWithPath: home[.documents].path + "/Drafts/../Client/hero.psd")] {
            // As a tool that went through would report it.
            #expect(spelling.standardizedFileURL.path == plain, "\(spelling)")
            let error = await #expect(throws: FolderAccessError.self) {
                try await checker.ensureReachable(spelling, timeout: Self.plenty)
            }
            #expect(error?.path == plain, "\(spelling)")
        }
    }

    @Test func ensureReachableRecordsWhatItFinds() async throws {
        // A tool's own check updates what Settings and get_app_info show, as a probe would.
        let home = FakeHome()
        let lister = FakeLister(["Documents": .failure(POSIXError(.EPERM)), "Dropbox": .failure(POSIXError(.EPERM)),
                                 "GoogleDrive-a": .hang])
        defer { lister.release() }
        let checker = checker(home, lister)

        _ = try? await checker.ensureReachable(home[.documents].appendingPathComponent("hero.psd"), timeout: Self.plenty)
        #expect(checker.lastKnownStates[.documents] == .denied)

        // One provider refused: the root is denied, naming it, though the others were never asked about.
        let dropbox = home[.cloudStorage].appendingPathComponent("Dropbox/hero.psd")
        _ = try? await checker.ensureReachable(dropbox, timeout: Self.plenty)
        #expect(checker.lastKnownAccess[.cloudStorage] == RootAccess(state: .denied, deniedFolders: ["Dropbox"]))
        // Another still waiting on its prompt is named too.
        let drive = home[.cloudStorage].appendingPathComponent("GoogleDrive-a/hero.psd")
        _ = try? await checker.ensureReachable(drive, timeout: .milliseconds(100))
        #expect(checker.lastKnownAccess[.cloudStorage]
                == RootAccess(state: .denied, deniedFolders: ["Dropbox"], pendingFolders: ["GoogleDrive-a"]))

        // The owner allows Dropbox: reaching it clears its refusal, leaving the root waiting on Google Drive.
        lister.answer("Dropbox", .folders([]))
        try await checker.ensureReachable(dropbox, timeout: Self.plenty)
        #expect(checker.lastKnownAccess[.cloudStorage] == RootAccess(state: .notDetermined, pendingFolders: ["GoogleDrive-a"]))

        // A provider reached before anything was known says nothing about the others: the root stays unchecked.
        let fresh = self.checker(home, FakeLister())
        try await fresh.ensureReachable(dropbox, timeout: Self.plenty)
        #expect(fresh.lastKnownAccess[.cloudStorage] == nil)
    }

    @Test func pendingListingsAreSharedWhateverTheCase() async throws {
        // APFS ignores case, so ".../googledrive-a" is the folder whose listing is already held up on a prompt: a
        // second spelling must join that listing, not leave another thread blocked in the kernel.
        let home = FakeHome()
        let lister = FakeLister(["GoogleDrive-a": .hang, "googledrive-a": .hang])
        let checker = checker(home, lister)
        let cloud = home[.cloudStorage]

        for name in ["GoogleDrive-a", "googledrive-a", "GOOGLEDRIVE-A"] {
            await #expect(throws: FolderAccessError.self) {
                try await checker.ensureReachable(cloud.appendingPathComponent(name + "/hero.psd"), timeout: .milliseconds(100))
            }
        }
        // The owner answers "Allow": the next call joins the held listing (it's looked up before this test lets
        // the main actor go), so every call above shared one.
        lister.release()
        try await checker.ensureReachable(cloud.appendingPathComponent("googledrive-A/hero.psd"), timeout: Self.plenty)
        #expect(lister.listed == ["GoogleDrive-a"])
    }

    @Test func noListingStartsOnceTheDeadlineHasPassed() async throws {
        // Nobody would wait for it, and a listing held up by a prompt leaves its thread blocked for good.
        let home = FakeHome()
        let lister = FakeLister()
        let checker = checker(home, lister)

        #expect(await checker.probe(.documents, timeout: .zero) == .notDetermined)
        await #expect(throws: FolderAccessError.self) {
            try await checker.ensureReachable(home[.desktop].appendingPathComponent("hero.psd"), timeout: .zero)
        }
        // Long enough for a listing thread to have started, had there been one.
        try await Task.sleep(for: .milliseconds(200))
        #expect(lister.listed.isEmpty)
    }

    @Test func aCheckWithNoTimeLeftAsksNothingAndKeepsWhatWasKnown() async throws {
        // A check out of time learns nothing, so it records nothing: a location known to be granted stays granted in
        // Settings and get_app_info instead of turning into "Waiting for approval" nobody raised.
        let home = FakeHome()
        let lister = FakeLister(["CloudStorage": .folders(["Dropbox"]), "Volumes": .folders(["USB"])])
        let checker = checker(home, lister)
        #expect(await checker.probe(.documents, timeout: Self.plenty) == .granted)
        #expect(await checker.probe(.cloudStorage, timeout: Self.plenty) == .granted)
        #expect(await checker.probe(.removableVolumes, timeout: Self.plenty) == .granted)
        let known = checker.lastKnownAccess
        let listed = lister.listed

        for url in [home[.documents].appendingPathComponent("hero.psd"),
                    home[.cloudStorage].appendingPathComponent("Dropbox/hero.psd"), // a provider
                    home[.cloudStorage], // a root guarded folder by folder, itself
                    home[.removableVolumes].appendingPathComponent("USB/hero.psd")] {
            let error = await #expect(throws: FolderAccessError.self) {
                try await checker.ensureReachable(url, timeout: .zero)
            }
            #expect(error?.reason == .pending, "\(url.path)")
        }
        // A probe out of time reports what's known (nothing, for Desktop and Downloads), and records nothing either.
        #expect(await checker.probeAccess(.documents, timeout: .zero) == known[.documents])
        #expect(await checker.probeAccess(.desktop, timeout: .zero) == RootAccess(state: .notDetermined))
        #expect(await checker.currentAccess(timeout: .zero)[.downloads] == RootAccess(state: .notDetermined))
        #expect(checker.lastKnownAccess == known)
        #expect(lister.listed == listed)
    }

    @Test func aProbeOutOfTimePartWayKeepsWhatWasKnownOfTheFoldersItDidNotReach() async throws {
        // Dropbox was refused earlier. This probe hears Drive's answer only after its deadline (the main actor was
        // held up meanwhile), so it has no time left to ask about Dropbox: Drive's answer is folded in, and Dropbox
        // stays refused rather than being reported as a prompt nobody raised.
        let home = FakeHome()
        let lister = FakeLister(["CloudStorage": .folders(["Drive", "Dropbox"]), "Dropbox": .failure(POSIXError(.EPERM))])
        let hold = MainQueueHold()
        let checker = FolderAccess.Checker(locations: home.locations, lister: { url in
            if url.lastPathComponent == "Drive" { hold.holdIfSet() }
            return try lister.list(url)
        })
        let known = RootAccess(state: .denied, deniedFolders: ["Dropbox"])

        // Deadlines are wall-clock: under load the root's own listing can miss this one (Drive is never asked), or
        // Drive's thread start so late that its answer comes after the timeout (Drive is waiting). Then try again.
        var access: RootAccess?
        for _ in 0..<5 where access == nil {
            #expect(await checker.probeAccess(.cloudStorage, timeout: Self.plenty) == known)
            let dropboxAsked = lister.listed.filter { $0 == "Dropbox" }.count
            hold.set(until: .now + .milliseconds(1_200))
            let found = await checker.probeAccess(.cloudStorage, timeout: .seconds(1))
            hold.set(until: nil)
            guard hold.takeHeld(), found.pendingFolders != ["Drive"] else { continue }
            #expect(lister.listed.filter { $0 == "Dropbox" }.count == dropboxAsked)
            access = found
        }
        #expect(access == known)
        #expect(checker.lastKnownAccess[.cloudStorage] == known)
    }

    @Test func aFileAndItsFolderInOnePlaceAreCheckedOnce() async throws {
        // Saving checks the file and the folder it goes in with one timeout: the second needs no listing of its own.
        let home = FakeHome()
        let lister = FakeLister()
        let checker = checker(home, lister)
        let file = home[.documents].appendingPathComponent("Out/poster.png")
        try await checker.ensureReachable([file, file.deletingLastPathComponent()], timeout: Self.plenty)
        #expect(lister.listed == ["Documents"])

        // Two providers are two places.
        let drive = home[.cloudStorage].appendingPathComponent("Drive/a.png")
        try await checker.ensureReachable([drive, drive.deletingLastPathComponent(),
                                           home[.cloudStorage].appendingPathComponent("Box/b.png")], timeout: Self.plenty)
        #expect(lister.listed == ["Documents", "Drive", "Box"])
    }

    @Test func currentAccessProbesOnlyRootsNotCheckedYetAndAllAtOnce() async {
        let home = FakeHome(roots: [.documents, .desktop, .downloads])
        let lister = FakeLister(["Desktop": .hang, "Downloads": .hang])
        defer { lister.release() }
        let checker = checker(home, lister)
        #expect(await checker.probe(.documents, timeout: Self.plenty) == .granted)

        // Two roots whose listings never return, probed side by side: one timeout in all, not one each.
        let (access, elapsed, stall) = await timed { await checker.currentAccess(timeout: .seconds(1)) }
        #expect(access.mapValues(\.state) == [.documents: .granted, .desktop: .notDetermined, .downloads: .notDetermined])
        #expect(elapsed < .milliseconds(1_500) + stall, "took \(elapsed) with the main actor held \(stall)")
        #expect(lister.listed.filter { $0 == "Documents" }.count == 1)
        // A listing that timed out is recorded. Under load the probe can start after its deadline, asking nothing:
        // then nothing is recorded, and the next report asks again.
        #expect(checker.lastKnownStates[.desktop] == (lister.listed.contains("Desktop") ? .notDetermined : nil))
    }

    @Test func guardedFoldersAreTheRootsAndTheFoldersInsideRootsGuardedFolderByFolder() throws {
        let home = FakeHome()
        let guarded = checker(home, FakeLister()).guardedFolders
        let documents = try realPath(home[.documents]), cloud = try realPath(home[.cloudStorage])

        #expect(guarded.contains(documents))
        #expect(guarded.contains(documents.uppercased()))
        #expect(!guarded.contains(documents + "/Client"))
        #expect(guarded.contains(cloud))
        #expect(guarded.contains(cloud + "/GoogleDrive-a"))
        #expect(!guarded.contains(cloud + "/GoogleDrive-a/My Drive"))
        #expect(guarded.contains(try realPath(home[.removableVolumes]) + "/USB"))
        #expect(!guarded.contains(try realPath(home.url)))
        #expect(!guarded.contains(try realPath(home.url) + "/Pictures"))
        // The Data volume's spelling of the same folder.
        #expect(guarded.contains("/System/Volumes/Data" + documents))
    }

    // MARK: - The real listing

    @Test func theRealListerReturnsVisibleFoldersAndItsFailuresAreClassified() throws {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent("FolderAccessTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: folder) }
        for name in ["a", "B", ".hidden", "locked"] {
            try fileManager.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: folder.appendingPathComponent("file.txt"))
        try fileManager.createSymbolicLink(atPath: folder.appendingPathComponent("link").path,
                                           withDestinationPath: folder.appendingPathComponent("a").path)
        #expect(Set(try FolderAccess.Checker.listFolders(in: folder)) == ["a", "B", "locked"])

        let missing = #expect(throws: (any Error).self) {
            try FolderAccess.Checker.listFolders(in: folder.appendingPathComponent("missing"))
        }
        #expect(missing.map(FolderAccess.state(for:)) == .absent)

        let locked = folder.appendingPathComponent("locked")
        try fileManager.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let refused = #expect(throws: (any Error).self) { try FolderAccess.Checker.listFolders(in: locked) }
        #expect(refused.map(FolderAccess.state(for:)) == .denied)

        // Foundation wraps the POSIX error; anything that isn't a refusal isn't a privacy problem.
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                              userInfo: [NSUnderlyingErrorKey: POSIXError(.EPERM)])
        #expect(FolderAccess.state(for: wrapped) == .denied)
        #expect(FolderAccess.state(for: POSIXError(.ENOTDIR)) == .absent)
        #expect(FolderAccess.state(for: POSIXError(.EIO)) == .granted)
    }
}

/// Holds the main queue, from a listing's thread, until a set time: the listing answers in time, but its caller hears
/// the answer only after that (the main queue runs its blocks in order, and the answer is queued behind the hold).
private final class MainQueueHold: @unchecked Sendable {
    private let lock = NSLock()
    private var until: ContinuousClock.Instant?
    private var held = false

    /// Makes the next `holdIfSet()` hold the main queue until `instant`; nil makes it do nothing.
    func set(until instant: ContinuousClock.Instant?) {
        lock.withLock { until = instant }
    }

    /// Whether the main queue was held since the last call.
    func takeHeld() -> Bool {
        lock.withLock {
            defer { held = false }
            return held
        }
    }

    /// Called on a listing's thread: queues a block that keeps the main queue busy until the set time, once.
    func holdIfSet() {
        let until: ContinuousClock.Instant? = lock.withLock {
            defer { self.until = nil }
            if self.until != nil { held = true }
            return self.until
        }
        guard let until else { return }
        DispatchQueue.main.async {
            while ContinuousClock.now < until { Thread.sleep(forTimeInterval: 0.005) }
        }
    }
}
