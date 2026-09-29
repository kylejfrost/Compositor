import CoreGraphics
import Foundation
import Testing
import MCP
@testable import Compositor

/// The filter tools: `apply_filter`, `apply_levels` and `apply_hue_saturation` run the app's filters on a layer's pixels
/// with the call's settings and no panel, as one undo step each, leaving the user's own filter settings alone;
/// `content_aware_fill` and `remove_background` run the automatic filters, and every one is refused on a layer it
/// can't change.
@MainActor struct MCPFilterToolTests {
    // MARK: Helpers

    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A `width`×`height` image drawn with a top-left origin.
    private func image(width: Int, height: Int, _ draw: (CGContext) -> Void) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(context)
        return try #require(context.makeImage())
    }

    private func solid(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        try image(width: width, height: height) {
            $0.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            $0.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @discardableResult
    private func addLayer(_ session: EditorSession, _ name: String, _ image: CGImage) throws -> UUID {
        session.insert(ImportedImage(image: image, thumbnail: image, name: name))
        return try #require(session.activeLayerID)
    }

    private func index(_ session: EditorSession, _ id: UUID) throws -> Int {
        try #require(session.document?.layers.firstIndex { $0.id == id })
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let index = (y * image.width + x) * 4
        return (0..<4).map { Int(bytes[index + $0]) }
    }

    private func render(_ session: EditorSession) async throws -> CGImage {
        try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
    }

    private func recorded(_ result: [String: Value]) -> Bool? { result["undo"]?.objectValue?["recorded"]?.boolValue }

    private func guardName(_ result: [String: Value]) -> String? { result["error"]?.objectValue?["guard"]?.stringValue }

    private func field(_ result: [String: Value]) -> String? {
        result["error"]?.objectValue?["details"]?.objectValue?["field"]?.stringValue
    }

    /// No filter, levels or hue/saturation edit left open.
    private func nothingOpen(_ session: EditorSession) -> Bool {
        session.filterEdit == nil && session.levels == nil && session.hueSaturation == nil && !session.isProjectBusy
    }

    // MARK: apply_filter

    @Test func gaussianBlurSpreadsTheLayerWithTheCallsSettings() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 64)
        let session = workspace.current.session
        try addLayer(session, "Square", try image(width: 64, height: 64) {
            $0.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            $0.fill(CGRect(x: 22, y: 22, width: 20, height: 20))
        })
        var user = FilterSettings()
        user.radius = 42
        session.filterSettings = user
        #expect(try pixel(try await render(session), x: 19, y: 32)[3] == 0)
        let before = session.history.undoCount
        let result = try await MCPTestSupport.call("apply_filter", ["layer": "Square", "kind": "gaussian_blur", "settings": ["radius": 5]],
                                                   in: workspace)
        let rendered = try await render(session)
        #expect(try pixel(rendered, x: 19, y: 32)[3] > 0)
        #expect(try pixel(rendered, x: 32, y: 32)[3] > 200)
        #expect(try pixel(rendered, x: 2, y: 2)[3] == 0)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Gaussian Blur")
        #expect(recorded(result) == true)
        #expect(result["kind"] == .string("gaussian_blur"))
        #expect(MCPValues.number(result["settings"]?.objectValue?["blur_radius"]) == 5)
        #expect(session.filterSettings == user)
        #expect(nothingOpen(session))
    }

    @Test func otherFiltersTakeTheirAdjustmentSettings() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        try addLayer(session, "Gray", try solid(width: 32, height: 32, red: 0.5, green: 0.5, blue: 0.5))
        let gray = try pixel(try await render(session), x: 16, y: 16)[0]

        try await MCPTestSupport.call("apply_filter", ["layer": "Gray", "kind": "exposure", "settings": ["exposure": 1]], in: workspace)
        let value = try pixel(try await render(session), x: 16, y: 16)[0]
        #expect(value > gray + 20, "\(gray) → \(value)")
        #expect(session.history.undoName == "Exposure")

        try await MCPTestSupport.call("apply_filter", ["layer": "Gray", "kind": "Curves",
                                                       "settings": ["points": [[0, 255], [255, 0]]]], in: workspace)
        let inverted = try pixel(try await render(session), x: 16, y: 16)[0]
        #expect(abs(inverted - (255 - value)) <= 3, "\(value) → \(inverted)")
        #expect(session.history.undoName == "Curves")

        // Lens Correction's only setting; none to remove changes nothing.
        let before = session.history.undoCount
        let none = try await MCPTestSupport.call("apply_filter", ["layer": "Gray", "kind": "lens_correction"], in: workspace)
        #expect(recorded(none) == false && session.history.undoCount == before)
        try await MCPTestSupport.call("apply_filter", ["layer": "Gray", "kind": "lens correction", "settings": ["distortion": 40]],
                                      in: workspace)
        #expect(session.history.undoName == "Lens Correction" && session.history.undoCount == before + 1)
        #expect(nothingOpen(session))

        let count = session.history.undoCount
        let invalid: [(Comment, [String: Value], String?)] = [
            ("an unknown kind", ["kind": "sharpen"], nil),
            ("an automatic filter", ["kind": "remove_background"], nil),
            ("radius out of range", ["kind": "gaussian_blur", "settings": ["radius": 500]], "blur_radius"),
            ("another kind's setting", ["kind": "gaussian_blur", "settings": ["angle": 5]], "angle"),
            ("a noise seed", ["kind": "add_noise", "settings": ["noise_seed": 3]], "noise_seed"),
            ("a grain seed", ["kind": "grain", "settings": ["grain_settings": ["seed": 3]]], "grain_settings.seed"),
            ("a lens setting it lacks", ["kind": "lens_correction", "settings": ["amount": 3]], "amount"),
            ("distortion out of range", ["kind": "lens_correction", "settings": ["distortion": 101]], "distortion"),
            ("settings not an object", ["kind": "exposure", "settings": 3], nil),
        ]
        for (situation, arguments, expectedField) in invalid {
            var arguments = arguments
            arguments["layer"] = "Gray"
            let result = try await MCPTestSupport.call("apply_filter", arguments, in: workspace, expectError: "invalid_argument")
            if let expectedField { #expect(field(result) == expectedField, situation) }
            #expect(session.history.undoCount == count, situation)
        }
        #expect(nothingOpen(session))
    }

    /// Upstream's finishing filters and the Camera Raw filter have no adjustment layer: apply_filter takes their panels'
    /// sliders by name, reports them, and refuses a key or value the panel doesn't have.
    @Test func finishingFiltersAndCameraRawTakeTheirPanelsSliders() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        try addLayer(session, "Gray", try solid(width: 32, height: 32, red: 0.5, green: 0.5, blue: 0.5))
        let gray = try pixel(try await render(session), x: 16, y: 16)[0]

        let raw = try await MCPTestSupport.call("apply_filter", ["layer": "Gray", "kind": "camera_raw_filter",
                                                                 "settings": ["exposure": 1, "contrast": 10]], in: workspace)
        let brighter = try pixel(try await render(session), x: 16, y: 16)[0]
        #expect(brighter > gray + 20, "\(gray) → \(brighter)")
        #expect(session.history.undoName == "Camera Raw Filter" && recorded(raw) == true)
        let reported = try #require(raw["settings"]?.objectValue)
        #expect(MCPValues.number(reported["exposure"]) == 1 && MCPValues.number(reported["contrast"]) == 10)
        #expect(MCPValues.number(reported["clarity"]) == 0)

        let vignette = try await MCPTestSupport.call("apply_filter", ["layer": "Gray", "kind": "vignette",
                                                                      "settings": ["amount": 80, "color": "#000000"]], in: workspace)
        let rendered = try await render(session)
        #expect(try pixel(rendered, x: 0, y: 0)[0] < pixel(rendered, x: 16, y: 16)[0])
        #expect(MCPValues.number(vignette["settings"]?.objectValue?["amount"]) == 80)
        #expect(session.history.undoName == "Vignette")

        for kind in ["bloom_glow", "tonal_contrast"] {
            try await MCPTestSupport.call("apply_filter", ["layer": "Gray", "kind": .string(kind), "settings": ["amount": 60]],
                                          in: workspace)
        }
        #expect(session.history.undoName == "Tonal Contrast")
        #expect(nothingOpen(session))

        let count = session.history.undoCount
        let invalid: [(Comment, [String: Value], String)] = [
            ("a Camera Raw setting apply_filter doesn't take", ["kind": "camera_raw_filter", "settings": ["curve": 3]], "curve"),
            ("exposure out of range", ["kind": "camera_raw_filter", "settings": ["exposure": 6]], "exposure"),
            ("vignette amount out of range", ["kind": "vignette", "settings": ["amount": 101]], "amount"),
            ("a color that isn't one", ["kind": "vignette", "settings": ["color": "black"]], "color"),
            ("another filter's slider", ["kind": "bloom_glow", "settings": ["midtones": 3]], "midtones"),
        ]
        for (situation, arguments, expectedField) in invalid {
            var arguments = arguments
            arguments["layer"] = "Gray"
            let result = try await MCPTestSupport.call("apply_filter", arguments, in: workspace, expectError: "invalid_argument")
            #expect(field(result) == expectedField, situation)
            #expect(session.history.undoCount == count, situation)
        }
    }

    /// Vignette, as in the app, also paints an empty layer: the canvas framed in the vignette's color.
    @Test func vignettePaintsAnEmptyLayerAcrossTheCanvas() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        session.addBlankLayer()
        let id = try #require(session.activeLayerID)
        #expect(session.document?.layers.first { $0.id == id }?.asset == nil)
        try await MCPTestSupport.call("apply_filter", ["layer": .string(id.uuidString), "kind": "vignette",
                                                       "settings": ["amount": 100, "color": "#000000"]], in: workspace)
        let layer = try #require(session.document?.layers.first { $0.id == id })
        let pixels = try #require(layer.asset?.image)
        #expect(try pixel(pixels, x: 0, y: 0)[3] > 0)
        #expect(try pixel(pixels, x: pixels.width / 2, y: pixels.height / 2)[3] < pixel(pixels, x: 0, y: 0)[3])
        #expect(session.history.undoName == "Vignette")
        // Other filters still need pixels.
        session.addBlankLayer()
        let blank = try #require(session.activeLayerID)
        let refused = try await MCPTestSupport.call("apply_filter", ["layer": .string(blank.uuidString), "kind": "bloom_glow"],
                                                    in: workspace, expectError: "precondition_failed")
        #expect(guardName(refused) == "has_pixels")
    }

    // MARK: apply_levels

    @Test func levelsDarkenBrightenAndStretch() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        try addLayer(session, "Gray", try solid(width: 32, height: 32, red: 0.6, green: 0.6, blue: 0.6))
        let gray = try pixel(try await render(session), x: 16, y: 16)
        let before = session.history.undoCount
        let result = try await MCPTestSupport.call("apply_levels", ["layer": "Gray", "settings": ["black": 128]], in: workspace)
        let darker = try pixel(try await render(session), x: 16, y: 16)
        #expect(darker[0] < gray[0] - 30 && darker[1] < gray[1] - 30, "\(gray) → \(darker)")
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Levels")
        let ranges = result["settings"]?.objectValue?["ranges"]?.arrayValue
        #expect(MCPValues.number(ranges?.first?.objectValue?["black"]) == 128)

        // One channel, by shorthand or by the full list of ranges.
        try await MCPTestSupport.call("apply_levels", ["layer": "Gray", "settings": ["channel": "red", "white": 128]], in: workspace)
        let shifted = try pixel(try await render(session), x: 16, y: 16)
        #expect(shifted[0] > darker[0] + 20 && abs(shifted[1] - darker[1]) <= 2, "\(darker) → \(shifted)")
        let identity: Value = ["black": 0, "gamma": 1, "white": 255, "output_black": 0, "output_white": 255]
        try await MCPTestSupport.call("apply_levels", ["layer": "Gray", "settings": ["ranges": [
            identity, identity, ["black": 0, "gamma": 1, "white": 128, "output_black": 0, "output_white": 255], identity,
        ]]], in: workspace)
        let green = try pixel(try await render(session), x: 16, y: 16)
        #expect(green[1] > shifted[1] + 20, "\(shifted) → \(green)")

        // Auto contrast stretches a narrow range of values across the whole scale.
        try addLayer(session, "Flat", try image(width: 32, height: 32) {
            $0.setFillColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1)
            $0.fill(CGRect(x: 0, y: 0, width: 16, height: 32))
            $0.setFillColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1)
            $0.fill(CGRect(x: 16, y: 0, width: 16, height: 32))
        })
        try await MCPTestSupport.call("apply_levels", ["layer": "Flat", "auto": "contrast"], in: workspace)
        let stretched = try await render(session)
        #expect(try pixel(stretched, x: 4, y: 16)[0] < 20)
        #expect(try pixel(stretched, x: 28, y: 16)[0] > 235)
        #expect(nothingOpen(session))

        let count = session.history.undoCount
        let invalid: [(Comment, [String: Value], String?)] = [
            ("white under black", ["settings": ["black": 20, "white": 10]], nil),
            ("black out of range", ["settings": ["black": 300]], "ranges[0].black"),
            ("an unknown channel", ["settings": ["channel": "alpha", "black": 5]], "channel"),
            ("an unknown key", ["settings": ["contrast": 5]], "contrast"),
            ("nothing to apply", [:], nil),
            ("an unknown auto", ["auto": "sharp"], nil),
            ("ranges and shorthand", ["settings": ["black": 5, "ranges": [identity, identity, identity, identity]]], nil),
        ]
        for (situation, arguments, expectedField) in invalid {
            var arguments = arguments
            arguments["layer"] = "Gray"
            let result = try await MCPTestSupport.call("apply_levels", arguments, in: workspace, expectError: "invalid_argument")
            if let expectedField { #expect(field(result) == expectedField, situation) }
            #expect(session.history.undoCount == count, situation)
        }
        #expect(nothingOpen(session))
    }

    // MARK: apply_hue_saturation

    @Test func hueSaturationNeutralizesAndShiftsRanges() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        try addLayer(session, "Red", try solid(width: 32, height: 32, red: 1, green: 0, blue: 0))
        let before = session.history.undoCount

        // A range other than red's leaves red alone.
        try await MCPTestSupport.call("apply_hue_saturation", ["layer": "Red", "settings": ["range": "blues", "saturation": -100]],
                                      in: workspace)
        #expect(try pixel(try await render(session), x: 16, y: 16) == [255, 0, 0, 255])

        let result = try await MCPTestSupport.call("apply_hue_saturation", ["layer": "Red", "settings": ["saturation": -100]],
                                                   in: workspace)
        let neutral = try pixel(try await render(session), x: 16, y: 16)
        #expect(abs(neutral[0] - neutral[1]) <= 2 && abs(neutral[1] - neutral[2]) <= 2, "\(neutral)")
        #expect(session.history.undoName == "Hue/Saturation" && session.history.undoCount == before + 2)
        let master = result["settings"]?.objectValue?["adjustments"]?.objectValue?["master"]?.objectValue
        #expect(MCPValues.number(master?["saturation"]) == -100)

        try addLayer(session, "Red 2", try solid(width: 32, height: 32, red: 1, green: 0, blue: 0))
        try await MCPTestSupport.call("apply_hue_saturation", ["layer": "Red 2", "settings": ["adjustments": ["reds": ["hue": 120]]]],
                                      in: workspace)
        let shifted = try pixel(try await render(session), x: 16, y: 16)
        #expect(shifted[1] > 200 && shifted[0] < 40, "\(shifted)")

        let count = session.history.undoCount
        let identity = try await MCPTestSupport.call("apply_hue_saturation", ["layer": "Red 2", "settings": [:]], in: workspace)
        #expect(recorded(identity) == false && session.history.undoCount == count)
        let invalid: [(Comment, [String: Value], String?)] = [
            ("saturation out of range", ["saturation": -150], "adjustments.master.saturation"),
            ("an unknown range", ["range": "purples"], "range"),
            ("a hue that isn't a number", ["hue": "x"], "hue"),
            ("an unknown key", ["vibrance": 5], "vibrance"),
        ]
        for (situation, settings, expectedField) in invalid {
            let result = try await MCPTestSupport.call("apply_hue_saturation", ["layer": "Red 2", "settings": .object(settings)],
                                                       in: workspace, expectError: "invalid_argument")
            if let expectedField { #expect(field(result) == expectedField, situation) }
            #expect(session.history.undoCount == count, situation)
        }
        #expect(nothingOpen(session))
    }

    /// Hue as the app's Hue/Saturation dialog takes it: a shift from −180 to 180, or with colorize the hue to tint
    /// with, 0–360. The ±360 the settings could hold would draw wrong colors when colorizing.
    @Test func hueSaturationTakesTheDialogsHueRanges() async throws {
        let workspace = MCPTestSupport.workspace(width: 8, height: 8)
        let session = workspace.current.session
        _ = try addLayer(session, "Red", try solid(width: 8, height: 8, red: 1, green: 0, blue: 0))
        let count = session.history.undoCount
        let refused: [([String: Value], String)] = [
            (["hue": 200], "adjustments.master.hue"),
            (["hue": -181], "adjustments.master.hue"),
            (["colorize": true, "hue": -30], "adjustments.master.hue"),
            (["colorize": true, "hue": 361], "adjustments.master.hue"),
            (["adjustments": ["reds": ["hue": 190]]], "adjustments.reds.hue"),
        ]
        for (settings, expected) in refused {
            let result = try await MCPTestSupport.call("apply_hue_saturation", ["layer": "Red", "settings": .object(settings)],
                                                       in: workspace, expectError: "invalid_argument")
            #expect(field(result) == expected, "\(settings): \(result)")
        }
        #expect(session.history.undoCount == count)
        try await MCPTestSupport.call("apply_hue_saturation", ["layer": "Red", "settings": ["hue": -180]], in: workspace)
        try await MCPTestSupport.call("apply_hue_saturation", ["layer": "Red", "settings": ["colorize": true, "hue": 270, "saturation": 50]],
                                      in: workspace)
        #expect(session.history.undoCount == count + 2)
    }

    // MARK: Automatic filters

    @Test func contentAwareFillNeedsASelectionAndFillsIt() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        let blank = try #require(session.activeLayerID)
        let colors = try addLayer(session, "Colors", try image(width: 64, height: 32) {
            $0.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            $0.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            $0.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            $0.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            // A green blot to fill away.
            $0.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
            $0.fill(CGRect(x: 12, y: 12, width: 6, height: 6))
        })
        let before = session.history.undoCount
        let none = try await MCPTestSupport.call("content_aware_fill", ["layer": "Colors"], in: workspace, expectError: "precondition_failed")
        #expect(guardName(none) == "can_content_aware_fill")
        #expect(session.history.undoCount == before)

        try await MCPTestSupport.call("select_rect", ["rect": ["x": 10, "y": 10, "width": 10, "height": 10]], in: workspace)
        try await MCPTestSupport.call("content_aware_fill", ["layer": "Colors"], in: workspace)
        let filled = try pixel(try await render(session), x: 15, y: 15)
        #expect(filled[1] < 60 && filled[0] > 150, "\(filled)")
        #expect(session.history.undoName == "Content-Aware Fill")
        #expect(nothingOpen(session))

        // A fill with nothing left to copy from fails after "Colors" became active, and puts the user's layers back.
        try await MCPTestSupport.call("select_all", in: workspace)
        session.selectLayers([blank, colors], primary: blank)
        let count = session.history.undoCount
        let failed = try await MCPTestSupport.call("content_aware_fill", ["layer": "Colors"], in: workspace, expectError: "precondition_failed")
        #expect(guardName(failed) == "filter_failed")
        #expect(session.activeLayerID == blank && session.selectedLayerIDs == [blank, colors])
        #expect(session.history.undoCount == count)
        #expect(nothingOpen(session))
    }

    @Test func removeBackgroundValidatesItsSettings() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        try addLayer(session, "Photo", try solid(width: 32, height: 32, red: 0.2, green: 0.4, blue: 0.6))
        let before = session.history.undoCount
        let invalid: [(Comment, [String: Value])] = [
            ("refine_edges 41", ["refine_edges": 41]),
            ("matte_contrast -1", ["matte_contrast": -1]),
            ("shift_edge 11", ["shift_edge": 11]),
            ("an unknown quality", ["quality": "ultra"]),
        ]
        for (situation, arguments) in invalid {
            var arguments = arguments
            arguments["layer"] = "Photo"
            try await MCPTestSupport.call("remove_background", arguments, in: workspace, expectError: "invalid_argument")
            #expect(session.history.undoCount == before, situation)
        }
        let blank = try await MCPTestSupport.call("remove_background", ["layer": "Layer 1"], in: workspace, expectError: "precondition_failed")
        #expect(guardName(blank) == "has_pixels")
        #expect(nothingOpen(session))
    }

    // MARK: Guards

    @Test func filtersAreRefusedOnLayersTheyCantChange() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        let blank = try #require(session.activeLayerID)
        let photo = try addLayer(session, "Photo", try solid(width: 32, height: 32, red: 1, green: 0, blue: 0))
        let photoIndex = try index(session, photo)
        session.selectLayer(blank)

        func expectRefusal(_ tool: String, _ arguments: [String: Value], _ expected: String, _ situation: Comment) async throws {
            let before = session.history.undoCount
            let result = try await MCPTestSupport.call(tool, arguments, in: workspace, expectError: "precondition_failed")
            #expect(guardName(result) == expected, situation)
            #expect(session.activeLayerID == blank, situation)
            #expect(session.history.undoCount == before && nothingOpen(session), situation)
        }
        let blur: [String: Value] = ["layer": "Photo", "kind": "gaussian_blur", "settings": ["radius": 2]]

        session.document?.layers[photoIndex].locks = [.pixels]
        try await expectRefusal("apply_filter", blur, "layer_locked", "pixels locked")
        try await expectRefusal("apply_levels", ["layer": "Photo", "settings": ["black": 20]], "layer_locked", "pixels locked")
        // Remove Background masks the layer instead, so only Lock All holds it (as in the app and Photoshop).
        session.document?.layers[photoIndex].locks = [.all]
        try await expectRefusal("remove_background", ["layer": "Photo"], "layer_locked", "all locked")
        session.document?.layers[photoIndex].locks = []

        session.document?.layers[photoIndex].isVisible = false
        try await expectRefusal("apply_hue_saturation", ["layer": "Photo", "settings": ["hue": 20]], "can_adjust_colors", "hidden")
        session.document?.layers[photoIndex].isVisible = true

        // A placeholder as import keeps one, hidden and without pixels, is named before either.
        let photoLayer = try #require(session.document?.layers[photoIndex])
        session.document?.layers[photoIndex].psdExtras = PSDLayerExtras(importedVisible: true, placeholder: "adjustment:brit")
        session.document?.layers[photoIndex].isVisible = false
        session.document?.layers[photoIndex].asset = nil
        try await expectRefusal("apply_filter", blur, "placeholder", "a Photoshop placeholder")
        try await expectRefusal("apply_levels", ["layer": "Photo", "settings": ["black": 20]], "placeholder", "a Photoshop placeholder")
        session.document?.layers[photoIndex] = photoLayer

        try await expectRefusal("apply_filter", ["layer": "Layer 1", "kind": "gaussian_blur"], "has_pixels", "a blank layer")
        try await MCPTestSupport.call("add_adjustment_layer", ["kind": "invert"], in: workspace)
        session.selectLayer(blank)
        let adjustment = try #require(session.document?.layers.first { $0.adjustment != nil }?.id)
        try await expectRefusal("apply_levels", ["layer": .string(adjustment.uuidString), "settings": ["black": 20]], "has_pixels",
                                "an adjustment layer")
    }
}
