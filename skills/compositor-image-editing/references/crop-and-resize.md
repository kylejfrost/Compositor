# Crop, straighten and resize

These tools change the whole document (canvas size, every layer, guides, the selection).
Each is one undo step, and each refuses while an edit is pending in the app (guard
`can_edit_layers`; see the compositor skill's pending-edits notes) rather than cancelling
it.

## Contents

- [Crop and trim](#crop-and-trim)
- [Straighten](#straighten)
- [Resize the image](#resize-the-image)
- [Resize the canvas](#resize-the-canvas)
- [Flip and resolution](#flip-and-resolution)

## Crop and trim

- `crop` with `rect` (document pixels, rounded out to whole pixels) makes that rectangle
  the canvas, as the Crop tool does. Layers move with it but **keep all their pixels**:
  nothing outside is deleted, so a later `resize_canvas` or `undo` brings it back, and a
  saved file carries the hidden margins. A rectangle reaching past the canvas extends it
  with transparency. The whole canvas records nothing.
- To crop to an aspect ratio: for a W × H canvas and a target ratio r = w/h, the largest
  crop is `min(W, H·r)` wide and `min(H, W/r)` tall; center it, or place it around the
  subject (`get_layer_bounds` or a `select_subject` bounds).
- `trim_canvas` crops to the box around pixels that aren't fully transparent, plus
  `padding` on every side; `layers` limits what is measured. Masks and effects are not
  measured, and it fails when nothing is drawn.

## Straighten

1. Find the tilt: a horizon or edge from (x1, y1) to (x2, y2) is off by
   `atan2(y2 − y1, x2 − x1)` in degrees (positive when it drops to the right).
2. `rotate_layer` on the photo with `degrees` equal to minus that angle (clockwise is
   positive), about its middle.
3. Crop away the transparent wedges. For a W × H photo turned by angle a (in radians,
   use |a|), the largest centered crop with the same proportions is s·W × s·H where
   `s = min(W / (W·cos a + H·sin a), H / (W·sin a + H·cos a))`, centered on the canvas.
4. `render_document` to check, and `sample_colors` at the four corners of the crop: none
   should be transparent (alpha 0).

## Resize the image

`resize_image` scales every layer and mask, as Image Size does:

- Give `width` and `height`, just one of them (the other keeps the aspect ratio), or
  `percent`. `resolution` sets the stored pixels per inch (unchanged when omitted); given
  alone, it changes only that number.
- `sampling`: `high` (default) for photos, `smooth` for faster good quality, `nearest`
  for pixel art and hard-edged icons that must stay crisp.
- Live text and shape layers stay editable (a turned one scaled unevenly becomes pixels);
  other layers are resampled. Render text at full size afterwards: text may look soft
  until it is next edited.
- Downscaling is safe. Upscaling invents no detail: past about 150% edges soften visibly.
  Say so and ask for a larger original rather than presenting an upscale as full quality.
- The same size and resolution again record nothing.

For deliverables of several sizes, don't resize the master: `duplicate_document` and
resize the copy, or export with `scale` / `max_size` (see the
compositor-variants-and-delivery skill).

## Resize the canvas

`resize_canvas` changes the canvas without scaling anything: layers keep their pixels and
move with the `anchor` (`center` by default; `top_left` … `bottom_right`, or 0–8), and
guides move with them. Both `width` and `height` are required, even when only one side
changes; `relative: true` adds them to the current size (0 keeps a side, negative values
shrink it). `fill` paints the added border into a new bottom layer named
"Canvas Extension"; without it the border is transparent. The result reports the new size
and `offset`, how far the content moved.

Typical uses: add a white border (`relative: true`, `width: 80`, `height: 80`, `fill:
"#ffffff"`), or extend a square photo to 4:5 (`height` to 1350 with `anchor: "top"` and a
fill matching the background).

## Flip and resolution

- `flip_canvas` with `axis` `horizontal` or `vertical` mirrors every layer, mask, the
  selection and the guides (it reports the `axis`). Mirroring text makes it read
  backwards; flip only photos, or flip single layers with `flip_layer`.
- `set_resolution` changes the stored pixels per inch without touching pixels (Image Size
  with resampling off): 300 for print, 72 for screen.
