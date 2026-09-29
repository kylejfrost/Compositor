import Foundation
import Testing
import MCP
@testable import Compositor

/// What `tools/list` promises about each tool matches what its handler does: every tool's annotations, as ruled, and
/// schemas that describe the values the handlers take.
@MainActor struct MCPToolContractTests {
    /// Every tool's side effects: R read-only; A additive (changes the document or app, losing nothing); D destructive
    /// (may discard data or replace a file); I idempotent (calling again with the same arguments changes nothing
    /// more). A new tool must be added here, so its annotations are a decision rather than a default.
    static let annotations: [String: String] = [
        // Documents
        "list_documents": "R", "get_document": "R", "get_app_info": "R", "select_document": "AI", "new_document": "A",
        "open_document": "AI", "save_document": "DI", "save_document_as": "D", "export_image": "DI",
        "close_document": "D", "duplicate_document": "A", "revert_document": "D", "settle_pending_edits": "D",
        // Render and inspect
        "render_document": "R", "render_region": "R", "render_layer": "R", "get_layer_bounds": "R",
        "get_pixel_color": "R", "sample_colors": "R",
        // Files
        "list_files": "R", "get_file_info": "R", "reveal_in_finder": "AI",
        // Layers
        "get_layer": "R", "add_blank_layer": "A", "add_image_layer": "A", "add_group": "A", "rename_layer": "AI",
        "set_layer_visibility": "AI", "set_layer_opacity": "AI", "set_layer_fill_opacity": "AI",
        "set_layer_blend_mode": "AI", "set_layer_locks": "AI", "delete_layers": "D", "duplicate_layer": "A",
        "layer_via_copy": "A", "reorder_layer": "AI", "place_layer": "AI", "group_layers": "A", "ungroup_layer": "D",
        "set_clipping_mask": "AI", "select_layers": "AI", "merge_layers": "D", "flatten_image": "D",
        "rasterize_layer": "D",
        // Transforms
        "move_layer": "A", "set_layer_transform": "AI", "set_layer_scale": "AI", "scale_layer_to_fit": "AI",
        "rotate_layer": "A", "flip_layer": "A", "distort_layer": "D", "align_layers": "AI", "distribute_layers": "AI",
        // Canvas and guides
        "resize_canvas": "A", "resize_image": "A", "set_resolution": "AI", "crop": "D", "trim_canvas": "D",
        "flip_canvas": "A", "add_guide": "A", "remove_guide": "D", "clear_guides": "D", "list_guides": "R",
        // Adjustment layers
        "add_adjustment_layer": "A", "set_adjustment": "AI",
        // History
        "undo": "D", "redo": "D", "get_history": "R", "run_batch": "D",
        // View, tools and palette
        "zoom_to_fit": "AI", "set_zoom": "AI", "select_tool": "AI", "bring_app_to_front": "AI",
        "set_palette_colors": "AI",
        // Layer effects
        "set_layer_effects": "DI", "add_layer_effect": "A", "remove_layer_effect": "D",
        "set_layer_effect_enabled": "AI",
        // Selection
        "select_rect": "A", "select_ellipse": "A", "select_polygon": "A", "select_all": "AI", "select_none": "AI",
        "invert_selection": "A", "select_by_color": "A", "select_object": "A", "select_subject": "A",
        "load_layer_selection": "A", "modify_selection": "A", "transform_selection": "A", "move_selected_pixels": "D",
        "get_selection": "R",
        // Painting and pixels
        "fill_selection": "D", "clear_selection": "D", "invert_pixels": "D", "stroke_path": "D", "draw_gradient": "D",
        "get_layer_pixels": "AI", "set_layer_pixels": "D", "paste_image_into_layer": "D", "copy_pixels": "AI",
        "paste_pixels": "A",
        // Filters
        "apply_filter": "D", "apply_levels": "D", "apply_hue_saturation": "D", "content_aware_fill": "D",
        "remove_background": "A",
        // Masks
        "add_layer_mask": "A", "set_mask_enabled": "AI", "set_mask_linked": "AI", "delete_layer_mask": "D",
        "apply_layer_mask": "D", "copy_layer_mask": "A",
        // Profiles
        "list_profiles": "R", "import_profile": "AI",
        // Text and fonts
        "add_text_layer": "A", "set_text": "AI", "set_text_style": "AI", "fit_text": "AI", "get_text_metrics": "R",
        "list_fonts": "R", "check_fonts": "R",
        // Shapes
        "add_solid_fill": "A", "add_shape": "A", "set_shape_style": "AI",
        // Smart objects
        "place_smart_object": "A", "replace_smart_object_contents": "D", "get_smart_object_info": "R",
        "export_smart_object_contents": "DI",
    ]

    @Test func everyToolHasTheAnnotationsRuledForIt() {
        let tools = Dictionary(uniqueKeysWithValues: MCPToolRegistry.tools.map { ($0.name, $0.annotations) })
        #expect(Set(tools.keys) == Set(Self.annotations.keys),
                "Not in the table: \(Set(tools.keys).subtracting(Self.annotations.keys).sorted()); gone: \(Set(Self.annotations.keys).subtracting(tools.keys).sorted())")
        for (name, code) in Self.annotations.sorted(by: { $0.key < $1.key }) {
            guard let hints = tools[name] else { continue }
            let readOnly = code == "R"
            #expect(hints.readOnlyHint == readOnly, "\(name) readOnlyHint")
            #expect(hints.destructiveHint == code.hasPrefix("D"), "\(name) destructiveHint")
            #expect(hints.idempotentHint == (readOnly || code.hasSuffix("I")), "\(name) idempotentHint")
            #expect(hints.openWorldHint == false, "\(name) openWorldHint")
        }
    }

    // MARK: Schemas

    /// The input schema of `tool`'s `path` (dotted, into nested objects), the object form of one that may be null.
    private func schema(_ tool: String, _ path: String) -> [String: Value]? {
        func unwrapped(_ node: [String: Value]?) -> [String: Value]? { node?["anyOf"]?.arrayValue?.first?.objectValue ?? node }
        var node = MCPToolRegistry.tools.first { $0.name == tool }?.inputSchema.objectValue
        for key in path.split(separator: ".").map(String.init) {
            node = unwrapped(node)?["properties"]?.objectValue?[key]?.objectValue
        }
        return unwrapped(node)
    }

    @Test func numberRangesAreTheOnesTheHandlersEnforce() async throws {
        // set_zoom clamps any zoom above 0 into 0.001–32 and says so: the schema can't call the rest invalid.
        let zoom = try #require(schema("set_zoom", "zoom"))
        #expect(zoom["minimum"] == nil && zoom["maximum"] == nil && zoom["exclusiveMinimum"] == .double(0), "\(zoom)")
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let clamped = try await MCPTestSupport.call("set_zoom", ["zoom": 100], in: workspace)
        #expect(clamped["clamped"] == .bool(true))
        try await MCPTestSupport.call("set_zoom", ["zoom": 0], in: workspace, expectError: "invalid_argument")

        // resize_image refuses a percent of 0.
        let percent = try #require(schema("resize_image", "percent"))
        #expect(percent["minimum"] == nil && percent["exclusiveMinimum"] == .double(0) && percent["maximum"] == .double(10_000), "\(percent)")
        try await MCPTestSupport.call("resize_image", ["percent": 0], in: workspace, expectError: "invalid_argument")

        // render_region's padding stops at 30,000 pixels.
        #expect(schema("render_region", "padding")?["maximum"] == .double(30_000))
        try await MCPTestSupport.call("render_region", ["region": ["x": 0, "y": 0, "width": 4, "height": 4], "padding": 30_001],
                                      in: workspace, expectError: "invalid_argument")
    }

    /// A default in a schema is what a client may send when the caller says nothing. Where giving the argument changes
    /// what the call means — a gradient `style` alongside `colors`, a patch field that should keep its value — the
    /// schema must not offer one.
    @Test func noDefaultChangesWhatACallMeans() async throws {
        #expect(schema("draw_gradient", "style")?["default"] == nil)
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        // The default the description names, when neither is given.
        try await MCPTestSupport.call("draw_gradient", ["layer": "@active", "start": ["x": 0, "y": 0], "end": ["x": 8, "y": 0]],
                                      in: workspace)

        for effect in ["stroke", "shadow", "inner_shadow", "outer_glow", "color_overlay"] {
            let fields = schema("set_layer_effects", "effects.\(effect)")?["properties"]?.objectValue ?? [:]
            #expect(!fields.isEmpty, "\(effect)")
            for (field, value) in fields { #expect(value.objectValue?["default"] == nil, "set_layer_effects effects.\(effect).\(field)") }
        }
        let stroke = schema("set_shape_style", "stroke")?["properties"]?.objectValue ?? [:]
        #expect(!stroke.isEmpty)
        for (field, value) in stroke { #expect(value.objectValue?["default"] == nil, "set_shape_style stroke.\(field)") }

        // place_smart_object's fit applies only with fit_rect, and is refused without it.
        #expect(schema("place_smart_object", "fit")?["default"] == nil)
        try await MCPTestSupport.call("place_smart_object", ["path": "anything.png", "fit": "fill"], in: workspace,
                                      expectError: "invalid_argument")
    }

    /// Tools clamp a color's components into 0–1 rather than refusing them, so no schema calls the rest invalid.
    @Test func colorComponentsAreNotRangeLimited() async throws {
        let rgb = try #require(schema("set_palette_colors", "foreground")?["properties"]?.objectValue)
        for component in ["r", "g", "b"] {
            #expect(rgb[component]?.objectValue?["minimum"] == nil && rgb[component]?.objectValue?["maximum"] == nil, "\(component)")
        }
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        try await MCPTestSupport.call("set_palette_colors", ["foreground": ["r": 2, "g": -1, "b": 0.5]], in: workspace)
        #expect(workspace.current.session.foregroundColor == PaletteColor(red: 1, green: 0, blue: 0.5))
    }

    /// A tab index is never negative, and every `document` selector says so, select_document's included.
    @Test func everyDocumentSelectorsIndexStartsAtZero() async throws {
        var checked = 0
        for tool in MCPToolRegistry.tools {
            guard let selector = tool.inputSchema.objectValue?["properties"]?.objectValue?["document"]?.objectValue else { continue }
            let integer = selector["anyOf"]?.arrayValue?.compactMap(\.objectValue).first { $0["type"] == .string("integer") }
            #expect(integer?["minimum"] == .int(0), "\(tool.name): \(selector)")
            checked += 1
        }
        #expect(checked > 100)
        try await MCPTestSupport.call("get_document", ["document": -1], in: MCPTestSupport.workspace(width: 8, height: 8),
                                      expectError: "not_found")
    }

    /// run_batch's description names exactly the tools a batch refuses, and each is refused as a step.
    @Test func runBatchNamesTheToolsItRefuses() async throws {
        let description = try #require(MCPToolRegistry.tools.first { $0.name == "run_batch" }?.description)
        let sentence = try #require(description.components(separatedBy: "Steps can't be ").last?.components(separatedBy: ".").first)
        let named = Set(sentence.replacingOccurrences(of: " or ", with: ", ").components(separatedBy: ", "))
        #expect(named == MCPToolRegistry.batchDisallowedTools, "\(sentence)")
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        for tool in MCPToolRegistry.batchDisallowedTools.sorted() {
            let refused = try await MCPTestSupport.call("run_batch", ["steps": [["tool": .string(tool)]]], in: workspace,
                                                        expectError: "invalid_argument")
            #expect(refused["error"]?.objectValue?["message"]?.stringValue?.contains("can't run inside a batch") == true, "\(tool)")
        }
    }

    /// A tool describes only arguments it takes: "target mask" belongs to tools with a `target`.
    @Test func descriptionsNameOnlyArgumentsTheToolTakes() {
        for tool in MCPToolRegistry.tools where tool.description?.contains("target mask") == true {
            #expect(schema(tool.name, "target") != nil, "\(tool.name) mentions 'target mask' but takes no target")
        }
    }
}
