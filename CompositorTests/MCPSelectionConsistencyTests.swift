import CoreGraphics
import Foundation
import Testing
import MCP
@testable import Compositor

/// Selections as the tools report and make them: one shape everywhere (`{exists: false}` without one), a mask loads
/// its white (revealed) areas as Photoshop's Cmd-click does, Select Subject that finds nothing says so without a beep,
/// an outline too long to return is cut off and flagged, and a polygon with no area is refused.
@MainActor struct MCPSelectionConsistencyTests {
    private func error(_ result: [String: Value]) -> [String: Value] { result["error"]?.objectValue ?? [:] }

    private func point(_ x: Double, _ y: Double) -> Value { ["x": .double(x), "y": .double(y)] }

    /// A one-byte gray image, black where `black` says.
    private func gray(width: Int, height: Int, black: (Int, Int) -> Bool) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width { bytes[y * width + x] = black(x, y) ? 0 : 255 }
        }
        return try #require(context.makeImage())
    }

    private func solid(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// A 16 × 16 layer at the origin whose mask is black on its left half and white on its right.
    private func maskedLayer(_ session: EditorSession) throws -> UUID {
        let image = try solid(width: 16, height: 16)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Photo"), centeredAt: CGPoint(x: 8, y: 8))
        let id = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        let mask = try gray(width: 16, height: 16) { x, _ in x < 8 }
        session.document?.layers[index].mask = LayerMask(asset: try LayerMask.asset(from: mask))
        return id
    }

    // MARK: Mask polarity

    @Test func aMaskLoadsItsWhiteAreasAsPhotoshopsCommandClickDoes() async throws {
        let workspace = MCPTestSupport.workspace(width: 16, height: 16)
        let session = workspace.current.session
        let id = try maskedLayer(session)

        let loaded = try await MCPTestSupport.call("load_layer_selection", ["layer": "Photo", "source": "mask"], in: workspace)
        let bounds = try #require(loaded["selection"]?.objectValue?["bounds"].flatMap(MCPValues.rect(from:)))
        #expect(bounds == CGRect(x: 8, y: 0, width: 8, height: 16))

        // The app's own command is unchanged: its black areas.
        session.deselect()
        session.loadMaskSelection(layerID: id)
        #expect(session.selection?.path.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 8, height: 16))

        // A mask with nothing white has nothing to select.
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].mask = LayerMask(asset: try LayerMask.asset(from: try gray(width: 16, height: 16) { _, _ in true }))
        let none = try await MCPTestSupport.call("load_layer_selection", ["layer": "Photo", "source": "mask"], in: workspace,
                                                 expectError: "precondition_failed")
        #expect(error(none)["guard"]?.stringValue == "mask_white_areas")
        #expect(error(none)["hint"]?.stringValue?.isEmpty == false)
    }

    // MARK: Select Subject

    @Test func selectSubjectThatFindsNothingSaysSo() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 64)
        let session = workspace.current.session
        let revision = session.history.revisionID
        let result = try await MCPTestSupport.call("select_subject", in: workspace)
        #expect(result["found"] == .bool(false), "\(result)")
        #expect(result["undo"]?.objectValue?["recorded"] == .bool(false))
        #expect(result["selection"] == .object(["exists": .bool(false)]))
        #expect(session.selection == nil && session.history.revisionID == revision)
        #expect(session.brushError == nil)
    }

    // MARK: One shape

    @Test func everyToolReportsTheSelectionInOneShape() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 64)
        let none: Value = .object(["exists": .bool(false)])

        var got = try await MCPTestSupport.call("get_selection", in: workspace)
        got["ok"] = nil
        #expect(Value.object(got) == none)
        var document = try await MCPTestSupport.call("get_document", in: workspace)
        #expect(document["document"]?.objectValue?["selection"] == none)
        let cleared = try await MCPTestSupport.call("select_none", in: workspace)
        #expect(cleared["selection"] == none)

        let made = try await MCPTestSupport.call("select_ellipse", ["rect": ["x": 1.25, "y": 2.5, "width": 20.125, "height": 10]],
                                                 in: workspace)
        got = try await MCPTestSupport.call("get_selection", in: workspace)
        got["ok"] = nil
        document = try await MCPTestSupport.call("get_document", in: workspace)
        #expect(made["selection"] == .object(got))
        #expect(document["document"]?.objectValue?["selection"] == .object(got))
        #expect(got["exists"] == .bool(true) && got["empty"] == .bool(false))
    }

    // MARK: Long outlines

    @Test func aVeryLongOutlineIsCutOffAndFlagged() async throws {
        let workspace = MCPTestSupport.workspace(width: 1000, height: 1000)
        let session = workspace.current.session
        let outline = CGMutablePath()
        for index in 0..<40_000 {
            outline.addRect(CGRect(x: Double(index % 200) * 5 + 0.123, y: Double(index / 200) * 5 + 0.456, width: 2.5, height: 2.5))
        }
        session.document?.selection = DocumentSelection(path: outline)
        let long = try await MCPTestSupport.call("get_selection", ["include_path": true], in: workspace)
        let path = try #require(long["path"]?.stringValue)
        #expect(long["path_truncated"] == .bool(true))
        #expect(path.utf8.count <= 256 * 1024 && path.utf8.count > 200 * 1024)
        // It ends on a whole outline, so what is there still parses.
        #expect(path.hasSuffix("Z"))

        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 4, height: 4), transform: nil))
        let short = try await MCPTestSupport.call("get_selection", ["include_path": true], in: workspace)
        #expect(short["path_truncated"] == .bool(false))
        #expect(short["path"]?.stringValue == "M0 0 L4 0 L4 4 L0 4 Z")
    }

    /// One outline longer than the cap on its own keeps its leading commands, up to the first that doesn't fit: a
    /// prefix of the whole path, never a later, shorter command after one it skipped.
    @Test func oneOutlineTooLongOnItsOwnIsCutToAPrefix() async throws {
        let small = CGMutablePath()
        small.move(to: .zero)
        small.addLine(to: CGPoint(x: 1000.5, y: 1000.5))
        small.addLine(to: CGPoint(x: 1, y: 1))
        small.closeSubpath()
        #expect(MCPValues.svgPath(small) == "M0 0 L1000.5 1000.5 L1 1 Z")
        let cut = MCPValues.svgPath(small, limit: 10)
        #expect(cut.0 == "M0 0" && cut.truncated)

        // Through get_selection: one traced outline (a star of 60,000 points) far past 256 KiB.
        let workspace = MCPTestSupport.workspace(width: 1000, height: 1000)
        let session = workspace.current.session
        let outline = CGMutablePath()
        let points = 60_000
        for index in 0..<points {
            let angle = Double(index) / Double(points) * 2 * .pi, radius = index % 2 == 0 ? 400.0 : 390.25
            let point = CGPoint(x: 500 + radius * cos(angle), y: 500 + radius * sin(angle))
            index == 0 ? outline.move(to: point) : outline.addLine(to: point)
        }
        outline.closeSubpath()
        session.document?.selection = DocumentSelection(path: outline)
        let result = try await MCPTestSupport.call("get_selection", ["include_path": true], in: workspace)
        let path = try #require(result["path"]?.stringValue)
        #expect(result["path_truncated"] == .bool(true))
        #expect(path.utf8.count <= 256 * 1024 && path.utf8.count > 250 * 1024)
        #expect(MCPValues.svgPath(outline).hasPrefix(path + " "))
    }

    // MARK: Polygons

    @Test func aPolygonThatEnclosesNoAreaIsRefused() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 64)
        let session = workspace.current.session
        let undoCount = session.history.undoCount
        for points: [Value] in [[point(0, 0), point(10, 10), point(20, 20)], [point(5, 5), point(5, 5), point(30, 40), point(55, 75)]] {
            try await MCPTestSupport.call("select_polygon", ["points": .array(points)], in: workspace, expectError: "invalid_argument")
        }
        #expect(session.selection == nil && session.history.undoCount == undoCount)
        // A bow tie crosses itself but still encloses area.
        try await MCPTestSupport.call("select_polygon", ["points": [point(0, 0), point(20, 20), point(20, 0), point(0, 20)]], in: workspace)
        #expect(session.selection?.isEmpty == false)
    }
}
