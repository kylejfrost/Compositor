import CoreGraphics
import Foundation
import Testing
import MCP
@testable import Compositor

/// The View and palette domain: zoom, the current tool, bringing Compositor forward, and the palette colors.
/// Serialized because the activation test swaps the process-wide app-activation hook.
@MainActor @Suite(.serialized) struct MCPViewToolTests {
    /// A 640×480 document shown in a 1000×800-point view on a 2× display.
    private func shownWorkspace() -> (ProjectWorkspace, EditorSession) {
        let workspace = MCPTestSupport.workspace(width: 640, height: 480)
        let session = workspace.current.session
        session.viewport.resize(to: CGSize(width: 1000, height: 800), backingScale: 2, documentSize: CGSize(width: 640, height: 480))
        return (workspace, session)
    }

    // MARK: Zoom

    @Test func zoomToFitFitsTheCanvasInTheView() async throws {
        let (workspace, session) = shownWorkspace()
        var expected = session.viewport
        expected.fit(documentSize: CGSize(width: 640, height: 480))

        try await MCPTestSupport.call("set_zoom", ["zoom": 4], in: workspace)
        #expect(session.viewport.zoom == 4)
        let fitted = try await MCPTestSupport.call("zoom_to_fit", in: workspace)
        #expect(session.viewport.zoom == expected.zoom && session.viewport.pan == .zero)
        #expect(fitted["zoom"]?.doubleValue == Double(expected.zoom))
    }

    @Test func setZoomClampsToTheViewportRange() async throws {
        let (workspace, session) = shownWorkspace()
        let high = try await MCPTestSupport.call("set_zoom", ["zoom": 100], in: workspace)
        #expect(session.viewport.zoom == CanvasViewport.zoomRange.upperBound)
        #expect(high["zoom"]?.doubleValue == Double(CanvasViewport.zoomRange.upperBound) && high["clamped"] == .bool(true))

        let low = try await MCPTestSupport.call("set_zoom", ["zoom": 0.00001], in: workspace)
        #expect(session.viewport.zoom == CanvasViewport.zoomRange.lowerBound)
        #expect(low["zoom"]?.doubleValue == Double(CanvasViewport.zoomRange.lowerBound) && low["clamped"] == .bool(true))

        let exact = try await MCPTestSupport.call("set_zoom", ["zoom": 2], in: workspace)
        #expect(session.viewport.zoom == 2 && exact["clamped"] == .bool(false))

        for bad: Value in [0, -1, "big"] {
            try await MCPTestSupport.call("set_zoom", ["zoom": bad], in: workspace, expectError: "invalid_argument")
        }
        try await MCPTestSupport.call("set_zoom", in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("set_zoom", ["zoom": 2, "anchor": "center"], in: workspace, expectError: "invalid_argument")
        #expect(session.viewport.zoom == 2)
    }

    @Test func setZoomKeepsTheAnchorPixelInPlace() async throws {
        let (workspace, session) = shownWorkspace()
        let size = CGSize(width: 640, height: 480)
        try await MCPTestSupport.call("set_zoom", ["zoom": 1], in: workspace)
        let pixel = CGPoint(x: 100, y: 50)
        let before = session.viewport.viewPoint(from: pixel, documentSize: size)
        try await MCPTestSupport.call("set_zoom", ["zoom": 3, "anchor": ["x": 100, "y": 50]], in: workspace)
        let after = session.viewport.viewPoint(from: pixel, documentSize: size)
        #expect(session.viewport.zoom == 3)
        #expect(abs(after.x - before.x) < 1e-9 && abs(after.y - before.y) < 1e-9)

        // Without an anchor the pixel at the middle of the view stays put, as the app's zoom buttons do.
        let middle = session.viewport.documentPoint(from: session.viewport.center, documentSize: size)
        try await MCPTestSupport.call("set_zoom", ["zoom": 0.5], in: workspace)
        let moved = session.viewport.viewPoint(from: middle, documentSize: size)
        #expect(abs(moved.x - session.viewport.center.x) < 1e-9 && abs(moved.y - session.viewport.center.y) < 1e-9)
    }

    @Test func zoomToolsNeedADocument() async throws {
        let workspace = ProjectWorkspace()
        try await MCPTestSupport.call("zoom_to_fit", in: workspace, expectError: "precondition_failed")
        try await MCPTestSupport.call("set_zoom", ["zoom": 2], in: workspace, expectError: "precondition_failed")
    }

    // MARK: Tools

    @Test func selectToolTakesSnakeCaseOrTheAppsNames() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 48)
        let session = workspace.current.session
        #expect(session.tool == .move)

        let brush = try await MCPTestSupport.call("select_tool", ["tool": "brush"], in: workspace)
        #expect(session.tool == .brush)
        #expect(brush["tool"]?.stringValue == "brush" && brush["previous"]?.stringValue == "move")
        let healing = try await MCPTestSupport.call("select_tool", ["tool": "spot_healing"], in: workspace)
        #expect(session.tool == .spotHealing && healing["tool"]?.stringValue == "spot_healing")
        try await MCPTestSupport.call("select_tool", ["tool": "cloneStamp"], in: workspace)
        #expect(session.tool == .cloneStamp)
        let same = try await MCPTestSupport.call("select_tool", ["tool": "Clone Stamp"], in: workspace)
        #expect(session.tool == .cloneStamp && same["previous"]?.stringValue == "clone_stamp")

        let unknown = try await MCPTestSupport.call("select_tool", ["tool": "eraser"], in: workspace, expectError: "invalid_argument")
        #expect(unknown["error"]?.objectValue?["message"]?.stringValue?.contains("spot_healing") == true)
        try await MCPTestSupport.call("select_tool", in: workspace, expectError: "invalid_argument")
        #expect(session.tool == .cloneStamp)

        // Every tool in the rail can be selected by its snake_case name.
        let schema = MCPToolRegistry.entriesByName["select_tool"]?.tool.inputSchema.objectValue?["properties"]?.objectValue?["tool"]
        let names = schema?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(names.count == NavigationTool.allCases.count)
        for name in names {
            try await MCPTestSupport.call("select_tool", ["tool": .string(name)], in: workspace)
            try await MCPTestSupport.call("select_tool", ["tool": "move"], in: workspace)
        }
    }

    @Test func selectToolRefusesWhileTheAppHoldsAnEdit() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 48)
        let session = workspace.current.session
        try await MCPTestSupport.call("add_blank_layer", ["name": "A"], in: workspace)

        // Switching tools would commit or cancel what the app is doing, so it waits for it.
        session.renamingLayerID = session.activeLayerID
        let renaming = try await MCPTestSupport.call("select_tool", ["tool": "brush"], in: workspace, expectError: "precondition_failed")
        #expect(renaming["error"]?.objectValue?["guard"]?.stringValue == "can_edit_layers")
        session.renamingLayerID = nil

        session.isProjectBusy = true
        try await MCPTestSupport.call("select_tool", ["tool": "brush"], in: workspace, expectError: "busy")
        session.isProjectBusy = false
        #expect(session.tool == .move)

        // Selecting crop starts a crop of the whole canvas, which switching away drops while it is untouched...
        let canvas = CGRect(x: 0, y: 0, width: 64, height: 48)
        try await MCPTestSupport.call("select_tool", ["tool": "crop"], in: workspace)
        #expect(session.tool == .crop && session.cropRect == canvas)
        try await MCPTestSupport.call("select_tool", ["tool": "move"], in: workspace)
        #expect(session.tool == .move && session.cropRect == nil)
        // ...unless something else holds the switch, and it stays as it was.
        try await MCPTestSupport.call("select_tool", ["tool": "crop"], in: workspace)
        session.renamingLayerID = session.activeLayerID
        try await MCPTestSupport.call("select_tool", ["tool": "move"], in: workspace, expectError: "precondition_failed")
        #expect(session.tool == .crop && session.cropRect == canvas)
        session.renamingLayerID = nil
        // A crop the user changed holds it too.
        let changed = CGRect(x: 4, y: 4, width: 32, height: 32)
        session.cropRect = changed
        try await MCPTestSupport.call("select_tool", ["tool": "move"], in: workspace, expectError: "precondition_failed")
        #expect(session.tool == .crop && session.cropRect == changed)
        session.cancelCrop()
        try await MCPTestSupport.call("select_tool", ["tool": "move"], in: workspace)

        // A tab without a document still switches tools.
        let empty = ProjectWorkspace()
        try await MCPTestSupport.call("select_tool", ["tool": "hand"], in: empty)
        #expect(empty.current.session.tool == .hand)
    }

    // MARK: App

    @Test func bringAppToFrontActivatesCompositor() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        var activations = 0
        let original = MCPToolRegistry.activateApp
        MCPToolRegistry.activateApp = { activations += 1 }
        defer { MCPToolRegistry.activateApp = original }

        try await MCPTestSupport.call("bring_app_to_front", in: workspace)
        #expect(activations == 1)
    }

    // MARK: Palette

    @Test func setPaletteColorsSetsEitherColorWithoutHistory() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let session = workspace.current.session
        let undoCount = session.history.undoCount, revision = session.history.revisionID, modified = session.isModified
        #expect(session.foregroundColor == .black && session.backgroundColor == .white)

        let red = try await MCPTestSupport.call("set_palette_colors", ["foreground": "#ff0000"], in: workspace)
        #expect(session.foregroundColor == PaletteColor(red: 1, green: 0, blue: 0) && session.backgroundColor == .white)
        #expect(red["foreground"]?.objectValue?["hex"]?.stringValue == "#ff0000")
        #expect(red["background"]?.objectValue?["hex"]?.stringValue == "#ffffff")

        try await MCPTestSupport.call("set_palette_colors", ["background": ["r": 0, "g": 0, "b": 1]], in: workspace)
        #expect(session.backgroundColor == PaletteColor(red: 0, green: 0, blue: 1))
        #expect(session.foregroundColor == PaletteColor(red: 1, green: 0, blue: 0))

        let both = try await MCPTestSupport.call("set_palette_colors", ["foreground": "#00ff00", "background": "#000000"], in: workspace)
        #expect(session.foregroundColor == PaletteColor(red: 0, green: 1, blue: 0) && session.backgroundColor == .black)
        #expect(both["background"]?.objectValue?["hex"]?.stringValue == "#000000")
        #expect(session.history.undoCount == undoCount && session.history.revisionID == revision && session.isModified == modified)

        try await MCPTestSupport.call("set_palette_colors", in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("set_palette_colors", ["foreground": "red"], in: workspace, expectError: "invalid_argument")
        session.isProjectBusy = true
        try await MCPTestSupport.call("set_palette_colors", ["foreground": "#ffffff"], in: workspace, expectError: "busy")
        session.isProjectBusy = false
        #expect(session.foregroundColor == PaletteColor(red: 0, green: 1, blue: 0))
    }

    @Test func viewToolsDeclareTheirEffects() {
        let byName = Dictionary(uniqueKeysWithValues: MCPToolRegistry.tools.map { ($0.name, $0.annotations) })
        for name in ["zoom_to_fit", "set_zoom", "select_tool", "bring_app_to_front", "set_palette_colors"] {
            let annotations = byName[name]
            #expect(annotations?.readOnlyHint == false && annotations?.destructiveHint == false && annotations?.idempotentHint == true,
                    "\(name)")
        }
    }
}
