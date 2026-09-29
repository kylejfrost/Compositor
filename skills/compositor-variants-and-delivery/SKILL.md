---
name: compositor-variants-and-delivery
description: Produce and deliver sets of images from one Compositor design. Plan the variants (sizes and aspect ratios, copy or language versions, one per person or product), make each from the approved master with duplicate_document, canvas resize or crop and re-layout inside each format's safe zones, batch edits with run_batch, export PNG or JPEG with the right quality, background, scale and pixel size, save layered PSD or .comp files for designers, name and organize the files, verify every output (pixel sizes, sources untouched, psd-verify, psd-diff, Photoshop checks), and show the set on a contact sheet. Use whenever the user asks Compositor for multiple sizes, formats or versions of a graphic, a social media kit, resized or localized versions, a batch of personalized cards, export settings, file naming or packaging a delivery, even if they only say "make the other sizes" or "send me the files".
---

# Compositor variants and delivery

A set is only as good as its worst file: one stretched logo, one headline under the
story's reply bar, or one overwritten master spoils the delivery. Work from an approved
master, derive every variant the same way, and check every file before handing the set
over. Read the **compositor** skill first; build the master with
**compositor-layout-and-type** or **compositor-psd-templates**.

## 1. Plan the set

Write the plan down (and show it when the set is large) before making anything:

| Variant | Size | From the master by | Format | Path |
|---|---|---|---|---|
| feed | 1080 × 1350 | extend the canvas, re-place headline and CTA | JPEG 0.9 | `out/spring-sale/spring-sale-feed-1080x1350.jpg` |
| story | 1080 × 1920 | extend, move text into the story safe zone | JPEG 0.9 | `out/spring-sale/spring-sale-story-1080x1920.jpg` |
| link | 1200 × 628 | re-layout side by side | JPEG 0.9 | `out/spring-sale/spring-sale-link-1200x628.jpg` |
| square @2x | 2160 × 2160 | export only, `scale: 2` | PNG | `out/spring-sale/spring-sale-square-2160x2160.png` |

Sizes and safe zones per platform are in the **compositor-layout-and-type** skill (its
canvas and grids reference); naming and folders in
[Export and naming](references/export-and-naming.md).

## 2. Protect the master

- Save the approved master as a `.comp` (and note its path and `shasum -a 256`) before
  deriving anything. Never resize, crop or re-lay out the master itself.
- Every variant is its own document: `duplicate_document` copies the canvas, layers,
  guides and selection into a new tab with new ids, no file and no undo history. Give it a
  `name` like the variant ("spring-sale story").
- Re-read the copy's layer ids with `get_document`: they differ from the master's.

## 3. Make each variant

Pick the cheapest route that gives a correct result:

| Variant differs by | Route |
|---|---|
| only pixel size, same aspect ratio | no new document: `export_image` with `scale` (0.05–4) or `max_size` |
| aspect ratio | `duplicate_document`, `resize_canvas` (anchor where the content should stay) or `crop`, then move text, logo and CTA into the new safe area |
| overall size including the canvas | `duplicate_document`, `resize_image`, then fix anything that must stay a fixed pixel size (logos, small text) |
| copy (language, price, name) | `duplicate_document` (or the template flow), `set_text`, then `fit_text` where it must stay on one line (point text keeps its anchor, so centered copy stays centered) |
| one per row of data | one fill per row from the pristine master, as in the psd-templates skill |

Re-layout means re-placing elements, not stretching them: extend backgrounds with
`resize_canvas` and `fill`, re-cover photos with `scale_layer_to_fit` (`mode: "cover"`),
and move text blocks with `set_layer_transform` (`anchor`) or `align_layers` against a
selection of the new safe area. Recipes, including proportional repositioning math, are in
[Sizes and re-layout](references/sizes-and-reflow.md).

Batch each variant's layout moves in one `run_batch` (`rollback_on_error: true`), so a
variant is one undo step and a failed step leaves no half-moved layout.

Check each variant **after its last change and right before its export**, in this order;
a check made before a later nudge proves nothing about the file:

1. `get_layer_bounds` on every text block, logo and CTA: its `content_bounds` (the
   pixels that show, not `bounds` or the transform, which add a text box's 12 px padding
   or a folder's canvas-sized box) lies inside the format's safe zone.
2. `render_document` of that final state, and look at it.
3. `export_image`, then confirm the file's pixel size (`sips -g pixelWidth -g
   pixelHeight`). Any change after step 1 means starting again at step 1.

## 4. Export and save

- `export_image` with an explicit `path` per variant, `format` (or the extension),
  `quality` for JPEG, `background` when transparency must become a color, `scale` or
  `max_size`, and `region` for a crop of the canvas. It never overwrites unless you pass
  `overwrite: true`; don't, except to replace a file the user asked you to replace.
- PNG for graphics with text, flat color or transparency; JPEG (0.85–0.92) for photos
  where file size matters. JPEG has no transparency: it gets a white background unless
  `background` says otherwise.
- Layered deliverables: `save_document_as` each variant to a new `.comp`, or to `.psd`
  when this build saves Photoshop files, and pass on the save's `warnings`. Use
  `set_as_current: false` to write a copy without re-pointing the document.
- Close the variant tabs you opened when done (`close_document`; unsaved variants need
  `discard_changes: true`, which is fine once they are exported and saved as asked).

## 5. Verify every file

For each output: it exists, its pixel size matches the plan (`export_image` reports it;
confirm with `sips -g pixelWidth -g pixelHeight`), it looks right (a small render or
the contact sheet), and PSDs pass `psd-verify.py`. The master and any source files still
have their original sha256. Details, the PSD pass rules and a contact-sheet recipe are in
[Verification and contact sheets](references/verification-and-contact-sheets.md).
Run shell checks (`shasum`, `sips`, the verification scripts) one command per call,
with the file's literal quoted absolute path: no shell variables, `cd … &&` chains or
`$(…)`. Agent setups often allow commands by their exact text, and a composite command
stops for approval, or is refused when no one is there to approve it.

## 6. Hand over

Report a table of every file: its absolute path (as the tool returned it), pixel size,
format, and anything approximated
(a font substitute, a PSD warning, an upscaled image). Offer the contact sheet, and
`reveal_in_finder` on the output folder when the user is at the Mac.

## References

- [Sizes and re-layout](references/sizes-and-reflow.md): deriving each size from the
  master, anchors, safe zones, proportional repositioning, batching.
- [Export and naming](references/export-and-naming.md): export options and when to use
  each, JPEG quality and file size, transparency, pixel density, naming and folders, PSD
  and `.comp` delivery.
- [Verification and contact sheets](references/verification-and-contact-sheets.md):
  scripted checks for sets, PSD verification and Photoshop pass rules, contact sheets.
