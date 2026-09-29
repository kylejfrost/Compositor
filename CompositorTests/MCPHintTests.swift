import CoreGraphics
import Foundation
import ImageIO
import Testing
import MCP
@testable import Compositor

/// Every `precondition_failed` comes with a hint: what the agent can do about it. Checked two ways: by calling every
/// tool in document states that trip the common guards, and by reading the MCP sources for a `.preconditionFailed`
/// error built without one.
@MainActor struct MCPHintTests {
    // MARK: Calling the tools

    private func solid(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func pngFile() throws -> URL {
        let url = MCPTestSupport.tempFile("hint.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try solid(width: 4, height: 4), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// A 32 × 32 document whose active layer is an opaque 16 × 16 "Photo", with `prepare` applied.
    private func photoWorkspace(_ prepare: (EditorSession, UUID) throws -> Void) throws -> ProjectWorkspace {
        let workspace = MCPTestSupport.workspace(width: 32, height: 32)
        let session = workspace.current.session
        let image = try solid(width: 16, height: 16)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Photo"))
        let id = try #require(session.activeLayerID)
        try prepare(session, id)
        return workspace
    }

    private func index(_ id: UUID, in session: EditorSession) throws -> Int {
        try #require(session.document?.layers.firstIndex { $0.id == id })
    }

    /// Document states that trip the guards tools share, each built fresh for every call.
    private var states: [(String, () throws -> ProjectWorkspace)] {
        [
            ("no document", { ProjectWorkspace() }),
            ("blank layer", { MCPTestSupport.workspace(width: 32, height: 32) }),
            ("pixels", { try self.photoWorkspace { _, _ in } }),
            ("folder", { try self.photoWorkspace { session, _ in session.addGroup() } }),
            ("adjustment", { try self.photoWorkspace { session, _ in session.addAdjustment(.levels); session.adjustmentEditingID = nil } }),
            ("placeholder", { try self.photoWorkspace { session, id in
                let index = try self.index(id, in: session)
                session.document?.layers[index].asset = nil
                session.document?.layers[index].isVisible = false
                session.document?.layers[index].psdExtras = PSDLayerExtras(importedVisible: true, placeholder: "adjustment:brit")
            } }),
            ("hidden", { try self.photoWorkspace { session, id in
                let index = try self.index(id, in: session)
                session.document?.layers[index].isVisible = false
            } }),
            ("lock all", { try self.photoWorkspace { session, id in
                let index = try self.index(id, in: session)
                session.document?.layers[index].locks = [.all]
            } }),
            ("lock pixels", { try self.photoWorkspace { session, id in
                let index = try self.index(id, in: session)
                session.document?.layers[index].locks = [.pixels]
            } }),
            ("disabled mask", { try self.photoWorkspace { session, id in
                session.addLayerMask(revealing: true)
                let index = try self.index(id, in: session)
                session.document?.layers[index].mask?.isEnabled = false
            } }),
            ("empty selection", { try self.photoWorkspace { session, _ in session.document?.selection = DocumentSelection(path: CGMutablePath()) } }),
            ("selection off the layer", { try self.photoWorkspace { session, _ in
                session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 24, y: 24, width: 4, height: 4), transform: nil))
            } }),
            ("editing in the app", { try self.photoWorkspace { session, id in session.renamingLayerID = id } }),
        ]
    }

    /// Arguments most tools accept, so a call gets past its argument checks to its guards; `overrides` settles the
    /// names that mean different things to different tools.
    private func arguments(for tool: String, png: URL, mask: Bool) -> [String: Value] {
        let point: (Double, Double) -> Value = { .object(["x": .double($0), "y": .double($1)]) }
        var args: [String: Value] = [
            "layer": "@active", "layers": ["@active"], "from": "@active", "to": "canvas",
            "points": [point(2, 2), point(12, 12), point(2, 12)], "rect": ["x": 0, "y": 0, "width": 8, "height": 8],
            "x": 2, "y": 2, "dx": 1, "dy": 1, "start": point(0, 0), "end": point(12, 0), "corners": [point(0, 0), point(12, 0), point(12, 12), point(0, 12)],
            "percent": 50, "degrees": 10, "axis": "horizontal", "edge": "left", "settings": [:], "operation": "expand", "amount": 2,
            "path": .string(png.path), "enabled": true, "visible": true, "linked": false, "opacity": 0.5, "fill_opacity": 0.5,
            "name": "Named", "index": 0, "color": "#336699", "effects": ["stroke": ["size": 2]], "discard_changes": false,
        ]
        if mask { args["target"] = "mask"; args["source"] = "mask" }
        let overrides: [String: [String: Value]] = [
            "stroke_path": ["mode": "paint"], "paste_image_into_layer": ["mode": "over"], "scale_layer_to_fit": ["mode": "contain"],
            "settle_pending_edits": ["mode": "commit"], "add_layer_mask": ["kind": "reveal_all"], "apply_filter": ["kind": "gaussian_blur"],
            "add_layer_effect": ["kind": "stroke"], "remove_layer_effect": ["kind": "stroke"], "set_layer_effect_enabled": ["kind": "stroke"],
            "add_adjustment_layer": ["kind": "invert"], "copy_layer_mask": ["to": "@active"], "set_layer_blend_mode": ["mode": "multiply"],
            "set_adjustment": ["settings": ["hue": 10]], "apply_hue_saturation": ["settings": ["hue": 10]],
            "apply_levels": ["settings": ["black": 10]], "modify_selection": ["mode": "replace"],
            "add_text_layer": ["text": "Hint"], "set_text": ["text": "Hint"], "set_text_style": ["style": ["font_size": 12]],
            "fit_text": ["max_width": 10], "add_shape": ["kind": "rectangle"],
        ]
        args.merge(overrides[tool] ?? [:]) { _, new in new }
        // Names that would make a tool refuse the call as a whole: a rectangle fills `rect`, and start/end place a line.
        let dropped: [String: [String]] = ["add_shape": ["start", "end"]]
        for name in dropped[tool] ?? [] { args[name] = nil }
        return args
    }

    /// Tools the sweep leaves out: those `MCPRegistryTests` never calls, and the Vision selections, which are slow and
    /// whose guards the source check covers.
    private static let unswept = MCPRegistryTests.toolsSkippedForEmptyArgsCall.union(["select_subject", "select_object"])

    @Test func everyRefusedPreconditionSaysWhatToDo() async throws {
        _ = MCPTestSupport.workspace()
        let png = try pngFile()
        var missing: [String] = []
        for entry in MCPToolRegistry.entries where !Self.unswept.contains(entry.tool.name) {
            let tool = entry.tool.name
            let properties = entry.tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
            let masks = properties["target"] != nil || properties["source"] != nil ? [false, true] : [false]
            for (state, make) in states {
                for mask in masks {
                    let workspace = try make()
                    let result = await MCPToolRegistry.call(tool, arguments(for: tool, png: png, mask: mask), workspace: workspace)
                    guard let error = result.structuredContent?.objectValue?["error"]?.objectValue,
                          error["code"]?.stringValue == "precondition_failed" else { continue }
                    if error["hint"]?.stringValue?.isEmpty != false {
                        missing.append("\(tool) [\(state)\(mask ? ", mask" : "")] guard \(error["guard"]?.stringValue ?? "?"): \(error["message"]?.stringValue ?? "")")
                    }
                }
            }
        }
        #expect(missing.isEmpty, "precondition_failed without a hint:\n\(Set(missing).sorted().joined(separator: "\n"))")
    }

    // MARK: Reading the sources

    /// Every `MCPToolError(...)` built in the MCP sources whose code can be `.preconditionFailed` passes a `hint:`.
    @Test func everyPreconditionErrorInTheSourcesHasAHint() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Compositor/MCP")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 20, "Read \(files.count) files from \(folder.path)")
        var missing: [String] = []
        for file in files {
            let source = Array(try String(contentsOf: file, encoding: .utf8).unicodeScalars)
            for call in SwiftCalls.arguments(of: "MCPToolError(", in: source) where call.text.contains(".preconditionFailed") {
                if !call.text.contains("hint:") { missing.append("\(file.lastPathComponent):\(call.line)") }
            }
        }
        #expect(missing.isEmpty, "MCPToolError(.preconditionFailed…) without hint: at \(missing.sorted().joined(separator: ", "))")
    }
}

/// Just enough of Swift's syntax to find a call's parenthesized arguments: parentheses inside string literals
/// (interpolations included) don't count.
private enum SwiftCalls {
    struct Call {
        let line: Int
        let text: String
    }

    /// The argument text of every call to `name` (which ends with its opening parenthesis) in `source`.
    static func arguments(of name: String, in source: [Unicode.Scalar]) -> [Call] {
        let pattern = Array(name.unicodeScalars)
        var calls: [Call] = []
        var index = 0
        while index + pattern.count <= source.count {
            if source[index] == pattern[0], Array(source[index..<(index + pattern.count)]) == pattern {
                let open = index + pattern.count - 1
                let close = matchingParenthesis(source, from: open)
                let line = source[..<index].filter { $0 == "\n" }.count + 1
                calls.append(Call(line: line, text: String(String.UnicodeScalarView(source[open...min(close, source.count - 1)]))))
                index = open + 1
            } else {
                index += 1
            }
        }
        return calls
    }

    /// The index of the parenthesis closing the one at `start`.
    private static func matchingParenthesis(_ source: [Unicode.Scalar], from start: Int) -> Int {
        var depth = 0, index = start
        while index < source.count {
            switch source[index] {
            case "\"": index = endOfString(source, from: index)
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index += 1
        }
        return source.count - 1
    }

    /// The index of the quote closing the string literal that opens at `start`.
    private static func endOfString(_ source: [Unicode.Scalar], from start: Int) -> Int {
        let triple = start + 2 < source.count && source[start + 1] == "\"" && source[start + 2] == "\""
        var index = start + (triple ? 3 : 1)
        while index < source.count {
            if source[index] == "\\" {
                if index + 1 < source.count, source[index + 1] == "(" {
                    index = matchingParenthesis(source, from: index + 1) + 1
                    continue
                }
                index += 2
                continue
            }
            if source[index] == "\"" {
                if !triple { return index }
                if index + 2 < source.count, source[index + 1] == "\"", source[index + 2] == "\"" { return index + 2 }
            }
            index += 1
        }
        return index
    }
}
