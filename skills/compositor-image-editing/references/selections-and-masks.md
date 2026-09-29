# Selections and masks

## Contents

- [How selections behave](#how-selections-behave)
- [Selection tools](#selection-tools)
- [Refining and inspecting](#refining-and-inspecting)
- [Masks](#masks)
- [Background removal](#background-removal)
- [Recipes](#recipes)

## How selections behave

- A document has at most one selection. Painting, fills, clears, pixel adjustments and
  filters act only inside it; `select_none` makes whole layers editable again.
- Selection tools combine with the current selection by `mode`: `replace` (default),
  `add` or `subtract`. Outlines are clipped to the canvas. `antialiased` (default true)
  smooths the edge; turn it off for hard pixel edges.
- A selection is not a layer: it belongs to the document, survives switching layers, and
  is saved in `.comp` projects. `get_document` summarizes it; `get_selection` describes it.

## Selection tools

| Tool | Selects | Key arguments |
|---|---|---|
| `select_rect` | a rectangle | `rect` |
| `select_ellipse` | the ellipse filling a rectangle | `rect` |
| `select_polygon` | a polygon (Polygonal Lasso) | `points` (3–10,000 `{x, y}`; not all on one line) |
| `select_all` / `select_none` | everything / nothing | |
| `invert_selection` | everything outside the current selection | needs a selection |
| `select_by_color` | pixels similar to the one at `x`, `y` (Magic Wand) | `tolerance` 0–255 (32), `contiguous` (true), `sample_all_layers` (false: reads the **active layer**), `sample_size` `point`, `3x3`, `5x5` |
| `select_object` | the object Vision finds under `x`, `y` | `sample_all_layers` (true), `edge_offset` −10…10 |
| `select_subject` | the main subject Vision finds in the visible image | |
| `load_layer_selection` | a layer's pixels at least 50% opaque (`source: "pixels"`, ignoring its mask), or an area of its mask (`source: "mask"`) | `layer`, `source` |

- `select_by_color` without `sample_all_layers` reads the active layer, not necessarily
  the photo you are looking at: `select_layers` the photo first, or pass
  `sample_all_layers: true` to read what is visible.
- Vision tools find nothing on flat graphics or empty areas. `select_object` then leaves
  no selection (in `replace` mode) and `select_subject` keeps the previous one; check
  `get_selection` (`exists`, `bounds`) before relying on the result.
- The app's own Magic Wand and Object Selection settings are never changed by these calls.

## Refining and inspecting

- `modify_selection` with `operation` `expand`, `contract` or `feather` and `amount`
  (1–500 px; a feather at most 250). Feathering softens the edge (and feathering again softens further); expand
  a few pixels before content-aware fill or a mask on a soft object.
- `transform_selection` moves (`dx`, `dy`) and scales (`scale_x`, `scale_y`, about
  `around`, default the outline's center) the outline only, never pixels.
- `move_selected_pixels` moves the selected pixels of a layer by whole pixels (optionally
  a `duplicate`), leaving transparency behind.
- `get_selection` reports `exists`, whether it is explicitly empty, `bounds`, `feather`,
  `antialiased`, and with `include_path` the outline as SVG path data (large for complex
  selections; ask for it only when you need the shape).
- `render_region` with `region: "selection"` shows what is selected, at full detail.

## Masks

| Tool | Does |
|---|---|
| `add_layer_mask` | adds a mask: `reveal_all` (white), `hide_all` (black), `from_selection` (shows only the selection), `hide_selection`; fails if the layer already has one |
| `stroke_path`, `fill_selection`, `draw_gradient`, `invert_pixels`, `clear_selection` with `target: "mask"` | paint the mask: black hides, white reveals, grays blend; on a mask colors become gray |
| `set_mask_enabled` | turns the mask off or on, keeping it |
| `set_mask_linked` | linked: the mask moves with the layer; unlinked: it stays where it is on the document |
| `delete_layer_mask` | removes it, showing the whole layer |
| `apply_layer_mask` | bakes it into the pixels (hidden becomes transparent) and removes it; not on folders, adjustment layers, a disabled mask or a pixel-locked layer; a text, shape or smart object becomes plain pixels |
| `copy_layer_mask` | copies one layer's mask to another (`from`, `to`), replacing any it had; folders can't take a copied mask |

- Folders take masks (`add_layer_mask` on the folder) that hide everything inside.
- Masks on adjustment layers limit where the adjustment applies: brighten only the face
  with a Levels layer whose mask is black except over the face.
- `render_layer` with `include_mask: false` shows the layer without its mask;
  `get_layer_pixels` with `target: "mask"` returns the mask itself as a gray image.
- A pixel lock doesn't stop mask edits; Lock All does. `apply_layer_mask` is the
  exception: it rewrites the layer's pixels, so a pixel lock refuses it (`layer_locked`).

## Background removal

`remove_background` (`layer`, `quality`, `refine_edges`, `matte_contrast`,
`shift_edge`) masks out what Vision thinks is background. The layer's pixels are not
touched: the result is a mask, black over the background (combined with any mask already
there; with a selection, only the selected part of the mask changes).

- Start with `quality: "basic"`. If edges look cut or haloed, `undo` and use `"advanced"`:
  `refine_edges` (0–40, default 12) pulls the edge onto real detail such as hair;
  `matte_contrast` (0–100, default 25) hardens gray fringes; `shift_edge` (−10…10)
  contracts (negative) or expands the mask.
- Inspect over black and white: `render_layer` with `background: "white"`, then
  `"black"`; halos show against the opposite color.
- Touch up with `stroke_path` on the mask (`target: "mask"`, white brush to restore, black
  to remove, `hardness` about 0.5 for soft edges).
- It fails when no subject is found (graphics, abstract images); select manually instead.

## Recipes

- **Product cutout on transparency**: `remove_background` (advanced) → check edges →
  `apply_layer_mask` → `trim_canvas` with a little `padding` (it measures pixels, not
  masks, so apply the mask first) → `export_image` as PNG (transparent by default). An
  export draws the mask anyway, so apply it only when you also need the tight canvas or a
  flat layer.
- **Brighten only the subject**: `select_subject` → `add_adjustment_layer` (Levels or
  Exposure) with `clip_to_below: true` above the photo → `add_layer_mask` with
  `from_selection` on the adjustment layer → `modify_selection` feather before masking
  for a soft transition → `select_none`.
- **Replace a flat sky**: `select_by_color` on the sky (`contiguous: true`, tolerance
  20–40) → `modify_selection` expand 2 then feather 2 → `add_layer_mask` with
  `hide_selection` on the photo → put the new sky layer below it.
- **Vignette**: `add_blank_layer` → `fill_selection` with black (no selection: the whole
  layer) → `add_layer_mask` (`reveal_all`) → `draw_gradient` on the mask, `shape:
  "radial"`, from black at the center to white at the corners → `set_layer_opacity` 0.3–0.5.
- **Select a layer's shape**: `load_layer_selection` with `source: "pixels"` (then
  `modify_selection` expand for an outline or glow).
