import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Opt-in corpus round trip (Task 4.3): every `.psd` in the folder `COMPOSITOR_PSD_CORPUS` names is opened as the app
/// opens it, written back without an edit, and read again. The test only reads that folder and writes nothing to
/// disk; point it at local copies of the files, never at a client folder. `PSDCorpusGuard` refuses a cloud-backed
/// folder and skips any file that is not local and fully present. Failures and skips name files and layers by index,
/// and the summary it attaches to the result holds counts only.
extension PSDWriterRoundTripTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["COMPOSITOR_PSD_CORPUS"] != nil))
    func corpusFilesKeepTheirLayersBlocksAndResourcesThroughASave() throws {
        let path = try #require(ProcessInfo.processInfo.environment["COMPOSITOR_PSD_CORPUS"])
        let files: [Result<URL, PSDCorpusGuard.Refusal>]
        do throws(PSDCorpusGuard.Refusal) {
            files = try PSDCorpusGuard.listing(path)
        } catch {
            Issue.record("the corpus folder is refused, \(error.rawValue): copy the files to a local folder")
            return
        }
        #expect(!files.isEmpty)
        var tally = CorpusTally()
        for (index, file) in files.enumerated() {
            switch file {
            case .failure(let reason):
                tally.skipped.append((index, reason))
                Issue.record("file \(index) skipped: \(reason.rawValue)", severity: .warning)
            case .success(let url):
                do {
                    try autoreleasepool { try roundTrip(url, file: index, tally: &tally) }
                } catch {
                    Issue.record("file \(index) failed: \(type(of: error))")
                }
            }
        }
        #expect(tally.skipped.count < files.count, "every corpus file was skipped")
        Attachment.record(tally.description, named: "psd-corpus-summary.txt")
    }

    private func roundTrip(_ url: URL, file: Int, tally: inout CorpusTally) throws {
        let source = try Data(contentsOf: url, options: .mappedIfSafe)
        let before = try PSDReader.read(source)
        let session = EditorSession()
        try session.insertPhotoshop(try PSDDocumentBuilder.makeImport(before), named: "Corpus")
        let written = try PSDWriter.data(for: try #require(session.psdWriteRequest()))
        let after = try PSDReader.read(written.data)
        tally.files += 1
        tally.bytes += written.data.count
        tally.warnings += written.report.warnings.count

        // Layers: what they are, where they sit, and every block and record field Photoshop wrote.
        #expect(after.layers.count == before.layers.count, "file \(file): layer count")
        guard after.layers.count == before.layers.count else { return }
        func parents(_ document: PSDDocument) -> [Int?] {
            document.layers.map { layer in layer.parentID.flatMap { id in document.layers.firstIndex { $0.id == id } } }
        }
        #expect(parents(after) == parents(before), "file \(file): folders")
        func differing<Value: Equatable>(_ value: (PSDRecord) -> Value) -> [Int] {
            before.layers.indices.filter { value(before.layers[$0]) != value(after.layers[$0]) }
        }
        // Indices of the layers that differ, named outside `#expect` so its expansion leaves the closures alone.
        let checks: [(String, [Int])] = [
            ("names", differing(\.name)), ("kinds", differing(\.kind)), ("bounds", differing(\.bounds)),
            ("visibility and clipping", differing { [$0.isVisible, $0.clipping] }),
            ("opacity and fill", differing { [$0.opacity, $0.fillOpacity] }),
            ("blend keys", differing(\.blendKey)), ("locks", differing(\.locks)), ("text", differing(\.typeLayer)),
            ("effects", differing { $0.extras?.blocks.filter { PSDLayerExtras.effectKeys.contains($0.key) } }),
            ("smart-object IDs", differing(smartObjectID)),
            ("blocks", differing { $0.extras?.blocks }),
            ("section dividers", differing { $0.extras?.sectionDividerExtras?.blocks }),
            ("blending ranges", differing { $0.extras?.blendingRanges }),
            ("flags, clipping and filler bytes", differing { $0.extras.map { [$0.flags, $0.clippingByte, $0.fillerByte] } }),
            ("record blend keys", differing { $0.extras?.blendKey }), ("layer IDs", differing { $0.extras?.layerID }),
            ("name sources", differing { $0.extras?.nameSource }),
        ]
        for (what, indices) in checks {
            #expect(indices.isEmpty, "file \(file): \(what) differ at layers \(indices)")
        }
        // Masks keep their flags, and their parameters unless the file had a real user mask, which a save leaves out
        // with its channel.
        let masked = before.layers.indices.filter { before.layers[$0].mask != nil }
        let real = masked.filter { (before.layers[$0].extras?.maskParameters?.count ?? 0) >= 18 }
        let maskFlags = masked.filter { before.layers[$0].extras?.maskFlags != after.layers[$0].extras?.maskFlags }
        let maskParameters = masked.filter {
            !real.contains($0) && before.layers[$0].extras?.maskParameters != after.layers[$0].extras?.maskParameters
        }
        #expect(maskFlags.isEmpty && maskParameters.isEmpty,
                "file \(file): mask flags differ at layers \(maskFlags), parameters at \(maskParameters)")

        // Layers placed one pixel to a pixel come back with the same pixels.
        let layers = session.document?.layers ?? []
        for index in before.layers.indices {
            guard let original = before.layers[index].image, let reread = after.layers[index].image,
                  let layer = layers.first(where: { $0.id == before.layers[index].id }),
                  PSDLayerBaker.isUpright(layer.transform, width: original.width, height: original.height) else { continue }
            tally.uprightLayers += 1
            #expect(try samePixels(original, reread), "file \(file): pixels differ at layer \(index)")
        }

        // The document: resources other than the regenerated ones (and the thumbnail) byte for byte, in order;
        // guides, the global layer mask info and the document's blocks.
        let old = try #require(before.extras), new = try #require(after.extras)
        let rewritten = PSDImageResourcesWriter.modeledIDs.union(PSDImageResourcesWriter.droppedIDs)
        let kept = old.resources.filter { !rewritten.contains($0.id) }
        #expect(new.resources.filter { !rewritten.contains($0.id) } == kept, "file \(file): resources")
        let oldIDs = old.resources.map(\.id).filter { !PSDImageResourcesWriter.droppedIDs.contains($0) }
        #expect(new.resources.map(\.id).filter(Set(oldIDs).contains) == oldIDs, "file \(file): resource order")
        #expect(!new.resources.contains { PSDImageResourcesWriter.droppedIDs.contains($0.id) }, "file \(file): thumbnail")
        func guides(_ extras: PSDDocumentExtras) -> [String] {
            extras.resources.filter { $0.id == 1032 }.flatMap { PSDResources.parseGuides($0.data) }.map { "\($0.axis) \($0.position)" }
        }
        #expect(guides(new) == guides(old), "file \(file): guides")
        #expect(new.globalLayerMaskInfo == old.globalLayerMaskInfo && new.globalBlocks == old.globalBlocks,
                "file \(file): global layer mask info or document blocks")
        // A negative layer count stays negative; a positive one turns negative only when Compositor's composite of
        // the layers has transparency, which the merged image then carries.
        #expect(!old.layerCountNegative || new.layerCountNegative, "file \(file): layer count sign")
        #expect(new.layerCountNegative == (old.layerCountNegative || written.report.wroteTransparencyChannel),
                "file \(file): layer count sign and merged transparency")
        if new.layerCountNegative != old.layerCountNegative { tally.transparentComposites += 1 }
        // Linked-layer entries (smart objects' contents, and the entries no layer names) byte for byte, in any order.
        let entries = [source, written.data].map { linkedEntries(in: $0).map(SmartObjectPayload.digest).sorted() }
        #expect(entries[1] == entries[0], "file \(file): linked-layer entries")
        tally.linkedEntries += entries[0].count

        // And the document the app opens from the written file is the one it wrote (compared outside `#expect`, which
        // would print names and text).
        let again = try PSDDocumentBuilder.makeImport(after)
        let sameNames = again.layers.map(\.name) == layers.map(\.name)
        let sameText = again.layers.map(\.text?.style) == layers.map(\.text?.style)
        let sameShapes = again.layers.map(\.shape?.style) == layers.map(\.shape?.style)
        let samePlaceholders = again.layers.map(\.isPhotoshopPlaceholder) == layers.map(\.isPhotoshopPlaceholder)
        #expect(sameNames && sameText && sameShapes && samePlaceholders,
                "file \(file): imported names \(sameNames), text \(sameText), shapes \(sameShapes), placeholders \(samePlaceholders)")

        tally.layers += before.layers.count
        tally.text += before.layers.filter { $0.typeLayer != nil }.count
        tally.smartObjects += before.layers.compactMap(smartObjectID).count
        tally.effects += before.layers.filter { $0.extras?.hasBlock(in: PSDLayerExtras.effectKeys) == true }.count
        tally.vectors += before.layers.filter { $0.kind == .vector }.count
        tally.masks += masked.count
        tally.realMasks += real.count
        tally.blocks += before.layers.reduce(0) { $0 + ($1.extras?.blocks.count ?? 0) }
        tally.resources += kept.count
    }

    /// A smart object's unique ID (`Idnt` in `SoLd`/`SoLE`, after the `soLD` key and version); nil for other layers.
    private func smartObjectID(_ record: PSDRecord) -> String? {
        guard let block = record.extras?.block("SoLd") ?? record.extras?.block("SoLE"), block.count > 8 else { return nil }
        var offset = 8
        return (try? PSDDescriptorReader.readBlock(Data(block), at: &offset))?.string("Idnt")
    }

    /// Every linked-layer entry among a PSD's document-level blocks.
    private func linkedEntries(in data: Data) -> [Data] {
        func u32(_ at: Int) -> Int {
            guard at >= 0, at + 4 <= data.count else { return data.count }
            let start = data.startIndex + at
            return data[start ..< start + 4].reduce(0) { $0 << 8 | Int($1) }
        }
        var offset = 26
        offset += 4 + u32(offset)                            // color mode data
        offset += 4 + u32(offset)                            // image resources
        let end = min(data.count, offset + 4 + u32(offset))
        offset += 4
        let info = u32(offset)
        offset += 4 + info + info % 2                        // layer info, padded to even
        offset += 4 + u32(offset)                            // global layer mask info
        guard offset <= end else { return [] }
        return PSDSmartObjects.decompose(PSDBlockFile.scanBlocks(data, from: offset, to: end)).entries
    }

    /// Whether the two images hold the same premultiplied RGBA bytes.
    private func samePixels(_ first: CGImage, _ second: CGImage) throws -> Bool {
        guard first.width == second.width, first.height == second.height else { return false }
        let contexts = try [first, second].map { image in
            let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
            BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
            return context
        }
        let a = try #require(contexts[0].data), b = try #require(contexts[1].data)
        return (0..<first.height).allSatisfy { row in
            memcmp(a + row * contexts[0].bytesPerRow, b + row * contexts[1].bytesPerRow, first.width * 4) == 0
        }
    }
}

/// Counts only: the corpus files are the owner's, so nothing about their content is printed. Skipped files are
/// named by index.
private struct CorpusTally: CustomStringConvertible {
    var files = 0, bytes = 0, warnings = 0, layers = 0, text = 0, smartObjects = 0, effects = 0, vectors = 0
    var masks = 0, realMasks = 0, uprightLayers = 0, blocks = 0, resources = 0, transparentComposites = 0, linkedEntries = 0
    var skipped: [(file: Int, reason: PSDCorpusGuard.Refusal)] = []

    var description: String {
        let skips = skipped.map { "file \($0.file): \($0.reason.rawValue)" }.joined(separator: ", ")
        return "\(files) files, \(bytes) bytes written, \(warnings) warnings; \(layers) layers (\(text) text, \(smartObjects) smart objects, "
            + "\(effects) with effects, \(vectors) vector, \(masks) masked of which \(realMasks) with a real user mask); "
            + "\(uprightLayers) upright layers compared pixel for pixel; \(blocks) layer blocks, \(resources) resources and "
            + "\(linkedEntries) linked-layer entries kept; "
            + "\(transparentComposites) positive layer counts written negative for a composite with transparency; "
            + "\(skipped.count) files skipped" + (skipped.isEmpty ? "" : " (\(skips))")
    }
}

/// Keeps the corpus test away from cloud-backed files, whose `open()` can start a download or block for hours (the
/// Task 2.7c probe hung for 6 h on one).
///
/// - A folder under `Library/Mobile Documents` or `Library/CloudStorage` (in any home or volume, named directly or
///   reached through a link) is refused, as is a folder that is itself an iCloud item or dataless.
/// - In an accepted folder, a `.psd` that is not a local, fully present regular file is skipped: dataless (a File
///   Provider placeholder), an iCloud item, a link into a cloud folder, or a dangling link.
///
/// Paths are resolved one component at a time with `lstat` and `readlink`. The cloud-folder check runs before each
/// lookup, and the dataless check before each lookup inside a directory. So no name is looked up inside a cloud
/// folder or a dataless directory, where a lookup can make the File Provider fetch it, and nothing is opened.
nonisolated enum PSDCorpusGuard {
    enum Refusal: String, Error {
        case cloudFolder = "in a cloud folder"
        case ubiquitous = "an iCloud item"
        case dataless = "a dataless placeholder"
        case notAFolder = "not a folder"
        case notAFile = "not a regular file"
        case unreadable = "unreadable"
    }

    /// The `.psd` entries in the folder at `path`, sorted by name: each is the local file to read (links resolved,
    /// so the file checked is the file read) or the reason it is skipped. Throws when the folder is refused.
    static func listing(_ path: String) throws(Refusal) -> [Result<URL, Refusal>] {
        try entries(path) { ($0 as NSString).pathExtension.lowercased() == "psd" }.map(\.file)
    }

    /// `listing` for the entries whose names pass `include`, each with its name in the folder.
    static func entries(_ path: String, where include: (String) -> Bool) throws(Refusal) -> [(name: String, file: Result<URL, Refusal>)] {
        let folder = try resolve(path)
        try check(mode: folder.info.st_mode, flags: folder.info.st_flags, ubiquitous: isUbiquitous(folder.path), folder: true)
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            throw .unreadable
        }
        return names.filter(include).sorted().map { name in
            (name, Result { () throws(Refusal) -> URL in
                let file = try resolve(folder.path + "/" + name)
                try check(mode: file.info.st_mode, flags: file.info.st_flags, ubiquitous: isUbiquitous(file.path), folder: false)
                return URL(fileURLWithPath: file.path, isDirectory: false)
            })
        }
    }

    /// What an item must be once resolved. It takes the item's mode and flags rather than a path, so a test can pass
    /// what no local test file can have: `SF_DATALESS` (only a File Provider sets it) and an iCloud item's answer.
    static func check(mode: mode_t, flags: UInt32, ubiquitous: @autoclosure () -> Bool, folder: Bool) throws(Refusal) {
        if flags & UInt32(SF_DATALESS) != 0 { throw .dataless }
        if ubiquitous() { throw .ubiquitous }
        if mode & S_IFMT != (folder ? S_IFDIR : S_IFREG) { throw folder ? .notAFolder : .notAFile }
    }

    /// Whether the path lies under a `Library/Mobile Documents` or `Library/CloudStorage` folder.
    static func isCloudPath(_ components: [String]) -> Bool {
        let names = components.map { $0.lowercased() }
        return zip(names, names.dropFirst()).contains { $0 == "library" && ($1 == "mobile documents" || $1 == "cloudstorage") }
    }

    /// `path` with every link followed, and the final item's `lstat`.
    private static func resolve(_ path: String) throws(Refusal) -> (path: String, info: stat) {
        let absolute = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        var pending = absolute.split(separator: "/").map(String.init)
        // First the path as written, with `..` taken lexically, before anything on it is looked up.
        let lexical = pending.reduce(into: [String]()) { names, name in
            if name == ".." { _ = names.popLast() } else if name != "." { names.append(name) }
        }
        if isCloudPath(lexical) { throw .cloudFolder }
        var components: [String] = []
        var info = try status(components)
        var links = 0
        while !pending.isEmpty {
            let name = pending.removeFirst()
            if name == "." { continue }
            if name == ".." {
                _ = components.popLast()
                info = try status(components)
                continue
            }
            if info.st_flags & UInt32(SF_DATALESS) != 0 { throw .dataless }
            components.append(name)
            if isCloudPath(components) { throw .cloudFolder }
            info = try status(components)
            guard info.st_mode & S_IFMT == S_IFLNK else { continue }
            links += 1
            guard links <= 32,
                  let target = try? FileManager.default.destinationOfSymbolicLink(atPath: joined(components))
            else { throw .unreadable }
            components.removeLast()
            if target.hasPrefix("/") { components = [] }
            pending = target.split(separator: "/").map(String.init) + pending
            info = try status(components)
        }
        return (joined(components), info)
    }

    private static func status(_ components: [String]) throws(Refusal) -> stat {
        var info = stat()
        guard lstat(joined(components), &info) == 0 else { throw .unreadable }
        return info
    }

    private static func joined(_ components: [String]) -> String { "/" + components.joined(separator: "/") }

    private static func isUbiquitous(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }
}

/// `PSDCorpusGuard` on local stand-ins: folders in a temporary directory named like cloud folders, so no real cloud
/// folder is touched.
@Suite struct PSDCorpusGuardTests {
    private var files: FileManager { .default }

    /// A new temporary directory, by its real path (`resolvingSymlinksInPath` would strip `/private`).
    private func temporaryDirectory() throws -> URL {
        let url = files.temporaryDirectory.appendingPathComponent("PSDCorpusGuardTests-\(UUID())")
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        let real = try #require(realpath(url.path, nil))
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real), isDirectory: true)
    }

    @Test func aCloudFolderIsRefusedBeforeAnythingOnItsPathIsLookedUp() {
        let home = files.homeDirectoryForCurrentUser.path
        // None of these exist: each is refused as written, so none is looked up.
        let paths = [
            home + "/Library/CloudStorage/NoSuchProvider-CorpusGuard/corpus",
            home + "/Library/Mobile Documents/com~apple~CloudDocs/NoSuchCorpus-CorpusGuard",
            "/System/Volumes/Data/Users/nobody-corpus-guard/library/cloudstorage/corpus",
            "/Users/nobody-corpus-guard/Library/NoSuchFolder/../CloudStorage/./corpus",
        ]
        for path in paths {
            #expect(throws: PSDCorpusGuard.Refusal.cloudFolder) { try PSDCorpusGuard.listing(path) }
        }
    }

    @Test func aFolderLinkedIntoACloudFolderIsRefused() throws {
        let base = try temporaryDirectory()
        defer { try? files.removeItem(at: base) }
        let cloud = base.appendingPathComponent("Home/Library/CloudStorage/Provider/corpus")
        try files.createDirectory(at: cloud, withIntermediateDirectories: true)
        try Data([1]).write(to: cloud.appendingPathComponent("a.psd"))
        try files.createSymbolicLink(atPath: base.path + "/absolute", withDestinationPath: cloud.path)
        try files.createSymbolicLink(atPath: base.path + "/relative", withDestinationPath: "Home/Library/CloudStorage/Provider")
        try Data([1]).write(to: base.appendingPathComponent("plain.psd"))

        #expect(throws: PSDCorpusGuard.Refusal.cloudFolder) { try PSDCorpusGuard.listing(cloud.path) }
        #expect(throws: PSDCorpusGuard.Refusal.cloudFolder) { try PSDCorpusGuard.listing(base.path + "/absolute") }
        #expect(throws: PSDCorpusGuard.Refusal.cloudFolder) { try PSDCorpusGuard.listing(base.path + "/relative/corpus") }
        #expect(throws: PSDCorpusGuard.Refusal.notAFolder) { try PSDCorpusGuard.listing(base.path + "/plain.psd") }
        #expect(throws: PSDCorpusGuard.Refusal.unreadable) { try PSDCorpusGuard.listing(base.path + "/missing") }
        #expect(try PSDCorpusGuard.listing(base.path).isEmpty == false)
    }

    @Test func onlyLocalRegularFilesAreRead() throws {
        let base = try temporaryDirectory()
        defer { try? files.removeItem(at: base) }
        let cloud = base.appendingPathComponent("Home/Library/Mobile Documents/com~apple~CloudDocs")
        let corpus = base.appendingPathComponent("corpus"), elsewhere = base.appendingPathComponent("elsewhere")
        for folder in [cloud, corpus, elsewhere, corpus.appendingPathComponent("d.psd")] {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for file in [cloud.appendingPathComponent("b.psd"), corpus.appendingPathComponent("a.psd"),
                     corpus.appendingPathComponent("h.txt"), elsewhere.appendingPathComponent("e.psd")] {
            try Data([1]).write(to: file)
        }
        func link(_ name: String, to destination: String) throws {
            try files.createSymbolicLink(atPath: corpus.path + "/" + name, withDestinationPath: destination)
        }
        try link("b.psd", to: cloud.path + "/b.psd")
        try link("c.psd", to: base.path + "/missing.psd")
        try link("e.psd", to: "../elsewhere/e.psd")
        try link("f.PSD", to: "../Home/Library/Mobile Documents/com~apple~CloudDocs/b.psd")
        try link("g.psd", to: "g.psd")
        // Through a link to the folder, so the folder's own path is resolved too.
        try files.createSymbolicLink(atPath: base.path + "/alias", withDestinationPath: "corpus")

        let listing = try PSDCorpusGuard.listing(base.path + "/alias")
        let expected: [Result<URL, PSDCorpusGuard.Refusal>] = [
            .success(corpus.appendingPathComponent("a.psd")), .failure(.cloudFolder), .failure(.unreadable),
            .failure(.notAFile), .success(elsewhere.appendingPathComponent("e.psd")), .failure(.cloudFolder),
            .failure(.unreadable),
        ]
        #expect(listing.map(\.path) == expected.map(\.path))
    }

    /// `entries` names each item it passes, so a caller can find a file by its name (the import corpus test finds
    /// `expectations.json` and each file by its name's hash), and checks each as `listing` does.
    @Test func entriesAreNamedAndCheckedLikeTheListing() throws {
        let base = try temporaryDirectory()
        defer { try? files.removeItem(at: base) }
        let cloud = base.appendingPathComponent("Home/Library/CloudStorage/Provider")
        let corpus = base.appendingPathComponent("corpus")
        for folder in [cloud, corpus] { try files.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data([1]).write(to: cloud.appendingPathComponent("expectations.json"))
        try Data([1]).write(to: corpus.appendingPathComponent("a.psd"))
        try Data([1]).write(to: corpus.appendingPathComponent("notes.txt"))
        try files.createSymbolicLink(atPath: corpus.path + "/expectations.json", withDestinationPath: cloud.path + "/expectations.json")

        let entries = try PSDCorpusGuard.entries(corpus.path) { $0 == "expectations.json" || $0.hasSuffix(".psd") }
        #expect(entries.map(\.name) == ["a.psd", "expectations.json"])
        #expect(entries.map(\.file.path) == [corpus.appendingPathComponent("a.psd").path, PSDCorpusGuard.Refusal.cloudFolder.rawValue])
        #expect(throws: PSDCorpusGuard.Refusal.cloudFolder) { try PSDCorpusGuard.entries(cloud.path) { _ in true } }
    }

    @Test func placeholdersAndICloudItemsAreSkipped() {
        let file = S_IFREG | 0o644, folder = S_IFDIR | 0o755, dataless = UInt32(SF_DATALESS)
        #expect(throws: PSDCorpusGuard.Refusal.dataless) {
            try PSDCorpusGuard.check(mode: file, flags: dataless, ubiquitous: false, folder: false)
        }
        #expect(throws: PSDCorpusGuard.Refusal.dataless) {
            try PSDCorpusGuard.check(mode: folder, flags: dataless | UInt32(UF_HIDDEN), ubiquitous: false, folder: true)
        }
        #expect(throws: PSDCorpusGuard.Refusal.ubiquitous) {
            try PSDCorpusGuard.check(mode: file, flags: 0, ubiquitous: true, folder: false)
        }
        #expect(throws: PSDCorpusGuard.Refusal.notAFolder) {
            try PSDCorpusGuard.check(mode: file, flags: 0, ubiquitous: false, folder: true)
        }
        #expect(throws: Never.self) {
            try PSDCorpusGuard.check(mode: file, flags: UInt32(UF_NODUMP), ubiquitous: false, folder: false)
            try PSDCorpusGuard.check(mode: folder, flags: 0, ubiquitous: false, folder: true)
        }
    }
}

private extension Result where Success == URL, Failure == PSDCorpusGuard.Refusal {
    /// The file's path or the reason it is skipped, comparable in a test.
    var path: String {
        switch self {
        case .success(let url): url.path
        case .failure(let reason): reason.rawValue
        }
    }
}
