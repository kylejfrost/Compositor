import AppKit
import Foundation
import ImageIO
import MCP
import UniformTypeIdentifiers

// MARK: - Files

extension MCPToolRegistry {
    /// Shows files in Finder; tests replace it so no Finder window opens.
    static var showInFinder: @MainActor ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }

    static let fileTools: [MCPToolEntry] = [
        tool("list_files", title: "List files",
             description: "Lists a folder's files and folders (default the Agent folder) in name order with name, path, size and is_directory; recursive walks subfolders. Hidden files are skipped and .comp projects count as files. Folders macOS keeps Compositor out of are listed but not entered, and named in skipped with folder_access_denied, folder_access_pending or folder_access_unchecked. extensions filters files; limit caps the entries (truncated).",
             properties: [
                 "path": MCPSchema.str("Folder to list (default the Agent folder)."),
                 "recursive": MCPSchema.bool("Walk subfolders.", default: false),
                 "extensions": MCPSchema.arr("Only files with these extensions, such as [\"png\", \"psd\"].",
                                             items: .object(["type": .string("string")]), minItems: 1),
                 "limit": MCPSchema.int("Most entries to return.", min: 1, max: 10_000, default: 500),
             ],
             targetsDocument: false, effect: .readOnly, handler: listFiles),
        tool("get_file_info", title: "Get file info",
             description: "Describes a file or folder without opening it: exists (a missing path is no error), is_directory, size, uti, and for an image the image_size it imports at.",
             properties: ["path": MCPSchema.str("The file or folder.")],
             required: ["path"], targetsDocument: false, effect: .readOnly, handler: getFileInfo),
        tool("reveal_in_finder", title: "Reveal in Finder",
             description: "Shows a file or folder selected in Finder (default the Agent folder), so the user can see what you made.",
             properties: ["path": MCPSchema.str("What to show (default the Agent folder).")],
             targetsDocument: false, effect: .additive(idempotent: true), handler: revealInFinder),
    ]

    // MARK: Listing

    static func listFiles(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let recursive = try ctx.args.bool("recursive", default: false)
        let limit = try ctx.args.int("limit", default: 500)
        guard (1...10_000).contains(limit) else { throw MCPToolError.invalidArgument("limit must be 1–10000.") }
        let extensions = try extensionsArgument(ctx.args)
        let folder = try await MCPPaths.resolveReachable(try ctx.args.optionalString("path"), mustExist: true)
        // Off the main actor (a recursive listing of a large tree takes a while), and stopped if the call is cancelled.
        let listing = try await MCPPaths.list(in: folder, recursive: recursive, extensions: extensions, limit: limit)
        var out: [String: Value] = [
            "root": .string(folder.path),
            "files": .array(listing.entries.map { entry in
                .object([
                    "name": .string(entry.name),
                    "path": .string(entry.path),
                    "size": entry.size.map { .int(Int($0)) } ?? .null,
                    "is_directory": .bool(entry.isDirectory),
                ])
            }),
            "count": .int(listing.entries.count),
            "truncated": .bool(listing.truncated),
        ]
        if !listing.skipped.isEmpty {
            out["skipped"] = .array(listing.skipped.map { .object(["path": .string($0.path), "code": .string($0.code)]) })
        }
        return ok(out)
    }

    /// The `extensions` argument, lowercased and without dots, or nil when absent.
    private static func extensionsArgument(_ args: Args) throws -> Set<String>? {
        guard let value = args["extensions"] else { return nil }
        let message = "extensions must be a list of file extensions, such as [\"png\", \"psd\"]."
        guard let items = value.arrayValue, !items.isEmpty else { throw MCPToolError.invalidArgument(message) }
        return Set(try items.map { item in
            guard let text = item.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
                throw MCPToolError.invalidArgument(message)
            }
            return String(text.drop { $0 == "." }).lowercased()
        })
    }

    // MARK: File info

    static func getFileInfo(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let url = try await MCPPaths.resolveReachable(try ctx.args.string("path"))
        let info = await Task.detached(priority: .userInitiated) { FileInfo(url) }.value
        var out: [String: Value] = ["path": .string(url.path), "exists": .bool(info.exists)]
        guard info.exists else { return ok(out) }
        out["is_directory"] = .bool(info.isDirectory)
        out["size"] = info.size.map { .int(Int($0)) } ?? .null
        out["uti"] = info.uti.map { .string($0) } ?? .null
        if let size = info.imageSize { out["image_size"] = .object(["width": .int(size.width), "height": .int(size.height)]) }
        return ok(out)
    }

    /// What get_file_info reports, read from the file system and, for an image, its header (never its pixels).
    nonisolated struct FileInfo: Sendable {
        var exists = false
        var isDirectory = false
        /// Bytes, for a file (not a folder or package).
        var size: Int64?
        var uti: String?
        /// Width and height as Compositor imports the image, its EXIF orientation applied.
        var imageSize: (width: Int, height: Int)?

        init(_ url: URL) {
            // Describes what a symbolic link points to.
            let target = url.resolvingSymlinksInPath()
            guard let values = try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentTypeKey]) else {
                return
            }
            exists = true
            // A package such as a .comp project is a file here, as in list_files.
            isDirectory = values.isDirectory == true && !MCPPaths.isPackage(target, values)
            size = values.isDirectory == true ? nil : values.fileSize.map { Int64($0) }
            uti = values.contentType?.identifier
            if values.isDirectory != true, values.contentType?.conforms(to: .image) == true {
                imageSize = Self.imageSize(of: target)
            }
        }

        private static func imageSize(of url: URL) -> (width: Int, height: Int)? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
            // EXIF orientations 5–8 turn the image a quarter, swapping its sides.
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            return (5...8).contains(orientation) ? (height, width) : (width, height)
        }
    }

    // MARK: Finder

    static func revealInFinder(_ ctx: MCPCallContext) async throws -> CallTool.Result {
        let url = try await MCPPaths.resolveReachable(try ctx.args.optionalString("path"), mustExist: true)
        showInFinder([url])
        return ok(["path": .string(url.path)])
    }
}
