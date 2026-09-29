import AppKit

nonisolated enum TextAlignment: String, Codable, CaseIterable, Sendable {
    case left = "Left", center = "Center", right = "Right"
}

nonisolated struct LayerTextStyle: Codable, Equatable, Sendable {
    var content = "Text"
    var fontName = "Helvetica"
    var fontSize: CGFloat = 72
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alignment: TextAlignment = .left
    var tracking: CGFloat = 0
    /// Baseline to baseline, in layer pixels, as Photoshop's Leading is. 0 is Auto: 120% of the font size.
    var leading: CGFloat = 0
    var autoLeading: CGFloat { fontSize * 1.2 }
    var lineHeight: CGFloat { leading > 0 ? leading : autoLeading }
    /// The gap between the text and its box, in layer pixels — the same for point text and a fixed box, so turning
    /// one into the other doesn't move the text, and wide enough to leave the box's edges easy to grab.
    static let padding: CGFloat = 12
    /// Fixed paragraph bounds in layer pixels. Nil supports older point-text layers.
    var boxSize: CGSize? = nil
    /// How many times wider than its font the text is drawn (0.1…10): Photoshop type scaled unevenly. Nil is 1.
    var horizontalScale: CGFloat? = nil
    var widthScale: CGFloat { horizontalScale ?? 1 }
    var boxIsValid: Bool {
        guard let boxSize else { return true }
        return boxSize.width.isFinite && boxSize.height.isFinite && (16...DocumentLimits.maxSideExtent).contains(boxSize.width)
            && (16...DocumentLimits.maxSideExtent).contains(boxSize.height) && boxSize.width * boxSize.height <= DocumentLimits.maxSurfaceExtent
    }
    /// Letters painted in a color other than `red`/`green`/`blue`, in UTF-16 offsets into `content`, sorted and not
    /// overlapping. Nil when the whole text is one color.
    var colorRuns: [LayerTextColorRun]? = nil
    /// Letters set in a face other than `fontName`, in the same offsets. Nil when the whole text is one face.
    var fontRuns: [LayerTextFontRun]? = nil
    var isValid: Bool {
        content.utf16.count <= 100_000 && boxIsValid
        && fontSize.isFinite && (1...2000).contains(fontSize)
        && [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
        && tracking.isFinite && (-100...1000).contains(tracking)
        && leading.isFinite && (0...5000).contains(leading)
        && (horizontalScale.map { $0.isFinite && (0.1...10).contains($0) } ?? true)
        && colorRunsAreValid && fontRunsAreValid
    }
    private var colorRunsAreValid: Bool {
        guard let colorRuns else { return true }
        var end = 0
        for run in colorRuns {
            guard run.location >= end, run.length > 0, run.location <= Int.max - run.length,
                  [run.red, run.green, run.blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return false }
            end = run.location + run.length
        }
        return !colorRuns.isEmpty && end <= content.utf16.count
    }
    private var fontRunsAreValid: Bool {
        guard let fontRuns else { return true }
        var end = 0
        for run in fontRuns {
            guard run.location >= end, run.length > 0, run.location <= Int.max - run.length,
                  !run.fontName.isEmpty, run.fontName.count <= 200, !run.fontName.contains(where: \.isNewline) else { return false }
            end = run.location + run.length
        }
        return !fontRuns.isEmpty && end <= content.utf16.count
    }

    /// The color of the UTF-16 unit at `index`.
    func color(at index: Int) -> PaletteColor {
        let run = colorRuns?.first { $0.location <= index && index < $0.location + $0.length }
        return run.map { PaletteColor(red: $0.red, green: $0.green, blue: $0.blue) } ?? PaletteColor(red: red, green: green, blue: blue)
    }

    /// Paints `range` in `color`. An empty range, or one covering the whole text, recolors all of it.
    mutating func setColor(_ color: PaletteColor, in range: NSRange) {
        let count = content.utf16.count
        let start = max(0, min(range.location, count)), end = max(start, min(range.location + range.length, count))
        if start == end || (start == 0 && end == count) {
            red = color.red; green = color.green; blue = color.blue
            colorRuns = nil
            return
        }
        var colors = unitColors
        for index in start..<end { colors[index] = color }
        setUnitColors(colors)
    }

    /// The face of the UTF-16 unit at `index`.
    func fontName(at index: Int) -> String {
        fontRuns?.first { $0.location <= index && index < $0.location + $0.length }?.fontName ?? fontName
    }

    /// The one face covering `range`, or nil when that range is empty or uses more than one.
    func uniformFontName(in range: NSRange) -> String? {
        let count = content.utf16.count
        let start = max(0, min(range.location, count))
        let end = max(start, min(range.location + range.length, count))
        guard end > start else { return nil }
        let face = fontName(at: start)
        var index = start
        for run in fontRuns ?? [] where run.location < end && run.location + run.length > index {
            if run.location > index, fontName != face { return nil }
            if run.fontName != face { return nil }
            index = min(end, max(index, run.location + run.length))
        }
        if index < end, fontName != face { return nil }
        return face
    }

    /// Sets the face of `range`. An empty range, or one covering the whole text, changes all of it.
    mutating func setFont(_ name: String, in range: NSRange) {
        guard !name.isEmpty, name.count <= 200, !name.contains(where: \.isNewline) else { return }
        let count = content.utf16.count
        let start = max(0, min(range.location, count)), end = max(start, min(range.location + range.length, count))
        if start == end || (start == 0 && end == count) {
            fontName = name
            fontRuns = nil
            return
        }
        var fonts = unitFonts
        for index in start..<end { fonts[index] = name }
        setUnitFonts(fonts)
    }

    /// Keeps each letter's color and face when `range` of `content` is replaced by `length` new UTF-16 units, which
    /// take them from the letter before, as typing does. Call before `content` changes.
    mutating func replaceCharacters(in range: NSRange, withLength length: Int) {
        let count = content.utf16.count
        let start = max(0, min(range.location, count)), end = max(start, min(range.location + range.length, count))
        if colorRuns != nil {
            var colors = unitColors
            let inherited = start > 0 ? colors[start - 1] : (end > start ? colors[start] : colors.first ?? PaletteColor(red: red, green: green, blue: blue))
            colors.replaceSubrange(start..<end, with: repeatElement(inherited, count: max(0, length)))
            setUnitColors(colors)
        }
        if fontRuns != nil {
            var fonts = unitFonts
            let inherited = start > 0 ? fonts[start - 1] : (end > start ? fonts[start] : fonts.first ?? fontName)
            fonts.replaceSubrange(start..<end, with: repeatElement(inherited, count: max(0, length)))
            setUnitFonts(fonts)
        }
    }

    private var unitColors: [PaletteColor] {
        let base = PaletteColor(red: red, green: green, blue: blue)
        var colors = Array(repeating: base, count: content.utf16.count)
        for run in colorRuns ?? [] {
            let color = PaletteColor(red: run.red, green: run.green, blue: run.blue)
            for index in max(0, run.location)..<min(colors.count, run.location + run.length) { colors[index] = color }
        }
        return colors
    }

    private mutating func setUnitColors(_ colors: [PaletteColor]) {
        let base = PaletteColor(red: red, green: green, blue: blue)
        var runs: [LayerTextColorRun] = []
        for (index, color) in colors.enumerated() where color != base {
            if let last = runs.last, last.location + last.length == index,
               PaletteColor(red: last.red, green: last.green, blue: last.blue) == color {
                runs[runs.count - 1].length += 1
            } else {
                runs.append(LayerTextColorRun(location: index, length: 1, red: color.red, green: color.green, blue: color.blue))
            }
        }
        colorRuns = runs.isEmpty ? nil : runs
    }

    private var unitFonts: [String] {
        var fonts = Array(repeating: fontName, count: content.utf16.count)
        for run in fontRuns ?? [] {
            for index in max(0, run.location)..<min(fonts.count, run.location + run.length) { fonts[index] = run.fontName }
        }
        return fonts
    }

    private mutating func setUnitFonts(_ fonts: [String]) {
        if let first = fonts.first, fonts.allSatisfy({ $0 == first }) {
            fontName = first
            fontRuns = nil
            return
        }
        var runs: [LayerTextFontRun] = []
        for (index, name) in fonts.enumerated() where name != fontName {
            if let last = runs.last, last.location + last.length == index, last.fontName == name {
                runs[runs.count - 1].length += 1
            } else {
                runs.append(LayerTextFontRun(location: index, length: 1, fontName: name))
            }
        }
        fontRuns = runs.isEmpty ? nil : runs
    }
}

nonisolated struct LayerTextColorRun: Codable, Equatable, Sendable {
    var location: Int
    var length: Int
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
}

nonisolated struct LayerTextFontRun: Codable, Equatable, Sendable {
    var location: Int
    var length: Int
    var fontName: String
}

/// The cached raster participates in the existing compositor. Pixel edits rasterize the layer;
/// transforms and masks keep the source text editable, just as shape layers keep their source.
nonisolated struct LayerText: Equatable, @unchecked Sendable {
    var style: LayerTextStyle
    let image: CGImage
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.style == rhs.style && lhs.image === rhs.image }
    static func loaded(_ style: LayerTextStyle?, image: CGImage?) -> LayerText? {
        guard let style, style.isValid, let image else { return nil }
        return LayerText(style: style, image: image)
    }
}

extension ImageLayer {
    var liveText: LayerText? {
        guard let text, let image = asset?.image, image === text.image else { return nil }
        return text
    }
}

/// Why a text command (`addTextLayer`, `updateTextStyle`, `fitText`) did nothing.
nonisolated enum TextLayerError: LocalizedError, Equatable {
    /// Layer edits aren't allowed right now: another edit (text being typed, say) holds the document.
    case notEditable
    /// The layer isn't live text: not text at all, or text whose pixels have been changed since it was drawn.
    case notText
    /// Paragraph text: its box sets its width, so it can't be fitted by shrinking the type.
    case paragraphText
    /// Even 1-pixel type is `minimumWidth` pixels wide, wider than the width asked for.
    case cannotFit(minimumWidth: CGFloat)

    var errorDescription: String? {
        switch self {
        case .notEditable: "The document can't be edited right now."
        case .notText: "That layer isn't editable text."
        case .paragraphText: "Paragraph text wraps to its box; only point text can be fitted to a width."
        case .cannotFit(let width): "Even 1-pixel type is \(Int(width.rounded(.up))) pixels wide."
        }
    }
}

struct TextDraft: Identifiable {
    let id = UUID()
    let documentID: UUID
    let layerID: UUID?
    var origin: CGPoint
    var transform: LayerTransform? = nil
    var style: LayerTextStyle
    /// What is selected in the on-canvas editor, in UTF-16 offsets into `style.content`. Color and font apply to it.
    var selection = NSRange(location: 0, length: 0)
}

extension EditorSession {
    func beginText(at point: CGPoint, newLayer: Bool = false) {
        guard canEditLayers, textDraft == nil, let document, point.x.isFinite, point.y.isFinite else { return }
        let visible = document.effectiveVisibleIDs
        let target = newLayer ? nil : document.layers.reversed().first {
            visible.contains($0.id) && $0.liveText != nil && $0.transform.contains(point)
        }
        // Lock All holds a text layer's text, as it does for the MCP text tools.
        if let target, !unlocked([target.id], for: .all) { return }
        if let target { selectLayer(target.id) }
        var style = target?.liveText?.style ?? textDefaults
        if target == nil {
            style.content = ""
            style.colorRuns = nil
            style.fontRuns = nil
            // New text starts in the foreground color, the same as every other tool that lays down color.
            if !isMaskSelected {
                style.red = foregroundColor.red; style.green = foregroundColor.green; style.blue = foregroundColor.blue
            }
            // A click makes point text: no box of its own, so what is typed decides how big the layer is. Dragging
            // a box out instead (beginText(in:)) sets boxSize, and so does resizing one by its handles.
            style.boxSize = nil
        }
        tool = .type
        // A click puts new text's first baseline on the pointer, starting at it, as Photoshop's does. A fixed line height
        // leaves its extra room above the letters, so the baseline sits the font's descent up from the bottom of the line.
        // Text already on the canvas opens where it is (`draftPlacement`), so an edit keeps its anchor.
        let placement = target.map { draftPlacement(for: $0, style: style) }
        let descent = abs((Self.textAttributes(style)[.font] as? NSFont)?.descender ?? 0)
        let baseline = LayerTextStyle.padding + style.lineHeight - descent
        let origin = placement?.origin ?? CGPoint(x: point.x - LayerTextStyle.padding, y: point.y - baseline)
        textDraft = TextDraft(documentID: document.id, layerID: target?.id, origin: origin,
                              transform: placement?.transform, style: style)
    }

    func editActiveText() {
        guard canEditLayers, textDraft == nil, let document, let layer = activeLayer, let text = layer.liveText,
              unlocked([layer.id], for: .all) else { return }
        tool = .type
        let placement = draftPlacement(for: layer, style: text.style)
        textDraft = TextDraft(documentID: document.id, layerID: layer.id, origin: placement.origin, transform: placement.transform,
                              style: text.style)
    }

    /// Where a draft on `layer` is shown: on the layer, except while imported Photoshop text still waits for its first
    /// edit on a layer drawn 1:1 and upright — then where that edit will put the new text (see `importedTextPlacement`).
    private func draftPlacement(for layer: ImageLayer, style: LayerTextStyle) -> (origin: CGPoint, transform: LayerTransform?) {
        let t = layer.transform
        if let asset = layer.asset, t.rotation == 0, !t.flipX, !t.flipY,
           abs(t.size.width - CGFloat(asset.image.width)) < 0.5, abs(t.size.height - CGFloat(asset.image.height)) < 0.5,
           let placed = Self.importedTextPlacement(for: layer, style: style) {
            return (placed.origin, nil)
        }
        return (layer.origin, layer.transform)
    }

    /// Where a new raster of `style` goes on a layer still showing imported Photoshop text: with the layer's scale,
    /// rotation and flips, placed so that its first baseline at the alignment point (point text) or its box's top-left
    /// (paragraph text) lands on `importedTextAnchor`, where Photoshop put it. Nil once the anchor has been used.
    ///
    /// The anchor is a point of the kind of text Photoshop had. When `style` is the other kind (point text made a
    /// box, or a box made point text), the layer's own text is placed by it instead, and the new raster keeps that
    /// top-left corner, as making a box with the editor's handles does. Nil when that can't be worked out.
    static func importedTextPlacement(for layer: ImageLayer, style: LayerTextStyle) -> LayerTransform? {
        guard let anchor = layer.psdExtras?.importedTextAnchor, let asset = layer.asset else { return nil }
        let base = layer.transform
        let pixelSize = CGSize(width: asset.image.width, height: asset.image.height)
        let target = base.documentPoint(ofUnit: anchor)
        let current = layer.liveText?.style
        let importedIsBox = layer.psdExtras?.importedTextIsBox ?? (current?.boxSize != nil)
        guard (style.boxSize != nil) != importedIsBox else { return textPlacement(style, at: target, on: base, pixelSize: pixelSize) }
        guard let current, (current.boxSize != nil) == importedIsBox,
              var placed = textPlacement(current, at: target, on: base, pixelSize: pixelSize) else { return nil }
        let raster = textBoxSize(style)
        let corner = placed.point(.zero)
        placed.size = CGSize(width: ceil(raster.width) * base.size.width / pixelSize.width,
                             height: ceil(raster.height) * base.size.height / pixelSize.height)
        let moved = placed.point(.zero)
        placed.origin.x += corner.x - moved.x
        placed.origin.y += corner.y - moved.y
        return placed.isValid ? placed : nil
    }

    /// Where point text drawn again as `style` goes on `layer`, which shows point text now: with the layer's scale,
    /// rotation and flips, hanging from the point the layer's text hangs from (see `textAnchor`), as Photoshop keeps a
    /// point-text layer's anchor through an edit. Left-aligned text keeps the left end of its first baseline, centered
    /// text its middle and right-aligned text its right end, so a longer centered line grows both ways. Nil when either
    /// is paragraph text, which keeps its box's top-left corner instead, or when that isn't a valid placement.
    static func anchoredTextPlacement(for layer: ImageLayer, style: LayerTextStyle) -> LayerTransform? {
        guard style.boxSize == nil, let current = layer.liveText, current.style.boxSize == nil,
              current.image.width > 0, current.image.height > 0 else { return nil }
        let pixelSize = CGSize(width: current.image.width, height: current.image.height)
        let local = textAnchor(current.style)
        let target = layer.transform.documentPoint(ofUnit: CGPoint(x: local.x / pixelSize.width, y: local.y / pixelSize.height))
        return textPlacement(style, at: target, on: layer.transform, pixelSize: pixelSize)
    }

    /// Where a raster of `style` goes so that its anchor (see `textAnchor`) lands on the document point `target`: with
    /// `base`'s rotation and flips, and the scale `base` gives pixels of `pixelSize`. Nil when that isn't a valid
    /// placement.
    static func textPlacement(_ style: LayerTextStyle, at target: CGPoint, on base: LayerTransform,
                              pixelSize: CGSize) -> LayerTransform? {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let metrics = textMetrics(style)
        guard metrics.size.width > 0, metrics.size.height > 0 else { return nil }
        var transform = base
        transform.size = CGSize(width: metrics.size.width * base.size.width / pixelSize.width,
                                height: metrics.size.height * base.size.height / pixelSize.height)
        let local = textAnchor(style, metrics: metrics)
        let placed = transform.documentPoint(ofUnit: CGPoint(x: local.x / metrics.size.width, y: local.y / metrics.size.height))
        transform.origin.x += target.x - placed.x
        transform.origin.y += target.y - placed.y
        return transform.isValid ? transform : nil
    }

    /// The point of `style`'s raster its text hangs from, in raster pixels: the first baseline at the alignment point
    /// for point text, the text area's top-left corner (inside the padding) for paragraph text.
    static func textAnchor(_ style: LayerTextStyle, metrics: (size: CGSize, firstBaseline: CGFloat, alignmentX: CGFloat)? = nil) -> CGPoint {
        guard style.boxSize == nil else { return CGPoint(x: LayerTextStyle.padding, y: LayerTextStyle.padding) }
        let metrics = metrics ?? textMetrics(style)
        return CGPoint(x: metrics.alignmentX, y: metrics.firstBaseline)
    }

    /// Where the editor on the canvas shows `draft` while it is `size` (its box, or what its point text measures now):
    /// exactly where committing it will put it (see `applyText`). Imported Photoshop text still waiting for its first
    /// edit grows around the point Photoshop anchored it by, and other point text around its own anchor (see
    /// `anchoredTextPlacement`); point text moved in the editor grows from its top-left corner. Each keeps the layer's
    /// scale, rotation and flips.
    func textDraftTransform(_ draft: TextDraft, size: CGSize) -> LayerTransform {
        var transform = draft.transform ?? LayerTransform(origin: draft.origin, size: size)
        guard let layer = document?.layers.first(where: { $0.id == draft.layerID }) else { return transform }
        if draft.transform == nil || draft.transform == layer.transform,
           let placed = Self.importedTextPlacement(for: layer, style: draft.style)
            ?? Self.anchoredTextPlacement(for: layer, style: draft.style) {
            return placed
        }
        if draft.style.boxSize == nil, draft.transform != nil, let asset = layer.asset, asset.image.width > 0 {
            let factor = transform.size.width / CGFloat(asset.image.width)
            // A rotated layer turns about its center, so growing it swings its corner away and the text drifts as it
            // is typed. The top-left corner is put back where it was, which is where the commit leaves it too.
            let anchor = transform.point(.zero)
            transform.size = CGSize(width: size.width * factor, height: size.height * factor)
            let moved = transform.point(.zero)
            transform.origin.x += anchor.x - moved.x
            transform.origin.y += anchor.y - moved.y
        }
        return transform
    }

    @discardableResult
    func applyText(_ draft: TextDraft) -> Bool {
        guard document?.id == draft.documentID, draft.style.isValid else { return false }
        let pending = textDraft
        textDraft = nil
        guard canEditLayers else { textDraft = pending; return false }
        var succeeded = false
        defer { if !succeeded { textDraft = pending } }
        if draft.layerID == nil, draft.style.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            succeeded = true
            return true
        }
        do {
            if let id = draft.layerID {
                guard let layer = document?.layers.first(where: { $0.id == id }), let text = layer.liveText,
                      unlocked([id], for: .all) else { return false }
                // Closed without a change: nothing to draw, and the Type tool keeps its settings.
                if text.style == draft.style && (draft.transform == nil || draft.transform == layer.transform) {
                    succeeded = true
                    return true
                }
                guard try redrawText(id, style: draft.style, transform: draft.transform, name: "Edit Text") else { return false }
            } else {
                _ = try addTextLayer(draft.style, at: draft.origin)
            }
            succeeded = true
            textDefaults = draft.style
            textDefaults.colorRuns = nil
            textDefaults.fontRuns = nil
            textDraft = nil
            canvasFocusRequest += 1
            return true
        } catch {
            brushError = error.localizedDescription
            return false
        }
    }

    /// Adds a text layer drawing `style` with its top-left corner at `origin`, above the active layer (at the top of it
    /// when it is a folder), makes it active, and returns its id. One "New Text Layer" undo step; the Type tool's own
    /// settings are left as they are.
    func addTextLayer(_ style: LayerTextStyle, at origin: CGPoint) throws -> UUID {
        guard canEditLayers, document != nil else { throw TextLayerError.notEditable }
        guard style.isValid else { throw ProjectError.invalid }
        let image = try Self.textImage(style)
        guard LayerTransform(origin: origin, size: CGSize(width: image.width, height: image.height)).isValid else {
            throw ProjectError.tooLarge
        }
        let before = activeLayerID
        addPixelLayer(image, at: origin, name: Self.layerName(for: style.content), editName: "New Text Layer",
                      dropsSelection: false, text: LayerText(style: style, image: image))
        guard let id = activeLayerID, id != before, document?.layers.contains(where: { $0.id == id }) == true else {
            throw ExportError.render
        }
        return id
    }

    /// Changes a live text layer's style with `change` and draws it again, placed as the Type tool places an edit: point
    /// text keeps its alignment anchor (see `anchoredTextPlacement`; imported Photoshop text the anchor Photoshop gave
    /// it, the first time), paragraph text its box's top-left corner. One "Edit Text" undo step, none when nothing
    /// changes; the Type tool's own settings are left as they are.
    func updateTextStyle(_ id: UUID, _ change: (inout LayerTextStyle) -> Void) throws {
        let original = try liveTextStyle(id)
        var style = original
        change(&style)
        // Letters colored on their own (`colorRuns`) keep those colors only while they are the same letters in the same
        // text color: new content, or a new color for the whole text, colors all of it, as the app's color swatch does,
        // unless the change set its own runs.
        if original.colorRuns != nil, style.colorRuns == original.colorRuns,
           style.content != original.content || style.red != original.red || style.green != original.green || style.blue != original.blue {
            style.colorRuns = nil
        }
        guard style.isValid else { throw ProjectError.invalid }
        guard try redrawText(id, style: style, transform: nil, name: "Edit Text") else { throw TextLayerError.notText }
    }

    /// Shrinks a live point-text layer's type until its text is at most `maxWidth` layer pixels wide (see
    /// `fittedTextStyle`) and returns the font size it ends at, keeping its alignment anchor as `updateTextStyle` does.
    /// One "Fit Text" undo step, none when it already fits. Paragraph text, whose box sets its width, throws
    /// `TextLayerError.paragraphText`.
    @discardableResult
    func fitText(_ id: UUID, maxWidth: CGFloat) throws -> CGFloat {
        let style = try liveTextStyle(id)
        let fitted = try Self.fittedTextStyle(style, maxWidth: maxWidth)
        guard fitted != style else { return style.fontSize }
        guard try redrawText(id, style: fitted, transform: nil, name: "Fit Text") else { throw TextLayerError.notText }
        return fitted.fontSize
    }

    /// `style` at the largest size, in steps of 0.1 pixel between 1 and its own, whose text is at most `maxWidth` wide:
    /// its point-text box less the padding either side. Leading set by hand and tracking scale with the size, so the
    /// lines and letters keep their proportions. `style` itself when it already fits.
    static func fittedTextStyle(_ style: LayerTextStyle, maxWidth: CGFloat) throws -> LayerTextStyle {
        guard style.boxSize == nil else { throw TextLayerError.paragraphText }
        func sized(_ size: CGFloat) -> LayerTextStyle {
            var sized = style
            let factor = size / style.fontSize
            sized.fontSize = size
            sized.leading = style.leading * factor
            sized.tracking = style.tracking * factor
            return sized
        }
        func width(_ style: LayerTextStyle) -> CGFloat { textBoxSize(style).width - 2 * LayerTextStyle.padding }
        guard maxWidth.isFinite else { throw ProjectError.invalid }
        if width(style) <= maxWidth { return style }
        let smallest = width(sized(1))
        guard smallest <= maxWidth else { throw TextLayerError.cannotFit(minimumWidth: smallest) }
        // Tenths of a pixel: the largest that fits, between 1 (which does) and just below the current size (which doesn't).
        var low = 10, high = max(10, Int((style.fontSize * 10).rounded(.up)) - 1)
        while low < high {
            let middle = (low + high + 1) / 2
            if width(sized(CGFloat(middle) / 10)) <= maxWidth { low = middle } else { high = middle - 1 }
        }
        let fitted = sized(CGFloat(low) / 10)
        guard fitted.isValid else { throw ProjectError.invalid }
        return fitted
    }

    /// The style of the live text layer `id`, once layer edits are allowed.
    private func liveTextStyle(_ id: UUID) throws -> LayerTextStyle {
        guard canEditLayers else { throw TextLayerError.notEditable }
        guard let style = document?.layers.first(where: { $0.id == id })?.liveText?.style else { throw TextLayerError.notText }
        return style
    }

    /// Draws `style` again on the live text layer `id` as one undo step named `name`: nothing when it is what the layer
    /// shows and `draftTransform` (the transform the editor left, or nil) doesn't move it. False when the layer is gone
    /// or no longer live text.
    private func redrawText(_ id: UUID, style: LayerTextStyle, transform draftTransform: LayerTransform?, name: String) throws -> Bool {
        guard let index = document?.layers.firstIndex(where: { $0.id == id }),
              let layer = document?.layers[index], layer.liveText != nil, let asset = layer.asset else { return false }
        if layer.liveText?.style == style && (draftTransform == nil || draftTransform == layer.transform) { return true }
        let image = try Self.textImage(style)
        let thumbnail = try PixelInvert.thumbnail(of: image)
        var transform = draftTransform ?? layer.transform
        // Keep the user's scale, rotation and flips. Point text keeps its anchor, as in Photoshop (imported
        // Photoshop text the one Photoshop gave it, the first time it is drawn again); paragraph text, text turned
        // from one kind into the other, and a draft that was moved or resized keep the transformed upper-left corner.
        let anchor = transform.point(.zero)
        if draftTransform == nil || draftTransform == layer.transform,
           let placed = Self.importedTextPlacement(for: layer, style: style) ?? Self.anchoredTextPlacement(for: layer, style: style) {
            transform = placed
        } else if draftTransform == nil || style.boxSize == nil {
            transform.size = CGSize(width: CGFloat(image.width) * transform.size.width / CGFloat(asset.image.width),
                                    height: CGFloat(image.height) * transform.size.height / CGFloat(asset.image.height))
            let moved = transform.point(.zero)
            transform.origin.x += anchor.x - moved.x
            transform.origin.y += anchor.y - moved.y
        }
        guard transform.isValid else { throw ProjectError.tooLarge }
        finishOpacityEdit()
        beginEdit(name)
        if layer.mask?.placement == nil { document?.layers[index].mask?.placement = layer.maskTransform }
        document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
        document?.layers[index].text = LayerText(style: style, image: image)
        document?.layers[index].transform = transform
        document?.layers[index].psdExtras?.importedTextAnchor = nil
        endEdit()
        return true
    }

    @discardableResult
    func finishText() -> Bool {
        guard let draft = textDraft else { return true }
        return applyText(draft)
    }

    func cancelText() { textDraft = nil; canvasFocusRequest += 1 }

    func beginText(in rect: CGRect) {
        guard canEditLayers, textDraft == nil, rect.width.isFinite, rect.height.isFinite else { return }
        var style = textDefaults
        style.boxSize = CGSize(width: max(16, rect.width.rounded()), height: max(16, rect.height.rounded()))
        guard style.boxIsValid else { brushError = "That text box exceeds the \(DocumentLimits.maxSide.formatted())-pixel or \(DocumentLimits.maxSurfaceMegapixels)-megapixel limit."; return }
        beginText(at: rect.origin, newLayer: true)
        // A dragged box is exactly where it was drawn.
        textDraft?.origin = rect.origin
        textDraft?.style.boxSize = style.boxSize
    }

    /// Paints a text layer's letters in `color`, keeping it editable text. Used by Fill with Foreground/Background;
    /// false when the layer isn't live text or its pixels couldn't be redrawn, so the caller fills as usual.
    @discardableResult
    func recolorText(_ id: UUID, to color: PaletteColor) -> Bool {
        guard canEditLayers, unlocked([id], for: .all), let index = document?.layers.firstIndex(where: { $0.id == id }),
              let layer = document?.layers[index], let text = layer.liveText, let asset = layer.asset else { return false }
        var style = text.style
        guard style.red != color.red || style.green != color.green || style.blue != color.blue || style.colorRuns != nil else { return true }
        style.setColor(color, in: NSRange(location: 0, length: 0))
        guard style.isValid, let image = try? Self.textImage(style), let thumbnail = try? PixelInvert.thumbnail(of: image) else { return false }
        // Imported Photoshop text drawn for the first time goes where Photoshop put it.
        let placed = Self.importedTextPlacement(for: layer, style: style)
        finishOpacityEdit()
        beginEdit("Fill Text")
        if let placed {
            if layer.mask?.placement == nil { document?.layers[index].mask?.placement = layer.maskTransform }
            document?.layers[index].transform = placed
            document?.layers[index].psdExtras?.importedTextAnchor = nil
        }
        document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
        document?.layers[index].text = LayerText(style: style, image: image)
        endEdit()
        return true
    }

    /// After Image Size, inside its undo step: each live text layer whose type the resize scaled (see
    /// `LayerTextStyle.scaled`) is typeset again at its new size instead of showing its old pixels resampled, which
    /// blurs them. Its letters stay where the resize put them: the new raster hangs from the same point (see
    /// `textAnchor`), scaled from where it was in `old`. Imported Photoshop text still waiting for its first edit keeps
    /// Photoshop's pixels, and a layer that can't be drawn again keeps its resampled ones.
    func redrawScaledText(from old: CanvasDocument) {
        guard let layers = document?.layers, layers.contains(where: { $0.liveText != nil }) else { return }
        let before = Dictionary(old.layers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, layer) in layers.enumerated() {
            guard let text = layer.liveText, layer.psdExtras?.importedTextAnchor == nil, let asset = layer.asset,
                  let previous = before[layer.id], let oldText = previous.liveText, oldText.style != text.style,
                  let oldAsset = previous.asset, oldAsset.image.width > 0, oldAsset.image.height > 0 else { continue }
            let local = Self.textAnchor(oldText.style)
            let target = layer.transform.documentPoint(ofUnit: CGPoint(x: local.x / CGFloat(oldAsset.image.width),
                                                                       y: local.y / CGFloat(oldAsset.image.height)))
            guard let image = try? Self.textImage(text.style), let thumbnail = try? PixelInvert.thumbnail(of: image),
                  let placed = Self.textPlacement(text.style, at: target, on: layer.transform,
                                                  pixelSize: CGSize(width: asset.image.width, height: asset.image.height)) else { continue }
            // A mask on the layer's own pixels stays where the resize left it.
            if layer.mask?.placement == nil { document?.layers[index].mask?.placement = layer.maskTransform }
            document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
            document?.layers[index].text = LayerText(style: text.style, image: image)
            document?.layers[index].transform = placed
        }
    }

    var currentTextStyle: LayerTextStyle { textDraft?.style ?? activeLayer?.liveText?.style ?? textDefaults }

    /// While the font menu is open, the text being edited shows the face under the pointer; `endFontPreview` puts it
    /// back. Only text already being edited: a selected text layer isn't opened for a preview.
    func previewFont(_ name: String) {
        guard var draft = textDraft else { return }
        let original = fontPreviewOriginal ?? draft.style
        fontPreviewOriginal = original
        var style = original
        style.setFont(name, in: draft.selection)
        guard style.isValid, style != draft.style else { return }
        draft.style = style
        textDraft = draft
    }
    /// The previewed face was chosen: keep the text as it shows, rather than putting it back and applying it again.
    func keepFontPreview() { fontPreviewOriginal = nil }
    func endFontPreview() {
        guard let original = fontPreviewOriginal else { return }
        fontPreviewOriginal = nil
        if var draft = textDraft, draft.style != original { draft.style = original; textDraft = draft }
    }

    func changeTextStyle(_ change: (inout LayerTextStyle) -> Void) {
        if textDraft == nil, activeLayer?.liveText != nil { editActiveText() }
        if var draft = textDraft {
            change(&draft.style)
            guard draft.style.isValid else { return }
            textDraft = draft
        } else {
            var style = textDefaults
            change(&style)
            if style.isValid { textDefaults = style }
        }
    }

    /// Live text layers whose font isn't installed: what they asked for and what `FontResolver`
    /// is standing in with, for a conversion report or a one-time warning.
    func missingFonts() -> [(layerID: UUID, layerName: String, requested: String, resolved: String)] {
        guard let document else { return [] }
        return document.layers.compactMap { layer in
            guard let text = layer.liveText else { return nil }
            let resolved = FontResolver.resolve(text.style.fontName, size: text.style.fontSize)
            guard resolved.isSubstitute else { return nil }
            let name = resolved.font.displayName ?? resolved.font.fontName
            return (layerID: layer.id, layerName: layer.name, requested: text.style.fontName, resolved: name)
        }
    }

    /// A text layer's name: its first words on one line. Line breaks and runs of spaces become single spaces, so a
    /// paragraph never makes the row in the Layers panel taller than one line.
    static func layerName(for content: String) -> String {
        let flattened = content.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return flattened.isEmpty ? "Text" : String(flattened.prefix(40))
    }

    /// How `style` is typeset: in the text's own space, which `textImage` stretches by the horizontal scale as it
    /// draws. `widthScaled` sets the letters and tracking already stretched instead, for a text view that draws them
    /// as they are (the editor on the canvas), so its lines are as wide, and break where, the layer's do.
    static func textAttributes(_ style: LayerTextStyle, widthScaled: Bool = false) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.alignment == .left ? .left : style.alignment == .center ? .center : .right
        // Leading is the line's whole height, so the lines close up (and eventually overlap) as it comes down,
        // exactly as Photoshop's does. Auto is 120% of the size.
        paragraph.minimumLineHeight = style.lineHeight
        paragraph.maximumLineHeight = style.lineHeight
        paragraph.lineBreakMode = .byWordWrapping
        var font = FontResolver.resolve(style.fontName, size: style.fontSize).font
        var tracking = style.tracking
        let scale = style.widthScale
        if widthScaled, scale != 1 {
            let stretch = AffineTransform(m11: scale * style.fontSize, m12: 0, m21: 0, m22: style.fontSize, tX: 0, tY: 0)
            font = NSFont(descriptor: font.fontDescriptor, textTransform: stretch) ?? font
            tracking *= scale
        }
        return [.font: font,
                .foregroundColor: NSColor(srgbRed: style.red, green: style.green, blue: style.blue, alpha: 1),
                .paragraphStyle: paragraph, .kern: tracking]
    }

    /// How big point text is: what it measures, plus its padding. A caret's worth of width so an empty line still
    /// has somewhere to type.
    static func textBoxSize(_ style: LayerTextStyle) -> CGSize {
        if let boxSize = style.boxSize { return boxSize }
        let string = attributedText(style)
        let padding = LayerTextStyle.padding
        let measured = string.boundingRect(with: CGSize(width: 100_000, height: 100_000),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading])
        let line = ceil(style.lineHeight)
        let scale = style.widthScale
        return CGSize(width: max(16, ceil(measured.width * scale + padding * 2 + style.fontSize * 0.1 * scale)),
                      height: max(16, ceil(max(measured.height, line) + padding * 2)))
    }

    /// The text as it is drawn and measured, with each letter's own face and color.
    static func attributedText(_ style: LayerTextStyle) -> NSMutableAttributedString {
        let string = NSMutableAttributedString(string: style.content, attributes: textAttributes(style))
        for run in style.fontRuns ?? [] where Self.containsTextRun(run.location, run.length, in: string.length) {
            let font = NSFont(name: run.fontName, size: style.fontSize) ?? NSFont.systemFont(ofSize: style.fontSize)
            string.addAttribute(.font, value: font, range: NSRange(location: run.location, length: run.length))
        }
        for run in style.colorRuns ?? [] where Self.containsTextRun(run.location, run.length, in: string.length) {
            string.addAttribute(.foregroundColor, value: NSColor(srgbRed: run.red, green: run.green, blue: run.blue, alpha: 1),
                                range: NSRange(location: run.location, length: run.length))
        }
        return string
    }

    static func containsTextRun(_ location: Int, _ length: Int, in total: Int) -> Bool {
        length > 0 && location >= 0 && location <= total - length
    }

    /// The raster size and text layout in the unstretched text space.
    static func textLayout(_ style: LayerTextStyle) -> (size: CGSize, storage: NSTextStorage, layout: NSLayoutManager, container: NSTextContainer) {
        let string = attributedText(style)
        let padding = LayerTextStyle.padding
        let measured = textBoxSize(style)
        let width = ceil(measured.width), height = ceil(measured.height)
        let storage = NSTextStorage(attributedString: string)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, (width - 2 * padding) / style.widthScale), height: max(1, height - 2 * padding)))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        return (CGSize(width: width, height: height), storage, layout, container)
    }

    static func textImage(_ style: LayerTextStyle) throws -> CGImage {
        guard style.isValid else { throw ProjectError.invalid }
        let laidOut = textLayout(style)
        let padding = LayerTextStyle.padding
        let width = laidOut.size.width, height = laidOut.size.height
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
              width <= DocumentLimits.maxSideExtent, height <= DocumentLimits.maxSideExtent, width * height <= DocumentLimits.maxSurfaceExtent else { throw ProjectError.tooLarge }
        let context = try BrushRaster.context(width: Int(width), height: Int(height), mask: false)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        // Unevenly scaled Photoshop type is drawn wider (or narrower) than its font.
        let scale = style.widthScale
        if scale != 1 { context.scaleBy(x: scale, y: 1) }
        let glyphs = laidOut.layout.glyphRange(for: laidOut.container)
        laidOut.layout.drawGlyphs(forGlyphRange: glyphs, at: CGPoint(x: padding / scale, y: padding))
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }

    /// Where `textImage` puts the text, in raster pixels: the raster's size, the first line's baseline, and the first
    /// line's alignment point (its left end, middle or right end, as the text is aligned).
    static func textMetrics(_ style: LayerTextStyle) -> (size: CGSize, firstBaseline: CGFloat, alignmentX: CGFloat) {
        let laidOut = textLayout(style)
        let padding = LayerTextStyle.padding
        let layout = laidOut.layout
        let glyphs = layout.glyphRange(for: laidOut.container)
        var fragment = layout.extraLineFragmentRect
        var baseline: CGFloat
        if glyphs.length > 0 {
            fragment = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            baseline = fragment.minY + layout.location(forGlyphAt: glyphs.location).y
        } else {
            // Nothing typed: the line's bottom less the font's descent.
            let font = FontResolver.resolve(style.fontName, size: style.fontSize).font
            if fragment.isEmpty { fragment = CGRect(x: 0, y: 0, width: laidOut.container.size.width, height: style.lineHeight) }
            baseline = fragment.maxY + font.descender
        }
        let x = switch style.alignment {
        case .left: fragment.minX
        case .center: fragment.midX
        case .right: fragment.maxX
        }
        return (laidOut.size, padding + baseline, padding + x * style.widthScale)
    }

    /// One line `textImage` draws: its text (without the line break), its width and its baseline's distance from the
    /// raster's top, in raster pixels.
    struct TextLine: Equatable {
        let text: String
        let width: CGFloat
        let baseline: CGFloat
    }

    /// How `textImage` lays `style` out, in raster pixels: the text's own size (its widest line, and its lines from
    /// the first one's top to the last one's bottom, without the padding), each line, and whether a paragraph's box
    /// cuts text off (point text never does).
    static func textLayoutMetrics(_ style: LayerTextStyle) -> (size: CGSize, lines: [TextLine], overflows: Bool) {
        let laidOut = textLayout(style)
        let layout = laidOut.layout, scale = style.widthScale, padding = LayerTextStyle.padding
        let glyphs = layout.glyphRange(for: laidOut.container)
        let text = laidOut.storage.string as NSString
        var lines: [TextLine] = []
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, used, _, range, _ in
            let characters = layout.characterRange(forGlyphRange: range, actualGlyphRange: nil)
            let line = text.substring(with: characters).trimmingCharacters(in: .newlines)
            let baseline = padding + rect.minY + layout.location(forGlyphAt: range.location).y
            lines.append(TextLine(text: line, width: used.width * scale, baseline: baseline))
        }
        let used = layout.usedRect(for: laidOut.container)
        return (CGSize(width: used.width * scale, height: used.height), lines, NSMaxRange(glyphs) < layout.numberOfGlyphs)
    }
}

extension LayerTransform {
    /// A point of the layer's own pixels, as a fraction of their size, in the document. Flips mirror it about the
    /// middle, the way the layer's pixels are drawn.
    nonisolated func documentPoint(ofUnit unit: CGPoint) -> CGPoint {
        point(CGPoint(x: flipX ? 1 - unit.x : unit.x, y: flipY ? 1 - unit.y : unit.y))
    }

    /// The document point `point` as a fraction of the layer's own pixels: the inverse of `documentPoint(ofUnit:)`.
    nonisolated func unit(of point: CGPoint) -> CGPoint {
        let x = point.x - center.x, y = point.y - center.y
        let u = (x * cos(radians) + y * sin(radians)) / size.width + 0.5
        let v = (-x * sin(radians) + y * cos(radians)) / size.height + 0.5
        return CGPoint(x: flipX ? 1 - u : u, y: flipY ? 1 - v : v)
    }
}
