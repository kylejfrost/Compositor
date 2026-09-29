import CoreGraphics
import Foundation
import MCP

/// JSON shapes tools return for tabs, documents, layers, transforms and history, shared
/// so every tool describes the same thing the same way.
@MainActor
enum MCPValues {
    // MARK: Tabs & documents

    static func tab(_ tab: ProjectTab, in workspace: ProjectWorkspace) -> Value {
        var out: [String: Value] = [
            "index": .int(tabIndex(tab, in: workspace)),
            "tab_id": .string(tab.id.uuidString),
            "title": .string(tab.title),
            "current": .bool(tab.id == workspace.selectedID),
        ]
        if let document = tab.session.document {
            out["document_id"] = .string(document.id.uuidString)
            out["width"] = .int(document.width)
            out["height"] = .int(document.height)
            out["is_modified"] = .bool(tab.session.isModified)
            out["layer_count"] = .int(document.layers.count)
        } else {
            out["document_id"] = .null
        }
        if let url = tab.session.projectURL { out["project_url"] = .string(url.path) }
        return .object(out)
    }

    static func tabIndex(_ tab: ProjectTab, in workspace: ProjectWorkspace) -> Int {
        workspace.tabs.firstIndex { $0 === tab } ?? 0
    }

    // MARK: Layers

    static func kind(of layer: ImageLayer) -> String {
        if layer.isGroup { return "folder" }
        // A Photoshop layer kept only to be written back (an unsupported adjustment): hidden, no pixels.
        if layer.isPhotoshopPlaceholder { return "placeholder" }
        if layer.adjustment != nil { return "adjustment" }
        if layer.shape != nil { return "shape" }
        if layer.text != nil { return "text" }
        if layer.smartObject != nil { return "smart_object" }
        return "raster"
    }

    /// `{id, path, kind}`: how an `ambiguous` error lists the layers a selector matched.
    static func candidate(_ layer: ImageLayer, in document: CanvasDocument) -> Value {
        .object([
            "id": .string(layer.id.uuidString),
            "path": .string(MCPSelectors.path(of: layer, in: document)),
            "kind": .string(kind(of: layer)),
        ])
    }

    static func transform(_ t: LayerTransform) -> Value {
        .object([
            "x": .double(Double(t.origin.x)),
            "y": .double(Double(t.origin.y)),
            "width": .double(Double(t.size.width)),
            "height": .double(Double(t.size.height)),
            "rotation": .double(Double(t.rotation)),
            "flip_x": .bool(t.flipX),
            "flip_y": .bool(t.flipY),
            "center_x": .double(Double(t.center.x)),
            "center_y": .double(Double(t.center.y)),
        ])
    }

    // MARK: Geometry

    /// `{x, y, width, height}` in document pixels.
    nonisolated static func rect(_ rect: CGRect) -> Value {
        .object([
            "x": .double(Double(rect.minX)),
            "y": .double(Double(rect.minY)),
            "width": .double(Double(rect.width)),
            "height": .double(Double(rect.height)),
        ])
    }

    /// `{x, y}` in document pixels.
    nonisolated static func point(_ point: CGPoint) -> Value {
        .object(["x": .double(Double(point.x)), "y": .double(Double(point.y))])
    }

    /// A rectangle given as `{x, y, width, height}` of finite numbers, or nil when the value is not one.
    nonisolated static func rect(from value: Value) -> CGRect? {
        guard let object = value.objectValue,
              let x = number(object["x"]), let y = number(object["y"]),
              let width = number(object["width"]), let height = number(object["height"]) else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// A point given as `{x, y}` of finite numbers, or nil when the value is not one.
    nonisolated static func point(from value: Value) -> CGPoint? {
        guard let object = value.objectValue, let x = number(object["x"]), let y = number(object["y"]) else { return nil }
        return CGPoint(x: x, y: y)
    }

    nonisolated static func number(_ value: Value?) -> Double? {
        guard let value, let number = value.doubleValue ?? value.intValue.map(Double.init), number.isFinite else { return nil }
        return number
    }

    // MARK: History

    /// `{name, count, recorded}` of the newest undo entry, returned by every mutating
    /// tool. `recorded` is true only when the call itself added that entry (a no-op edit,
    /// or an undo/redo, adds none).
    static func undo(_ session: EditorSession, recorded: Bool) -> Value {
        .object([
            "name": .string(session.history.undoName),
            "count": .int(session.history.undoCount),
            "recorded": .bool(recorded),
        ])
    }

    static func history(_ session: EditorSession) -> [String: Value] {
        [
            "can_undo": .bool(session.canUndo),
            "can_redo": .bool(session.canRedo),
            "undo_name": .string(session.history.undoName),
            "redo_name": .string(session.history.redoName),
            "is_modified": .bool(session.isModified),
        ]
    }

    // MARK: Colors

    /// The keys a color object may hold.
    nonisolated static let colorChannelKeys: Set<String> = ["r", "g", "b", "red", "green", "blue"]

    /// `{r, g, b}` in 0–1 (`red`/`green`/`blue` also accepted; a missing component is 0, but at least one must be
    /// there and nothing else may be) or `"#rrggbb"` (six hex digits), clamped to 0–1. Nil when the value is neither:
    /// a misspelled channel (`R`, `hex`) must not read as black.
    nonisolated static func color(from value: Value) -> (red: Double, green: Double, blue: Double)? {
        func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
        if let object = value.objectValue {
            guard !object.isEmpty, object.keys.allSatisfy(colorChannelKeys.contains) else { return nil }
            func component(_ short: String, _ long: String) -> Double? {
                guard let value = object[short] ?? object[long] else { return 0 }
                guard let number = value.doubleValue ?? value.intValue.map(Double.init), number.isFinite else { return nil }
                return clamp(number)
            }
            guard let red = component("r", "red"), let green = component("g", "green"), let blue = component("b", "blue") else { return nil }
            return (red, green, blue)
        }
        guard var hex = value.stringValue?.trimmingCharacters(in: .whitespaces) else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit), let rgb = UInt32(hex, radix: 16) else { return nil }
        return (Double((rgb >> 16) & 0xFF) / 255, Double((rgb >> 8) & 0xFF) / 255, Double(rgb & 0xFF) / 255)
    }
}

extension MCPValues {
    /// A text style as the text tools take it (`set_text_style`): `MCPCodable.agentForm`'s snake_case fields and
    /// alignment by name, with `box_size` as `{width, height}` (null for point text) and `horizontal_scale` null when
    /// the letters aren't stretched.
    static func textStyle(_ style: LayerTextStyle) -> Value {
        guard var fields = (try? MCPCodable.agentForm(style))?.objectValue else { return .null }
        fields["box_size"] = style.boxSize.map { .object(["width": .double(Double($0.width)), "height": .double(Double($0.height))]) } ?? .null
        fields["horizontal_scale"] = style.horizontalScale.map { .double(Double($0)) } ?? .null
        return .object(fields)
    }

    /// A shape's style as the shape tools report it: `MCPCodable.agentForm`'s snake_case fields, with the kind and the
    /// stroke's alignment by name, and a line's `start` and `end` as `{x, y}` fractions of the layer's box.
    static func shapeStyle(_ style: LayerShapeStyle) -> Value {
        guard var fields = (try? MCPCodable.agentForm(style))?.objectValue else { return .null }
        if let start = style.start { fields["start"] = point(start) }
        if let end = style.end { fields["end"] = point(end) }
        return .object(fields)
    }

    /// A smart object's contents and where they are placed: `quad` is the placement's corners in document pixels
    /// (top-left, top-right, bottom-right, bottom-left), which need not match the layer's pixels; `bytes` is null when
    /// the document doesn't hold the contents.
    static func smartObject(_ smartObject: LayerSmartObject, transform: LayerTransform) -> Value {
        let info = smartObject.info
        let quad = info.quad.documentQuad(for: transform)
        return .object([
            "file_name": .string(info.fileName),
            "file_type": .string(info.fileType.trimmingCharacters(in: .whitespaces)),
            "bytes": smartObject.payload.map { .int($0.data.count) } ?? .null,
            "natural_size": .object(["width": .double(Double(info.naturalSize.width)),
                                     "height": .double(Double(info.naturalSize.height))]),
            "quad": .array(quad.corners.map { point($0) }),
            "embedded": .bool(info.isEmbedded),
            "contents_revision": .int(info.contentsRevision),
        ])
    }
}

// MARK: - Document and layer detail (get_document)

extension MCPValues {
    /// The document as get_document reports it: canvas, format and files, the layer tree (see `layerDetail`), the
    /// selection, guides, undo state, palette colors, and whether it can be edited right now. `contentBounds` holds
    /// the document-space content boxes a full read scanned.
    static func documentDetail(_ session: EditorSession, _ document: CanvasDocument, full: Bool,
                               contentBounds: [UUID: CGRect] = [:]) -> Value {
        let byParent = Dictionary(grouping: document.layers, by: \.parentID)
        let locks = document.lockIndex
        let layers = (byParent[nil] ?? []).map {
            layerDetail($0, in: document, full: full, contentBounds: contentBounds, children: byParent, locks: locks)
        }
        var undoState = history(session)
        undoState["undo_count"] = .int(session.history.undoCount)
        return .object([
            "id": .string(document.id.uuidString),
            "width": .int(document.width),
            "height": .int(document.height),
            "resolution": .double(document.resolution),
            "format": .string(session.documentFormat.rawValue),
            "project_url": session.projectURL.map { .string($0.path) } ?? .null,
            "source_url": session.sourceURL.map { .string($0.path) } ?? .null,
            "is_modified": .bool(session.isModified),
            "layer_count": .int(document.layers.count),
            "layers": .array(layers),
            "active_layer_id": session.activeLayerID.map { .string($0.uuidString) } ?? .null,
            "selected_layer_ids": .array(session.selectedLayerIDs.sorted { $0.uuidString < $1.uuidString }.map { .string($0.uuidString) }),
            "selection": selectionState(document.selection),
            "guides": .array(document.guides.map(guide)),
            "history": .object(undoState),
            "palette": .object(["foreground": paletteColor(session.foregroundColor), "background": paletteColor(session.backgroundColor)]),
            "capabilities": capabilities(session),
        ])
    }

    /// A layer, and a folder's contents under `children`: id, name, folder path, kind, visibility, opacity, fill,
    /// blending, clipping, transform, its own `locks` and `effective_locks` (with those of the folders it is in, which
    /// hold it too), and an adjustment layer's kind as set_adjustment names it. `full` adds its drawn box, pixel size
    /// and content bounds (from `contentBounds`: a folder's covers what it shows; null when nothing is drawn),
    /// effects, text and shape settings (snake_case, as tools take them), an adjustment's settings exactly as
    /// set_adjustment reports and takes them, a smart object's contents and placement (see
    /// `smartObject(_:transform:)`), and mask details.
    /// `children` groups the document's layers by parent and `locks` indexes their locks (each computed when nil).
    static func layerDetail(_ layer: ImageLayer, in document: CanvasDocument, full: Bool,
                            contentBounds: [UUID: CGRect] = [:], children: [UUID?: [ImageLayer]]? = nil,
                            locks: LayerLockIndex? = nil) -> Value {
        let locks = locks ?? document.lockIndex
        var out: [String: Value] = [
            "id": .string(layer.id.uuidString),
            "name": .string(layer.name),
            "path": .string(MCPSelectors.path(of: layer, in: document)),
            "kind": .string(kind(of: layer)),
            "visible": .bool(layer.isVisible),
            "opacity": .double(layer.opacity),
            "fill_opacity": .double(layer.fillOpacity),
            "blend_mode": .string(layer.blendMode.rawValue),
            "clipping": .bool(layer.maskSourceID != nil),
            "transform": transform(layer.transform),
            "locks": layerLocks(layer.locks),
            "effective_locks": layerLocks(locks.locks(of: layer.id)),
        ]
        if let parentID = layer.parentID { out["parent_id"] = .string(parentID.uuidString) }
        if let placeholder = layer.psdExtras?.placeholder { out["photoshop_placeholder"] = .string(placeholder) }
        if let adjustment = layer.adjustment { out["adjustment_kind"] = .string(MCPToolRegistry.adjustmentKindName(adjustment.kind)) }
        if full {
            out["bounds"] = rect(MCPRender.box(of: layer.transform))
            out["content_bounds"] = contentBounds[layer.id].map(rect) ?? .null
            if let image = layer.asset?.image {
                out["pixel_width"] = .int(image.width)
                out["pixel_height"] = .int(image.height)
            }
            if let source = layer.maskSourceID { out["mask_source_id"] = .string(source.uuidString) }
            if let effects = layer.effects { out["effects"] = snakeCased(effects) ?? .null }
            if let shape = layer.liveShape { out["shape"] = shapeStyle(shape.style) }
            if let text = layer.liveText { out["text"] = textStyle(text.style) }
            if let adjustment = layer.adjustment { out["adjustment"] = (try? MCPToolRegistry.adjustmentSettingsValue(adjustment)) ?? .null }
            if let smartObject = layer.smartObject { out["smart_object"] = self.smartObject(smartObject, transform: layer.transform) }
            if let mask = layer.mask {
                out["mask"] = .object([
                    "enabled": .bool(mask.isEnabled),
                    "linked": .bool(mask.isLinked),
                    "bounds": rect(MCPRender.box(of: mask.placement ?? layer.transform)),
                    "pixel_width": .int(mask.asset.image.width),
                    "pixel_height": .int(mask.asset.image.height),
                ])
            }
        }
        if layer.isGroup {
            let contents = children.map { $0[layer.id] ?? [] } ?? document.layers.filter { $0.parentID == layer.id }
            out["children"] = .array(contents.map {
                layerDetail($0, in: document, full: full, contentBounds: contentBounds, children: children, locks: locks)
            })
        }
        return .object(out)
    }

    /// The locks set on a layer, by name: `transparency`, `pixels`, `position`, `artboard_nesting`, `all`.
    static func layerLocks(_ locks: LayerLocks) -> Value {
        let names: [(LayerLocks, String)] = [(.transparency, "transparency"), (.pixels, "pixels"), (.position, "position"),
                                             (.artboardNesting, "artboard_nesting"), (.all, "all")]
        return .array(names.filter { locks.contains($0.0) }.map { .string($0.1) })
    }

    /// `{r, g, b}` in 0–1 plus `hex`.
    static func paletteColor(_ color: PaletteColor) -> Value {
        func byte(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return .object([
            "r": .double(Double(color.red)),
            "g": .double(Double(color.green)),
            "b": .double(Double(color.blue)),
            "hex": .string(String(format: "#%02x%02x%02x", byte(color.red), byte(color.green), byte(color.blue))),
        ])
    }

    /// `{id, axis, position}`; position is x for a vertical guide, y for a horizontal one.
    static func guide(_ guide: CanvasGuide) -> Value {
        .object(["id": .string(guide.id.uuidString), "axis": .string(guide.axis.rawValue), "position": .double(guide.position)])
    }

    /// Whether layer and pixel edits can run right now, and what blocks them when not.
    static func capabilities(_ session: EditorSession) -> Value {
        .object([
            "can_edit_layers": .bool(session.canEditLayers),
            "can_edit_pixels": .bool(session.canEditPixels),
            "blocking_reason": MCPGuards.blockingReason(session).map { .string($0) } ?? .null,
        ])
    }

    /// `value` as JSON with snake_case keys, the spelling tools take settings in.
    static func snakeCased<T: Encodable>(_ value: T) -> Value? {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(value) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }
}

extension MCPValues {
    // MARK: Selection

    /// The longest outline `selectionState` returns as `path`, in bytes of SVG path data.
    nonisolated static let maxSelectionPathBytes = 256 * 1024

    /// The selection as every tool reports it: `{exists, empty, bounds, feather, antialiased}`, or `{exists: false}`
    /// without one, plus `path` (SVG path data) and `path_truncated` when `includePath`. `empty` marks an explicit empty
    /// selection, which edits treat as "touch nothing"; its bounds are null. Geometry is rounded to 3 decimals, below
    /// the noise path operations leave. A path longer than `maxSelectionPathBytes` stops after the last whole outline
    /// that fits, and `path_truncated` is true.
    nonisolated static func selectionState(_ selection: DocumentSelection?, includePath: Bool = false) -> Value {
        guard let selection else { return .object(["exists": .bool(false)]) }
        let box = selection.path.boundingBoxOfPath
        var out: [String: Value] = [
            "exists": .bool(true),
            "empty": .bool(selection.isEmpty),
            "bounds": selection.isEmpty ? .null : rect(CGRect(x: thousandths(box.minX), y: thousandths(box.minY),
                                                              width: thousandths(box.width), height: thousandths(box.height))),
            "feather": .double(Double(selection.feather)),
            "antialiased": .bool(selection.antialiased),
        ]
        if includePath {
            let (data, truncated) = svgPath(selection.path, limit: maxSelectionPathBytes)
            out["path"] = .string(data)
            out["path_truncated"] = .bool(truncated)
        }
        return .object(out)
    }

    /// `svgPath(_:)` of at most `limit` bytes: whole outlines (subpaths) while they fit, and whole commands of the
    /// first outline when even it doesn't. Also whether anything was left out.
    nonisolated static func svgPath(_ path: CGPath, limit: Int) -> (String, truncated: Bool) {
        let commands = svgCommands(path)
        var kept: [String] = [], outline: [String] = [], bytes = 0, outlineBytes = 0
        for command in commands {
            let size = command.utf8.count + 1
            if command.hasPrefix("M"), !outline.isEmpty {
                // The outline before it is whole: keep it if it fits, else stop.
                guard bytes + outlineBytes <= limit + 1 else { break }
                kept += outline
                bytes += outlineBytes
                outline = []
                outlineBytes = 0
            }
            outline.append(command)
            outlineBytes += size
        }
        if !outline.isEmpty, bytes + outlineBytes <= limit + 1 {
            kept += outline
            bytes += outlineBytes
            outline = []
        }
        if kept.isEmpty, !outline.isEmpty {
            // One outline too long on its own: its leading commands, up to the first that doesn't fit, so what is
            // kept is still a prefix of the path.
            for command in outline {
                guard bytes + command.utf8.count + 1 <= limit + 1 else { break }
                kept.append(command)
                bytes += command.utf8.count + 1
            }
        }
        return (kept.joined(separator: " "), kept.count < commands.count)
    }

    /// `path` as SVG path data in document pixels (`M`, `L`, `Q`, `C` and `Z`), numbers rounded to 3 decimals.
    nonisolated static func svgPath(_ path: CGPath) -> String {
        svgCommands(path).joined(separator: " ")
    }

    private nonisolated static func svgCommands(_ path: CGPath) -> [String] {
        func number(_ value: CGFloat) -> String {
            let rounded = thousandths(value)
            if rounded == rounded.rounded(), abs(rounded) < 1e15 { return String(Int(rounded)) }
            return String(rounded)
        }
        func coordinates(_ points: [CGPoint]) -> String {
            points.map { "\(number($0.x)) \(number($0.y))" }.joined(separator: " ")
        }
        var commands: [String] = []
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint: commands.append("M" + coordinates([element.points[0]]))
            case .addLineToPoint: commands.append("L" + coordinates([element.points[0]]))
            case .addQuadCurveToPoint: commands.append("Q" + coordinates([element.points[0], element.points[1]]))
            case .addCurveToPoint: commands.append("C" + coordinates([element.points[0], element.points[1], element.points[2]]))
            case .closeSubpath: commands.append("Z")
            @unknown default: break
            }
        }
        return commands
    }

    private nonisolated static func thousandths(_ value: CGFloat) -> Double { (Double(value) * 1000).rounded() / 1000 }
}
