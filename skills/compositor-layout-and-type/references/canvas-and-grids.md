# Canvas, margins and grids

## Contents

- [Sizes by use](#sizes-by-use)
- [Safe zones](#safe-zones)
- [Margins](#margins)
- [Column grids as guides](#column-grids-as-guides)
- [Print: resolution, trim and bleed](#print-resolution-trim-and-bleed)
- [Color](#color)

## Sizes by use

Platforms change their recommendations; when the user names a current spec, use theirs.
Otherwise these are safe defaults (width × height in pixels):

| Use | Size | Notes |
|---|---|---|
| Instagram / Facebook feed, portrait | 1080 × 1350 | 4:5, the most screen space in a feed |
| Square post | 1080 × 1080 | 1:1; profile grids crop feed posts toward the center |
| Story, reel cover, TikTok | 1080 × 1920 | 9:16 |
| Link preview, landscape ad, Open Graph | 1200 × 628 | about 1.91:1 |
| X / Twitter in-stream image | 1600 × 900 | 16:9 |
| LinkedIn post (landscape) | 1200 × 627 | |
| YouTube thumbnail | 1280 × 720 | 16:9; must read at 320 px wide |
| Email header | 1200 × 400 (or 600 × 200 at 1×) | export at 2× for sharp text on Retina |
| Web hero | 1920 × 1080 (or as the site needs) | leave room for the site's own text if it overlays |
| Presentation slide | 1920 × 1080 | 16:9 |

Design at the largest size needed and make smaller ones from it (see the
**compositor-variants-and-delivery** skill); don't upscale a small design.

## Safe zones

App interfaces cover parts of a full-screen image. Keep text, faces and logos out of:

| Format | Keep clear |
|---|---|
| Story / reel 1080 × 1920 | the top 250 px (profile, progress bar) and the bottom 340 px (reply bar, captions) |
| Feed 4:5 shown in a square profile grid | 135 px top and bottom (the grid shows the middle 1080 × 1080) |
| YouTube thumbnail | the bottom-right corner, about 200 × 60 px (duration badge) |

Add them as guides, check with `get_layer_bounds` that no text or logo `content_bounds`
cross them, and mention any exception the design needs.

## Margins

- Screen graphics: 5–8% of the shorter side (54–86 px on 1080) on every side, the same on
  all four unless a safe zone asks for more.
- Measure what the eye sees: for text, the glyphs (`content_bounds` from
  `get_layer_bounds`), not the text layer's box, which has 12 px of padding on every side.
- Make the content area a selection (`select_rect` with the margins inset) and align to it
  (`align_layers` with `to: "selection"`); `select_none` afterwards so later edits aren't
  confined to it.

## Column grids as guides

For `n` columns with gutter `g` inside a content area from `left` to `right`:

```
column width = (right − left − (n − 1) × g) / n
column i starts at left + i × (column width + g)      i = 0 … n−1
```

Example: 1080 wide, 64 px margins (content 64–1016, 952 px), 4 columns, 24 px gutters:
column width (952 − 72) / 4 = 220; columns start at 64, 308, 552, 796. Add a vertical
guide at each column edge (`add_guide` with `axis: "vertical"`). Horizontal rhythm: a
baseline unit of 8 px (or the body text's leading) for vertical gaps.

Guides are saved with the document (up to 1,000) and written into PSDs, where designers
see them. `list_guides` reports them; `clear_guides` removes them all.

## Print: resolution, trim and bleed

- Pixels = inches × 300 (or millimeters × 300 / 25.4). A 5 × 7 in card is 1500 × 2100 px
  trimmed; with 0.125 in (37.5, round to 38 px) bleed on every side the canvas is
  1576 × 2176 px.
- Create it with `new_document` and `resolution: 300`; the resolution is stored in
  exports and PSDs so print software sizes it correctly. `set_resolution` changes only the
  number, never the pixels.
- Backgrounds and edge-touching images extend through the bleed; text and logos stay at
  least 0.25 in (75 px) inside the trim. Put guides on the trim and the safe line.
- Compositor works in RGB (sRGB). A printer that needs CMYK converts the export; mention
  that saturated screen colors (bright blues, greens) may print duller.

## Color

- Everything is sRGB; hex colors from a brand guide can be used directly.
- `get_document` reports the palette's `foreground` and `background`; many tools default
  to them. Set them once with `set_palette_colors` when you will reuse a color many times,
  or pass explicit colors per call (clearer, and not dependent on app state).
- Limit a layout to a background, a text color and one or two accents. Pull accents from
  the photo with `sample_colors` so the palette belongs to the image.
