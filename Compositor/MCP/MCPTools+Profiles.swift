import Foundation
import MCP

// MARK: - Profiles

extension MCPToolRegistry {
    static let profileTools: [MCPToolEntry] = [
        tool("list_profiles", title: "List profiles",
             description: "Lists the Lightroom and Camera Raw profiles Compositor can apply as a Profile adjustment layer, installed and imported, with id, group, fidelity and hidden counts. Pass an id, Adobe UUID, \"Group/Name\" or name as 'profile' to add_adjustment_layer (kind profile) or set_adjustment.",
             properties: [
                 "query": MCPSchema.str("Text to find in names, groups and files."),
                 "group": MCPSchema.str("Only this group."),
                 "include_unusable": MCPSchema.bool("Also list profiles it can't apply, with the reason.",
                                                    default: false),
                 "refresh": MCPSchema.bool("Scan the profile folders again.", default: false),
                 "limit": MCPSchema.int("Most profiles to return.", min: 1, max: 500, default: 100),
                 "offset": MCPSchema.int("Profiles to skip, for paging.", min: 0, default: 0),
             ],
             targetsDocument: false, effect: .readOnly, handler: listProfiles),
        tool("import_profile", title: "Import profile",
             description: "Imports Lightroom or Camera Raw profiles (.xmp files with PresetType Look), a file or a folder searched recursively (up to 1,000 files), into Compositor's profile library. Files it refuses are listed in skipped with a code.",
             properties: [
                 "path": MCPSchema.str("A .xmp profile or a folder of them."),
             ],
             required: ["path"], targetsDocument: false, effect: .additive(idempotent: true), handler: importProfile),
    ]

    // MARK: Handlers

    static func listProfiles(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let query = try ctx.args.optionalString("query")
        let group = try ctx.args.optionalString("group")
        let includeUnusable = try ctx.args.bool("include_unusable", default: false)
        let refresh = try ctx.args.bool("refresh", default: false)
        let limit = try ctx.args.int("limit", default: 100)
        let offset = try ctx.args.int("offset", default: 0)
        guard (1...500).contains(limit) else {
            throw MCPToolError(.invalidArgument, "limit must be 1–500.", hint: "Page through more with offset.",
                               details: ["field": .string("limit")])
        }
        guard offset >= 0 else {
            throw MCPToolError(.invalidArgument, "offset must be 0 or more.", hint: "Leave it out (0) for the first page.",
                               details: ["field": .string("offset")])
        }
        let index = await ProfileLibrary.shared.index(refresh: refresh)
        let matches = index.search(query: query, group: group, includeUnusable: includeUnusable)
        return ok([
            "profiles": .array(matches.dropFirst(offset).prefix(limit).map(profileEntry)),
            "total": .int(matches.count),
            "offset": .int(offset),
            "groups": .array(index.groups.map { .object(["name": .string($0.name), "count": .int($0.count)]) }),
            "hidden": .object([
                "raw_only": .int(index.hidden.rawOnly),
                "camera_specific": .int(index.hidden.cameraSpecific),
                "unsupported": .int(index.hidden.unsupported),
            ]),
        ])
    }

    /// The most `.xmp` files one `import_profile` call reads from a folder; past it the result says `truncated`.
    nonisolated static let profileImportFileLimit = 1_000
    /// The most skipped files an `import_profile` result lists; `skipped_count` counts them all.
    nonisolated static let profileImportSkippedLimit = 100

    static func importProfile(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        // Access first: any look at a file in a protected folder can wait on a macOS permission prompt. A refusal is
        // io_error folder_access_denied, a prompt still waiting busy folder_access_pending.
        let url = try await MCPPaths.resolveReachable(try ctx.args.string("path"), mustExist: true)
        // File or folder: looked at only now that the access check has let the path through.
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard isDirectory.boolValue else {
            let report = await ProfileLibrary.shared.importProfiles(at: [url])
            if let failure = report.skipped.first {
                let error = failure.error
                let details: [String: Value] = ["code": .string(profileErrorCode(error)), "path": .string(failure.url.path)]
                switch error {
                case .unreadable, .writeFailed:
                    throw MCPToolError(.ioError, error.localizedDescription,
                                       hint: "Check that the file can be read and the disk isn't full, then retry.", details: details)
                default:
                    throw MCPToolError(.invalidArgument, error.localizedDescription, hint: importRefusalHint(error), details: details)
                }
            }
            return importResult(report, truncated: false)
        }
        let found = try await profileImportFiles(in: url)
        return importResult(await ProfileLibrary.shared.importProfiles(at: found.files), truncated: found.truncated)
    }

    /// `import_profile`'s result, listing at most `profileImportSkippedLimit` skipped files.
    private static func importResult(_ report: ProfileImportReport, truncated: Bool) -> CallTool.Result {
        ok([
            "imported": .array(report.imported.map(profileEntry)),
            "already_imported": .array(report.alreadyImported.map(profileEntry)),
            "skipped": .array(report.skipped.prefix(profileImportSkippedLimit).map { failure in
                .object([
                    "path": .string(failure.url.path),
                    "code": .string(profileErrorCode(failure.error)),
                    "message": .string(failure.error.localizedDescription),
                ])
            }),
            "skipped_count": .int(report.skipped.count),
            "truncated": .bool(truncated),
        ])
    }

    /// The `.xmp` files `import_profile` reads from `folder`, at any depth: regular files only, never through a
    /// symbolic link or inside a package, and at most `limit`, in bounded time (`MCPPaths.list`); `truncated` when
    /// the walk stopped early. `folder` must come from `MCPPaths.resolveReachable`.
    ///
    /// Before walking, each macOS-protected root the walk would enter — `~/Documents` when `folder` is `~`, each
    /// iCloud or cloud storage folder, each volume — is probed through `FolderAccess.activeChecker`, each within
    /// `timeout`. A root still waiting on a permission prompt fails the call with `busy` (`details.code
    /// "folder_access_pending"`) before anything is walked, rather than leaving it out of the import unannounced. The
    /// walk itself enters no protected folder macOS hasn't let Compositor into (`MCPPaths.list` checks each first),
    /// so a refused one is left out.
    static func profileImportFiles(in folder: URL, timeout: Duration = FolderAccess.defaultTimeout,
                                   limit: Int = profileImportFileLimit) async throws -> (files: [URL], truncated: Bool) {
        let checker = FolderAccess.activeChecker
        for root in protectedRoots(inside: folder, checker: checker) {
            let access = await checker.probeAccess(root, timeout: timeout)
            guard access.state == .notDetermined || !access.pendingFolders.isEmpty, let location = checker.locations[root] else {
                continue
            }
            let waiting = access.pendingFolders.first.map { location.appendingPathComponent($0, isDirectory: true) } ?? location
            let error = FolderAccessError(reason: .pending, root: root, path: waiting.path)
            throw MCPToolError(.busy, error.localizedDescription,
                               hint: error.hint + " Or import from a folder that doesn't hold \(root.displayName).",
                               details: ["code": .string(error.code), "path": .string(waiting.path), "root": .string(root.rawValue)])
        }
        // Off the main actor (a recursive walk of a large tree takes a while), in this task, so it checks access with
        // the same checker and stops when the call is cancelled.
        let listing = try await MCPPaths.list(in: folder, recursive: true, extensions: ["xmp"], limit: limit)
        let paths = listing.entries.map(\.path)
        // Only regular files: a link to a .xmp file could lead anywhere, including into a protected folder. Looking at
        // each (without following links) stays inside the folders the walk checked.
        let files = await Task.detached(priority: .userInitiated) {
            paths.map { URL(fileURLWithPath: $0) }.filter { url in
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true
            }
        }.value
        return (files, listing.truncated)
    }

    /// The protected roots on this Mac that a walk of `folder` would enter: those inside it, and `folder` itself when
    /// it is a root guarded folder by folder (cloud storage, `/Volumes`). A root guarded as a whole that `folder` is
    /// or lies in was checked with the path. Compares real paths, ignoring case and the Data volume's
    /// `/System/Volumes/Data` spelling; `/System` and `/System/Volumes` hold that volume, so like `/` they hold every
    /// root. A root itself is only looked at to see that it exists, never read. Resolving `folder`'s real path looks
    /// at it, so it must have been checked for access first; a root's parent (`~`, `~/Library`, `/`) is in no root.
    static func protectedRoots(inside folder: URL, checker: FolderAccess.Checker) -> [ProtectedRoot] {
        func realPath(_ path: String) -> String {
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        /// A path's components as the Data volume sees them: `/System/Volumes/Data/Users` is `/Users`, and a folder
        /// above the Data volume (`/System`, `/System/Volumes`) is `/`, since a walk of it reaches all of `/`.
        func key(_ path: String) -> [String] {
            let components = path.split(separator: "/").map { $0.lowercased() }.filter { $0 != "." }
            let dataVolume = ["system", "volumes", "data"]
            if components.starts(with: dataVolume) { return Array(components.dropFirst(dataVolume.count)) }
            return dataVolume.starts(with: components) ? [] : components
        }
        let folderKey = key(realPath(folder.path))
        return ProtectedRoot.allCases.filter { root in
            guard let location = checker.url(of: root) else { return false }
            let parent = realPath(location.deletingLastPathComponent().path)
            let rootKey = key((parent as NSString).appendingPathComponent(location.lastPathComponent))
            return rootKey == folderKey ? root.guardsEachFolder : rootKey.starts(with: folderKey)
        }
    }

    // MARK: The profile key

    /// For kind .profile: replaces a `profile` key (selector string or null) with `profile_settings.reference`, loading and
    /// registering the profile; adds `amount: 100` when the profile has no Amount and no amount was given.
    /// Other kinds and settings without `profile` pass through unchanged.
    static func resolvingProfileShorthand(_ settings: [String: Value]?, kind: AdjustmentKind) async throws -> [String: Value]? {
        guard kind == .profile, var settings, let selector = settings.removeValue(forKey: "profile") else { return settings }
        let given = settings["profile_settings"]
        guard given == nil || given?.objectValue != nil else {
            throw MCPToolError(.invalidArgument, "'profile_settings' must be an object.",
                               hint: "Pass e.g. {\"amount\": 80}, or choose the profile with 'profile' alone.",
                               details: ["field": .string("profile_settings")])
        }
        var profileSettings = given?.objectValue ?? [:]
        guard profileSettings["reference"] == nil else {
            throw MCPToolError(.invalidArgument, "Pass either profile or profile_settings.reference, not both.",
                               hint: "Choose the profile with 'profile' alone; profile_settings can still set amount.",
                               details: ["field": .string("profile")])
        }
        let reference: Value
        switch selector {
        case .null:
            reference = .null
        case .string(let text):
            let summary: ProfileSummary
            do {
                summary = try await ProfileLibrary.shared.resolve(text)
            } catch let error as ProfileSelectorError {
                throw profileToolError(error, selector: text)
            }
            let loaded: LoadedProfile
            do {
                loaded = try await ProfileLibrary.shared.load(summary)
            } catch let error as ProfileError {
                let details: [String: Value] = ["code": .string(profileErrorCode(error)), "field": .string("profile")]
                switch error {
                case .unreadable, .digestMismatch:
                    throw MCPToolError(.ioError, error.localizedDescription, hint: "Call list_profiles with refresh: true.", details: details)
                default:
                    throw MCPToolError(.invalidArgument, error.localizedDescription,
                                       hint: "Choose another profile (list_profiles), or import a fresh copy with import_profile.", details: details)
                }
            }
            // Every member, so none is left over from the reference this one replaces (patches merge objects).
            let value = ProfileReference(loaded)
            reference = .object([
                "digest": .string(value.digest.hex),
                "uuid": value.uuid.map(Value.string) ?? .null,
                "name": .string(value.name),
                "group": value.group.map(Value.string) ?? .null,
            ])
            if !loaded.profile.support.contains(.amount), settings["amount"] == nil, profileSettings["amount"] == nil {
                settings["amount"] = .int(100)
            }
        default:
            throw MCPToolError(.invalidArgument, "'profile' must be a profile name or id, or null.",
                               hint: "list_profiles shows the profiles Compositor can apply.", details: ["field": .string("profile")])
        }
        profileSettings["reference"] = reference
        settings["profile_settings"] = .object(profileSettings)
        return settings
    }

    // MARK: Reporting

    /// A profile as `list_profiles` and `import_profile` report it.
    static func profileEntry(_ summary: ProfileSummary) -> Value {
        var entry: [String: Value] = [
            "id": .string(summary.digest.hex),
            "uuid": .string(summary.identity.uuid),
            "name": .string(summary.name),
            "group": .string(summary.group),
            "source": .string(summary.source.rawValue),
            "supports_amount": .bool(summary.supportsAmount),
            "monochrome": .bool(summary.convertsToGrayscale),
            "tables": .string(tablesName(summary.tables)),
            "usable": .bool(summary.usability == .usable),
        ]
        // A profile that came from a document has no file.
        if let path = summary.path { entry["path"] = .string(path) }
        switch summary.fidelity {
        case .exact:
            entry["fidelity"] = .string("exact")
            entry["ignored_settings"] = .array([])
        case .approximate(let ignored):
            entry["fidelity"] = .string("approximate")
            entry["ignored_settings"] = .array(ignored.map(Value.string))
        }
        if let reason = usabilityReason(summary.usability), let error = summary.usability.error {
            entry["reason"] = .string(reason)
            entry["reason_detail"] = .string(error.localizedDescription)
        }
        return .object(entry)
    }

    static func profileToolError(_ error: ProfileSelectorError, selector: String) -> MCPToolError {
        switch error {
        case .notFound(let text):
            return MCPToolError(.notFound, "No profile matches '\(text)'.",
                                hint: "list_profiles shows the profiles Compositor can apply; pass an id, an Adobe UUID, \"Group/Name\" or a name.",
                                details: ["field": .string("profile")])
        case .ambiguous(let candidates):
            return MCPToolError(.ambiguous, "'\(selector)' matches \(candidates.count) profiles.",
                                hint: "Pass an id from details.candidates, or \"Group/Name\".",
                                details: [
                                    "field": .string("profile"),
                                    "candidates": .array(candidates.map { summary in
                                        .object([
                                            "id": .string(summary.digest.hex),
                                            "name": .string(summary.name),
                                            "group": .string(summary.group),
                                            "source": .string(summary.source.rawValue),
                                        ])
                                    }),
                                ])
        case .unusable(let summary):
            // `resolve` reports only a profile that isn't usable, so both are there.
            let detail = summary.usability.error?.localizedDescription ?? ""
            return MCPToolError(.unsupported, "“\(summary.name)” can't be applied: \(detail)",
                                hint: "Choose a profile list_profiles shows: it lists only those Compositor can apply.",
                                details: ["field": .string("profile"), "reason": .string(usabilityReason(summary.usability) ?? "unsupported")])
        }
    }

    /// What to do about a single file `import_profile` refused as `error`.
    static func importRefusalHint(_ error: ProfileError) -> String {
        switch error {
        case .rawOnly, .cameraSpecific, .unsupported:
            "Compositor applies creative profiles made for rendered images; list_profiles shows those it has."
        case .tooLarge:
            "Profiles are at most 4 MB, and those Lightroom and Camera Raw make are far smaller: check that the path names a profile's .xmp file."
        default:
            "Pass a Lightroom or Camera Raw profile: a .xmp file with PresetType Look, as Lightroom exports or installs them."
        }
    }

    static func profileErrorCode(_ error: ProfileError) -> String {
        switch error {
        case .notAProfile: "not_a_profile"
        case .rawOnly: "raw_only"
        case .cameraSpecific: "camera_specific"
        case .unsupported: "unsupported"
        case .tooLarge: "too_large"
        case .malformed: "malformed"
        case .unreadable: "unreadable"
        case .digestMismatch: "changed"
        case .notLoaded: "not_loaded"
        case .writeFailed: "write_failed"
        }
    }

    /// Why a profile can't be applied, as `reason` names it; nil when it can.
    static func usabilityReason(_ usability: ProfileUsability) -> String? {
        switch usability {
        case .usable: nil
        case .rawOnly: "raw_only"
        case .cameraSpecific: "camera_specific"
        case .unsupported: "unsupported"
        }
    }

    /// The tables a profile names: "look", "rgb", "look+rgb" or "none".
    static func tablesName(_ tables: ProfileTables) -> String {
        let names = [(ProfileTables.look, "look"), (.rgb, "rgb")].filter { tables.contains($0.0) }.map(\.1)
        return names.isEmpty ? "none" : names.joined(separator: "+")
    }
}
