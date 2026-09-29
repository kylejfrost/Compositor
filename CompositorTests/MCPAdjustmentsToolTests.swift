import CoreGraphics
import Foundation
import Testing
import MCP
@testable import Compositor

/// The adjustment tools: `add_adjustment_layer` adds a named, optionally clipped and configured layer as one undo
/// step without opening the app's settings panel, and `set_adjustment` changes a layer's settings through its
/// kind's shorthand keys or the full settings merged through `MCPCodable.decodeMerged`, as one "Edit Adjustment" step.
@MainActor struct MCPAdjustmentsToolTests {
    // MARK: Helpers

    /// Adds an adjustment layer of `kind` through the tool and returns its id.
    private func add(_ kind: String, in workspace: ProjectWorkspace, _ arguments: [String: Value] = [:]) async throws -> UUID {
        var arguments = arguments
        arguments["kind"] = .string(kind)
        let result = try await MCPTestSupport.call("add_adjustment_layer", arguments, in: workspace)
        return try #require(result["layer_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
    }

    @discardableResult
    private func set(_ id: UUID, _ settings: Value, in workspace: ProjectWorkspace, expectError code: String? = nil) async throws -> [String: Value] {
        try await MCPTestSupport.call("set_adjustment", ["layer": .string(id.uuidString), "settings": settings], in: workspace, expectError: code)
    }

    private func adjustment(_ session: EditorSession, _ id: UUID) -> LayerAdjustment? {
        session.document?.layers.first { $0.id == id }?.adjustment
    }

    private func error(_ result: [String: Value]) -> [String: Value] {
        result["error"]?.objectValue ?? [:]
    }

    private func message(_ result: [String: Value]) -> String {
        error(result)["message"]?.stringValue ?? ""
    }

    private func field(_ result: [String: Value]) -> String? {
        error(result)["details"]?.objectValue?["field"]?.stringValue
    }

    private func recorded(_ result: [String: Value]) -> Bool? {
        result["undo"]?.objectValue?["recorded"]?.boolValue
    }

    /// A 1×1 opaque image of one color.
    private func swatch(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return try #require(context.makeImage())
    }

    /// The red, green and blue bytes of a 1×1 image.
    private func rgb(_ image: CGImage) throws -> [Int] {
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return [Int(bytes[0]), Int(bytes[1]), Int(bytes[2])]
    }

    // MARK: set_adjustment

    @Test func flattenedKeysStillWork() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session

        let hsv = try await add("hue/saturation", in: workspace)
        try await set(hsv, ["hue": 30, "saturation": -40, "lightness": 10, "colorize": false], in: workspace)
        #expect(adjustment(session, hsv)?.resolvedHSV == HueSaturationSettings(hue: 30, saturation: -40, lightness: 10))

        let levels = try await add("levels", in: workspace)
        try await set(levels, ["channel": "Red", "black": 20, "gamma": 1.5, "white": 230, "output_black": 5, "output_white": 250],
                      in: workspace)
        let levelsSettings = try #require(adjustment(session, levels)?.levels)
        #expect(levelsSettings.ranges[LevelsChannel.red.index] == LevelRange(black: 20, gamma: 1.5, white: 230, outputBlack: 5, outputWhite: 250))
        #expect(levelsSettings.ranges[LevelsChannel.rgb.index] == LevelRange())
        #expect(levelsSettings.channel == .red)
        // Without a channel the shorthand edits the composite RGB range.
        try await set(levels, ["black": 12], in: workspace)
        #expect(adjustment(session, levels)?.levels.ranges[LevelsChannel.rgb.index].black == 12)

        let curves = try await add("curves", in: workspace)
        try await set(curves, ["channel": "blue", "points": [[0, 10], [128, 150], ["x": 255, "y": 240]]], in: workspace)
        let curvesSettings = try #require(adjustment(session, curves)?.curves)
        #expect(curvesSettings.channels[LevelsChannel.blue.index] == [CurvePoint(x: 0, y: 10), CurvePoint(x: 128, y: 150), CurvePoint(x: 255, y: 240)])
        #expect(curvesSettings.channels[LevelsChannel.rgb.index] == CurvesSettings().channels[0])

        let blur = try await add("gaussian blur", in: workspace)
        try await set(blur, ["radius": 4], in: workspace)
        #expect(adjustment(session, blur)?.blurRadius == 4)

        let motion = try await add("motion_blur", in: workspace)
        try await set(motion, ["angle": 45, "distance": 30], in: workspace)
        #expect(adjustment(session, motion)?.motionAngle == 45 && adjustment(session, motion)?.motionDistance == 30)

        let noise = try await add("add noise", in: workspace)
        try await set(noise, ["amount": 25, "gaussian": true, "monochromatic": true], in: workspace)
        let noiseSettings = try #require(adjustment(session, noise))
        #expect(noiseSettings.noiseAmount == 25 && noiseSettings.noiseGaussian == true && noiseSettings.noiseMonochromatic == true)

        let exposure = try await add("exposure", in: workspace)
        try await set(exposure, ["exposure": 1.5, "offset": -0.1, "gamma": 1.2], in: workspace)
        #expect(adjustment(session, exposure)?.exposure == ExposureSettings(exposure: 1.5, offset: -0.1, gamma: 1.2))

        let map = try await add("gradient map", in: workspace)
        try await set(map, ["shadows": "#ff0000", "highlights": ["r": 0, "g": 0, "b": 1], "reversed": true], in: workspace)
        #expect(adjustment(session, map)?.gradientMap == GradientMapSettings(shadows: AdjustmentColor(red: 1, green: 0, blue: 0),
                                                                              highlights: AdjustmentColor(red: 0, green: 0, blue: 1),
                                                                              reversed: true))

        let grain = try await add("grain", in: workspace)
        let seed = adjustment(session, grain)?.grain.seed
        try await set(grain, ["amount": 40, "size": 2, "roughness": 10], in: workspace)
        #expect(adjustment(session, grain)?.grain == GrainSettings(amount: 40, size: 2, roughness: 10, seed: seed ?? 0))

        let mono = try await add("black & white", in: workspace)
        try await set(mono, ["reds": 10, "tint": true, "tint_hue": 200], in: workspace)
        let monoSettings = try #require(adjustment(session, mono)?.blackWhite)
        #expect(monoSettings.reds == 10 && monoSettings.tint && monoSettings.tintHue == 200 && monoSettings.yellows == BlackWhiteSettings().yellows)

        let balance = try await add("color_balance", in: workspace)
        try await set(balance, ["mid_cyan_red": 30, "preserve_luminosity": false], in: workspace)
        let balanceSettings = try #require(adjustment(session, balance)?.colorBalance)
        #expect(balanceSettings.midCyanRed == 30 && !balanceSettings.preserveLuminosity && balanceSettings.shadowCyanRed == 0)
    }

    @Test func nestedColorRangeSettingsPatchOneRange() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        let id = try await add("hsv", in: workspace, ["settings": ["saturation": -20]])

        let result = try await set(id, ["hsv_settings": ["adjustments": ["reds": ["hue": 30]]]], in: workspace)
        let hsv = try #require(adjustment(session, id)?.hsvSettings)
        #expect(hsv.adjustments[.reds] == RangeAdjustment(hue: 30, saturation: 0, lightness: 0))
        #expect(hsv.adjustments[.master] == RangeAdjustment(hue: 0, saturation: -20, lightness: 0), "Master keeps what the layer had")
        let settings = result["settings"]?.objectValue
        let reds = settings?["hsv_settings"]?.objectValue?["adjustments"]?.objectValue?["reds"]?.objectValue
        #expect(MCPValues.number(reds?["hue"]) == 30, "\(String(describing: settings))")
        #expect(settings?["hue"] == nil, "The flat fields hsv_settings replaces aren't reported")
        #expect(result["kind"]?.stringValue == "hue_saturation")

        // Range keys match loosely and merge field by field; the shorthand now edits Master inside hsv_settings.
        try await set(id, ["hsv_settings": ["adjustments": ["Reds": ["saturation": 15]]], "lightness": 5], in: workspace)
        let after = try #require(adjustment(session, id)?.hsvSettings)
        #expect(after.adjustments[.reds] == RangeAdjustment(hue: 30, saturation: 15, lightness: 0))
        #expect(after.adjustments[.master] == RangeAdjustment(hue: 0, saturation: -20, lightness: 5))
    }

    @Test func reportedSettingsPatchBackUnchanged() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        let changes: [(kind: String, settings: Value)] = [
            ("hsv", ["saturation": -30]),
            ("hsv", ["hsv_settings": ["adjustments": ["blues": ["hue": 40]], "range": "blues"]]),
            ("levels", ["channel": "green", "gamma": 1.4]), ("curves", ["points": [[0, 20], [255, 235]]]),
            ("exposure", ["offset": 0.2]), ("gradient_map", ["reversed": true]), ("grain", ["size": 3]),
            ("gaussian_blur", ["radius": 2]), ("motion_blur", ["angle": -30]), ("add_noise", ["gaussian": true]),
            ("invert", [:]), ("black_white", ["tint": true]), ("color_balance", ["highlight_yellow_blue": -15]),
        ]
        for change in changes {
            let id = try await add(change.kind, in: workspace, ["settings": change.settings])
            let value = adjustment(session, id)
            let settings = try #require(try await set(id, [:], in: workspace)["settings"])
            let again = try await set(id, settings, in: workspace)
            #expect(recorded(again) == false, "\(change.kind): \(settings)")
            #expect(adjustment(session, id) == value, "\(change.kind)")
        }
    }

    @Test func aColorRangeShiftsOnlyItsColors() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        let id = try await add("hsv", in: workspace)
        try await set(id, ["hsv_settings": ["adjustments": ["reds": ["hue": 120]]]], in: workspace)
        let value = try #require(adjustment(session, id))

        let red = try rgb(value.apply(swatch(red: 1, green: 0, blue: 0)))
        #expect(red[1] > 200 && red[0] < 60, "Red turns green: \(red)")
        let blue = try rgb(value.apply(swatch(red: 0, green: 0, blue: 1)))
        #expect(zip(blue, [0, 0, 255]).allSatisfy { abs($0 - $1) <= 2 }, "Blue is outside the reds: \(blue)")
    }

    @Test func setAdjustmentIsExactlyOneUndoEntry() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        let id = try await add("levels", in: workspace)
        let before = session.history.undoCount

        let result = try await set(id, ["black": 30, "white": 220], in: workspace)
        #expect(session.history.undoCount == before + 1)
        #expect(session.history.undoName == "Edit Adjustment")
        #expect(recorded(result) == true && result["undo"]?.objectValue?["name"]?.stringValue == "Edit Adjustment")
        #expect(adjustment(session, id)?.levels.ranges[0] == LevelRange(black: 30, gamma: 1, white: 220, outputBlack: 0, outputWhite: 255))

        // The same settings again, or an empty patch, change nothing and record nothing.
        let same = try await set(id, ["black": 30], in: workspace)
        let empty = try await set(id, [:], in: workspace)
        #expect(recorded(same) == false && recorded(empty) == false)
        #expect(session.history.undoCount == before + 1)

        try await MCPTestSupport.call("undo", in: workspace)
        #expect(adjustment(session, id)?.levels == LevelsSettings())
    }

    @Test func wrongTypesBadPointsAndOutOfRangeValuesFail() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        let hsv = try await add("hsv", in: workspace)
        let levels = try await add("levels", in: workspace)
        let curves = try await add("curves", in: workspace)
        let exposure = try await add("exposure", in: workspace)
        let document = session.document
        let before = session.history.undoCount

        let colorize = try await set(hsv, ["colorize": "yes"], in: workspace, expectError: "invalid_argument")
        #expect(message(colorize).contains("colorize"), "\(message(colorize))")

        let shortPoint = try await set(curves, ["points": [[0, 0], [128], [255, 255]]], in: workspace, expectError: "invalid_argument")
        #expect(field(shortPoint) == "points[1]", "\(message(shortPoint))")
        let textPoint = try await set(curves, ["points": [[0, 0], ["x": 128, "y": "high"], [255, 255]]], in: workspace,
                                      expectError: "invalid_argument")
        #expect(field(textPoint) == "points[1]", "\(message(textPoint))")
        let farPoint = try await set(curves, ["points": [[0, 0], [300, 10], [255, 255]]], in: workspace, expectError: "invalid_argument")
        #expect(field(farPoint) == "points[1]" && message(farPoint).contains("0–255"), "\(message(farPoint))")
        let noEnds = try await set(curves, ["points": [[10, 0], [255, 255]]], in: workspace, expectError: "invalid_argument")
        #expect(message(noEnds).contains("x 0"), "\(message(noEnds))")
        let channel = try await set(curves, ["channel": "purple", "points": [[0, 0], [255, 255]]], in: workspace, expectError: "invalid_argument")
        #expect(field(channel) == "channel" && message(channel).contains("rgb"), "\(message(channel))")

        let black = try await set(levels, ["black": 300], in: workspace, expectError: "invalid_argument")
        #expect(message(black).contains("black") && message(black).contains("0–254"), "\(message(black))")
        let crossed = try await set(levels, ["black": 200, "white": 150], in: workspace, expectError: "invalid_argument")
        #expect(message(crossed).contains("white") && message(crossed).contains("black"), "\(message(crossed))")
        let twice = try await set(levels, ["black": 30, "levels": ["ranges": []]], in: workspace, expectError: "invalid_argument")
        #expect(message(twice).contains("levels.ranges"), "\(message(twice))")

        let foreign = try await set(exposure, ["radius": 4], in: workspace, expectError: "invalid_argument")
        #expect(field(foreign) == "radius" && message(foreign).contains("Exposure"), "\(message(foreign))")
        let otherKind = try await set(exposure, ["blur_radius": 4], in: workspace, expectError: "invalid_argument")
        #expect(field(otherKind) == "blur_radius", "\(message(otherKind))")
        let range = try await set(exposure, ["exposure_settings": ["exposure": 30]], in: workspace, expectError: "invalid_argument")
        #expect(field(range) == "exposure_settings.exposure" && message(range).contains("-20–20"), "\(message(range))")
        let kind = try await set(exposure, ["kind": "levels"], in: workspace, expectError: "invalid_argument")
        #expect(field(kind) == "kind", "\(message(kind))")
        let both = try await set(exposure, ["exposure": 1, "exposure_settings": ["exposure": 2]], in: workspace, expectError: "invalid_argument")
        #expect(message(both).contains("exposure_settings.exposure"), "\(message(both))")

        let unknownRange = try await set(hsv, ["hsv_settings": ["adjustments": ["purples": ["hue": 10]]]], in: workspace,
                                         expectError: "invalid_argument")
        #expect(field(unknownRange) == "hsv_settings.adjustments.purples", "\(message(unknownRange))")
        let typedRange = try await set(hsv, ["hsv_settings": ["adjustments": ["reds": ["hue": "warm"]]]], in: workspace,
                                       expectError: "invalid_argument")
        #expect(field(typedRange) == "hsv_settings.adjustments.reds.hue", "\(message(typedRange))")
        let rangeValue = try await set(hsv, ["hsv_settings": ["adjustments": ["reds": ["saturation": 150]]]], in: workspace,
                                       expectError: "invalid_argument")
        #expect(field(rangeValue) == "hsv_settings.adjustments.reds.saturation" && message(rangeValue).contains("-100–100"),
                "\(message(rangeValue))")
        let selected = try await set(hsv, ["hsv_settings": ["range": "teal"]], in: workspace, expectError: "invalid_argument")
        #expect(field(selected) == "hsv_settings.range" && message(selected).contains("reds"), "\(message(selected))")

        #expect(session.document == document)
        #expect(session.history.undoCount == before)
    }

    @Test func onlyCompositorAdjustmentLayersHaveSettings() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        var placeholder = ImageLayer(name: "Brightness Contrast 1", blankSize: CGSize(width: 32, height: 32))
        placeholder.isVisible = false
        placeholder.psdExtras = PSDLayerExtras(importedVisible: true, placeholder: "adjustment:brit")
        session.document?.layers.append(placeholder)

        let result = try await set(placeholder.id, ["hue": 10], in: workspace, expectError: "unsupported")
        #expect(error(result)["hint"]?.stringValue?.contains("add_adjustment_layer") == true, "\(error(result))")
        #expect(error(result)["guard"]?.stringValue == "placeholder", "\(error(result))")
        #expect(session.document?.layers.last?.psdExtras?.placeholder == "adjustment:brit")

        let pixels = try #require(session.document?.layers.first?.id)
        let notAdjustment = try await set(pixels, ["hue": 10], in: workspace, expectError: "precondition_failed")
        #expect(error(notAdjustment)["guard"]?.stringValue == "is_adjustment")
    }

    // MARK: add_adjustment_layer

    @Test func addAdjustmentLayerNamesClipsAndConfiguresInOneStep() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        let base = try #require(session.activeLayerID)
        let before = session.history.undoCount

        let result = try await MCPTestSupport.call(
            "add_adjustment_layer", ["kind": "levels", "name": "Tone", "clip_to_below": true, "settings": ["black": 20]], in: workspace)
        let id = try #require(result["layer_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let layer = try #require(session.document?.layers.first { $0.id == id })
        #expect(layer.name == "Tone")
        #expect(layer.maskSourceID == base)
        #expect(layer.adjustment?.levels.ranges[0].black == 20)
        #expect(session.adjustmentEditingID == nil, "No settings panel opens for an agent's layer")
        #expect(session.history.undoCount == before + 1)
        #expect(session.history.undoName == "New Levels Adjustment")
        #expect(recorded(result) == true && result["undo"]?.objectValue?["name"]?.stringValue == "New Levels Adjustment")
        #expect(result["kind"]?.stringValue == "levels" && result["name"]?.stringValue == "Tone" && result["clipping"] == .bool(true))
        let ranges = result["settings"]?.objectValue?["levels"]?.objectValue?["ranges"]?.arrayValue
        #expect(MCPValues.number(ranges?.first?.objectValue?["black"]) == 20, "\(String(describing: result["settings"]))")

        try await MCPTestSupport.call("undo", in: workspace)
        #expect(session.document?.layers.contains { $0.id == id } == false)
    }

    @Test func anAdjustmentThatCannotClipLeavesNothingBehind() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        try await MCPTestSupport.call("add_group", ["name": "Folder"], in: workspace)
        let document = session.document
        let active = session.activeLayerID
        let before = session.history.undoCount

        // Inside the empty folder the new layer has nothing below it to clip to.
        let result = try await MCPTestSupport.call("add_adjustment_layer", ["kind": "invert", "clip_to_below": true], in: workspace,
                                                   expectError: "precondition_failed")
        #expect(error(result)["guard"]?.stringValue == "can_clip")
        #expect(session.document == document)
        #expect(session.activeLayerID == active)
        #expect(session.history.undoCount == before)
    }

    /// A Hue/Saturation layer's hue follows the app's dialog: a shift from −180 to 180, or with colorize 0–360.
    @Test func hueTakesTheDialogsRanges() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let session = workspace.current.session
        let id = try await add("hue_saturation", in: workspace)
        let before = adjustment(session, id)
        let refused: [(Value, String)] = [
            (["hue": 200], "hue"),
            (["colorize": true, "hue": -30], "hue"),
            (["hsv_settings": ["adjustments": ["reds": ["hue": 190]]]], "hsv_settings.adjustments.reds.hue"),
        ]
        for (settings, expected) in refused {
            let result = try await set(id, settings, in: workspace, expectError: "invalid_argument")
            #expect(field(result) == expected, "\(settings): \(result)")
        }
        #expect(adjustment(session, id) == before)
        try await set(id, ["colorize": true, "hue": 300], in: workspace)
        #expect(adjustment(session, id)?.resolvedHSV.hue == 300)

        let layers = session.document?.layers.count
        let added = try await MCPTestSupport.call("add_adjustment_layer", ["kind": "hsv", "settings": ["hue": 270]], in: workspace,
                                                  expectError: "invalid_argument")
        #expect(field(added) == "hue" && session.document?.layers.count == layers)
    }

    @Test func theLayerLimitIsAPrecondition() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let session = workspace.current.session
        session.document?.layers = (0..<10_000).map { ImageLayer(name: "Layer \($0)", blankSize: CGSize(width: 8, height: 8)) }
        session.activeLayerID = session.document?.layers.last?.id

        let result = try await MCPTestSupport.call("add_adjustment_layer", ["kind": "exposure"], in: workspace, expectError: "precondition_failed")
        #expect(error(result)["guard"]?.stringValue == "max_layers")
        #expect(session.document?.layers.count == 10_000)
    }
}
