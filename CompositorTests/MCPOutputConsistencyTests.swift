import CoreGraphics
import Foundation
import Testing
import MCP
@testable import Compositor

/// What get_layer and get_document report can be sent back: an adjustment's kind and settings read in the form
/// set_adjustment takes, a folder's content bounds cover what it shows, and every layer carries its effective locks.
@MainActor struct MCPOutputConsistencyTests {
    private func solid(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// An opaque 8 × 8 layer with its top-left corner at `origin`.
    @discardableResult
    private func addLayer(_ session: EditorSession, _ name: String, at origin: CGPoint) throws -> UUID {
        let image = try solid(width: 8, height: 8)
        session.insert(ImportedImage(image: image, thumbnail: image, name: name))
        let id = try #require(session.activeLayerID)
        session.renameLayer(id, to: name)
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].transform.origin = origin
        return id
    }

    private func group(_ session: EditorSession, _ ids: Set<UUID>, name: String) throws -> UUID {
        session.selectLayers(ids, primary: ids.first)
        session.groupSelectedLayers()
        let folder = try #require(session.activeLayerID)
        session.renameLayer(folder, to: name)
        return folder
    }

    /// `value` with the object at `path` (keys, or array indexes as strings) changed by `change`.
    private func changing(_ value: Value, _ path: [String], _ change: (Value) -> Value) -> Value {
        guard let key = path.first else { return change(value) }
        let rest = Array(path.dropFirst())
        if var object = value.objectValue {
            object[key] = changing(object[key] ?? .null, rest, change)
            return .object(object)
        }
        if var array = value.arrayValue, let index = Int(key), array.indices.contains(index) {
            array[index] = changing(array[index], rest, change)
            return .array(array)
        }
        return value
    }

    // MARK: Adjustments

    @Test func anAdjustmentReadsBackInTheFormSetAdjustmentTakes() async throws {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        try addLayer(session, "Photo", at: .zero)
        let cases: [(kind: String, path: [String], value: Value, check: (LayerAdjustment) -> Bool)] = [
            ("levels", ["levels", "ranges", "0", "black"], 20, { $0.levels.ranges[0].black == 20 }),
            ("hue_saturation", ["saturation"], -40, { $0.saturation == -40 }),
            ("curves", ["curves", "channels", "0"], [["x": 0, "y": 0], ["x": 128, "y": 180], ["x": 255, "y": 255]],
             { $0.curves.channels[0].count == 3 && $0.curves.channels[0][1].y == 180 }),
        ]
        for (kind, path, newValue, check) in cases {
            let added = try await MCPTestSupport.call("add_adjustment_layer", ["kind": .string(kind)], in: workspace)
            let id = try #require(added["layer_id"]?.stringValue)
            let described = try await MCPTestSupport.call("get_layer", ["layer": .string(id)], in: workspace)
            let layer = try #require(described["layer"]?.objectValue)
            #expect(layer["adjustment_kind"] == .string(kind), "\(kind): \(layer)")
            let settings = try #require(layer["adjustment"])
            #expect(settings == added["settings"], "\(kind): \(settings)")

            let document = try await MCPTestSupport.call("get_document", ["detail": "full"], in: workspace)
            let listed = try #require(document["document"]?.objectValue?["layers"]?.arrayValue?
                .compactMap(\.objectValue).first { $0["id"]?.stringValue == id })
            #expect(listed["adjustment_kind"] == .string(kind) && listed["adjustment"] == settings)

            // Read, change one value, send the whole thing back.
            let patched = changing(settings, path) { _ in newValue }
            let set = try await MCPTestSupport.call("set_adjustment", ["layer": .string(id), "settings": patched], in: workspace)
            #expect(set["undo"]?.objectValue?["recorded"] == .bool(true), "\(kind): \(set)")
            let adjustment = try #require(session.document?.layers.first { $0.id.uuidString == id }?.adjustment)
            #expect(check(adjustment), "\(kind)")
            // Sending back what was read changes nothing.
            let again = try await MCPTestSupport.call("get_layer", ["layer": .string(id)], in: workspace)
            let unchanged = try await MCPTestSupport.call("set_adjustment",
                                                          ["layer": .string(id), "settings": again["layer"]?.objectValue?["adjustment"] ?? .null],
                                                          in: workspace)
            #expect(unchanged["undo"]?.objectValue?["recorded"] == .bool(false), "\(kind): \(unchanged)")
        }
    }

    // MARK: Folders and locks

    @Test func aFoldersContentBoundsCoverWhatItShows() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 64)
        let session = workspace.current.session
        let shown = try addLayer(session, "Shown", at: CGPoint(x: 2, y: 3))
        let hidden = try addLayer(session, "Hidden", at: CGPoint(x: 40, y: 40))
        let tucked = try addLayer(session, "Tucked", at: CGPoint(x: 20, y: 20))
        let inner = try group(session, [tucked], name: "Inner")
        let folder = try group(session, [shown, hidden, inner], name: "Folder")
        for id in [hidden, inner] {
            let index = try #require(session.document?.layers.firstIndex { $0.id == id })
            session.document?.layers[index].isVisible = false
        }

        let described = try await MCPTestSupport.call("get_layer", ["layer": "Folder"], in: workspace)
        let layer = try #require(described["layer"]?.objectValue)
        #expect(layer["content_bounds"].flatMap(MCPValues.rect(from:)) == CGRect(x: 2, y: 3, width: 8, height: 8))
        #expect(layer["transform"].flatMap { MCPValues.rect(from: $0) } == CGRect(x: 0, y: 0, width: 64, height: 64))
        let children = try #require(layer["children"]?.arrayValue).compactMap(\.objectValue)
        // Each layer still reports its own pixels, and a hidden folder what it would show.
        let bounds = Dictionary(uniqueKeysWithValues: children.compactMap { child in
            child["name"]?.stringValue.map { ($0, child["content_bounds"].flatMap(MCPValues.rect(from:))) }
        })
        #expect(bounds["Hidden"] == CGRect(x: 40, y: 40, width: 8, height: 8))
        #expect(bounds["Inner"] == CGRect(x: 20, y: 20, width: 8, height: 8))

        let document = try await MCPTestSupport.call("get_document", ["detail": "full"], in: workspace)
        let roots = try #require(document["document"]?.objectValue?["layers"]?.arrayValue).compactMap(\.objectValue)
        let listed = try #require(roots.first { $0["id"]?.stringValue == folder.uuidString })
        #expect(listed["content_bounds"] == layer["content_bounds"])
    }

    @Test func everyLayerReportsItsEffectiveLocks() async throws {
        let workspace = MCPTestSupport.workspace(width: 64, height: 64)
        let session = workspace.current.session
        let a = try addLayer(session, "A", at: .zero)
        let folder = try group(session, [a], name: "Folder")
        let index = try #require(session.document?.layers.firstIndex { $0.id == folder })
        session.document?.layers[index].locks = [.position]
        try await MCPTestSupport.call("add_adjustment_layer", ["kind": "invert"], in: workspace)

        for detail in ["summary", "full"] {
            let document = try await MCPTestSupport.call("get_document", ["detail": .string(detail)], in: workspace)
            var pending = try #require(document["document"]?.objectValue?["layers"]?.arrayValue).compactMap(\.objectValue)
            var seen = 0
            while let layer = pending.popLast() {
                seen += 1
                #expect(layer["effective_locks"]?.arrayValue != nil, "\(detail): \(layer["name"] ?? .null)")
                pending += layer["children"]?.arrayValue?.compactMap(\.objectValue) ?? []
            }
            #expect(seen == session.document?.layers.count)
        }
    }
}
