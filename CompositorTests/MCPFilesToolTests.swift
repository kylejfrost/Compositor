import CoreGraphics
import Foundation
import ImageIO
import Testing
import MCP
import UniformTypeIdentifiers
@testable import Compositor

/// The Files domain: listing folders, describing a file, and showing one in Finder.
///
/// Every file lives in a fresh folder inside the test Agent folder (`MCPTestSupport.agentRootOverride`), which other
/// suites write into concurrently, so listings are checked by their own entries only. Serialized because the reveal
/// test swaps the process-wide Finder hook.
@MainActor @Suite(.serialized) struct MCPFilesToolTests {
    // MARK: Fixtures

    /// A new, empty folder inside the Agent folder: its URL and its name there.
    private func scratchFolder() throws -> (url: URL, name: String) {
        let name = "files-\(UUID().uuidString)"
        let url = MCPTestSupport.agentRootOverride.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, name)
    }

    /// Writes a `width` × `height` red image of `type`, recording `orientation` (EXIF) when given.
    private func writeImage(_ url: URL, width: Int, height: Int, type: UTType = .png, orientation: Int? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, properties)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func writeText(_ url: URL, _ text: String = "hello") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func entries(_ result: [String: Value]) -> [[String: Value]] {
        result["files"]?.arrayValue?.compactMap(\.objectValue) ?? []
    }

    private func names(_ result: [String: Value]) -> [String] {
        entries(result).compactMap { $0["name"]?.stringValue }
    }

    // MARK: list_files

    @Test func listFilesDefaultsToTheTopOfTheAgentFolder() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let folder = try scratchFolder()
        try writeText(folder.url.appendingPathComponent("a.txt"))

        let listed = try await MCPTestSupport.call("list_files", in: workspace)
        #expect(listed["root"]?.stringValue == MCPTestSupport.agentRootOverride.path)
        let mine = try #require(entries(listed).first { $0["name"]?.stringValue == folder.name })
        #expect(mine["is_directory"] == .bool(true))
        #expect(mine["path"]?.stringValue == folder.url.path)
        // Not recursive by default: nothing inside the folder is listed.
        #expect(!names(listed).contains { $0.hasPrefix(folder.name + "/") })
    }

    @Test func listFilesRecursesWithNamesRelativeToTheListedFolder() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let folder = try scratchFolder()
        try writeText(folder.url.appendingPathComponent("a.txt"), "12345")
        try writeText(folder.url.appendingPathComponent("sub/b.txt"))
        try writeText(folder.url.appendingPathComponent(".hidden"))
        try writeText(folder.url.appendingPathComponent("scratch.tmp"))

        // The temporary folder is reached through the /var -> /private/var link; both spellings list the same names.
        var spellings = [folder.name, folder.url.path]
        if folder.url.path.hasPrefix("/var/") { spellings.append("/private" + folder.url.path) }
        for spelling in spellings {
            let listed = try await MCPTestSupport.call("list_files", ["path": .string(spelling), "recursive": true], in: workspace)
            #expect(names(listed) == ["a.txt", "sub", "sub/b.txt"], "\(spelling)")
            #expect(listed["count"]?.intValue == 3 && listed["truncated"] == .bool(false))
            for entry in entries(listed) {
                let name = try #require(entry["name"]?.stringValue)
                let path = try #require(entry["path"]?.stringValue)
                #expect(path.hasSuffix("/" + name) && FileManager.default.fileExists(atPath: path), "\(spelling): \(path)")
            }
            let file = try #require(entries(listed).first { $0["name"]?.stringValue == "a.txt" })
            #expect(file["size"]?.intValue == 5 && file["is_directory"] == .bool(false))
            let sub = try #require(entries(listed).first { $0["name"]?.stringValue == "sub" })
            #expect(sub["is_directory"] == .bool(true) && sub["size"] == .null)
        }

        // A listing of a subfolder names its entries relative to that subfolder.
        let nested = try await MCPTestSupport.call("list_files", ["path": .string(folder.name + "/sub")], in: workspace)
        #expect(names(nested) == ["b.txt"])
        #expect(nested["root"]?.stringValue == folder.url.appendingPathComponent("sub").path)
    }

    @Test func listFilesFiltersByExtensionAndStopsAtTheLimit() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let folder = try scratchFolder()
        for name in ["a.PNG", "b.jpg", "c.txt", "sub/d.png", "sub/e.txt"] {
            try writeText(folder.url.appendingPathComponent(name))
        }
        let path = Value.string(folder.url.path)

        // Case-insensitive, with or without the dot; folders are left out of a filtered listing but still searched.
        let images = try await MCPTestSupport.call("list_files", ["path": path, "recursive": true, "extensions": ["png", ".JPG"]],
                                                   in: workspace)
        #expect(names(images) == ["a.PNG", "b.jpg", "sub/d.png"])
        let flat = try await MCPTestSupport.call("list_files", ["path": path, "extensions": ["png"]], in: workspace)
        #expect(names(flat) == ["a.PNG"])

        let limited = try await MCPTestSupport.call("list_files", ["path": path, "recursive": true, "limit": 2], in: workspace)
        #expect(names(limited) == ["a.PNG", "b.jpg"])
        #expect(limited["count"]?.intValue == 2 && limited["truncated"] == .bool(true))
        let exact = try await MCPTestSupport.call("list_files", ["path": path, "limit": 4], in: workspace)
        #expect(names(exact) == ["a.PNG", "b.jpg", "c.txt", "sub"] && exact["truncated"] == .bool(false))

        try await MCPTestSupport.call("list_files", ["path": path, "limit": 0], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("list_files", ["path": path, "limit": 10_001], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("list_files", ["path": path, "extensions": [1]], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("list_files", ["path": path, "extensions": "png"], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("list_files", ["path": path, "recursive": "yes"], in: workspace, expectError: "invalid_argument")
    }

    @Test func projectPackagesAreFiles() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let folder = try scratchFolder()
        try writeText(folder.url.appendingPathComponent("Poster.comp/manifest.json"), "{}")
        let listed = try await MCPTestSupport.call("list_files", ["path": .string(folder.url.path), "recursive": true], in: workspace)
        #expect(names(listed) == ["Poster.comp"])
        #expect(entries(listed).first?["is_directory"] == .bool(false))
        let projects = try await MCPTestSupport.call("list_files", ["path": .string(folder.url.path), "extensions": ["comp"]], in: workspace)
        #expect(names(projects) == ["Poster.comp"])
        let info = try await MCPTestSupport.call("get_file_info", ["path": .string(folder.name + "/Poster.comp")], in: workspace)
        #expect(info["exists"] == .bool(true) && info["is_directory"] == .bool(false) && info["size"] == .null)
    }

    @Test func aProjectPackageIsNotAFolderToList() async throws {
        // The Finder shows a .comp project as one file, so list_files does too, even when asked to list it.
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let folder = try scratchFolder()
        try writeText(folder.url.appendingPathComponent("Poster.comp/manifest.json"), "{}")
        let refused = try await MCPTestSupport.call("list_files", ["path": .string(folder.name + "/Poster.comp")], in: workspace,
                                                    expectError: "invalid_argument")
        let hint = try #require(refused["error"]?.objectValue?["hint"]?.stringValue)
        #expect(hint.contains("get_file_info") && hint.contains("open_document"))
        #expect(refused["files"] == nil)
    }

    @Test func symbolicLinksReportTheirTargetsSize() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let folder = try scratchFolder()
        try writeText(folder.url.appendingPathComponent("a.txt"), "12345")
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let files = FileManager.default
        try files.createSymbolicLink(atPath: folder.url.appendingPathComponent("link.txt").path, withDestinationPath: "a.txt")
        try files.createSymbolicLink(atPath: folder.url.appendingPathComponent("absolute.txt").path,
                                     withDestinationPath: folder.url.appendingPathComponent("a.txt").path)
        try files.createSymbolicLink(atPath: folder.url.appendingPathComponent("folder-link").path, withDestinationPath: "sub")
        try files.createSymbolicLink(atPath: folder.url.appendingPathComponent("broken").path, withDestinationPath: "nowhere.txt")

        let listed = try await MCPTestSupport.call("list_files", ["path": .string(folder.name)], in: workspace)
        let byName = Dictionary(uniqueKeysWithValues: entries(listed).compactMap { entry in
            entry["name"]?.stringValue.map { ($0, entry) }
        })
        // A link reports what it points to, as get_file_info does — not the few bytes of the link itself.
        #expect(byName["link.txt"]?["size"] == 5 && byName["absolute.txt"]?["size"] == 5)
        // Links are never followed into, so a link to a folder is a file with no size, as is a broken one.
        #expect(byName["folder-link"]?["size"] == .null && byName["folder-link"]?["is_directory"] == .bool(false))
        #expect(byName["broken"]?["size"] == .null)
    }

    @Test func listingStopsWhenTheCallIsCancelled() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let folder = try scratchFolder()
        for index in 0..<20 { try writeText(folder.url.appendingPathComponent("sub/\(index).txt")) }

        // Cancelled before it starts: the walk gives up instead of listing the whole tree.
        let call = Task { await MCPToolRegistry.call("list_files", ["path": .string(folder.name), "recursive": true], workspace: workspace) }
        call.cancel()
        let result = await call.value
        #expect(result.isError == true)
        #expect(result.structuredContent?.objectValue?["files"] == nil)
        #expect(result.structuredContent?.objectValue?["error"]?.objectValue?["code"]?.stringValue == "busy")
    }

    @Test func listFilesRefusesMissingFoldersAndFiles() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let folder = try scratchFolder()
        try writeText(folder.url.appendingPathComponent("a.txt"))
        try await MCPTestSupport.call("list_files", ["path": .string(folder.name + "/missing")], in: workspace, expectError: "not_found")
        try await MCPTestSupport.call("list_files", ["path": .string(folder.name + "/a.txt")], in: workspace, expectError: "invalid_argument")
    }

    // MARK: get_file_info

    @Test func getFileInfoDescribesImagesFilesAndFolders() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let folder = try scratchFolder()
        let png = folder.url.appendingPathComponent("photo.png")
        try writeImage(png, width: 30, height: 20)
        // Turned a quarter by its EXIF orientation: Compositor imports it 20 wide and 30 high.
        try writeImage(folder.url.appendingPathComponent("turned.jpg"), width: 30, height: 20, type: .jpeg, orientation: 6)
        try writeText(folder.url.appendingPathComponent("notes.txt"))

        // A relative path resolves inside the Agent folder.
        let image = try await MCPTestSupport.call("get_file_info", ["path": .string(folder.name + "/photo.png")], in: workspace)
        #expect(image["path"]?.stringValue == png.path)
        #expect(image["exists"] == .bool(true) && image["is_directory"] == .bool(false))
        let bytes = try #require(try FileManager.default.attributesOfItem(atPath: png.path)[.size] as? Int)
        #expect(image["size"]?.intValue == bytes)
        #expect(image["uti"]?.stringValue == UTType.png.identifier)
        #expect(image["image_size"] == .object(["width": 30, "height": 20]))

        let turned = try await MCPTestSupport.call("get_file_info", ["path": .string(folder.name + "/turned.jpg")], in: workspace)
        #expect(turned["uti"]?.stringValue == UTType.jpeg.identifier)
        #expect(turned["image_size"] == .object(["width": 20, "height": 30]))

        let text = try await MCPTestSupport.call("get_file_info", ["path": .string(folder.url.appendingPathComponent("notes.txt").path)],
                                                 in: workspace)
        #expect(text["uti"]?.stringValue == UTType.plainText.identifier && text["size"]?.intValue == 5)
        #expect(text["image_size"] == nil)

        let directory = try await MCPTestSupport.call("get_file_info", ["path": .string(folder.name)], in: workspace)
        #expect(directory["is_directory"] == .bool(true) && directory["size"] == .null)
        #expect(directory["uti"]?.stringValue == UTType.folder.identifier)
    }

    @Test func getFileInfoReportsMissingFilesAndExpandsTilde() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let folder = try scratchFolder()
        let missing = try await MCPTestSupport.call("get_file_info", ["path": .string(folder.name + "/nope.png")], in: workspace)
        #expect(missing["exists"] == .bool(false))
        #expect(missing["path"]?.stringValue == folder.url.appendingPathComponent("nope.png").path)

        let home = try await MCPTestSupport.call("get_file_info", ["path": "~"], in: workspace)
        #expect(home["path"]?.stringValue == NSHomeDirectory())
        #expect(home["exists"] == .bool(true) && home["is_directory"] == .bool(true))

        try await MCPTestSupport.call("get_file_info", in: workspace, expectError: "invalid_argument")
    }

    // MARK: reveal_in_finder

    @Test func revealInFinderShowsThePathOrTheAgentFolder() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let folder = try scratchFolder()
        try writeText(folder.url.appendingPathComponent("a.txt"))
        var revealed: [[URL]] = []
        let original = MCPToolRegistry.showInFinder
        MCPToolRegistry.showInFinder = { revealed.append($0) }
        defer { MCPToolRegistry.showInFinder = original }

        let root = try await MCPTestSupport.call("reveal_in_finder", in: workspace)
        #expect(root["path"]?.stringValue == MCPTestSupport.agentRootOverride.path)
        let file = try await MCPTestSupport.call("reveal_in_finder", ["path": .string(folder.name + "/a.txt")], in: workspace)
        #expect(file["path"]?.stringValue == folder.url.appendingPathComponent("a.txt").path)
        try await MCPTestSupport.call("reveal_in_finder", ["path": "~"], in: workspace)
        #expect(revealed.map { $0.map(\.path) } == [[MCPTestSupport.agentRootOverride.path],
                                                     [folder.url.appendingPathComponent("a.txt").path],
                                                     [NSHomeDirectory()]])

        try await MCPTestSupport.call("reveal_in_finder", ["path": .string(folder.name + "/missing.txt")], in: workspace,
                                      expectError: "not_found")
        #expect(revealed.count == 3)
    }

    // MARK: Annotations

    @Test func fileToolsDeclareTheirEffects() {
        let byName = Dictionary(uniqueKeysWithValues: MCPToolRegistry.tools.map { ($0.name, $0.annotations) })
        for name in ["list_files", "get_file_info"] {
            #expect(byName[name]?.readOnlyHint == true && byName[name]?.idempotentHint == true, "\(name)")
        }
        #expect(byName["reveal_in_finder"]?.readOnlyHint == false && byName["reveal_in_finder"]?.destructiveHint == false)
        #expect(byName["reveal_folder"] == nil)
    }
}
