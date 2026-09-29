import Foundation

/// Where a listed profile file lives.
nonisolated enum ProfileSource: String, Codable, Hashable, Sendable {
    case adobe, adobeUser = "adobe_user", imported, document

    /// When one profile is in several places, the lowest rank is listed.
    fileprivate var rank: Int {
        switch self {
        case .adobe: 0
        case .adobeUser: 1
        case .imported: 2
        case .document: 3
        }
    }
}

/// The tables a profile names (whether or not the file embeds them).
nonisolated struct ProfileTables: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int
    static let look = ProfileTables(rawValue: 1)
    static let rgb = ProfileTables(rawValue: 2)
}

/// What the profile browser and MCP list for one profile file, read without decoding its tables.
nonisolated struct ProfileSummary: Identifiable, Hashable, Sendable {
    var id: ProfileDigest { digest }
    let digest: ProfileDigest
    let identity: ProfileIdentity
    let name: String
    let group: String
    /// crs:SortName, else name.
    let sortKey: String
    let cluster: String?
    let version: String?
    let source: ProfileSource
    /// Absolute file path; nil for .document.
    let path: String?
    let fileSize: Int
    let supportsAmount: Bool
    let convertsToGrayscale: Bool
    let tables: ProfileTables
    let usability: ProfileUsability
    let fidelity: ProfileFidelity

    init(profile: AdobeProfile, digest: ProfileDigest, source: ProfileSource, path: String?, fileSize: Int, group: String) {
        self.digest = digest
        identity = profile.identity
        name = profile.name
        self.group = group
        sortKey = profile.sortName ?? profile.name
        cluster = profile.cluster
        version = profile.version
        self.source = source
        self.path = path
        self.fileSize = fileSize
        supportsAmount = profile.support.contains(.amount)
        convertsToGrayscale = profile.convertToGrayscale
        var tables: ProfileTables = []
        if profile.lookTableFingerprint != nil { tables.insert(.look) }
        if profile.rgbTableFingerprint != nil { tables.insert(.rgb) }
        self.tables = tables
        usability = profile.usability
        fidelity = profile.fidelity
    }

    /// A registered profile no library folder has (it came from a document): source .document, group from crs:Group or "Other".
    init(loaded: LoadedProfile) {
        self.init(profile: loaded.profile, digest: loaded.digest, source: .document, path: nil, fileSize: loaded.data.count,
                  group: loaded.profile.group ?? "Other")
    }
}

nonisolated struct ProfileGroupCount: Hashable, Sendable {
    let name: String
    let count: Int
}

/// Profiles the library found but doesn't offer, by why.
nonisolated struct ProfileHiddenCounts: Hashable, Sendable {
    var rawOnly = 0, cameraSpecific = 0, unsupported = 0
    var total: Int { rawOnly + cameraSpecific + unsupported }
}

/// One scan of the library folders.
nonisolated struct ProfileIndex: Sendable {
    static let empty = ProfileIndex(profiles: [], groups: [], hidden: ProfileHiddenCounts())

    /// Deduplicated, every usability, display order.
    let profiles: [ProfileSummary]
    /// Usable profiles only, display order.
    let groups: [ProfileGroupCount]
    /// Deduplicated unusable profiles (unparseable Look files count as unsupported).
    let hidden: ProfileHiddenCounts

    var usable: [ProfileSummary] { profiles.filter { $0.usability == .usable } }

    func summary(for digest: ProfileDigest) -> ProfileSummary? {
        profiles.first { $0.digest == digest }
    }

    /// A trimmed, non-empty query matches a case- and diacritic-insensitive substring of the name, group or file name;
    /// `group` must equal the summary's group. Display order is kept.
    func search(query: String?, group: String?, includeUnusable: Bool) -> [ProfileSummary] {
        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return profiles.filter { summary in
            guard includeUnusable || summary.usability == .usable else { return false }
            if let group, summary.group != group { return false }
            guard !query.isEmpty else { return true }
            var fields = [summary.name, summary.group]
            if let path = summary.path { fields.append(URL(fileURLWithPath: path).lastPathComponent) }
            return fields.contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

nonisolated extension ProfileIndex {
    /// Deduplicates the scanned summaries, orders them and counts the groups and the hidden profiles.
    fileprivate init(scanned: [ProfileSummary], unparseable: Int) {
        var kept: [ProfileIdentity: ProfileSummary] = [:]
        for summary in scanned {
            if let current = kept[summary.identity], !Self.prefers(summary, over: current) { continue }
            kept[summary.identity] = summary
        }
        let profiles = kept.values.sorted(by: Self.displayOrder)

        var counts: [String: Int] = [:]
        var hidden = ProfileHiddenCounts(unsupported: unparseable)
        for summary in profiles {
            switch summary.usability {
            case .usable: counts[summary.group, default: 0] += 1
            case .rawOnly: hidden.rawOnly += 1
            case .cameraSpecific: hidden.cameraSpecific += 1
            case .unsupported: hidden.unsupported += 1
            }
        }
        let groups = counts.keys.sorted { Self.compare($0, $1) == .orderedAscending }
            .map { ProfileGroupCount(name: $0, count: counts[$0, default: 0]) }
        self.init(profiles: profiles, groups: groups, hidden: hidden)
    }

    /// The lowest source rank, then the highest version, then the smallest path.
    private static func prefers(_ candidate: ProfileSummary, over current: ProfileSummary) -> Bool {
        if candidate.source.rank != current.source.rank { return candidate.source.rank < current.source.rank }
        let versions = compareVersions(candidate.version, current.version)
        if versions != .orderedSame { return versions == .orderedDescending }
        return (candidate.path ?? "") < (current.path ?? "")
    }

    /// Dot-separated numeric components, missing or non-numeric ones as 0 ("10.2" > "9.9"); nil is lowest.
    private static func compareVersions(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
        guard let lhs, let rhs else {
            if lhs == nil, rhs == nil { return .orderedSame }
            return lhs == nil ? .orderedAscending : .orderedDescending
        }
        func components(_ version: String) -> [Int] {
            version.split(separator: ".", omittingEmptySubsequences: false)
                .map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        }
        let left = components(lhs), right = components(rhs)
        for position in 0 ..< max(left.count, right.count) {
            let l = position < left.count ? left[position] : 0
            let r = position < right.count ? right[position] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Group, then sort key, then name, each as Finder sorts; then digest.
    private static func displayOrder(_ lhs: ProfileSummary, _ rhs: ProfileSummary) -> Bool {
        for (left, right) in [(lhs.group, rhs.group), (lhs.sortKey, rhs.sortKey), (lhs.name, rhs.name)] {
            let order = compare(left, right)
            if order != .orderedSame { return order == .orderedAscending }
        }
        return lhs.digest < rhs.digest
    }

    /// `localizedStandardCompare`, with strings it considers equal told apart by code point so that the order is total.
    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let order = lhs.localizedStandardCompare(rhs)
        guard order == .orderedSame, lhs != rhs else { return order }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }
}

nonisolated struct ProfileImportFailure: Equatable, Sendable {
    let url: URL
    let error: ProfileError
}

nonisolated struct ProfileImportReport: Sendable {
    var imported: [ProfileSummary] = []
    var alreadyImported: [ProfileSummary] = []
    var skipped: [ProfileImportFailure] = []
}

nonisolated enum ProfileSelectorError: Error, Equatable, Sendable {
    case notFound(String)
    case ambiguous([ProfileSummary])
    case unusable(ProfileSummary)
}

/// The Lightroom and Camera Raw profiles installed on this Mac plus those imported into Compositor: found, listed,
/// imported, resolved by name or digest, and loaded for rendering.
actor ProfileLibrary {
    static let shared = ProfileLibrary()

    nonisolated struct Locations: Equatable, Sendable {
        /// /Library/Application Support/Adobe/CameraRaw/Settings
        var adobeSystem: URL
        /// ~/Library/Application Support/Adobe/CameraRaw/Settings
        var adobeUser: URL
        /// ~/Library/Application Support/Compositor/Profiles
        var imported: URL

        /// The real folders (the app is not sandboxed). Reading this creates nothing.
        static var defaults: Locations {
            let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            return Locations(
                adobeSystem: URL(fileURLWithPath: "/Library/Application Support/Adobe/CameraRaw/Settings", isDirectory: true),
                adobeUser: applicationSupport.appendingPathComponent("Adobe/CameraRaw/Settings", isDirectory: true),
                imported: applicationSupport.appendingPathComponent("Compositor/Profiles", isDirectory: true))
        }

        /// Test seam, like `MCPSettings.agentRootOverride`: tests (MCP) install temporary folders here so nothing reads
        /// or writes the real libraries. Always nil in production.
        ///
        /// `nonisolated(unsafe)`: global mutable state with no lock, sound only because tests write it before any
        /// library code reads it.
        nonisolated(unsafe) static var override: Locations?

        static var standard: Locations { override ?? defaults }
    }

    private let fixedLocations: Locations?
    private var cache: (locations: Locations, index: ProfileIndex)?

    /// nil reads `Locations.standard` at every scan (so an override installed later is honored).
    init(locations: Locations? = nil) {
        fixedLocations = locations
    }

    private var locations: Locations { fixedLocations ?? .standard }

    /// The last scan while the locations are unchanged; otherwise, or with `refresh`, a new one.
    func index(refresh: Bool = false) -> ProfileIndex {
        let locations = self.locations
        if !refresh, let cache, cache.locations == locations { return cache.index }
        let started = ContinuousClock.now
        let index = Self.scan(locations)
        DocumentLog.scanned(index, startedAt: started)
        cache = (locations, index)
        return index
    }

    /// Copies each usable profile, byte for byte, to `imported/<digest>.xmp`. Folders are walked recursively.
    func importProfiles(at urls: [URL]) -> ProfileImportReport {
        let folder = locations.imported
        var report = ProfileImportReport()
        defer { cache = nil }
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                report.skipped.append(ProfileImportFailure(url: url, error: .unreadable("No file at \(url.path)")))
                continue
            }
            let files = isDirectory.boolValue ? Self.profileFiles(in: url).map(\.url) : [url]
            for file in files {
                do throws(ProfileError) {
                    let (summary, isNew) = try Self.importProfile(at: file, into: folder)
                    if isNew { report.imported.append(summary) } else { report.alreadyImported.append(summary) }
                } catch {
                    report.skipped.append(ProfileImportFailure(url: file, error: error))
                }
            }
        }
        DocumentLog.imported(report)
        return report
    }

    /// Resolves an MCP selector: a digest, a UUID, "Group/Name" or a name. Throws `ProfileSelectorError`.
    func resolve(_ selector: String) throws -> ProfileSummary {
        let selector = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = self.index()
        let matches: [ProfileSummary]
        if let digest = ProfileDigest(hex: selector.lowercased()) {
            if let summary = index.summary(for: digest) {
                matches = [summary]
            } else if let summary = Self.importedSummary(digest, in: locations.imported) {
                // Imported, but listed under another copy with its identity (the same UUID and tables): the id
                // `importProfiles` returned still names it.
                matches = [summary]
            } else if let loaded = ProfileRegistry.shared.profile(digest) {
                matches = [ProfileSummary(loaded: loaded)]
            } else {
                throw ProfileSelectorError.notFound(selector)
            }
        } else {
            matches = Self.matches(selector, in: index.profiles)
        }
        guard let first = matches.first else { throw ProfileSelectorError.notFound(selector) }
        let usable = matches.filter { $0.usability == .usable }
        switch usable.count {
        case 0: throw ProfileSelectorError.unusable(first)
        case 1: return usable[0]
        default: throw ProfileSelectorError.ambiguous(usable)
        }
    }

    /// The profile a summary lists, checked against its digest and registered. Throws `ProfileError`.
    func load(_ summary: ProfileSummary) throws -> LoadedProfile {
        guard summary.source != .document, let path = summary.path else {
            guard let loaded = ProfileRegistry.shared.profile(summary.digest) else {
                throw ProfileError.notLoaded(name: summary.name)
            }
            return loaded
        }
        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            // The size first, so an oversized or changed file is never read.
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= AdobeProfileParser.maximumFileBytes else { throw ProfileError.tooLarge }
            guard size == summary.fileSize else { throw ProfileError.digestMismatch }
            data = try Data(contentsOf: url)
        } catch let error as ProfileError {
            throw error
        } catch {
            throw ProfileError.unreadable(error.localizedDescription)
        }
        guard ProfileDigest(of: data) == summary.digest else { throw ProfileError.digestMismatch }
        return try ProfileRegistry.shared.register(data)
    }

    // MARK: - Scanning

    private struct ProfileFile {
        let url: URL
        let size: Int
        /// Directly inside the folder being walked.
        let isAtTop: Bool
    }

    /// Reads every Look file under the three roots, in order; a missing root is empty. Creates nothing.
    private static func scan(_ locations: Locations) -> ProfileIndex {
        var scanned: [ProfileSummary] = []
        var unparseable = 0
        let roots: [(URL, ProfileSource)] = [
            (locations.adobeSystem, .adobe), (locations.adobeUser, .adobeUser), (locations.imported, .imported),
        ]
        for (root, source) in roots {
            for file in profileFiles(in: root) where file.size <= AdobeProfileParser.maximumFileBytes {
                // Import parsed every imported file in full, so only Adobe's folders need the quick check.
                guard let data = try? Data(contentsOf: file.url), source == .imported || isLook(data) else { continue }
                let profile: AdobeProfile
                do {
                    profile = try AdobeProfileParser.profile(from: data, decodeTables: false)
                } catch ProfileError.notAProfile {
                    continue
                } catch {
                    unparseable += 1
                    continue
                }
                let group = profile.group
                    ?? (file.isAtTop ? (source == .imported ? "Imported" : "Other")
                        : file.url.deletingLastPathComponent().lastPathComponent)
                scanned.append(ProfileSummary(profile: profile, digest: ProfileDigest(of: data), source: source,
                                              path: file.url.path, fileSize: data.count, group: group))
            }
        }
        return ProfileIndex(scanned: scanned, unparseable: unparseable)
    }

    /// Regular, non-hidden, non-symlink `*.xmp` files under `folder`, at any depth and of any size.
    private static func profileFiles(in folder: URL) -> [ProfileFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var files: [ProfileFile] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "xmp" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            files.append(ProfileFile(url: url, size: values.fileSize ?? 0, isAtTop: enumerator.level == 1))
        }
        return files
    }

    private static let lookMarkers = [Data("PresetType=\"Look\"".utf8), Data("PresetType>Look<".utf8)]

    /// Whether the first 8 KiB declare a Look, which skips presets without parsing them.
    private static func isLook(_ data: Data) -> Bool {
        let head = data.prefix(8192)
        return lookMarkers.contains { head.range(of: $0) != nil }
    }

    // MARK: - Importing

    /// Checks one file and copies it into `folder` unless the same bytes are there. Returns its summary and whether it
    /// was copied now.
    private static func importProfile(at url: URL, into folder: URL) throws(ProfileError) -> (ProfileSummary, Bool) {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > AdobeProfileParser.maximumFileBytes {
            throw .tooLarge
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .unreadable(error.localizedDescription)
        }
        let profile: AdobeProfile
        do {
            profile = try AdobeProfileParser.profile(from: data, decodeTables: true)
        } catch let error as ProfileError {
            throw error
        } catch {
            throw .malformed(error.localizedDescription)
        }
        if let error = profile.usability.error { throw error }

        let digest = ProfileDigest(of: data)
        let destination = folder.appendingPathComponent("\(digest.hex).xmp")
        let summary = ProfileSummary(profile: profile, digest: digest, source: .imported, path: destination.path,
                                     fileSize: data.count, group: profile.group ?? "Imported")
        if let existing = try? Data(contentsOf: destination), ProfileDigest(of: existing) == digest {
            return (summary, false)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
        return (summary, true)
    }

    // MARK: - Resolving

    /// The imported file `imported/<digest>.xmp`, when it is there with those bytes and parses: an imported copy the
    /// index doesn't list because another copy of the same identity ranks above it.
    private static func importedSummary(_ digest: ProfileDigest, in folder: URL) -> ProfileSummary? {
        let url = folder.appendingPathComponent("\(digest.hex).xmp")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= AdobeProfileParser.maximumFileBytes, let data = try? Data(contentsOf: url),
              ProfileDigest(of: data) == digest,
              let profile = try? AdobeProfileParser.profile(from: data, decodeTables: false) else { return nil }
        return ProfileSummary(profile: profile, digest: digest, source: .imported, path: url.path, fileSize: data.count,
                              group: profile.group ?? "Imported")
    }

    /// Rules 2–4 of `resolve`: a UUID, then "Group/Name", then an exact name, all case-insensitive; the first rule that
    /// matches anything wins.
    private static func matches(_ selector: String, in profiles: [ProfileSummary]) -> [ProfileSummary] {
        func same(_ lhs: String, _ rhs: some StringProtocol) -> Bool {
            lhs.compare(rhs, options: .caseInsensitive) == .orderedSame
        }
        var rules: [(ProfileSummary) -> Bool] = []
        if selector.utf8.count == 32, selector.allSatisfy({ $0.isASCII && $0.isHexDigit }) {
            rules.append { same($0.identity.uuid, selector) }
        }
        if let slash = selector.lastIndex(of: "/") {
            let group = selector[..<slash], name = selector[selector.index(after: slash)...]
            rules.append { same($0.group, group) && same($0.name, name) }
        }
        rules.append { same($0.name, selector) }
        for rule in rules {
            let found = profiles.filter(rule)
            if !found.isEmpty { return found }
        }
        return []
    }
}
