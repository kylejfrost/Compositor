# Images, shapes and alignment

## Contents

- [Placing images](#placing-images)
- [Framing: clipping and masks](#framing-clipping-and-masks)
- [Shapes and lines](#shapes-and-lines)
- [Alignment recipes](#alignment-recipes)
- [Effects](#effects)
- [Organizing layers](#organizing-layers)

## Placing images

`add_image_layer` imports PNG, JPEG, HEIC, TIFF or camera raw, or an SVG drawn into pixels
(at the size its fit gives it, inside or covering the canvas, so it stays sharp; `place_smart_object`
keeps an SVG vector), as a new layer
above the active layer, centered on `center` (default the canvas center):

- `fit: "none"` (default) keeps the image's pixel size; `"contain"` scales it to fit
  inside the canvas; `"cover"` scales it to cover the canvas. Only the layer's size
  changes; its pixels stay at full resolution, so scaling down and back up loses nothing.
- To fill a frame rather than the canvas, place it, then `scale_layer_to_fit` with
  `rect` (the frame) and `mode`: `cover` fills the frame (cropping visually past it),
  `contain` fits inside, `stretch` distorts; `anchor` sets which part stays in view when
  it doesn't fill (for a portrait, `anchor: "top"` keeps the head).
- Check resolution: the result's size versus the image's `pixel_width` (from `get_layer`).
  An image scaled above 100% of its pixels looks soft; say so, or ask for a larger file.
- Recolor or tone the photo before layout with the **compositor-image-editing** skill.

## Framing: clipping and masks

| Frame | How |
|---|---|
| rectangle or rounded rectangle | `add_shape` (`kind: "rectangle"`, `rect`, `corner_radius`), then the image directly above it with `set_clipping_mask` `enabled: true`: the image shows only inside the shape |
| circle (avatar) | `add_shape` with `kind: "ellipse"` and a square `rect`, the image clipped to it |
| any selection | `select_rect` / `select_ellipse` / `select_polygon`, then `add_layer_mask` on the image with `kind: "from_selection"` |
| soft fade | `add_layer_mask` (`reveal_all`), then `draw_gradient` on it with `target: "mask"` from white to black |

Clipping keeps the frame editable (restyle or resize the shape later); a mask keeps the
image self-contained. After framing, `scale_layer_to_fit` the image to the frame's
`bounds` with `cover`.

## Shapes and lines

- `add_shape` with `kind` `rectangle`, `ellipse` or `line`; a `rect` for rectangles and
  ellipses, `start` and `end` points for a line; `color` (default the foreground color),
  `corner_radius`, `line_width`, `name`, and an optional `stroke` `{enabled, width,
  color, alignment}` with `alignment` `inside`, `center` or `outside`.
- A shape's layer box includes its stroke's outer reach, so a rectangle with a 4 px outside
  stroke occupies 8 px more in each direction than its `rect`.
- `set_shape_style` changes color, corner radius, line width or stroke in place.
- Shapes are live: scaling redraws them sharp at the new size, and each `set_layer_scale`
  call starts from the current size, so repeating one compounds (check `corner_radius`
  and `line_width` with `get_layer` afterwards). Painting on a shape, filtering it or `distort_layer` makes it
  plain pixels.
- Lines have round caps, which reach half the line width past each end point.
- Buttons and badges: a rounded rectangle, a text layer centered on it (`align_layers`
  with both, `to: "layers"`, `edge: "center_x"` and then `"center_y"`), grouped in a
  folder so they move together.

## Alignment recipes

- **To the canvas**: `align_layers` with `to: "canvas"` and the edge: `center_x` centers
  horizontally.
- **To margins or a column**: `select_rect` over the content area or column, `align_layers`
  with `to: "selection"`, then `select_none`.
- **To each other**: `to: "layers"` aligns the listed layers to the box around them all
  (at least two).
- **By what shows**: `use_content_bounds: true` measures non-transparent pixels, which
  matters for text (12 px padding) and for PNGs with transparent margins.
- **Even spacing**: `distribute_layers` along `horizontal` or `vertical` for three or more
  layers: equal gaps between the first and last, or a fixed `spacing` laid out from the
  first.
- **Exact positions**: `set_layer_transform` with `anchor` places that point of the layer
  at `x`, `y`; `move_layer` nudges by `dx`, `dy`. A folder moves with everything in it,
  measured by the box around what it shows.
- Position-locked layers (or layers in a position-locked folder) refuse to move: check
  `effective_locks` first.

## Effects

`set_layer_effects` sets several at once (`merge: true` keeps the ones you don't mention;
`null` removes one); `add_layer_effect` adds one at the app's defaults plus `settings`.
The keys:

| Effect | `set_layer_effects` key | `add_layer_effect` kind | Fields |
|---|---|---|---|
| Stroke | `stroke` | `stroke` | `size` 0–500, `color`, `opacity`, `inside` |
| Drop shadow | `shadow` | `drop_shadow` | `angle`, `distance`, `blur`, `color`, `opacity` |
| Inner shadow | `inner_shadow` | `inner_shadow` | `angle`, `distance`, `blur`, `color`, `opacity` |
| Outer glow | `outer_glow` | `outer_glow` | `size` 0–500, `color`, `opacity` |
| Inner glow | `inner_glow` | `inner_glow` | `size` 0–500, `color`, `opacity` |
| Color overlay | `color_overlay` | `color_overlay` | `color`, `opacity` |

Every effect also takes `enabled`. Folders, adjustment layers and empty layers can't have
effects. A readable-text shadow over a photo: `shadow` with `distance` 2–4, `blur` 8–16,
black at `opacity` 0.35–0.5.

## Organizing layers

- New layers land above the active layer (inside the active folder, at its top). A folder
  under Lock All takes no new layers: they are placed just above it instead.
- `group_layers` collects layers into a folder where the topmost of them was;
  `place_layer` moves one into (`parent`) or out of a folder (`parent: null`), `above`
  another, or to the `bottom`; `reorder_layer` sets the index among siblings (0 is the
  bottom).
- Name everything by role with `rename_layer`, and keep background, images, text and
  brand in separate folders so the owner can find them.
