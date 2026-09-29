# Addressing, coordinates and colors

How to name what a call acts on, where things are, and what the numbers mean. Every rule
here comes from Compositor's selector, geometry and value code; the atlas gives each
tool's own parameters.

## Contents

- [Documents](#documents)
- [Layers](#layers)
- [The layer stack](#the-layer-stack)
- [Coordinates and transforms](#coordinates-and-transforms)
- [Folders are measured by what they show](#folders-are-measured-by-what-they-show)
- [Colors](#colors)
- [Units and ranges](#units-and-ranges)
- [Shapes results come back in](#shapes-results-come-back-in)

## Documents

Each open document is a tab. `list_documents` reports each tab's `index`, `tab_id`,
`document_id`, `title`, whether it is `current`, its size and whether it has unsaved
changes. Document tools take an optional `document`:

| Value | Selects |
|---|---|
| absent, `null`, `"@current"` | the current (visible) tab |
| an integer | that tab index from `list_documents` (indexes shift when a tab closes) |
| a UUID string | the tab with that tab id or document id |
| any other string | the tab with exactly that title; two tabs with the title fail as `ambiguous` |

Ids are the safe choice for anything longer than a couple of calls. A `document_id` lasts
while the document stays open, with two exceptions: `revert_document` gives a document
opened from a Photoshop file or image a new id (its `tab_id` stays), and
`duplicate_document` makes a new document (new ids for it and every layer in it).
`new_document`, `open_document` and `duplicate_document` make the new tab current;
`open_document` with `select: false` opens it in the background. `new_document` reuses the
tab when the only one open is empty.

Tools that don't act on a document (`list_documents`, `get_app_info`, `list_files`,
`open_document`, `new_document`) take no `document`; a stray one is ignored.

## Layers

`layer` (one) and `layers` (a list; a single selector is accepted too) take:

| Value | Selects |
|---|---|
| `"@active"` | the active layer; `precondition_failed` (guard `active_layer`) when there is none |
| a UUID string | the layer or folder with that id |
| a name | the layer or folder with exactly that name, anywhere in the tree |
| a path `"Footer/Logo"` | the layer `Logo` inside the folder `Footer`: matched from the top level first, then as a suffix, so `"Footer/Logo"` also finds `"Page/Footer/Logo"` when that is the only match |

Names are case-sensitive and exact. A slash inside a name is written `\/` and a backslash
`\\`, exactly as `get_document` spells a layer's `path`, so any `path` from a result is
itself a valid selector. A selector is also tried as a literal name (a layer really named
`Before/After`). Anything matching more than one layer fails as `ambiguous`; the error's
`details.candidates` lists each match's `id`, `path` and `kind`, so retry with the id.

Prefer ids. Photoshop templates routinely hold several layers called "Layer 1" or "Copy",
and a rename by you or the owner breaks a name-based plan halfway through. A layer id
lasts while the document stays open and is not read from its file again. Reading a
Photoshop file or an image again gives every layer a new id: `revert_document` on a
document opened from a `.psd` or image does, and so does closing and reopening it (a
`.comp` project keeps the ids it saved). A duplicate (`duplicate_layer`,
`duplicate_document`) gets new ids too. After a revert or reopen, old ids fail as
`not_found`: run `get_document` again and find each layer by its `path` before using ids.

**The active layer moves.** Tools that paint or change pixels or masks make their target
the active layer: `stroke_path`, `fill_selection`, `clear_selection`, `invert_pixels`,
`draw_gradient`, `set_layer_pixels`, `paste_image_into_layer`, `copy_pixels`,
`apply_filter`, `apply_levels`, `apply_hue_saturation`, `content_aware_fill`,
`remove_background`, `move_selected_pixels`, `add_layer_mask`, `set_mask_enabled`,
`delete_layer_mask` and `copy_layer_mask` (its `to` layer). New layers become active too. So `"@active"` after such a call means that layer; name layers explicitly rather
than leaning on it. `select_layers` sets the active layer, the multi-selection
(`merge_layers` without `layers` merges it) and whether the app targets pixels or mask.

**Tools that take several layers** use `layers`: `delete_layers` (a folder takes its
contents), `group_layers`, `flip_layer`, `align_layers`, `distribute_layers`,
`select_layers`, `trim_canvas` (what to measure) and `merge_layers`, whose `layers` is
optional and defaults to the current multi-selection. `merge_layers` with one layer merges
it down onto the pixel layer below; with several, merges them; with a folder, merges its
contents.

**Layer kinds** (`kind` in results): `raster`, `text`, `shape`, `smart_object`,
`adjustment`, `folder`, and `placeholder`, a Photoshop layer Compositor can't show (an
unsupported adjustment or fill) kept hidden only so it can be written back. Pixel tools
refuse folders and adjustment layers (guard `has_pixels`) and placeholders (guard
`placeholder`); a text or shape layer that gets painted, filtered, distorted or given new
pixels becomes plain pixels, so do text and shape changes through their own tools
(`fill_selection` without a selection is the exception: it recolors live text).

## The layer stack

`get_document` lists each level of the tree **bottom to top**: the last entry is the
topmost, the reverse of the Layers panel (and of `psd-verify.py`, which prints Photoshop's
top-to-bottom order). A folder's `children` follow the same order. New layers go directly
above the active layer, or at the top of the active folder's contents; `parent` and
`above` on `add_blank_layer`, and `place_layer`, put them exactly. `reorder_layer` counts
`index` from 0 at the bottom of the layer's own folder.

## Coordinates and transforms

- Units are **document pixels**. The origin is the canvas's top-left corner; x grows to the
  right and **y grows downward**. Positions may be fractional and may lie off the canvas.
- A rectangle is `{x, y, width, height}` with `(x, y)` its top-left corner; a point is
  `{x, y}`. Lists of points (`select_polygon`, `stroke_path`, `sample_colors`,
  `distort_layer`) are arrays of `{x, y}` objects, not `[x, y]` pairs.
- A layer's `transform` is `{x, y, width, height, rotation, flip_x, flip_y, center_x,
  center_y}`: its **unrotated** box at `(x, y)` sized `width` × `height`, then turned
  `rotation` degrees **clockwise** about its center and mirrored by the flips. For a turned
  layer the upright box around it is `bounds` (from `get_layer` with `detail: "full"` or
  `get_layer_bounds`), not the transform.
- A layer's own pixels (`pixel_width`, `pixel_height`) can differ from its drawn size: a
  photo scaled to half keeps its full-resolution pixels. `set_layer_scale` counts percent
  of those pixels (100 draws them 1:1), not of the current size.
- **Anchors** name nine points of a box: `top_left`, `top`, `top_right`, `left`, `center`,
  `right`, `bottom_left`, `bottom`, `bottom_right`. `set_layer_transform` with `anchor`
  places that point at `(x, y)` and keeps it fixed while the size or angle changes;
  without `anchor`, `(x, y)` is the unrotated box's top-left. `resize_canvas` also accepts
  the numbers 0–8 in that order (4 is `center`, the default).
- Guides have an `axis` and a `position`: a `horizontal` guide sits at a y, a `vertical`
  one at an x.
- Pixel sampling floors fractions: `get_pixel_color` at `x: 10.7` reads column 10.

## Folders are measured by what they show

A folder's own `transform` in `get_document` is canvas-sized, whatever it contains, so
never compute placement from it. `get_layer_bounds` on a folder reports the union of the
layers shown inside it (as `render_layer` draws it); `align_layers`, `distribute_layers`
and `set_layer_transform` measure a folder the same way, and moving a folder moves
everything in it (`set_layer_transform` on a folder only moves: its `x`, `y` and `anchor`
place that content box, and the result reports it as `bounds`).

Two more layers whose box isn't what shows: a layer made with `add_blank_layer` is as big
as the canvas, and painting part of it (`select_rect` then `fill_selection`) doesn't
shrink it; a text layer's box is its text plus 12 px of padding on every side. To learn or
check where pixels are, read `content_bounds` from `get_layer_bounds` (or
`get_document` with `detail: "full"`), or `sample_colors` just inside and outside the
edges; don't use the `transform` or `bounds`.

## Colors

- A color argument is `{r, g, b}` with each channel from 0 to 1, or a `"#rrggbb"` hex
  string. `{red, green, blue}` is accepted too. Results report colors as `{r, g, b}` plus
  `hex`.
- Some arguments take `"foreground"` or `"background"` (the app palette's two colors), and
  gradients take `"transparent"` for an end. `get_document` reports the palette; change
  it with `set_palette_colors` (the app's state, not the document's: no undo step).
- On a layer mask, colors paint as gray: black hides, white reveals, and the palette reads
  as the mask's black and white.
- Converting from 0–255: divide by 255 (`#1a73e8` is `{r: 0.102, g: 0.451, b: 0.910}`);
  hex avoids the arithmetic.

## Units and ranges

| Quantity | Unit | Note |
|---|---|---|
| position, size, distance, blur, stroke width | document pixels | not points, not percent |
| opacity, fill opacity, brush opacity, JPEG quality | 0–1 | `set_layer_opacity` rejects out-of-range values instead of clamping |
| rotation | degrees, clockwise | `rotate_layer` adds by default (`relative: true`) |
| `set_layer_scale` | percent of the layer's own pixels | 100 is 1:1 |
| `resize_image` `percent` | percent of the current image size | or give `width`/`height` (one alone keeps the ratio) |
| resolution | pixels per inch, 1–9600 | stored metadata; it changes no pixels unless you resample |
| export `scale` | output pixels per document pixel, 0.05–4 | `max_size` caps the longest side |
| text sizes (tracking, leading, font size) | pixels | see the compositor-layout-and-type skill |

## Shapes results come back in

- Mutating tools add `undo: {name, count, recorded}`; new layers come back with their
  `id` (and usually their `transform`).
- `get_document` → `document`: `id`, `width`, `height`, `resolution`, `format`,
  `project_url`, `source_url` (the Photoshop file or image it was opened from),
  `is_modified`, `layer_count`, `layers`, `active_layer_id`, `selected_layer_ids`,
  `selection`, `guides`, `history`, `palette`, `capabilities` (`can_edit_layers`,
  `can_edit_pixels`, `blocking_reason`).
- Each layer: `id`, `name`, `path`, `kind`, `visible`, `opacity`, `fill_opacity`,
  `blend_mode`, `clipping`, `transform`, `locks`, `effective_locks` (its own plus every
  enclosing folder's), `parent_id`, and for folders `children`. With `detail: "full"`
  also `bounds`, `content_bounds`, `pixel_width`/`pixel_height`, `effects`, `text`,
  `shape`, `adjustment`, `smart_object` and `mask`, in the same snake_case form the
  setters take, so a value read there can be edited and passed back.
- Render tools return the image first, then JSON with its `width`, `height`, `scale` and,
  for regions and layers, the document `region` it covers.
