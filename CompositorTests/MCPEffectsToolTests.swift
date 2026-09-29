import CoreGraphics
import Foundation
import Testing
import MCP
@testable import Compositor

/// The effects tools: `set_layer_effects` patches a layer's effects through `MCPCodable.decodeMerged`,
/// `add_layer_effect`/`remove_layer_effect`/`set_layer_effect_enabled` work one effect at a time, and every
/// change is one undo step that never opens the app's effects panel.
@MainActor struct MCPEffectsToolTests {
    // MARK: Helpers

    /// A workspace whose active layer is an opaque 20×20 square named "Square".
    private func squareWorkspace() throws -> (workspace: ProjectWorkspace, session: EditorSession, id: UUID) {
        let workspace = MCPTestSupport.workspace(width: 64, height: 48)
        let session = workspace.current.session
        let context = try #require(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Square"))
        return (workspace, session, try #require(session.activeLayerID))
    }

    private func effects(_ session: EditorSession, _ id: UUID) -> LayerEffects? {
        session.document?.layers.first { $0.id == id }?.effects
    }

    private func message(_ result: [String: Value]) -> String {
        result["error"]?.objectValue?["message"]?.stringValue ?? ""
    }

    private func recorded(_ result: [String: Value]) -> Bool? {
        result["undo"]?.objectValue?["recorded"]?.boolValue
    }

    // MARK: set_layer_effects

    @Test func mergeKeepsOtherEffects() async throws {
        let (workspace, session, id) = try squareWorkspace()
        let before = session.history.undoCount
        try await MCPTestSupport.call("set_layer_effects", ["layer": "Square", "effects": ["stroke": ["size": 6, "color": "#ff0000"]]],
                                      in: workspace)
        let result = try await MCPTestSupport.call(
            "set_layer_effects", ["layer": "Square", "effects": ["shadow": ["distance": 12, "color": ["r": 0, "g": 0, "b": 1]]]],
            in: workspace)
        let effects = try #require(effects(session, id))
        #expect(effects.stroke?.size == 6 && effects.stroke?.red == 1 && effects.stroke?.green == 0)
        #expect(effects.shadow?.distance == 12 && effects.shadow?.blue == 1)
        #expect(effects.shadow?.blur == ShadowEffect().blur && effects.shadow?.opacity == ShadowEffect().opacity)
        #expect(session.history.undoCount == before + 2)
        #expect(session.history.undoName == "Layer Effects")
        #expect(recorded(result) == true)
        let stroke = result["effects"]?.objectValue?["stroke"]?.objectValue
        #expect(MCPValues.number(stroke?["size"]) == 6 && stroke?["enabled"] == .bool(true))
        #expect(result["layer_id"]?.stringValue == id.uuidString)
    }

    @Test func sizeOutOfRangeFailsNamingTheRange() async throws {
        let (workspace, session, id) = try squareWorkspace()
        let before = session.history.undoCount
        let result = try await MCPTestSupport.call(
            "set_layer_effects", ["layer": "Square", "effects": ["stroke": ["size": 900]]], in: workspace, expectError: "invalid_argument")
        #expect(message(result).contains("stroke.size") && message(result).contains("0–500"), "\(message(result))")
        #expect(effects(session, id) == nil)
        #expect(session.history.undoCount == before)
    }

    @Test func nullRemovesAnEffect() async throws {
        let (workspace, session, id) = try squareWorkspace()
        try await MCPTestSupport.call("set_layer_effects", ["layer": "Square", "effects": ["stroke": [:], "outer_glow": ["size": 8]]],
                                      in: workspace)
        #expect(effects(session, id)?.kinds == [.stroke, .outerGlow])
        try await MCPTestSupport.call("set_layer_effects", ["layer": "Square", "effects": ["outer_glow": nil]], in: workspace)
        #expect(effects(session, id)?.kinds == [.stroke])
        try await MCPTestSupport.call("set_layer_effects", ["layer": "Square", "effects": ["stroke": nil]], in: workspace)
        #expect(effects(session, id) == nil)
    }

    @Test func mergeFalseReplacesTheWholeSet() async throws {
        let (workspace, session, id) = try squareWorkspace()
        try await MCPTestSupport.call("set_layer_effects", ["layer": "Square", "effects": ["stroke": ["size": 3]]], in: workspace)
        try await MCPTestSupport.call("set_layer_effects", ["layer": "Square", "merge": false, "effects": ["outer_glow": ["size": 8]]],
                                      in: workspace)
        var glow = OuterGlowEffect()
        glow.size = 8
        #expect(effects(session, id) == LayerEffects(outerGlow: glow))
    }

    @Test func unknownFieldsFailAndKindNamesWorkAsKeys() async throws {
        let (workspace, session, id) = try squareWorkspace()
        let result = try await MCPTestSupport.call(
            "set_layer_effects", ["layer": "Square", "effects": ["stroke": ["sise": 3]]], in: workspace, expectError: "invalid_argument")
        #expect(message(result).contains("stroke.sise"), "\(message(result))")
        try await MCPTestSupport.call("set_layer_effects", ["layer": "Square", "effects": ["drop_shadow": ["distance": 5]]], in: workspace)
        #expect(effects(session, id)?.shadow?.distance == 5)
    }

    @Test func strayRGBKeysFailInsteadOfDroppingTheOtherFields() async throws {
        let (workspace, session, id) = try squareWorkspace()
        let before = session.history.undoCount
        let overlay = try await MCPTestSupport.call(
            "set_layer_effects", ["layer": "Square", "effects": ["color_overlay": ["r": 1, "g": 0, "b": 0, "opacity": 0.5]]],
            in: workspace, expectError: "invalid_argument")
        #expect(message(overlay).contains("color_overlay.b"), "\(message(overlay))")
        let stroke = try await MCPTestSupport.call(
            "add_layer_effect", ["layer": "Square", "kind": "stroke", "settings": ["r": 1, "g": 0, "b": 0, "size": 8]],
            in: workspace, expectError: "invalid_argument")
        #expect(message(stroke).contains("stroke.b"), "\(message(stroke))")
        let whole = try await MCPTestSupport.call("set_layer_effects", ["layer": "Square", "effects": ["stroke": "#ff0000"]],
                                                  in: workspace, expectError: "invalid_argument")
        #expect(message(whole).contains("'stroke'"), "\(message(whole))")
        #expect(effects(session, id) == nil && session.history.undoCount == before)
        // The same change through `color` keeps both fields.
        try await MCPTestSupport.call(
            "set_layer_effects", ["layer": "Square", "effects": ["color_overlay": ["color": ["r": 1, "g": 0, "b": 0], "opacity": 0.5]]],
            in: workspace)
        let applied = try #require(effects(session, id)?.colorOverlay)
        #expect(applied.red == 1 && applied.green == 0 && applied.blue == 0 && applied.opacity == 0.5)
    }

    @Test func nullOnANameThatIsNoEffectOrFieldFails() async throws {
        let (workspace, session, id) = try squareWorkspace()
        session.setEffects(LayerEffects(stroke: StrokeEffect()), on: id)
        let before = session.history.undoCount
        for patch: Value in [["glow": nil], ["overlay": nil]] {
            let result = try await MCPTestSupport.call("set_layer_effects", ["layer": "Square", "effects": patch],
                                                       in: workspace, expectError: "invalid_argument")
            #expect(message(result).contains("Unknown field"), "\(message(result))")
        }
        let field = try await MCPTestSupport.call("set_layer_effects", ["layer": "Square", "effects": ["stroke": ["sise": nil]]],
                                                  in: workspace, expectError: "invalid_argument")
        #expect(message(field).contains("stroke.sise"), "\(message(field))")
        let settings = try await MCPTestSupport.call("add_layer_effect", ["layer": "Square", "kind": "stroke", "settings": ["sise": nil]],
                                                     in: workspace, expectError: "invalid_argument")
        #expect(message(settings).contains("stroke.sise"), "\(message(settings))")
        // Real names still remove: an effect or optional field the layer doesn't have is already gone.
        let absent = try await MCPTestSupport.call(
            "set_layer_effects", ["layer": "Square", "effects": ["shadow": nil, "stroke": ["enabled": nil]]], in: workspace)
        #expect(recorded(absent) == false)
        #expect(effects(session, id) == LayerEffects(stroke: StrokeEffect()) && session.history.undoCount == before)
    }

    @Test func unchangedEffectsRecordNoUndoStep() async throws {
        let (workspace, session, _) = try squareWorkspace()
        let args: [String: Value] = ["layer": "Square", "effects": ["stroke": ["size": 6]]]
        try await MCPTestSupport.call("set_layer_effects", args, in: workspace)
        let count = session.history.undoCount
        let again = try await MCPTestSupport.call("set_layer_effects", args, in: workspace)
        #expect(recorded(again) == false)
        // A stroke with no explicit `enabled` is already shown.
        let shown = try await MCPTestSupport.call("set_layer_effects", ["layer": "Square", "effects": ["stroke": ["enabled": true]]],
                                                  in: workspace)
        #expect(recorded(shown) == false)
        #expect(session.history.undoCount == count)
    }

    @Test func foldersAndEmptyLayersAreRefused() async throws {
        let (workspace, session, _) = try squareWorkspace()
        session.addGroup()
        let folder = try #require(session.activeLayerID)
        try await MCPTestSupport.call("set_layer_effects", ["layer": .string(folder.uuidString), "effects": ["stroke": [:]]],
                                      in: workspace, expectError: "precondition_failed")
        session.addBlankLayer()
        let blank = try #require(session.activeLayerID)
        try await MCPTestSupport.call("add_layer_effect", ["layer": .string(blank.uuidString), "kind": "stroke"],
                                      in: workspace, expectError: "precondition_failed")
    }

    @Test func anOpenPanelCannotCancelTheAgentsEdit() async throws {
        let (workspace, session, id) = try squareWorkspace()
        session.setEffects(LayerEffects(stroke: StrokeEffect()), on: id)
        session.selectEffect(.stroke, on: id, editing: true)
        try await MCPTestSupport.call("set_layer_effects", ["layer": "Square", "effects": ["stroke": ["size": 9]]], in: workspace)
        session.finishEffectsEditing(commit: false)
        #expect(effects(session, id)?.stroke?.size == 9)
    }

    @Test func importedPhotoshopEffectsStayForTheWriter() async throws {
        let (workspace, session, id) = try squareWorkspace()
        let imported = LayerEffects(stroke: StrokeEffect())
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].effects = imported
        session.document?.layers[index].psdExtras = PSDLayerExtras(importedEffects: imported)
        try await MCPTestSupport.call("set_layer_effects", ["layer": "Square", "effects": ["stroke": ["size": 9]]], in: workspace)
        #expect(effects(session, id)?.stroke?.size == 9)
        #expect(session.document?.layers[index].psdExtras?.importedEffects == imported)
    }

    // MARK: add_layer_effect / remove_layer_effect / set_layer_effect_enabled

    @Test func addUsesTheAppDefaultsWithoutOpeningThePanel() async throws {
        let (workspace, session, id) = try squareWorkspace()
        session.backgroundColor = PaletteColor(red: 0.2, green: 0.4, blue: 0.6)
        let before = session.history.undoCount
        let added = try await MCPTestSupport.call("add_layer_effect", ["layer": "Square", "kind": "stroke"], in: workspace)
        var stroke = StrokeEffect()
        stroke.red = 0.2; stroke.green = 0.4; stroke.blue = 0.6
        #expect(effects(session, id)?.stroke == stroke)
        #expect(added["added"] == .bool(true) && added["kind"] == .string("stroke"))
        #expect(session.effectsEditing == nil && session.colorPicker == nil)
        #expect(session.history.undoName == "Add Stroke" && session.history.undoCount == before + 1)

        try await MCPTestSupport.call("add_layer_effect", ["layer": "Square", "kind": "Drop Shadow", "settings": ["distance": 30]],
                                      in: workspace)
        var shadow = ShadowEffect()
        shadow.distance = 30
        #expect(effects(session, id)?.shadow == shadow)
        #expect(session.history.undoName == "Add Drop Shadow" && session.history.undoCount == before + 2)

        // Adding an effect the layer already has changes only what the settings say.
        let edited = try await MCPTestSupport.call("add_layer_effect", ["layer": "Square", "kind": "stroke", "settings": ["size": 10]],
                                                   in: workspace)
        stroke.size = 10
        #expect(effects(session, id)?.stroke == stroke && edited["added"] == .bool(false))
        #expect(session.history.undoName == "Edit Stroke")

        let bad = try await MCPTestSupport.call("add_layer_effect", ["layer": "Square", "kind": "outer_glow", "settings": ["size": 900]],
                                                in: workspace, expectError: "invalid_argument")
        #expect(message(bad).contains("0–500") && effects(session, id)?.outerGlow == nil, "\(message(bad))")
        try await MCPTestSupport.call("add_layer_effect", ["layer": "Square", "kind": "bevel"], in: workspace, expectError: "invalid_argument")
    }

    /// Inner Glow (upstream's effect) goes through the same tools as the rest: named inner_glow, sized 0–500.
    @Test func innerGlowIsSetAddedAndRangeChecked() async throws {
        let (workspace, session, id) = try squareWorkspace()
        let set = try await MCPTestSupport.call(
            "set_layer_effects", ["layer": "Square", "effects": ["inner_glow": ["size": 12, "color": "#ffcc00", "opacity": 0.5]]],
            in: workspace)
        let glow = try #require(effects(session, id)?.innerGlow)
        #expect(glow.size == 12 && glow.red == 1 && abs(glow.green - 0.8) < 0.001 && glow.blue == 0 && glow.opacity == 0.5)
        #expect(MCPValues.number(set["effects"]?.objectValue?["inner_glow"]?.objectValue?["size"]) == 12)
        let bad = try await MCPTestSupport.call("set_layer_effects", ["layer": "Square", "effects": ["inner_glow": ["size": 900]]],
                                                in: workspace, expectError: "invalid_argument")
        #expect(message(bad).contains("inner_glow.size") && message(bad).contains("0–500"), "\(message(bad))")
        try await MCPTestSupport.call("remove_layer_effect", ["layer": "Square", "kind": "inner_glow"], in: workspace)
        let added = try await MCPTestSupport.call("add_layer_effect", ["layer": "Square", "kind": "Inner Glow"], in: workspace)
        #expect(effects(session, id)?.innerGlow == InnerGlowEffect() && added["kind"] == .string("inner_glow"))
        let hidden = try await MCPTestSupport.call("set_layer_effect_enabled", ["layer": "Square", "kind": "inner_glow", "enabled": false],
                                                   in: workspace)
        #expect(effects(session, id)?.innerGlow?.enabled == false && recorded(hidden) == true)
    }

    @Test func removeDeletesOneEffect() async throws {
        let (workspace, session, id) = try squareWorkspace()
        session.setEffects(LayerEffects(stroke: StrokeEffect(), shadow: ShadowEffect()), on: id)
        let result = try await MCPTestSupport.call("remove_layer_effect", ["layer": "Square", "kind": "stroke"], in: workspace)
        #expect(effects(session, id) == LayerEffects(shadow: ShadowEffect()))
        #expect(result["undo"]?.objectValue?["name"] == .string("Remove Stroke"))
        try await MCPTestSupport.call("remove_layer_effect", ["layer": "Square", "kind": "stroke"], in: workspace, expectError: "not_found")
    }

    @Test func enabledTogglesOnlyWhenItChanges() async throws {
        let (workspace, session, id) = try squareWorkspace()
        session.setEffects(LayerEffects(stroke: StrokeEffect()), on: id)
        let count = session.history.undoCount
        let hidden = try await MCPTestSupport.call("set_layer_effect_enabled", ["layer": "Square", "kind": "stroke", "enabled": false],
                                                   in: workspace)
        #expect(effects(session, id)?.stroke?.enabled == false)
        #expect(hidden["undo"]?.objectValue?["name"] == .string("Hide Stroke") && recorded(hidden) == true)
        let again = try await MCPTestSupport.call("set_layer_effect_enabled", ["layer": "Square", "kind": "stroke", "enabled": false],
                                                  in: workspace)
        #expect(recorded(again) == false && session.history.undoCount == count + 1)
        try await MCPTestSupport.call("set_layer_effect_enabled", ["layer": "Square", "kind": "stroke", "enabled": true], in: workspace)
        #expect(effects(session, id)?.stroke?.isEnabled == true && session.history.undoName == "Show Stroke")
        try await MCPTestSupport.call("set_layer_effect_enabled", ["layer": "Square", "kind": "outer_glow", "enabled": true],
                                      in: workspace, expectError: "not_found")
    }

    @Test func effectToolsAreRegisteredWithTheirHints() {
        let tools = MCPToolRegistry.entriesByName
        #expect(tools["set_layer_effects"]?.tool.annotations.idempotentHint == true)
        #expect(tools["add_layer_effect"]?.tool.annotations.destructiveHint == false)
        #expect(tools["remove_layer_effect"]?.tool.annotations.destructiveHint == true)
        #expect(tools["set_layer_effect_enabled"]?.tool.annotations.idempotentHint == true)
    }
}
