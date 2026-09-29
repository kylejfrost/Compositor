import AppKit
import CoreText

/// Where the text tool's raster of a text style puts its text, measured with the same layout that draws it
/// (`EditorSession.textLayout`), for writing the style as a Photoshop type layer. Taken on the main actor, where the
/// layout and the font resolver live; the writer reads it anywhere.
nonisolated struct PSDTextMetrics: Equatable, Sendable {
    /// The raster's size in pixels (`EditorSession.textImage`).
    var size: CGSize
    /// Photoshop's text origin in the raster, in pixels: the first line's baseline at its alignment point (the left
    /// end, middle or right end) for point text, the box's top-left inside its padding for paragraph text.
    var anchor: CGPoint
    /// The widest line, in text space (before the horizontal scale).
    var lineWidth: CGFloat
    /// The font's ascent and descent (both positive).
    var ascent: CGFloat
    var descent: CGFloat
    var lineCount: Int
    /// Photoshop's `FontType`: 0 for an OpenType font with PostScript (CFF) outlines, 1 for TrueType.
    var fontType: Int
}

extension PSDTextMetrics {
    @MainActor
    static func measure(_ style: LayerTextStyle) -> PSDTextMetrics {
        let drawn = EditorSession.textMetrics(style)
        let laidOut = EditorSession.textLayout(style)
        let layout = laidOut.layout
        let glyphs = layout.glyphRange(for: laidOut.container)
        var lineCount = 0
        var lineWidth: CGFloat = 0
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
            lineCount += 1
            lineWidth = max(lineWidth, used.width)
        }
        // A final line break leaves an empty last line, which Photoshop counts too.
        if lineCount == 0 || !layout.extraLineFragmentRect.isEmpty { lineCount += 1 }
        let font = FontResolver.resolve(style.fontName, size: style.fontSize).font
        let isCFF = CTFontCopyTable(font as CTFont, CTFontTableTag(kCTFontTableCFF), []) != nil
        let anchor = style.boxSize == nil
            ? CGPoint(x: drawn.alignmentX, y: drawn.firstBaseline)
            : CGPoint(x: LayerTextStyle.padding, y: LayerTextStyle.padding)
        return PSDTextMetrics(size: drawn.size, anchor: anchor, lineWidth: lineWidth, ascent: font.ascender,
                              descent: -font.descender, lineCount: lineCount, fontType: isCFF ? 0 : 1)
    }
}
