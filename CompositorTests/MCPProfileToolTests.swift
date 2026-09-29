import Foundation
import Testing
import MCP
@testable import Compositor

/// The profile tools: `list_profiles` lists the temporary library `ProfileTestSupport` installs, `import_profile` copies
/// profiles into it, and `add_adjustment_layer` and `set_adjustment` take a `profile` selector for a Profile layer,
/// loading and registering the profile it names.
@MainActor struct MCPProfileToolTests {
    // MARK: Helpers

    /// A workspace with a document open, after a fresh scan of the temporary library (never the real one).
    private func workspace() async -> ProjectWorkspace {
        _ = ProfileTestSupport.locations
        _ = await ProfileLibrary.shared.index(refresh: true)
        return MCPTestSupport.workspace(width: 8, height: 8)
    }

    @discardableResult
    private func call(_ name: String, _ args: [String: Value] = [:], in workspace: ProjectWorkspace,
                      expectError code: String? = nil) async throws -> [String: Value] {
        try await MCPTestSupport.call(name, args, in: workspace, expectError: code)
    }

    private func entries(_ result: [String: Value], _ key: String = "profiles") -> [[String: Value]] {
        (result[key]?.arrayValue ?? []).compactMap(\.objectValue)
    }

    private func names(_ result: [String: Value]) -> [String] {
        entries(result).compactMap { $0["name"]?.stringValue }
    }

    private func details(_ result: [String: Value]) -> [String: Value] {
        result["error"]?.objectValue?["details"]?.objectValue ?? [:]
    }

    private func profileSettings(_ result: [String: Value]) -> [String: Value] {
        result["settings"]?.objectValue?["profile_settings"]?.objectValue ?? [:]
    }

    private func referenceName(_ result: [String: Value]) -> String? {
        profileSettings(result)["reference"]?.objectValue?["name"]?.stringValue
    }

    private func amount(_ result: [String: Value]) -> Double? {
        MCPValues.number(profileSettings(result)["amount"])
    }

    /// A path with its symbolic links resolved: a folder walk reports the temporary folder as /private/var.
    private func resolved(_ path: String?) -> String? {
        path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    private func adjustment(_ session: EditorSession, _ id: UUID) -> LayerAdjustment? {
        session.document?.layers.first { $0.id == id }?.adjustment
    }

    private func digest(ofFixture name: String) throws -> ProfileDigest {
        ProfileDigest(of: try ProfileFixtureFiles.data(name))
    }

    /// A usable profile no other test has: a unique uuid and a small RGB table.
    private func uniqueProfile(_ name: String, group: String? = "MCP Tests") -> Data {
        ProfileFixture.xmp(name: name, uuid: ProfileAdjustmentTests.uniqueUUID(), group: group,
                           rgb: ProfileFixture.rgbTable(divisions: 5) { r, g, b in (r, min(1, g * 1.05), b) })
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPProfileToolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Adds a Profile layer showing "Warm AdobeRGB" at 140 and returns its id.
    private func addWarmLayer(in workspace: ProjectWorkspace) async throws -> UUID {
        let added = try await call("add_adjustment_layer",
                                   ["kind": "profile", "settings": ["profile": "Warm AdobeRGB", "amount": 140]], in: workspace)
        return try #require(added["layer_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
    }

    // MARK: list_profiles

    @Test func listProfilesDescribesTheLibrary() async throws {
        let workspace = await workspace()
        let listed = try await call("list_profiles", in: workspace)
        let profiles = entries(listed)

        let warm = try #require(profiles.first { $0["name"]?.stringValue == "Warm AdobeRGB" })
        #expect(warm["tables"]?.stringValue == "rgb")
        #expect(warm["fidelity"]?.stringValue == "exact")
        #expect(warm["ignored_settings"]?.arrayValue == [])
        #expect(warm["usable"] == .bool(true) && warm["reason"] == nil && warm["reason_detail"] == nil)
        #expect(warm["supports_amount"] == .bool(true) && warm["monochrome"] == .bool(false))
        #expect(warm["id"]?.stringValue == (try digest(ofFixture: "profile-warm-adobe.xmp")).hex)
        #expect(warm["id"]?.stringValue?.count == 64)
        #expect(warm["uuid"]?.stringValue == "00000000000000000000000000000002")
        #expect(warm["group"]?.stringValue == "Synthetic" && warm["source"]?.stringValue == "adobe")
        #expect(resolved(warm["path"]?.stringValue)
            == resolved(ProfileTestSupport.locations.adobeSystem.appendingPathComponent("profile-warm-adobe.xmp").path))

        let approximate = try #require(profiles.first { $0["name"]?.stringValue == "Approximate" })
        #expect(approximate["fidelity"]?.stringValue == "approximate")
        #expect(approximate["ignored_settings"]?.arrayValue == ["Clarity2012", "Contrast2012"])

        let mono = try #require(profiles.first { $0["name"]?.stringValue == "Mono Curve" })
        #expect(mono["tables"]?.stringValue == "look+rgb" && mono["monochrome"] == .bool(true))
        #expect(profiles.first { $0["name"]?.stringValue == "Hue Linear" }?["tables"]?.stringValue == "look")
        #expect(profiles.first { $0["name"]?.stringValue == "No Amount" }?["supports_amount"] == .bool(false))

        #expect(MCPValues.number(listed["hidden"]?.objectValue?["raw_only"]) == 1)
        #expect(MCPValues.number(listed["hidden"]?.objectValue?["camera_specific"]) != nil)
        #expect(MCPValues.number(listed["hidden"]?.objectValue?["unsupported"]) != nil)
        let groups = (listed["groups"]?.arrayValue ?? []).compactMap(\.objectValue)
        let synthetic = try #require(groups.first { $0["name"]?.stringValue == "Synthetic" })
        #expect(MCPValues.number(synthetic["count"]) == 11)
        #expect(MCPValues.number(listed["total"]) == Double(profiles.count) && profiles.count <= 100)
        #expect(MCPValues.number(listed["offset"]) == 0)
        #expect(!profiles.contains { $0["name"]?.stringValue == "Raw Only" })
    }

    @Test func listProfilesFiltersAndPages() async throws {
        let workspace = await workspace()
        let hue = names(try await call("list_profiles", ["query": "hue"], in: workspace))
        #expect(!hue.isEmpty && hue.allSatisfy { $0.contains("Hue") }, "\(hue)")

        let everything = entries(try await call("list_profiles", ["include_unusable": true, "limit": 500], in: workspace))
        let raw = try #require(everything.first { $0["name"]?.stringValue == "Raw Only" })
        #expect(raw["usable"] == .bool(false) && raw["reason"]?.stringValue == "raw_only")
        #expect(raw["reason_detail"]?.stringValue == ProfileError.rawOnly.localizedDescription)

        // Scoped to the fixtures' group, which no other test adds to, so the total can't change between the calls.
        let whole = try await call("list_profiles", ["group": "Synthetic"], in: workspace)
        #expect(names(whole).count == 11)
        let page = try await call("list_profiles", ["group": "Synthetic", "limit": 2, "offset": 1], in: workspace)
        #expect(entries(page).count == 2 && MCPValues.number(page["offset"]) == 1)
        #expect(MCPValues.number(page["total"]) == MCPValues.number(whole["total"]))
        #expect(names(page) == Array(names(whole)[1...2]))

        for (key, value) in [("limit", Value.int(0)), ("limit", .int(501)), ("offset", .int(-1))] {
            let failed = try await call("list_profiles", [key: value], in: workspace, expectError: "invalid_argument")
            #expect(details(failed)["field"]?.stringValue == key)
        }
    }

    // MARK: import_profile

    @Test func importProfileCopiesAndIsIdempotent() async throws {
        let workspace = await workspace()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = uniqueProfile("Imported One")
        let file = folder.appendingPathComponent("Imported One.xmp")
        try data.write(to: file)

        let first = try await call("import_profile", ["path": .string(file.path)], in: workspace)
        let imported = entries(first, "imported")
        #expect(imported.count == 1 && entries(first, "already_imported").isEmpty && entries(first, "skipped").isEmpty)
        let copy = ProfileTestSupport.locations.imported.appendingPathComponent("\(ProfileDigest(of: data).hex).xmp")
        #expect(imported.first?["name"]?.stringValue == "Imported One" && imported.first?["source"]?.stringValue == "imported")
        #expect(imported.first?["id"]?.stringValue == ProfileDigest(of: data).hex)
        #expect(imported.first?["path"]?.stringValue == copy.path)
        #expect(try Data(contentsOf: copy) == data)
        let again = try await call("import_profile", ["path": .string(file.path)], in: workspace)
        #expect(entries(again, "imported").isEmpty && entries(again, "already_imported").count == 1)

        // A folder is searched recursively; a preset in it is skipped with a reason.
        let batch = folder.appendingPathComponent("batch", isDirectory: true)
        let nested = batch.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try uniqueProfile("Imported Two").write(to: nested.appendingPathComponent("Imported Two.xmp"))
        let preset = batch.appendingPathComponent("Preset.xmp")
        try ProfileFixture.xmp(presetType: "Normal").write(to: preset)
        let mixed = try await call("import_profile", ["path": .string(batch.path)], in: workspace)
        #expect(entries(mixed, "imported").compactMap { $0["name"]?.stringValue } == ["Imported Two"])
        let skipped = entries(mixed, "skipped")
        #expect(skipped.count == 1 && MCPValues.number(mixed["skipped_count"]) == 1 && mixed["truncated"] == .bool(false))
        #expect(skipped.first?["code"]?.stringValue == "not_a_profile" && resolved(skipped.first?["path"]?.stringValue) == resolved(preset.path))
        #expect(skipped.first?["message"]?.stringValue == ProfileError.notAProfile(presetType: "Normal").localizedDescription)

        // A single file that can't be imported fails the call.
        let refused = try await call("import_profile", ["path": .string(preset.path)], in: workspace, expectError: "invalid_argument")
        #expect(details(refused)["code"]?.stringValue == "not_a_profile" && details(refused)["path"]?.stringValue == preset.path)
        #expect(refused["error"]?.objectValue?["message"]?.stringValue == ProfileError.notAProfile(presetType: "Normal").localizedDescription)

        try await call("import_profile", ["path": .string(folder.appendingPathComponent("Missing.xmp").path)], in: workspace,
                       expectError: "not_found")

        // A relative path is inside the Agent folder.
        let agent = MCPTestSupport.agentRootOverride
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        let name = "Imported Three \(UUID().uuidString).xmp"
        try uniqueProfile("Imported Three").write(to: agent.appendingPathComponent(name))
        let relative = try await call("import_profile", ["path": .string(name)], in: workspace)
        #expect(entries(relative, "imported").first?["name"]?.stringValue == "Imported Three")
    }

    /// A file past the 4 MB limit is refused with a hint about its size: telling the agent to pass a Look profile .xmp
    /// is no help when that's what it passed.
    @Test func importingAFileOverTheSizeLimitSaysWhy() async throws {
        let workspace = await workspace()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let big = folder.appendingPathComponent("Big.xmp")
        try Data(count: AdobeProfileParser.maximumFileBytes + 1).write(to: big)
        let refused = try await call("import_profile", ["path": .string(big.path)], in: workspace, expectError: "invalid_argument")
        #expect(details(refused)["code"]?.stringValue == "too_large")
        let hint = refused["error"]?.objectValue?["hint"]?.stringValue ?? ""
        #expect(hint.contains("4 MB") && !hint.contains("PresetType"), "\(hint)")
    }

    @Test func importProfileBoundsAFolderOfSidecars() async throws {
        let workspace = await workspace()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A photo folder: one develop-settings sidecar per raw file, more of them than one call reads.
        let limit = MCPToolRegistry.profileImportFileLimit
        let photos = folder.appendingPathComponent("Photos", isDirectory: true)
        let later = photos.appendingPathComponent("Later", isDirectory: true)
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        let sidecar = ProfileFixture.xmp(presetType: "Normal")
        for index in 0..<limit {
            try sidecar.write(to: photos.appendingPathComponent(String(format: "IMG_%04d.xmp", index)))
        }
        try sidecar.write(to: later.appendingPathComponent("IMG_9999.xmp"))

        let result = try await call("import_profile", ["path": .string(photos.path)], in: workspace)
        #expect(result["truncated"] == .bool(true))
        #expect(entries(result, "imported").isEmpty && entries(result, "already_imported").isEmpty)
        let skipped = entries(result, "skipped")
        #expect(skipped.count == MCPToolRegistry.profileImportSkippedLimit)
        #expect(MCPValues.number(result["skipped_count"]) == Double(limit))
        #expect(skipped.allSatisfy { $0["code"]?.stringValue == "not_a_profile" })
        #expect(resolved(skipped.first?["path"]?.stringValue) == resolved(photos.appendingPathComponent("IMG_0000.xmp").path))

        // Symbolic links are never followed: not a linked file, nor a linked folder.
        let profiles = folder.appendingPathComponent("Profiles", isDirectory: true)
        let elsewhere = folder.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try uniqueProfile("Walked").write(to: profiles.appendingPathComponent("Walked.xmp"))
        let linkedFile = elsewhere.appendingPathComponent("Linked File.xmp")
        try uniqueProfile("Linked File").write(to: linkedFile)
        try FileManager.default.createSymbolicLink(at: profiles.appendingPathComponent("Linked File.xmp"), withDestinationURL: linkedFile)
        try FileManager.default.createSymbolicLink(at: profiles.appendingPathComponent("Linked Folder"), withDestinationURL: elsewhere)
        let walked = try await call("import_profile", ["path": .string(profiles.path)], in: workspace)
        #expect(entries(walked, "imported").compactMap { $0["name"]?.stringValue } == ["Walked"])
        #expect(entries(walked, "skipped").isEmpty && MCPValues.number(walked["skipped_count"]) == 0)
        #expect(walked["truncated"] == .bool(false))
    }

    /// A walk of a folder holding macOS-protected roots — `~` holds Documents, Desktop, Downloads, iCloud Drive and
    /// cloud storage — probes each one first, through a checker with temporary roots and a fake lister set for this
    /// test's task (`FolderAccess.taskChecker`; the real protected folders are never read from the test host), and stops
    /// before reading a root still waiting on a prompt.
    @Test(.timeLimit(.minutes(5)))
    func importWalkNeverWaitsOnAPermissionPrompt() async throws {
        let home = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: home) }
        var locations: [ProtectedRoot: URL] = [:]
        for root in ProtectedRoot.allCases {
            let location = root == .removableVolumes ? home.appendingPathComponent("Volumes", isDirectory: true) : root.location(home: home)
            try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
            locations[root] = location
        }
        let drive = locations[.cloudStorage]!.appendingPathComponent("Drive", isDirectory: true)
        let pictures = home.appendingPathComponent("Pictures/Profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        try uniqueProfile("In Documents").write(to: locations[.documents]!.appendingPathComponent("In Documents.xmp"))
        try uniqueProfile("In Pictures").write(to: pictures.appendingPathComponent("In Pictures.xmp"))
        let library = home.appendingPathComponent("Library", isDirectory: true)
        func checker(_ lister: ProfileImportLister) -> FolderAccess.Checker {
            FolderAccess.Checker(locations: locations, lister: { try lister.list($0) })
        }
        func names(_ files: [URL]) -> [String] { files.map(\.lastPathComponent).sorted() }
        /// `profileImportFiles`, its probes and the walk's own checks answered by `lister`.
        func importFiles(in folder: URL, _ lister: ProfileImportLister, timeout: Duration,
                         limit: Int = MCPToolRegistry.profileImportFileLimit) async throws -> (files: [URL], truncated: Bool) {
            try await FolderAccess.$taskChecker.withValue(checker(lister)) {
                try await MCPToolRegistry.profileImportFiles(in: folder, timeout: timeout, limit: limit)
            }
        }
        let plenty: Duration = .seconds(120)

        // Which roots a walk enters: those inside the folder, spelled any way, and a root guarded folder by folder
        // when it is the folder. A root guarded as a whole that the folder is or lies in was checked with the path.
        let probe = checker(ProfileImportLister())
        let everyRoot = ProtectedRoot.allCases
        #expect(MCPToolRegistry.protectedRoots(inside: home, checker: probe) == everyRoot)
        let dataVolume = URL(fileURLWithPath: "/System/Volumes/Data" + (try realPath(home)), isDirectory: true)
        #expect(MCPToolRegistry.protectedRoots(inside: dataVolume, checker: probe) == everyRoot)
        // The folders above the Data volume lead to all of / — Users, Volumes and the rest — as / itself does.
        for above in ["/", "/System", "/System/Volumes", "/system/volumes/", "/System/Volumes/Data"] {
            let folder = URL(fileURLWithPath: above, isDirectory: true)
            #expect(MCPToolRegistry.protectedRoots(inside: folder, checker: probe) == everyRoot, "\(above)")
        }
        #expect(MCPToolRegistry.protectedRoots(inside: URL(fileURLWithPath: "/System/Library", isDirectory: true), checker: probe).isEmpty)
        #expect(MCPToolRegistry.protectedRoots(inside: library, checker: probe) == [.iCloudDrive, .cloudStorage])
        #expect(MCPToolRegistry.protectedRoots(inside: locations[.cloudStorage]!, checker: probe) == [.cloudStorage])
        #expect(MCPToolRegistry.protectedRoots(inside: locations[.documents]!, checker: probe).isEmpty)
        #expect(MCPToolRegistry.protectedRoots(inside: pictures, checker: probe).isEmpty)

        // Documents is still asking: the call fails fast, naming it, and nothing is walked.
        let asking = ProfileImportLister(["Documents": .hang])
        defer { asking.release() }
        do {
            _ = try await importFiles(in: home, asking, timeout: .milliseconds(300))
            Issue.record("A walk into a root waiting on a prompt should fail")
        } catch let error as MCPToolError {
            #expect(error.code == .busy)
            #expect(error.details["code"]?.stringValue == "folder_access_pending" && error.details["root"]?.stringValue == "documents")
            #expect(error.details["path"]?.stringValue == locations[.documents]!.path)
        }

        // One cloud storage provider is asking: named by its folder. The probe lists CloudStorage, then Drive, and
        // starts no listing once its time is up, so it gets the default time: with too little, a busy main actor
        // between the two leaves Drive unasked, and the root is reported instead.
        let provider = ProfileImportLister(["CloudStorage": .folders(["Drive"]), "Drive": .hang])
        defer { provider.release() }
        do {
            _ = try await importFiles(in: library, provider, timeout: FolderAccess.defaultTimeout)
            Issue.record("A walk into a provider waiting on a prompt should fail")
        } catch let error as MCPToolError {
            #expect(error.details["code"]?.stringValue == "folder_access_pending" && error.details["root"]?.stringValue == "cloud_storage")
            #expect(error.details["path"]?.stringValue == drive.path)
        }

        // Every root answered (Desktop with a refusal, which a walk meets at once): the walk goes ahead.
        let answered = ProfileImportLister(["Desktop": .failure(POSIXError(.EPERM)), "CloudStorage": .folders(["Drive"])])
        let found = try await importFiles(in: home, answered, timeout: plenty)
        #expect(names(found.files) == ["In Documents.xmp", "In Pictures.xmp"] && !found.truncated)
        #expect(Set(answered.listed) == ["Documents", "Desktop", "Downloads", "Mobile Documents", "CloudStorage", "Drive", "Volumes"])

        // A folder with no root inside probes nothing; the file limit truncates the walk.
        let untouched = ProfileImportLister()
        let inPictures = try await importFiles(in: pictures, untouched, timeout: plenty)
        #expect(names(inPictures.files) == ["In Pictures.xmp"] && untouched.listed.isEmpty)
        let first = try await importFiles(in: home, answered, timeout: plenty, limit: 1)
        #expect(first.files.count == 1 && first.truncated)
    }

    /// `path` with every symlink resolved (`/var/…` → `/private/var/…`).
    private func realPath(_ url: URL) throws -> String {
        let resolved = try #require(realpath(url.path, nil))
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: Applying

    @Test func addAdjustmentLayerAppliesAProfileInOneStep() async throws {
        let workspace = await workspace()
        let session = workspace.current.session
        let layers = session.document?.layers.count ?? 0
        let undoCount = session.history.undoCount

        let added = try await call("add_adjustment_layer",
                                   ["kind": "profile", "settings": ["profile": "Warm AdobeRGB", "amount": 140]], in: workspace)
        let id = try #require(added["layer_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let warm = try digest(ofFixture: "profile-warm-adobe.xmp")
        // Named after its profile, as the app names the Profile layers it adds.
        #expect(added["kind"]?.stringValue == "profile" && added["name"]?.stringValue == "Warm AdobeRGB")
        #expect(session.document?.layers.first { $0.id == id }?.name == "Warm AdobeRGB")
        #expect(referenceName(added) == "Warm AdobeRGB" && amount(added) == 140)
        let reference = profileSettings(added)["reference"]?.objectValue ?? [:]
        #expect(reference["digest"]?.stringValue == warm.hex && reference["group"]?.stringValue == "Synthetic")
        #expect(reference["uuid"]?.stringValue == "00000000000000000000000000000002")
        #expect(adjustment(session, id)?.profile == ProfileAdjustmentSettings(
            reference: ProfileReference(digest: warm, uuid: "00000000000000000000000000000002", name: "Warm AdobeRGB", group: "Synthetic"),
            amount: 140))
        #expect(session.history.undoCount == undoCount + 1 && session.document?.layers.count == layers + 1)
        #expect(ProfileRegistry.shared.profile(warm) != nil)

        try await call("undo", in: workspace)
        #expect(session.document?.layers.count == layers && adjustment(session, id) == nil)
    }

    @Test func setAdjustmentSwitchesClearsAndResolvesEverySelector() async throws {
        let workspace = await workspace()
        let session = workspace.current.session
        let id = try await addWarmLayer(in: workspace)

        /// Sets `profile` (and any other settings) on the layer, checking that it is one undo step.
        func set(_ settings: [String: Value]) async throws -> [String: Value] {
            let undoCount = session.history.undoCount
            let result = try await call("set_adjustment", ["layer": .string(id.uuidString), "settings": .object(settings)], in: workspace)
            #expect(session.history.undoCount == undoCount + 1 && session.history.undoName == "Edit Adjustment")
            return result
        }

        let film = try await set(["profile": "Synthetic/Film ProPhoto"])
        #expect(referenceName(film) == "Film ProPhoto" && amount(film) == 140)
        #expect(adjustment(session, id)?.profile.reference?.digest == (try digest(ofFixture: "profile-film-prophoto.xmp")))

        let linear = try await set(["profile": .string("00000000000000000000000000000006".lowercased())])
        #expect(referenceName(linear) == "Hue Linear" && amount(linear) == 140)
        #expect(adjustment(session, id)?.profile.reference?.group == "Synthetic")

        // A profile without a group leaves none behind from the one it replaces.
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let loose = uniqueProfile("Loose Look", group: nil)
        try loose.write(to: folder.appendingPathComponent("Loose Look.xmp"))
        let imported = try await call("import_profile", ["path": .string(folder.appendingPathComponent("Loose Look.xmp").path)], in: workspace)
        let looseID = try #require(entries(imported, "imported").first?["id"]?.stringValue)
        #expect(ProfileRegistry.shared.profile(ProfileDigest(of: loose)) == nil)
        let switched = try await set(["profile": .string(looseID)])
        #expect(referenceName(switched) == "Loose Look" && profileSettings(switched)["reference"]?.objectValue?["group"] == nil)
        #expect(adjustment(session, id)?.profile.reference?.group == nil)
        #expect(ProfileRegistry.shared.profile(ProfileDigest(of: loose)) != nil)

        let noAmount = try digest(ofFixture: "profile-no-amount.xmp")
        let fixed = try await set(["profile": .string(noAmount.hex)])
        #expect(referenceName(fixed) == "No Amount" && amount(fixed) == 100)

        let none = try await set(["profile": .null])
        #expect(profileSettings(none)["reference"] == nil && amount(none) == 100)
        #expect(adjustment(session, id)?.profile.reference == nil)
    }

    @Test func profileErrors() async throws {
        let workspace = await workspace()
        let session = workspace.current.session
        let id = try await addWarmLayer(in: workspace)
        let settings = adjustment(session, id)
        let undoCount = session.history.undoCount
        func set(_ value: [String: Value], expectError code: String) async throws -> [String: Value] {
            try await call("set_adjustment", ["layer": .string(id.uuidString), "settings": .object(value)], in: workspace, expectError: code)
        }

        let missing = try await set(["profile": "Nope"], expectError: "not_found")
        #expect(details(missing)["field"]?.stringValue == "profile")

        // Two profiles with one name, in different groups.
        let twins = try ["A", "B"].map { group in
            let file = ProfileTestSupport.locations.adobeUser.appendingPathComponent("Twin Look \(group) \(UUID().uuidString).xmp")
            try uniqueProfile("Twin Look", group: group).write(to: file)
            return file
        }
        // `refresh` finds profiles installed since the last scan.
        let listed = try await call("list_profiles", ["query": "Twin Look", "refresh": true], in: workspace)
        #expect(names(listed) == ["Twin Look", "Twin Look"])
        let ambiguous = try await set(["profile": "Twin Look"], expectError: "ambiguous")
        let candidates = (details(ambiguous)["candidates"]?.arrayValue ?? []).compactMap(\.objectValue)
        #expect(candidates.count == 2 && details(ambiguous)["field"]?.stringValue == "profile")
        #expect(Set(candidates.compactMap { $0["group"]?.stringValue }) == ["A", "B"])
        #expect(candidates.allSatisfy { $0["name"]?.stringValue == "Twin Look" && $0["source"]?.stringValue == "adobe_user"
            && $0["id"]?.stringValue?.count == 64 })
        for file in twins { try FileManager.default.removeItem(at: file) }
        _ = await ProfileLibrary.shared.index(refresh: true)

        let raw = try await set(["profile": "Raw Only"], expectError: "unsupported")
        #expect(details(raw)["reason"]?.stringValue == "raw_only" && details(raw)["field"]?.stringValue == "profile")
        #expect(raw["error"]?.objectValue?["message"]?.stringValue == "“Raw Only” can't be applied: \(ProfileError.rawOnly.localizedDescription)")

        let number = try await set(["profile": 5], expectError: "invalid_argument")
        #expect(details(number)["field"]?.stringValue == "profile")
        let fixedAmount = try await set(["profile": "No Amount", "amount": 150], expectError: "invalid_argument")
        #expect(details(fixedAmount)["field"]?.stringValue == "amount")
        let both = try await set(["profile": "Warm AdobeRGB", "profile_settings": ["reference": .null]], expectError: "invalid_argument")
        #expect(details(both)["field"]?.stringValue == "profile")
        let flat = try await set(["profile": "Warm AdobeRGB", "profile_settings": 5], expectError: "invalid_argument")
        #expect(details(flat)["field"]?.stringValue == "profile_settings")
        #expect(adjustment(session, id) == settings && session.history.undoCount == undoCount)

        // A profile that can't be found adds nothing.
        let layers = session.document?.layers.count
        try await call("add_adjustment_layer", ["kind": "profile", "settings": ["profile": "Nope"]], in: workspace, expectError: "not_found")
        #expect(session.document?.layers.count == layers && session.history.undoCount == undoCount)
    }

    @Test func aFailedProfileLayerLeavesTheSelectionAndMaskTargetAsTheyWere() async throws {
        let workspace = await workspace()
        let session = workspace.current.session
        try await call("add_layer_mask", ["layer": "Layer 1"], in: workspace)
        let active = session.activeLayerID
        #expect(session.isMaskSelected)
        let document = session.document
        let undoCount = session.history.undoCount

        // The profile loads, but its amount can't change: the layer is added, then taken back.
        let result = try await call("add_adjustment_layer",
                                    ["kind": "profile", "settings": ["profile": "No Amount", "amount": 150]], in: workspace,
                                    expectError: "invalid_argument")
        #expect(details(result)["field"]?.stringValue == "amount")
        #expect(session.document == document && session.activeLayerID == active && session.isMaskSelected)
        #expect(session.history.undoCount == undoCount)

        // A blank name is refused rather than ignored.
        let blank = try await call("add_adjustment_layer", ["kind": "profile", "name": "   "], in: workspace, expectError: "invalid_argument")
        #expect(details(blank)["field"]?.stringValue == "name")
        #expect(session.document == document && session.history.undoCount == undoCount)
    }

    /// A Profile layer is named after its profile unless the call names it; one without a profile yet is "Profile".
    @Test func profileLayersAreNamedAfterTheirProfile() async throws {
        let workspace = await workspace()
        let named = try await call("add_adjustment_layer",
                                   ["kind": "profile", "name": "Grade", "settings": ["profile": "Warm AdobeRGB"]], in: workspace)
        #expect(named["name"]?.stringValue == "Grade")
        let empty = try await call("add_adjustment_layer", ["kind": "profile"], in: workspace)
        #expect(empty["name"]?.stringValue == "Profile")
        let none = try await call("add_adjustment_layer", ["kind": "profile", "settings": ["profile": .null]], in: workspace)
        #expect(none["name"]?.stringValue == "Profile")
        // Naming follows the profile only when it is added: changing it later leaves the name alone, as in the app.
        let id = try #require(empty["layer_id"]?.stringValue)
        try await call("set_adjustment", ["layer": .string(id), "settings": ["profile": "Warm AdobeRGB"]], in: workspace)
        #expect(workspace.current.session.document?.layers.first { $0.id.uuidString == id }?.name == "Profile")
    }

    /// Every way a profile call fails says what to do next.
    @Test func profileFailuresCarryAHint() async throws {
        let workspace = await workspace()
        let id = try await addWarmLayer(in: workspace)
        func hint(_ result: [String: Value]) -> String { result["error"]?.objectValue?["hint"]?.stringValue ?? "" }
        func set(_ value: [String: Value], expectError code: String) async throws -> [String: Value] {
            try await call("set_adjustment", ["layer": .string(id.uuidString), "settings": .object(value)], in: workspace, expectError: code)
        }

        let limit = try await call("list_profiles", ["limit": 0], in: workspace, expectError: "invalid_argument")
        #expect(!hint(limit).isEmpty, "\(limit)")
        let offset = try await call("list_profiles", ["offset": -1], in: workspace, expectError: "invalid_argument")
        #expect(!hint(offset).isEmpty, "\(offset)")
        let flat = try await set(["profile": "Warm AdobeRGB", "profile_settings": 5], expectError: "invalid_argument")
        #expect(!hint(flat).isEmpty, "\(flat)")
        let both = try await set(["profile": "Warm AdobeRGB", "profile_settings": ["reference": .null]], expectError: "invalid_argument")
        #expect(!hint(both).isEmpty, "\(both)")
        let raw = try await set(["profile": "Raw Only"], expectError: "unsupported")
        #expect(hint(raw).contains("list_profiles"), "\(raw)")

        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let preset = folder.appendingPathComponent("Preset.xmp")
        try ProfileFixture.xmp(presetType: "Normal").write(to: preset)
        let refused = try await call("import_profile", ["path": .string(preset.path)], in: workspace, expectError: "invalid_argument")
        #expect(!hint(refused).isEmpty, "\(refused)")
    }

    /// `profile` belongs to Profile layers: any other kind rejects it as the unknown field it is, changing nothing.
    @Test func profileOnAnotherKindIsAnUnknownField() async throws {
        let workspace = await workspace()
        let session = workspace.current.session
        let levels = try await call("add_adjustment_layer", ["kind": "levels"], in: workspace)
        let id = try #require(levels["layer_id"]?.stringValue)
        let document = session.document
        let undoCount = session.history.undoCount

        let set = try await call("set_adjustment", ["layer": .string(id), "settings": ["profile": "Warm AdobeRGB"]], in: workspace,
                                 expectError: "invalid_argument")
        #expect(details(set)["field"]?.stringValue == "profile", "\(set)")
        let added = try await call("add_adjustment_layer", ["kind": "levels", "settings": ["profile": "Warm AdobeRGB"]], in: workspace,
                                   expectError: "invalid_argument")
        #expect(details(added)["field"]?.stringValue == "profile", "\(added)")
        #expect(session.document == document && session.history.undoCount == undoCount)
    }

    @Test func getDocumentShowsProfileSettings() async throws {
        let workspace = await workspace()
        let id = try await addWarmLayer(in: workspace)
        let document = try await call("get_document", ["detail": "full"], in: workspace)
        let layers = (document["document"]?.objectValue?["layers"]?.arrayValue ?? []).compactMap(\.objectValue)
        let layer = try #require(layers.first { $0["id"]?.stringValue == id.uuidString })
        // The kind as set_adjustment names it, not the app's "Profile".
        #expect(layer["adjustment_kind"]?.stringValue == "profile")
        let settings = try #require(layer["adjustment"]?.objectValue?["profile_settings"]?.objectValue)
        #expect(settings["reference"]?.objectValue?["name"]?.stringValue == "Warm AdobeRGB" && MCPValues.number(settings["amount"]) == 140)
    }

    /// A Profile layer follows the rule every adjustment does: get_layer and get_document report its settings exactly
    /// as add_adjustment_layer and set_adjustment return them, and sending them back changes nothing.
    @Test func aProfileLayerReadsBackInTheFormSetAdjustmentTakes() async throws {
        let workspace = await workspace()
        let session = workspace.current.session
        let added = try await call("add_adjustment_layer",
                                   ["kind": "profile", "settings": ["profile": "Warm AdobeRGB", "amount": 140]], in: workspace)
        let id = try #require(added["layer_id"]?.stringValue)
        let described = try await call("get_layer", ["layer": .string(id)], in: workspace)
        let layer = try #require(described["layer"]?.objectValue)
        #expect(layer["adjustment_kind"]?.stringValue == "profile")
        let settings = try #require(layer["adjustment"])
        #expect(settings == added["settings"], "\(settings)")
        #expect(settings.objectValue?.keys.sorted() == ["profile_settings"])

        let document = try await call("get_document", ["detail": "full"], in: workspace)
        let listed = try #require(document["document"]?.objectValue?["layers"]?.arrayValue?
            .compactMap(\.objectValue).first { $0["id"]?.stringValue == id })
        #expect(listed["adjustment_kind"] == layer["adjustment_kind"] && listed["adjustment"] == settings)

        // Sending back what was read changes nothing.
        let unchanged = try await call("set_adjustment", ["layer": .string(id), "settings": settings], in: workspace)
        #expect(unchanged["undo"]?.objectValue?["recorded"] == .bool(false), "\(unchanged)")
        #expect(unchanged["settings"] == settings)

        // Read, change the amount, send the whole thing back.
        var profile = try #require(settings.objectValue?["profile_settings"]?.objectValue)
        profile["amount"] = 60
        let set = try await call("set_adjustment", ["layer": .string(id), "settings": ["profile_settings": .object(profile)]],
                                 in: workspace)
        #expect(set["undo"]?.objectValue?["recorded"] == .bool(true), "\(set)")
        let uuid = try #require(UUID(uuidString: id))
        #expect(adjustment(session, uuid)?.profile.amount == 60)
        #expect(adjustment(session, uuid)?.profile.reference?.name == "Warm AdobeRGB")
        let again = try await call("get_layer", ["layer": .string(id)], in: workspace)
        #expect(again["layer"]?.objectValue?["adjustment"] == set["settings"])
    }
}

/// Stands in for the listing a folder-access probe runs: answers per folder name (an empty listing by default),
/// records each folder listed, and holds `hang` listings until `release()`, the way macOS holds a read while its
/// permission prompt is up.
private final class ProfileImportLister: @unchecked Sendable {
    enum Answer {
        case folders([String])
        case failure(any Error)
        case hang
    }

    private let lock = NSLock()
    private let answers: [String: Answer]
    private var listedNames: [String] = []
    private let gate = DispatchSemaphore(value: 0)

    init(_ answers: [String: Answer] = [:]) {
        self.answers = answers
    }

    /// The names of the folders listed so far, in order.
    var listed: [String] { lock.withLock { listedNames } }

    func list(_ directory: URL) throws -> [String] {
        lock.withLock { listedNames.append(directory.lastPathComponent) }
        switch answers[directory.lastPathComponent] ?? .folders([]) {
        case .folders(let names):
            return names
        case .failure(let error):
            throw error
        case .hang:
            gate.wait()
            gate.signal() // Let any other held listing through too.
            return []
        }
    }

    /// Lets every held listing finish, as if the owner answered.
    func release() {
        gate.signal()
    }
}
