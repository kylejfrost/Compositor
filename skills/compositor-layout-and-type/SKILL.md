---
name: compositor-layout-and-type
description: Design graphics in Compositor from scratch, or fix the layout of an existing one (misaligned or off-center elements, uneven spacing, cramped margins, weak hierarchy, text that runs over). Pick the canvas (feed 1080x1350, square 1080x1080, story 1080x1920, landscape 1200x628, print at 300 ppi with bleed), set margins and guides, add and fit text (point vs paragraph, anchors, fit_text, leading, tracking, fonts), draw shapes and lines, place photos with cover or contain and clip them to frames, align and distribute layers, add effects, sample and reuse brand colors, and check legibility and contrast at the size people will see. Use whenever the user asks Compositor to design, compose, lay out or typeset a social post, story, banner, ad, quote card, thumbnail, flyer, poster or announcement, or to fix spacing, alignment, hierarchy or text that doesn't fit, even if they never name a tool.
---

# Compositor layout and type

Good layouts come from a plan made in numbers: a canvas, margins, a grid, a type scale,
two or three colors. Decide those first, then place every element against them, and
verify with renders at the size the audience will see. Read the **compositor** skill
first for selectors, coordinates (y grows downward) and the render-and-verify loop.

The order: plan the canvas (1), set up the document (2), build back to front (3–6), then
**check it like a viewer would (7) before exporting**. That last step is the one that
gets skipped once a design looks right at 1024 px, and it is where a feed post fails:
people see it at about 320 px in a grid, where a thin headline disappears.

## 1. Plan the canvas

| Deliverable | Size (px) | Ratio | Keep clear |
|---|---|---|---|
| Feed post (portrait) | 1080 × 1350 | 4:5 | 60–80 px margins |
| Square post | 1080 × 1080 | 1:1 | 60–80 px margins |
| Story / reel cover | 1080 × 1920 | 9:16 | top 250 px and bottom 340 px for app UI |
| Landscape link / ad | 1200 × 628 | 1.91:1 | 60 px margins; text under ~20% of the area reads best |
| Thumbnail / banner | as specified | | check at the smallest size shown |
| Print | inches × 300 | | 300 ppi; 0.125 in (38 px) bleed beyond the trim on every side, text 0.25 in (75 px) inside it |

More sizes, safe zones and grid math: [Canvas, margins and grids](references/canvas-and-grids.md).
When the user gives a platform but no size, use the table and say which size you chose.

## 2. Set up the document

- `new_document` with `width`, `height`, `resolution` (72 for screen, 300 for print),
  `name`, and `fill` for a flat background. It becomes the current tab.
- Margins and columns as guides (`add_guide` with `axis` and `position`): they cost
  nothing, show the owner your grid, and are what you align to. A 1080-wide canvas with
  64 px margins has its content area from x 64 to x 1016.
- Organize as you go: a folder per block (`add_group`: "Background", "Photo", "Text",
  "Brand"), every layer named for its role ("Headline", "CTA Button"). The owner will
  open this file after you; unnamed "Layer 7"s make it hard to change.

## 3. Build back to front

1. **Background**: the `new_document` fill, a gradient (`add_blank_layer`, then
   `draw_gradient` with `colors` `{from, to}` and `start`/`end` points), or a photo
   (`add_image_layer` with `fit: "cover"`).
2. **Images**: `add_image_layer` with `path`, `center` and `fit`, then
   `scale_layer_to_fit` with the frame's `rect` and `mode: "cover"` (fill the frame,
   crop the excess) or `"contain"` (show it all). Crop an image to a frame by clipping it
   to a shape below it (`add_shape`, then `set_clipping_mask` on the image) or with a
   mask (`select_rect` or `select_ellipse`, then `add_layer_mask` with `kind:
   "from_selection"`). Details: [Images, shapes and alignment](references/images-shapes-and-alignment.md).
3. **Shapes**: `add_shape` with `kind` (`rectangle`, `ellipse`, `line`), a `rect` (or
   `start`/`end` for a line), `color`, `corner_radius`, `line_width`, optional `stroke`.
   Shape layers stay live: `set_shape_style` restyles them and scaling redraws them sharp.
4. **Text**: [section 4](#4-set-the-type).
5. **Brand marks** last, on top, inside the margins.

## 4. Set the type

- `add_text_layer` with `text`, `x`, `y`, `anchor`, `style` (`font_name`, `font_size`,
  `color`, `alignment`, `tracking`, `leading`, and `box_size` for paragraph text),
  `max_width` and `name`. It returns the layer's id, transform and metrics.
- The anchor places a point of the text's **box**, which is the text plus 12 px of
  padding on every side (a paragraph's box includes the padding too). A headline whose
  letters should start exactly at a 64 px margin needs `x: 52` with `anchor: "top_left"`,
  or align it afterwards by its pixels (`align_layers` with `use_content_bounds: true`).
- Centered text: `anchor: "top"` at the canvas's center x with `alignment: "center"`.
  Right-aligned: `anchor: "top_right"` with `alignment: "right"`.
- Fit, don't overflow: `max_width` on `add_text_layer` (or `fit_text` later) shrinks
  one-line text to a width; paragraph text wraps in `box_size` and `get_text_metrics`
  says whether it `overflows`.
- Fonts are PostScript names: find them with `list_fonts` (`query: "helvetica bold"`)
  and confirm with `check_fonts`; never assume a font is installed.
- A clear hierarchy uses two or three sizes in a ratio (headline about 2–3× body), one or
  two weights, and leading around 1.1–1.25× the size for headlines and 1.3–1.5× for body.

Type scales, leading and tracking values, line length, contrast math and fitting recipes
are in [Typography](references/typography.md).

## 5. Align and space

- `align_layers` with `layers`, `edge` (`left`, `center_x`, `right`, `top`, `center_y`,
  `bottom`) and `to` (`canvas`, `selection`, `layers`). To align to a margin or a column,
  select that area first (`select_rect` over the content area, then `to: "selection"`),
  then `select_none`.
- `use_content_bounds: true` measures the visible pixels instead of the layer's box, which
  is what the eye sees for text (padding) and for images with transparent edges.
- `distribute_layers` spaces three or more layers evenly along an `axis`, or with a fixed
  `spacing` in pixels.
- Exact placement: `set_layer_transform` with `anchor` puts that point of the layer at
  `x`, `y`; `move_layer` nudges by `dx`, `dy`.
- Consistent spacing reads as design: pick a base unit (8 px) and keep gaps multiples of
  it; equal margins on all sides unless the platform's safe zones say otherwise.

## 6. Color and effects

- Take brand colors as hex from the user. To pick colors from a photo, `sample_colors`
  over a few points of it; use them for accents so text and photo belong together.
- Check contrast where text sits: `sample_colors` behind the text's bounds and compare with
  the text color (the formula is in [Typography](references/typography.md#contrast)).
  Body text needs at least 4.5:1, large headlines 3:1; over a busy photo, add a scrim (a
  dark rectangle or gradient at 40–60% opacity under the text) rather than hoping.
- Effects (`set_layer_effects` or `add_layer_effect`): a soft shadow (`shadow`: small
  `distance`, larger `blur`, low `opacity`) separates text from a photo; a `stroke`
  outlines a cutout. Keep them subtle: heavy glows and hard shadows date a design.

## 7. Check it like a viewer would, before exporting

1. `render_document` at the default size: overall balance, alignment, nothing crossing a
   margin or safe zone.
2. `render_document` with `max_size: 320` or so: at feed-thumbnail size, is the headline
   still readable and the subject clear?
3. `render_region` on each text block at full detail: kerning, clipped descenders,
   stray characters.
4. `get_layer_bounds` on text and marks: every `content_bounds` (what shows; a text
   layer's `bounds` add 12 px of padding) inside the margins you set.
5. Fix, re-render, then export (`export_image`, PNG for text-heavy graphics, JPEG at
   0.85–0.92 for photos) and save the layered `.comp` beside it for later edits.

When the user asked for several sizes of the same design, hand off to
**compositor-variants-and-delivery**; for retouching the photos first, use
**compositor-image-editing**.

## References

- [Canvas, margins and grids](references/canvas-and-grids.md): sizes by platform, safe
  zones, margins, column grids, print bleed and resolution.
- [Typography](references/typography.md): text tools in depth, anchors and padding,
  point vs paragraph, fitting, type scales, leading, tracking, fonts, contrast.
- [Images, shapes and alignment](references/images-shapes-and-alignment.md): placing and
  framing photos, shapes and lines, clipping and masks, alignment and distribution
  recipes, effects, layer organization.
