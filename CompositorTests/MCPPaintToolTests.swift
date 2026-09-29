import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import MCP
@testable import Compositor

/// The pixel and painting tools: fills, clears and inverts of a layer's pixels or mask, headless brush strokes and
/// gradients, reading and replacing a layer's raster, pasting an image into a layer, and the pixel clipboard. Each edit
/// is one undo step named as the app names it, and a refused call leaves the user's layer selection as it was.
@MainActor struct MCPPaintToolTests {
    // MARK: Helpers

    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// An image drawn with a top-left origin, as documents are.
    private func image(width: Int, height: Int, _ draw: (CGContext) -> Void = { _ in }) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(context)
        return try #require(context.makeImage())
    }

    /// An image filled with one color.
    private func solid(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        try image(width: width, height: height) {
            $0.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            $0.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// A canvas-sized image: red left of `split`, blue from it on.
    private func twoColor(width: Int = 64, height: Int = 32, split: Int = 32) throws -> CGImage {
        try image(width: width, height: height) {
            $0.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            $0.fill(CGRect(x: 0, y: 0, width: width, height: height))
            $0.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            $0.fill(CGRect(x: 0, y: 0, width: split, height: height))
        }
    }

    /// Adds `image` as a layer named `name`, centered on the canvas, and returns its id.
    @discardableResult
    private func addLayer(_ session: EditorSession, _ name: String, _ image: CGImage) throws -> UUID {
        session.insert(ImportedImage(image: image, thumbnail: image, name: name))
        return try #require(session.activeLayerID)
    }

    private func layer(_ session: EditorSession, _ id: UUID) -> ImageLayer? { session.document?.layers.first { $0.id == id } }

    private func index(_ session: EditorSession, _ id: UUID) throws -> Int {
        try #require(session.document?.layers.firstIndex { $0.id == id })
    }

    /// Gives the layer a plain mask, all white (`revealing`) or all black.
    private func addMask(_ session: EditorSession, to id: UUID, revealing: Bool = true) {
        session.selectLayer(id)
        session.addLayerMask(revealing: revealing)
    }

    /// One pixel as premultiplied 0–255 RGBA (straight, for opaque pixels).
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

    /// The decoded image of a result's first content block.
    private func decodedImage(_ result: CallTool.Result) throws -> CGImage {
        guard case .image(let base64, let mimeType, _, _) = try #require(result.content.first) else {
            Issue.record("The first content block is not an image: \(result.content)")
            throw CancellationError()
        }
        #expect(mimeType == "image/png")
        let data = try #require(Data(base64Encoded: base64))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func decodedFile(_ url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// `image` written as a PNG to a scratch file.
    private func png(_ image: CGImage, named name: String) throws -> URL {
        let url = MCPTestSupport.tempFile(name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func recorded(_ result: [String: Value]) -> Bool? { result["undo"]?.objectValue?["recorded"]?.boolValue }

    private func guardName(_ result: [String: Value]) -> String? { result["error"]?.objectValue?["guard"]?.stringValue }

    private func point(_ x: Double, _ y: Double) -> Value { ["x": .double(x), "y": .double(y)] }

    // MARK: stroke_path

    @Test func strokePathPaintsOpaquePixelsAlongTheLineAsOneBrushStroke() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        let target = try #require(session.activeLayerID)
        let before = session.history.undoCount
        let result = try await MCPTestSupport.call("stroke_path", [
            "layer": "Layer 1",
            "points": [point(4, 16), point(60, 16)],
            "brush": ["diameter": 8, "color": "#ff0000"],
        ], in: workspace)
        var rendered = try await render(session)
        #expect(try pixel(rendered, x: 10, y: 16) == [255, 0, 0, 255])
        #expect(try pixel(rendered, x: 32, y: 16) == [255, 0, 0, 255])
        #expect(try pixel(rendered, x: 32, y: 4)[3] == 0)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Brush Stroke")
        #expect(recorded(result) == true)
        #expect(result["layer_id"]?.stringValue == target.uuidString)

        // Without a color the brush paints the foreground color.
        session.foregroundColor = PaletteColor(red: 0, green: 0, blue: 1)
        try await MCPTestSupport.call("stroke_path", ["layer": "Layer 1", "points": [point(4, 27), point(60, 27)],
                                                      "brush": ["diameter": 6]], in: workspace)
        rendered = try await render(session)
        #expect(try pixel(rendered, x: 32, y: 27) == [0, 0, 255, 255])
        #expect(session.history.undoCount == before + 2)
    }

    @Test func eraseClearsAlongTheLine() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        try await MCPTestSupport.call("fill_selection", ["layer": "Layer 1", "color": "#ff0000"], in: workspace)
        let before = session.history.undoCount
        try await MCPTestSupport.call("stroke_path", ["layer": "Layer 1", "mode": "erase",
                                                      "points": [point(4, 16), point(60, 16)], "brush": ["diameter": 8]],
                                      in: workspace)
        let rendered = try await render(session)
        #expect(try pixel(rendered, x: 32, y: 16)[3] == 0)
        #expect(try pixel(rendered, x: 32, y: 4) == [255, 0, 0, 255])
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Erase")
    }

    @Test func strokingAMaskPaintsTheMaskInItsPalette() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        let id = try addLayer(session, "Red", try solid(width: 64, height: 32, red: 1, green: 0, blue: 0))
        addMask(session, to: id)
        session.isMaskSelected = false
        let before = session.history.undoCount
        // A mask paints black by default, which hides.
        try await MCPTestSupport.call("stroke_path", ["layer": "Red", "target": "mask", "points": [point(4, 16), point(60, 16)],
                                                      "brush": ["diameter": 8]], in: workspace)
        let rendered = try await render(session)
        #expect(try pixel(rendered, x: 32, y: 16)[3] == 0)
        #expect(try pixel(rendered, x: 32, y: 4) == [255, 0, 0, 255])
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Paint Mask")
        #expect(session.activeLayerID == id && session.isMaskSelected)
        #expect(layer(session, id)?.asset?.image.width == 64)
    }

    @Test func cloneBlurAndLiquifyStrokes() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        try addLayer(session, "Colors", try twoColor())

        // Clone Stamp: the first point copies from the source, and the rest keep that offset.
        try await MCPTestSupport.call("stroke_path", [
            "layer": "Colors", "mode": "clone", "clone": ["source": point(8, 16)],
            "points": [point(48, 16), point(56, 16)], "brush": ["diameter": 6],
        ], in: workspace)
        var rendered = try await render(session)
        #expect(try pixel(rendered, x: 52, y: 16) == [255, 0, 0, 255])
        #expect(try pixel(rendered, x: 52, y: 4) == [0, 0, 255, 255])
        #expect(session.history.undoName == "Clone Stamp")

        // Blur softens the red/blue edge under the brush.
        try await MCPTestSupport.call("stroke_path", ["layer": "Colors", "mode": "blur", "points": [point(32, 6), point(32, 12)],
                                                      "brush": ["diameter": 20]], in: workspace)
        rendered = try await render(session)
        let blurred = try pixel(rendered, x: 31, y: 9)
        #expect(blurred[0] > 0 && blurred[2] > 0, "\(blurred)")
        #expect(session.history.undoName == "Blur")

        // Liquify pushes the red across the edge.
        try await MCPTestSupport.call("stroke_path", ["layer": "Colors", "mode": "liquify", "points": [point(22, 26), point(40, 26)],
                                                      "brush": ["diameter": 12]], in: workspace)
        rendered = try await render(session)
        let pushed = try pixel(rendered, x: 34, y: 26)
        #expect(pushed[0] > 0, "\(pushed)")
        #expect(session.history.undoName == "Liquify")
    }

    @Test func healAndSmudgeStrokes() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        try addLayer(session, "Spot", try image(width: 64, height: 32) {
            $0.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            $0.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            $0.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            $0.fill(CGRect(x: 14, y: 14, width: 4, height: 4))
        })
        // Spot Healing rebuilds the blue spot from the red around it.
        try await MCPTestSupport.call("stroke_path", ["layer": "Spot", "mode": "heal", "heal_mode": "proximity_match",
                                                      "points": [point(16, 16)], "brush": ["diameter": 12]], in: workspace)
        var rendered = try await render(session)
        let healed = try pixel(rendered, x: 15, y: 15)
        #expect(healed[0] > 200 && healed[2] < 60, "\(healed)")
        #expect(session.history.undoName == "Spot Healing")

        // Smudge drags the red into the blue half.
        try addLayer(session, "Colors", try twoColor())
        try await MCPTestSupport.call("stroke_path", ["layer": "Colors", "mode": "smudge", "points": [point(24, 16), point(40, 16)],
                                                      "brush": ["diameter": 12]], in: workspace)
        rendered = try await render(session)
        let smudged = try pixel(rendered, x: 34, y: 16)
        #expect(smudged[0] > 0, "\(smudged)")
        #expect(session.history.undoName == "Smudge")
    }

    @Test func invalidStrokesFailWithoutAnEdit() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        let before = session.history.undoCount
        let line: Value = [point(4, 16), point(60, 16)]
        let cases: [(Comment, [String: Value])] = [
            ("no points", ["points": []]),
            ("too many points", ["points": .array(Array(repeating: point(1, 1), count: 10_001))]),
            ("a point without y", ["points": [["x": 1]]]),
            ("diameter 0", ["points": line, "brush": ["diameter": 0]]),
            ("diameter 2001", ["points": line, "brush": ["diameter": 2001]]),
            ("hardness 1.5", ["points": line, "brush": ["hardness": 1.5]]),
            ("opacity 0", ["points": line, "brush": ["opacity": 0]]),
            ("an unknown brush key", ["points": line, "brush": ["size": 10]]),
            ("a bad color", ["points": line, "brush": ["color": "red"]]),
            ("an unknown mode", ["points": line, "mode": "spray"]),
            ("clone without a source", ["points": line, "mode": "clone"]),
            ("heal on a mask", ["points": line, "mode": "heal", "target": "mask"]),
            ("erase on a mask", ["points": line, "mode": "erase", "target": "mask"]),
            ("smudge on a mask", ["points": line, "mode": "smudge", "target": "mask"]),
            ("an unknown heal mode", ["points": line, "mode": "heal", "heal_mode": "magic"]),
            ("an unknown target", ["points": line, "target": "alpha"]),
        ]
        for (situation, arguments) in cases {
            var arguments = arguments
            arguments["layer"] = "Layer 1"
            try await MCPTestSupport.call("stroke_path", arguments, in: workspace, expectError: "invalid_argument")
            #expect(session.history.undoCount == before, situation)
        }
    }

    // MARK: fill_selection, clear_selection

    @Test func fillSelectionFillsTheSelectionWithAColorAndRecolorsLiveText() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        try await MCPTestSupport.call("select_rect", ["rect": ["x": 0, "y": 0, "width": 32, "height": 32]], in: workspace)
        let before = session.history.undoCount
        let filled = try await MCPTestSupport.call("fill_selection", ["layer": "Layer 1", "with": "color", "color": "#00ff00"],
                                                   in: workspace)
        var rendered = try await render(session)
        #expect(try pixel(rendered, x: 10, y: 10) == [0, 255, 0, 255])
        #expect(try pixel(rendered, x: 50, y: 10)[3] == 0)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Fill")
        #expect(recorded(filled) == true)

        // A color alone implies with: color; foreground and background are the palette's.
        try await MCPTestSupport.call("fill_selection", ["layer": "Layer 1", "color": ["r": 0, "g": 0, "b": 1]], in: workspace)
        rendered = try await render(session)
        #expect(try pixel(rendered, x: 10, y: 10) == [0, 0, 255, 255])
        session.foregroundColor = PaletteColor(red: 1, green: 1, blue: 0)
        try await MCPTestSupport.call("fill_selection", ["layer": "Layer 1", "with": "foreground"], in: workspace)
        rendered = try await render(session)
        #expect(try pixel(rendered, x: 10, y: 10) == [255, 255, 0, 255])
        try await MCPTestSupport.call("fill_selection", ["layer": "Layer 1", "with": "background"], in: workspace)
        rendered = try await render(session)
        #expect(try pixel(rendered, x: 10, y: 10) == [255, 255, 255, 255])
        #expect(session.history.undoCount == before + 4)

        let count = session.history.undoCount
        try await MCPTestSupport.call("fill_selection", ["layer": "Layer 1", "with": "background", "color": "#ff0000"],
                                      in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("fill_selection", ["layer": "Layer 1", "with": "color"], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("fill_selection", ["layer": "Layer 1", "with": "pattern"], in: workspace, expectError: "invalid_argument")
        #expect(session.history.undoCount == count)

        // A live text layer takes the color as its own and stays text.
        try await MCPTestSupport.call("select_none", in: workspace)
        session.beginText(at: CGPoint(x: 4, y: 4), newLayer: true)
        var draft = try #require(session.textDraft)
        draft.style.content = "Hi"
        draft.style.fontSize = 12
        #expect(session.applyText(draft))
        let text = try #require(session.activeLayerID)
        try await MCPTestSupport.call("fill_selection", ["layer": .string(text.uuidString), "color": "#ff0000"], in: workspace)
        let style = try #require(layer(session, text)?.liveText?.style)
        #expect(style.red == 1 && style.green == 0 && style.blue == 0)
        #expect(session.history.undoName == "Fill Text")
    }

    @Test func fillAndClearWorkOnPixelsAndMasks() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        let id = try #require(session.activeLayerID)
        try await MCPTestSupport.call("fill_selection", ["layer": "Layer 1", "color": "#ff0000"], in: workspace)
        try await MCPTestSupport.call("select_rect", ["rect": ["x": 0, "y": 0, "width": 32, "height": 32]], in: workspace)
        try await MCPTestSupport.call("clear_selection", ["layer": "Layer 1"], in: workspace)
        var rendered = try await render(session)
        #expect(try pixel(rendered, x: 10, y: 10)[3] == 0)
        #expect(try pixel(rendered, x: 50, y: 10) == [255, 0, 0, 255])
        #expect(session.history.undoName == "Clear")

        // The mask: black hides, and clearing it fills with the mask's background, white, which reveals.
        addMask(session, to: id)
        try await MCPTestSupport.call("select_rect", ["rect": ["x": 32, "y": 0, "width": 32, "height": 32]], in: workspace)
        try await MCPTestSupport.call("fill_selection", ["layer": "Layer 1", "target": "mask", "color": "#000000"], in: workspace)
        rendered = try await render(session)
        #expect(try pixel(rendered, x: 50, y: 10)[3] == 0)
        #expect(session.history.undoName == "Fill Mask")
        try await MCPTestSupport.call("clear_selection", ["layer": "Layer 1", "target": "mask"], in: workspace)
        rendered = try await render(session)
        #expect(try pixel(rendered, x: 50, y: 10) == [255, 0, 0, 255])
        #expect(session.history.undoName == "Fill Mask")

        try await MCPTestSupport.call("select_none", in: workspace)
        let before = session.history.undoCount
        let cleared = try await MCPTestSupport.call("clear_selection", ["layer": "Layer 1"], in: workspace,
                                                    expectError: "precondition_failed")
        #expect(guardName(cleared) == "selection")
        #expect(session.history.undoCount == before)
    }

    // MARK: invert_pixels

    @Test func invertPixelsInvertsColorsOrTheMask() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        let id = try addLayer(session, "Colors", try twoColor())
        try await MCPTestSupport.call("invert_pixels", ["layer": "Colors"], in: workspace)
        var rendered = try await render(session)
        #expect(try pixel(rendered, x: 10, y: 10) == [0, 255, 255, 255])
        #expect(try pixel(rendered, x: 50, y: 10) == [255, 255, 0, 255])
        #expect(session.history.undoName == "Invert")

        try await MCPTestSupport.call("select_rect", ["rect": ["x": 0, "y": 0, "width": 32, "height": 32]], in: workspace)
        try await MCPTestSupport.call("invert_pixels", ["layer": "Colors"], in: workspace)
        rendered = try await render(session)
        #expect(try pixel(rendered, x: 10, y: 10) == [255, 0, 0, 255])
        #expect(try pixel(rendered, x: 50, y: 10) == [255, 255, 0, 255])

        addMask(session, to: id)
        try await MCPTestSupport.call("invert_pixels", ["layer": "Colors", "target": "mask"], in: workspace)
        rendered = try await render(session)
        #expect(try pixel(rendered, x: 10, y: 10)[3] == 0)
        #expect(try pixel(rendered, x: 50, y: 10) == [255, 255, 0, 255])
        #expect(session.history.undoName == "Invert Mask")

        let before = session.history.undoCount
        let blank = try await MCPTestSupport.call("invert_pixels", ["layer": "Layer 1"], in: workspace, expectError: "precondition_failed")
        #expect(guardName(blank) == "has_pixels")
        #expect(session.history.undoCount == before)
    }

    // MARK: draw_gradient

    @Test func drawGradientBlendsBetweenItsEnds() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        let base = try #require(session.activeLayerID)
        let before = session.history.undoCount
        try await MCPTestSupport.call("draw_gradient", ["layer": "Layer 1", "start": point(0, 16), "end": point(64, 16),
                                                        "colors": ["from": "#0000ff", "to": "transparent"]], in: workspace)
        var rendered = try await render(session)
        let start = try pixel(rendered, x: 1, y: 16), end = try pixel(rendered, x: 62, y: 16)
        #expect(start[3] >= 245 && start[2] >= 245 && start[0] == 0, "\(start)")
        #expect(end[3] <= 10, "\(end)")
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Gradient")

        // The palette styles, reversed, on a second layer.
        try await MCPTestSupport.call("add_blank_layer", ["name": "B"], in: workspace)
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        session.backgroundColor = .white
        try await MCPTestSupport.call("draw_gradient", ["layer": "B", "start": point(0, 16), "end": point(64, 16),
                                                        "style": "foreground_to_background", "reversed": true], in: workspace)
        rendered = try await render(session)
        let white = try pixel(rendered, x: 1, y: 16), red = try pixel(rendered, x: 62, y: 16)
        #expect(white.allSatisfy { $0 >= 245 }, "\(white)")
        #expect(red[0] >= 250 && red[1] <= 10 && red[3] == 255, "\(red)")

        // Radial runs from the start out to the end's distance.
        try await MCPTestSupport.call("draw_gradient", ["layer": "B", "shape": "radial", "start": point(32, 16), "end": point(44, 16),
                                                        "colors": ["from": "#000000", "to": "#ffffff"]], in: workspace)
        rendered = try await render(session)
        #expect(try pixel(rendered, x: 32, y: 16).prefix(3).allSatisfy { $0 <= 20 })
        #expect(try pixel(rendered, x: 60, y: 16) == [255, 255, 255, 255])

        // On a mask, black to white hides the left and reveals the right.
        let baseIndex = try index(session, base)
        session.document?.layers[baseIndex].isVisible = false
        let b = try #require(session.document?.layers.first { $0.name == "B" }?.id)
        addMask(session, to: b)
        try await MCPTestSupport.call("draw_gradient", ["layer": "B", "target": "mask", "start": point(0, 16), "end": point(64, 16),
                                                        "colors": ["from": "#000000", "to": "#ffffff"]], in: workspace)
        rendered = try await render(session)
        #expect(try pixel(rendered, x: 1, y: 16)[3] <= 10)
        #expect(try pixel(rendered, x: 62, y: 16)[3] >= 245)
        #expect(session.history.undoName == "Gradient Mask")

        let count = session.history.undoCount
        let invalid: [(Comment, [String: Value])] = [
            ("no line", ["start": point(10, 10), "end": point(10, 10)]),
            ("colors and style", ["start": point(0, 0), "end": point(10, 0), "style": "foreground_to_background",
                                  "colors": ["from": "#000000", "to": "#ffffff"]]),
            ("opacity 0", ["start": point(0, 0), "end": point(10, 0), "opacity": 0]),
            ("a bad color", ["start": point(0, 0), "end": point(10, 0), "colors": ["from": "#12", "to": "transparent"]]),
            ("a missing end color", ["start": point(0, 0), "end": point(10, 0), "colors": ["from": "#000000"]]),
            ("an unknown shape", ["start": point(0, 0), "end": point(10, 0), "shape": "diamond"]),
            ("an unknown style", ["start": point(0, 0), "end": point(10, 0), "style": "rainbow"]),
            ("no end", ["start": point(0, 0)]),
        ]
        for (situation, arguments) in invalid {
            var arguments = arguments
            arguments["layer"] = "B"
            try await MCPTestSupport.call("draw_gradient", arguments, in: workspace, expectError: "invalid_argument")
            #expect(session.history.undoCount == count, situation)
        }
    }

    // MARK: get_layer_pixels

    @Test func getLayerPixelsReturnsTheLayersOwnRaster() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        let id = try addLayer(session, "Chip", try solid(width: 20, height: 10, red: 1, green: 0, blue: 0))
        #expect(layer(session, id)?.transform.origin == CGPoint(x: 22, y: 11))

        let raw = await MCPToolRegistry.call("get_layer_pixels", ["layer": "Chip"], workspace: workspace)
        #expect(raw.isError != true)
        let fields = try #require(raw.structuredContent?.objectValue)
        let returned = try decodedImage(raw)
        #expect(returned.width == 20 && returned.height == 10)
        #expect(try pixel(returned, x: 5, y: 5) == [255, 0, 0, 255])
        #expect(fields["pixel_width"] == .int(20) && fields["pixel_height"] == .int(10))
        #expect(fields["width"] == .int(20) && fields["scale"] == .double(1) && fields["target"] == .string("pixels"))
        #expect(fields["transform"]?.objectValue?["x"] == .double(22))

        let small = await MCPToolRegistry.call("get_layer_pixels", ["layer": "Chip", "max_size": 16], workspace: workspace)
        let scaled = try decodedImage(small)
        #expect(scaled.width == 16 && scaled.height == 8)

        // save_to writes the full-size raster as PNG, and never over a file without overwrite.
        let saved = try await MCPTestSupport.call("get_layer_pixels", ["layer": "Chip", "max_size": 16, "save_to": "chip-pixels.png"],
                                                  in: workspace)
        let path = try #require(saved["path"]?.stringValue)
        #expect(path.hasPrefix(MCPTestSupport.agentRootOverride.path))
        let file = try decodedFile(URL(fileURLWithPath: path))
        #expect(file.width == 20 && file.height == 10)
        let exists = try await MCPTestSupport.call("get_layer_pixels", ["layer": "Chip", "save_to": "chip-pixels.png"],
                                                   in: workspace, expectError: "io_error")
        #expect(exists["error"]?.objectValue?["details"]?.objectValue?["code"] == .string("file_exists"))
        try await MCPTestSupport.call("get_layer_pixels", ["layer": "Chip", "save_to": "chip-pixels.png", "overwrite": true],
                                      in: workspace)
        try await MCPTestSupport.call("get_layer_pixels", ["layer": "Chip", "save_to": "chip.jpg"], in: workspace,
                                      expectError: "invalid_argument")

        // The mask as gray.
        let noMask = try await MCPTestSupport.call("get_layer_pixels", ["layer": "Chip", "target": "mask"], in: workspace,
                                                   expectError: "precondition_failed")
        #expect(guardName(noMask) == "has_mask")
        addMask(session, to: id, revealing: false)
        let maskResult = await MCPToolRegistry.call("get_layer_pixels", ["layer": "Chip", "target": "mask"], workspace: workspace)
        let mask = try decodedImage(maskResult)
        #expect(mask.width == 1 && mask.height == 1)
        #expect(try pixel(mask, x: 0, y: 0) == [0, 0, 0, 255])
        #expect(maskResult.structuredContent?.objectValue?["target"] == .string("mask"))

        let blank = try await MCPTestSupport.call("get_layer_pixels", ["layer": "Layer 1"], in: workspace, expectError: "precondition_failed")
        #expect(guardName(blank) == "has_pixels")
    }

    // MARK: set_layer_pixels

    @Test func setLayerPixelsReplacesTheRasterByPlacement() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        let id = try addLayer(session, "Chip", try solid(width: 20, height: 10, red: 1, green: 0, blue: 0))
        let file = try png(try solid(width: 10, height: 10, red: 0, green: 0, blue: 1), named: "blue.png")
        let before = session.history.undoCount

        let kept = try await MCPTestSupport.call("set_layer_pixels", ["layer": "Chip", "path": .string(file.path)], in: workspace)
        #expect(layer(session, id)?.transform == LayerTransform(origin: CGPoint(x: 22, y: 11), size: CGSize(width: 20, height: 10)))
        #expect(layer(session, id)?.asset?.image.width == 10)
        var rendered = try await render(session)
        #expect(try pixel(rendered, x: 40, y: 15) == [0, 0, 255, 255])
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Replace Pixels")
        #expect(kept["pixel_width"] == .int(10))

        // keep_origin: its own size from the same top-left; the layer's mask stays where it was on the document.
        // A mask from a selection hides the selected right half of the layer's box, x 32–42.
        try await MCPTestSupport.call("select_rect", ["rect": ["x": 32, "y": 11, "width": 10, "height": 10]], in: workspace)
        session.selectLayer(id)
        session.addMask(revealing: true)
        #expect(layer(session, id)?.mask?.placement == nil && layer(session, id)?.mask?.asset.image.width == 10)
        try await MCPTestSupport.call("set_layer_pixels", ["layer": "Chip", "path": .string(file.path), "placement": "keep_origin"],
                                      in: workspace)
        #expect(layer(session, id)?.transform == LayerTransform(origin: CGPoint(x: 22, y: 11), size: CGSize(width: 10, height: 10)))
        #expect(layer(session, id)?.mask?.placement == LayerTransform(origin: CGPoint(x: 22, y: 11), size: CGSize(width: 20, height: 10)))
        // Stretched over the new box instead, the mask would hide x 27–32.
        rendered = try await render(session)
        let left = try pixel(rendered, x: 25, y: 15), right = try pixel(rendered, x: 28, y: 15)
        #expect(left == [0, 0, 255, 255], "\(left)")
        #expect(right == [0, 0, 255, 255], "\(right)")

        // natural: its own size, upright, centered where the layer was.
        let chip = try index(session, id)
        session.document?.layers[chip].mask = nil
        session.document?.layers[chip].transform = LayerTransform(origin: CGPoint(x: 10, y: 6), size: CGSize(width: 30, height: 20), rotation: 45)
        try await MCPTestSupport.call("set_layer_pixels", ["layer": "Chip", "path": .string(file.path), "placement": "natural"],
                                      in: workspace)
        #expect(layer(session, id)?.transform == LayerTransform(origin: CGPoint(x: 20, y: 11), size: CGSize(width: 10, height: 10)))
        // Three replacements, plus the marquee and the mask.
        #expect(session.history.undoCount == before + 5)

        let count = session.history.undoCount
        try await MCPTestSupport.call("set_layer_pixels", ["layer": "Chip", "path": "missing.png"], in: workspace, expectError: "not_found")
        try await MCPTestSupport.call("set_layer_pixels", ["layer": "Chip", "path": .string(file.path), "placement": "stretch"],
                                      in: workspace, expectError: "invalid_argument")
        let text = MCPTestSupport.tempFile("notes.txt")
        try Data("not an image".utf8).write(to: text)
        try await MCPTestSupport.call("set_layer_pixels", ["layer": "Chip", "path": .string(text.path)], in: workspace, expectError: "io_error")
        session.selectLayer(id)
        session.groupSelectedLayers()
        let folder = try await MCPTestSupport.call("set_layer_pixels", ["layer": .string(try #require(session.activeLayerID).uuidString),
                                                                        "path": .string(file.path)],
                                                   in: workspace, expectError: "precondition_failed")
        #expect(guardName(folder) == "has_pixels")
        #expect(session.history.undoCount == count + 1)
    }

    /// keep_bounds keeps the layer's box but can change its pixel grid. A mask painted in the old grid is pinned to the
    /// box then, because strokes and pastes that grow the layer read an unpinned mask 1:1 in the layer's grid.
    @Test func setLayerPixelsKeepBoundsWithANewPixelSizePinsAMaskPaintedInTheOldGrid() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        let id = try addLayer(session, "Chip", try solid(width: 20, height: 10, red: 1, green: 0, blue: 0))
        let box = LayerTransform(origin: CGPoint(x: 22, y: 11), size: CGSize(width: 20, height: 10))
        #expect(layer(session, id)?.transform == box)
        addMask(session, to: id)
        session.isMaskSelected = false
        // Hide a band of the box, x 35–43, which gives the mask a raster in the layer's 20×10 grid.
        try await MCPTestSupport.call("stroke_path", ["layer": "Chip", "target": "mask", "points": [point(39, 4), point(39, 28)],
                                                      "brush": ["diameter": 8]], in: workspace)
        #expect(layer(session, id)?.mask?.placement == nil && layer(session, id)?.mask?.asset.image.width == 20)
        var rendered = try await render(session)
        #expect(try pixel(rendered, x: 39, y: 16)[3] == 0)

        // The same pixel size keeps the grid, so the mask keeps following the layer.
        let sameSize = try png(try solid(width: 20, height: 10, red: 1, green: 0, blue: 0), named: "same.png")
        try await MCPTestSupport.call("set_layer_pixels", ["layer": "Chip", "path": .string(sameSize.path)], in: workspace)
        #expect(layer(session, id)?.mask?.placement == nil)

        // A 10×10 image over the same 20×10 box: the mask is pinned to the box, so it still hides x 35–43.
        let blue = try png(try solid(width: 10, height: 10, red: 0, green: 0, blue: 1), named: "blue.png")
        try await MCPTestSupport.call("set_layer_pixels", ["layer": "Chip", "path": .string(blue.path), "placement": "keep_bounds"],
                                      in: workspace)
        #expect(layer(session, id)?.transform == box && layer(session, id)?.asset?.image.width == 10)
        #expect(layer(session, id)?.mask?.placement == box)
        rendered = try await render(session)
        #expect(try pixel(rendered, x: 39, y: 16)[3] == 0)
        #expect(try pixel(rendered, x: 30, y: 16) == [0, 0, 255, 255])

        // A stroke outside the box grows the layer. Read 1:1 in the 10-pixel grid, the mask would cover 40 document
        // pixels and hide x 48–62 instead of x 35–43.
        try await MCPTestSupport.call("stroke_path", ["layer": "Chip", "points": [point(4, 4), point(10, 4)],
                                                      "brush": ["diameter": 4, "color": "#00ff00"]], in: workspace)
        #expect(layer(session, id)?.transform != box)
        #expect(layer(session, id)?.mask?.placement == box)
        rendered = try await render(session)
        #expect(try pixel(rendered, x: 7, y: 4) == [0, 255, 0, 255])
        let hidden = try pixel(rendered, x: 39, y: 16), shown = try pixel(rendered, x: 30, y: 16)
        #expect(hidden[3] == 0, "\(hidden)")
        #expect(shown == [0, 0, 255, 255], "\(shown)")
    }

    // MARK: paste_image_into_layer

    @Test func pasteImageIntoLayerDrawsOverOrReplaces() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        let red = try png(try solid(width: 10, height: 10, red: 1, green: 0, blue: 0), named: "red.png")
        let clear = try png(try image(width: 10, height: 10), named: "clear.png")
        let before = session.history.undoCount
        let pasted = try await MCPTestSupport.call("paste_image_into_layer", ["layer": "Layer 1", "path": .string(red.path), "x": 5, "y": 5],
                                                   in: workspace)
        var rendered = try await render(session)
        #expect(try pixel(rendered, x: 7, y: 7) == [255, 0, 0, 255])
        #expect(try pixel(rendered, x: 20, y: 20)[3] == 0)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Paste Image")
        #expect(pasted["rect"].flatMap(MCPValues.rect(from:)) == CGRect(x: 5, y: 5, width: 10, height: 10))

        // Transparent pixels change nothing drawn over, and clear what they replace.
        try await MCPTestSupport.call("fill_selection", ["layer": "Layer 1", "color": "#0000ff"], in: workspace)
        try await MCPTestSupport.call("paste_image_into_layer", ["layer": "Layer 1", "path": .string(clear.path), "x": 40, "y": 10],
                                      in: workspace)
        rendered = try await render(session)
        #expect(try pixel(rendered, x: 45, y: 15) == [0, 0, 255, 255])
        try await MCPTestSupport.call("paste_image_into_layer", ["layer": "Layer 1", "path": .string(clear.path), "x": 40, "y": 10,
                                                                 "mode": "replace"], in: workspace)
        rendered = try await render(session)
        #expect(try pixel(rendered, x: 45, y: 15)[3] == 0)
        #expect(try pixel(rendered, x: 30, y: 15) == [0, 0, 255, 255])

        // Only inside the selection.
        try await MCPTestSupport.call("select_rect", ["rect": ["x": 0, "y": 0, "width": 8, "height": 8]], in: workspace)
        try await MCPTestSupport.call("paste_image_into_layer", ["layer": "Layer 1", "path": .string(red.path), "x": 20, "y": 0],
                                      in: workspace)
        try await MCPTestSupport.call("paste_image_into_layer", ["layer": "Layer 1", "path": .string(red.path), "x": 2, "y": 2],
                                      in: workspace)
        rendered = try await render(session)
        #expect(try pixel(rendered, x: 6, y: 6) == [255, 0, 0, 255])
        #expect(try pixel(rendered, x: 10, y: 10) == [0, 0, 255, 255])
        #expect(try pixel(rendered, x: 22, y: 2) == [0, 0, 255, 255])

        try await MCPTestSupport.call("paste_image_into_layer", ["layer": "Layer 1", "path": .string(red.path), "x": 0, "y": 0, "mode": "under"],
                                      in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("paste_image_into_layer", ["layer": "Layer 1", "path": .string(red.path), "x": 0],
                                      in: workspace, expectError: "invalid_argument")
    }

    // MARK: copy_pixels, paste_pixels

    @Test func copyPixelsThenPastePixelsMakesALayerWhereAsked() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        try addLayer(session, "Colors", try twoColor())
        try await MCPTestSupport.call("select_rect", ["rect": ["x": 0, "y": 0, "width": 16, "height": 16]], in: workspace)
        let copied = try await MCPTestSupport.call("copy_pixels", ["layer": "Colors"], in: workspace)
        #expect(copied["region"].flatMap(MCPValues.rect(from:)) == CGRect(x: 0, y: 0, width: 16, height: 16))
        let before = session.history.undoCount
        let pasted = try await MCPTestSupport.call("paste_pixels", ["x": 40, "y": 8], in: workspace)
        let id = try #require(pasted["layer_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        #expect(layer(session, id)?.transform == LayerTransform(origin: CGPoint(x: 40, y: 8), size: CGSize(width: 16, height: 16)))
        let rendered = try await render(session)
        #expect(try pixel(rendered, x: 45, y: 12) == [255, 0, 0, 255])
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Paste")

        let merged = try await MCPTestSupport.call("copy_pixels", ["merged": true], in: workspace)
        #expect(merged["merged"] == .bool(true))
        try await MCPTestSupport.call("paste_pixels", ["x": 40], in: workspace, expectError: "invalid_argument")
        try await MCPTestSupport.call("copy_pixels", ["layer": "Colors", "merged": true], in: workspace, expectError: "invalid_argument")
        let blank = try await MCPTestSupport.call("copy_pixels", ["layer": "Layer 1"], in: workspace, expectError: "precondition_failed")
        #expect(guardName(blank) == "has_pixels")
    }

    // MARK: Guards

    @Test func refusedPixelEditsLeaveTheLayerSelectionAlone() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 32)
        let session = workspace.current.session
        let blank = try #require(session.activeLayerID)
        let colors = try addLayer(session, "Colors", try twoColor())
        addMask(session, to: colors)
        let target = try addLayer(session, "Target", try solid(width: 64, height: 32, red: 0, green: 1, blue: 0))
        let targetIndex = try index(session, target)
        let effect = LayerEffectSelection(layerID: colors, kind: .shadow)

        func expectRefusal(_ tool: String, _ arguments: [String: Value], _ expected: String, _ situation: Comment) async throws {
            session.selectLayers([colors, blank], primary: colors)
            session.isMaskSelected = true
            session.effectSelection = effect
            let before = session.history.undoCount
            let result = try await MCPTestSupport.call(tool, arguments, in: workspace, expectError: "precondition_failed")
            #expect(guardName(result) == expected, situation)
            #expect(session.activeLayerID == colors && session.selectedLayerIDs == [colors, blank], situation)
            #expect(session.isMaskSelected && session.effectSelection == effect, situation)
            #expect(session.history.undoCount == before, situation)
        }
        let fill: [String: Value] = ["layer": "Target", "color": "#ff0000"]
        let stroke: [String: Value] = ["layer": "Target", "points": [point(4, 16), point(60, 16)]]

        session.document?.layers[targetIndex].locks = [.pixels]
        try await expectRefusal("fill_selection", fill, "layer_locked", "pixels locked")
        try await expectRefusal("stroke_path", stroke, "layer_locked", "pixels locked")
        try await expectRefusal("invert_pixels", ["layer": "Target"], "layer_locked", "pixels locked")
        session.document?.layers[targetIndex].locks = [.all]
        try await expectRefusal("draw_gradient", ["layer": "Target", "start": point(0, 0), "end": point(10, 0)], "layer_locked", "all locked")
        session.document?.layers[targetIndex].locks = []

        session.document?.layers[targetIndex].isVisible = false
        try await expectRefusal("fill_selection", fill, "can_paint", "hidden")
        try await expectRefusal("invert_pixels", ["layer": "Target"], "can_invert", "hidden")
        session.document?.layers[targetIndex].isVisible = true

        // A placeholder as import keeps one, hidden and without pixels, is named before either.
        let targetLayer = try #require(session.document?.layers[targetIndex])
        session.document?.layers[targetIndex].psdExtras = PSDLayerExtras(importedVisible: true, placeholder: "adjustment:brit")
        session.document?.layers[targetIndex].isVisible = false
        session.document?.layers[targetIndex].asset = nil
        try await expectRefusal("stroke_path", stroke, "placeholder", "a Photoshop placeholder")
        try await expectRefusal("invert_pixels", ["layer": "Target"], "placeholder", "a Photoshop placeholder")
        session.document?.layers[targetIndex] = targetLayer

        try await expectRefusal("fill_selection", ["layer": "Target", "target": "mask", "color": "#000000"], "has_mask", "no mask")
        session.document?.layers[targetIndex].mask = LayerMask.solid(revealing: true)
        session.document?.layers[targetIndex].mask?.isEnabled = false
        try await expectRefusal("stroke_path", stroke.merging(["target": "mask"]) { $1 }, "can_paint", "a disabled mask")
        session.document?.layers[targetIndex].mask = nil

        session.selectLayer(target)
        session.groupSelectedLayers()
        let folder = try #require(session.activeLayerID)
        try await expectRefusal("fill_selection", ["layer": .string(folder.uuidString), "color": "#ff0000"], "has_pixels", "a folder's pixels")

        try await MCPTestSupport.call("select_rect", ["rect": ["x": 10, "y": 10, "width": 10, "height": 10]], in: workspace)
        try await MCPTestSupport.call("select_rect", ["rect": ["x": 0, "y": 0, "width": 64, "height": 32], "mode": "subtract"], in: workspace)
        #expect(session.selection?.isEmpty == true)
        try await expectRefusal("fill_selection", fill, "selection", "an empty selection")
        try await expectRefusal("stroke_path", stroke, "selection", "an empty selection")
    }
}
