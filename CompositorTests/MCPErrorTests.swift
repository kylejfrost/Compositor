import Foundation
import Testing
import MCP
@testable import Compositor

/// The structured error envelope, tool annotations, guards and file-safety rules every
/// MCP tool shares.
@MainActor struct MCPErrorTests {
    // MARK: Annotations

    @Test func everyToolDeclaresItsSideEffects() {
        for tool in MCPToolRegistry.tools {
            let a = tool.annotations
            #expect(a.readOnlyHint != nil || a.destructiveHint != nil, "'\(tool.name)' sets neither readOnlyHint nor destructiveHint")
            if a.readOnlyHint != true {
                #expect(a.destructiveHint != nil, "'\(tool.name)' mutates but leaves destructiveHint unset")
            }
            #expect(a.openWorldHint == false, "'\(tool.name)' must set openWorldHint false")
        }
        let byName = Dictionary(uniqueKeysWithValues: MCPToolRegistry.tools.map { ($0.name, $0.annotations) })
        #expect(byName["get_document"]?.readOnlyHint == true)
        #expect(byName["delete_layers"]?.destructiveHint == true)
        #expect(byName["rename_layer"]?.idempotentHint == true)
        // Tools that can replace a file (with overwrite: true) may destroy data.
        #expect(byName["save_document"]?.destructiveHint == true)
        #expect(byName["export_image"]?.destructiveHint == true)
    }

    @Test func toolsWithoutADocumentIgnoreAStrayDocumentValue() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        try await MCPTestSupport.call("list_files", ["document": 99], in: workspace)
        try await MCPTestSupport.call("new_document", ["width": 8, "height": 8, "document": "no such tab"], in: workspace)
        try await MCPTestSupport.call("add_blank_layer", ["document": 99], in: workspace, expectError: "not_found")
    }

    @Test func toolsTakeDocumentAndLayerSelectorsNotRawIDs() {
        for tool in MCPToolRegistry.tools {
            let properties = tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
            #expect(properties["id"] == nil && properties["ids"] == nil, "'\(tool.name)' still advertises id/ids")
        }
        let byName = Dictionary(uniqueKeysWithValues: MCPToolRegistry.tools.map { ($0.name, $0.inputSchema) })
        #expect(byName["rename_layer"]?.objectValue?["properties"]?.objectValue?["layer"] != nil)
        #expect(byName["group_layers"]?.objectValue?["properties"]?.objectValue?["layers"] != nil)
        #expect(byName["add_blank_layer"]?.objectValue?["properties"]?.objectValue?["document"] != nil)
    }

    // MARK: Envelope

    @Test func failuresUseTheStructuredEnvelope() async throws {
        let workspace = MCPTestSupport.workspace()
        let result = await MCPToolRegistry.call("rename_layer", ["layer": "Nope", "name": "X"], workspace: workspace)
        #expect(result.isError == true)
        let object = try #require(result.structuredContent?.objectValue)
        #expect(object["ok"] == .bool(false))
        let error = try #require(object["error"]?.objectValue)
        #expect(error["code"]?.stringValue == "not_found")
        #expect(error["message"]?.stringValue?.isEmpty == false)
        // The text block carries the same JSON for text-only clients.
        guard case .text(let text, _, _) = result.content.first else { Issue.record("No text content"); return }
        #expect(text.contains("\"not_found\""))
    }

    @Test func missingArgumentIsInvalidArgument() async throws {
        let workspace = MCPTestSupport.workspace()
        try await MCPTestSupport.call("rename_layer", ["name": "X"], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("set_layer_opacity", ["layer": "@active", "opacity": "lots"], in: workspace, expectError: "invalid_argument")
    }

    /// An argument the tool doesn't take is refused before anything runs, naming it (with the closest real name when
    /// one is near), as settings patches already are: ignoring it made a typo silently take the default.
    @Test func anArgumentTheToolDoesntTakeIsRefused() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let session = workspace.current.session
        let path = MCPTestSupport.tempFile("row1.comp")
        let typo = try await MCPTestSupport.call("save_document_as", ["path": .string(path.path), "set_as_curent": false],
                                                 in: workspace, expectError: "invalid_argument")
        let error = try #require(typo["error"]?.objectValue)
        #expect(error["details"]?.objectValue?["field"]?.stringValue == "set_as_curent", "\(error)")
        #expect(error["hint"]?.stringValue?.contains("set_as_current") == true, "\(error)")
        #expect(!FileManager.default.fileExists(atPath: path.path) && session.projectURL == nil)

        let copied = try await MCPTestSupport.call("copy_pixels", ["layer_id": "Layer 1"], in: workspace, expectError: "invalid_argument")
        #expect(copied["error"]?.objectValue?["hint"]?.stringValue?.contains("layer") == true, "\(copied)")
        let layers = session.document?.layers.count
        let batch = try await MCPTestSupport.call("run_batch", [
            "steps": [["tool": "add_blank_layer", "arguments": ["name": "A"]], ["tool": "add_blank_layer", "arguments": ["nmae": "B"]]],
        ], in: workspace, expectError: "invalid_argument")
        let details = batch["error"]?.objectValue?["details"]?.objectValue
        #expect(details?["step"]?.intValue == 1 && details?["field"]?.stringValue == "nmae", "\(batch)")
        #expect(batch["error"]?.objectValue?["hint"]?.stringValue?.contains("'name'") == true, "\(batch)")
        #expect(session.document?.layers.count == layers, "A step ran before the batch was refused")
        try await MCPTestSupport.call("run_batch", ["steps": [["tool": "add_blank_layer"]], "rollback": true],
                                      in: workspace, expectError: "invalid_argument")
        // Pre-selector names still say what replaced them.
        let legacy = try await MCPTestSupport.call("rename_layer", ["id": "Layer 1", "name": "X"], in: workspace, expectError: "invalid_argument")
        #expect(legacy["error"]?.objectValue?["hint"]?.stringValue?.contains("'layer'") == true, "\(legacy)")
    }

    /// A color argument is {r, g, b} (or red/green/blue) with nothing else in it, or "#rrggbb": a misspelled or
    /// missing channel used to read as 0, so {"R": 1} or {} painted black and reported success. A settings patch
    /// already refused them.
    @Test func aColorWithUnknownOrNoChannelsIsRefused() async throws {
        for value: Value in [["R": 1, "G": 0, "B": 0], ["hex": "#ff0000"], ["h": 0, "s": 1, "l": 0.5], [:], ["r": 1, "alpha": 1],
                             "+fffff", "#fffff", "ff00zz"] {
            #expect(MCPValues.color(from: value) == nil, "\(value)")
            let workspace = MCPTestSupport.workspace(width: 8, height: 8)
            let tabs = workspace.tabs.count
            let refused = try await MCPTestSupport.call("new_document", ["width": 8, "height": 8, "fill": value], in: workspace,
                                                        expectError: "invalid_argument")
            #expect(refused["error"]?.objectValue?["message"]?.stringValue?.contains("fill") == true, "\(value): \(refused)")
            #expect(workspace.tabs.count == tabs)
        }
        for (value, rgb) in [(Value.object(["r": 1]), [1.0, 0, 0]), (["red": 0, "green": 0.5, "blue": 1], [0, 0.5, 1]),
                             ("#FF0000", [1, 0, 0]), (" #00ff00 ", [0, 1, 0]), ("0000ff", [0, 0, 1])] {
            let color = MCPValues.color(from: value)
            #expect(color.map { [$0.red, $0.green, $0.blue] } == rgb, "\(value)")
        }
    }

    @Test func unknownToolAndUnknownDocumentAreNotFound() async throws {
        let workspace = MCPTestSupport.workspace()
        try await MCPTestSupport.call("no_such_tool", in: workspace, expectError: "not_found")
        try await MCPTestSupport.call("get_document", ["document": 9], in: workspace, expectError: "not_found")
    }

    @Test func noDocumentIsAPreconditionFailure() async throws {
        let workspace = ProjectWorkspace()
        let result = try await MCPTestSupport.call("add_blank_layer", in: workspace, expectError: "precondition_failed")
        #expect(result["error"]?.objectValue?["guard"]?.stringValue == "document")
        #expect(result["error"]?.objectValue?["hint"]?.stringValue?.contains("new_document") == true)
    }

    @Test func busyDocumentReportsTheBlockingReason() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        #expect(MCPGuards.blockingReason(session) == nil)
        session.isProjectBusy = true
        defer { session.isProjectBusy = false }
        #expect(MCPGuards.blockingReason(session) != nil)
        let result = try await MCPTestSupport.call("add_blank_layer", in: workspace, expectError: "busy")
        #expect(result["error"]?.objectValue?["guard"]?.stringValue == "can_edit_layers")
    }

    @Test func mutatorsReportTheUndoEntry() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        let before = session.history.undoCount
        let result = try await MCPTestSupport.call("add_blank_layer", ["name": "Top"], in: workspace)
        let undo = try #require(result["undo"]?.objectValue)
        #expect(undo["count"]?.intValue == before + 1, "Adding and naming a layer is one undo step")
        #expect(undo["name"]?.stringValue == session.history.undoName)
    }

    @Test func mutatorsReportWhetherTheyRecordedAStep() async throws {
        let workspace = MCPTestSupport.workspace()
        let changed = try await MCPTestSupport.call("set_layer_opacity", ["layer": "@active", "opacity": 0.5], in: workspace)
        #expect(changed["undo"]?.objectValue?["recorded"] == .bool(true))
        let same = try await MCPTestSupport.call("set_layer_opacity", ["layer": "@active", "opacity": 0.5], in: workspace)
        #expect(same["undo"]?.objectValue?["recorded"] == .bool(false), "A no-op setter must not claim an undo step")
        #expect(same["undo"]?.objectValue?["count"] == changed["undo"]?.objectValue?["count"])
        let undone = try await MCPTestSupport.call("undo", in: workspace)
        #expect(undone["undo"]?.objectValue?["recorded"] == .bool(false))
    }

    @Test func setAdjustmentIsOneUndoableStep() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        let added = try await MCPTestSupport.call("add_adjustment_layer", ["kind": "exposure"], in: workspace)
        let id = try #require(added["layer_id"]?.stringValue)
        func exposure() -> Double? { session.document?.layers.first { $0.id.uuidString == id }?.adjustment?.exposure.exposure }
        let original = exposure()
        session.history.markSaved()
        let before = session.history.undoCount

        let result = try await MCPTestSupport.call("set_adjustment", ["layer": .string(id), "settings": ["exposure": 2]], in: workspace)
        #expect(exposure() == 2)
        #expect(session.history.undoCount == before + 1)
        #expect(session.isModified)
        #expect(result["undo"]?.objectValue?["recorded"] == .bool(true))
        #expect(result["undo"]?.objectValue?["name"]?.stringValue == "Edit Adjustment")

        try await MCPTestSupport.call("undo", in: workspace)
        #expect(exposure() == original)
        try await MCPTestSupport.call("redo", in: workspace)
        #expect(exposure() == 2)
    }

    @Test func addAdjustmentWithSettingsIsOneStepAndRollsBackInvalidSettings() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        let before = session.history.undoCount
        try await MCPTestSupport.call("add_adjustment_layer", ["kind": "exposure", "settings": ["exposure": 1]], in: workspace)
        #expect(session.history.undoCount == before + 1)

        session.history.markSaved()
        let layers = session.document?.layers.map(\.id)
        let revision = session.history.revisionID
        let active = session.activeLayerID
        try await MCPTestSupport.call("add_adjustment_layer", ["kind": "exposure", "settings": ["exposure": "bright"]],
                                      in: workspace, expectError: "invalid_argument")
        #expect(session.document?.layers.map(\.id) == layers)
        #expect(session.history.revisionID == revision && session.history.undoCount == before + 1)
        #expect(session.activeLayerID == active)
        #expect(!session.isModified)
    }

    @Test func tabCapacityIsAGuard() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        while workspace.tabs.count < MCPSettings.maxTabs {
            try await MCPTestSupport.call("new_document", ["width": 8, "height": 8], in: workspace)
        }
        let result = try await MCPTestSupport.call("new_document", ["width": 8, "height": 8], in: workspace, expectError: "precondition_failed")
        #expect(result["error"]?.objectValue?["guard"]?.stringValue == "max_tabs")
        #expect(workspace.tabs.count == MCPSettings.maxTabs)
    }

    // MARK: Files

    @Test func saveDocumentRefusesAnExistingFileUnlessOverwrite() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        let url = MCPTestSupport.tempFile("existing.comp")
        try await MCPTestSupport.call("save_document_as", ["path": .string(url.path)], in: workspace)
        #expect(FileManager.default.fileExists(atPath: url.path))

        // Re-saving the document to its own file is a plain save.
        try await MCPTestSupport.call("save_document", in: workspace)
        try await MCPTestSupport.call("save_document_as", ["path": .string(url.path)], in: workspace)

        try await MCPTestSupport.call("new_document", ["width": 8, "height": 8], in: workspace)
        let refused = try await MCPTestSupport.call("save_document_as", ["path": .string(url.path)], in: workspace, expectError: "io_error")
        #expect(refused["error"]?.objectValue?["details"]?.objectValue?["code"]?.stringValue == "file_exists")
        try await MCPTestSupport.call("save_document_as", ["path": .string(url.path), "overwrite": true], in: workspace)
    }

    @Test func exportImageRefusesAnExistingFileUnlessOverwrite() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        let url = MCPTestSupport.tempFile("existing.png")
        try Data([1, 2, 3]).write(to: url)
        let refused = try await MCPTestSupport.call("export_image", ["path": .string(url.path)], in: workspace, expectError: "io_error")
        #expect(refused["error"]?.objectValue?["details"]?.objectValue?["code"]?.stringValue == "file_exists")
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
        try await MCPTestSupport.call("export_image", ["path": .string(url.path), "overwrite": true], in: workspace)
        #expect(try Data(contentsOf: url).count > 3)
    }

    /// A call cancelled before it finished stopped part way through, which retrying fixes: busy, never internal.
    @Test func aCancelledCallIsBusy() {
        let cancelled = MCPToolError.from(CancellationError())
        #expect(cancelled.code == .busy, "\(cancelled)")
        #expect(cancelled.message == "The call was cancelled before it finished.")
        #expect(cancelled.hint?.isEmpty == false)
    }

    @Test func pathsExpandTildeAndResolveRelativeIntoTheAgentFolder() async throws {
        _ = MCPTestSupport.workspace()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let tilde = try await MCPPaths.resolveReachable("~/Pictures/x.png")
        #expect(tilde.path == home + "/Pictures/x.png")
        let relative = try await MCPPaths.resolveReachable("sub/y.png")
        #expect(relative.path == MCPTestSupport.agentRootOverride.standardizedFileURL.appendingPathComponent("sub/y.png").path)
        let absolute = try await MCPPaths.resolveReachable("/tmp/z.png")
        #expect(absolute.path == "/tmp/z.png")
        let parent = try await MCPPaths.resolveReachable("sub/../w.png")
        #expect(parent.lastPathComponent == "w.png" && !parent.path.contains(".."))
        #expect(parent.deletingLastPathComponent().resolvingSymlinksInPath().path
                == MCPTestSupport.agentRootOverride.resolvingSymlinksInPath().path)
        let agentFolder = try await MCPPaths.resolveReachable(nil)
        #expect(agentFolder.path == MCPTestSupport.agentRootOverride.standardizedFileURL.path)
        await #expect(throws: MCPToolError.self) {
            try await MCPPaths.resolveReachable("definitely-missing-\(UUID().uuidString).png", mustExist: true)
        }
    }
}
