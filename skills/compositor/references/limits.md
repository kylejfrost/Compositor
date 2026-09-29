# Limits

The numbers Compositor enforces, taken from its source (`DocumentLimits`, `MCPSettings`,
`MCPToolRegistry`, `MCPRenderOptions`, `DocumentHistory`, `ProjectStore`, `PSDWriter`). `get_app_info` reports
the main ones at run time under `limits`; the atlas gives each parameter's own range.
Going past a limit fails cleanly (`invalid_argument` or `precondition_failed` with a
`guard`); nothing is silently truncated unless a row says so.

## Documents and canvas

| Limit | Value | Guard or note |
|---|---|---|
| Open documents (tabs) | 32 | `max_tabs` |
| Canvas side | 1–30,000 px | new, resize, crop, export |
| One surface | 200,000,000 px (200 MP) in any one canvas, export, filter target, text box or shape (`limits.max_pixels`) | `pixel_budget`; also a filled `new_document` |
| Document pixel budget | what an imported layer (image, SVG, PSD layers, pasted or copied layers) is checked against, not 200 MP: all the document's layers together, and masks as much again; scales with the Mac's memory, a quarter of it at 4 bytes a pixel, 200–800 MP (`limits.document_pixel_budget`) | `pixel_budget`; a PSD that wouldn't fit opens cropped to the canvas |
| Layers per document | 10,000, folders included | `max_layers` |
| Folder nesting | 64 levels | project format |
| Guides | 1,000 | `max_guides` |
| Resolution | 1–9,600 ppi | `new_document`, `resize_image`, `set_resolution` |
| `new_document` defaults | 1920 × 1080 px, 72 ppi, one transparent layer "Layer 1" | |

## Undo

| Limit | Value | Note |
|---|---|---|
| Undo entries | 100 per document | oldest dropped first |
| Retained pixels | about 256 MB per document | large steps drop older entries sooner |
| `run_batch` steps | 1–200 | one undo step |
| `undo` / `redo` `steps` | 1 or more | stops early when nothing is left |

## Previews, sampling and export

| Limit | Value | Note |
|---|---|---|
| Render `max_size` | 16–4,096 px, default 1,024 | longest side of the returned image; never scaled up |
| Render / export JPEG `quality` | 0–1, default 0.85 | ignored for PNG |
| `get_layer_pixels` `max_size` | 16–4,096 px, default 1,024 | `save_to` writes the full-size PNG |
| `sample_colors` points | 1–256 per call | |
| Export `scale` | 0.05–4 | result still capped at 30,000 px per side and 200 MP |
| Export `max_size` | 16–30,000 px | scales down to fit, never up |
| Export formats | PNG (transparent by default), JPEG (white background by default) | `background`: `transparent`, `white`, `black`, `checkerboard` |

## Selections, painting and transforms

| Limit | Value |
|---|---|
| `select_polygon` points | 3–10,000 |
| `stroke_path` points | 1–10,000 |
| Brush `diameter` | 1–2,000 px (`hardness` 0–1, `opacity` 0.01–1) |
| `select_by_color` `tolerance` | 0–255, default 32 |
| `select_object` `edge_offset` | −10 to 10 |
| `modify_selection` `amount` | 1–500 px to expand or contract, 1–250 px to feather |
| `transform_selection` `scale_x` / `scale_y` | 0.01–100 |
| Offsets (`dx`, `dy`, positions) | within ±1,000,000 px |
| `set_layer_scale` `percent` | 1–10,000 |
| `remove_background` | `refine_edges` 0–40 (default 12), `matte_contrast` 0–100 (default 25), `shift_edge` −10 to 10 |
| Effect sizes (stroke, outer glow, inner glow) | 0–500 px |
| `set_zoom` | 0.001–32 (clamped, and `clamped` says so) |

## Files

| Limit | Value | Note |
|---|---|---|
| `list_files` `limit` | 1–10,000, default 500 | `truncated` when more exist |
| Items one listing looks at | 100,000 | `truncated` |
| Folder-access check | about 2 s | then `folder_access_pending` instead of waiting |
| Opens | `.comp`, `.psd` and `.psb` (8-bit RGB), PNG, JPEG, HEIC, TIFF, SVG (as pixels), camera raw | a `.psb` is saved back as a `.psd` |
| Saves | `.comp` and layered `.psd` (`get_app_info.features.photoshop_save`) | |
| `.comp` project | 30,000 px per side, the document pixel budget in image pixels plus as much in mask pixels, 10,000 layers, 4 MiB manifest, 512 MiB per image; smart-object contents 512 MiB each, 2 GiB in all | |
| PSD written | 30,000 px per side, 200 MP canvas, 32,767 layer records, 4 GB of layer data | 8-bit RGB |

## Text and fonts

| Limit | Value |
|---|---|
| Font size | 1–2,000 px |
| Tracking | −100 to 1,000 px |
| Leading | 0–5,000 px (0 is auto, 120% of the size) |
| Paragraph `box_size` | 16–30,000 px per side, its 12 px padding included |
| Horizontal scale | 0.1–10 |
| `list_fonts` `limit` | 1–5,000, default 200 |
| `check_fonts` names | 1–200 per call |

## Server

| Limit | Value | Note |
|---|---|---|
| Queued or running calls, all clients | 64 | `busy` past it |
| Request body | 32 MB | HTTP 413 |
| Default port | 2667 on 127.0.0.1 | falls back to a free port when taken |
| `list_profiles` `limit` | 1–500, default 100 | `offset` pages |
| `import_profile` | 1,000 `.xmp` files per call | `truncated` |
