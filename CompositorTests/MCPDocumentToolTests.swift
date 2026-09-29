import CoreGraphics
import Foundation
import ImageIO
import Testing
import MCP
@testable import Compositor

/// The Documents domain: opening, saving, exporting, closing, duplicating and reverting documents, their safety
/// defaults (no overwrite, no silent discard, the tab cap), and what get_document and get_app_info report.
@MainActor struct MCPDocumentToolTests {
    // MARK: Fixtures

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MCPDocumentToolTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func solid(width: Int, height: Int, red: CGFloat = 0, green: CGFloat = 0.5, blue: CGFloat = 1) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// A 4×2 Photoshop file: a pixel layer and a Dissolve layer (a conversion to report).
    private func photoshopFile(in folder: URL, name: String = "Client Template.psd") throws -> URL {
        let fill = try solid(width: 2, height: 2)
        var sky = PSDRecord(id: UUID(), name: "Sky")
        sky.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        sky.image = fill
        var dissolved = PSDRecord(id: UUID(), name: "Dissolved")
        dissolved.bounds = CGRect(x: 2, y: 0, width: 2, height: 2)
        dissolved.image = fill
        dissolved.blendKey = "diss"
        let data = try PSDFixture.data(PSDDocument(width: 4, height: 2, resolution: 144, layers: [sky, dissolved]),
                                       composite: try solid(width: 4, height: 2))
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func decoded(_ path: String) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> MCPRender.Sample {
        try #require(try MCPRender.Pixels(image).sample(x: x, y: y))
    }

    private func errorObject(_ result: [String: Value]) -> [String: Value] {
        result["error"]?.objectValue ?? [:]
    }

    // MARK: Saving

    @Test func saveDocumentAsRefusesAnExistingFileWithoutOverwrite() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        let session = workspace.current.session
        let url = MCPTestSupport.tempFile("existing.comp")
        let saved = try await MCPTestSupport.call("save_document_as", ["path": .string(url.path)], in: workspace)
        #expect(saved["path"]?.stringValue == url.path)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("QuickLook/Preview.jpg").path))
        #expect(session.projectURL?.path == url.path && !session.isModified)
        // The package now exists, so the path resolves as a folder: still the same document and the same file.
        let reopened = try await MCPTestSupport.call("open_document", ["path": .string(url.path)], in: workspace)
        #expect(reopened["already_open"] == .bool(true) && workspace.tabs.count == 1)
        try await MCPTestSupport.call("save_document_as", ["path": .string(url.path)], in: workspace)

        try await MCPTestSupport.call("new_document", ["width": 8, "height": 8], in: workspace)
        let refused = try await MCPTestSupport.call("save_document_as", ["path": .string(url.path)], in: workspace, expectError: "io_error")
        #expect(errorObject(refused)["details"]?.objectValue?["code"]?.stringValue == "file_exists")
        try await MCPTestSupport.call("save_document_as", ["path": .string(url.path), "overwrite": true], in: workspace)
        #expect(try await ProjectStore.shared.load(from: url).manifest.width == 8)

        // A copy leaves the document where it was, still unsaved.
        try await MCPTestSupport.call("add_blank_layer", in: workspace)
        let current = workspace.current.session
        let copy = MCPTestSupport.tempFile("copy")
        let written = try await MCPTestSupport.call("save_document_as", ["path": .string(copy.path), "set_as_current": false], in: workspace)
        #expect(written["path"]?.stringValue == copy.path + ".comp")
        #expect(current.projectURL?.path == url.path && current.isModified)
    }

    @Test func saveDocumentAsPhotoshopWritesALayeredFileTheDocumentThenLivesIn() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 8)
        let session = workspace.current.session
        try await MCPTestSupport.call("add_blank_layer", ["name": "Paint"], in: workspace)
        let target = MCPTestSupport.tempFile("out.psd")
        let saved = try await MCPTestSupport.call("save_document_as", ["path": .string(target.path)], in: workspace)
        #expect(saved["path"]?.stringValue == target.path)
        #expect(saved["format"]?.stringValue == "psd" && saved["saved"] == .bool(true))
        #expect(saved["set_as_current"] == .bool(true) && saved["is_modified"] == .bool(false))
        #expect(saved["warnings"]?.arrayValue == [])
        let written = try PSDReader.read(from: target)
        #expect(written.width == 16 && written.height == 8)
        #expect(written.layers.map(\.name) == ["Layer 1", "Paint"])
        #expect(session.projectURL?.path == target.path && session.documentFormat == .psd && !session.isModified)
        #expect(workspace.current.title == "out")

        // save_document keeps writing the PSD.
        try await MCPTestSupport.call("add_blank_layer", ["name": "Later"], in: workspace)
        let again = try await MCPTestSupport.call("save_document", in: workspace)
        #expect(again["path"]?.stringValue == target.path && again["format"]?.stringValue == "psd")
        #expect(try PSDReader.read(from: target).layers.map(\.name) == ["Layer 1", "Paint", "Later"])
        #expect(!session.isModified && session.documentFormat == .psd)

        // 'format' names the type for a path without an extension; a copy leaves the document where it was.
        try await MCPTestSupport.call("add_blank_layer", ["name": "Unsaved"], in: workspace)
        let named = MCPTestSupport.tempFile("named")
        let copy = try await MCPTestSupport.call("save_document_as", ["path": .string(named.path), "format": "psd",
                                                                       "set_as_current": false], in: workspace)
        #expect(copy["path"]?.stringValue == named.path + ".psd" && copy["set_as_current"] == .bool(false))
        #expect(try PSDReader.read(from: URL(fileURLWithPath: named.path + ".psd")).layers.count == 4)
        #expect(session.projectURL?.path == target.path && session.isModified)

        // The extension and an explicit format must agree.
        try await MCPTestSupport.call("save_document_as", ["path": .string(target.path), "format": "comp"], in: workspace,
                                      expectError: "invalid_argument")
    }

    /// The Photoshop file a document was opened from is a template, not the document's own file: saving over it takes
    /// overwrite, from save_document_as only.
    @Test func savingOverThePhotoshopFileADocumentCameFromNeedsOverwrite() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try photoshopFile(in: root)
        let original = try Data(contentsOf: url)
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        try await MCPTestSupport.call("open_document", ["path": .string(url.path)], in: workspace)
        let session = workspace.current.session
        try await MCPTestSupport.call("rename_layer", ["layer": "Sky", "name": "Night"], in: workspace)

        let noFile = try await MCPTestSupport.call("save_document", in: workspace, expectError: "precondition_failed")
        #expect(errorObject(noFile)["guard"]?.stringValue == "project_file")
        #expect(errorObject(noFile)["hint"]?.stringValue?.contains("overwrite") == true)
        let refused = try await MCPTestSupport.call("save_document_as", ["path": .string(url.path)], in: workspace, expectError: "io_error")
        #expect(errorObject(refused)["details"]?.objectValue?["code"]?.stringValue == "file_exists")
        #expect(try Data(contentsOf: url) == original)
        #expect(session.projectURL == nil && session.isModified)

        let replaced = try await MCPTestSupport.call("save_document_as", ["path": .string(url.path), "overwrite": true], in: workspace)
        #expect(replaced["format"]?.stringValue == "psd")
        #expect(try PSDReader.read(from: url).layers.map(\.name) == ["Night", "Dissolved"])
        #expect(session.projectURL?.path == url.path && session.documentFormat == .psd && !session.isModified)
        // Now it is the document's own file.
        try await MCPTestSupport.call("rename_layer", ["layer": "Night", "name": "Dawn"], in: workspace)
        try await MCPTestSupport.call("save_document", in: workspace)
        try await MCPTestSupport.call("save_document_as", ["path": .string(url.path)], in: workspace)
        #expect(try PSDReader.read(from: url).layers.map(\.name) == ["Dawn", "Dissolved"])
    }

    /// What Photoshop can't hold exactly is refused unless the call allows it, and then listed in 'warnings'.
    @Test func aLossyPhotoshopSaveNeedsAllowLossy() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        try await MCPTestSupport.call("add_adjustment_layer", ["kind": "grain", "name": "Film"], in: workspace)
        let target = MCPTestSupport.tempFile("film.psd")
        let refused = try await MCPTestSupport.call("save_document_as", ["path": .string(target.path)], in: workspace,
                                                    expectError: "precondition_failed")
        #expect(errorObject(refused)["guard"]?.stringValue == "lossy")
        #expect(errorObject(refused)["hint"]?.stringValue?.contains("allow_lossy") == true)
        let listed = try #require(errorObject(refused)["details"]?.objectValue?["warnings"]?.arrayValue)
        #expect(listed.contains { $0.objectValue?["layer"]?.stringValue == "Film" && $0.objectValue?["lossy"] == .bool(true) })
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(workspace.current.session.projectURL == nil)

        let saved = try await MCPTestSupport.call("save_document_as", ["path": .string(target.path), "allow_lossy": true], in: workspace)
        let warnings = try #require(saved["warnings"]?.arrayValue)
        #expect(warnings.contains { $0.objectValue?["layer"]?.stringValue == "Film" && $0.objectValue?["lossy"] == .bool(true)
            && $0.objectValue?["message"]?.stringValue?.contains("rasterized") == true })
        #expect(try PSDReader.read(from: target).layers.map(\.name) == ["Layer 1", "Film (rasterized)"])
        // save_document follows the same rule.
        try await MCPTestSupport.call("save_document", in: workspace, expectError: "precondition_failed")
        try await MCPTestSupport.call("save_document", ["allow_lossy": true], in: workspace)
    }

    @Test func saveDocumentWritesOnlyTheDocumentsOwnFile() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        let session = workspace.current.session
        let refused = try await MCPTestSupport.call("save_document", in: workspace, expectError: "precondition_failed")
        #expect(errorObject(refused)["hint"]?.stringValue?.contains("save_document_as") == true)
        try await MCPTestSupport.call("save_document", ["path": "somewhere.comp"], in: workspace, expectError: "invalid_argument")

        let url = MCPTestSupport.tempFile("own.comp")
        try await MCPTestSupport.call("save_document_as", ["path": .string(url.path)], in: workspace)
        try await MCPTestSupport.call("add_blank_layer", ["name": "Later"], in: workspace)
        #expect(session.isModified)
        let saved = try await MCPTestSupport.call("save_document", in: workspace)
        #expect(saved["path"]?.stringValue == url.path)
        #expect(!session.isModified)
        let reloaded = try await ProjectStore.shared.load(from: url)
        #expect(reloaded.manifest.layers.map(\.name).contains("Later"))
    }

    // MARK: Closing

    @Test func closeDocumentRefusesAModifiedDocument() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        try await MCPTestSupport.call("new_document", ["width": 8, "height": 8], in: workspace)
        let modified = workspace.current
        #expect(modified.session.isModified)
        let refused = try await MCPTestSupport.call("close_document", in: workspace, expectError: "precondition_failed")
        #expect(errorObject(refused)["guard"]?.stringValue == "unsaved_changes")
        #expect(errorObject(refused)["hint"]?.stringValue?.contains("discard_changes") == true)
        #expect(workspace.tabs.count == 2)

        let closed = try await MCPTestSupport.call("close_document", ["discard_changes": true], in: workspace)
        #expect(closed["discarded_changes"] == .bool(true))
        #expect(closed["remaining_tabs"]?.intValue == 1)
        #expect(!workspace.tabs.contains { $0 === modified })

        // A saved document closes without asking, unless an edit is still in progress in the app.
        let url = MCPTestSupport.tempFile("close.comp")
        try await MCPTestSupport.call("save_document_as", ["path": .string(url.path)], in: workspace)
        let saved = workspace.current.session
        saved.insert(ImportedImage(image: try solid(width: 4, height: 4), thumbnail: try solid(width: 4, height: 4), name: "Box"))
        try await MCPTestSupport.call("save_document", in: workspace)
        saved.beginTransform()
        let pending = try await MCPTestSupport.call("close_document", in: workspace, expectError: "precondition_failed")
        #expect(errorObject(pending)["guard"]?.stringValue == "can_edit_layers")
        saved.cancelTransform()
        let quiet = try await MCPTestSupport.call("close_document", in: workspace)
        #expect(quiet["discarded_changes"] == .bool(false))
    }

    // MARK: Tabs

    @Test func theThirtyThirdNewDocumentFailsWithTheTabCap() async throws {
        _ = MCPTestSupport.workspace()
        let workspace = ProjectWorkspace()
        for _ in 0..<MCPSettings.maxTabs {
            try await MCPTestSupport.call("new_document", ["width": 8, "height": 8], in: workspace)
        }
        #expect(workspace.tabs.count == 32)
        let result = try await MCPTestSupport.call("new_document", ["width": 8, "height": 8], in: workspace, expectError: "precondition_failed")
        #expect(errorObject(result)["guard"]?.stringValue == "max_tabs")
        try await MCPTestSupport.call("duplicate_document", in: workspace, expectError: "precondition_failed")
        #expect(workspace.tabs.count == 32)
    }

    @Test func newDocumentNamesTheTabAndFillsItsFirstLayer() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        let result = try await MCPTestSupport.call("new_document", [
            "width": 20, "height": 10, "resolution": 300, "name": "Hero Banner", "fill": "#ff0000",
        ], in: workspace)
        let tab = workspace.current
        let session = tab.session
        #expect(result["title"]?.stringValue == "Hero Banner")
        #expect(result["tab_index"]?.intValue == 1)
        #expect(tab.title == "Hero Banner")
        let document = try #require(session.document)
        #expect(document.width == 20 && document.height == 10 && document.resolution == 300)
        #expect(document.layers.map(\.name) == ["Layer 1"])
        let image = try #require(document.layers.first?.asset?.image)
        #expect(image.width == 20 && image.height == 10)
        let red = try pixel(image, x: 5, y: 5)
        #expect(red.red == 255 && red.green == 0 && red.blue == 0 && red.alpha == 255)
        // One undo step, as File > New makes.
        #expect(session.history.undoCount == 1 && session.isModified)
        #expect(result["undo"]?.objectValue?["count"]?.intValue == 1)

        try await MCPTestSupport.call("new_document", ["width": 8, "height": 8, "resolution": 0], in: workspace, expectError: "invalid_argument")
        let plain = try await MCPTestSupport.call("new_document", ["width": 8, "height": 8], in: workspace)
        #expect(plain["title"]?.stringValue?.hasPrefix("Untitled") == true)
        #expect(workspace.current.session.document?.layers.first?.asset == nil)
    }

    @Test func duplicateDocumentHasANewIdentityAndItsOwnUndo() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 16)
        let original = workspace.current
        try await MCPTestSupport.call("add_blank_layer", ["name": "Badge"], in: workspace)
        try await MCPTestSupport.call("group_layers", ["layers": ["Badge"]], in: workspace)
        let originalUndo = original.session.history.undoCount
        let originalID = try #require(original.session.document?.id)

        let result = try await MCPTestSupport.call("duplicate_document", ["name": "Variant B"], in: workspace)
        let copy = workspace.current
        #expect(copy !== original && workspace.tabs.count == 2)
        #expect(copy.title == "Variant B" && result["title"]?.stringValue == "Variant B")
        let copyDocument = try #require(copy.session.document)
        #expect(result["document_id"]?.stringValue == copyDocument.id.uuidString)
        #expect(copyDocument.id != originalID)
        let sourceLayers = try #require(original.session.document?.layers)
        #expect(copyDocument.layers.map(\.name) == sourceLayers.map(\.name))
        #expect(Set(copyDocument.layers.map(\.id)).isDisjoint(with: sourceLayers.map(\.id)))
        // Folders keep their contents under the new ids.
        let badge = try #require(copyDocument.layers.first { $0.name == "Badge" })
        #expect(copyDocument.layers.first { $0.id == badge.parentID }?.isGroup == true)
        #expect(copy.session.activeLayerID.map { id in copyDocument.layers.contains { $0.id == id } } == true)
        #expect(copy.session.projectURL == nil && copy.session.sourceURL == nil)
        // The copy exists only in memory: no history of its own yet, but unsaved.
        #expect(copy.session.history.undoCount == 0 && copy.session.isModified)

        try await MCPTestSupport.call("add_blank_layer", ["name": "Only In Copy"], in: workspace)
        #expect(original.session.history.undoCount == originalUndo)
        #expect(original.session.document?.layers.contains { $0.name == "Only In Copy" } == false)
        try await MCPTestSupport.call("undo", in: workspace)
        #expect(copy.session.document?.layers.contains { $0.name == "Only In Copy" } == false)
        #expect(original.session.history.undoCount == originalUndo)

        let untitled = try await MCPTestSupport.call("duplicate_document", ["document": 0], in: workspace)
        #expect(untitled["title"]?.stringValue == "\(original.title) copy")
    }

    // MARK: Opening

    @Test func openDocumentOnAPhotoshopFileReturnsConversionsAndATab() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try photoshopFile(in: root)
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)

        let opened = try await MCPTestSupport.call("open_document", ["path": .string(url.path)], in: workspace)
        #expect(opened["already_open"] == .bool(false))
        #expect(opened["tab_index"]?.intValue == 1)
        #expect(opened["format"]?.stringValue == "psd")
        let tab = workspace.current
        #expect(opened["tab_id"]?.stringValue == tab.id.uuidString)
        #expect(opened["document_id"]?.stringValue == tab.session.document?.id.uuidString)
        let conversions = try #require(opened["conversions"]?.arrayValue)
        #expect(conversions.contains { $0.objectValue?["layer"]?.stringValue == "Dissolved" })
        #expect(conversions.allSatisfy { $0.objectValue?["message"]?.stringValue?.isEmpty == false })
        #expect(tab.session.sourceURL?.path == url.path && tab.session.projectURL == nil)

        // Already open: the same tab, selected, with nothing new to report.
        try await MCPTestSupport.call("select_document", ["document": 0], in: workspace)
        let again = try await MCPTestSupport.call("open_document", ["path": .string(url.path)], in: workspace)
        #expect(again["already_open"] == .bool(true))
        #expect(again["tab_id"]?.stringValue == tab.id.uuidString)
        #expect(again["conversions"]?.arrayValue?.isEmpty == true)
        #expect(workspace.current === tab && workspace.tabs.count == 2)

        // Saved as .comp, the tab still answers for the Photoshop file it came from.
        let project = root.appendingPathComponent("Client Template.comp")
        try await MCPTestSupport.call("save_document_as", ["path": .string(project.path)], in: workspace)
        try await MCPTestSupport.call("select_document", ["document": 0], in: workspace)
        let saved = try await MCPTestSupport.call("open_document", ["path": .string(url.path), "select": false], in: workspace)
        #expect(saved["already_open"] == .bool(true) && saved["tab_id"]?.stringValue == tab.id.uuidString)
        #expect(workspace.current !== tab)

        try await MCPTestSupport.call("open_document", ["path": .string(root.appendingPathComponent("missing.psd").path)],
                                      in: workspace, expectError: "not_found")
        let text = root.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        try await MCPTestSupport.call("open_document", ["path": .string(text.path)], in: workspace, expectError: "io_error")
        let gif = root.appendingPathComponent("anim.gif")
        let destination = try #require(CGImageDestinationCreateWithURL(gif as CFURL, "com.compuserve.gif" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try solid(width: 4, height: 4), nil)
        #expect(CGImageDestinationFinalize(destination))
        let unsupported = try await MCPTestSupport.call("open_document", ["path": .string(gif.path)], in: workspace, expectError: "unsupported")
        #expect(errorObject(unsupported)["details"]?.objectValue?["path"]?.stringValue == gif.path)
        #expect(workspace.tabs.count == 2)
    }

    /// An SVG opens as a document of one layer, drawn into pixels at the size the file gives (upstream's SVG import).
    @Test func openDocumentOnAnSVGDrawsItIntoOneLayer() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Logo.svg")
        try Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="64" height="32"><circle cx="16" cy="16" r="16" fill="#0000ff"/></svg>"##.utf8)
            .write(to: url)
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        let opened = try await MCPTestSupport.call("open_document", ["path": .string(url.path)], in: workspace)
        let document = try #require(workspace.current.session.document)
        #expect(opened["already_open"] == .bool(false) && document.size == CGSize(width: 64, height: 32))
        #expect(document.layers.count == 1 && document.layers.first?.asset?.image.width == 64)
        #expect(workspace.current.session.sourceURL?.path == url.path)
        let info = try await MCPTestSupport.call("get_app_info", in: workspace)
        #expect(info["features"]?.objectValue?["open"]?.arrayValue?.contains(.string("svg")) == true)
    }

    /// Large Document (.psb) files open like PSDs (upstream #109), and a file with only a background (no layer
    /// records) opens from its merged image (upstream e6bcfa1), through open_document as through the app.
    @Test func openDocumentOpensLargeDocumentsAndBackgroundOnlyFiles() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        var sky = PSDRecord(id: UUID(), name: "Sky")
        sky.bounds = CGRect(x: 0, y: 0, width: 4, height: 2)
        sky.image = try solid(width: 4, height: 2)
        let psb = root.appendingPathComponent("Poster.psb")
        try PSDFixture.data(PSDDocument(width: 4, height: 2, resolution: 72, layers: [sky]), composite: try solid(width: 4, height: 2),
                            largeDocument: true).write(to: psb)
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        let opened = try await MCPTestSupport.call("open_document", ["path": .string(psb.path)], in: workspace)
        #expect(opened["format"]?.stringValue == "psd")
        #expect(workspace.current.session.document?.layers.map(\.name) == ["Sky"])

        for (name, large) in [("Flat.psd", false), ("Flat.psb", true)] {
            let url = root.appendingPathComponent(name)
            try PSDFixture.data(PSDDocument(width: 6, height: 3, resolution: 72, layers: []),
                                composite: try solid(width: 6, height: 3, red: 1, green: 0, blue: 0), largeDocument: large).write(to: url)
            try await MCPTestSupport.call("open_document", ["path": .string(url.path)], in: workspace)
            let document = try #require(workspace.current.session.document)
            #expect(document.size == CGSize(width: 6, height: 3), "\(name)")
            let image = try #require(document.layers.first?.asset?.image, "\(name)")
            #expect(document.layers.count == 1 && image.width == 6 && image.height == 3, "\(name)")
            let red = try pixel(image, x: 3, y: 1)
            #expect(red.red == 255 && red.green == 0 && red.blue == 0, "\(name)")
        }
        let info = try await MCPTestSupport.call("get_app_info", in: workspace)
        #expect(info["features"]?.objectValue?["open"]?.arrayValue?.contains(.string("psb")) == true)
    }

    /// Compositor writes version-1 Photoshop files: a document opened from a PSB saves as a .psd, and a .psb path is
    /// refused rather than given a PSD's bytes or a doubled extension.
    @Test func aLargeDocumentSavesAsAPSDAndAPSBPathIsRefused() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        var sky = PSDRecord(id: UUID(), name: "Sky")
        sky.bounds = CGRect(x: 0, y: 0, width: 4, height: 2)
        sky.image = try solid(width: 4, height: 2)
        let psb = root.appendingPathComponent("Poster.psb")
        try PSDFixture.data(PSDDocument(width: 4, height: 2, resolution: 72, layers: [sky]), composite: try solid(width: 4, height: 2),
                            largeDocument: true).write(to: psb)
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        try await MCPTestSupport.call("open_document", ["path": .string(psb.path)], in: workspace)
        let refused = try await MCPTestSupport.call("save_document_as", ["path": .string(root.appendingPathComponent("Copy.psb").path)],
                                                    in: workspace, expectError: "invalid_argument")
        #expect(errorObject(refused)["hint"]?.stringValue?.contains(".psd") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["Poster.psb"])

        let psd = root.appendingPathComponent("Poster.psd")
        try await MCPTestSupport.call("save_document_as", ["path": .string(psd.path)], in: workspace)
        let written = try Data(contentsOf: psd)
        #expect(written.prefix(6) == Data([0x38, 0x42, 0x50, 0x53, 0, 1]))
        #expect(try PSDReader.read(written).layers.map(\.name) == ["Sky"])
    }

    /// A PSB's `8B64` blocks go into the version-1 file as `8BIM` blocks with 4-byte lengths: a reader (ours included)
    /// takes an `8B64` block's length as eight bytes, so keeping the signature would misframe everything after it.
    @Test func aLargeDocumentsEightBSixtyFourBlocksAreWrittenAsEightBIMBlocksInAPSD() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let wide = PSDTaggedBlock(signature: "8B64", key: "zzzz", data: Data([1, 2, 3, 4, 5, 6]))
        let after = PSDTaggedBlock(key: "qqqq", data: Data([9, 9]))
        let pattern = PSDTaggedBlock(key: "Patt", data: Data([7, 7, 7, 7]))
        var sky = PSDRecord(id: UUID(), name: "Sky")
        sky.bounds = CGRect(x: 0, y: 0, width: 4, height: 2)
        sky.image = try solid(width: 4, height: 2)
        sky.extras = PSDLayerExtras(blocks: [wide, after])
        let psb = root.appendingPathComponent("Poster.psb")
        try PSDFixture.data(PSDDocument(width: 4, height: 2, resolution: 72, layers: [sky],
                                        extras: PSDDocumentExtras(globalBlocks: [wide, pattern])),
                            composite: try solid(width: 4, height: 2), largeDocument: true).write(to: psb)
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        try await MCPTestSupport.call("open_document", ["path": .string(psb.path)], in: workspace)
        let opened = try #require(workspace.current.session.document)
        #expect(opened.layers.first?.psdExtras?.blocks.contains(wide) == true && opened.psdExtras?.globalBlocks.contains(wide) == true)

        let psd = root.appendingPathComponent("Poster.psd")
        try await MCPTestSupport.call("save_document_as", ["path": .string(psd.path)], in: workspace)
        let written = try Data(contentsOf: psd)
        #expect(written.range(of: Data("8B64".utf8)) == nil)
        // Signature, key, a u32 length of 6, the payload: once in the layer's record and once among the document's blocks.
        #expect(written.ranges(of: Data("8BIMzzzz".utf8) + Data([0, 0, 0, 6, 1, 2, 3, 4, 5, 6])).count == 2)
        let reread = try PSDReader.read(written)
        let narrow = PSDTaggedBlock(key: "zzzz", data: wide.data)
        let layer = try #require(reread.layers.first?.extras)
        let keys = layer.blocks.map(\.key)
        #expect(layer.blocks.contains(narrow) && layer.blocks.contains(after), "\(keys)")
        #expect(keys.firstIndex(of: "zzzz").map { keys.dropFirst($0 + 1).first == "qqqq" } == true, "\(keys)")
        #expect(layer.trailingBytes.isEmpty, "\(layer.trailingBytes as NSData)")
        let global = reread.extras?.globalBlocks ?? []
        #expect(global.contains(narrow) && global.contains(pattern), "\(global.map(\.key))")
        #expect(reread.layers.map(\.name) == ["Sky"])
    }

    // MARK: Reverting

    @Test func revertDocumentReloadsItsFileOnlyWhenAskedToDiscard() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        try await MCPTestSupport.call("revert_document", in: workspace, expectError: "precondition_failed")

        let project = root.appendingPathComponent("Revert.comp")
        try await MCPTestSupport.call("save_document_as", ["path": .string(project.path)], in: workspace)
        let tab = workspace.current
        let documentID = try #require(tab.session.document?.id)
        try await MCPTestSupport.call("add_blank_layer", ["name": "Scratch"], in: workspace)
        let refused = try await MCPTestSupport.call("revert_document", in: workspace, expectError: "precondition_failed")
        #expect(errorObject(refused)["guard"]?.stringValue == "unsaved_changes")
        #expect(tab.session.document?.layers.contains { $0.name == "Scratch" } == true)

        let reverted = try await MCPTestSupport.call("revert_document", ["discard_changes": true], in: workspace)
        #expect(reverted["discarded_changes"] == .bool(true))
        #expect(workspace.current === tab && tab.session.projectURL?.path == project.path)
        #expect(tab.session.document?.id == documentID)
        #expect(tab.session.document?.layers.contains { $0.name == "Scratch" } == false)
        #expect(!tab.session.isModified && !tab.session.canUndo)

        // A Photoshop document reloads from the Photoshop file, which stays its source.
        let psd = try photoshopFile(in: root)
        try await MCPTestSupport.call("open_document", ["path": .string(psd.path)], in: workspace)
        let photoshop = workspace.current
        try await MCPTestSupport.call("rename_layer", ["layer": "Sky", "name": "Night"], in: workspace)
        let again = try await MCPTestSupport.call("revert_document", ["discard_changes": true], in: workspace)
        #expect(again["conversions"]?.arrayValue?.isEmpty == false)
        #expect(photoshop.session.document?.layers.map(\.name) == ["Sky", "Dissolved"])
        #expect(photoshop.session.sourceURL?.path == psd.path && photoshop.session.documentFormat == .psd)
        #expect(!photoshop.session.isModified)
    }

    // MARK: Pending edits

    @Test func settlePendingEditsCommitsOrCancelsWhatBlocksEditing() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 64)
        let session = workspace.current.session
        session.insert(ImportedImage(image: try solid(width: 8, height: 8), thumbnail: try solid(width: 8, height: 8), name: "Box"))
        let id = try #require(session.activeLayerID)
        let before = try #require(session.document?.layers.first { $0.id == id }?.transform)
        session.beginTransform()
        var moved = before
        moved.origin.x += 10
        session.previewTransform(moved)
        try await MCPTestSupport.call("add_blank_layer", in: workspace, expectError: "precondition_failed")
        try await MCPTestSupport.call("settle_pending_edits", in: workspace, expectError: "invalid_argument")

        let committed = try await MCPTestSupport.call("settle_pending_edits", ["mode": "commit"], in: workspace)
        #expect(committed["settled"]?.arrayValue == [.string("transform")])
        #expect(committed["blocking_reason"] == .null && committed["can_edit_layers"] == .bool(true))
        #expect(session.transformEdit == nil)
        #expect(session.document?.layers.first { $0.id == id }?.transform.origin.x == before.origin.x + 10)
        #expect(committed["undo"]?.objectValue?["recorded"] == .bool(true))

        session.beginTransform()
        session.previewTransform(before)
        session.renamingLayerID = id
        let cancelled = try await MCPTestSupport.call("settle_pending_edits", ["mode": "cancel"], in: workspace)
        #expect(Set(cancelled["settled"]?.arrayValue ?? []) == [.string("transform"), .string("rename")])
        #expect(session.document?.layers.first { $0.id == id }?.transform.origin.x == before.origin.x + 10)
        #expect(session.renamingLayerID == nil && session.transformEdit == nil)
        try await MCPTestSupport.call("add_blank_layer", in: workspace)

        let idle = try await MCPTestSupport.call("settle_pending_edits", ["mode": "commit"], in: workspace)
        #expect(idle["settled"]?.arrayValue?.isEmpty == true)
        #expect(idle["failed"]?.arrayValue?.isEmpty == true)
    }

    @Test func settlePendingEditsReportsAFailedCommitWithoutAnAlert() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 64)
        let session = workspace.current.session
        func failures(_ result: [String: Value]) -> [[String: Value]] {
            (result["failed"]?.arrayValue ?? []).compactMap(\.objectValue)
        }

        // Paint and crop alerts already up are dismissed along with the import alert.
        session.brushError = "An earlier stroke failed."
        session.cropError = "An earlier crop failed."
        let dismissed = try await MCPTestSupport.call("settle_pending_edits", ["mode": "commit"], in: workspace)
        #expect(dismissed["settled"]?.arrayValue == [.string("error_alert")])
        #expect(failures(dismissed).isEmpty)
        #expect(session.brushError == nil && session.cropError == nil)

        // Text too large to draw: committing it in the app shows "Couldn't paint". The agent gets the message
        // instead, no alert is left up, and the draft stays so nothing typed is lost.
        let layerCount = session.document?.layers.count
        session.beginText(at: CGPoint(x: 4, y: 4), newLayer: true)
        session.textDraft?.style.content = String(repeating: "W", count: 40)
        session.textDraft?.style.fontSize = 2000
        #expect(session.textDraft?.style.isValid == true)
        let tooLarge = try await MCPTestSupport.call("settle_pending_edits", ["mode": "commit"], in: workspace)
        #expect(tooLarge["settled"]?.arrayValue?.isEmpty == true)
        #expect(failures(tooLarge).map { $0["edit"] } == [.string("text")])
        #expect(failures(tooLarge).first?["message"]?.stringValue?.isEmpty == false)
        #expect(session.brushError == nil && session.cropError == nil)
        #expect(session.textDraft != nil && session.document?.layers.count == layerCount)
        #expect(tooLarge["can_edit_layers"] == .bool(false) && tooLarge["blocking_reason"] != .null)

        // A style that no longer validates can't commit either, and has no message of its own.
        session.textDraft?.style.fontSize = 0
        let invalid = try await MCPTestSupport.call("settle_pending_edits", ["mode": "commit"], in: workspace)
        #expect(invalid["settled"]?.arrayValue?.isEmpty == true)
        #expect(failures(invalid).map { $0["edit"] } == [.string("text")])
        #expect(failures(invalid).first?["message"]?.stringValue?.contains("still in progress") == true)
        #expect(session.brushError == nil && session.textDraft != nil)

        let cancelled = try await MCPTestSupport.call("settle_pending_edits", ["mode": "cancel"], in: workspace)
        #expect(cancelled["settled"]?.arrayValue == [.string("text")] && failures(cancelled).isEmpty)
        #expect(session.textDraft == nil && session.document?.layers.count == layerCount)

        // A crop frame that isn't valid stays pending, is reported, and shows no "Couldn't crop" alert.
        session.cropRect = CGRect(x: 0, y: 0, width: 0.5, height: 8)
        let crop = try await MCPTestSupport.call("settle_pending_edits", ["mode": "commit"], in: workspace)
        #expect(crop["settled"]?.arrayValue?.isEmpty == true)
        #expect(failures(crop).map { $0["edit"] } == [.string("crop")])
        #expect(session.cropError == nil && session.brushError == nil && session.cropRect != nil)
        #expect(session.document?.width == 64)
        let croppedAway = try await MCPTestSupport.call("settle_pending_edits", ["mode": "cancel"], in: workspace)
        #expect(croppedAway["settled"]?.arrayValue == [.string("crop")] && session.cropRect == nil)
    }

    // MARK: Reading

    @Test func getDocumentSummarizesAndFullAddsSettingsAndBounds() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        session.insert(ImportedImage(image: try solid(width: 8, height: 4), thumbnail: try solid(width: 8, height: 4), name: "Box"),
                       centeredAt: CGPoint(x: 20, y: 10))
        let id = try #require(session.activeLayerID)
        session.addGuide(CanvasGuide(id: UUID(), axis: .vertical, position: 12))
        if let index = session.document?.layers.firstIndex(where: { $0.id == id }) {
            session.document?.layers[index].locks = [.position]
        }

        let summary = try await MCPTestSupport.call("get_document", in: workspace)
        let document = try #require(summary["document"]?.objectValue)
        #expect(document["format"]?.stringValue == "comp")
        let layerValues = try #require(document["layers"]?.arrayValue)
        let layers = layerValues.compactMap(\.objectValue)
        let box = try #require(layers.first { $0["id"]?.stringValue == id.uuidString })
        #expect(box["kind"]?.stringValue == "raster")
        #expect(box["locks"]?.arrayValue == [.string("position")])
        #expect(box["transform"]?.objectValue?["x"]?.doubleValue == 16)
        #expect(box["content_bounds"] == nil && box["effects"] == nil)
        #expect(document["guides"]?.arrayValue?.first?.objectValue?["position"]?.doubleValue == 12)
        #expect(document["selection"] == .object(["exists": .bool(false)]))
        #expect(document["history"]?.objectValue?["undo_count"]?.intValue == session.history.undoCount)
        let capabilities = try #require(document["capabilities"]?.objectValue)
        #expect(capabilities["can_edit_layers"] == .bool(true) && capabilities["blocking_reason"] == .null)
        #expect(document["palette"]?.objectValue?["foreground"]?.objectValue?["hex"]?.stringValue != nil)

        let full = try await MCPTestSupport.call("get_document", ["detail": "full"], in: workspace)
        let fullValues = try #require(full["document"]?.objectValue?["layers"]?.arrayValue)
        let fullLayers = fullValues.compactMap(\.objectValue)
        let detailed = try #require(fullLayers.first { $0["id"]?.stringValue == id.uuidString })
        let bounds = try #require(detailed["content_bounds"]?.objectValue)
        #expect(bounds["x"]?.doubleValue == 16 && bounds["width"]?.doubleValue == 8 && bounds["height"]?.doubleValue == 4)
        #expect(detailed["pixel_width"]?.intValue == 8)

        // A position-locked layer refuses Free Transform, so unlock it to start one.
        session.setLocks([], on: id)
        session.beginTransform()
        let busy = try await MCPTestSupport.call("get_document", in: workspace)
        let blocked = try #require(busy["document"]?.objectValue?["capabilities"]?.objectValue)
        #expect(blocked["can_edit_layers"] == .bool(false) && blocked["blocking_reason"]?.stringValue != nil)
        session.cancelTransform()

        try await MCPTestSupport.call("get_document", ["detail": "everything"], in: workspace, expectError: "invalid_argument")
    }

    @Test func getAppInfoReportsVersionLimitsAndTheAgentFolder() async throws {
        let workspace = MCPTestSupport.workspace()
        let info = try await MCPTestSupport.call("get_app_info", in: workspace)
        #expect(info["version"]?.objectValue?["app"]?.stringValue?.isEmpty == false)
        let limits = try #require(info["limits"]?.objectValue)
        #expect(limits["max_documents"]?.intValue == MCPSettings.maxTabs)
        #expect(limits["max_canvas_side"]?.intValue == 30_000)
        // One canvas or export, and what a document's layers hold in all, which scales with the Mac (`DocumentLimits`).
        #expect(limits["max_pixels"]?.intValue == 200_000_000)
        #expect(limits["document_pixel_budget"]?.intValue == DocumentLimits.documentPixelBudget)
        #expect((200_000_000...800_000_000).contains(DocumentLimits.documentPixelBudget))
        #expect(info["agent_folder"]?.stringValue == MCPTestSupport.agentRootOverride.path)
        #expect(info["features"]?.objectValue?["save"]?.arrayValue == [.string("comp"), .string("psd")])
        #expect(info["features"]?.objectValue?["photoshop_save"] == .bool(true))
        // No server runs in the test host: nothing published by this process.
        #expect(info["endpoint"] == .null)
    }

    // MARK: Exporting

    /// An export writes a picture of the document, not the document: after a Photoshop save and an edit, export_image
    /// (PNG or JPEG, alone or in a batch) leaves it modified, and still living in its PSD.
    @Test func exportsNeverMarkTheDocumentSaved() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 8)
        let session = workspace.current.session
        let target = MCPTestSupport.tempFile("poster.psd")
        try await MCPTestSupport.call("save_document_as", ["path": .string(target.path)], in: workspace)
        try await MCPTestSupport.call("add_blank_layer", ["name": "Later"], in: workspace)
        let saved = try Data(contentsOf: target)
        func expectStillUnsaved() async throws {
            let document = try #require(try await MCPTestSupport.call("get_document", in: workspace)["document"]?.objectValue)
            #expect(document["is_modified"] == .bool(true))
            #expect(document["format"]?.stringValue == "psd" && document["project_url"]?.stringValue == target.path)
            #expect(session.isModified && session.projectURL?.path == target.path && session.documentFormat == .psd)
        }
        try await expectStillUnsaved()

        for name in ["poster.png", "poster.jpg"] {
            let exported = try await MCPTestSupport.call("export_image", ["path": .string(MCPTestSupport.tempFile(name).path)],
                                                         in: workspace)
            #expect(exported["saved"] == nil && exported["set_as_current"] == nil)
            try await expectStillUnsaved()
        }
        try await MCPTestSupport.call("run_batch", ["steps": [
            .object(["tool": "add_blank_layer", "arguments": .object(["name": "In batch"])]),
            .object(["tool": "export_image", "arguments": .object(["path": .string(MCPTestSupport.tempFile("batch.png").path)])]),
        ]], in: workspace)
        try await expectStillUnsaved()
        #expect(try Data(contentsOf: target) == saved)
    }

    @Test func exportImageTakesARegionAndAScale() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        session.insert(ImportedImage(image: try solid(width: 16, height: 16, red: 1, green: 0, blue: 0),
                                     thumbnail: try solid(width: 16, height: 16), name: "Red"),
                       centeredAt: CGPoint(x: 8, y: 8))
        let target = MCPTestSupport.tempFile("region.png")
        let result = try await MCPTestSupport.call("export_image", [
            "path": .string(target.path), "region": ["x": 8, "y": 0, "width": 16, "height": 8], "scale": 2,
        ], in: workspace)
        #expect(result["width"]?.intValue == 32 && result["height"]?.intValue == 16)
        #expect(result["scale"]?.doubleValue == 2)
        #expect(result["region"]?.objectValue?["x"]?.doubleValue == 8)
        let image = try decoded(target.path)
        #expect(image.width == 32 && image.height == 16)
        #expect(try pixel(image, x: 4, y: 4).red == 255)
        #expect(try pixel(image, x: 28, y: 4).alpha == 0)

        let half = try await MCPTestSupport.call("export_image", ["path": .string(MCPTestSupport.tempFile("half.png").path), "scale": 0.5],
                                                 in: workspace)
        #expect(half["width"]?.intValue == 32 && half["height"]?.intValue == 16)

        try await MCPTestSupport.call("export_image", ["path": .string(MCPTestSupport.tempFile("big.png").path), "scale": 5],
                                      in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("export_image", ["path": .string(MCPTestSupport.tempFile("off.png").path),
                                                       "region": ["x": 100, "y": 100, "width": 4, "height": 4]],
                                      in: workspace, expectError: "invalid_argument")
    }
}
