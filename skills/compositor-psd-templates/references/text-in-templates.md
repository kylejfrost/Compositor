# Text in templates

Text slots fail in quiet ways: a long name runs off the card or wraps, a mixed-style
headline collapses to one style, a missing font swaps in Helvetica. Check each one.

## Contents

- [Point text and paragraph text](#point-text-and-paragraph-text)
- [Changing the words](#changing-the-words)
- [Keeping text inside its space](#keeping-text-inside-its-space)
- [Where edited text lands](#where-edited-text-lands)
- [Fonts](#fonts)
- [One style per layer](#one-style-per-layer)
- [Text Compositor keeps as pixels](#text-compositor-keeps-as-pixels)

## Point text and paragraph text

`get_layer` (`detail: "full"`) shows a text layer's `text`: `content`, `font_name` (a
PostScript name such as `Helvetica-Bold`), `font_size` (pixels), `color`, `alignment`
(`left`, `center`, `right`), `tracking` and `leading` (pixels; leading 0 is auto, 120% of
the size), `horizontal_scale`, and `box_size` for paragraph text.

- **Point text** (no `box_size`) is one line per `\n`, as wide as its words: the layer's
  box is the text plus 12 px of padding on every side. Longer words make it wider.
- **Paragraph text** (`box_size: {width, height}`, padding included) wraps inside a fixed
  box. Longer words make more lines; lines past the box's bottom are cut off, and
  `get_text_metrics` reports `overflows: true`.

Photoshop templates use point text for names and headlines and paragraph text for body
copy; keep whichever the designer chose.

## Changing the words

`set_text` with `layer` and `text` replaces the words and keeps style and name; one undo
step (none when the text is unchanged). `\n` starts a new line. It is refused only under
Lock All (the layer's own or a folder's); other locks leave text editable.

`set_text_style` changes style fields; only the fields given change, in the form
`get_layer` reports them. Use it for a size or color the user asked for, not to "fix" a
template's typography on your own.

## Keeping text inside its space

Decide the limit first: the template's safe area, the frame the text sits in, or the
width the original text used (`content_bounds` from `get_layer_bounds` before editing).
Then, after `set_text`, measure with `get_text_metrics` (`width`, `line_count`,
`overflows`, `font_used`; for a layer also `scale` and `bounds`).

Measure the text, not its box. `width` is the text itself, in the text's own pixels
(times `scale.x` for document pixels), and it is what `fit_text`'s `max_width` limits.
`bounds` and `box` add 12 px of padding on each side, so a name fitted to `max_width: 960`
and centered at x 540 has `bounds` from 48 to 1032 while its letters stay within 60 to
1020. Compare the limit with `width` or with `content_bounds` (the glyphs' pixels).

| The slot | Too long? | Fix |
|---|---|---|
| one-line point text (a name, a price) | `width` (× `scale.x`) wider than the limit | `fit_text` with `max_width` set to the limit: shrinks the type in 0.1 px steps, never grows it, and scales hand-set tracking and leading with it |
| multi-line point text (a headline) | a line wider than the limit | insert `\n` at a natural break, then `fit_text` if still too wide |
| paragraph text | `overflows: true` | shorten with the user, or lower `font_size` with `set_text_style` a step at a time, re-measuring |

Don't shrink below what stays legible at the delivery size (roughly 24 px for a
1080-px-wide social graphic; judge with `render_document` at the delivery size). Say when
you had to shrink, and by how much (`fit_text` returns `previous_font_size` and
`font_size`).

`fit_text` refuses paragraph text; convert to point text only when a one-line result is
really wanted (`set_text_style` with `box_size: null`).

## Where edited text lands

- **Point text keeps its alignment anchor** whenever the words change, the style changes
  or `fit_text` shrinks it: the left end, the middle or the right end of its first
  baseline, by its `alignment`. A centered name stays centered on the same x, a
  right-aligned price keeps its right edge, a left-aligned label its left edge. This holds
  for text Compositor made and for imported Photoshop text alike (imported text is
  anchored where Photoshop anchored it), so there is nothing to re-center after
  `set_text` or `fit_text`.
- **Paragraph text keeps its box's top-left** and wraps inside the box; the box doesn't
  move or grow.
- Re-align only when the design needs a different position than the anchor gives: text
  the template centered on a frame rather than on its own anchor point, or a slot the
  brief asks to move. Then `select_rect` over the frame's bounds and `align_layers` with
  `to: "selection"` and `edge: "center_x"` (clear the selection afterwards), or
  `set_layer_transform` with an `anchor`.
- Either way, compare `get_layer_bounds` (`content_bounds`) before and after, and render
  the region.

## Fonts

- `check_fonts` with a list of PostScript names says, for each, whether it is
  `available` and, when not, the `substitute` Compositor draws with and whether it is from
  the same family (`family_match`). Its `document_missing` lists the open document's text
  layers whose font is missing.
- `list_fonts` with a `query` finds installed faces (`postscript_name`, `family`,
  `style`, `weight`, `italic`); pass `postscript_name` as `font_name`.
- A template text layer whose font is missing keeps Photoshop's own pixels, so it looks
  right until you edit it; the edit redraws it in the substitute. Before editing such a
  slot, tell the user which font is missing and what would replace it; let them install it
  or approve the substitute. Don't pick a "close" font silently.
- `get_text_metrics` reports `font_used` and `font_available` after the edit; check them.

## One style per layer

A Compositor text layer has one style. Photoshop text with several style runs (a bold
first word, a second color, a smaller line) imports with its most common style, and keeps
Photoshop's pixels until edited; editing it redraws everything in that one style. Before
editing such a layer, say so; to keep emphasis, split it into two text layers (duplicate,
set each one's text and style, then align them).

## Text Compositor keeps as pixels

Some Photoshop type can't be edited as live text: settings beyond Compositor's text model
(the conversion note says so), or type data that couldn't be read. Such
layers import as pixels with a conversion note, and their `kind` is not `text`. To change
their words, recreate the text with `add_text_layer` over the old layer (matching font,
size and color from the note or the user), hide the original, and tell the user the slot
was rebuilt. Justified text imports as editable left-aligned (or centered) text, with a
note.
