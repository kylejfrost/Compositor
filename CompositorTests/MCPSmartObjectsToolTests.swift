import CoreGraphics
import Foundation
import ImageIO
import MCP
import Testing
import UniformTypeIdentifiers
@testable import Compositor

/// The smart-object tools: `place_smart_object` places a file as a new smart object (at its own size, or fitted in
/// `fit_rect`) and `replace_smart_object_contents` swaps a smart object's contents, each as one undo step;
/// `get_smart_object_info` describes the contents and `export_smart_object_contents` writes them to a file.
@MainActor
@Suite(.serialized)
struct MCPSmartObjectsToolTests {
    /// Where the imported smart object places its contents, in document pixels: apart from its pixels (24 × 24 at
    /// 20, 16), as Photoshop trims them.
    private let quad = [CGPoint(x: 18, y: 14), CGPoint(x: 46, y: 14), CGPoint(x: 46, y: 42), CGPoint(x: 18, y: 42)]

    // MARK: Helpers

    private func layer(_ session: EditorSession, _ id: UUID) -> ImageLayer? {
        session.document?.layers.first { $0.id == id }
    }

    private func id(_ result: [String: Value]) throws -> UUID {
        try #require(result["layer_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
    }

    private func error(_ result: [String: Value]) -> [String: Value] {
        result["error"]?.objectValue ?? [:]
    }

    private func message(_ result: [String: Value]) -> String {
        error(result)["message"]?.stringValue ?? ""
    }

    private func corners(_ value: Value?) -> [CGPoint] {
        value?.arrayValue?.compactMap(MCPValues.point(from:)) ?? []
    }

    private func close(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0.x - $1.x) < 0.001 && abs($0.y - $1.y) < 0.001 }
    }

    /// A red PNG, saying `dpi` when given.
    private func png(width: Int, height: Int, dpi: Double? = nil) throws -> Data {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        let properties = dpi.map { [kCGImagePropertyDPIWidth: $0, kCGImagePropertyDPIHeight: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), properties)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// `data` in a file named `name`, in a scratch folder of its own.
    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = MCPTestSupport.tempFile(name)
        try data.write(to: url)
        return url
    }

    /// Waits until a place or replace call running in another task is reading its file: the session holds the project
    /// busy then, and the call resumes on the main actor only after this returns.
    private func untilReading(_ session: EditorSession) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !session.isProjectBusy {
            try #require(Date() < deadline, "The call never started reading its file.")
            await Task.yield()
        }
    }

    /// A 64 × 64 document holding one smart object imported from Photoshop, "Logo": 10 × 8 PNG contents placed on
    /// `quad`, over blue pixels at 20, 16, 24 × 24. No undo history.
    private func importedWorkspace() throws -> (workspace: ProjectWorkspace, session: EditorSession, id: UUID) {
        let context = try BrushRaster.context(width: 24, height: 24, mask: false)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        let blue = try #require(context.makeImage())
        var record = PSDRecord(id: UUID(), name: "Logo")
        record.bounds = CGRect(x: 20, y: 16, width: 24, height: 24)
        record.image = blue
        record.extras = PSDLayerExtras(blocks: PSDFixture.smartObjectBlocks(uuid: "u", size: CGSize(width: 10, height: 8), quad: quad))
        let entry = PSDFixture.LinkedEntry(uuid: "u", fileName: "Logo.png", data: try png(width: 10, height: 8))
        var document = PSDDocument(width: 64, height: 64, resolution: 72, layers: [record])
        document.extras = PSDDocumentExtras(globalBlocks: [PSDFixture.linkedLayersBlock(entries: [entry])])
        let imported = try PSDDocumentBuilder.makeImport(try PSDReader.read(try PSDFixture.data(document, composite: blue)))
        let workspace = MCPTestSupport.workspace(width: 64, height: 64)
        let session = workspace.current.session
        session.document?.layers = imported.layers
        let id = try #require(imported.layers.first?.id)
        session.activeLayerID = id
        session.history.reset()
        return (workspace, session, id)
    }

    // MARK: place_smart_object

    @Test func placeSmartObjectCentersItsContentsAsOneStep() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        let contents = try png(width: 30, height: 20, dpi: 72)
        let badge = try file("Badge.png", contents)
        let before = session.history.undoCount
        let result = try await MCPTestSupport.call("place_smart_object", ["path": .string(badge.path)], in: workspace)
        let placed = try #require(layer(session, try id(result)))
        // Its own size at the document's resolution, centered on the 640 × 480 canvas.
        #expect(placed.transform.origin == CGPoint(x: 305, y: 230) && placed.transform.size == CGSize(width: 30, height: 20))
        #expect(placed.name == "Badge" && result["name"]?.stringValue == "Badge" && session.activeLayerID == placed.id)
        #expect(placed.smartObject?.payload?.data == contents)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Place Smart Object")
        #expect(result["undo"]?.objectValue?["recorded"]?.boolValue == true)
        #expect(MCPValues.number(result["transform"]?.objectValue?["width"]) == 30)
        let smart = try #require(result["smart_object"]?.objectValue)
        #expect(smart["file_name"]?.stringValue == "Badge.png" && smart["file_type"]?.stringValue == "png")
        #expect(smart["bytes"]?.intValue == contents.count && smart["embedded"]?.boolValue == true)
        #expect(smart["contents_revision"]?.intValue == 0)
        #expect(close(corners(smart["quad"]),
                      [CGPoint(x: 305, y: 230), CGPoint(x: 335, y: 230), CGPoint(x: 335, y: 250), CGPoint(x: 305, y: 250)]))

        // At a center, under another name: still one step, which undo takes away whole.
        let named = try await MCPTestSupport.call("place_smart_object", [
            "path": .string(badge.path), "center": ["x": 100, "y": 50], "name": "Logo",
        ], in: workspace)
        let logo = try #require(layer(session, try id(named)))
        #expect(logo.name == "Logo" && named["name"]?.stringValue == "Logo" && logo.transform.center == CGPoint(x: 100, y: 50))
        #expect(session.history.undoCount == before + 2 && session.history.undoName == "Place Smart Object")
        session.undo()
        #expect(layer(session, logo.id) == nil && layer(session, placed.id) != nil)
    }

    /// Painting, filling, filters and replacing pixels would turn a smart object into plain pixels and drop its
    /// embedded file without a word (a later replace_smart_object_contents then fails). As in Photoshop they're
    /// refused instead (guard not_smart_object), pointing at rasterize_layer; the object's mask can still be painted.
    @Test func pixelToolsRefuseASmartObjectRatherThanDropItsContents() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 64)
        let session = workspace.current.session
        let contents = try png(width: 30, height: 20)
        let badge = try file("Badge.png", contents)
        let smart = try id(try await MCPTestSupport.call("place_smart_object", ["path": .string(badge.path)], in: workspace))
        let target = Value.string(smart.uuidString)
        func point(_ x: Double, _ y: Double) -> Value { ["x": .double(x), "y": .double(y)] }
        try await MCPTestSupport.call("select_rect", ["rect": ["x": 20, "y": 25, "width": 20, "height": 10]], in: workspace)
        let undoCount = session.history.undoCount
        let calls: [(String, [String: Value])] = [
            ("stroke_path", ["layer": target, "points": [point(20, 30), point(40, 30)]]),
            ("fill_selection", ["layer": target, "color": "#00ff00"]),
            ("clear_selection", ["layer": target]),
            ("invert_pixels", ["layer": target]),
            ("draw_gradient", ["layer": target, "start": point(0, 0), "end": point(60, 0), "colors": ["from": "#000000", "to": "#ffffff"]]),
            ("apply_filter", ["layer": target, "kind": "gaussian_blur", "settings": ["radius": 2]]),
            ("apply_levels", ["layer": target, "settings": ["black": 128]]),
            ("apply_hue_saturation", ["layer": target, "settings": ["saturation": -100]]),
            ("set_layer_pixels", ["layer": target, "path": .string(badge.path)]),
            ("paste_image_into_layer", ["layer": target, "path": .string(badge.path), "x": 0, "y": 0]),
        ]
        for (tool, args) in calls {
            let refused = try await MCPTestSupport.call(tool, args, in: workspace, expectError: "precondition_failed")
            #expect(error(refused)["guard"]?.stringValue == "not_smart_object", "\(tool): \(refused)")
            #expect(error(refused)["hint"]?.stringValue?.contains("rasterize_layer") == true, "\(tool): \(refused)")
            #expect(layer(session, smart)?.smartObject?.payload?.data == contents, "\(tool) dropped the contents")
        }
        #expect(session.history.undoCount == undoCount)
        try await MCPTestSupport.call("add_layer_mask", ["layer": target], in: workspace)
        try await MCPTestSupport.call("fill_selection", ["layer": target, "target": "mask", "color": "#000000"], in: workspace)
        #expect(layer(session, smart)?.smartObject?.payload?.data == contents)
    }

    @Test func placeSmartObjectFitsItsContentsInFitRectAsOneStep() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        let wide = try file("Wide.png", try png(width: 40, height: 20))
        let rect: Value = ["x": 100, "y": 100, "width": 100, "height": 100]
        let cases: [(fit: String?, box: CGRect)] = [
            (nil, CGRect(x: 100, y: 125, width: 100, height: 50)),
            ("fit", CGRect(x: 100, y: 125, width: 100, height: 50)),
            ("fill", CGRect(x: 100, y: 100, width: 100, height: 100)),
            ("Stretch", CGRect(x: 100, y: 100, width: 100, height: 100)),
        ]
        for (fit, box) in cases {
            let before = session.history.undoCount
            var args: [String: Value] = ["path": .string(wide.path), "fit_rect": rect]
            if let fit { args["fit"] = .string(fit) }
            let result = try await MCPTestSupport.call("place_smart_object", args, in: workspace)
            let placed = try #require(layer(session, try id(result)))
            let label = fit ?? "default"
            #expect(placed.transform.origin == box.origin && placed.transform.size == box.size, "\(label)")
            #expect(placed.asset?.image.width == Int(box.width) && placed.asset?.image.height == Int(box.height), "\(label)")
            #expect(placed.smartObject?.info.quad == .unitSquare, "\(label)")
            // Filling crops the contents to the box: their middle 20 × 20.
            let natural = fit == "fill" ? CGSize(width: 20, height: 20) : CGSize(width: 40, height: 20)
            #expect(placed.smartObject?.info.naturalSize == natural, "\(label)")
            #expect(session.history.undoCount == before + 1 && session.history.undoName == "Place Smart Object", "\(label)")
            // Placed and fitted in one step: undo takes the layer away.
            session.undo()
            #expect(layer(session, placed.id) == nil, "\(label)")
        }
    }

    @Test func placeSmartObjectRefusesArgumentsItCantUse() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        let badge = try file("Badge.png", try png(width: 10, height: 10))
        let path = Value.string(badge.path)
        let rect: Value = ["x": 0, "y": 0, "width": 50, "height": 50]
        let before = session.history.undoCount, count = session.document?.layers.count
        let cases: [([String: Value], String)] = [
            (["path": path, "center": ["x": 10, "y": 10], "fit_rect": rect], "center"),
            (["path": path, "fit": "fill"], "fit_rect"),
            (["path": path, "fit_rect": rect, "fit": "squash"], "fit"),
            (["path": path, "center": ["x": 2_000_000, "y": 0]], "center"),
            (["path": path, "center": ["x": 10]], "center"),
            (["path": path, "fit_rect": ["x": 0, "y": 0, "width": 0, "height": 50]], "fit_rect"),
            (["path": path, "fit_rect": ["x": 0, "y": 0, "width": 400_000, "height": 50]], "fit_rect"),
            (["path": path, "fit_rect": ["x": 999_990, "y": 0, "width": 50, "height": 50]], "fit_rect"),
        ]
        for (args, field) in cases {
            let result = try await MCPTestSupport.call("place_smart_object", args, in: workspace, expectError: "invalid_argument")
            #expect(message(result).contains(field), "\(args): \(message(result))")
        }
        let missing = badge.deletingLastPathComponent().appendingPathComponent("Missing.png")
        try await MCPTestSupport.call("place_smart_object", ["path": .string(missing.path)], in: workspace, expectError: "not_found")
        #expect(session.history.undoCount == before && session.document?.layers.count == count && !session.isProjectBusy)
    }

    @Test func placeSmartObjectGoesAboveTheOutermostLockAllFolder() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        let badge = try file("Badge.png", try png(width: 10, height: 10))
        let outer = try #require(try await MCPTestSupport.call("add_group", ["name": "Outer"], in: workspace)["group_id"]?.stringValue)
        try await MCPTestSupport.call("add_group", ["name": "Inner"], in: workspace)
        try await MCPTestSupport.call("add_blank_layer", ["name": "Deep"], in: workspace)
        try await MCPTestSupport.call("set_layer_locks", ["layer": .string(outer), "all": true], in: workspace)
        try await MCPTestSupport.call("select_layers", ["layers": ["Deep"]], in: workspace)
        let before = session.history.undoCount
        let result = try await MCPTestSupport.call("place_smart_object", ["path": .string(badge.path), "name": "Free"], in: workspace)
        let document = try #require(session.document)
        let placed = try #require(layer(session, try id(result)))
        #expect(placed.parentID == nil && placed.name == "Free")
        // Directly above the locked folder, among the top-level layers.
        let topLevel = document.layers.filter { $0.parentID == nil }.map(\.id)
        #expect(topLevel.last == placed.id && topLevel.dropLast().last?.uuidString == outer)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Place Smart Object")
    }

    /// The layer lands above whichever layer is active once the file is read, so where it landed, not what was active
    /// when the call began, decides whether it leaves a folder under Lock All.
    @Test func placeSmartObjectLeavesALockedFolderItLandsInAfterTheRead() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        let badge = try file("Badge.png", try png(width: 10, height: 10))
        let outer = try #require(try await MCPTestSupport.call("add_group", ["name": "Outer"], in: workspace)["group_id"]?.stringValue)
        try await MCPTestSupport.call("add_group", ["name": "Inner"], in: workspace)
        let deep = try id(try await MCPTestSupport.call("add_blank_layer", ["name": "Deep"], in: workspace))
        try await MCPTestSupport.call("set_layer_locks", ["layer": .string(outer), "all": true], in: workspace)
        // A top-level layer is active when the call begins...
        try await MCPTestSupport.call("select_layers", ["layers": ["Layer 1"]], in: workspace)
        let before = session.history.undoCount
        let call = Task { try await MCPTestSupport.call("place_smart_object", ["path": .string(badge.path)], in: workspace) }
        try await untilReading(session)
        // ...and one in the locked folder by the time the file has been read.
        session.selectLayer(deep)
        let placed = try #require(layer(session, try id(try await call.value)))
        let document = try #require(session.document)
        #expect(placed.parentID == nil)
        let topLevel = document.layers.filter { $0.parentID == nil }.map(\.id)
        #expect(topLevel.last == placed.id && topLevel.dropLast().last?.uuidString == outer)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Place Smart Object")
    }

    /// A place that fails because the document was closed while its file was read leaves the tab as it found it then:
    /// the step doesn't bring the closed document back.
    @Test func placeSmartObjectLeavesADocumentClosedDuringTheReadClosed() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        let badge = try file("Badge.png", try png(width: 10, height: 10))
        let call = Task {
            try await MCPTestSupport.call("place_smart_object", ["path": .string(badge.path)], in: workspace, expectError: "busy")
        }
        try await untilReading(session)
        session.clearProject()
        _ = try await call.value
        #expect(session.document == nil && session.activeLayerID == nil && session.history.undoCount == 0)
    }

    @Test func placeSmartObjectStopsAtTheLayerCap() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        let badge = try file("Badge.png", try png(width: 10, height: 10))
        let size = try #require(session.document?.size)
        session.document?.layers = (0..<10_000).map { ImageLayer(name: "Layer \($0)", blankSize: size) }
        let result = try await MCPTestSupport.call("place_smart_object", ["path": .string(badge.path)], in: workspace,
                                                   expectError: "precondition_failed")
        #expect(error(result)["guard"]?.stringValue == "max_layers")
        #expect(session.document?.layers.count == 10_000)
    }

    // MARK: Contents that can't be used

    @Test func contentsCompositorCantDrawOrKeepAreRefused() async throws {
        let (workspace, session, id) = try importedWorkspace()
        let before = try #require(layer(session, id))
        let layerArgument = Value.string(id.uuidString)
        let eps = try file("Logo.eps", Data("%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 10 10\nshowpage\n".utf8))
        let psb = try file("Big.psb", Data("8BPS\0\u{2}".utf8) + Data(count: 40))
        let notes = try file("Notes.txt", Data("Not a picture".utf8))
        for (url, word) in [(eps, "EPS"), (psb, "PSB"), (notes, "PNG")] {
            let placed = try await MCPTestSupport.call("place_smart_object", ["path": .string(url.path)], in: workspace,
                                                       expectError: "unsupported")
            #expect(message(placed).contains(word), "\(url.lastPathComponent): \(message(placed))")
            let replaced = try await MCPTestSupport.call("replace_smart_object_contents", [
                "layer": layerArgument, "path": .string(url.path),
            ], in: workspace, expectError: "unsupported")
            #expect(message(replaced).contains(word), "\(url.lastPathComponent): \(message(replaced))")
        }

        // More than a project keeps (512 MiB), without reading it: a sparse file.
        let huge = MCPTestSupport.tempFile("Huge.png")
        #expect(FileManager.default.createFile(atPath: huge.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: huge) }
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(SmartObjectFileRecord.maximumBytes) + 1)
        try handle.close()
        let placed = try await MCPTestSupport.call("place_smart_object", ["path": .string(huge.path)], in: workspace,
                                                   expectError: "invalid_argument")
        #expect(message(placed).contains("512 MiB"), "\(message(placed))")
        let replaced = try await MCPTestSupport.call("replace_smart_object_contents", [
            "layer": layerArgument, "path": .string(huge.path),
        ], in: workspace, expectError: "invalid_argument")
        #expect(message(replaced).contains("512 MiB"), "\(message(replaced))")

        // A folder is no contents either.
        try await MCPTestSupport.call("place_smart_object", ["path": .string(huge.deletingLastPathComponent().path)],
                                      in: workspace, expectError: "invalid_argument")

        #expect(layer(session, id) == before && session.document?.layers.count == 1)
        #expect(session.history.undoCount == 0 && !session.isProjectBusy)
    }

    // MARK: replace_smart_object_contents

    @Test func replaceKeepsTheQuadUnderStretchAndBumpsTheRevision() async throws {
        let (workspace, session, id) = try importedWorkspace()
        let contents = try png(width: 20, height: 10)
        let replacement = try file("New.png", contents)
        let result = try await MCPTestSupport.call("replace_smart_object_contents", [
            "layer": .string(id.uuidString), "path": .string(replacement.path), "fit": "stretch",
        ], in: workspace)
        #expect(result["layer_id"]?.stringValue == id.uuidString)
        #expect(result["smart_object"]?.objectValue?["contents_revision"]?.intValue == 1)
        #expect(session.history.undoCount == 1 && session.history.undoName == "Replace Smart Object Contents")
        #expect(result["undo"]?.objectValue?["recorded"]?.boolValue == true)

        let info = try await MCPTestSupport.call("get_smart_object_info", ["layer": "Logo"], in: workspace)
        #expect(close(corners(info["quad"]), quad), "\(corners(info["quad"]))")
        #expect(info["contents_revision"]?.intValue == 1 && info["file_name"]?.stringValue == "New.png")
        #expect(info["bytes"]?.intValue == contents.count && info["file_type"]?.stringValue == "png")
        #expect(MCPValues.number(info["natural_size"]?.objectValue?["width"]) == 20)
        #expect(MCPValues.number(info["natural_size"]?.objectValue?["height"]) == 10)
        // The pixels now fill the quad.
        let replaced = try #require(layer(session, id))
        #expect(replaced.smartObject?.payload?.data == contents)
        #expect(replaced.transform.origin == CGPoint(x: 18, y: 14) && replaced.transform.size == CGSize(width: 28, height: 28))
        #expect(MCPValues.number(result["transform"]?.objectValue?["width"]) == 28)
    }

    @Test func replaceFitsByDefaultAndFillsTheQuadWithACrop() async throws {
        let (workspace, session, id) = try importedWorkspace()
        // A 20,000 × 1 divider filling the 28 × 28 quad is cropped to its middle pixel: the layer covers the quad.
        let divider = try file("Divider.png", try png(width: 20_000, height: 1))
        let filled = try await MCPTestSupport.call("replace_smart_object_contents", [
            "layer": .string(id.uuidString), "path": .string(divider.path), "fit": "fill",
        ], in: workspace)
        #expect(close(corners(filled["smart_object"]?.objectValue?["quad"]), quad))
        #expect(MCPValues.number(filled["smart_object"]?.objectValue?["natural_size"]?.objectValue?["width"]) == 1)
        #expect(layer(session, id)?.asset?.image.width == 28 && layer(session, id)?.asset?.image.height == 28)
        #expect(session.history.undoCount == 1)
        // So does placing it in a box that size.
        let placed = try await MCPTestSupport.call("place_smart_object", [
            "path": .string(divider.path), "fit_rect": ["x": 18, "y": 14, "width": 28, "height": 28], "fit": "fill",
        ], in: workspace)
        let box = try #require(layer(session, try self.id(placed)))
        #expect(box.transform.origin == CGPoint(x: 18, y: 14) && box.transform.size == CGSize(width: 28, height: 28))
        #expect(session.document?.layers.count == 2 && session.history.undoCount == 2)

        // Fitted by default: inside the quad, 2:1 and centered.
        let wide = try file("Wide.png", try png(width: 20, height: 10))
        let result = try await MCPTestSupport.call("replace_smart_object_contents", [
            "layer": .string(id.uuidString), "path": .string(wide.path),
        ], in: workspace)
        #expect(close(corners(result["smart_object"]?.objectValue?["quad"]),
                      [CGPoint(x: 18, y: 21), CGPoint(x: 46, y: 21), CGPoint(x: 46, y: 35), CGPoint(x: 18, y: 35)]))
        #expect(layer(session, id)?.asset?.image.width == 28 && layer(session, id)?.asset?.image.height == 14)
        #expect(session.history.undoCount == 3)

        // A quad Photoshop placed 400,000 pixels wide would make a layer larger than a document holds: refused.
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        let transform = session.document!.layers[index].transform
        session.document!.layers[index].smartObject?.info.quad = .rect(CGRect(x: 18, y: 14, width: 400_000, height: 28), in: transform)
        let before = try #require(layer(session, id))
        let refused = try await MCPTestSupport.call("replace_smart_object_contents", [
            "layer": .string(id.uuidString), "path": .string(wide.path), "fit": "stretch",
        ], in: workspace, expectError: "invalid_argument")
        #expect(message(refused).contains("300,000"), "\(message(refused))")
        #expect(layer(session, id) == before && session.history.undoCount == 3 && !session.isProjectBusy)
    }

    @Test func replaceRefusesOtherLayersLockedPixelsAndMovingALockedPosition() async throws {
        let workspace = MCPTestSupport.workspace()
        let session = workspace.current.session
        let plain = try #require(session.document?.layers.first?.id)
        let square = try file("Square.png", try png(width: 20, height: 20))
        let wide = try file("Wide.png", try png(width: 40, height: 20))
        let placed = try id(try await MCPTestSupport.call("place_smart_object", ["path": .string(square.path)], in: workspace))
        let before = session.history.undoCount
        @discardableResult
        func replace(_ layer: UUID, _ url: URL, fit: String? = nil, expectError code: String? = nil) async throws -> [String: Value] {
            var args: [String: Value] = ["layer": .string(layer.uuidString), "path": .string(url.path)]
            if let fit { args["fit"] = .string(fit) }
            return try await MCPTestSupport.call("replace_smart_object_contents", args, in: workspace, expectError: code)
        }

        // Only a smart object takes contents; a Photoshop placeholder is named as one first.
        let notSmart = try await replace(plain, square, expectError: "precondition_failed")
        #expect(error(notSmart)["guard"]?.stringValue == "is_smart_object")
        var placeholder = ImageLayer(name: "Brightness Contrast 1", blankSize: CGSize(width: 32, height: 32))
        placeholder.isVisible = false
        placeholder.psdExtras = PSDLayerExtras(importedVisible: true, placeholder: "adjustment:brit")
        session.document?.layers.insert(placeholder, at: 0)
        let held = try await replace(placeholder.id, square, expectError: "precondition_failed")
        #expect(error(held)["guard"]?.stringValue == "placeholder")

        // Locked pixels: refused.
        try await MCPTestSupport.call("set_layer_locks", ["layer": .string(placed.uuidString), "pixels": true], in: workspace)
        let pixels = try await replace(placed, wide, fit: "stretch", expectError: "precondition_failed")
        #expect(error(pixels)["guard"]?.stringValue == "layer_locked")

        // A locked position takes contents that keep the placement, but not contents that would move it.
        try await MCPTestSupport.call("set_layer_locks", ["layer": .string(placed.uuidString), "pixels": false, "position": true],
                                      in: workspace)
        let locked = try #require(layer(session, placed))
        let lockedSteps = session.history.undoCount
        try await replace(placed, wide, fit: "stretch")
        let stretched = try #require(layer(session, placed))
        #expect(stretched.transform == locked.transform && stretched.smartObject?.info.fileName == "Wide.png")
        #expect(session.history.undoCount == lockedSteps + 1)
        // Filling crops the contents to the placement, so it keeps it too.
        try await replace(placed, wide, fit: "fill")
        let filled = try #require(layer(session, placed))
        #expect(filled.transform == locked.transform && filled.smartObject?.info.naturalSize == CGSize(width: 20, height: 20))
        #expect(session.history.undoCount == lockedSteps + 2)
        let moving = try await replace(placed, wide, expectError: "precondition_failed")
        #expect(error(moving)["guard"]?.stringValue == "layer_locked")
        #expect(error(moving)["details"]?.objectValue?["layer_id"]?.stringValue == placed.uuidString)
        #expect(error(moving)["hint"]?.stringValue?.contains("fit: fill or stretch") == true, "\(error(moving))")
        #expect(layer(session, placed) == filled && session.history.undoCount == lockedSteps + 2 && !session.isProjectBusy)

        // Lock All on a folder around it holds it too.
        try await MCPTestSupport.call("set_layer_locks", ["layer": .string(placed.uuidString), "position": false], in: workspace)
        let folder = try await MCPTestSupport.call("group_layers", ["layers": [.string(placed.uuidString)], "name": "Held"],
                                                   in: workspace)
        try await MCPTestSupport.call("set_layer_locks", ["layer": try #require(folder["group_id"]), "all": true], in: workspace)
        let inherited = try await replace(placed, square, expectError: "precondition_failed")
        #expect(error(inherited)["guard"]?.stringValue == "layer_locked")
        #expect(session.history.undoCount > before)
    }

    @Test func placeAndReplaceWaitForOtherEditsWithoutCommittingThem() async throws {
        let (workspace, session, id) = try importedWorkspace()
        let square = try file("Square.png", try png(width: 10, height: 10))
        let replaceArgs: [String: Value] = ["layer": .string(id.uuidString), "path": .string(square.path)]
        let placeArgs: [String: Value] = ["path": .string(square.path)]

        // Another operation holding the project: busy, nothing changed.
        session.isProjectBusy = true
        for (tool, args) in [("replace_smart_object_contents", replaceArgs), ("place_smart_object", placeArgs)] {
            let result = try await MCPTestSupport.call(tool, args, in: workspace, expectError: "busy")
            #expect(error(result)["guard"]?.stringValue == "can_edit_layers", "\(tool)")
        }
        session.isProjectBusy = false

        // A free transform in progress in the app: refused and left pending, with no step recorded.
        session.selectLayer(id)
        session.beginTransform()
        #expect(session.transformEdit != nil)
        for (tool, args) in [("replace_smart_object_contents", replaceArgs), ("place_smart_object", placeArgs)] {
            let result = try await MCPTestSupport.call(tool, args, in: workspace, expectError: "precondition_failed")
            #expect(error(result)["guard"]?.stringValue == "can_edit_layers", "\(tool)")
        }
        #expect(session.transformEdit != nil && session.history.undoCount == 0 && session.document?.layers.count == 1)
        session.cancelTransform()
    }

    // MARK: get_smart_object_info

    @Test func getSmartObjectInfoDescribesTheContents() async throws {
        let (workspace, session, id) = try importedWorkspace()
        let smartObject = try #require(layer(session, id)?.smartObject)
        let payload = try #require(smartObject.payload)
        let info = try await MCPTestSupport.call("get_smart_object_info", ["layer": "Logo"], in: workspace)
        #expect(info["layer_id"]?.stringValue == id.uuidString && info["name"]?.stringValue == "Logo")
        #expect(info["file_type"]?.stringValue == "png" && info["file_name"]?.stringValue == "Logo.png")
        #expect(info["bytes"]?.intValue == payload.data.count)
        #expect(MCPValues.number(info["natural_size"]?.objectValue?["width"]) == 10)
        #expect(MCPValues.number(info["natural_size"]?.objectValue?["height"]) == 8)
        #expect(close(corners(info["quad"]), quad))
        #expect(info["embedded"]?.boolValue == true && info["contents_revision"]?.intValue == 0)
        #expect(info["undo"] == nil)

        // Contents the document doesn't hold (Photoshop linked them, or left them out) have no bytes.
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].smartObject = LayerSmartObject(info: smartObject.info, payload: nil)
        let missing = try await MCPTestSupport.call("get_smart_object_info", ["layer": "Logo"], in: workspace)
        #expect(missing["bytes"] == .null && missing["file_name"]?.stringValue == "Logo.png")

        try await MCPTestSupport.call("add_blank_layer", ["name": "Plain"], in: workspace)
        let plain = try await MCPTestSupport.call("get_smart_object_info", ["layer": "Plain"], in: workspace,
                                                  expectError: "precondition_failed")
        #expect(error(plain)["guard"]?.stringValue == "is_smart_object")
    }

    // MARK: export_smart_object_contents

    @Test func exportSmartObjectContentsWritesThemAsTheyAre() async throws {
        let (workspace, session, id) = try importedWorkspace()
        let smartObject = try #require(layer(session, id)?.smartObject)
        let payload = try #require(smartObject.payload)
        let target = MCPTestSupport.tempFile("Logo copy.png")
        let result = try await MCPTestSupport.call("export_smart_object_contents", ["layer": "Logo", "path": .string(target.path)],
                                                   in: workspace)
        #expect(try Data(contentsOf: target) == payload.data)
        #expect(result["path"]?.stringValue == target.path && result["bytes"]?.intValue == payload.data.count)
        #expect(result["file_type"]?.stringValue == "png" && result["file_name"]?.stringValue == "Logo.png")

        // Never over a file unless asked.
        try Data("older".utf8).write(to: target)
        let refused = try await MCPTestSupport.call("export_smart_object_contents", ["layer": "Logo", "path": .string(target.path)],
                                                    in: workspace, expectError: "io_error")
        #expect(error(refused)["details"]?.objectValue?["code"]?.stringValue == "file_exists")
        #expect(try Data(contentsOf: target) == Data("older".utf8))
        try await MCPTestSupport.call("export_smart_object_contents", [
            "layer": "Logo", "path": .string(target.path), "overwrite": true,
        ], in: workspace)
        #expect(try Data(contentsOf: target) == payload.data)

        // A path without an extension takes the contents' own; a relative one lands in the Agent folder.
        let relative = "smart-\(UUID().uuidString)/logo"
        let folder = MCPTestSupport.agentRootOverride.appendingPathComponent(relative).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let named = try await MCPTestSupport.call("export_smart_object_contents", ["layer": "Logo", "path": .string(relative)],
                                                  in: workspace)
        let written = MCPTestSupport.agentRootOverride.appendingPathComponent(relative + ".png")
        #expect(try Data(contentsOf: written) == payload.data)
        #expect(named["path"]?.stringValue?.hasSuffix(relative + ".png") == true)

        // Contents the document doesn't hold can't be written.
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].smartObject = LayerSmartObject(info: smartObject.info, payload: nil)
        let absent = try await MCPTestSupport.call("export_smart_object_contents", [
            "layer": "Logo", "path": .string(MCPTestSupport.tempFile("Absent.png").path),
        ], in: workspace, expectError: "precondition_failed")
        #expect(error(absent)["guard"]?.stringValue == "has_contents")
        #expect(session.history.undoCount == 0)
    }
}
