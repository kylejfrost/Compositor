# Errors and recovery

A failed call is a normal tool result with `isError: true` and this body:

```json
{"ok": false, "error": {"code": "precondition_failed", "message": "'Logo' is locked (position).",
  "guard": "layer_locked", "hint": "Unlock it with set_layer_locks, then retry.",
  "details": {"layer_id": "…", "locked_by_id": "…", "locks": ["position"]}}}
```

`code` is the class of failure, `guard` (for `precondition_failed` and some `busy`) the
check that refused, `hint` the next step in words, usually naming a tool, and `details`
machine-readable specifics. Read `hint` before improvising; retry only after changing
something, and never loop on the same call.

## Contents

- [Error codes](#error-codes)
- [Guards: document and app state](#guards-document-and-app-state)
- [Guards: layers, locks and structure](#guards-layers-locks-and-structure)
- [Guards: pixels, selections and masks](#guards-pixels-selections-and-masks)
- [Files, paths and folder access](#files-paths-and-folder-access)
- [Batches](#batches)
- [Recovery patterns](#recovery-patterns)

## Error codes

| `code` | Meaning | `details` | Recovery |
|---|---|---|---|
| `invalid_argument` | An argument is missing, of the wrong type, out of range, not one the tool takes (a misspelled or made-up name is refused, never ignored), an unknown key in a settings object, or contradicts another. | `field` names the offending argument, or the field in a settings object (`"brush.diameter"`, `"settings.hue"`); for an unknown argument the hint names the one meant ("Did you mean 'set_as_current'?") or lists the tool's own. | Fix that field. Check the tool's rows in the atlas for the argument names, types, ranges and allowed values. |
| `not_found` | The document, layer, file, effect or tool named doesn't exist. | `path` for files. | Re-read `get_document` or `list_files`. Relative paths resolve inside the Agent folder, not your working directory. |
| `ambiguous` | A layer or tab selector matched more than one. | `candidates`: `{id, path, kind}` for layers; `{index, tab_id, document_id, title}` for tabs. | Retry with an id from `candidates`. |
| `precondition_failed` | The document's state refuses the call. | `guard` names the check; see the tables below. | Fix the state the guard names, or ask the owner. |
| `busy` | Something else is running (an import, save, resize or render), 64 calls are already queued, or macOS is showing a permission prompt. | `code: "folder_access_pending"` for the prompt. | Wait a few seconds and retry once. Don't send calls in parallel. |
| `io_error` | A file already exists, can't be read or written, or macOS denied access. | `code`: `file_exists` or `folder_access_denied`; `path`; for other file-system failures `domain` and `error_code`. | See [Files, paths and folder access](#files-paths-and-folder-access). |
| `unsupported` | This build can't do it: a file format or PSD feature it doesn't read, a layer kind a tool can't handle (rendering an adjustment layer alone). | sometimes `format`. | Tell the user what isn't possible and offer the closest supported route. |
| `internal` | An unexpected failure inside Compositor. | | Report it with the call you made; don't retry blindly. |

## Guards: document and app state

| `guard` | Cause | Recovery |
|---|---|---|
| `document` | The tab has no document. | `new_document` or `open_document` first. |
| `can_edit_layers` | The app is in the middle of an edit (text typing, free transform, crop, gradient, moved pixels, a filter, Levels or Hue/Saturation dialog, an adjustment panel, a rename, a dialog or alert). The message says which. `save_document` and `save_document_as` refuse the same way while such an edit (or an opacity drag) is half-done, since the file would hold it half-done. With `code: "busy"` an import or long operation is running. | If you started it, `settle_pending_edits`; if the owner did, ask them to finish it; if busy, wait. |
| `can_start_project_operation` | A save, export, resize or render is already running on this document (usually `busy`). | Wait, then retry. |
| `can_switch` | The current tab can't be switched away from right now (usually `busy`). | Wait, or settle the current tab's pending edit. |
| `can_use_history` | Undo or redo while text is being typed or a layer renamed; `run_batch` then too, and whenever the app has any edit open or pending (a gradient, crop, moved pixels, a dialog, an adjustment panel). | Settle or wait; `get_document` shows the `blocking_reason`. |
| `history_busy` | Undo or redo while the app holds an edit open or pending (an adjustment panel, a slider drag, a gradient not yet committed, a crop frame, moved pixels, a filter or Hue/Saturation dialog), which they must not reach into; also stops a batch, without rolling it back, when the app edited the document while a step waited. | Settle the open edit with `settle_pending_edits` (or ask the owner, or wait), then retry; after a stopped batch, check `get_history` and run the remaining steps. |
| `max_tabs` | 32 documents are open. | Save and `close_document` one you opened. |
| `unsaved_changes` | `close_document` or `revert_document` on a document with unsaved changes. | Save it first, or pass `discard_changes: true` only when the user wants the changes gone. |
| `project_file` | `save_document` on a document with no file of its own (new, duplicated, or opened from a PSD or image), or `revert_document` on one that was never saved. | `save_document_as` with a new `.comp` or `.psd` path. The original PSD or image is never replaced by `save_document`; `save_document_as` onto it needs `overwrite: true`. |
| `lossy` | Saving as `.psd` would change what the file holds (an adjustment Photoshop lacks written as pixels, a clipping applied to pixels or left out, a curve resampled, a shape saved as pixels or a plain path, alpha channels or an adjustment's vector mask left out). `details.warnings` lists each `{layer, message, lossy}`; nothing was written. | Tell the user what would change. Retry with `allow_lossy: true` only if they accept it; otherwise save a `.comp`, or change the layers first. |
| `photoshop_limits` | The document is past what a PSD holds (30,000 px per side, 200 MP canvas, 32,767 layer records, 4 GB of layer data). | Save a `.comp`. |
| `pixel_budget` | A canvas, filled canvas or export would pass 30,000 px per side or 200 megapixels, or the document's layers its pixel budget (`get_app_info` `limits.document_pixel_budget`); also a file too large to open. | Use a smaller `scale`, `region` or size. |
| `max_layers` | The document already has (or would pass) 10,000 layers, folders included. | Delete, merge or flatten layers first. |
| `max_guides` | 1,000 guides already. | `remove_guide` or `clear_guides`. |
| `can_edit_guides` / `can_clear_guides` | Guides are locked in the app (View > Lock Guides), or another operation is running. | Ask the owner to unlock guides, or wait. |
| `can_select_tool` | `select_tool` while switching would commit or cancel something in progress. | Settle it first. |
| `can_edit_palette` | The palette can't change during a brush stroke. | Wait. |
| `document_changed` | The document changed while a long operation (a resize) ran. | Re-read the document and retry. |

## Guards: layers, locks and structure

| `guard` | Cause | Recovery |
|---|---|---|
| `active_layer` | `"@active"` with no active layer. | Name the layer, or `select_layers` first. |
| `layer_locked` | A lock on the layer, or on a folder it is in, blocks this edit. `details.layer_id` is the layer, `details.locked_by_id` the layer or folder holding the lock, `details.locks` its locks. A position lock blocks moving and transforming (and a smart-object replace that would move or resize the layer); a pixel lock blocks painting, filters, rasterizing, merging and `apply_layer_mask` (which rewrites the layer's pixels); Lock All blocks every change (effects and adjustment settings included) except showing, hiding, selecting and duplicating the layer. The other mask tools answer only to Lock All: under a pixel lock you can still add, paint, enable, link and delete a mask. | Decide whether the lock is meant to protect this layer (template locks usually are). If the task really needs it, `set_layer_locks` on the `locked_by_id` layer, make the edit, then restore the lock. |
| `locked_by_folder` | `set_layer_locks` on a layer inside a folder under Lock All. | Unlock the folder (`all: false`) first. |
| `placeholder` | The layer is a Photoshop placeholder (`kind: "placeholder"`), kept only to be written back; `details.placeholder` names its Photoshop type. | Leave it alone; it has no pixels or editable settings. |
| `has_pixels` | A pixel tool on a folder or adjustment layer. | Target a pixel, text or shape layer (rasterize text or shapes only when the task allows). |
| `not_smart_object` | Painting, a fill or gradient, clearing, inverting, a filter, Levels, Hue/Saturation, `set_layer_pixels` or `paste_image_into_layer` on a smart object's own pixels: it would drop the embedded file. Its mask can still be painted. | Change the picture with `export_smart_object_contents` and `replace_smart_object_contents`; `rasterize_layer` first only when the task wants plain pixels (the smart object is gone then). |
| `not_folder` / `is_folder` | The tool needs a layer that isn't a folder (fill opacity, a copied mask), or needs a folder (`ungroup_layer`). | Target the right kind. |
| `is_adjustment` | `set_adjustment` on a layer that isn't an adjustment layer. | `add_adjustment_layer` creates one. |
| `is_text` / `point_text` | A text tool on a layer that isn't live text; `fit_text` on paragraph text (it only fits point text). | Target the text layer (`kind: "text"`); for a paragraph, shorten it or lower `font_size`, or make it point text with `set_text_style` `box_size: null`. |
| `is_shape` | `set_shape_style` on a layer that isn't a live shape. | `add_shape` adds one; a rasterized shape is plain pixels now. |
| `is_smart_object` / `has_contents` | A smart-object tool on another kind of layer; or `export_smart_object_contents` on one whose contents the document doesn't hold (Photoshop linked them to a file, or left them out). | `place_smart_object` places a file as one; `replace_smart_object_contents` gives it contents the document keeps. |
| `can_clip` | Clipping needs a non-folder layer directly below, in the same folder. | Reorder, or leave out `clip_to_below`. |
| `can_group` / `can_place_layer` | The layers can't be grouped there, or a folder can't go inside itself. | Check the tree with `get_document`. |
| `can_merge_layers` | Nothing to merge: Merge Down needs a pixel layer directly below; a folder needs pixel layers inside. | Pick layers that can merge, or `rasterize_layer` first. |
| `can_transform` | Nothing that can flip: only shown layers with pixels flip. | Show the layers, or target others. |
| `hidden_layers` | `flatten_image` with `discard_hidden: false` and hidden layers present; `details.hidden_layer_ids`. | Show or delete them, or pass `discard_hidden: true`. |

## Guards: pixels, selections and masks

| `guard` | Cause | Recovery |
|---|---|---|
| `selection` | The tool needs a selection (`clear_selection`, `content_aware_fill`, `invert_selection`, `render_region` with `"selection"`, masks from a selection, aligning to the selection). | Make one (`select_rect`, `select_subject`, `load_layer_selection`…). |
| `can_edit_selection` | A selection is being drawn or moved in the app. | Wait, or ask the owner to finish. |
| `can_select_subject` | Select Subject isn't available right now. | Check that visible pixels exist; retry after pending edits settle. |
| `can_paint` | The layer is hidden (or in a hidden folder), its mask is disabled, or the app can't edit it right now. | `set_layer_visibility` or `set_mask_enabled` first, or settle. |
| `brush_error` | The app refused the paint operation; the message says why. | Fix what the message names. |
| `can_copy_pixels` | Nothing under the selection to copy. | Select where the layer has pixels, or clear the selection. |
| `can_adjust_colors` / `can_invert` / `can_content_aware_fill` | The pixel adjustment can't run on this layer now (no pixels, a panel open, no selection for Content-Aware Fill). | Read the message; target a pixel layer, make a selection, or settle. |
| `filter_failed` | The filter couldn't be applied to this layer. | Try other settings or another layer; report it. |
| `has_mask` | The layer has no mask to target, apply, delete or copy. | `add_layer_mask` first. |
| `no_mask` | `add_layer_mask` on a layer that already has one. | Paint the existing mask with `target: "mask"`, or `delete_layer_mask` first. |
| `mask_enabled` | `apply_layer_mask` on a disabled mask. | `set_mask_enabled` first. |
| `mask_white_areas` | `load_layer_selection` with `source: "mask"` from a mask with no white (revealed) areas: it hides the whole layer, so there is nothing to select. | Paint some of the mask white first, or load `source: "pixels"`; check the mask with `render_layer` or `get_layer_pixels` (`target: "mask"`). |
| `clipboard` | `paste_pixels` with no image on the clipboard. | `copy_pixels` first. |

## Files, paths and folder access

- **`io_error` with `details.code: "file_exists"`**: a writing tool (`export_image`,
  `save_document_as`, `get_layer_pixels` with `save_to`) found a file at the path. Pick a
  new name (add a suffix or a version), or pass `overwrite: true` only when the user asked
  to replace that file. Saving a document over its own `.comp` or `.psd` is an ordinary
  save; the PSD a document was opened from is not its own file.
- **`not_found` for a relative path**: relative paths resolve in the Agent folder
  (`get_app_info.agent_folder`), not the directory your shell is in. Pass an absolute or
  `~/` path for files elsewhere. `list_files` lists one folder level unless you pass
  `recursive: true`, so a file in a subfolder won't show in a plain listing.
- **`busy` with `details.code: "folder_access_pending"`**: the path is in Documents,
  Desktop, Downloads, iCloud Drive, a cloud storage provider or another volume, and macOS
  is waiting for the owner to answer its permission prompt. Tell the owner to answer it on
  the Mac (or grant access in Compositor > Settings… > Folder access), then retry once.
- **`io_error` with `details.code: "folder_access_denied"`**: macOS refused access there.
  The owner can allow it in System Settings > Privacy & Security > Files and Folders (or
  Full Disk Access); meanwhile, copy the file into the Agent folder yourself if your own
  shell can read it, and work from the copy.
- `get_app_info` reports `folder_access` per location (`granted`, `denied`,
  `not_determined`, `absent`); check it before a job that reads from those places.
- `list_files` never fails on a folder it can't enter: it lists it and names it under
  `skipped` with `folder_access_denied`, `folder_access_pending` or
  `folder_access_unchecked`.
- **`unsupported` opening a file**: Compositor opens `.comp`, 8-bit RGB `.psd`, PNG, JPEG,
  HEIC, TIFF, SVG (as pixels) and camera raw, and 8-bit RGB `.psb` Large Documents (saved
  back as `.psd`). A 16-bit or CMYK PSD or a PDF won't open; say so.
- Cloud files that are online-only placeholders can fail or stall to read; ask for them to
  be downloaded first.

## Batches

A failing `run_batch` step returns the step's own error with `details.step` (its index)
and `details.tool` added, plus `completed`, `results` and `rolled_back`. A step refused
before anything ran (unknown tool, a tool not allowed in a batch, an argument the step's
tool doesn't take, a step with its own `document`) fails as `invalid_argument` or
`not_found` with `details.step`. Fix that step and rerun the batch; with
`rollback_on_error: true` nothing from the failed run remains, without it the completed
steps stayed applied as one undo step (undo it before rerunning the whole batch, or run
only the remaining steps).

## Recovery patterns

- **Wrong layer changed**: `undo` (check `get_history` first so you undo only your own
  steps), then address the layer by id.
- **Out-of-range value**: the message states the range; clamp it yourself and say so if
  the user asked for something impossible.
- **Something blocks every edit**: `get_document` → `capabilities.blocking_reason` tells
  you what; see [Pending edits](history-and-batches.md#pending-edits-in-the-app).
- **A tool you expected doesn't exist**: tools are renamed as the app evolves (for example
  `delete_layers`, `reveal_in_finder`). Check the atlas or `tools/list` rather than
  guessing names; `not_found` for a tool name means exactly that.
- **Repeated `busy`**: one retry after a pause is reasonable; after that, tell the user
  Compositor is occupied (a long export, a prompt on screen) instead of hammering it.
