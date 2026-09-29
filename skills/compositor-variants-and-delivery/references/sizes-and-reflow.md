# Sizes and re-layout

## Contents

- [Same aspect ratio: export only](#same-aspect-ratio-export-only)
- [New aspect ratio: extend or crop, then re-place](#new-aspect-ratio-extend-or-crop-then-re-place)
- [Proportional repositioning](#proportional-repositioning)
- [Common conversions](#common-conversions)
- [Copy and personalization variants](#copy-and-personalization-variants)
- [Batching a variant](#batching-a-variant)
- [Pitfalls](#pitfalls)

## Same aspect ratio: export only

A 1080 × 1080 master becomes 2160 × 2160 (Retina) or 600 × 600 without touching the
document: `export_image` with `scale: 2` or `max_size: 600`. `scale` multiplies the
document size (0.05–4); `max_size` caps the longest side and only ever scales down. Both
together: `scale` first, then the cap. Upscaled exports of photos soften; say so when a
variant is larger than the master's photo pixels support.

## New aspect ratio: extend or crop, then re-place

1. `duplicate_document` the master (name it for the variant).
2. Change the canvas:
   - taller or wider than the master: `resize_canvas` with the new `width` and `height`,
     an `anchor` that keeps the main content where it belongs (`center`, or `top` to add
     room below), and `fill` with the background color so the new area isn't transparent;
   - narrower or shorter: `crop` to a rectangle that keeps the subject (compute it from
     the subject's `get_layer_bounds`), or `resize_canvas` smaller with an anchor.
3. Re-cover full-bleed elements: a background photo that no longer covers the canvas gets
   `scale_layer_to_fit` with `rect` = the whole new canvas and `mode: "cover"`; a flat
   background layer gets refilled or the new canvas `fill` covers it.
4. Re-place text, logo and buttons inside the new safe area: `select_rect` over the safe
   area, `align_layers` (`to: "selection"`) for edges and centers, `distribute_layers` for
   stacks, `set_layer_transform` with `anchor` for exact spots; `select_none` afterwards.
   Move folders ("CTA", "Headline block") rather than their parts, so groups stay intact.
5. Check with `get_layer_bounds` that every text and logo `content_bounds` (what shows,
   without a text box's 12 px padding) sits inside the safe area, then `render_document`.

## Proportional repositioning

To keep an element's relative position when the canvas changes from W₀ × H₀ to W₁ × H₁
(safe areas S₀ and S₁ as `{x, y, width, height}`), map its anchor point, not its
top-left corner:

```
u = (anchor_x − S₀.x) / S₀.width        v = (anchor_y − S₀.y) / S₀.height
x_new = S₁.x + u · S₁.width              y_new = S₁.y + v · S₁.height
```

then `set_layer_transform` with that `anchor` at (`x_new`, `y_new`). Use the anchor that
matches the element's alignment: `top_left` for left-aligned text, `top` for centered,
`top_right` for right-aligned, `bottom` for a CTA pinned near the bottom. Don't scale text
proportionally to canvas area; keep its size unless it no longer fits, then `fit_text`.

## Common conversions

| From → to | Canvas | Layout |
|---|---|---|
| square 1080 → feed 1080 × 1350 | `resize_canvas` `width` 1080 and `height` 1350 (both are required), `anchor: "center"`, `fill` background | photo re-covered; headline up, CTA down into the new room |
| square 1080 → story 1080 × 1920 | `width` 1080, `height` 1920, `anchor: "center"` | keep text between y 250 and y 1580; stack elements vertically |
| square 1080 → link 1200 × 628 | `crop` or a new layout | usually a real re-layout: photo on one side (`scale_layer_to_fit` into a half), text on the other; shorten the headline if the user agrees |
| feed 1080 × 1350 → square | `crop` 1080 × 1080 around the subject | check the headline still fits |
| any → print | new document at 300 ppi; place the design | images need 300 ppi at print size; say when they fall short |

## Copy and personalization variants

- Language or price versions: `duplicate_document`, `set_text` on each text layer, then fit
  (`fit_text` or `get_text_metrics` overflow checks); point text keeps its alignment
  anchor, so centered copy stays centered. Longer languages (German, French) often need a
  smaller size or a line break.
- One per person or product: fill from the pristine master every time, not from the
  previous variant. With a PSD template follow the compositor-psd-templates skill; with a
  `.comp` master, `duplicate_document` per row or `open_document` the master fresh.
- Name each file from the row's data (slugged), and keep a list of rows done, so a failure
  mid-set can resume without redoing or skipping any.

## Batching a variant

Put one variant's layout changes in a `run_batch` with `rollback_on_error: true` and a
`name` ("Story layout"): one undo step per variant, all or nothing. Steps address layers
by id (read from `get_document` on the duplicate first) or by unique name. Canvas changes
(`resize_canvas`, `crop`) can go in the same batch; exports go after it, once the batch
result is ok and a render looks right.

## Pitfalls

- Duplicates have new layer ids, and so does a PSD or image master after `revert_document`
  or a reopen: never reuse ids from another copy or an earlier row; re-read `get_document`.
- `resize_image` scales everything, text and logos included; for a smaller variant of the
  same ratio prefer export `scale`, which leaves the document alone.
- `crop` keeps pixels outside the canvas in the layers; a later `resize_canvas` brings
  them back into view, which is useful for re-layout but surprising in a PSD delivery
  (the hidden margins travel with the file).
- A position-locked element (or folder) refuses to move: unlock it only if the user
  agrees, and relock it.
