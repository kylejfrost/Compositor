# Compositor tool atlas

Generated from Compositor's `tools/list` by `scripts/tool-atlas.py`; do not edit by hand. 129 tools in 17 groups. Each parameter row gives its type, whether it is required, its default and what it allows; `a.b` rows are members of object `a`, `a[].b` members of the objects in array `a`. Effect comes from the tool's annotations: read-only tools change nothing, additive ones only add (and are undoable), destructive ones can replace or discard something.

When a call's schema and this file disagree, the server is right: regenerate with `python3 scripts/tool-atlas.py` from the compositor skill's folder while Compositor's MCP server runs.

## Contents

- [Documents and app](#documents-and-app) (13): `list_documents`, `get_document`, `get_app_info`, `select_document`, `new_document`, `open_document`, `save_document`, `save_document_as`, `export_image`, `close_document`, `duplicate_document`, `revert_document`, `settle_pending_edits`
- [Previews and sampling](#previews-and-sampling) (6): `render_document`, `render_region`, `render_layer`, `get_layer_bounds`, `get_pixel_color`, `sample_colors`
- [Files](#files) (3): `list_files`, `get_file_info`, `reveal_in_finder`
- [Layers](#layers) (22): `get_layer`, `add_blank_layer`, `add_image_layer`, `add_group`, `rename_layer`, `set_layer_visibility`, `set_layer_opacity`, `set_layer_fill_opacity`, `set_layer_blend_mode`, `set_layer_locks`, `delete_layers`, `duplicate_layer`, `layer_via_copy`, `reorder_layer`, `place_layer`, `group_layers`, `ungroup_layer`, `set_clipping_mask`, `select_layers`, `merge_layers`, `flatten_image`, `rasterize_layer`
- [Transforms and alignment](#transforms-and-alignment) (9): `move_layer`, `set_layer_transform`, `set_layer_scale`, `scale_layer_to_fit`, `rotate_layer`, `flip_layer`, `distort_layer`, `align_layers`, `distribute_layers`
- [Canvas and guides](#canvas-and-guides) (10): `resize_canvas`, `resize_image`, `set_resolution`, `crop`, `trim_canvas`, `flip_canvas`, `add_guide`, `remove_guide`, `clear_guides`, `list_guides`
- [Text and fonts](#text-and-fonts) (7): `add_text_layer`, `set_text`, `set_text_style`, `fit_text`, `get_text_metrics`, `list_fonts`, `check_fonts`
- [Shapes](#shapes) (3): `add_solid_fill`, `add_shape`, `set_shape_style`
- [Smart objects](#smart-objects) (4): `place_smart_object`, `replace_smart_object_contents`, `get_smart_object_info`, `export_smart_object_contents`
- [Layer effects](#layer-effects) (4): `set_layer_effects`, `add_layer_effect`, `remove_layer_effect`, `set_layer_effect_enabled`
- [Adjustment layers and profiles](#adjustment-layers-and-profiles) (4): `add_adjustment_layer`, `set_adjustment`, `list_profiles`, `import_profile`
- [Selection](#selection) (14): `select_rect`, `select_ellipse`, `select_polygon`, `select_all`, `select_none`, `invert_selection`, `select_by_color`, `select_object`, `select_subject`, `load_layer_selection`, `modify_selection`, `transform_selection`, `move_selected_pixels`, `get_selection`
- [Pixels and painting](#pixels-and-painting) (10): `fill_selection`, `clear_selection`, `invert_pixels`, `stroke_path`, `draw_gradient`, `get_layer_pixels`, `set_layer_pixels`, `paste_image_into_layer`, `copy_pixels`, `paste_pixels`
- [Filters and destructive adjustments](#filters-and-destructive-adjustments) (5): `apply_filter`, `apply_levels`, `apply_hue_saturation`, `content_aware_fill`, `remove_background`
- [Masks](#masks) (6): `add_layer_mask`, `set_mask_enabled`, `set_mask_linked`, `delete_layer_mask`, `apply_layer_mask`, `copy_layer_mask`
- [History and batches](#history-and-batches) (4): `undo`, `redo`, `get_history`, `run_batch`
- [View and app window](#view-and-app-window) (5): `zoom_to_fit`, `set_zoom`, `select_tool`, `bring_app_to_front`, `set_palette_colors`

## Documents and app

### `list_documents` — List open documents

**Effect:** read-only, idempotent

Lists the open document tabs: index, tab and document ids, title, whether it is current, canvas size, and unsaved changes.

No parameters.

### `get_document` — Get document

**Effect:** read-only, idempotent

Describes a document: canvas, format and files, the layer tree, selection, guides, undo state, palette, and capabilities (which edits can run now, and what blocks them). Each layer reports its own locks and effective_locks (its folders' too). detail full adds each layer's box, content bounds, effects, text, shape, adjustment, smart-object and mask details.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `detail` | string |  | `"summary"` | `summary`, `full` | Detail per layer. |

### `get_app_info` — Get app info

**Effect:** read-only, idempotent

Reports Compositor's version, MCP endpoint, limits, Agent folder, formats and features, and whether macOS lets it into each protected location (folder_access). Each is granted, denied, not_determined (a permission prompt is waiting) or absent; folder_access_detail names denied or waiting providers and volumes. Locations not checked yet are probed now, within about two seconds.

No parameters.

### `select_document` — Select document

**Effect:** additive, idempotent

Switches the visible document tab.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string | yes |  |  | The document to show. |

### `new_document` — New document

**Effect:** additive

Creates a document in a new tab and makes it current, with one layer, 'Layer 1', transparent or filled with 'fill'. It counts as unsaved; 'name' titles it until it is saved.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `width` | integer |  | `1920` | 1–30000 | Canvas width. |
| `height` | integer |  | `1080` | 1–30000 | Canvas height. |
| `fill` | object {r, g, b} \| string `^#[0-9A-Fa-f]{6}$` |  |  |  | Fill for the first layer (default transparent). {r, g, b} in 0–1, or "#rrggbb". |
| `name` | string |  |  |  | Title (default 'Untitled N'). |
| `resolution` | number |  | `72` | 1–9600 | Pixels per inch. |

### `open_document` — Open document

**Effect:** additive, idempotent

Opens a .comp project, a Photoshop .psd or .psb (8-bit RGB) or an image (PNG, JPEG, HEIC, TIFF, camera raw, SVG as pixels) in a new tab, without dialogs. What Compositor converted in a PSD is listed in conversions. A file already open returns its tab with already_open: true. The file itself is never changed: a PSD or image document has no project file until save_document_as.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `path` | string | yes |  |  | The file; a path with no extension is also tried with .comp. |
| `select` | boolean |  | `true` |  | Make it the current tab. |

### `save_document` — Save document

**Effect:** destructive, idempotent

Saves the document to its own file (the .comp it was opened from, or the .comp/.psd it was last saved as) in that file's format, and marks it saved. A document without one (new, duplicated, or opened from a Photoshop file or image) fails with a hint to use save_document_as, so an original is never replaced. A .psd follows save_document_as's allow_lossy rule and returns its warnings.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `allow_lossy` | boolean |  | `false` |  | For a .psd: write what Photoshop can't hold exactly as an approximation (listed in 'warnings' with lossy: true) instead of refusing the save. |

### `save_document_as` — Save document as

**Effect:** destructive

Saves the document to a file: a Compositor project (.comp), which keeps everything, or a layered Photoshop file (.psd). The format comes from 'format' or the path's extension (a path with neither gets '.comp'). Never replaces an existing file unless overwrite is true, the Photoshop file the document was opened from included. With set_as_current (the default) the document now lives at that path in that format (save_document writes it again) and is marked saved; false writes a copy and leaves the document as it was. A Photoshop save returns 'warnings', what the file holds differently from the document; lossy ones (an adjustment Photoshop lacks written as pixels, a clipping applied to pixels or left out, a curve resampled, a shape saved as pixels or a plain path, alpha channels or an adjustment's vector mask left out) refuse the save (guard lossy, listed in details.warnings, nothing written) unless allow_lossy is true.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `path` | string | yes |  |  | Where to save: absolute, ~/…, or relative to the Agent folder, e.g. 'work/hero.comp'. |
| `allow_lossy` | boolean |  | `false` |  | For a .psd: write what Photoshop can't hold exactly as an approximation (listed in 'warnings' with lossy: true) instead of refusing the save. |
| `format` | string |  |  | `comp`, `psd` | File format. Defaults from the path's extension, else comp. |
| `overwrite` | boolean |  | `false` |  | Replace an existing file at 'path'. |
| `set_as_current` | boolean |  | `true` |  | Make 'path' the document's file (Save As). false saves a copy. |

### `export_image` — Export image

**Effect:** destructive, idempotent

Renders the composite, or a region of it, to a PNG or JPEG file, resized by 'scale' and scaled down to fit 'max_size'.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `path` | string | yes |  |  | Output path; its extension sets the format unless 'format' does. |
| `background` | string |  |  | `transparent`, `white`, `black`, `checkerboard` | Behind transparent pixels; default transparent (PNG) or white (JPEG). |
| `format` | string |  |  | `png`, `jpeg` | Output format (default from the extension). |
| `max_size` | integer |  |  | 16–30000 | Longest side of the file; larger results scale down. |
| `overwrite` | boolean |  | `false` |  | Replace an existing file at 'path'. |
| `quality` | number |  | `0.85` | 0–1 | JPEG quality. |
| `region` | object |  |  |  | Part of the canvas to export (default all). |
| `region.x` | number | yes |  |  |  |
| `region.y` | number | yes |  |  |  |
| `region.width` | number | yes |  | ≥ 0 |  |
| `region.height` | number | yes |  | ≥ 0 |  |
| `scale` | number |  | `1` | 0.05–4 | Output pixels per document pixel. |

### `close_document` — Close document

**Effect:** destructive

Closes a document's tab; one with unsaved changes is refused (guard unsaved_changes) unless discard_changes is true. Closing the last tab leaves an empty one.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `discard_changes` | boolean |  | `false` |  | Close despite unsaved changes, losing them. |

### `duplicate_document` — Duplicate document

**Effect:** additive

Copies the document into a new tab and makes it current: the same canvas, layers, guides and selection under new ids, with no file and no undo history (it counts as unsaved).

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `name` | string |  |  |  | The copy's title. |

### `revert_document` — Revert document

**Effect:** destructive

Reloads the document from its file in the same tab, dropping every change and the undo history. Unsaved changes are refused (guard unsaved_changes) unless discard_changes is true; a PSD or image document gets a new document_id.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `discard_changes` | boolean |  | `false` |  | Revert despite unsaved changes, losing them. |

### `settle_pending_edits` — Settle pending edits

**Effect:** destructive

Commits (mode commit) or cancels an edit in progress in the app that blocks tools: a transform, typed text, a crop, gradient, lasso or shape, a filter or adjustment dialog, moved pixels. It also dismisses renames, pickers and error alerts. Returns settled, failed [{edit, message}] and blocking_reason; each committed edit is its own undo step. Text or a crop that fails stays open; imports and long operations are left to finish.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `mode` | string | yes |  | `commit`, `cancel` | Keep or throw away the pending edits. |

## Previews and sampling

### `render_document` — Render document

**Effect:** read-only, idempotent

Renders the document's composite as export draws it and returns it as an image, then JSON: width, height, scale, document size, format and bytes. Nothing is written; export_image writes files.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `background` | string |  |  | `transparent`, `white`, `black`, `checkerboard` | Behind transparent pixels; default transparent (PNG) or white (JPEG). |
| `format` | string |  | `"png"` | `png`, `jpeg` | Image format. |
| `max_size` | integer |  | `1024` | 16–4096 | Longest side of the returned image; larger renders scale down. |
| `quality` | number |  | `0.85` | 0–1 | JPEG quality. |

### `render_region` — Render region

**Effect:** read-only, idempotent

Renders part of the composite at full detail, a rectangle or the selection's bounds, and returns it as an image, then JSON with the region rendered.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `region` | object {x, y, width, height} \| one of `selection` | yes |  |  | A rectangle, or "selection" for its bounds; clamped to the canvas. |
| `region.x` | number | yes |  |  |  |
| `region.y` | number | yes |  |  |  |
| `region.width` | number | yes |  | ≥ 0 |  |
| `region.height` | number | yes |  | ≥ 0 |  |
| `background` | string |  |  | `transparent`, `white`, `black`, `checkerboard` | Behind transparent pixels; default transparent (PNG) or white (JPEG). |
| `format` | string |  | `"png"` | `png`, `jpeg` | Image format. |
| `max_size` | integer |  | `1024` | 16–4096 | Longest side of the returned image; larger renders scale down. |
| `padding` | number |  | `0` | 0–30000 | Pixels added around the region. |
| `quality` | number |  | `0.85` | 0–1 | JPEG quality. |

### `render_layer` — Render layer

**Effect:** read-only, idempotent

Renders one layer, or a folder's contents, by itself, even when hidden, with nothing below it and no clipping base, and returns it as an image. Adjustment layers show nothing alone and are unsupported.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `background` | string |  |  | `transparent`, `white`, `black`, `checkerboard` | Behind transparent pixels; default transparent (PNG) or white (JPEG). |
| `crop` | string |  | `"layer"` | `layer`, `canvas` | layer: the box it draws in, effects included; canvas: the whole canvas. |
| `format` | string |  | `"png"` | `png`, `jpeg` | Image format. |
| `include_effects` | boolean |  | `true` |  | Draw its effects. |
| `include_mask` | boolean |  | `true` |  | Apply its mask. |
| `max_size` | integer |  | `1024` | 16–4096 | Longest side of the returned image; larger renders scale down. |
| `quality` | number |  | `0.85` | 0–1 | JPEG quality. |

### `get_layer_bounds` — Get layer bounds

**Effect:** read-only, idempotent

Reports where a layer sits in document pixels: transform, corners, upright bounds, effects_bounds, content_bounds around its visible pixels, mask placement, and text metrics. A folder reports the union of what it shows.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `content` | boolean |  | `true` |  | Also scan pixels for content_bounds. |

### `get_pixel_color` — Get pixel color

**Effect:** read-only, idempotent

Reads one document pixel's color as {r, g, b, a} in 0–1 and hex, from the composite or (source layer) from the layer's own pixels. For several pixels, call sample_colors once.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string |  |  |  | For source 'layer', the layer to read (default the active layer). |
| `x` | number | yes |  |  | Column (floored). |
| `y` | number | yes |  |  | Row (floored). |
| `source` | string |  | `"composite"` | `composite`, `layer` | Where to read. |

### `sample_colors` — Sample colors

**Effect:** read-only, idempotent

Reads up to 256 document pixels' colors at once, as get_pixel_color reports them, in the order given.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string |  |  |  | For source 'layer', the layer to read (default the active layer). |
| `points` | array of object | yes |  | 1–256 items | Points to read. |
| `points[].x` | number | yes |  |  |  |
| `points[].y` | number | yes |  |  |  |
| `source` | string |  | `"composite"` | `composite`, `layer` | Where to read. |

## Files

### `list_files` — List files

**Effect:** read-only, idempotent

Lists a folder's files and folders (default the Agent folder) in name order with name, path, size and is_directory; recursive walks subfolders. Hidden files are skipped and .comp projects count as files. Folders macOS keeps Compositor out of are listed but not entered, and named in skipped with folder_access_denied, folder_access_pending or folder_access_unchecked. extensions filters files; limit caps the entries (truncated).

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `extensions` | array of string |  |  | ≥ 1 items | Only files with these extensions, such as ["png", "psd"]. |
| `limit` | integer |  | `500` | 1–10000 | Most entries to return. |
| `path` | string |  |  |  | Folder to list (default the Agent folder). |
| `recursive` | boolean |  | `false` |  | Walk subfolders. |

### `get_file_info` — Get file info

**Effect:** read-only, idempotent

Describes a file or folder without opening it: exists (a missing path is no error), is_directory, size, uti, and for an image the image_size it imports at.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `path` | string | yes |  |  | The file or folder. |

### `reveal_in_finder` — Reveal in Finder

**Effect:** additive, idempotent

Shows a file or folder selected in Finder (default the Agent folder), so the user can see what you made.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `path` | string |  |  |  | What to show (default the Agent folder). |

## Layers

### `get_layer` — Get layer

**Effect:** read-only, idempotent

Describes one layer as get_document does: id, name, path, kind, visibility, opacity, blending, clipping, transform, locks and effective_locks, and a folder's children. Kinds: raster, text, shape, smart_object, adjustment, folder, placeholder. detail full (the default) adds its box, content bounds, effects, text, shape, adjustment, smart-object and mask details.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `detail` | string |  | `"full"` | `summary`, `full` | Detail. |

### `add_blank_layer` — Add blank layer

**Effect:** additive

Adds an empty transparent layer above the active layer (at the top of it when it is a folder), at the top of 'parent' (null: the top level), or directly above 'above'.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `above` | string |  |  |  | The layer to put it directly above. |
| `name` | string |  |  |  | Layer name. |
| `parent` | string \| null |  |  |  | The folder to add it to (null: the top level). |

### `add_image_layer` — Add image layer

**Effect:** additive

Imports an image file (PNG, JPEG, HEIC, TIFF, camera raw, or SVG drawn into pixels) as a new layer above the active layer, centered on 'center' (default the canvas center). fit contain or cover sizes the layer to fit inside or cover the canvas, keeping its pixels. A tab with no document gets one sized to the image.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `path` | string | yes |  |  | Image file. |
| `center` | object |  |  |  | Where its center goes (default the canvas center). |
| `center.x` | number | yes |  |  |  |
| `center.y` | number | yes |  |  |  |
| `fit` | string |  | `"none"` | `none`, `contain`, `cover` | Size against the canvas. |
| `name` | string |  |  |  | Layer name (default the file name). |

### `add_group` — Add folder

**Effect:** additive

Adds an empty folder above the active layer (inside it when it is a folder).

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `name` | string |  |  |  | Folder name. |

### `rename_layer` — Rename layer

**Effect:** additive, idempotent

Renames a layer or folder.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `name` | string | yes |  |  | New name. |

### `set_layer_visibility` — Set layer visibility

**Effect:** additive, idempotent

Shows or hides a layer or folder, even a locked one.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `visible` | boolean | yes |  |  | Show it. |

### `set_layer_opacity` — Set layer opacity

**Effect:** additive, idempotent

Sets a layer's or folder's opacity from 0 to 1, its effects included.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `opacity` | number | yes |  | 0–1 | Opacity. |

### `set_layer_fill_opacity` — Set layer fill opacity

**Effect:** additive, idempotent

Sets a layer's fill opacity (Photoshop's Fill) from 0 to 1: its own pixels' opacity, apart from its effects. It is saved and written to PSD, and drawn on layers without effects. Folders have none.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `fill_opacity` | number | yes |  | 0–1 | Fill opacity. |

### `set_layer_blend_mode` — Set layer blend mode

**Effect:** additive, idempotent

Sets a layer's blend mode; names match loosely (color_burn, Color Burn). Folders pass their contents through and take none.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `mode` | string | yes |  | `Normal`, `Darken`, `Multiply`, `Color Burn`, `Linear Burn`, `Lighten`, `Screen`, `Color Dodge`, `Linear Dodge (Add)`, `Overlay`, `Soft Light`, `Hard Light`, `Vivid Light`, `Linear Light`, `Pin Light`, `Hard Mix`, `Difference`, `Exclusion`, `Subtract`, `Divide`, `Hue`, `Saturation`, `Color`, `Luminosity` | Blend mode name. |

### `set_layer_locks` — Set layer locks

**Effect:** additive, idempotent

Turns layer locks on or off: position (moving, transforming), pixels (painting, rasterizing, merging), all (every change but showing, hiding and selecting) and transparency (kept for PSD). Locks not given keep their state; a folder's locks hold everything in it.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `all` | boolean |  |  |  | Lock all. |
| `pixels` | boolean |  |  |  | Lock image pixels. |
| `position` | boolean |  |  |  | Lock position. |
| `transparency` | boolean |  |  |  | Lock transparent pixels. |

### `delete_layers` — Delete layers

**Effect:** destructive

Deletes layers, a folder with its contents. Layers clipped to a deleted one are baked to their current look first, as the app's Delete does.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layers` | array of string | yes |  | ≥ 1 items | Layers to delete. |

### `duplicate_layer` — Duplicate layer

**Effect:** additive

Duplicates a layer, a folder with its contents, directly above it and selects the copy.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `name` | string |  |  |  | The copy's name. |

### `layer_via_copy` — Layer via copy

**Effect:** additive

Copies a pixel layer's pixels inside the selection to a new layer, in place above it (Layer via Copy); without a selection the whole layer is duplicated.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |

### `reorder_layer` — Reorder layer

**Effect:** additive, idempotent

Moves a layer to a sibling index inside its folder, 0 being the bottom. Clipping follows the stack: moved into a clipping group a layer joins it, moved out of one it stops clipping.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `index` | integer | yes |  | ≥ 0 | Sibling index, 0 the bottom (past the top: the top). |

### `place_layer` — Place layer

**Effect:** additive, idempotent

Moves a layer or folder into a folder or out of one. It goes into 'parent' (null: the top level; omitted, the folder 'above' is in, else its own), directly above 'above', at the bottom with bottom: true, or else at the top.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `above` | string |  |  |  | The layer to put it directly above. |
| `bottom` | boolean |  | `false` |  | Put it at the bottom. |
| `parent` | string \| null |  |  |  | The folder to move it into (null: the top level). |

### `group_layers` — Group layers

**Effect:** additive

Collects layers into a new folder, placed where the topmost of them was.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layers` | array of string | yes |  | ≥ 1 items | Layers to group. |
| `name` | string |  |  |  | Folder name. |

### `ungroup_layer` — Ungroup folder

**Effect:** destructive

Removes a folder, moving its contents into its parent at its place in the stack, in order, and selects them. The folder's own opacity, mask and effects go with it, as in Photoshop.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The folder. |

### `set_clipping_mask` — Set clipping mask

**Effect:** additive, idempotent

Clips a layer to the layer below it, or unclips it (Photoshop's clipping mask).

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `enabled` | boolean | yes |  |  | Clip to the layer below. |

### `select_layers` — Select layers

**Effect:** additive, idempotent

Sets the active layer and multi-selection (what merge_layers and the app act on), and whether edits in the app target the active layer's pixels or its mask.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layers` | array of string | yes |  | ≥ 1 items | Layers to select. |
| `active` | string |  |  |  | The layer to make active (defaults to the first of 'layers'). |
| `target` | string |  | `"pixels"` | `pixels`, `mask` | pixels, or mask (it must have one). |

### `merge_layers` — Merge layers

**Effect:** destructive

Merges layers into one pixel layer, baking blending, masks, clipping and adjustments: one layer merges down, several merge together, and a folder merges its contents. layers defaults to the selection; the result names the action.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layers` | array of string |  |  | ≥ 1 items | Layers to merge (default: the current selection). |

### `flatten_image` — Flatten image

**Effect:** destructive

Flattens the document into one full-canvas pixel layer, 'Background', as export_image renders it. Hidden layers are discarded, or with discard_hidden false the call is refused while there are any.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `discard_hidden` | boolean |  | `true` |  | Discard hidden layers (false: refuse if any). |

### `rasterize_layer` — Rasterize layer

**Effect:** destructive

Turns a text or shape layer into the plain pixels it shows now, keeping its effects and mask. A pixel layer stays as it is; folders, adjustment layers and placeholders are refused.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |

## Transforms and alignment

### `move_layer` — Move layer

**Effect:** additive

Moves a layer, or a folder with its contents, by dx, dy document pixels; a linked mask moves with it and an unlinked one stays put.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `dx` | number | yes |  |  | Horizontal offset. |
| `dy` | number | yes |  |  | Vertical offset. |

### `set_layer_transform` — Set layer transform

**Effect:** additive, idempotent

Sets a layer's position, size, rotation and flips; omitted fields keep their values. x, y place the unrotated top-left, or with 'anchor' that point, which a new size or angle keeps in place. A folder can only move: x, y place the box around what it shows (returned as bounds). Returns the transform.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `x` | number |  |  |  | x of the anchor point, or of the unrotated top-left. |
| `y` | number |  |  |  | y of the anchor point, or of the unrotated top-left. |
| `width` | number |  |  | 1–300000 | Width in pixels. |
| `height` | number |  |  | 1–300000 | Height in pixels. |
| `anchor` | string |  |  | `top_left`, `top`, `top_right`, `left`, `center`, `right`, `bottom_left`, `bottom`, `bottom_right` | The point x, y place, kept in place by a resize or turn. |
| `flip_x` | boolean |  |  |  | Mirror horizontally. |
| `flip_y` | boolean |  |  |  | Mirror vertically. |
| `rotation` | number |  |  |  | Clockwise degrees. |

### `set_layer_scale` — Set layer scale

**Effect:** additive, idempotent

Scales a layer to a percentage of its own pixels (100 is 1:1), keeping its angle and flips. A live shape draws itself again at the new size, so a later percentage starts from there.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `percent` | number | yes |  | 1–10000 | Percent of its pixel size. |
| `keep_center` | boolean |  | `true` |  | Keep its middle in place (false: its top-left). |

### `scale_layer_to_fit` — Scale layer to fit

**Effect:** additive, idempotent

Scales and moves a layer so its upright box fits a rectangle: contain fits inside and cover fills it, keeping the aspect ratio, and stretch fills it exactly. 'anchor' places the result; angle and flips are kept.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `mode` | string | yes |  | `contain`, `cover`, `stretch` | How to fit. |
| `rect` | object | yes |  |  | The rectangle. |
| `rect.x` | number | yes |  |  |  |
| `rect.y` | number | yes |  |  |  |
| `rect.width` | number | yes |  | ≥ 0 |  |
| `rect.height` | number | yes |  | ≥ 0 |  |
| `anchor` | string |  | `"center"` | `top_left`, `top`, `top_right`, `left`, `center`, `right`, `bottom_left`, `bottom`, `bottom_right` | Where it sits in the rectangle. |

### `rotate_layer` — Rotate layer

**Effect:** additive

Turns a layer clockwise by 'degrees' (relative, the default) or to that angle, about its middle or 'around'.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `degrees` | number | yes |  |  | Clockwise degrees. |
| `around` | object |  |  |  | Point to turn about (default its middle). |
| `around.x` | number | yes |  |  |  |
| `around.y` | number | yes |  |  |  |
| `relative` | boolean |  | `true` |  | Add to the current angle. |

### `flip_layer` — Flip layers

**Effect:** additive

Mirrors layers horizontally or vertically: one about its own middle, several (or a folder's contents) about the middle of their box. Linked masks flip too; only shown layers with pixels flip.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layers` | array of string | yes |  | ≥ 1 items | The layers or folders to flip. |
| `axis` | string | yes |  | `horizontal`, `vertical` | Mirror axis. |

### `distort_layer` — Distort layer

**Effect:** destructive

Moves a layer's four corners (top-left, top-right, bottom-right, bottom-left) and resamples its pixels and linked mask into that shape. Text and shape layers become pixels; get_layer_bounds reports the current corners.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `corners` | array of object | yes |  | 4–4 items | New corners: top-left, top-right, bottom-right, bottom-left. |
| `corners[].x` | number | yes |  |  |  |
| `corners[].y` | number | yes |  |  |  |

### `align_layers` — Align layers

**Effect:** additive, idempotent

Lines up the same edge or middle of layers with the canvas, the selection or their combined box. Layers are measured by their upright box, or with use_content_bounds by their visible pixels; a folder moves with its contents.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layers` | array of string | yes |  | ≥ 1 items | The layers or folders to align. |
| `edge` | string | yes |  | `left`, `center_x`, `right`, `top`, `center_y`, `bottom` | Edge or middle to line up. |
| `to` | string | yes |  | `selection`, `canvas`, `layers` | What to line up with. |
| `use_content_bounds` | boolean |  | `false` |  | Measure visible pixels, not whole boxes. |

### `distribute_layers` — Distribute layers

**Effect:** additive, idempotent

Spaces three or more layers along an axis, in order of their middles: equal gaps with the first and last fixed, or gaps of 'spacing' pixels from the first.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layers` | array of string | yes |  | ≥ 1 items | The layers or folders to distribute (at least three). |
| `axis` | string | yes |  | `horizontal`, `vertical` | Axis. |
| `spacing` | number |  |  |  | Gap between boxes (default equal gaps). |

## Canvas and guides

### `resize_canvas` — Resize canvas

**Effect:** additive

Changes the canvas size without scaling anything (Canvas Size): layers and guides move with the anchor. relative adds width and height to the current size; 'fill' paints the added border into a new bottom layer. Returns the size and offset, how far content moved.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `width` | integer | yes |  | -30000–30000 | New width, or with relative the pixels to add. |
| `height` | integer | yes |  | -30000–30000 | New height, or with relative the pixels to add. |
| `anchor` | integer 0–8 \| one of `top_left`, `top`, `top_right`, `left`, `center`, `right`, `bottom_left`, `bottom`, `bottom_right` |  |  |  | The point of the old canvas that stays put: 0–8 from top-left to bottom-right in rows (4 center, the default), or a name such as "top_left". |
| `fill` | object {r, g, b} \| string `^#[0-9A-Fa-f]{6}$` |  |  |  | Color for the added border (default transparent). {r, g, b} in 0–1, or "#rrggbb". |
| `relative` | boolean |  | `false` |  | Add to the current size. |

### `resize_image` — Resize image

**Effect:** additive

Scales the whole image, every layer and mask (Image Size), to width and height, one of them (keeping the aspect ratio) or percent. Live text and shapes stay editable; other pixels resample with 'sampling'. 'resolution' sets the stored pixels per inch.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `width` | integer |  |  | 1–30000 | New width in pixels. |
| `height` | integer |  |  | 1–30000 | New height in pixels. |
| `percent` | number |  |  | ≤ 10000 | Scale both sides by this percentage. |
| `resolution` | number |  |  | 1–9600 | Stored pixels per inch. |
| `sampling` | string |  | `"high"` | `nearest`, `smooth`, `high` | Resampling. |

### `set_resolution` — Set resolution

**Effect:** additive, idempotent

Sets the pixels per inch stored with the document, changing no pixels.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `resolution` | number | yes |  | 1–9600 | Pixels per inch. |

### `crop` — Crop

**Effect:** destructive

Crops the canvas to a rectangle, rounded to whole pixels, as the Crop tool does: layers keep all their pixels, and a rectangle past the canvas extends it with transparency.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `rect` | object | yes |  |  | The area to keep. |
| `rect.x` | number | yes |  |  |  |
| `rect.y` | number | yes |  |  |  |
| `rect.width` | number | yes |  | ≥ 0 |  |
| `rect.height` | number | yes |  | ≥ 0 |  |

### `trim_canvas` — Trim canvas

**Effect:** destructive

Crops the canvas to the box around pixels that aren't transparent, plus 'padding', measuring every shown layer or only 'layers'. Masks and effects aren't measured; fails when nothing is drawn.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layers` | array of string |  |  | ≥ 1 items | Measure only these. |
| `padding` | integer |  | `0` | 0–30000 | Margin around the content. |

### `flip_canvas` — Flip canvas

**Effect:** additive

Mirrors the whole document horizontally or vertically: every layer and mask, the selection and the guides.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `axis` | string | yes |  | `horizontal`, `vertical` | Mirror axis. |

### `add_guide` — Add guide

**Effect:** additive

Adds a horizontal guide at a document y, or a vertical one at an x, and returns its id. Refused while guides are locked in the app, and past 1000 guides.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `axis` | string | yes |  | `horizontal`, `vertical` | Which way it runs. |
| `position` | number | yes |  |  | y for a horizontal guide, x for a vertical one. |

### `remove_guide` — Remove guide

**Effect:** destructive

Removes one guide by its id; refused while guides are locked in the app.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `guide_id` | string | yes |  |  | The guide id. |

### `clear_guides` — Clear guides

**Effect:** destructive

Removes every guide, even while guides are locked.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |

### `list_guides` — List guides

**Effect:** read-only, idempotent

Lists the guides as {id, axis, position}, and whether guides are shown and locked in the app.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |

## Text and fonts

### `add_text_layer` — Add text layer

**Effect:** additive

Adds a live text layer: point text as big as its text, or paragraph text wrapping in style.box_size, with its box's 'anchor' point at (x, y). The style defaults to 72 px Helvetica in the foreground color; max_width shrinks point text to fit. Returns the id, transform, style and metrics.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `x` | number | yes |  |  | x of the anchor point. |
| `y` | number | yes |  |  | y of the anchor point. |
| `text` | string | yes |  |  | The text; \n breaks lines. |
| `anchor` | string |  | `"top_left"` | `top_left`, `top`, `top_right`, `left`, `center`, `right`, `bottom_left`, `bottom`, `bottom_right` | The point of the text's box placed at (x, y). |
| `max_width` | number |  |  | ≥ 1 | Shrink point text to at most this many document pixels wide. |
| `name` | string |  |  |  | Layer name. Defaults to the text's first words. |
| `style` | object |  |  |  | Style fields; any left out keep their values. |
| `style.alignment` | string |  |  | `left`, `center`, `right` | Line alignment. |
| `style.box_size` | object {width, height} \| null |  |  |  | Paragraph text: the box it wraps in, padding included. null: point text. |
| `style.color` | object {r, g, b} \| string `^#[0-9A-Fa-f]{6}$` \| one of `foreground`, `background` |  |  |  | Text color: {r, g, b}, "#rrggbb", "foreground" or "background". |
| `style.color_runs` | array of object |  |  | ≤ 100000 items | Optional per-range colors. Ranges use zero-based UTF-16 offsets; fields are location, length, red, green and blue. |
| `style.color_runs[].blue` | number | yes |  | 0–1 | Blue component. |
| `style.color_runs[].green` | number | yes |  | 0–1 | Green component. |
| `style.color_runs[].length` | integer | yes |  | ≥ 1 | UTF-16 range length. |
| `style.color_runs[].location` | integer | yes |  | ≥ 0 | UTF-16 start offset. |
| `style.color_runs[].red` | number | yes |  | 0–1 | Red component. |
| `style.font_name` | string |  |  |  | PostScript name (list_fonts); a missing font draws with a substitute (check_fonts). |
| `style.font_runs` | array of object |  |  | ≤ 100000 items | Optional per-range font faces. Ranges use zero-based UTF-16 offsets; fields are location, length and font_name. |
| `style.font_runs[].font_name` | string | yes |  |  | PostScript font name. |
| `style.font_runs[].length` | integer | yes |  | ≥ 1 | UTF-16 range length. |
| `style.font_runs[].location` | integer | yes |  | ≥ 0 | UTF-16 start offset. |
| `style.font_size` | number |  |  | 1–2000 | Type size in pixels. |
| `style.horizontal_scale` | number 0.1–10 \| null |  |  |  | Width stretch; null is 1. |
| `style.leading` | number |  |  | 0–5000 | Baseline to baseline in pixels; 0 is auto. |
| `style.size_runs` | array of object |  |  | ≤ 100000 items | Optional per-range font sizes in pixels. Ranges use zero-based UTF-16 offsets; fields are location, length and font_size. |
| `style.size_runs[].font_size` | number | yes |  | 1–2000 | Font size in pixels. |
| `style.size_runs[].length` | integer | yes |  | ≥ 1 | UTF-16 range length. |
| `style.size_runs[].location` | integer | yes |  | ≥ 0 | UTF-16 start offset. |
| `style.tracking` | number |  |  | -100–1000 | Extra space after each letter. |

### `set_text` — Set text

**Effect:** additive, idempotent

Replaces a text layer's text, keeping its style. Point text keeps its anchor (the left end, middle or right end of its first baseline, as aligned); paragraph text keeps its box's top-left.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The text layer. |
| `text` | string | yes |  |  | The new text; \n breaks lines. |

### `set_text_style` — Set text style

**Effect:** additive, idempotent

Patches a live text layer's style; optional color_runs, font_runs and size_runs use UTF-16 offsets.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The text layer. |
| `style` | object | yes |  |  | Style fields; any left out keep their values. |
| `style.alignment` | string |  |  | `left`, `center`, `right` | Line alignment. |
| `style.box_size` | object {width, height} \| null |  |  |  | Paragraph text: the box it wraps in, padding included. null: point text. |
| `style.color` | object {r, g, b} \| string `^#[0-9A-Fa-f]{6}$` \| one of `foreground`, `background` |  |  |  | Text color: {r, g, b}, "#rrggbb", "foreground" or "background". |
| `style.color_runs` | array of object |  |  | ≤ 100000 items | Optional per-range colors. Ranges use zero-based UTF-16 offsets; fields are location, length, red, green and blue. |
| `style.color_runs[].blue` | number | yes |  | 0–1 | Blue component. |
| `style.color_runs[].green` | number | yes |  | 0–1 | Green component. |
| `style.color_runs[].length` | integer | yes |  | ≥ 1 | UTF-16 range length. |
| `style.color_runs[].location` | integer | yes |  | ≥ 0 | UTF-16 start offset. |
| `style.color_runs[].red` | number | yes |  | 0–1 | Red component. |
| `style.content` | string |  |  |  | The text. |
| `style.font_name` | string |  |  |  | PostScript name (list_fonts); a missing font draws with a substitute (check_fonts). |
| `style.font_runs` | array of object |  |  | ≤ 100000 items | Optional per-range font faces. Ranges use zero-based UTF-16 offsets; fields are location, length and font_name. |
| `style.font_runs[].font_name` | string | yes |  |  | PostScript font name. |
| `style.font_runs[].length` | integer | yes |  | ≥ 1 | UTF-16 range length. |
| `style.font_runs[].location` | integer | yes |  | ≥ 0 | UTF-16 start offset. |
| `style.font_size` | number |  |  | 1–2000 | Type size in pixels. |
| `style.horizontal_scale` | number 0.1–10 \| null |  |  |  | Width stretch; null is 1. |
| `style.leading` | number |  |  | 0–5000 | Baseline to baseline in pixels; 0 is auto. |
| `style.size_runs` | array of object |  |  | ≤ 100000 items | Optional per-range font sizes in pixels. Ranges use zero-based UTF-16 offsets; fields are location, length and font_size. |
| `style.size_runs[].font_size` | number | yes |  | 1–2000 | Font size in pixels. |
| `style.size_runs[].length` | integer | yes |  | ≥ 1 | UTF-16 range length. |
| `style.size_runs[].location` | integer | yes |  | ≥ 0 | UTF-16 start offset. |
| `style.tracking` | number |  |  | -100–1000 | Extra space after each letter. |

### `fit_text` — Fit text to a width

**Effect:** additive, idempotent

Shrinks a point-text layer's type (never grows it) to the largest size, in 0.1 px steps, whose text is at most max_width document pixels wide. It keeps its anchor; set leading and tracking shrink along. Paragraph text is refused.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The text layer. |
| `max_width` | number | yes |  | ≥ 1 | The widest the text may be, in document pixels. |

### `get_text_metrics` — Get text metrics

**Effect:** read-only, idempotent

Measures a text layer, or 'text' in a 'style', as Compositor lays it out. Returns box, text width and height, lines [{text, width, baseline}], line height, ascent, descent, overflows, and the font used (font_available false for a substitute); for a layer, scale and bounds give document pixels.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string |  |  |  | The text layer to measure. |
| `style` | object |  |  |  | Style fields; any left out keep their values. |
| `style.alignment` | string |  |  | `left`, `center`, `right` | Line alignment. |
| `style.box_size` | object {width, height} \| null |  |  |  | Paragraph text: the box it wraps in, padding included. null: point text. |
| `style.color` | object {r, g, b} \| string `^#[0-9A-Fa-f]{6}$` \| one of `foreground`, `background` |  |  |  | Text color: {r, g, b}, "#rrggbb", "foreground" or "background". |
| `style.color_runs` | array of object |  |  | ≤ 100000 items | Optional per-range colors. Ranges use zero-based UTF-16 offsets; fields are location, length, red, green and blue. |
| `style.color_runs[].blue` | number | yes |  | 0–1 | Blue component. |
| `style.color_runs[].green` | number | yes |  | 0–1 | Green component. |
| `style.color_runs[].length` | integer | yes |  | ≥ 1 | UTF-16 range length. |
| `style.color_runs[].location` | integer | yes |  | ≥ 0 | UTF-16 start offset. |
| `style.color_runs[].red` | number | yes |  | 0–1 | Red component. |
| `style.font_name` | string |  |  |  | PostScript name (list_fonts); a missing font draws with a substitute (check_fonts). |
| `style.font_runs` | array of object |  |  | ≤ 100000 items | Optional per-range font faces. Ranges use zero-based UTF-16 offsets; fields are location, length and font_name. |
| `style.font_runs[].font_name` | string | yes |  |  | PostScript font name. |
| `style.font_runs[].length` | integer | yes |  | ≥ 1 | UTF-16 range length. |
| `style.font_runs[].location` | integer | yes |  | ≥ 0 | UTF-16 start offset. |
| `style.font_size` | number |  |  | 1–2000 | Type size in pixels. |
| `style.horizontal_scale` | number 0.1–10 \| null |  |  |  | Width stretch; null is 1. |
| `style.leading` | number |  |  | 0–5000 | Baseline to baseline in pixels; 0 is auto. |
| `style.size_runs` | array of object |  |  | ≤ 100000 items | Optional per-range font sizes in pixels. Ranges use zero-based UTF-16 offsets; fields are location, length and font_size. |
| `style.size_runs[].font_size` | number | yes |  | 1–2000 | Font size in pixels. |
| `style.size_runs[].length` | integer | yes |  | ≥ 1 | UTF-16 range length. |
| `style.size_runs[].location` | integer | yes |  | ≥ 0 | UTF-16 start offset. |
| `style.tracking` | number |  |  | -100–1000 | Extra space after each letter. |
| `text` | string |  |  |  | Text to measure instead of a layer. |

### `list_fonts` — List fonts

**Effect:** read-only, idempotent

Lists installed fonts by family: postscript_name (what font_name takes), family, style, weight and italic, filtered by query; total and truncated say what limit left out.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `limit` | integer |  | `200` | 1–5000 | Most fonts to return. |
| `query` | string |  |  |  | Text to look for. |

### `check_fonts` — Check fonts

**Effect:** read-only, idempotent

Checks PostScript font names: whether each is available, or the substitute drawn instead (family_match when from the same family), and lists the document's text layers whose font is missing.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `names` | array of string |  |  | 1–200 items | PostScript names. |

## Shapes

### `add_solid_fill` — Add solid fill

**Effect:** additive

Adds an editable solid-color fill across the whole canvas. It is a live rectangle shape, so set_shape_style can change its color; masks, opacity, blending and effects work as for other layers.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `color` | object {r, g, b} \| string `^#[0-9A-Fa-f]{6}$` \| one of `foreground`, `background` |  |  |  | The fill color. Defaults to the foreground color. {r, g, b} in 0–1, "#rrggbb", "foreground" or "background". |
| `name` | string |  |  |  | Layer name. Defaults to 'Solid Color Fill N'. |

### `add_shape` — Add shape

**Effect:** additive

Adds a live shape layer: a rectangle or ellipse filling rect, or a line from start to end, in color (default the foreground). corner_radius rounds a rectangle, line_width sets a line's thickness, and stroke outlines a rectangle or ellipse, growing the layer's box. Returns the id, transform and shape.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `kind` | string | yes |  | `rectangle`, `ellipse`, `line` | The shape. |
| `color` | object {r, g, b} \| string `^#[0-9A-Fa-f]{6}$` \| one of `foreground`, `background` |  |  |  | The fill color (a line's color). Defaults to the foreground color. {r, g, b} in 0–1, "#rrggbb", "foreground" or "background". |
| `corner_radius` | number |  | `0` | 0–5000 | A rectangle's corner radius. |
| `end` | object |  |  |  | A line's end. |
| `end.x` | number | yes |  |  |  |
| `end.y` | number | yes |  |  |  |
| `line_width` | number |  | `4` | 1–5000 | A line's thickness. |
| `name` | string |  |  |  | Layer name. |
| `rect` | object |  |  |  | The box a rectangle or ellipse fills. |
| `rect.x` | number | yes |  |  |  |
| `rect.y` | number | yes |  |  |  |
| `rect.width` | number | yes |  | ≥ 0 |  |
| `rect.height` | number | yes |  | ≥ 0 |  |
| `start` | object |  |  |  | A line's start. |
| `start.x` | number | yes |  |  |  |
| `start.y` | number | yes |  |  |  |
| `stroke` | object |  |  |  | Stroke around a rectangle or ellipse; fields left out keep their values (new: 1 px, black, inside). |
| `stroke.width` | number |  |  | 0–500 | Width in pixels. |
| `stroke.alignment` | string |  |  | `center`, `inside`, `outside` | Where it lies against the edge. |
| `stroke.color` | object {r, g, b} \| string `^#[0-9A-Fa-f]{6}$` \| one of `foreground`, `background` |  |  |  | The stroke's color. {r, g, b} in 0–1, "#rrggbb", "foreground" or "background". |
| `stroke.enabled` | boolean |  |  |  | Draw it (off keeps its settings). |

### `set_shape_style` — Set shape style

**Effect:** additive, idempotent

Changes a live shape layer's color, corner_radius, line_width or stroke (patched; null removes it). The shape keeps its size and place; the layer's box grows or shrinks around a changed stroke.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The shape layer. |
| `color` | object {r, g, b} \| string `^#[0-9A-Fa-f]{6}$` \| one of `foreground`, `background` |  |  |  | The fill color (a line's color). {r, g, b} in 0–1, "#rrggbb", "foreground" or "background". |
| `corner_radius` | number |  |  | 0–5000 | A rectangle's corner radius. |
| `line_width` | number |  |  | 1–5000 | A line's thickness. |
| `stroke` | object {width, alignment, color, enabled} \| null |  |  |  | Stroke around a rectangle or ellipse; fields left out keep their values (new: 1 px, black, inside). |
| `stroke.width` | number |  |  | 0–500 | Width in pixels. |
| `stroke.alignment` | string |  |  | `center`, `inside`, `outside` | Where it lies against the edge. |
| `stroke.color` | object {r, g, b} \| string `^#[0-9A-Fa-f]{6}$` \| one of `foreground`, `background` |  |  |  | The stroke's color. {r, g, b} in 0–1, "#rrggbb", "foreground" or "background". |
| `stroke.enabled` | boolean |  |  |  | Draw it (off keeps its settings). |

## Smart objects

### `place_smart_object` — Place smart object

**Effect:** additive

Places a file as a new smart object, which keeps the file whole so it can be replaced later: PNG, JPEG, TIFF, GIF, SVG, PDF or PSD (not PSB or EPS), up to 512 MiB. It takes its own size, shrunk to the canvas, centered on 'center', or goes in fit_rect as fit says.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `path` | string | yes |  |  | The file to place. |
| `center` | object |  |  |  | Where its center goes (not with fit_rect). |
| `center.x` | number | yes |  |  |  |
| `center.y` | number | yes |  |  |  |
| `fit` | string |  |  | `fit`, `fill`, `stretch` | How the contents go in fit_rect (only with it; default fit): fit inside or fill keeping proportions, centered (fill crops them and keeps the crop as the contents), or stretch. |
| `fit_rect` | object |  |  |  | A box to fit the contents in. |
| `fit_rect.x` | number | yes |  |  |  |
| `fit_rect.y` | number | yes |  |  |  |
| `fit_rect.width` | number | yes |  | ≥ 0 |  |
| `fit_rect.height` | number | yes |  | ≥ 0 |  |
| `name` | string |  |  |  | Layer name (default the file name). |

### `replace_smart_object_contents` — Replace smart object contents

**Effect:** destructive

Replaces a smart object's contents with a file and draws them in the object's placement (its quad) as fit says. The name, effects, mask and Photoshop settings stay, and contents_revision goes up.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The smart object. |
| `path` | string | yes |  |  | The file with the new contents. |
| `fit` | string |  | `"fit"` | `fit`, `fill`, `stretch` | How the new contents go in the object's quad: fit inside or fill keeping proportions, centered (fill crops them and keeps the crop as the contents), or stretch. |

### `get_smart_object_info` — Get smart object info

**Effect:** read-only, idempotent

Describes a smart object's contents: file_type, file_name, bytes (null when not held), natural_size, quad (where they are placed, in document pixels), embedded and contents_revision.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The smart object. |

### `export_smart_object_contents` — Export smart object contents

**Effect:** destructive, idempotent

Writes a smart object's contents to a file exactly as the document holds them (the placed PNG, PDF or PSD), to edit elsewhere and bring back with replace_smart_object_contents. A path without an extension takes theirs.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The smart object. |
| `path` | string | yes |  |  | Where to write the contents. |
| `overwrite` | boolean |  | `false` |  | Replace a file at path. |

## Layer effects

### `set_layer_effects` — Set layer effects

**Effect:** destructive, idempotent

Sets a layer's effects: stroke, shadow, color_overlay, inner_shadow, outer_glow and inner_glow. With merge (the default) only given fields change, a new effect starts from add_layer_effect's defaults and null removes one; merge false replaces the set. Unknown or out-of-range fields fail naming the field (color components clamp). Folders, adjustments and empty layers take no effects.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `effects` | object | yes |  |  | Effects to set, each its fields or null to remove it. |
| `effects.color_overlay` | object {color, enabled, opacity} \| null |  |  |  | Color Overlay. |
| `effects.color_overlay.color` | object {r, g, b} \| string `^#[0-9A-Fa-f]{6}$` |  |  |  |  |
| `effects.color_overlay.enabled` | boolean |  |  |  | false hides it. |
| `effects.color_overlay.opacity` | number |  |  | 0–1 | Opacity. |
| `effects.inner_glow` | object {color, enabled, opacity, size} \| null |  |  |  | Inner Glow. |
| `effects.inner_glow.color` | object {r, g, b} \| string `^#[0-9A-Fa-f]{6}$` |  |  |  |  |
| `effects.inner_glow.enabled` | boolean |  |  |  | false hides it. |
| `effects.inner_glow.opacity` | number |  |  | 0–1 | Opacity. |
| `effects.inner_glow.size` | number |  |  | 0–500 | Spread in pixels. |
| `effects.inner_shadow` | object {angle, blur, color, distance, enabled, opacity} \| null |  |  |  | Inner Shadow. |
| `effects.inner_shadow.angle` | number |  |  | -360–360 | Light angle, degrees counterclockwise from the right; 90 is from above. |
| `effects.inner_shadow.blur` | number |  |  | 0–500 | Softness in pixels. |
| `effects.inner_shadow.color` | object {r, g, b} \| string `^#[0-9A-Fa-f]{6}$` |  |  |  |  |
| `effects.inner_shadow.distance` | number |  |  | 0–5000 | Offset in pixels. |
| `effects.inner_shadow.enabled` | boolean |  |  |  | false hides it. |
| `effects.inner_shadow.opacity` | number |  |  | 0–1 | Opacity. |
| `effects.outer_glow` | object {color, enabled, opacity, size} \| null |  |  |  | Outer Glow. |
| `effects.outer_glow.color` | object {r, g, b} \| string `^#[0-9A-Fa-f]{6}$` |  |  |  |  |
| `effects.outer_glow.enabled` | boolean |  |  |  | false hides it. |
| `effects.outer_glow.opacity` | number |  |  | 0–1 | Opacity. |
| `effects.outer_glow.size` | number |  |  | 0–500 | Spread in pixels. |
| `effects.shadow` | object {angle, blur, color, distance, enabled, opacity} \| null |  |  |  | Drop Shadow. |
| `effects.shadow.angle` | number |  |  | -360–360 | Light angle, degrees counterclockwise from the right; 90 is from above. |
| `effects.shadow.blur` | number |  |  | 0–500 | Softness in pixels. |
| `effects.shadow.color` | object {r, g, b} \| string `^#[0-9A-Fa-f]{6}$` |  |  |  |  |
| `effects.shadow.distance` | number |  |  | 0–5000 | Offset in pixels. |
| `effects.shadow.enabled` | boolean |  |  |  | false hides it. |
| `effects.shadow.opacity` | number |  |  | 0–1 | Opacity. |
| `effects.stroke` | object {color, enabled, inside, opacity, size} \| null |  |  |  | Stroke. |
| `effects.stroke.color` | object {r, g, b} \| string `^#[0-9A-Fa-f]{6}$` |  |  |  |  |
| `effects.stroke.enabled` | boolean |  |  |  | false hides it. |
| `effects.stroke.inside` | boolean |  |  |  | Inside the layer's edge. |
| `effects.stroke.opacity` | number |  |  | 0–1 | Opacity. |
| `effects.stroke.size` | number |  |  | 0–500 | Width in pixels. |
| `merge` | boolean |  | `true` |  | Patch the current effects; false replaces them. |

### `add_layer_effect` — Add layer effect

**Effect:** additive

Adds one effect at the app's defaults (a new stroke or color overlay takes the background color), then applies 'settings'; on an effect the layer has, only the settings change. No panel opens.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `kind` | string | yes |  | `stroke`, `drop_shadow`, `color_overlay`, `inner_shadow`, `outer_glow`, `inner_glow` | Effect kind. |
| `settings` | object |  |  |  | Its fields, as set_layer_effects takes them. |

### `remove_layer_effect` — Remove layer effect

**Effect:** destructive

Removes one effect from a layer; not_found when it has none of that kind.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `kind` | string | yes |  | `stroke`, `drop_shadow`, `color_overlay`, `inner_shadow`, `outer_glow`, `inner_glow` | Effect kind. |

### `set_layer_effect_enabled` — Show or hide layer effect

**Effect:** additive, idempotent

Shows or hides one of a layer's effects, keeping its settings.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `enabled` | boolean | yes |  |  | Show it. |
| `kind` | string | yes |  | `stroke`, `drop_shadow`, `color_overlay`, `inner_shadow`, `outer_glow`, `inner_glow` | Effect kind. |

## Adjustment layers and profiles

### `add_adjustment_layer` — Add adjustment layer

**Effect:** additive

Adds an adjustment layer of 'kind' above the active layer, optionally named, clipped to the layer below (clip_to_below) and configured with 'settings' as set_adjustment takes them, as one step. A Profile layer is named after its profile; no settings panel opens.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `kind` | string | yes |  | `hue_saturation`, `levels`, `curves`, `exposure`, `gradient_map`, `grain`, `add_noise`, `gaussian_blur`, `motion_blur`, `invert`, `black_white`, `color_balance`, `profile` | Adjustment kind. |
| `clip_to_below` | boolean |  | `false` |  | Clip to the layer below, adjusting only it. |
| `name` | string |  |  |  | Layer name (default the kind, or the profile). |
| `settings` | object |  |  |  | Settings, as set_adjustment takes them. |

### `set_adjustment` — Set adjustment

**Effect:** additive, idempotent

Changes an adjustment layer's settings; only what is given changes. Shorthand keys — hue_saturation: hue, saturation, lightness, colorize; levels: channel, black, gamma, white, output_black, output_white; curves: channel, points [[x, y], …]; exposure: exposure, offset, gamma; gradient_map: shadows, highlights, reversed; grain: amount, size, roughness; gaussian_blur: radius; motion_blur: angle, distance; add_noise: amount, gaussian, monochromatic; black_white: reds…magentas, tint, tint_hue, tint_saturation; color_balance: shadow_, mid_ or highlight_ cyan_red, magenta_green, yellow_blue, preserve_luminosity; profile: profile (a list_profiles id or name; null for none), amount (0–200). The full settings it returns patch too: objects merge, arrays replace, null removes. An unknown or out-of-range key fails naming the field.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The adjustment layer. |
| `settings` | object | yes |  |  | Shorthand keys, or the full form this tool returns. |

### `list_profiles` — List profiles

**Effect:** read-only, idempotent

Lists the Lightroom and Camera Raw profiles Compositor can apply as a Profile adjustment layer, installed and imported, with id, group, fidelity and hidden counts. Pass an id, Adobe UUID, "Group/Name" or name as 'profile' to add_adjustment_layer (kind profile) or set_adjustment.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `group` | string |  |  |  | Only this group. |
| `include_unusable` | boolean |  | `false` |  | Also list profiles it can't apply, with the reason. |
| `limit` | integer |  | `100` | 1–500 | Most profiles to return. |
| `offset` | integer |  | `0` | ≥ 0 | Profiles to skip, for paging. |
| `query` | string |  |  |  | Text to find in names, groups and files. |
| `refresh` | boolean |  | `false` |  | Scan the profile folders again. |

### `import_profile` — Import profile

**Effect:** additive, idempotent

Imports Lightroom or Camera Raw profiles (.xmp files with PresetType Look), a file or a folder searched recursively (up to 1,000 files), into Compositor's profile library. Files it refuses are listed in skipped with a code.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `path` | string | yes |  |  | A .xmp profile or a folder of them. |

## Selection

### `select_rect` — Select rectangle

**Effect:** additive

Selects a rectangle (Rectangular Marquee), combined with the current selection by mode and clipped to the canvas.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `rect` | object | yes |  |  | The rectangle to select, in document pixels. |
| `rect.x` | number | yes |  |  |  |
| `rect.y` | number | yes |  |  |  |
| `rect.width` | number | yes |  | ≥ 0 |  |
| `rect.height` | number | yes |  | ≥ 0 |  |
| `antialiased` | boolean |  | `true` |  | Smooth edges. |
| `mode` | string |  | `"replace"` | `replace`, `add`, `subtract` | How it combines with the current selection. |

### `select_ellipse` — Select ellipse

**Effect:** additive

Selects the ellipse filling a rectangle (Elliptical Marquee), combined with the current selection by mode and clipped to the canvas.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `rect` | object | yes |  |  | The rectangle the ellipse fills, in document pixels. |
| `rect.x` | number | yes |  |  |  |
| `rect.y` | number | yes |  |  |  |
| `rect.width` | number | yes |  | ≥ 0 |  |
| `rect.height` | number | yes |  | ≥ 0 |  |
| `antialiased` | boolean |  | `true` |  | Smooth edges. |
| `mode` | string |  | `"replace"` | `replace`, `add`, `subtract` | How it combines with the current selection. |

### `select_polygon` — Select polygon

**Effect:** additive

Selects the polygon through 3 or more points (Polygonal Lasso), combined with the current selection by mode and clipped to the canvas.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `points` | array of object | yes |  | 3–10000 items | The corners in order, in document pixels; the outline closes itself. |
| `points[].x` | number | yes |  |  |  |
| `points[].y` | number | yes |  |  |  |
| `antialiased` | boolean |  | `true` |  | Smooth edges. |
| `mode` | string |  | `"replace"` | `replace`, `add`, `subtract` | How it combines with the current selection. |

### `select_all` — Select all

**Effect:** additive, idempotent

Selects the whole canvas.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |

### `select_none` — Deselect

**Effect:** additive, idempotent

Removes the selection, so edits apply to whole layers again.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |

### `invert_selection` — Invert selection

**Effect:** additive

Selects everything on the canvas outside the current selection; needs a selection.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |

### `select_by_color` — Select by color

**Effect:** additive

Selects pixels similar in color to the one at (x, y) (Magic Wand), read from the active layer or with sample_all_layers from the composite. The app's Magic Wand settings are left alone.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `x` | number | yes |  |  | x of the pixel to match, in document pixels. |
| `y` | number | yes |  |  | y of the pixel to match, in document pixels. |
| `contiguous` | boolean |  | `true` |  | Only pixels connected to (x, y). |
| `mode` | string |  | `"replace"` | `replace`, `add`, `subtract` | How it combines with the current selection. |
| `sample_all_layers` | boolean |  | `false` |  | Read the composite, not the active layer. |
| `sample_size` | string |  | `"point"` | `point`, `3x3`, `5x5` | Area averaged into the sample. |
| `tolerance` | integer |  | `32` | 0–255 | How far each channel may differ. |

### `select_object` — Select object

**Effect:** additive

Selects the object Vision finds under (x, y) (Object Selection); nothing found leaves no selection in replace mode.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `x` | number | yes |  |  | x of a point on the object, in document pixels. |
| `y` | number | yes |  |  | y of a point on the object, in document pixels. |
| `edge_offset` | integer |  | `0` | -10–10 | Pixels to shrink (positive) or grow the outline. |
| `mode` | string |  | `"replace"` | `replace`, `add`, `subtract` | How it combines with the current selection. |
| `sample_all_layers` | boolean |  | `true` |  | Read the composite, not the active layer. |

### `select_subject` — Select subject

**Effect:** additive

Selects the main subject Vision finds in the composite; when none is found the selection stays and found is false.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `mode` | string |  | `"replace"` | `replace`, `add`, `subtract` | How it combines with the current selection. |

### `load_layer_selection` — Load layer selection

**Effect:** additive

Selects a layer's pixels that are at least 50% opaque, ignoring its mask, or with source mask the white (revealed) areas of its mask.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `mode` | string |  | `"replace"` | `replace`, `add`, `subtract` | How it combines with the current selection. |
| `source` | string |  | `"pixels"` | `pixels`, `mask` | The layer's opaque pixels, or its mask's white areas. |

### `modify_selection` — Modify selection

**Effect:** additive

Expands, contracts or feathers the selection by 'amount' pixels (feather up to 250).

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `amount` | integer | yes |  | 1–500 | Pixels (feather up to 250). |
| `operation` | string | yes |  | `expand`, `contract`, `feather` | The change. |

### `transform_selection` — Transform selection

**Effect:** additive

Scales the selection outline about 'around' (default its center) and moves it by dx, dy; pixels stay put.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `around` | object |  |  |  | Fixed point while scaling (default the center). |
| `around.x` | number | yes |  |  |  |
| `around.y` | number | yes |  |  |  |
| `dx` | number |  | `0` |  | Horizontal offset. |
| `dy` | number |  | `0` |  | Vertical offset. |
| `scale_x` | number |  | `1` | 0.01–100 | Horizontal scale. |
| `scale_y` | number |  | `1` | 0.01–100 | Vertical scale. |

### `move_selected_pixels` — Move selected pixels

**Effect:** destructive

Moves a layer's selected pixels by whole pixels, leaving transparency behind (or with duplicate a copy), and moves the outline with them.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `dx` | number | yes |  |  | Horizontal offset, rounded to whole pixels. |
| `dy` | number | yes |  |  | Vertical offset, rounded to whole pixels. |
| `duplicate` | boolean |  | `false` |  | Move a copy, keeping the original. |

### `get_selection` — Get selection

**Effect:** read-only, idempotent

Reports the selection: whether it exists or is empty, bounds, feather, antialiasing, and with include_path its outline as SVG path data (up to 256 KiB, then path_truncated).

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `include_path` | boolean |  | `false` |  | Also return the outline as SVG path data. |

## Pixels and painting

### `fill_selection` — Fill selection

**Effect:** destructive

Fills the selection (the whole layer without one) on a layer's pixels, or its mask with target mask, with a color, the foreground or the background. A text layer filled whole takes the color and stays editable. On a mask, colors paint as gray and foreground and background are the app's mask colors.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `color` | object {r, g, b} \| string `^#[0-9A-Fa-f]{6}$` |  |  |  | Fill color. {r, g, b} in 0–1, or "#rrggbb". |
| `target` | string |  | `"pixels"` | `pixels`, `mask` | The layer's pixels, or its mask. |
| `with` | string |  |  | `color`, `foreground`, `background` | Fill source (default color when given, else foreground). |

### `clear_selection` — Clear selection

**Effect:** destructive

Clears a layer's selected pixels to transparency; on its mask (target mask) the selection fills with the app's mask background, white unless swapped. Needs a selection.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `target` | string |  | `"pixels"` | `pixels`, `mask` | The layer's pixels, or its mask. |

### `invert_pixels` — Invert pixels

**Effect:** destructive

Inverts a layer's colors, keeping transparency, or its mask with target mask, inside the selection when there is one.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `target` | string |  | `"pixels"` | `pixels`, `mask` | The layer's pixels, or its mask. |

### `stroke_path` — Stroke path

**Effect:** destructive

Paints one brush stroke through 'points' on a layer's pixels, or its mask with target mask, with this call's brush and no smoothing, inside the selection when there is one. mode: paint (brush.color, default the foreground, or on a mask the app's mask foreground), erase, heal (heal_mode), clone (from clone.source), blur, smudge or liquify; masks take paint and blur.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `points` | array of object | yes |  | 1–10000 items | The path; one point paints a dab. |
| `points[].x` | number | yes |  |  |  |
| `points[].y` | number | yes |  |  |  |
| `brush` | object |  |  |  | The brush tip. |
| `brush.color` | object {r, g, b} \| string `^#[0-9A-Fa-f]{6}$` |  |  |  | Paint color (default the foreground). {r, g, b} in 0–1, or "#rrggbb". |
| `brush.diameter` | number |  | `40` | 1–2000 | Tip diameter. |
| `brush.hardness` | number |  | `1` | 0–1 | 0 soft to 1 hard. |
| `brush.opacity` | number |  | `1` | 0.01–1 | Most coverage. |
| `clone` | object |  |  |  | For clone: where to copy from. |
| `clone.source` | object | yes |  |  | Where the first point copies from. |
| `clone.source.x` | number | yes |  |  |  |
| `clone.source.y` | number | yes |  |  |  |
| `clone.aligned` | boolean |  | `true` |  | Photoshop's Aligned (one stroke per call). |
| `clone.sample_all_layers` | boolean |  | `false` |  | Copy from the composite. |
| `heal_mode` | string |  | `"content_aware"` | `content_aware`, `create_texture`, `proximity_match` | How heal rebuilds. |
| `mode` | string |  | `"paint"` | `paint`, `erase`, `heal`, `clone`, `blur`, `smudge`, `liquify` | What it does. |
| `target` | string |  | `"pixels"` | `pixels`, `mask` | The layer's pixels, or its mask. |

### `draw_gradient` — Draw gradient

**Effect:** destructive

Draws a linear or radial gradient from start to end on a layer's pixels, or its mask with target mask, inside the selection when there is one. Its ends are colors {from, to}, each a color or "transparent", or a palette style; a radial one centers on start. On a mask, colors paint as gray.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `end` | object | yes |  |  | End (on a radial one's rim). |
| `end.x` | number | yes |  |  |  |
| `end.y` | number | yes |  |  |  |
| `start` | object | yes |  |  | Start (a radial one's center). |
| `start.x` | number | yes |  |  |  |
| `start.y` | number | yes |  |  |  |
| `colors` | object |  |  |  | End colors (or give style). |
| `colors.from` | object \| string \| one of `transparent` | yes |  |  | Start color or "transparent". |
| `colors.to` | object \| string \| one of `transparent` | yes |  |  | End color or "transparent". |
| `opacity` | number |  | `1` | 0.01–1 | Coverage. |
| `reversed` | boolean |  | `false` |  | Swap the ends. |
| `shape` | string |  | `"linear"` | `linear`, `radial` | Shape. |
| `style` | string |  |  | `foreground_to_background`, `foreground_to_transparent` | Palette ends; foreground_to_transparent when neither this nor colors is given. |
| `target` | string |  | `"pixels"` | `pixels`, `mask` | The layer's pixels, or its mask. |

### `get_layer_pixels` — Get layer pixels

**Effect:** additive, idempotent

Returns a layer's own pixels (before opacity, mask, effects and blending), or with target mask its mask as gray, as a PNG image scaled down to max_size, then JSON with the sizes and transform. Hidden layers are read too; save_to also writes the full-size PNG.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `max_size` | integer |  | `1024` | 16–4096 | Longest side of the returned image; larger rasters scale down. |
| `overwrite` | boolean |  | `false` |  | Replace a file at save_to. |
| `save_to` | string |  |  |  | A .png path for the full-size pixels. |
| `target` | string |  | `"pixels"` | `pixels`, `mask` | The layer's pixels, or its mask. |

### `set_layer_pixels` — Set layer pixels

**Effect:** destructive

Replaces a layer's pixels with an image file, placed by 'placement'. keep_bounds stretches it over the layer's box, keep_origin puts it at its own size at the box's top-left, natural at its own size, upright, centered where the layer was. Text and shape layers become pixels.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `path` | string | yes |  |  | Image file. |
| `placement` | string |  | `"keep_bounds"` | `keep_bounds`, `keep_origin`, `natural` | Where the pixels go. |

### `paste_image_into_layer` — Paste image into layer

**Effect:** destructive

Draws an image file into a layer's pixels with its top-left at (x, y), one image pixel per document pixel, inside the canvas and the selection: over draws it on top, replace swaps in its pixels.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `x` | number | yes |  |  | Left edge. |
| `y` | number | yes |  |  | Top edge. |
| `path` | string | yes |  |  | Image file. |
| `mode` | string |  | `"over"` | `over`, `replace` | over or replace. |

### `copy_pixels` — Copy pixels

**Effect:** additive, idempotent

Copies a layer's selected pixels (all of them without a selection), or with merged the visible composite (the canvas without a selection), to Compositor's clipboard and the system pasteboard. It returns the region copied.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string |  |  |  | The layer to copy from (default the active layer; not with merged). |
| `merged` | boolean |  | `false` |  | Copy the composite. |

### `paste_pixels` — Paste pixels

**Effect:** additive

Pastes the clipboard as a new layer above the active layer: pixels copied in Compositor go back where they came from, other images are centered, or x and y place the top-left. The selection is dropped.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `x` | number |  |  |  | Left edge (with y). |
| `y` | number |  |  |  | Top edge (with x). |

## Filters and destructive adjustments

### `apply_filter` — Apply filter

**Effect:** destructive

Runs a filter on a layer's pixels, inside the selection when there is one, without a panel. 'settings' takes set_adjustment's keys for the same kind, or the full form it reports; a filter without an adjustment layer takes its panel's sliders (an unknown key's error lists them), and Vignette also paints an empty layer. Unset settings are the filter's defaults, not the app's last-used ones; a filter that changes nothing records nothing.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `kind` | string | yes |  | `gaussian_blur`, `motion_blur`, `add_noise`, `vignette`, `bloom_glow`, `dither`, `tonal_contrast`, `lens_correction`, `camera_raw_filter`, `curves`, `exposure`, `gradient_map`, `grain`, `black_white`, `color_balance` | The filter. |
| `settings` | object |  |  |  | Settings to change from the defaults. |

### `apply_levels` — Apply levels

**Effect:** destructive

Applies Levels to a layer's pixels, inside the selection when there is one: one channel's black, gamma, white, output_black and output_white, or 'ranges' for all four (rgb, red, green, blue). 'auto' (contrast, color or neutral) sets them from the histogram first.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `auto` | string |  |  | `contrast`, `color`, `neutral` | Start from automatic levels. |
| `settings` | object |  |  |  | One channel's range, or ranges for all four. |

### `apply_hue_saturation` — Apply hue/saturation

**Effect:** destructive

Applies Hue/Saturation to a layer's pixels, inside the selection when there is one. hue (−180…180, or 0–360 with colorize), saturation and lightness (−100…100) change 'range' (default master); 'adjustments' sets several ranges; bands and invert_range tune which hues a range covers.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `settings` | object | yes |  |  | hue, saturation, lightness, range, colorize, adjustments, bands, invert_range. |

### `content_aware_fill` — Content-aware fill

**Effect:** destructive

Fills the selection on a layer's pixels with texture from the pixels around it (Content-Aware Fill); needs a selection that leaves enough of the layer to copy from.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |

### `remove_background` — Remove background

**Effect:** additive

Masks out a layer's background, keeping the subject Vision finds, with a layer mask that is black over the background; nothing is erased, and a mask already there is combined. quality advanced refines the edge (refine_edges, matte_contrast, shift_edge). Fails when no subject is found.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `matte_contrast` | number |  | `25` | 0–100 | Advanced: matte contrast. |
| `quality` | string |  | `"basic"` | `basic`, `advanced` | advanced refines the edge. |
| `refine_edges` | number |  | `12` | 0–40 | Advanced: edge pull onto detail (0 off). |
| `shift_edge` | number |  | `0` | -10–10 | Advanced: contract (negative) or expand. |

## Masks

### `add_layer_mask` — Add layer mask

**Effect:** additive

Adds a mask to a layer or folder: reveal_all (white), hide_all (black), from_selection or hide_selection. Paint it with stroke_path, fill_selection, draw_gradient or invert_pixels (target: mask); black hides, white reveals.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `kind` | string |  | `"reveal_all"` | `reveal_all`, `hide_all`, `from_selection`, `hide_selection` | What the mask shows. |

### `set_mask_enabled` — Enable or disable layer mask

**Effect:** additive, idempotent

Turns a layer's mask on or off, keeping its pixels.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `enabled` | boolean | yes |  |  | Apply the mask. |

### `set_mask_linked` — Link or unlink layer mask

**Effect:** additive, idempotent

Links a layer's mask to it, so they move and transform together, or unlinks it, so the mask stays put on the document.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |
| `linked` | boolean | yes |  |  | Link it. |

### `delete_layer_mask` — Delete layer mask

**Effect:** destructive

Deletes a layer's mask, showing the whole layer again.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |

### `apply_layer_mask` — Apply layer mask

**Effect:** destructive

Applies a layer's mask to its pixels, making what it hides transparent, and removes it. Text and shape layers become pixels; folders, adjustment layers, a disabled mask and Lock Pixels are refused.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `layer` | string | yes |  |  | The layer: id, name, "Group/Child" path, or "@active". |

### `copy_layer_mask` — Copy layer mask

**Effect:** additive

Copies one layer's mask to another, replacing any mask it has, where the mask sits on the document. Folders can't take one.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `from` | string | yes |  |  | The layer whose mask is copied. |
| `to` | string | yes |  |  | The layer that takes the copy. |

## History and batches

### `undo` — Undo

**Effect:** destructive

Undoes the last 'steps' edits (default 1) as ⌘Z does, stopping when nothing is left, and returns undone and the undo state. Refused while the app holds the history (guard can_use_history) or an edit open (history_busy).

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `steps` | integer |  | `1` | ≥ 1 | Entries to undo. |

### `redo` — Redo

**Effect:** destructive

Redoes the last 'steps' undone edits (default 1) as ⇧⌘Z does, and returns redone and the undo state; refused when undo is.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `steps` | integer |  | `1` | ≥ 1 | Entries to redo. |

### `get_history` — Get history

**Effect:** read-only, idempotent

Lists undo_names (what undo steps back through, next first) and redo_names, their counts, whether undo and redo can run now, and whether there are unsaved changes.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |

### `run_batch` — Run batch

**Effect:** destructive

Runs up to 200 tool calls in order as one undo step named 'name' (default "Batch (n)"), each {tool, arguments} on this batch's document. It stops at the first failure (details.step, details.tool, completed, results); earlier steps stay unless rollback_on_error. Steps can't be close_document, duplicate_document, new_document, open_document, redo, revert_document, run_batch, select_document, settle_pending_edits or undo. Refused (guard can_use_history) while the app holds the history or an edit open: settle_pending_edits first.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `steps` | array of object | yes |  | 1–200 items | The calls, in order. |
| `steps[].tool` | string | yes |  |  | The tool's name, e.g. add_blank_layer. |
| `steps[].arguments` | object |  |  |  | The tool's arguments, without 'document'. |
| `name` | string |  |  |  | The undo entry's name. |
| `rollback_on_error` | boolean |  | `false` |  | On failure, undo the earlier steps too. |

## View and app window

### `zoom_to_fit` — Zoom to fit

**Effect:** additive, idempotent

Zooms and centers the canvas to fit the window, as ⌘0 does, and returns the zoom (1 is 100%). Only the view changes.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |

### `set_zoom` — Set zoom

**Effect:** additive, idempotent

Sets the canvas zoom (1 is 100%, 2 is 200%), clamped to 0.001–32 (clamped says so), keeping 'anchor', a document pixel, where it is on screen. Only the view changes.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `zoom` | number | yes |  |  | Zoom factor; 1 is 100%. |
| `anchor` | object |  |  |  | Document pixel kept in place (default the view's middle). |
| `anchor.x` | number | yes |  |  |  |
| `anchor.y` | number | yes |  |  |  |

### `select_tool` — Select tool

**Effect:** additive, idempotent

Selects a tool in the tool rail, ready for the user's clicks; crop starts a whole-canvas crop that holds other edits. Refused while an edit that switching would commit or cancel is open.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `tool` | string | yes |  | `move`, `marquee`, `lasso`, `wand`, `crop`, `brush`, `spot_healing`, `clone_stamp`, `blur`, `gradient`, `shape`, `type`, `eyedropper`, `hand`, `zoom`, `idle` | The tool (the app's own spellings, such as "spotHealing", work too). |

### `bring_app_to_front` — Bring Compositor to front

**Effect:** additive, idempotent

Brings Compositor's window to the front so the user sees your work; macOS may keep an app the user is typing in in front.

No parameters.

### `set_palette_colors` — Set palette colors

**Effect:** additive, idempotent

Sets the foreground and/or background color, the app's swatches that brushes, type, shapes and fills use. They belong to the app, not the document, so no undo step; mask painting keeps its own black and white.

| Parameter | Type | Required | Default | Allowed | Description |
|---|---|---|---|---|---|
| `document` | integer ≥ 0 \| string |  |  |  | Default: the current tab. |
| `background` | object {r, g, b} \| string `^#[0-9A-Fa-f]{6}$` |  |  |  | Background color. {r, g, b} in 0–1, or "#rrggbb". |
| `foreground` | object {r, g, b} \| string `^#[0-9A-Fa-f]{6}$` |  |  |  | Foreground color. {r, g, b} in 0–1, or "#rrggbb". |
