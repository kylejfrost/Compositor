# Typography

## Contents

- [The text tools](#the-text-tools)
- [The text box, anchors and padding](#the-text-box-anchors-and-padding)
- [Point text or paragraph text](#point-text-or-paragraph-text)
- [Making text fit](#making-text-fit)
- [Type scale, leading and tracking](#type-scale-leading-and-tracking)
- [Choosing fonts](#choosing-fonts)
- [Contrast](#contrast)
- [Checking type](#checking-type)

## The text tools

| Tool | Does |
|---|---|
| `add_text_layer` | a new live text layer: `text`, `x`, `y`, `anchor`, `style`, optional `max_width` and `name`; above the active layer; returns `layer_id`, `name`, `transform`, `text` (the style and content, as `get_layer` reports them) and `metrics` |
| `set_text` | new words, same style; point text keeps its alignment anchor (the left end, middle or right end of its first baseline), paragraph text its box's top-left |
| `set_text_style` | changes only the style fields given, keeping the same anchor |
| `fit_text` | shrinks point text to a `max_width` (never grows it), keeping its anchor |
| `get_text_metrics` | measures a layer, or `text` in a `style` without adding anything |
| `list_fonts` / `check_fonts` | installed fonts; whether named fonts are available, and their substitutes |

`style` fields, as `get_layer` reports them under `text`:

| Field | Values | Default |
|---|---|---|
| `font_name` | PostScript name (`Helvetica-Bold`, `Georgia-Italic`) | Helvetica |
| `font_size` | 1–2,000 px | 72 |
| `color` | `{r, g, b}`, `"#rrggbb"`, `"foreground"`, `"background"` | the foreground color |
| `alignment` | `left`, `center`, `right` | `left` |
| `tracking` | −100 to 1,000 px added between letters | 0 |
| `leading` | 0–5,000 px baseline to baseline; 0 is auto (120% of the size) | 0 |
| `box_size` | `{width, height}` 16–30,000 px, padding included; `null` for point text | point text |
| `horizontal_scale` | 0.1–10 (1 is normal) | 1 |

Text sizes are in pixels, not points: at 72 ppi they are the same number; for print at 300
ppi, a 10 pt body is 10 × 300 / 72 ≈ 42 px.

## The text box, anchors and padding

A text layer's box is its text plus **12 px of padding on every side** (a paragraph's
`box_size` includes that padding). `add_text_layer` puts the `anchor` point of that box at
`(x, y)`:

| Wanted | `anchor` | `x`, `y` |
|---|---|---|
| glyphs start at a 64 px left margin, top of the box 200 px down | `top_left` | 52, 188 |
| centered on the canvas (1080 wide), top at 200 | `top` with `alignment: "center"` | 540, 188 |
| right edge at a 64 px right margin | `top_right` with `alignment: "right"` | 1028, 188 |
| centered in a block 300 px tall starting at y 900 | `center` | 540, 1050 |

The box's top sits above the cap height by the padding plus the font's internal leading,
so align visually with `use_content_bounds: true` when precision matters, or read
`get_text_metrics` (`lines[].baseline` is measured down from the box's top) to place a
baseline exactly.

## Point text or paragraph text

- **Point text** for headlines, names, prices, labels: one line per `\n`; you control
  every break. Width follows the words.
- **Paragraph text** (`box_size`) for body copy, captions and anything whose length you
  don't control: it wraps inside the box width; lines past the box's height are cut off
  (`overflows: true`). Size the box height generously, then check.
- Switching: `set_text_style` with a `box_size` makes point text a paragraph; `box_size:
  null` makes it point text again.

## Making text fit

| Situation | Approach |
|---|---|
| a one-line headline or name of unknown length | `add_text_layer` with `max_width` (or `fit_text`), which shrinks only when needed |
| a two-line headline | break it yourself with `\n` at a natural phrase boundary, then `fit_text` to the column width |
| body copy of unknown length | paragraph text: a fixed `box_size`, then shrink `font_size` in small steps until `overflows` is false, or ask to cut the copy |
| several labels that must match | measure the longest with `get_text_metrics` (pass `text` and `style`, nothing is added), fit that one, then give every label the same size |

Set a floor before shrinking (for a 1080 px feed post, body text under ~28 px and
headlines under ~48 px get hard to read on a phone) and tell the user when the copy needs
editing instead. `fit_text` returns `previous_font_size` and `font_size`; report them.

## Type scale, leading and tracking

- **Scale**: pick a body size, then multiply by a ratio (1.25 or 1.333) for each step up.
  For a 1080-wide post: body 32, subhead 42, headline 56–96 by length. For a story: body
  40, headline 72–120.
- **Leading**: auto is 1.2× the size. Tighten big headlines to 1.05–1.15× (`leading:
  font_size × 1.1`); open body text to 1.35–1.5×.
- **Tracking**: 0 for body. Slight negative (−1 to −2 px at 80+ px sizes) tightens large
  headlines; positive (+2 to +6 px) opens all-caps labels and small caps, which look
  cramped otherwise.
- **Line length**: 30–60 characters per line for body copy; break headlines by meaning,
  not by where the width runs out.
- **Weight and style**: one family, two weights (regular and bold) covers most layouts;
  don't set whole paragraphs in bold or italic.
- **Alignment**: left-aligned for more than two lines of text; centered only for short
  headlines and single lines; avoid justified text (Compositor doesn't justify).

## Choosing fonts

- `list_fonts` with a `query` (a family name, "bold", "condensed") returns
  `postscript_name`, `family`, `style`, `weight` (0–15: 5 regular, 9 bold) and `italic`.
- `check_fonts` before using a font you were told about: `available: false` comes with the
  `substitute` Compositor would draw with; tell the user instead of shipping it.
- Fonts macOS ships: Helvetica Neue, Avenir Next, Futura, Gill Sans, Georgia,
  Baskerville, Didot, Menlo among others; confirm with `list_fonts`. Brand fonts must be
  installed on this Mac; ask for them.

## Contrast

Relative luminance of a color with channels in 0–1:

```
linear(c) = c / 12.92                    if c ≤ 0.04045
          = ((c + 0.055) / 1.055) ^ 2.4  otherwise
L = 0.2126 · linear(r) + 0.7152 · linear(g) + 0.0722 · linear(b)
contrast = (L_lighter + 0.05) / (L_darker + 0.05)
```

Targets: 4.5:1 for body text, 3:1 for large text (about 24 px bold or 32 px regular and
up on a 1080 px graphic). Measure the real background: `sample_colors` at 9–16 points
spread over the text's `bounds` (with the text layer hidden, or `source: "layer"` on the
background layer), and use the lightest (for dark text) or darkest (for light text)
sample. Over a photo, add a scrim under the text (a black rectangle or a gradient to
transparent at 40–60% opacity) until the worst sample passes.

## Checking type

- `render_region` over each text block at full size: clipped descenders, collisions,
  odd breaks, a word alone on the last line (a widow).
- `get_text_metrics` after edits: `font_used` equals the font you asked for,
  `font_available` is true, `overflows` is false.
- `render_document` with `max_size` about 320: the headline still reads at thumbnail size.
