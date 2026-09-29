---
name: compositor-psd-templates
description: Use this skill when an existing layered Photoshop file (.psd) or design template needs its slots filled or changed with Compositor — swap a photo into a smart-object frame, replace a name, headline, date, price or logo, localize the text, or produce one version per person or row of a list. It covers the whole job in Compositor — inspect the layers, fonts and locks, fit the photo and text, preview, export PNG/JPEG, save a new PSD or .comp without overwriting the template, and verify the result. Also use it when someone wants to replace a Photoshop script or action that fills templates, or asks what survives a PSD round trip through Compositor. It applies even to short requests like "do the usual template". Don't use it for installing or configuring Compositor or its MCP server, for designing from a blank canvas, for driving Photoshop itself, or for Canva or general Photoshop questions.
---

# Compositor PSD templates

A template is someone's finished design with slots: a photo frame, a name, a headline, a
date. The job is to change exactly those slots and nothing else, and to prove it. Treat
the source file as read-only: it is often the only copy of a client's design, and a
template that has been overwritten with one person's details is broken for the next.

Read the **compositor** skill first for selectors, coordinates, undo and error handling.

## The workflow

### 1. Protect the source, then open it

- Note the source's path and fingerprint before touching anything (`shasum -a 256
  template.psd`, or `get_file_info` for its size) so you can show it is unchanged at the
  end.
  Run shell checks (`shasum`, `sips`, the verification scripts) one command per call,
  with the file's literal quoted absolute path: no shell variables, `cd … &&` chains or
  `$(…)`. Agent setups often allow commands by their exact text, and a composite command
  stops for approval, or is refused when no one is there to approve it.
- Choose output paths now, **beside the source or in an output folder, never the source
  path**: `Card - Endorser Name.psd`, `out/card-endorser-name.png`.
- `open_document` with the `.psd` path. Read `conversions` in the result: each entry names
  a layer and what Compositor did with a Photoshop feature it converts or keeps only for
  writing back (a missing font, justified text, an effect it can't draw). Tell the user
  about any that touch a slot you are filling. `already_open: true` means a tab already
  shows it: use that tab, and check `is_modified` before assuming it is pristine.

### 2. Inspect before you edit

- `get_document` with `detail: "full"`. For each layer note `id`, `path`, `kind`,
  `visible`, `effective_locks`, and for text layers `text` (content and style), for smart
  objects `smart_object` (`file_name`, `natural_size`, `quad`), for masks and clipping
  what they hide. `kind: "placeholder"` layers are Photoshop features Compositor keeps
  hidden only to write back: never edit, delete or reorder them.
- Fonts: `check_fonts` with the text layers' `font_name`s. A missing font draws the
  imported pixels until the text is edited; editing it substitutes another face. If a
  slot you must change uses a missing font, stop and tell the user (install it, or accept
  the named substitute) rather than shipping the wrong typeface.
- `render_document` once as the baseline you will compare against.
- Write down a slot map before editing:

  | Slot | Layer (id, path) | Kind | Change | Constraint |
  |---|---|---|---|---|
  | Photo | `…`, `Photo/Portrait` | smart_object | replace with `portrait.jpg`, fill | frame 820 × 820 |
  | Name | `…`, `Name` | text | "Endorser Name" | one line, text ≤ 760 px wide |

  Match the user's fields to layers by name and by current content; when two layers could
  be the slot (a visible "Headline" and a hidden "Headline copy"), pick the visible one
  and say so, or ask. The ids hold only until the PSD is read again: reverting or
  reopening it gives every layer a new id, so rebuild the map then (see
  [Many people, one template](#many-people-one-template)).

### 3. Replace the photo

When the frame is a smart object, `replace_smart_object_contents` with `layer`, `path`
and `fit` swaps what is inside, keeping the frame's name, mask, effects, clipping and
locks. The layer's placement follows the new image's proportions: an image shaped like
the frame lands exactly on it, while any other image resizes the layer. With
`fit: "fill"` it grows past two sides of the frame and **is drawn there**, over the name
or the accent bar next to it; with `"fit"` (the default) it shrinks and leaves two sides
of the frame bare. A position lock refuses either (`layer_locked`).

So crop the photo to the frame's proportions first, then replace with `fit: "fill"`:

1. `get_smart_object_info` on the frame: the `quad` gives the frame's width `W` and
   height `H`.
2. If the photo's `w / h` differs from `W / H`, crop it into a new file: centered with
   `sips --cropToHeightWidth <h'> <w'> photo.png --out photo-cropped.png`, where
   `w' = min(w, round(h × W / H))` and `h' = min(h, round(w × H / W))`; or, to keep an
   off-center face in frame, in a scratch document (`open_document`, `crop` a `W:H`
   rectangle around the face, `export_image`, `close_document` with `discard_changes`).
3. `replace_smart_object_contents` with the cropped file and `fit: "fill"`. The result's
   `transform` equals the frame's; `render_region` over the frame shows the face.

Use `"fit"` for logos and artwork that must not be cropped (on a frame of their own
proportions it is the same as `"fill"`). Never leave a photo spilling out of its frame.

Frames that are not smart objects, and how to fill each, are in
[Smart objects and photo frames](references/smart-objects-and-frames.md): a pixel frame
with a clipped photo layer above it, a folder with a mask, or a plain rectangle.

### 4. Replace the text

- `set_text` changes the words and keeps the layer's style and name. **Point text keeps
  its alignment anchor**: a centered name stays centered on the same x, right-aligned
  text keeps its right end, and imported Photoshop text stays anchored where Photoshop
  anchored it. There is nothing to re-center afterwards.
- A slot that must stay on one line and inside a width: `fit_text` with `max_width`
  shrinks the type (never grows it) until it fits, keeping the same anchor. It works on
  point text only, and `max_width` limits the text itself, not the layer's box with its
  12 px of padding. It returns `previous_font_size` and `font_size`: tell the user.
- A paragraph (text with a `box_size`) keeps its box and wraps inside it;
  `get_text_metrics` reports `overflows: true` when words fall off the bottom. Shorten,
  reduce `font_size` with `set_text_style`, or ask; never leave overflowing text.
- Keep the template's style unless asked: Compositor gives a text layer one style, so
  editing text that mixed styles (a bold first word, two colors) collapses it to one.
  Warn before editing such a layer, or rebuild the emphasis as a second text layer.

Details, including font substitution and how to measure, are in
[Text in templates](references/text-in-templates.md).

### 5. Respect locks

`effective_locks` shows what protects each layer, including locks inherited from its
folders. Designers lock what must not move, so a lock on a slot you were asked to change
is a question, not an obstacle. Most locks don't stand in the way of a fill: text changes
under any lock but Lock All, and a position-locked photo frame takes a photo cropped to
its proportions (step 3), which doesn't move it. When a call is refused
with guard `layer_locked` and the change is clearly the one asked for, unlock only the
lock named in `details`, on the layer `details.locked_by_id` names, make the change and
restore the lock in one `run_batch`, and report it. Never unlock a whole folder under Lock All to change one
thing inside it without saying so.

### 6. Preview and compare

`render_document` after the fills, `render_region` on each slot at full detail (text
edges, the face in the photo), and compare with the baseline: nothing outside the slots
should have moved. `content_bounds` from `get_layer_bounds` confirms a text layer's
letters stay inside its safe area (its `bounds` add 12 px of padding on each side).

### 7. Export and save a new file

- Flat deliverables: `export_image` to a new path (PNG for graphics with transparency or
  sharp text, JPEG with `quality` 0.85–0.92 for photos on social platforms).
- Layered deliverable: `save_document_as` to a **new** `.psd` path (the format follows the
  extension, or `format: "psd"`; `get_app_info.features.save` lists `psd` when this build
  writes Photoshop files, otherwise save a `.comp`). Read the result's `warnings` and pass
  them on. A save that would change what the file holds (an adjustment Photoshop lacks, a
  clipping applied to pixels or left out, a shape saved as pixels or a plain path, the
  file's alpha channels or an adjustment's vector mask left out) is refused with guard
  `lossy` and nothing written; `allow_lossy: true` writes the approximation, but only
  when the user accepts what `details.warnings` lists. Saving onto an existing `.psd`, the
  template included, needs `overwrite: true`: don't.
- `save_document_as` makes the new file the document's own (`set_as_current: true` by
  default), so a later `save_document` writes there, never back to the template.
- The PSD round trip keeps untouched layers byte for byte and regenerates what you edited;
  the full list of what survives, what is rewritten and what is flagged is in
  [PSD round trip](references/round-trip.md).

### 8. Verify, then report

Run the checks in [Verification](references/verification.md): the source's sha256 is
unchanged, the output opens in psd-tools without warnings (`psd-verify.py`), its layer
names and kinds match the source except where you meant to change them, text layers are
still text, and the flat export has the expected pixel size. Report the files written
(each by the absolute `path` the tool returned), each slot's new value, any conversion or
save warnings, and anything you couldn't do.

## Many people, one template

For a list of fills (one card per person), fill and export one, verify it with the user,
then repeat per row from the pristine template. Save each row's layered file with
`save_document_as` and `set_as_current: false`, which writes a copy and leaves the
document tied to the template; then `revert_document` with `discard_changes: true` (you
have just saved and exported that row) reloads the template for the next one. With
`set_as_current: true` a revert would reload the row you just saved instead.

A revert reads the PSD again, and a Photoshop file (or image) read again gets a new
`document_id` and a new id for every layer. The slot map's ids from the first row fail as
`not_found` from the second row on. After each revert:

1. Address the document by its `tab_id`, which a revert keeps, or by the `document_id` the
   revert returns; never by the old `document_id`.
2. Read the revert's `conversions`; they should match the first open's.
3. Run `get_document` again and rebuild the slot map: find each slot by its `path` and
   `kind` and take its new `id`. Or address slots by `path` from the start, when every
   slot's path is unique in the template.

Name outputs from the row (`card-<slug>.png`), never reuse a name, and stop at the first
failure instead of skipping rows silently. The **compositor-variants-and-delivery**
skill covers naming, sizes and contact sheets for the set.

## References

- [Smart objects and photo frames](references/smart-objects-and-frames.md): every kind of
  photo slot and how to fill it, fit math, what replacing keeps, limits.
- [Text in templates](references/text-in-templates.md): point and paragraph text, fitting
  strategies, imported text, fonts and substitutes, style runs.
- [PSD round trip](references/round-trip.md): what survives untouched, what is regenerated
  on edit, what is flagged on open and on save.
- [Verification](references/verification.md): source fingerprint, psd-verify and
  photoshop-verify, comparing source and output, pixel checks.
