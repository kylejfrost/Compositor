---
name: compositor
description: Drive Compositor, the macOS layered image editor, through its MCP tools (mcp__compositor__* such as get_document, add_image_layer, render_document, export_image) to open or create documents, edit layers, text, shapes, masks, effects and adjustments, preview, and export PNG/JPEG or save .comp and PSD files. Use this skill first whenever Compositor's tools are available or the user mentions Compositor and wants an image made, edited, checked or exported (social graphics, banners, template fills, photo fixes, size variants), even if they only say "make the graphic" or "update the PSD". It holds what every call depends on (document and layer selectors, pixel coordinates, colors, one undo step per call and run_batch, overwrite and discard flags, errors, limits), the render-and-verify loop, and routes to the compositor-psd-templates, -layout-and-type, -image-editing, -variants-and-delivery and -setup skills. Prefer it to Photoshop scripting when Compositor can do the job.
---

# Compositor

Compositor is a local macOS image editor with a Photoshop-style layer model: pixel, text,
shape, smart-object, adjustment and folder layers, masks, clipping, effects and blend modes.
Its built-in MCP server gives an agent the same document model and undo stack as the app's
own menus, with no dialogs: every tool call either does its job or returns a structured
error. It opens `.comp` projects, layered Photoshop files (8-bit RGB `.psd` and `.psb`) and
PNG, JPEG, HEIC, TIFF, SVG and camera raw images; it saves `.comp` projects and layered `.psd` files, and
exports PNG and JPEG.

Prefer it to automating Photoshop when the job is layout, template filling, text, masks,
adjustments or exports: it runs unattended, needs no Photoshop license or open UI, and
each edit is one undoable step the owner can inspect in the app afterwards. Reach for
Photoshop when a job needs what Compositor doesn't model (CMYK or 16-bit output, vector
path editing, 3D, smart filters, artboards) and say so rather than approximating silently.

The owner may be working in the same app while you call it. Treat their open documents
and anything in progress on screen as theirs.

**Tool names depend on the client.** Claude Code, Codex and Hermes expose these tools as
`mcp__compositor__<tool>` (for example `mcp__compositor__get_document`); this skill uses the
bare names. When the client hides MCP tools behind a search step (Claude Code's tool search;
Hermes's `tool_search`, `tool_describe` and `tool_call`), load or call them by the full name —
in Hermes, `tool_call` with `{"calls":[{"name":"mcp__compositor__get_app_info","arguments":{}}]}`.
Steps inside `run_batch` use the bare names. In Hermes, previews (`render_*`) come back as
`MEDIA:<path>` text instead of pixels: call `vision_analyze` on that path to look at it, and
put `MEDIA:<exported file path>` in a chat reply to send an image. Hermes also pauses all of
Compositor's tools for a minute after three failed calls in a row, so check arguments
against the tool atlas before retrying.

## Start every session the same way

1. `get_app_info`: version, limits, the Agent folder that relative paths resolve into, and
   the formats this build opens, saves and exports (`features.save` lists `psd` when it
   writes Photoshop files). If Compositor's tools are missing, or calls fail before
   reaching a tool (connection refused, HTTP 401/421/403/405), use the **compositor-setup**
   skill. A 401 means the client lacks Compositor's current access token (it was
   regenerated, or the client was set up over HTTP without it): set the client up again
   through the `compositor-mcp` bridge, which sends the token by itself, and never turn
   **Require access token** off or print the token.
2. `list_documents`: which tabs are open, which is current and which have unsaved changes.
   Work in your own tab (`new_document` and `open_document` make the new tab current)
   instead of editing whatever the owner has on screen.
3. `get_document` on your target (`detail: "summary"` first; `"full"` when you need text,
   shape, effect, mask or smart-object settings): the layer tree with every layer's `id`,
   `path`, `kind`, `transform`, `locks` and `effective_locks`, plus `capabilities`, which
   says whether edits can run right now and what blocks them.

## Conventions every call depends on

Read [Addressing, coordinates and colors](references/addressing.md) the first time you
build arguments by hand; the essentials:

- **Documents**: most tools take an optional `document`: a tab index, a tab or document
  id, an exact tab title, or `"@current"` (the default). Pass it explicitly once more than
  one tab is open, so a tab switch in the app can't redirect your edit.
- **Layers**: `layer` / `layers` take a layer id (best: stable for the session), an exact
  name, a folder path such as `"Footer/Logo"` (`\/` escapes a slash inside a name), or
  `"@active"`. A name matching two layers fails as `ambiguous` with `details.candidates`
  (`id`, `path`, `kind`); retry with an id. Templates reuse names like "Layer 1", so copy
  ids from `get_document` rather than typing names.
- **Coordinates** are document pixels, origin at the top-left, x to the right, **y down**.
  Rectangles are `{x, y, width, height}`, points `{x, y}`. A layer's `transform` is its
  unrotated box (`x`, `y` top-left, `width`, `height`), then `rotation` clockwise in
  degrees and `flip_x`/`flip_y` about its center. A folder's own transform is canvas-sized;
  measure what a folder shows with `get_layer_bounds`.
- **Colors** are `{r, g, b}` with each channel 0–1, or `"#rrggbb"`. Opacity is 0–1 (not
  percent) and out-of-range values fail rather than clamp. Tools that default to "the
  foreground color" use the app's palette (`set_palette_colors`, not undoable).
- **One call, one undo step.** Every mutating result carries `undo: {name, count,
  recorded}`; `recorded: false` means this call added no undo entry, which is worth
  noticing (a value already set, a selector that hit the wrong layer). `run_batch` runs
  up to 200 calls as one step, stops at the first failure and can roll back. See
  [Undo, batches and pending edits](references/history-and-batches.md).
- **Nothing is overwritten or discarded silently.** Writing tools refuse an existing file
  unless you pass `overwrite: true` (`io_error`, `details.code: "file_exists"`); closing or
  reverting a document with unsaved changes needs `discard_changes: true` (guard
  `unsaved_changes`); `save_document` never writes over the Photoshop file or image a
  document was opened from. Pass those flags only when the user asked for that outcome,
  never to make an error go away.
- **Paths** may be absolute, start with `~`, or be relative to the Agent folder
  (`get_app_info.agent_folder`), which macOS privacy prompts don't guard. Relative output
  paths keep deliverables together. When you report files, give the absolute `path` each
  result returns (or `agent_folder` joined with your relative path), exactly as the tool
  gave it: the Agent folder isn't always the default
  `~/Library/Application Support/Compositor/Agent`, and a relative name alone doesn't
  tell the user where to look.
- **One call at a time.** Calls run in arrival order across every client; firing them in
  parallel only fills the 64-call queue (`busy`). Wait for each result.
- **Shell checks** (`sips`, `shasum`, the skills' verification scripts): one command per
  call, with literal quoted absolute paths, not shell variables, `cd … &&` chains or
  `$(…)`. Agent setups often allow commands by their exact text, so a composite command
  stops for approval, or is refused when no one is there to approve it.

## The see → act → verify loop

Work in small, checked steps; an agent that edits blind ships misplaced text and clipped
images.

1. **See.** Read the state you are about to change: `get_document` or `get_layer` for
   structure and settings, `get_layer_bounds` for where a layer's pixels actually are
   (`content_bounds`, `effects_bounds`), `get_selection`, `list_guides`, and for text
   `get_text_metrics`. Render once before editing a document you didn't create, so you
   know what "unchanged" looks like.
2. **Act** with the most specific tool (a `set_*` setter over rebuilding a layer, a
   non-destructive adjustment layer over a pixel filter). Group a sequence that should undo
   together in `run_batch`. Read each result: ids of new layers, the resulting
   `transform`, `recorded`.
3. **Verify** what the user will judge:
   - `render_document` (image plus JSON) after each meaningful group of changes. The
     default `max_size` 1024 is plenty for layout; 512 is a cheap glance; the returned
     `scale` says how far it was shrunk.
   - `render_region` at full detail for small things: text edges, a logo, a seam.
   - `render_layer` to see one layer alone (even hidden), with or without its effects and
     mask.
   - `get_pixel_color` or `sample_colors` (up to 256 points in one call) when a value
     matters exactly: a brand color, a transparent corner, the background behind text.
   - For files: `export_image` reports `path`, `width`, `height` and `bytes`;
     `get_file_info` reads them back from disk (`image_size`), as does
     `sips -g pixelWidth -g pixelHeight <file>`.

   Previews are read-only images and never touch files; only `export_image`, the save
   tools, `get_layer_pixels` with `save_to` and `export_smart_object_contents` write
   files you name.
4. **Report** what changed, the paths written, and anything you could not do or had to
   approximate.

## When a call fails

Failures come back as a normal result with `isError: true` and `{"ok": false, "error":
{"code", "message", "guard"?, "hint"?, "details"?}}`. Read `hint` first: it names the tool
that fixes the problem. The common ones:

| Code | Usually means | Do |
|---|---|---|
| `invalid_argument` | A missing, wrong-type or out-of-range argument, or one the tool doesn't take (a misspelled name is refused, not ignored); `details.field` names it. | Fix that field; check the atlas entry. |
| `not_found` | No such document, layer, file, effect or tool. | Re-read `get_document` / `list_files`; relative paths start in the Agent folder. |
| `ambiguous` | A name matched several layers or tabs. | Use an id from `details.candidates`. |
| `precondition_failed` | The document's state refuses the call; `guard` says which check. | See the guard in [Errors and recovery](references/errors.md). |
| `busy` | Another operation, a full queue, or a macOS permission prompt. | Wait and retry once; don't loop. |
| `io_error` | A file exists (`file_exists`), can't be read or written, or macOS denied access. | Choose another path, pass `overwrite` only if asked, or see folder access. |
| `unsupported` | This build can't do it (a format, a layer kind). | Tell the user; offer the nearest supported route. |

`guard: "can_edit_layers"` means something is in progress in the app (text being typed, a
crop, a transform, a dialog); `capabilities.blocking_reason` in `get_document` says what.
If you started it (for example `select_tool` with `crop`), finish it with
`settle_pending_edits`; if the owner did, ask before committing or cancelling their work.
`guard: "layer_locked"` names the lock and, in `details.locked_by_id`, the layer or folder
holding it; template locks are deliberate, so unlock only what the task needs and relock
it afterwards.

## Which skill next

| The job | Skill |
|---|---|
| Fill a PSD template: swap the photo in a smart object, change text, keep locks, export, save a new PSD | **compositor-psd-templates** |
| Build a graphic from scratch, or fix an existing layout (off-center or misaligned elements, uneven spacing, text that runs over): canvas sizes, grids, text layout and fitting, shapes, placing images, alignment | **compositor-layout-and-type** |
| Photo and pixel work: selections, masks, background removal, adjustment layers, Lightroom profiles, filters, retouching, crop and resize | **compositor-image-editing** |
| Sets of outputs: sizes, copies, naming, JPEG and PNG settings, PSD delivery, verification, contact sheets | **compositor-variants-and-delivery** |
| Tools missing, connection errors, turning the server on, folder access | **compositor-setup** |
| Changing Compositor's own source code | **compositor-development** |

## References

- [Tool atlas](references/tool-atlas.md): every tool, grouped by domain, with each
  parameter's type, default, allowed values and description. Generated from `tools/list`;
  search it by tool name. The server's own schema wins if they ever disagree.
- [Addressing, coordinates and colors](references/addressing.md): selectors in depth,
  transforms, anchors, folders, colors, units, and the JSON shapes results use.
- [Undo, batches and pending edits](references/history-and-batches.md): undo steps,
  `run_batch` rules and rollback, pending edits and `settle_pending_edits`, saved state.
- [Errors and recovery](references/errors.md): every error code and guard, what causes it
  and how to recover, including locks, folder access and busy states.
- [Limits](references/limits.md): sizes, counts and ranges, from the app's own constants.

Regenerate the atlas after Compositor updates, with its MCP server running:
`python3 <skill>/scripts/tool-atlas.py`, where `<skill>` is this skill's base directory
(`--check` only reports drift; `--help` lists the other options).
