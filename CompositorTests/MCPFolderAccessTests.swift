import CoreGraphics
import Foundation
import ImageIO
import Testing
import MCP
import UniformTypeIdentifiers
@testable import Compositor

/// No MCP tool can hang on a macOS privacy prompt: every tool that opens, lists or writes a file checks folder access
/// first and fails fast with a structured error, and get_app_info reports each protected location's access.
///
/// Each test runs its calls with a `FolderAccess.Checker` whose protected roots live in a fake home in the temporary
/// folder, with a fake lister standing in for macOS, so nothing here reads the real Documents, Desktop, Downloads,
/// iCloud Drive, cloud storage or /Volumes. The checker is set for the test's own task (`FolderAccess.taskChecker`), so
/// other suites running meanwhile never see the fake roots. Serialized so the timing tests don't compete with each
/// other for the main actor.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)))
struct MCPFolderAccessTests {
    private static let deniedHint = "Grant Compositor access in System Settings > Privacy & Security > Files and Folders (or Full Disk Access), or copy the file to the Agent folder"
    private static let pendingHint = "A macOS permission prompt is waiting on this Mac; approve it and retry."

    // MARK: Fixtures

    /// Runs `body` with a checker whose protected roots are `home`'s and whose listings `lister` answers.
    private func withRoots<T>(_ home: FakeHome, _ lister: FakeLister, _ body: () async throws -> T) async rethrows -> T {
        let checker = FolderAccess.Checker(locations: home.locations, lister: { try lister.list($0) })
        return try await FolderAccess.$taskChecker.withValue(checker) { try await body() }
    }

    /// Writes a small opaque PNG at `url`, making its folder.
    private func writePNG(_ url: URL, width: Int = 4, height: Int = 4) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// Everything inside `folder`, as paths relative to it.
    private func contents(of folder: URL) -> [String] {
        (FileManager.default.subpaths(atPath: folder.path) ?? []).sorted()
    }

    /// Checks a tool's failure carries the folder-access error: `details.code`, the path, the root and the hint.
    private func expectRefusal(_ result: [String: Value], _ code: String, path: String, root: String = "documents",
                               sourceLocation: SourceLocation = #_sourceLocation) {
        let error = result["error"]?.objectValue
        let details = error?["details"]?.objectValue
        #expect(details?["code"]?.stringValue == code, "\(String(describing: error))", sourceLocation: sourceLocation)
        #expect(details?["path"]?.stringValue == path, "\(String(describing: error))", sourceLocation: sourceLocation)
        #expect(details?["root"]?.stringValue == root, "\(String(describing: error))", sourceLocation: sourceLocation)
        let hint = code == "folder_access_denied" ? Self.deniedHint : Self.pendingHint
        #expect(error?["hint"]?.stringValue == hint, sourceLocation: sourceLocation)
        #expect(error?["message"]?.stringValue?.contains(path) == true, sourceLocation: sourceLocation)
    }

    // MARK: Failing fast

    @Test func openingAFileInADeniedRootFailsFastWithoutReadingIt() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let home = FakeHome(roots: [.documents])
        let lister = FakeLister(["Documents": .failure(POSIXError(.EPERM))])
        let file = home[.documents].appendingPathComponent("Client/hero.png")
        try writePNG(file)

        let (result, elapsed, stall) = try await withRoots(home, lister) {
            try await timed {
                try await MCPTestSupport.call("open_document", ["path": .string(file.path)], in: workspace, expectError: "io_error")
            }
        }
        expectRefusal(result, "folder_access_denied", path: file.path)
        #expect(elapsed < .seconds(3) + stall, "took \(elapsed) with the main actor held \(stall)")
        #expect(lister.listed == ["Documents"])
        #expect(workspace.tabs.count == 1 && workspace.current.session.sourceURL == nil)
    }

    @Test func aPendingPromptMakesToolsBusyWithinTheTimeout() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let home = FakeHome(roots: [.documents])
        let lister = FakeLister(["Documents": .hang])
        defer { lister.release() }
        let file = home[.documents].appendingPathComponent("hero.png")
        try writePNG(file)

        let (result, elapsed, stall) = try await withRoots(home, lister) {
            try await timed {
                try await MCPTestSupport.call("open_document", ["path": .string(file.path)], in: workspace, expectError: "busy")
            }
        }
        expectRefusal(result, "folder_access_pending", path: file.path)
        // It waited out the probe (the default two seconds), and no longer.
        #expect(elapsed >= FolderAccess.defaultTimeout)
        #expect(elapsed < .seconds(3) + stall, "took \(elapsed) with the main actor held \(stall)")
    }

    @Test func savingOrExportingIntoADeniedRootWritesNothing() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let home = FakeHome(roots: [.documents])
        let lister = FakeLister(["Documents": .failure(POSIXError(.EPERM))])
        let documents = home[.documents]

        try await withRoots(home, lister) {
            for (tool, args, target) in [
                ("save_document_as", ["path": Value.string(documents.path + "/out.comp")], "out.comp"),
                ("export_image", ["path": .string(documents.path + "/Work/out.png")], "Work/out.png"),
                ("get_layer_pixels", ["layer": "@active", "save_to": .string(documents.path + "/pixels.png")], "pixels.png"),
            ] {
                let (result, elapsed, stall) = try await timed {
                    try await MCPTestSupport.call(tool, args, in: workspace, expectError: "io_error")
                }
                expectRefusal(result, "folder_access_denied", path: documents.appendingPathComponent(target).path)
                #expect(elapsed < .seconds(3) + stall, "\(tool) took \(elapsed) with the main actor held \(stall)")
            }
        }
        #expect(contents(of: documents).isEmpty)
    }

    @Test func aDocumentsOwnFileIsCheckedBeforeSavingOrReverting() async throws {
        // save_document and revert_document take no path: they touch the file the document came from.
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let home = FakeHome(roots: [.documents])
        let lister = FakeLister()
        let project = home[.documents].appendingPathComponent("Poster.comp")

        try await withRoots(home, lister) {
            try await MCPTestSupport.call("save_document_as", ["path": .string(project.path)], in: workspace)
            try await MCPTestSupport.call("add_blank_layer", in: workspace)
            let session = workspace.current.session
            let layers = session.document?.layers.count

            // The owner turns Documents off for Compositor.
            lister.answer("Documents", .failure(POSIXError(.EPERM)))
            let saved = try await MCPTestSupport.call("save_document", in: workspace, expectError: "io_error")
            expectRefusal(saved, "folder_access_denied", path: project.path)
            #expect(session.isModified)
            let reverted = try await MCPTestSupport.call("revert_document", ["discard_changes": true], in: workspace,
                                                         expectError: "io_error")
            expectRefusal(reverted, "folder_access_denied", path: project.path)
            #expect(session.document?.layers.count == layers)
        }
    }

    @Test func everyFileToolRefusesADeniedPath() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let home = FakeHome(roots: [.documents])
        let lister = FakeLister(["Documents": .failure(POSIXError(.EPERM))])
        let documents = home[.documents]
        let image = documents.appendingPathComponent("Client/hero.png")
        try writePNG(image)
        let missing = documents.appendingPathComponent("Client/missing.png")
        let calls: [(String, [String: Value], URL)] = [
            ("open_document", ["path": .string(image.path)], image),
            ("get_file_info", ["path": .string(image.path)], image),
            // Nothing there: without the check this would be not_found (and never open a Finder window).
            ("reveal_in_finder", ["path": .string(missing.path)], missing),
            ("list_files", ["path": .string(documents.path)], documents),
            ("add_image_layer", ["path": .string(image.path)], image),
            ("place_smart_object", ["path": .string(image.path)], image),
            ("set_layer_pixels", ["path": .string(image.path), "layer": "@active"], image),
            ("paste_image_into_layer", ["path": .string(image.path), "layer": "@active", "x": 0, "y": 0], image),
            ("save_document_as", ["path": .string(documents.path + "/Client/copy.comp")], documents.appendingPathComponent("Client/copy.comp")),
            ("export_image", ["path": .string(documents.path + "/Client/out.png")], documents.appendingPathComponent("Client/out.png")),
            ("get_layer_pixels", ["layer": "@active", "save_to": .string(documents.path + "/Client/pixels.png")],
             documents.appendingPathComponent("Client/pixels.png")),
        ]
        try await withRoots(home, lister) {
            for (tool, args, path) in calls {
                let result = try await MCPTestSupport.call(tool, args, in: workspace, expectError: "io_error")
                expectRefusal(result, "folder_access_denied", path: path.path)
            }
        }
        #expect(contents(of: documents) == ["Client", "Client/hero.png"])
        #expect(workspace.tabs.count == 1 && workspace.current.session.document?.layers.count == 1)
    }

    @Test func listingADeniedFolderFailsTheSameWay() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let home = FakeHome(roots: [.documents])
        let lister = FakeLister(["Documents": .failure(POSIXError(.EPERM))])
        try writePNG(home[.documents].appendingPathComponent("hero.png"))

        try await withRoots(home, lister) {
            let (result, elapsed, stall) = try await timed {
                try await MCPTestSupport.call("list_files", ["path": .string(home[.documents].path), "recursive": true], in: workspace,
                                              expectError: "io_error")
            }
            expectRefusal(result, "folder_access_denied", path: home[.documents].path)
            #expect(elapsed < .seconds(3) + stall, "took \(elapsed) with the main actor held \(stall)")
        }
    }

    @Test func aRecursiveListingEntersNoFolderMacOSHasNotAllowed() async throws {
        // Listing the home folder reaches Documents and cloud storage on the way down: each is checked before
        // anything inside it is read, and one macOS refuses is listed but not entered.
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let home = FakeHome(roots: [.documents, .cloudStorage])
        let lister = FakeLister(["Documents": .failure(POSIXError(.EPERM)), "Dropbox": .failure(POSIXError(.EPERM))])
        let files = FileManager.default
        for path in ["Pictures/a.txt", "Documents/secret.txt", "Library/CloudStorage/Dropbox/x.txt", "Library/CloudStorage/Drive/y.txt"] {
            let url = home.url.appendingPathComponent(path)
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: url)
        }

        let listed = try await withRoots(home, lister) {
            try await MCPTestSupport.call("list_files", ["path": .string(home.url.path), "recursive": true], in: workspace)
        }
        let names = listed["files"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue }
        #expect(names == ["Documents", "Library", "Library/CloudStorage", "Library/CloudStorage/Drive",
                          "Library/CloudStorage/Drive/y.txt", "Library/CloudStorage/Dropbox", "Pictures", "Pictures/a.txt"])
        let root = try #require(listed["root"]?.stringValue)
        #expect(listed["skipped"] == .array([
            .object(["path": .string(root + "/Documents"), "code": "folder_access_denied"]),
            .object(["path": .string(root + "/Library/CloudStorage/Dropbox"), "code": "folder_access_denied"]),
        ]))
        #expect(Set(lister.listed) == ["Documents", "CloudStorage", "Drive", "Dropbox"])
    }

    @Test func aListingOutOfTimeAsksNothingMoreAndKeepsWhatWasKnown() async throws {
        // `list_files ~ recursive` while the Desktop prompt is up: Desktop, first in name order, uses up the listing's
        // two seconds. The protected folders after it are listed but not entered, and named as unchecked instead of
        // being asked about with no time to wait: Documents and cloud storage, granted earlier, stay granted, and
        // Downloads stays unchecked for get_app_info to probe. A link into Documents gets no size, unasked.
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let home = FakeHome(roots: [.desktop, .documents, .downloads, .cloudStorage])
        let lister = FakeLister(["Desktop": .hang, "CloudStorage": .folders(["Dropbox"])])
        defer { lister.release() }
        for path in ["Desktop/a.txt", "Documents/secret.txt", "Downloads/d.txt", "Library/CloudStorage/Dropbox/x.txt", "Pictures/p.txt"] {
            let url = home.url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: url)
        }
        let pictures = home.url.appendingPathComponent("Pictures")
        try FileManager.default.createSymbolicLink(atPath: pictures.appendingPathComponent("zLinkIn").path,
                                                   withDestinationPath: home[.documents].appendingPathComponent("secret.txt").path)
        try FileManager.default.createSymbolicLink(atPath: pictures.appendingPathComponent("zLinkOut").path, withDestinationPath: "p.txt")

        try await withRoots(home, lister) {
            #expect(await FolderAccess.probe(.documents, timeout: .seconds(120)) == .granted)
            #expect(await FolderAccess.probe(.cloudStorage, timeout: .seconds(120)) == .granted)
            let before = lister.listed.count

            let (listed, elapsed, stall) = try await timed {
                try await MCPTestSupport.call("list_files", ["path": .string(home.url.path), "recursive": true], in: workspace)
            }
            let root = try #require(listed["root"]?.stringValue)
            #expect(listed["skipped"] == .array([
                .object(["path": .string(root + "/Desktop"), "code": "folder_access_pending"]),
                .object(["path": .string(root + "/Documents"), "code": "folder_access_unchecked"]),
                .object(["path": .string(root + "/Downloads"), "code": "folder_access_unchecked"]),
                .object(["path": .string(root + "/Library/CloudStorage"), "code": "folder_access_unchecked"]),
            ]))
            let sizes = (listed["files"]?.arrayValue ?? []).compactMap { entry -> String? in
                guard let object = entry.objectValue, let name = object["name"]?.stringValue else { return nil }
                return object["size"].flatMap(\.intValue).map { "\(name) \($0)" } ?? name
            }
            #expect(sizes == ["Desktop", "Documents", "Downloads", "Library", "Library/CloudStorage", "Pictures", "Pictures/p.txt 5",
                              "Pictures/zLinkIn", "Pictures/zLinkOut 5"])
            #expect(elapsed < .seconds(3) + stall, "took \(elapsed) with the main actor held \(stall)")
            #expect(Array(lister.listed.dropFirst(before)) == ["Desktop"])
            #expect(FolderAccess.lastKnownStates == [.documents: .granted, .cloudStorage: .granted, .desktop: .notDetermined])

            // What get_app_info reports from them (Downloads it probes now, against the clock).
            let access = try await MCPTestSupport.call("get_app_info", in: workspace)["folder_access"]?.objectValue
            #expect(access?["documents"] == "granted" && access?["cloud_storage"] == "granted")
            #expect(access?["desktop"] == "not_determined")
        }
    }

    @Test func aLinksSizeIsReadOnlyWhereMacOSAllows() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let home = FakeHome(roots: [.documents])
        let lister = FakeLister(["Documents": .failure(POSIXError(.EPERM))])
        let files = FileManager.default
        let links = home.url.appendingPathComponent("Links", isDirectory: true)
        try files.createDirectory(at: links, withIntermediateDirectories: true)
        try files.createDirectory(at: home.url.appendingPathComponent("Pictures"), withIntermediateDirectories: true)
        try Data("12345".utf8).write(to: home.url.appendingPathComponent("Pictures/real.txt"))
        try writePNG(home[.documents].appendingPathComponent("hero.png"))
        try files.createSymbolicLink(atPath: links.appendingPathComponent("toPicture").path, withDestinationPath: "../Pictures/real.txt")
        try files.createSymbolicLink(atPath: links.appendingPathComponent("toSecret").path,
                                     withDestinationPath: home[.documents].appendingPathComponent("hero.png").path)

        let listed = try await withRoots(home, lister) {
            try await MCPTestSupport.call("list_files", ["path": .string(links.path)], in: workspace)
        }
        let sizes = Dictionary(uniqueKeysWithValues: (listed["files"]?.arrayValue ?? []).compactMap { entry -> (String, Value)? in
            guard let object = entry.objectValue, let name = object["name"]?.stringValue else { return nil }
            return (name, object["size"] ?? .null)
        })
        #expect(sizes == ["toPicture": 5, "toSecret": .null])
        #expect(lister.listed == ["Documents"])
    }

    // MARK: Working normally

    @Test func grantedRootsWorkNormally() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let home = FakeHome(roots: [.documents])
        let lister = FakeLister()
        let documents = home[.documents]
        let image = documents.appendingPathComponent("Client/hero.png")
        try writePNG(image)

        try await withRoots(home, lister) {
            let info = try await MCPTestSupport.call("get_file_info", ["path": .string(image.path)], in: workspace)
            #expect(info["exists"] == .bool(true) && info["image_size"] == .object(["width": 4, "height": 4]))
            let listed = try await MCPTestSupport.call("list_files", ["path": .string(documents.path), "recursive": true], in: workspace)
            #expect(listed["files"]?.arrayValue?.count == 2 && listed["skipped"] == nil)
            try await MCPTestSupport.call("add_image_layer", ["path": .string(image.path)], in: workspace)
            try await MCPTestSupport.call("export_image", ["path": .string(documents.path + "/Out/composite.png")], in: workspace)
            try await MCPTestSupport.call("save_document_as", ["path": .string(documents.path + "/Out/poster.comp")], in: workspace)
            try await MCPTestSupport.call("save_document", in: workspace)
            let opened = try await MCPTestSupport.call("open_document", ["path": .string(image.path)], in: workspace)
            #expect(opened["already_open"] == .bool(false))
        }
        #expect(files(in: documents).isSuperset(of: ["Out/composite.png", "Out/poster.comp"]))
        #expect(lister.listed.allSatisfy { $0 == "Documents" } && !lister.listed.isEmpty)
    }

    private func files(in folder: URL) -> Set<String> { Set(contents(of: folder)) }

    /// One call asks macOS about a location once, however many times it looks at paths there (the path, then the
    /// file it writes, then the document's own file); the next call asks again.
    @Test func eachCallChecksALocationOnce() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let home = FakeHome(roots: [.documents])
        let lister = FakeLister()
        let documents = home[.documents]
        let image = documents.appendingPathComponent("hero.png")
        try writePNG(image)

        try await withRoots(home, lister) {
            for (tool, args) in [
                ("save_document_as", ["path": Value.string(documents.path + "/poster.comp")]),
                ("save_document_as", ["path": .string(documents.path + "/poster.comp")]),
                ("save_document", [:]),
                ("export_image", ["path": .string(documents.path + "/out/poster.png")]),
                ("open_document", ["path": .string(documents.path + "/poster")]),
                ("open_document", ["path": .string(image.path)]),
            ] {
                let before = lister.listed.count
                try await MCPTestSupport.call(tool, args, in: workspace)
                #expect(lister.listed.count == before + 1, "\(tool) \(args): listed Documents \(lister.listed.count - before) times")
            }
        }
    }

    /// An edit the owner starts in the app while a call waits on macOS fails the save or export cleanly: nothing is
    /// written with the edit half-done.
    @Test func anEditStartedDuringTheAccessWaitStopsASaveOrExport() async throws {
        let home = FakeHome(roots: [.documents])
        let documents = home[.documents]
        let own = documents.appendingPathComponent("own.comp")
        func modified(_ url: URL) -> Date? {
            try? url.appendingPathComponent("manifest.json").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        // The copy and the export go in a folder that doesn't exist yet: a refused call must not leave it behind.
        for (tool, target) in [("save_document", "own.comp"), ("save_document_as", "New/copy.comp"), ("export_image", "New/out.png")] {
            // The owner answers the prompt within the call's two seconds; a machine too loaded for that makes the call
            // report the prompt as still waiting instead, and the round is tried again.
            for attempt in 1...3 {
                let workspace = MCPTestSupport.workspace(width: 8, height: 8)
                let session = workspace.current.session
                let lister = FakeLister()
                try await withRoots(home, lister) {
                    try await MCPTestSupport.call("save_document_as", ["path": .string(own.path), "overwrite": true], in: workspace)
                    try await MCPTestSupport.call("add_blank_layer", in: workspace)
                }
                let saved = modified(own)
                lister.answer("Documents", .hang)
                let listed = lister.listed.count
                let args: [String: Value] = tool == "save_document" ? [:] : ["path": .string(documents.appendingPathComponent(target).path)]
                let call = Task { await withRoots(home, lister) { await MCPToolRegistry.call(tool, args, workspace: workspace) } }
                // Once the call is waiting on macOS, the owner starts typing text in the app, then answers the prompt.
                // Typing before the call got there would be refused by its first check, not the one after the wait.
                let start = ContinuousClock.now
                while lister.listed.count == listed, start.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(5)) }
                try #require(lister.listed.count > listed, "\(tool) never reached the access check")
                session.beginText(at: CGPoint(x: 2, y: 2))
                #expect(session.textDraft != nil)
                lister.release()
                let result = await call.value
                session.cancelText()
                let error = result.structuredContent?.objectValue?["error"]?.objectValue
                if error?["details"]?.objectValue?["code"]?.stringValue == "folder_access_pending", attempt < 3 { continue }
                #expect(result.isError == true, "\(tool) went ahead while text was being typed: \(String(describing: result.structuredContent))")
                #expect(error?["guard"]?.stringValue == "can_start_project_operation", "\(tool): \(String(describing: error))")
                if tool == "save_document" {
                    #expect(modified(own) == saved && session.isModified)
                } else {
                    #expect(!FileManager.default.fileExists(atPath: documents.appendingPathComponent("New").path), "\(tool) made its folder")
                }
                break
            }
        }
    }

    /// A Save As the owner finishes while save_document waits on macOS moves the document to another file, here in
    /// another format: the save then writes that file as that format, and never puts the document back on the old one.
    @Test func aSaveAsDuringTheAccessWaitIsWhereSaveDocumentWrites() async throws {
        let home = FakeHome(roots: [.documents])
        let own = home[.documents].appendingPathComponent("own.comp")
        let manifest = own.appendingPathComponent("manifest.json")
        for attempt in 1...3 {
            let workspace = MCPTestSupport.workspace(width: 8, height: 8)
            let session = workspace.current.session
            let moved = MCPTestSupport.tempFile("Moved.psd")
            let lister = FakeLister()
            try await withRoots(home, lister) {
                try await MCPTestSupport.call("save_document_as", ["path": .string(own.path), "overwrite": true], in: workspace)
                try await MCPTestSupport.call("add_blank_layer", in: workspace)
            }
            let saved = try Data(contentsOf: manifest)
            lister.answer("Documents", .hang)
            let listed = lister.listed.count
            let call = Task { await withRoots(home, lister) { await MCPToolRegistry.call("save_document", [:], workspace: workspace) } }
            let start = ContinuousClock.now
            while lister.listed.count == listed, start.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(5)) }
            try #require(lister.listed.count > listed, "save_document never reached the access check")
            // The owner's Save As finishes meanwhile: the document now lives in a Photoshop file elsewhere.
            session.projectURL = moved
            session.documentFormat = .psd
            lister.release()
            let result = await call.value
            let object = result.structuredContent?.objectValue ?? [:]
            if object["error"]?.objectValue?["details"]?.objectValue?["code"]?.stringValue == "folder_access_pending", attempt < 3 { continue }
            #expect(result.isError != true, "\(object)")
            #expect(object["path"]?.stringValue == moved.path && object["format"]?.stringValue == "psd", "\(object)")
            #expect(session.projectURL == moved && session.documentFormat == .psd && !session.isModified)
            #expect(try Data(contentsOf: moved).prefix(4) == Data("8BPS".utf8))
            #expect(try Data(contentsOf: manifest) == saved, "The old file was written")
            break
        }
    }

    /// An edit the owner makes while revert_document waits on macOS is unsaved work: without discard_changes the
    /// revert is refused instead of reloading the file over it and wiping the undo history.
    @Test func anEditMadeDuringTheAccessWaitStopsARevert() async throws {
        let home = FakeHome(roots: [.documents])
        let own = home[.documents].appendingPathComponent("own.comp")
        for attempt in 1...3 {
            let workspace = MCPTestSupport.workspace(width: 8, height: 8)
            let session = workspace.current.session
            let lister = FakeLister()
            _ = try await withRoots(home, lister) {
                try await MCPTestSupport.call("save_document_as", ["path": .string(own.path), "overwrite": true], in: workspace)
            }
            #expect(!session.isModified)
            lister.answer("Documents", .hang)
            let listed = lister.listed.count
            let call = Task { await withRoots(home, lister) { await MCPToolRegistry.call("revert_document", [:], workspace: workspace) } }
            let start = ContinuousClock.now
            while lister.listed.count == listed, start.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(5)) }
            try #require(lister.listed.count > listed, "The revert never reached the access check")
            // The owner adds a layer, then answers the prompt.
            session.addBlankLayer()
            let layers = session.document?.layers.count
            lister.release()
            let result = await call.value
            let error = result.structuredContent?.objectValue?["error"]?.objectValue
            if error?["details"]?.objectValue?["code"]?.stringValue == "folder_access_pending", attempt < 3 { continue }
            #expect(result.isError == true, "The revert threw the owner's edit away: \(String(describing: result.structuredContent))")
            #expect(error?["guard"]?.stringValue == "unsaved_changes", "\(String(describing: error))")
            #expect(session.document?.layers.count == layers && session.isModified && session.history.undoCount > 0)
            break
        }
    }

    /// A refused path is named as a call that went through would name it: `standardizedFileURL`'s spelling, with
    /// "." and ".." worked out.
    @Test func aRefusedPathIsSpelledAsSuccessResultsSpellIt() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let home = FakeHome(roots: [.documents])
        let lister = FakeLister(["Documents": .failure(POSIXError(.EPERM))])
        let spelled = home[.documents].path + "/Drafts/../Client/./hero.png"
        let standardized = URL(fileURLWithPath: spelled).standardizedFileURL.path
        #expect(standardized == home[.documents].path + "/Client/hero.png")

        try await withRoots(home, lister) {
            for (tool, args, code) in [
                ("get_file_info", ["path": Value.string(spelled)], "io_error"),
                ("export_image", ["path": .string(spelled)], "io_error"),
            ] {
                let result = try await MCPTestSupport.call(tool, args, in: workspace, expectError: code)
                expectRefusal(result, "folder_access_denied", path: standardized)
            }
        }
    }

    @Test func pathsOutsideEveryRootAreNeverProbed() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let home = FakeHome(roots: [.documents])
        let lister = FakeLister()
        let image = MCPTestSupport.tempFile("outside.png")
        try writePNG(image)
        let folder = image.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }

        try await withRoots(home, lister) {
            try await MCPTestSupport.call("get_file_info", ["path": .string(image.path)], in: workspace)
            try await MCPTestSupport.call("list_files", ["path": .string(folder.path), "recursive": true], in: workspace)
            try await MCPTestSupport.call("add_image_layer", ["path": .string(image.path)], in: workspace)
            try await MCPTestSupport.call("export_image", ["path": .string(folder.path + "/out.png")], in: workspace)
            try await MCPTestSupport.call("save_document_as", ["path": .string(folder.path + "/out.comp")], in: workspace)
            try await MCPTestSupport.call("open_document", ["path": .string(image.path)], in: workspace)
            // Relative paths land in the Agent folder, which no root holds.
            try await MCPTestSupport.call("export_image", ["path": .string("folder-access-\(UUID().uuidString).png")], in: workspace)
        }
        #expect(lister.listed.isEmpty)
    }

    // MARK: get_app_info

    @Test func getAppInfoReportsFolderAccessWithinOneTimeout() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let home = FakeHome(roots: [.documents, .desktop, .downloads, .cloudStorage])
        let lister = FakeLister(["Desktop": .hang, "Downloads": .hang,
                                 "CloudStorage": .folders(["Dropbox", "GoogleDrive-a"]), "Dropbox": .failure(POSIXError(.EPERM))])
        defer { lister.release() }

        try await withRoots(home, lister) {
            // Checked earlier this session: reported as found, not probed again.
            #expect(await FolderAccess.probe(.documents, timeout: .seconds(120)) == .granted)
            #expect(await FolderAccess.probe(.cloudStorage, timeout: .seconds(120)) == .denied)
            let before = lister.listed.count

            // Desktop and Downloads were never checked, and their listings never return: probed side by side.
            let (info, elapsed, stall) = try await timed { try await MCPTestSupport.call("get_app_info", in: workspace) }
            #expect(info["folder_access"] == .object(["documents": "granted", "desktop": "not_determined",
                                                      "downloads": "not_determined", "cloud_storage": "denied"]))
            #expect(info["folder_access_detail"] == .object([
                "cloud_storage": .object(["denied_folders": ["Dropbox"], "pending_folders": []]),
            ]))
            #expect(elapsed < .seconds(3) + stall, "took \(elapsed) with the main actor held \(stall)")
            #expect(Set(lister.listed.dropFirst(before)) == ["Desktop", "Downloads"])

            // Now every root has a state: the next call probes nothing.
            let count = lister.listed.count
            let again = try await MCPTestSupport.call("get_app_info", in: workspace)
            #expect(again["folder_access"] == info["folder_access"])
            #expect(lister.listed.count == count)
        }
    }

    // MARK: Importing profiles

    /// A usable profile with a name and uuid of its own, so a stray import could be found in the shared test library.
    private func writeProfile(named name: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ProfileFixture.xmp(name: name, uuid: ProfileAdjustmentTests.uniqueUUID(), group: "MCP Tests",
                               rgb: ProfileFixture.rgbTable(divisions: 5)).write(to: url)
    }

    @Test func importingAProfileFromADeniedRootFailsFastAndImportsNothing() async throws {
        // workspace() installs the temporary profile library: even a wrong import never reaches the real one.
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let home = FakeHome(roots: [.documents])
        let lister = FakeLister(["Documents": .failure(POSIXError(.EPERM))])
        let folder = home[.documents].appendingPathComponent("Profiles", isDirectory: true)
        let file = folder.appendingPathComponent("Denied.xmp")
        let name = "Denied \(UUID().uuidString)"
        try writeProfile(named: name, to: file)

        try await withRoots(home, lister) {
            // A profile file and a folder of them.
            for path in [file, folder] {
                let (result, elapsed, stall) = try await timed {
                    try await MCPTestSupport.call("import_profile", ["path": .string(path.path)], in: workspace, expectError: "io_error")
                }
                expectRefusal(result, "folder_access_denied", path: path.path)
                #expect(elapsed < .seconds(3) + stall, "\(path.lastPathComponent) took \(elapsed) with the main actor held \(stall)")
            }
        }
        #expect(Set(lister.listed) == ["Documents"])
        let found = try await MCPTestSupport.call("list_profiles", ["query": .string(name), "refresh": true], in: workspace)
        #expect(MCPValues.number(found["total"]) == 0)
    }

    @Test func importingAProfileWhileAPromptWaitsIsBusyWithinTheTimeout() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let home = FakeHome(roots: [.documents])
        let lister = FakeLister(["Documents": .hang])
        defer { lister.release() }
        let file = home[.documents].appendingPathComponent("Waiting.xmp")
        try writeProfile(named: "Waiting \(UUID().uuidString)", to: file)

        let (result, elapsed, stall) = try await withRoots(home, lister) {
            try await timed {
                try await MCPTestSupport.call("import_profile", ["path": .string(file.path)], in: workspace, expectError: "busy")
            }
        }
        expectRefusal(result, "folder_access_pending", path: file.path)
        #expect(elapsed >= FolderAccess.defaultTimeout)
        #expect(elapsed < .seconds(3) + stall, "took \(elapsed) with the main actor held \(stall)")
    }

    // MARK: Smart objects

    @Test func smartObjectToolsRefuseADeniedPathAndChangeNothing() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let session = workspace.current.session
        let home = FakeHome(roots: [.documents])
        let lister = FakeLister(["Documents": .failure(POSIXError(.EPERM))])
        let documents = home[.documents]
        let image = documents.appendingPathComponent("Client/badge.png")
        try writePNG(image)
        // A smart object placed from outside every root, for the other two tools to replace or export the contents of.
        let outside = MCPTestSupport.tempFile("smart-\(UUID().uuidString).png")
        try writePNG(outside)
        let export = documents.appendingPathComponent("Client/contents.png")

        try await withRoots(home, lister) {
            let placed = try await MCPTestSupport.call("place_smart_object", ["path": .string(outside.path), "name": "Badge"],
                                                       in: workspace)
            let id = try #require(placed["layer_id"]?.stringValue)
            let document = try #require(session.document)
            let undoCount = session.history.undoCount
            let calls: [(String, [String: Value], URL)] = [
                ("place_smart_object", ["path": .string(image.path)], image),
                ("place_smart_object", ["path": .string(image.path), "fit_rect": ["x": 0, "y": 0, "width": 4, "height": 4]], image),
                ("replace_smart_object_contents", ["layer": .string(id), "path": .string(image.path)], image),
                ("export_smart_object_contents", ["layer": .string(id), "path": .string(export.path)], export),
                // Without an extension: the path is refused as given, before the contents' own extension is added.
                ("export_smart_object_contents", ["layer": .string(id), "path": .string(documents.path + "/Client/contents")],
                 documents.appendingPathComponent("Client/contents")),
            ]
            for (tool, args, path) in calls {
                let (result, elapsed, stall) = try await timed {
                    try await MCPTestSupport.call(tool, args, in: workspace, expectError: "io_error")
                }
                expectRefusal(result, "folder_access_denied", path: path.path)
                #expect(elapsed < .seconds(3) + stall, "\(tool) took \(elapsed) with the main actor held \(stall)")
            }
            #expect(session.document == document && session.history.undoCount == undoCount && !session.isProjectBusy)
        }
        #expect(contents(of: documents) == ["Client", "Client/badge.png"])
        #expect(Set(lister.listed) == ["Documents"])
    }

    @Test func placingASmartObjectWhileAPromptWaitsIsBusyWithinTheTimeout() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let session = workspace.current.session
        let home = FakeHome(roots: [.documents])
        let lister = FakeLister(["Documents": .hang])
        defer { lister.release() }
        let file = home[.documents].appendingPathComponent("badge.png")
        try writePNG(file)
        let document = try #require(session.document)
        let undoCount = session.history.undoCount

        let (result, elapsed, stall) = try await withRoots(home, lister) {
            try await timed {
                try await MCPTestSupport.call("place_smart_object", ["path": .string(file.path)], in: workspace, expectError: "busy")
            }
        }
        expectRefusal(result, "folder_access_pending", path: file.path)
        #expect(elapsed >= FolderAccess.defaultTimeout)
        #expect(elapsed < .seconds(3) + stall, "took \(elapsed) with the main actor held \(stall)")
        #expect(session.document == document && session.history.undoCount == undoCount && !session.isProjectBusy)
    }

    // MARK: Error mapping

    @Test func folderAccessErrorsBecomeToolErrors() {
        let path = "/Users/someone/Desktop/hero.psd"
        let denied = MCPToolError.from(FolderAccessError(reason: .denied, root: .desktop, path: path))
        #expect(denied.code == .ioError && denied.hint == Self.deniedHint && denied.guardName == nil)
        #expect(denied.details == ["code": "folder_access_denied", "path": .string(path), "root": "desktop"])
        #expect(denied.message.contains(path))

        let pending = MCPToolError.from(FolderAccessError(reason: .pending, root: .cloudStorage, path: path))
        #expect(pending.code == .busy && pending.hint == Self.pendingHint)
        #expect(pending.details == ["code": "folder_access_pending", "path": .string(path), "root": "cloud_storage"])
    }

    // MARK: - Nothing touches a file before the check

    /// Calls in Compositor/MCP that stat, open, read, list, reveal or write a file. Each may only run on a URL whose
    /// macOS folder access was checked first; the helpers at the end touch only URLs their callers checked, and
    /// count as touches wherever they're called.
    private static let fileTouches = [
        #"\bFileManager\b"#, #"\bfileExists\b"#, #"\bData\(contentsOf"#, #"\bcontentsOfDirectory\b"#, #"\bsubpaths\b"#,
        #"\bresourceValues\b"#, #"\bCGImageSourceCreateWithURL\b"#, #"\bcreateDirectory\b"#, #"\.write\(to"#, #"\bremoveItem\b"#,
        #"\bdestinationOfSymbolicLink\b"#, #"\bresolvingSymlinksInPath\b"#, #"\bstandardizedFileURL\b"#, #"\brealpath\("#,
        #"\bl?stat\("#, #"\bopendir\("#, #"\bNSImage\(contentsOf"#, #"\bactivateFileViewerSelecting\b"#,
        #"\.openDocument\(at"#, #"\.revertDocument\("#, #"\.tab\(showing"#, #"\bImageImporter\b"#, #"\bProjectStore\b"#,
        #"\bImageExporter\.shared\.write\("#, #"\bString\(contentsOf"#, #"\bNSData\(contentsOf"#, #"\bFileHandle\b"#,
        #"\bCGImageDestinationCreateWithURL\b"#, #"\bCGDataProvider\(url"#, #"\bInputStream\(url"#, #"(?<![\w.])f?open\("#,
        #"\bNSFileCoordinator\b"#, #"\bcheckResourceIsReachable\b"#,
        #"\brefuseExisting\("#, #"\bcreateParentFolder\("#, #"\bsaveFile\("#, #"\bwritePhotoshop\("#, #"\bPSDExporter\.shared\.export\("#,
        #"\bdecodeImageFile\("#, #"\bFileInfo\("#,
        #"\bMCPPaths\.list\("#, #"\bshowInFinder\("#, #"\bprofileImportFiles\("#, #"\bprotectedRoots\("#,
    ]

    /// Calls that check folder access.
    private static let accessChecks = [#"\bresolveReachable\("#, #"\bensureReachable\("#, #"\bprepareForWriting\("#,
                                       #"\bcheckForWriting\("#, #"\bMCPPaths\.exists\("#]

    private enum Rule {
        /// Allowed once the function has checked access on an earlier line.
        case afterCheck
        /// A helper that touches only URLs its callers checked (its call sites are file touches themselves).
        case checkedByCaller
        /// Compositor's own files (the Agent folder, the endpoint and token files, the app), never a path from a tool call.
        case compositorsOwnFile
    }

    /// Every function in Compositor/MCP allowed to touch a file, by file and function (or static property).
    private static let allowed: [String: [String: Rule]] = [
        "MCPPaths.swift": [
            "agentFolder": .compositorsOwnFile, "reveal": .compositorsOwnFile,
            "resolveReachable": .afterCheck, "prepareForWriting": .afterCheck, "checkForWriting": .afterCheck, "exists": .afterCheck,
            "isSameFile": .afterCheck,
            "refuseExisting": .checkedByCaller, "createParentFolder": .checkedByCaller, "list": .checkedByCaller, "contents": .checkedByCaller,
            "targetSize": .checkedByCaller, "realPath": .checkedByCaller,
        ],
        "MCPTools+Documents.swift": [
            "openDocument": .afterCheck, "revertDocument": .afterCheck, "saveDocument": .afterCheck, "saveDocumentAs": .afterCheck,
            "exportImage": .afterCheck, "saveFile": .checkedByCaller, "writePhotoshop": .checkedByCaller,
        ],
        "MCPTools+Files.swift": [
            "showInFinder": .checkedByCaller, "listFiles": .afterCheck, "getFileInfo": .afterCheck, "init": .checkedByCaller,
            "imageSize": .checkedByCaller, "revealInFinder": .afterCheck,
        ],
        "MCPTools+Layers.swift": ["addImageLayer": .afterCheck],
        "MCPTools+Paint.swift": [
            "getLayerPixels": .afterCheck, "setLayerPixels": .afterCheck, "pasteImageIntoLayer": .afterCheck,
            "decodeImageFile": .checkedByCaller,
        ],
        "MCPTools+SmartObjects.swift": [
            // Whether the path it checked is a folder, and how large the file is.
            "contentsFile": .afterCheck,
            // Whether the path it checked (with the contents' extension added) is a folder, then the write.
            "exportSmartObjectContents": .afterCheck,
        ],
        "MCPTools+Profiles.swift": [
            // Whether the path it checked is a file or a folder.
            "importProfile": .afterCheck,
            // Walks the folder importProfile checked; the listing checks each protected folder before entering it,
            // and only the files it found are looked at (whether each is a regular file, not following links).
            "profileImportFiles": .checkedByCaller,
            // The real path of the folder importProfile checked, and of each root's parent, which is in no root
            // (realPath is protectedRoots' own helper).
            "protectedRoots": .checkedByCaller, "realPath": .checkedByCaller,
        ],
        "MCPEndpointFile.swift": [
            "write": .compositorsOwnFile, "remove": .compositorsOwnFile, "read": .compositorsOwnFile, "removeStale": .compositorsOwnFile,
        ],
        // The access token file and its folder.
        "MCPAccessToken.swift": [
            "loadOrCreate": .compositorsOwnFile, "secureFolder": .compositorsOwnFile, "writeOwnerOnly": .compositorsOwnFile,
        ],
        "MCPSettings.swift": ["applicationSupportBaseURL": .compositorsOwnFile, "agentRoot": .compositorsOwnFile],
        // The app bundle's own location.
        "MCPClientSnippets.swift": ["isInApplicationsFolder": .compositorsOwnFile],
    ]

    /// The scan knows every way Compositor/MCP could read or write a file, not just the ones it uses today.
    @Test func theScanRecognizesEveryWayToTouchAFile() throws {
        let touches = try NSRegularExpression(pattern: Self.fileTouches.joined(separator: "|"))
        let samples = [
            "let text = try String(contentsOf: url, encoding: .utf8)",
            "let data = NSData(contentsOf: url)",
            "let handle = try FileHandle(forReadingFrom: url)",
            "let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil)",
            "let provider = CGDataProvider(url: url as CFURL)",
            "let stream = InputStream(url: url)",
            "let file = fopen(url.path, \"r\")",
            "let descriptor = open(url.path, O_RDONLY)",
            "let coordinator = NSFileCoordinator(filePresenter: nil)",
            "_ = try url.checkResourceIsReachable()",
        ]
        for sample in samples {
            #expect(touches.firstMatch(in: sample, range: NSRange(location: 0, length: (sample as NSString).length)) != nil,
                    "Not recognized as touching a file: \(sample)")
        }
        // Opening a Settings pane by its URL isn't the POSIX call, and neither is a method that ends in "open".
        for sample in ["NSWorkspace.shared.open(Self.privacySettingsURL)", "tab.reopen(later)"] {
            #expect(touches.firstMatch(in: sample, range: NSRange(location: 0, length: (sample as NSString).length)) == nil, "\(sample)")
        }
    }

    /// `timed` stops its stall meter's thread however the body ends, so a test that throws leaves nothing running.
    @Test func timedStopsItsMeterWhenTheBodyThrows() async {
        struct Failure: Error {}
        let meter = StallMeter()
        _ = try? await timed(meter: meter) { throw Failure() }
        #expect(!meter.isRunning)
    }

    @Test func nothingInTheMCPLayerTouchesAFileBeforeCheckingAccess() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Compositor/MCP", isDirectory: true)
        let sources = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }.sorted()
        #expect(sources.contains("MCPPaths.swift") && sources.contains("MCPTools+Documents.swift"))
        let touches = try NSRegularExpression(pattern: Self.fileTouches.joined(separator: "|"))
        let checks = try NSRegularExpression(pattern: Self.accessChecks.joined(separator: "|"))
        let declaration = try NSRegularExpression(pattern: #"^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:private|fileprivate|internal|public|static|class|nonisolated|override|mutating|final|convenience|required)(?:\([^)]*\))?\s+)*(?:func\s+(\w+)|(init)\s*[?!]?\s*[(<])"#)
        let staticProperty = try NSRegularExpression(pattern: #"^\s*(?:@[\w.]+\s+)*(?:(?:private|fileprivate|internal|public|nonisolated)(?:\([^)]*\))?\s+)*static\s+(?:var|let)\s+(\w+)"#)
        /// The first capture group `expression` finds in `line`, if it matches.
        func declared(_ expression: NSRegularExpression, in line: String) -> String? {
            let text = line as NSString
            guard let match = expression.firstMatch(in: line, range: NSRange(location: 0, length: text.length)) else { return nil }
            return (1..<match.numberOfRanges).lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound }
                .map { text.substring(with: $0) } ?? "?"
        }
        func matches(_ expression: NSRegularExpression, _ line: String) -> Bool {
            expression.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
        }

        var used: Set<String> = []
        for source in sources {
            let lines = try String(contentsOf: folder.appendingPathComponent(source), encoding: .utf8).components(separatedBy: "\n")
            var function = "<top>"
            var checked = false
            for (number, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") { continue }
                var declares = false
                if line.contains("func ") || line.contains("init") || line.contains("static "),
                   let name = declared(declaration, in: raw) ?? declared(staticProperty, in: raw) {
                    function = name
                    checked = false
                    declares = true
                }
                if !declares, matches(checks, raw) { checked = true }
                guard matches(touches, raw) else { continue }
                let site = "\(source):\(number + 1) in \(function): \(line)"
                guard let rule = Self.allowed[source]?[function] else {
                    Issue.record("A file is touched where no folder-access rule allows it: \(site)")
                    continue
                }
                used.insert("\(source) \(function)")
                if case .afterCheck = rule, !checked {
                    Issue.record("A file is touched before its folder access is checked: \(site)")
                }
            }
        }
        let listed = Set(Self.allowed.flatMap { file, functions in functions.keys.map { "\(file) \($0)" } })
        #expect(listed.subtracting(used).isEmpty, "Allowed but touching no file any more (drop them): \(listed.subtracting(used).sorted())")
    }
}
