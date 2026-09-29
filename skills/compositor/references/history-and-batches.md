# Undo, batches and pending edits

Compositor records agent edits in the same per-document undo history as the owner's own,
so ⌘Z in the app undoes your work too. Use that: a clean history of well-named steps is
how the owner reviews, keeps or rolls back what you did.

## Contents

- [One call, one step](#one-call-one-step)
- [Undo and redo](#undo-and-redo)
- [run_batch](#run_batch)
- [Pending edits in the app](#pending-edits-in-the-app)
- [Saved state](#saved-state)
- [History limits](#history-limits)

## One call, one step

Every tool that changes a document records at most one undo entry, named like the app's
menu item ("Move Layer", "Add Layer Mask", "Levels"), and reports it:

```json
"undo": {"name": "Move Layer", "count": 14, "recorded": true}
```

`recorded: false` means this call added no undo entry, usually because it changed
nothing: the value was already set, the canvas already had that size, a filter at its
defaults. It is not an error, but read it: an
unexpected `false` often means you addressed the wrong layer. Reads (`get_*`, `list_*`,
`render_*`, `sample_colors`) never record anything, and neither do `set_palette_colors`
or the view tools (`set_zoom`, `zoom_to_fit`, `select_tool`).

A few tools record several entries or none by design: `settle_pending_edits` commits each
pending edit as its own step; `duplicate_document` starts the copy with an empty history;
`open_document` and `revert_document` start fresh histories.

## Undo and redo

`undo` and `redo` take `steps` (default 1) and stop early when nothing is left; the
result says how many entries moved (`undone` / `redone`) and the new state. `get_history`
lists `undo_names` and `redo_names` (each starting with the next one), so check what you
are about to undo before you undo more than one step: the owner's steps sit in the same
list as yours.

Undo is refused while something in the app holds the history: text being typed, a layer
being renamed (guard `can_use_history`), or an edit open or pending, such as an
adjustment layer's settings panel, a slider drag, a gradient not yet committed, a crop
frame, moved pixels or a filter or Hue/Saturation dialog (guard `history_busy`). Undoing
then would throw the owner's pending work away. Settle or wait, then retry.

## run_batch

`run_batch` runs 1–200 calls in order as **one** undo step:

```json
{"name": "Headline band", "rollback_on_error": true, "steps": [
  {"tool": "add_group", "arguments": {"name": "Headline block"}},
  {"tool": "add_blank_layer", "arguments": {"name": "Band"}},
  {"tool": "select_rect", "arguments": {"rect": {"x": 0, "y": 980, "width": 1080, "height": 220}}},
  {"tool": "fill_selection", "arguments": {"layer": "Band", "with": "color", "color": "#1a73e8"}},
  {"tool": "select_none", "arguments": {}},
  {"tool": "set_layer_opacity", "arguments": {"layer": "Band", "opacity": 0.9}}
]}
```

The Band layer this makes is canvas-sized (`add_blank_layer`); only its pixels are a band.
Check it with `get_layer_bounds`: on a 1080 × 1350 canvas `content_bounds` is `{x: 0,
y: 980, width: 1080, height: 220}`, while its `transform` still covers the whole canvas.

- Each step is `{tool, arguments}`, exactly the call you would make on its own, minus
  `document`: every step acts on the batch's document (pass `document` to `run_batch`
  itself; a step that names its own is refused before anything runs).
- Every step is checked up front: an unknown tool, a disallowed tool, an argument the
  step's tool doesn't take or a malformed step fails the whole batch with nothing
  applied, `details.step` naming it.
- Steps run in order. The first failing step stops the batch: the result is an error
  whose `details.step` and `details.tool` name it, with `completed` (how many succeeded)
  and their `results`. Without `rollback_on_error` the completed steps stay applied, still
  as one undo step; with it, the document, the active layer and the layer selection go back
  to how they were.
- Files a step wrote (a save or an export) stay written even after a rollback. Put exports
  after the batch, once its result is ok.
- Not allowed inside a batch: `undo`, `redo`, `run_batch`, `new_document`,
  `open_document`, `close_document`, `select_document`, `duplicate_document`,
  `revert_document` and `settle_pending_edits`. They open, close or switch documents or
  move through the history the batch is recording into.
- A batch refuses to start while the app holds the history or has any edit open or
  pending (a gradient, crop, moved pixels, a dialog, an adjustment panel; guard
  `can_use_history`). While it runs, the owner's edits, undo, saves and opens wait. If
  the app still edits the document while a step waits (a save, an export, reading a
  file), the batch stops after that step (guard `history_busy`) and is not rolled back,
  since that would undo the owner's edit too: check `get_history`, then run the remaining
  steps.
- Later steps see earlier steps' effects, but you can't feed a step's result (a new
  layer's id) into a later step's arguments. Give new layers unique names and address them
  by name inside the batch, or split the work: one call to create, then a batch using the
  returned ids.

Use a batch when steps belong together for the owner (one "Headline block" to undo) or
when a half-done sequence would leave the document broken (rollback). Don't batch
exploratory work you still need to look at between steps: render in between instead.

## Pending edits in the app

Compositor refuses layer edits while the app is in the middle of something: text being
typed, a free transform or crop in progress, a gradient being dragged, pixels being moved,
a filter, Levels or Hue/Saturation dialog, an adjustment layer's settings panel, a layer
being renamed, a dialog or an error alert. Such calls fail with guard `can_edit_layers`
(or `busy` while an import or save is running), and `get_document` reports it as
`capabilities.can_edit_layers: false` with a `blocking_reason`. Whole-document tools
(`resize_image`, `resize_canvas`, `crop`, `trim_canvas`, `flip_canvas`, `flatten_image`)
refuse the same way rather than cancelling anything, and so do `save_document` and
`save_document_as` while any of these (or an opacity drag) is half-done: the file would
hold it half-done while the document read as saved.

`settle_pending_edits` with `mode: "commit"` keeps those edits (each as its own undo step)
and `"cancel"` throws them away; it also dismisses the app's dialogs and alerts. It
returns `settled`, `failed` (a list of `{edit, message}` for edits that couldn't commit:
text or a crop that fails stays in progress, a failed gradient or pixel move is
discarded), `can_edit_layers` and any `blocking_reason` left. Imports and long
operations are left alone; wait for those.

Settling touches the owner's work. Commit or cancel on your own only what you started (a
crop begun by `select_tool` with `tool: "crop"`, which holds other edits until another
tool is selected). When the owner is typing or has a dialog open, tell them what is
blocking and ask, or wait.

## Saved state

`is_modified` (in `list_documents`, `get_document`, `get_history`) says whether the
document differs from its file. Saves mark it saved: `save_document`, and
`save_document_as` with `set_as_current: true` (the default), which also makes the new
path the document's file. `save_document_as` with `set_as_current: false` writes a copy and
leaves the document as it was. `export_image` never marks anything saved. Inside a batch a
save marks the state it wrote; if later steps change the document, it reads as modified
again once the batch ends.

## History limits

A document keeps at most 100 undo entries and about 256 MB of retained pixels; older
entries drop off first, and replacing very large smart-object contents can drop that step's
undo at once. Save a checkpoint (`save_document_as` to a new `.comp`, `set_as_current:
false`) before long destructive work rather than counting on undo to get back.
