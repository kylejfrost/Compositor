import CoreGraphics
import Foundation
import Testing
import MCP
@testable import Compositor

/// Structural tests for `MCPToolRegistry` itself: the tool list is well-formed, and
/// dispatch reaches a real handler for every declared tool. Behavioral tests for
/// individual tools live in their own suites and use `MCPTestSupport`.
@MainActor struct MCPRegistryTests {
    /// Tools skipped by `everyToolCanBeCalledWithEmptyArguments` because calling them
    /// with `{}` has a real effect outside the workspace/session under test, rather
    /// than just succeeding or failing against it:
    /// - `reveal_in_finder` opens a Finder window (`NSWorkspace.activateFileViewerSelecting`).
    /// - `bring_app_to_front` activates Compositor, taking focus from whatever app the user is in.
    ///
    /// Every other tool was inspected in `Compositor/MCP/MCPTools+<Domain>.swift`: the
    /// rest either only touch the in-memory workspace/session, or (like `save_document_as`
    /// with a relative path) write into the Agent folder — which, in this suite, is the
    /// temporary directory `MCPTestSupport` installs as `MCPSettings.agentRootOverride`,
    /// never the real one.
    static let toolsSkippedForEmptyArgsCall: Set<String> = ["reveal_in_finder", "bring_app_to_front"]

    @Test func everyToolNameIsUniqueAndLowerSnakeCase() {
        let names = MCPToolRegistry.tools.map(\.name)
        #expect(names.count == Set(names).count, "Duplicate tool names in \(names)")
        for name in names {
            #expect(isLowerSnakeCase(name), "Tool name '\(name)' doesn't match ^[a-z][a-z0-9_]*$")
        }
    }

    @Test func everyToolCanBeCalledWithEmptyArguments() async {
        let workspace = MCPTestSupport.workspace()
        let overrideDirectory = MCPTestSupport.agentRootOverride
        // list_profiles scans the temporary profile library, never the real Adobe folders: building the workspace
        // installed it (read before `ProfileTestSupport.locations`, which would install it itself).
        let profileLocations = ProfileLibrary.Locations.override
        #expect(profileLocations != nil && profileLocations == ProfileTestSupport.locations)
        // The real folder, computed the same pure way `agentRootURL` does — but bypassing
        // `agentRootOverride`, so this reads whatever actually is (or isn't) at the real
        // location without ever creating it.
        let realAgentRoot = MCPSettings.agentRootURL(under: MCPSettings.applicationSupportBaseURL)
        let realAgentRootBefore = Self.topLevelSnapshot(of: realAgentRoot)

        for tool in MCPToolRegistry.tools where !Self.toolsSkippedForEmptyArgsCall.contains(tool.name) {
            let result = await MCPToolRegistry.call(tool.name, [:], workspace: workspace)
            let object = result.structuredContent?.objectValue
            let message = object?["error"]?.stringValue ?? object?["error"]?.objectValue?["message"]?.stringValue
            #expect(
                message?.hasPrefix("Unknown tool") != true,
                "'\(tool.name)' dispatched to Unknown tool: \(String(describing: object))"
            )
        }
        // A relative path lands in the override, never the real Agent folder.
        let probe = "registry-\(UUID().uuidString).comp"
        _ = await MCPToolRegistry.call("save_document_as", ["path": .string(probe)], workspace: MCPTestSupport.workspace())
        #expect(FileManager.default.fileExists(atPath: overrideDirectory.appendingPathComponent(probe).path))

        #expect(
            Self.topLevelSnapshot(of: realAgentRoot) == realAgentRootBefore,
            "A tool wrote to the real Agent folder (\(realAgentRoot.path)) instead of the temporary override (\(overrideDirectory.path))"
        )
        let overrideEntries = (try? FileManager.default.contentsOfDirectory(atPath: overrideDirectory.path)) ?? []
        #expect(
            !overrideEntries.isEmpty,
            "Expected save_document_as to have written inside the temporary override directory \(overrideDirectory.path)"
        )
    }

    /// A cheap, non-recursive snapshot of a directory's immediate entries and their
    /// modification dates, used to assert a directory was left untouched. Directories
    /// that don't exist yield an empty snapshot, so a folder that never gets created stays
    /// equal to "never created" across the check.
    private static func topLevelSnapshot(of url: URL) -> [String: Date?] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [:] }
        var snapshot: [String: Date?] = [:]
        for entry in entries {
            snapshot[entry.lastPathComponent] = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return snapshot
    }

    @Test func newDocumentThenListDocumentsShowsTwoTabs() async throws {
        let workspace = MCPTestSupport.workspace()
        try await MCPTestSupport.call("new_document", in: workspace)
        let listed = try await MCPTestSupport.call("list_documents", in: workspace)
        let tabs = listed["tabs"]?.arrayValue
        #expect(tabs?.count == 2, "Expected two tabs after new_document, got: \(String(describing: listed))")
    }

    /// Walks the original tools through the selector-based arguments, checking each one
    /// still does its job after the move to per-domain handlers.
    @Test func existingToolsWorkThroughSelectors() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 48)
        let session = workspace.current.session
        func layer(_ name: String) -> ImageLayer? { session.document?.layers.first { $0.name == name } }
        @discardableResult
        func call(_ name: String, _ args: [String: Value] = [:]) async throws -> [String: Value] {
            try await MCPTestSupport.call(name, args, in: workspace)
        }

        try await call("add_blank_layer", ["name": "A"])
        try await call("add_blank_layer", ["name": "B"])
        try await call("rename_layer", ["layer": "A", "name": "Alpha"])
        try await call("set_layer_visibility", ["layer": "Alpha", "visible": false])
        try await call("set_layer_opacity", ["layer": "Alpha", "opacity": 0.5])
        try await call("set_layer_blend_mode", ["layer": "Alpha", "mode": "multiply"])
        #expect(layer("Alpha")?.isVisible == false && layer("Alpha")?.opacity == 0.5 && layer("Alpha")?.blendMode == .multiply)

        let copy = try await call("duplicate_layer", ["layer": "B"])
        #expect(copy["layer_id"]?.stringValue != layer("B")?.id.uuidString)
        try await call("reorder_layer", ["layer": "Alpha", "index": 0])
        #expect(session.document?.layers.first(where: { $0.parentID == nil })?.name == "Alpha")

        let group = try await call("group_layers", ["layers": ["Alpha", "B"]])
        let groupID = try #require(group["group_id"]?.stringValue)
        #expect(layer("Alpha")?.parentID?.uuidString == groupID)
        try await call("rename_layer", ["layer": .string(groupID), "name": "Folder"])
        try await call("set_layer_opacity", ["layer": "Folder/Alpha", "opacity": 0.25])
        #expect(layer("Alpha")?.opacity == 0.25)
        try await call("ungroup_layer", ["layer": "Folder"])
        #expect(layer("Folder") == nil && layer("Alpha")?.parentID == nil)

        let source = MCPTestSupport.tempFile("source.png")
        try await call("export_image", ["path": .string(source.path)])
        let image = try await call("add_image_layer", ["path": .string(source.path), "name": "Photo"])
        #expect(image["layer_id"]?.stringValue == layer("Photo")?.id.uuidString)
        try await call("move_layer", ["layer": "@active", "dx": 5, "dy": 3])
        #expect(layer("Photo")?.transform.origin == CGPoint(x: 5, y: 3))
        try await call("set_layer_transform", ["layer": "Photo", "width": 20, "rotation": 90])
        #expect(layer("Photo")?.transform.size.width == 20 && layer("Photo")?.transform.rotation == 90)

        try await call("select_layers", ["layers": ["Alpha", "Photo"], "active": "Photo"])
        #expect(session.activeLayerID == layer("Photo")?.id && session.selectedLayerIDs.count == 2)

        let adjustment = try await call("add_adjustment_layer", ["kind": "exposure", "settings": ["exposure": 1.5]])
        let adjustmentID = try #require(adjustment["layer_id"]?.stringValue)
        try await call("set_adjustment", ["layer": .string(adjustmentID), "settings": ["offset": 0.1]])
        let settings = session.document?.layers.first { $0.id.uuidString == adjustmentID }?.adjustment?.exposure
        #expect(settings?.exposure == 1.5 && settings?.offset == 0.1)
        try await call("set_clipping_mask", ["layer": .string(adjustmentID), "enabled": true])
        #expect(session.document?.layers.first { $0.id.uuidString == adjustmentID }?.maskSourceID != nil)

        try await call("resize_canvas", ["width": 80, "height": 60, "fill": "#ff0000"])
        #expect(session.document?.width == 80)
        try await call("resize_image", ["width": 40, "height": 30])
        #expect(session.document?.width == 40 && session.document?.height == 30)
        try await call("flip_canvas", ["axis": "horizontal"])

        let undone = try await call("undo")
        #expect(undone["can_redo"] == .bool(true))
        try await call("redo")

        try await call("delete_layers", ["layers": ["B copy"]])
        #expect(layer("B copy") == nil)
        try await call("merge_layers", ["layers": ["Photo"]])

        let preview = try await call("export_image", ["path": .string("previews/walkthrough-\(UUID().uuidString).png"), "max_size": 32])
        #expect(FileManager.default.fileExists(atPath: preview["path"]?.stringValue ?? ""))
        #expect(preview["width"]?.intValue == 32)
        try await call("render_document", ["max_size": 32])
        let files = try await call("list_files")
        #expect(files["files"]?.arrayValue?.isEmpty == false)

        let project = MCPTestSupport.tempFile("walkthrough.comp")
        try await call("save_document_as", ["path": .string(project.path)])
        try await call("close_document")
        let opened = try await call("open_document", ["path": .string(project.path)])
        #expect(opened["document_id"]?.stringValue != nil)
        let again = try await call("open_document", ["path": .string(project.path)])
        #expect(again["already_open"] == .bool(true))
        try await call("new_document", ["width": 8, "height": 8])
        try await call("select_document", ["document": 0])
        #expect(workspace.current.session.projectURL?.lastPathComponent == "walkthrough.comp")
        let document = try await call("get_document", ["document": "walkthrough"])
        #expect(document["document"]?.objectValue?["width"]?.intValue == 40)
    }

    private func isLowerSnakeCase(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLowercase, first.isLetter else { return false }
        return name.allSatisfy { character in
            guard character.isASCII else { return false }
            if character == "_" { return true }
            if let ascii = character.asciiValue, (48...57).contains(ascii) { return true } // 0-9
            return character.isLowercase && character.isLetter
        }
    }
}
