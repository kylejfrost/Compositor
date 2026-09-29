import Foundation
import Testing
@testable import Compositor

/// Every test scans its own temporary folders; the real libraries are read only by `installedLibraryIndexes`, on request.
struct ProfileLibraryTests {
    /// `root/system`, `root/user` and `root/imported` stand in for the three library folders. `imported` is left for
    /// the code under test (or `write`) to create.
    struct Sandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileLibraryTests-\(UUID().uuidString)", isDirectory: true)
        var system: URL { root.appendingPathComponent("system", isDirectory: true) }
        var user: URL { root.appendingPathComponent("user", isDirectory: true) }
        var imported: URL { root.appendingPathComponent("imported", isDirectory: true) }
        func makeLibrary() -> ProfileLibrary {
            ProfileLibrary(locations: .init(adobeSystem: system, adobeUser: user, imported: imported))
        }

        func makeLibraryFolders() throws {
            try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        }

        /// Writes `data` at a path relative to `root`, creating the folders on the way.
        @discardableResult func write(_ data: Data, _ path: String) throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    static let table = ProfileFixture.rgbTable(divisions: 5)
    static let otherTable = ProfileFixture.rgbTable(divisions: 5) { r, g, b in (r, g, b * 0.9) }

    static func uniqueUUID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") }

    static func profile(_ name: String, uuid: String = uniqueUUID(), group: String? = nil, presetType: String = "Look",
                        outputReferred: Bool = true, cameraModel: String? = nil, rgb: RGBTable = table,
                        embedTables: Bool = true, extra: String = "") -> Data {
        ProfileFixture.xmp(name: name, uuid: uuid, group: group, presetType: presetType, outputReferred: outputReferred,
                           cameraModel: cameraModel, rgb: rgb, embedTables: embedTables, extraDescriptionXML: extra)
    }

    /// An XML comment that takes a profile past the 4 MiB cap.
    static let padding = "\n<!--" + String(repeating: "x", count: AdobeProfileParser.maximumFileBytes) + "-->"

    static func version(_ version: String) -> String { "<crs:Version>\(version)</crs:Version>" }

    @Test func scanFindsLookProfilesRecursivelyAndSkipsTheRest() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        try sandbox.makeLibraryFolders()
        let a1 = try sandbox.write(Self.profile("A1", group: "Artistic"), "system/Adobe/Profiles/Artistic/A1.xmp")
        try sandbox.write(Self.profile("X", outputReferred: false, cameraModel: "Nikon Z 8"),
                          "system/Adobe/Profiles/Camera/Nikon/X.xmp")
        try sandbox.write(Self.profile("R", outputReferred: false), "system/Raw/R.xmp")
        try sandbox.write(Self.profile("P", presetType: "Normal"), "system/Adobe/Presets/P.xmp")
        try sandbox.write(Self.profile("Hidden", group: "Artistic"), "system/.hidden.xmp")
        try sandbox.write(Self.profile("Big", group: "Artistic", extra: Self.padding), "system/big.xmp")
        try FileManager.default.createSymbolicLink(at: sandbox.system.appendingPathComponent("link.xmp"),
                                                   withDestinationURL: a1)
        // A link to a profile outside every library folder, so following links would show up as an extra entry.
        let outside = try sandbox.write(Self.profile("Linked", group: "Artistic"), "outside/Linked.xmp")
        try FileManager.default.createSymbolicLink(at: sandbox.system.appendingPathComponent("outside-link.xmp"),
                                                   withDestinationURL: outside)
        try sandbox.write(Self.profile("Notes", group: "Artistic"), "system/notes.txt")
        try sandbox.write(Data("<x:xmpmeta crs:PresetType=\"Look\"><unclosed>".utf8), "system/Broken.xmp")

        let index = await sandbox.makeLibrary().index()
        try #require(index.profiles.count == 3)
        #expect(index.profiles.map(\.name) == ["A1", "X", "R"])
        #expect(index.profiles.map(\.group) == ["Artistic", "Nikon", "Raw"])
        #expect(index.profiles.map(\.source) == [.adobe, .adobe, .adobe])
        #expect(index.groups == [ProfileGroupCount(name: "Artistic", count: 1)])
        #expect(index.hidden == ProfileHiddenCounts(rawOnly: 1, cameraSpecific: 1, unsupported: 1))
        #expect(index.usable.map(\.name) == ["A1"])

        let found = try #require(index.profiles.first)
        let data = try Data(contentsOf: a1)
        #expect(found.digest == ProfileDigest(of: data))
        #expect(found.fileSize == data.count)
        #expect(found.path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } == a1.resolvingSymlinksInPath())
        #expect(found.tables == .rgb)
        #expect(found.supportsAmount)
        #expect(!found.convertsToGrayscale)
        #expect(found.usability == .usable)
        #expect(found.fidelity == .exact)
        #expect(index.summary(for: found.digest) == found)
        #expect(index.profiles[1].usability == .cameraSpecific("Nikon Z 8"))
        #expect(index.profiles[2].usability == .rawOnly)
    }

    @Test func dedupPrefersSourceThenVersion() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        try sandbox.makeLibraryFolders()
        let shared = Self.uniqueUUID()
        try sandbox.write(Self.profile("Shared", uuid: shared, extra: Self.version("1.0")), "system/Shared.xmp")
        try sandbox.write(Self.profile("Shared", uuid: shared, extra: Self.version("2.0")), "user/Shared.xmp")
        let versioned = Self.uniqueUUID()
        try sandbox.write(Self.profile("Versioned", uuid: versioned, extra: Self.version("9.9")), "user/a/V.xmp")
        try sandbox.write(Self.profile("Versioned", uuid: versioned, extra: Self.version("10.2")), "user/b/V.xmp")
        try sandbox.write(Self.profile("Versioned", uuid: versioned), "user/c/V.xmp")
        let tied = Self.uniqueUUID()
        try sandbox.write(Self.profile("Tied", uuid: tied, extra: Self.version("3")), "user/y/T.xmp")
        try sandbox.write(Self.profile("Tied", uuid: tied, extra: Self.version("3.0")), "user/x/T.xmp")
        let twoTables = Self.uniqueUUID()
        try sandbox.write(Self.profile("Two Tables", uuid: twoTables), "system/D1.xmp")
        try sandbox.write(Self.profile("Two Tables", uuid: twoTables, rgb: Self.otherTable), "system/D2.xmp")

        let profiles = await sandbox.makeLibrary().index().profiles
        let sharedEntries = profiles.filter { $0.identity.uuid == shared }
        #expect(sharedEntries.map(\.source) == [.adobe])
        #expect(sharedEntries.map(\.version) == ["1.0"])
        let versionedEntries = profiles.filter { $0.identity.uuid == versioned }
        #expect(versionedEntries.map(\.version) == ["10.2"])
        #expect(versionedEntries.first?.path?.hasSuffix("user/b/V.xmp") == true)
        let tiedEntries = profiles.filter { $0.identity.uuid == tied }
        #expect(tiedEntries.count == 1)
        #expect(tiedEntries.first?.path?.hasSuffix("user/x/T.xmp") == true)
        let tableEntries = profiles.filter { $0.identity.uuid == twoTables }
        #expect(tableEntries.count == 2)
        #expect(Set(tableEntries.map(\.identity)).count == 2)
        #expect(profiles.count == 5)
    }

    @Test func groupsAndOrder() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        try sandbox.makeLibraryFolders()
        try sandbox.write(Self.profile("Old", group: "Vintage"), "system/Old.xmp")
        try sandbox.write(Self.profile("Mono", group: "B&W"), "system/Mono.xmp")
        try sandbox.write(Self.profile("Art", group: "artistic"), "user/Art.xmp")
        try sandbox.write(Self.profile("Alpha", group: "Numbers", extra: "<crs:SortName>Look 10</crs:SortName>"),
                          "system/Alpha.xmp")
        try sandbox.write(Self.profile("Zeta", group: "Numbers", extra: "<crs:SortName>Look 9</crs:SortName>"),
                          "system/Zeta.xmp")
        try sandbox.write(Self.profile("Folder"), "system/My Looks/Folder.xmp")
        try sandbox.write(Self.profile("Loose"), "system/Loose.xmp")
        try sandbox.write(Self.profile("Loose User"), "user/LooseUser.xmp")
        try sandbox.write(Self.profile("Mine"), "imported/Mine.xmp")

        let index = await sandbox.makeLibrary().index()
        #expect(index.profiles.map(\.name) == ["Art", "Mono", "Mine", "Folder", "Zeta", "Alpha", "Loose", "Loose User", "Old"])
        #expect(index.profiles.map(\.sortKey) == ["Art", "Mono", "Mine", "Folder", "Look 9", "Look 10", "Loose",
                                                  "Loose User", "Old"])
        #expect(index.profiles.first { $0.name == "Mine" }?.source == .imported)
        #expect(index.profiles.first { $0.name == "Loose User" }?.source == .adobeUser)
        #expect(index.groups == [
            ProfileGroupCount(name: "artistic", count: 1), ProfileGroupCount(name: "B&W", count: 1),
            ProfileGroupCount(name: "Imported", count: 1), ProfileGroupCount(name: "My Looks", count: 1),
            ProfileGroupCount(name: "Numbers", count: 2), ProfileGroupCount(name: "Other", count: 2),
            ProfileGroupCount(name: "Vintage", count: 1),
        ])
        #expect(index.hidden == ProfileHiddenCounts())
    }

    @Test func searchIsCaseAndDiacriticInsensitive() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        try sandbox.makeLibraryFolders()
        try sandbox.write(Self.profile("A1", group: "Artistic"), "system/A1.xmp")
        try sandbox.write(Self.profile("Éclair", group: "Vintage"), "system/E1.xmp")
        try sandbox.write(Self.profile("Old Film", group: "Vintage"), "system/V2.xmp")
        try sandbox.write(Self.profile("R", group: "Raw", outputReferred: false), "system/R.xmp")
        try sandbox.write(Self.profile("X", group: "Camera", cameraModel: "Nikon Z 8"), "system/X.xmp")

        let index = await sandbox.makeLibrary().index()
        func names(_ query: String?, group: String? = nil, includeUnusable: Bool = false) -> [String] {
            index.search(query: query, group: group, includeUnusable: includeUnusable).map(\.name)
        }
        #expect(names("vint") == ["Éclair", "Old Film"])
        #expect(names("ECLAIR") == ["Éclair"])
        #expect(names("a1.xmp") == ["A1"])
        #expect(names(" film ") == ["Old Film"])
        #expect(names(nil, group: "Vintage") == ["Éclair", "Old Film"])
        #expect(names("film", group: "Artistic") == [])
        #expect(names("   ") == ["A1", "Éclair", "Old Film"])
        #expect(names(nil) == ["A1", "Éclair", "Old Film"])
        #expect(names(nil, includeUnusable: true) == ["A1", "X", "R", "Éclair", "Old Film"])
        #expect(names("r", group: "Raw", includeUnusable: true) == ["R"])
        #expect(names("r", group: "Raw") == [])
    }

    @Test func readingNeverCreatesFolders() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        let index = await sandbox.makeLibrary().index(refresh: true)
        #expect(index.profiles.isEmpty && index.groups.isEmpty && index.hidden == ProfileHiddenCounts())
        for folder in [sandbox.system, sandbox.user, sandbox.imported] {
            #expect(!FileManager.default.fileExists(atPath: folder.path))
        }
        _ = try? await sandbox.makeLibrary().resolve("Anything")
        #expect(!FileManager.default.fileExists(atPath: sandbox.imported.path))
    }

    @Test func indexIsCachedUntilRefreshedOrImported() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        try sandbox.makeLibraryFolders()
        let library = sandbox.makeLibrary()
        try sandbox.write(Self.profile("First", group: "G"), "system/First.xmp")
        #expect(await library.index().profiles.map(\.name) == ["First"])
        try sandbox.write(Self.profile("Second", group: "G"), "system/Second.xmp")
        #expect(await library.index().profiles.map(\.name) == ["First"])
        #expect(await library.index(refresh: true).profiles.map(\.name) == ["First", "Second"])
        let incoming = try sandbox.write(Self.profile("Third", group: "G"), "incoming/Third.xmp")
        #expect(await library.importProfiles(at: [incoming]).imported.count == 1)
        #expect(await library.index().profiles.map(\.name) == ["First", "Second", "Third"])
    }

    @Test func importCopiesBytesAndIsIdempotent() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        try sandbox.makeLibraryFolders()
        let library = sandbox.makeLibrary()
        let data = Self.profile("Good", group: "Portraits")
        let good = try sandbox.write(data, "incoming/Good.xmp")
        let digest = ProfileDigest(of: data)
        #expect(await library.index().profiles.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sandbox.imported.path))

        let report = await library.importProfiles(at: [good])
        #expect(report.imported.count == 1)
        #expect(report.alreadyImported.isEmpty && report.skipped.isEmpty)
        let copy = sandbox.imported.appendingPathComponent("\(digest.hex).xmp")
        #expect(try Data(contentsOf: copy) == data)
        let summary = try #require(report.imported.first)
        #expect(summary.digest == digest)
        #expect(summary.source == .imported)
        #expect(summary.group == "Portraits")
        #expect(summary.path.map { URL(fileURLWithPath: $0).lastPathComponent } == "\(digest.hex).xmp")

        let listed = try #require(await library.index().summary(for: digest))
        #expect(listed.source == .imported)
        #expect(listed.group == "Portraits")
        #expect(listed.name == "Good")

        let again = await library.importProfiles(at: [good])
        #expect(again.alreadyImported.count == 1)
        #expect(again.imported.count == 0)
        #expect(again.alreadyImported.first?.digest == digest)
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.imported.path) == ["\(digest.hex).xmp"])
    }

    /// Import parses every file in full, so the index lists what it imported even when the file declares its Look
    /// too late for the quick check that skips presets in Adobe's folders.
    @Test func importedProfilesAreListedWhereverTheyDeclareTheirType() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        try sandbox.makeLibraryFolders()
        let late = ProfileFixture.xmp(name: "Late", uuid: Self.uniqueUUID(), group: "G", rgb: Self.table,
                                      doctype: "<!--" + String(repeating: "x", count: 9000) + "-->\n")
        try sandbox.write(late, "system/Late.xmp")
        let incoming = try sandbox.write(late, "incoming/Late.xmp")
        let library = sandbox.makeLibrary()
        #expect(await library.index().profiles.isEmpty, "Adobe's folders skip a file without the marker up front")

        #expect(await library.importProfiles(at: [incoming]).imported.count == 1)
        let listed = try #require(await library.index().summary(for: ProfileDigest(of: late)))
        #expect(listed.source == .imported && listed.name == "Late")
    }

    @Test func importReportsAWriteFailure() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        try sandbox.makeLibraryFolders()
        // A file where the imported folder should be, so the copy can't be written.
        try sandbox.write(Data("in the way".utf8), "imported")
        let good = try sandbox.write(Self.profile("Good", group: "G"), "incoming/Good.xmp")
        let report = await sandbox.makeLibrary().importProfiles(at: [good])
        #expect(report.imported.isEmpty)
        let failure = try #require(report.skipped.first)
        guard case .writeFailed(let detail) = failure.error else {
            Issue.record("Expected .writeFailed, got \(failure.error)")
            return
        }
        #expect(!detail.isEmpty)
        #expect(failure.error.errorDescription?.contains("..") == false)
    }

    @Test func importReportsEachFailure() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        try sandbox.makeLibraryFolders()
        let incoming = sandbox.root.appendingPathComponent("incoming", isDirectory: true)
        try sandbox.write(Self.profile("Good 1", group: "G"), "incoming/good1.xmp")
        try sandbox.write(Self.profile("Good 2", group: "G"), "incoming/nested/good2.xmp")
        try sandbox.write(Self.profile("Preset", presetType: "Normal"), "incoming/preset.xmp")
        try sandbox.write(Self.profile("Raw", outputReferred: false), "incoming/raw.xmp")
        try sandbox.write(Self.profile("Camera", cameraModel: "Nikon Z 8"), "incoming/camera.xmp")
        try sandbox.write(Self.profile("Missing", embedTables: false), "incoming/missing.xmp")
        var big = Self.profile("Big")
        big.append(Data(repeating: 0x20, count: 5 * 1024 * 1024 - big.count))
        try sandbox.write(big, "incoming/big.xmp")
        try sandbox.write(Data("hello".utf8), "incoming/garbage.xmp")
        try sandbox.write(Data("not a profile".utf8), "incoming/readme.txt")
        let nowhere = sandbox.root.appendingPathComponent("nowhere.xmp")

        let report = await sandbox.makeLibrary().importProfiles(at: [incoming, nowhere])
        #expect(report.imported.map(\.name).sorted() == ["Good 1", "Good 2"])
        #expect(report.alreadyImported.isEmpty)
        #expect(report.skipped.count == 7)
        let skipped = Dictionary(report.skipped.map { ($0.url.lastPathComponent, $0.error) }) { first, _ in first }
        #expect(skipped == [
            "preset.xmp": .notAProfile(presetType: "Normal"),
            "raw.xmp": .rawOnly,
            "camera.xmp": .cameraSpecific("Nikon Z 8"),
            "missing.xmp": .unsupported("a table it names isn't in the file"),
            "big.xmp": .tooLarge,
            "garbage.xmp": .malformed("XML"),
            "nowhere.xmp": .unreadable("No file at \(nowhere.path)"),
        ])
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.imported.path).count == 2)
    }

    @Test func resolveSelectors() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        try sandbox.makeLibraryFolders()
        let chromeUUID = Self.uniqueUUID()
        try sandbox.write(Self.profile("Sepia", group: "Warm"), "system/Warm/Sepia.xmp")
        try sandbox.write(Self.profile("Sepia", group: "Cool"), "system/Cool/Sepia.xmp")
        try sandbox.write(Self.profile("Chrome", uuid: chromeUUID, group: "Film"), "system/Chrome.xmp")
        try sandbox.write(Self.profile("Raw Look", group: "Raw", outputReferred: false), "system/RawLook.xmp")
        let library = sandbox.makeLibrary()
        let index = await library.index()
        let chrome = try #require(index.profiles.first { $0.name == "Chrome" })
        let warm = try #require(index.profiles.first { $0.group == "Warm" })
        let cool = try #require(index.profiles.first { $0.group == "Cool" })
        let rawLook = try #require(index.profiles.first { $0.name == "Raw Look" })

        #expect(try await library.resolve(chrome.digest.hex.uppercased()) == chrome)
        #expect(try await library.resolve(chromeUUID.lowercased()) == chrome)
        #expect(try await library.resolve("warm/sepia") == warm)
        #expect(try await library.resolve("chrome") == chrome)
        #expect(try await library.resolve("  Chrome \n") == chrome)
        await #expect(throws: ProfileSelectorError.ambiguous([cool, warm])) { try await library.resolve("Sepia") }
        await #expect(throws: ProfileSelectorError.notFound("Nope")) { try await library.resolve("Nope") }
        await #expect(throws: ProfileSelectorError.notFound("film/sepia")) { try await library.resolve("film/sepia") }
        await #expect(throws: ProfileSelectorError.unusable(rawLook)) { try await library.resolve("Raw Look") }
        await #expect(throws: ProfileSelectorError.unusable(rawLook)) { try await library.resolve(rawLook.digest.hex) }
        let unknown = String(repeating: "ab", count: 32)
        await #expect(throws: ProfileSelectorError.notFound(unknown)) { try await library.resolve(unknown) }

        let loaded = try ProfileRegistry.shared.register(Self.profile("Only In A Document", group: nil))
        let document = try await library.resolve(loaded.digest.hex)
        #expect(document.source == .document)
        #expect(document.digest == loaded.digest)
        #expect(document.name == "Only In A Document")
        #expect(document.group == "Other")
        #expect(document.path == nil)
        #expect(document.fileSize == loaded.data.count)
    }

    /// An imported copy that deduplication hides behind an installed profile of the same identity (UUID and tables)
    /// but other bytes still resolves by the id `importProfiles` returned for it, so an agent can apply the profile it
    /// has just imported.
    @Test func anImportedCopyHiddenByDedupResolvesByItsDigest() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        try sandbox.makeLibraryFolders()
        let uuid = Self.uniqueUUID()
        try sandbox.write(Self.profile("Shared Look", uuid: uuid, group: "Adobe"), "system/Shared.xmp")
        let copy = try sandbox.write(Self.profile("Shared Look (edited)", uuid: uuid, group: "Adobe"), "outside/Copy.xmp")
        let library = sandbox.makeLibrary()
        let imported = try #require(await library.importProfiles(at: [copy]).imported.first)
        #expect(await library.index().summary(for: imported.digest) == nil)

        let resolved = try await library.resolve(imported.digest.hex)
        #expect(resolved.digest == imported.digest && resolved.source == .imported)
        #expect(resolved.name == "Shared Look (edited)" && resolved.group == "Adobe")
        #expect(try await library.load(resolved).digest == imported.digest)
        // A digest nobody has, imported or listed, is still not found.
        let unknown = String(repeating: "cd", count: 32)
        await #expect(throws: ProfileSelectorError.notFound(unknown)) { try await library.resolve(unknown) }
    }

    @Test func loadVerifiesTheDigestAndRegisters() async throws {
        let sandbox = Sandbox()
        defer { sandbox.remove() }
        try sandbox.makeLibraryFolders()
        let file = try sandbox.write(Self.profile("Loadable", group: "G"), "system/L.xmp")
        let library = sandbox.makeLibrary()
        let summary = try #require(await library.index().profiles.first)

        let loaded = try await library.load(summary)
        #expect(loaded.digest == summary.digest)
        #expect(loaded.profile.rgbTable == Self.table)
        #expect(ProfileRegistry.shared.profile(summary.digest) === loaded)
        #expect(try await library.load(summary) === loaded)

        try Self.profile("Replacement", group: "G").write(to: file)
        await #expect(throws: ProfileError.digestMismatch) { try await library.load(summary) }

        try FileManager.default.removeItem(at: file)
        let unreadable = await #expect(throws: ProfileError.self) { try await library.load(summary) }
        if case .unreadable = unreadable {} else { Issue.record("Expected .unreadable, got \(String(describing: unreadable))") }

        // The size is checked before anything is read: a file over 4 MiB, or one whose size changed, fails even
        // when it can't be read.
        try (Self.profile("Loadable", group: "G") + Data(Self.padding.utf8)).write(to: file)
        await #expect(throws: ProfileError.tooLarge) { try await library.load(summary) }
        try Self.profile("Changed size", group: "G").write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        await #expect(throws: ProfileError.digestMismatch) { try await library.load(summary) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        let unregistered = ProfileSummary(loaded: try LoadedProfile(data: Self.profile("Unregistered", group: "G")))
        #expect(unregistered.source == .document)
        await #expect(throws: ProfileError.notLoaded(name: "Unregistered")) { try await library.load(unregistered) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["COMPOSITOR_ADOBE_LIBRARY"] == "1"))
    func installedLibraryIndexes() async {
        let library = ProfileLibrary(locations: .defaults)
        let start = ContinuousClock.now
        let index = await library.index()
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        var lines = ["Installed profile library: indexed in \(String(format: "%.3f", seconds)) s, \(index.usable.count) usable, "
                     + "hidden \(index.hidden.rawOnly) raw-only, \(index.hidden.cameraSpecific) camera-specific, "
                     + "\(index.hidden.unsupported) unsupported"]
        lines += index.groups.map { "  \($0.name): \($0.count)" }
        let report = lines.joined(separator: "\n")
        print(report)
        // xcodebuild doesn't show an app-hosted test's stdout; the attachment keeps the counts in the result bundle.
        Attachment.record(report, named: "installed-profile-library.txt")
        #expect(index.usable.count >= 1)
        #expect(index.usable.allSatisfy { !$0.group.isEmpty })
    }
}
