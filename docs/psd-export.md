# PSD export

Compositor writes a document back to Photoshop as a layered PSD (version 1, 8-bit RGB). It reads Large Document (PSB, version 2) files too, and writes those documents as a `.psd` as well: Compositor opens at most 30,000 pixels a side, which a `.psd` holds, and `save_document_as` refuses a `.psb` path rather than give it version-1 bytes. A PSB's `8B64` blocks are written as `8BIM` blocks with 4-byte lengths, since readers take an `8B64` block's length as eight bytes. This document describes the file it writes and how that file is checked against psd-tools and Photoshop itself.

## Byte layout

`PSDWriter` writes the sections of Adobe's *Photoshop File Formats Specification* in order, big-endian, streamed into a temporary file that replaces the destination only once it is complete.

- **Header** (26 bytes): `8BPS`, version 1, six zero bytes, the channel count (3, or 4 when the merged image carries transparency), height, width, depth 8 and color mode 3 (RGB). Canvases are limited to 30,000 pixels per side (the most a `.psd` holds) and to Compositor's 200-megapixel surface limit (`DocumentLimits.maxSurfacePixels`).
- **Color mode data:** empty (length 0), as for every RGB file.
- **Image resources** (`PSDImageResourcesWriter`): the resources the file was opened with, in their order, with the ones Compositor derives from the document regenerated: resolution (1005), target layer (1024), layer group info (1026), grid and guides (1032), version info (1057, naming Compositor), layer selection IDs (1069) and layer groups enabled (1072). The thumbnails (1036, and Photoshop 4's 1033) are left out, since they would show the document as the file had it, and so are the resources describing alpha and spot channels, which the file written doesn't have: their names (1006, 1045), identifiers (1053), display information (1007, 1077), alternate spot colors (1067) and the Quick Mask channel (1022). The XMP packet (1060) loses Photoshop's `photoshop:TextLayers` once a type layer isn't written as the file had it. After Crop, Canvas Size, Image Size or Flip Canvas, the file's saved paths are placed where the canvas went and its slices (1050) are left out. A derived resource the file lacked goes where Photoshop 2026 writes it.
- **Layer and mask information:**
  - the layer count, stored negative when the merged image's first alpha channel is its transparency;
  - the layer records, bottom to top, a folder written as its section divider (`</Layer group>`), its contents, then the folder's own record;
  - each record's channel data in record order: transparency (−1), red, green and blue, then the layer mask (−2), each compressed with PackBits (compression 1, a `u16` byte count per row first). Color is straight (not premultiplied) sRGB, and fully transparent pixels are black;
  - padding to 4 bytes, the global layer mask info as the file had it (empty for a new document), then the document's tagged blocks: the file's own in their order, 4-byte aligned, and one `lnk2` block with the smart objects' contents where the file had its linked-layer blocks (first when it had none).
- **Layer records** (`PSDLayerRecordWriter`, `PSDLayerBaker`): a layer's pixels sit in an axis-aligned rectangle of whole document pixels. A layer drawn upright at its own size is written as its own image, losslessly; any other transform is drawn exactly as `ImageExporter` draws it into the box around its corners, then trimmed to the pixels that are there. Every record has blending ranges covering 0…255 unless the file stored its own, and its tagged blocks follow one another with no padding added between them (a block Compositor generates pads its own payload, as the adjustment blocks do to 4 bytes).
- **Merged image** (`PSDCompositeWriter`): the document as `ImageExporter` renders it, layer effects included, in red, green and blue, plus alpha only where some pixel isn't opaque (or the file's layer count was negative). Color is stored over white where the image is transparent, as Photoshop stores it, and every channel's row byte counts come before the rows.

## Policies

Every layer follows two rules; the sections below give the details for each kind.

- **What the document was opened with goes back as Photoshop stored it** (`preserveExtras`): a layer's tagged blocks in their order, the bytes after them, its blending ranges and flags, and its blend key, clipping and filler bytes while the layer still matches them. Only the blocks Compositor models are rewritten, and only where the layer no longer matches them (`luni` after a rename, `lspf` for locks, `iOpa` for Fill, `lclr` for the color label, and the text, smart object, effects, vector and adjustment blocks described below). A layer that is no longer a folder loses its section blocks. A layer Photoshop never saw gets the blocks Photoshop writes.
- **What Compositor can't represent is kept or approximated, never dropped silently.** Layers Compositor keeps only as placeholders (fill and adjustment kinds it can't draw, and their data) are written back as they were read. What the file must hold differently from the document is reported as a warning. A lossy one (an adjustment Photoshop lacks written as pixels, a clipping applied to pixels or left out, a curve resampled, a shape saved as pixels or as a plain path, the file's alpha channels or an adjustment's vector mask left out) is written only when the save allows it (`allowLossy`); the rest are notes.

### Text layers

A live text layer is written as a Photoshop type layer: its rendered pixels in the channels, so the file shows the text wherever it opens, plus a `TySh` block that Photoshop can lay out again.

- **New or edited text** gets a `TySh` generated from its style (`PSDTextWriter`): one style run per stretch of one color and font face (`colorRuns` and `fontRuns`), and one paragraph run per paragraph, with `Editor.Text` ending every paragraph in `\r`. The font set names each face those runs use. The transform maps text space to the document through the layer's placement. Its origin is the first baseline at the alignment point for point text, or the box's top-left for paragraph text (`BoxBounds` is the box less its 12 px padding). `FontSize` is the style's size, and the horizontal scale is carried in the transform. EngineData uses the layout psd-tools 1.19 writes.
- **Imported text that is still what import made of it** keeps Photoshop's `TySh`, every style run included, as long as its pixels are still Photoshop's (`importedTextAnchor` is set; the first redraw removes it). It is written byte for byte while the layer stays where it was. When the layer was moved, scaled or turned, only the transform is rewritten. Text edited and then edited back to its imported style (a recolor and back) counts as edited: its pixels are Compositor's single-style render, so its `TySh` is generated from the style.
- **Text rasterized since import** (Rasterize Layer, a paint stroke) is written as a pixel layer without `TySh`. Type Compositor couldn't make editable (vertical, warped, rotated…) keeps its `TySh` as read.
- **`TextIndex`**: each type layer keeps its own. A duplicate, or a layer whose index another layer already has, gets the next free index, as does new text.
- **`Txt2`**, Photoshop's document-wide text engine data, is written back only while every type layer's `TySh` is written as it was read. Otherwise it is left out, and Photoshop rebuilds it from the layers.
- `PSDWriteOptions.textAsPixels` writes every text layer as pixels only.

Compositor and Photoshop lay text out differently. After Photoshop re-typesets a layer, lines can break in other places, and the first line of paragraph text can sit a few pixels higher than Compositor draws it. See "Measured caveat" below.

### Smart objects

A smart object is written as Photoshop writes one: its pixels in the channels, a `PlLd` and a `SoLd` block (`SoLE` for a linked file) on the layer, and its contents in the document's linked-layer entries (`PSDSmartObjectWriter`).

- **Contents still as imported** (the same `uniqueID` and `contentsRevision` as `importedSmartObject`) keep Photoshop's blocks and entry byte for byte. Only the placement follows the layer: when the corners derived from the layer's quad are more than 0.01 px from the file's `Trnf` (after a move, scale, turn, Canvas Size, Crop or Image Size), `Trnf`, `nonAffineTransform` and `PlLd`'s corners are rewritten and every other byte stays.
- **Contents placed or replaced in Compositor** get generated blocks: `SoLd` is `"soLD"`, version 4, then the descriptor `Idnt placed PgNm totalPages Crop frameStep duration frameCount Annt Type Trnf nonAffineTransform warp Sz Rslt`, with the corners in document pixels (top-left, top-right, bottom-right, bottom-left) and no warp (`warpNone` over the contents' bounds, 4 × 4). `PlLd` is `"plcL"`, version 3, the contents' uuid, page, page count, anti-aliasing, type, the corners and the warp. Both are padded to 4. Their entry is `liFD` version 7: uuid, file name (its NUL counted), type, creator (`8BIM` for Photoshop documents), size, the contents, an empty child ID, time 0 and no lock. Version 7 is the newest version whose fields psd-tools and Adobe's specification describe; Photoshop 2026 refuses to open a file whose version 8 entry has only those fields, so it has more. An imported entry keeps its own version, and any bytes after the fields Compositor knows.
- **Duplicates** share one entry, as in Photoshop, and each gets a placement ID (`placed`) of its own.
- **One `lnk2` block** holds every smart object's entry, then the entries no layer names (kept from the file), where the file had its linked-layer blocks among the document-level blocks (first when it had none).
- **Smart objects made pixels** (Rasterize, a paint stroke, a filter, a clip baked in) are written as pixel layers without placed-layer blocks, and their contents aren't written. Placed-layer blocks Compositor couldn't read stay as the file had them, their entry among the others. A smart object from a project saved before Compositor kept smart objects is written as pixels with a warning, since its pixels may have been painted then; replacing its contents makes it a smart object again.

### Saving as Photoshop

- **A working format, as in Photoshop.** Save As offers a Format pop-up: Compositor Project or Photoshop. A Photoshop save makes the `.psd` the document's file, so ⌘S (and MCP `save_document`) writes it again. The document is marked saved. `.comp` stays the format that keeps everything. PNG and JPEG exports never mark the document saved.
- **The file a document was opened from is not its file.** A document opened from a PSD remembers it as its source. ⌘S asks where to save; the panel starts at Photoshop and the file's name, and choosing the original asks to replace it. Over MCP, `save_document` refuses (guard `project_file`), and `save_document_as` onto an existing `.psd`, the source included, needs `overwrite: true`.
- **Lossy items are agreed to first.** Some warnings are lossy: an adjustment Photoshop lacks written as pixels, a clipping applied to pixels or left out, a curve resampled, a shape saved as pixels or as a plain path, or the file's alpha channels or an adjustment's vector mask left out. The app lists them before writing anything (`PSDWriteReportSheet`, lossy items first, then the notes) and writes only on Save. A save whose warnings are all notes goes ahead without asking. Over MCP, the save is refused unless `allow_lossy: true`: guard `lossy`, the items in `details.warnings`, and nothing written. With it, the result's `warnings` list every item with its `lossy` flag.
- **Photoshop files open as their own documents.** File > Open lists `.psd` files. A PSD opened there, from the Dock or Finder, or dropped on the tab bar or on an empty tab opens as that file's document (its source and the Photoshop format), after the conversion sheet, as MCP `open_document` opens it. Dropped on a document, a PSD is imported into it as a folder of layers.
- **A failed save changes nothing.** The file is streamed into a temporary file on the destination's volume and moved over the destination in one step. A temporary file left beside the destination by a save that never finished, because the app quit or crashed during it, is removed by the next save to that file.

### Adjustment layers

- **Kinds Photoshop has** are written as Photoshop adjustment layers: a record with no pixels (flags 0x18, the layer's mask if any) whose first block holds the settings, padded to 4 bytes. The blocks are Levels `levl` (gamma × 100), Curves `curv` (then `Crv `), Hue/Saturation `hue2`, Exposure `expA`, Color Balance `blnc`, Invert `nvrt`, Black & White `blwh` (the tint as an `RGBC` color at full brightness), and Gradient Map `grdm`. A Gradient Map is written as version 1 (Classic) with two stops and smoothness 0, the straight ramp Compositor draws.
- **An imported adjustment layer** keeps its block byte for byte while its settings are still what import read from it. Once edited, the block is rewritten in place. It keeps what Compositor doesn't show:
  - the Hue/Saturation half that isn't Compositor's Master (Photoshop's Master while colorizing, otherwise the colorization);
  - the Levels records after the four channels;
  - a gradient's version, method, name and middle stops;
  - Black & White's other keys, and its tint color until the tint's hue or saturation changes.
- **Curves have at most 16 points.** A longer curve is resampled to 16 evenly spaced points along Compositor's curve, with a warning. The format allows 19, but Photoshop 2026 opens a Curves layer with 17 or more points as an empty pixel layer.
- **Kinds Photoshop lacks** (Grain, Gaussian Blur, Motion Blur, Add Noise, Profile) stop the save with `unsupportedAdjustment`. A save with `allowLossy` writes each one as a pixel layer instead, "<name> (rasterized)", holding what Compositor draws for it. The pixel layer stays in the same place and folder, and keeps the adjustment's opacity, blend mode, Fill, mask and clipping. The save warns about each one. What the adjustment is applied to depends on clipping:
  - **Unclipped:** everything Compositor draws below it. Folders pass through, so that includes the layers under its folder.
  - **Clipped in a clipping stack:** the stack alone, as Compositor draws one. That is the base at normal blend and full opacity, its color divided by its alpha, with the layers clipped to it below the adjustment drawn over it. Nothing below the base enters, since the base's blend and opacity apply to the whole stack afterwards. The pixel layer is opaque wherever the base has any alpha and empty elsewhere. Photoshop clips it to the base and draws the group at the base's alpha, blend and opacity, so pixels holding the base's alpha too would apply it twice. On a Multiply base at 50% and a Normal base at 60% with soft edges, Photoshop 2026 draws the result within 2 levels of Compositor.
- **The merged image** is Compositor's rendering, so it leaves out layers Compositor keeps only as placeholders: adjustment and fill kinds it can't draw. A save warns for each placeholder that Photoshop shows. Photoshop draws those layers itself, but apps that read only the merged image won't show them.

## Known differences

Measured in Photoshop 2026 (27.8) against Compositor's render of the same file (Tasks 4.9 and 5.1). The values written to the file are right: Photoshop reads them back as set and shows its own result. These are differences in how Compositor draws the adjustment, on the canvas, in exports and in the merged image it writes, and are not fixed yet.

- **Color Balance** is about three times stronger in Compositor. Midtones +50, −30, +20 on mid gray give (151, 103, 134) in Photoshop and (218, 75, 165) in Compositor; every channel moves the same way.
- **Hue/Saturation Master Lightness** is applied differently. At +5, Photoshop lifts black to 12 and keeps white at 255; Compositor keeps black at 0 and dims white to 242.
- **Black & White tint:** Photoshop keeps the tint's chroma constant into the highlights; Compositor's tint, mixed in HSL, fades toward white.
- **Gradient Map:**
  - Compositor draws a straight ramp from the first stop's color to the last. The locations and midpoints of an imported gradient's stops, and any stops between the ends, aren't drawn (they're kept and written back for Photoshop).
  - Photoshop's default smoothness for a new gradient is 100 %, which it draws differently from a straight ramp: up to about 11 levels apart in mid-dark tones. Gradient maps Compositor creates are written with smoothness 0, which Photoshop draws exactly as Compositor does.
  - Even at smoothness 0 the lightest and darkest colors can be up to 15 levels apart, from how each app weights luminance; mid gray is identical.
- **Exposure** agrees within 4 levels, and **Invert** and **Black & White** without a tint are identical.

**Edited text** is a difference in layout rather than drawing. Photoshop lays text out again from its engine data when the text is edited (as the harness does when it re-typesets), and its layout of text edited in Compositor differs from Compositor's: lines break and sit a few pixels apart. On three real templates (Photoshop 27.8, Task 5.5b-2), each with one text layer edited in Compositor, the edited layer's opened-vs-retypeset difference grew from 0% in the source to up to about 3% of the pixels in the written file (0.58%, 1.00% and 3.03%), all of it on and just below the edited layer, while untouched layers matched. The file stays editable: Photoshop opens it showing Compositor's pixels, and shows its own layout once the text is edited. The ratified criterion 5 (with its relative rule) therefore holds for untouched text only; edited text is judged at the looser threshold, `--max-fraction 0.002`, which these three files exceed too.

## Verification

Four scripts in `scripts/` check a PSD from the outside. None of them changes the file it checks, and all of them work on PSDs from any writer, Photoshop included.

| Script | Runs with | Produces |
| --- | --- | --- |
| `psd-verify.py` | `uv run --with psd-tools python3` (psd-tools 1.19) | the structure psd-tools reads, as text and optional JSON |
| `photoshop-verify.sh` + `photoshop-verify.jsx` | Adobe Photoshop 2026 (27.8), already running | what Photoshop sees, as JSON, and two PNG renders |
| `psd-diff.py` | the system `python3` with Pillow (`uv run --with pillow` if it lacks Pillow) | a pixel comparison of two renders |

### Client data

Layer names, text, document names and file names are client data. By default, neither report stores them. Each string is stored as its SHA-256 instead: 64 lowercase hex digits of its UTF-8 bytes, taken as-is with no normalisation, so text keeps its `\r` line separators. The fields are `name_sha256`, `text_sha256` / `contents_sha256`, and `file_sha256` (the hash of the file's name without its directory). Both tools hash the same way, so the hashes can be compared directly. `photoshop-verify.jsx` carries its own ES3 SHA-256, and its tests check it against Python's `hashlib`. Error and warning messages can quote those strings, and Photoshop's messages name the layer, so every name, text and file name (or path) a tool has seen is replaced in them with `#` and the first 12 hex digits of its hash. psd-verify's printed summary shows names the same way.

Font names are not client data here, and both reports list them in the clear (`fonts`, and each text layer's font): they name published typefaces, and pass criterion 3 compares them between the two reports. A client's choice of typefaces can still point to the client, though, so they stay out of what this repository publishes to others: the agent skills' deny-list (`DENIED_TERM_HASHES` in `scripts/tests/test_skills.py`) refuses the typefaces used across the owner's client corpus, and a report, like a render, belongs outside the repository.

`--raw` (on either `psd-verify.py` or `photoshop-verify.sh`) also stores the strings themselves (`name`, `text` / `contents`, `file` as the full path, and `document.name`) next to their hashes, and leaves messages unchanged. Use it only for debugging. With or without `--raw`, write reports and renders outside the repository (`/private/tmp`), because the PNG renders are the client's pixels. Run the tools on copies of client files, never on the originals.

### psd-verify.py

```sh
uv run --with psd-tools python3 scripts/psd-verify.py file.psd [--json out.json] [--raw]
```

Prints a summary and, with `--json`, writes the full report:

- `file_sha256` (plus `file`, the path as given, with `--raw`) and `raw`.
- `header`: `version`, `channels`, `width`, `height`, `depth`, `color_mode`.
- `layer_count`: the signed count from the layer info. Negative means the first alpha channel is the merged image's transparency (Photoshop pairs this with `channels = 4`; an opaque Background gives `channels = 3` and a positive count).
- `resources`: every image resource as `{id, name}` in file order (`name` is null for ids psd-tools doesn't know, such as 1092 and 1097).
- `document_blocks`: the document-level tagged block keys in file order.
- `guides`: resource 1032 as `{location, direction, axis, position}`: `location` in 1/32 px as stored, `direction` 0 (vertical) or 1 (horizontal), `position` in pixels. Empty when there are none.
- `layers`: every layer in Photoshop's order (top to bottom, each group before its contents), with `index`, `depth` (nesting level), `kind` (psd-tools: `group`, `pixel`, `type`, `smartobject`, `shape`, or a fill or adjustment class such as `solidcolorfill` or `huesaturation`), `name_sha256` (plus `name` with `--raw`), `bbox` `[left, top, right, bottom]`, `blend_mode` (psd-tools `BlendMode` name), `opacity` and `fill_opacity` (0–255 as stored), `visible` (the layer's own flag), `clipping`, and `locks` (the `lspf` value and its bits, or null without `lspf`). Where present:
  - `text`: `text_sha256` of `TypeLayer.text` (`\r` between lines; plus `text` with `--raw`), `text_type` (`POINT` or `PARAGRAPH`), `transform` (`xx xy yx yy tx ty`), `fonts` (PostScript names in use) and `font_sizes` (each style run's `FontSize`, before the transform).
  - `effects`: `enabled` (the master switch) and the effects psd-tools keeps (present ones) as `{name, enabled, shown}`.
  - `smart_object`: `unique_id`, `kind` (`data`, `alias` or `external`), `filetype` and `filesize`.
- `warnings`: every message psd-tools logged at warning level or raised as a Python warning. `errors`: a file or block psd-tools couldn't read. Both are scrubbed as described under "Client data".

Exit status: 0 when there are no warnings or errors, 1 otherwise, 2 for bad arguments.

### photoshop-verify.sh

```sh
scripts/photoshop-verify.sh [--raw] copy.psd out-dir
```

Runs `photoshop-verify.jsx` in Photoshop through `osascript` (`do javascript file … with arguments {in, out, "hashed" | "raw"}`; nothing is quoted into the script). The harness:

1. refuses a file that is already open in Photoshop, and treats `app.open` as failed unless it added a document, so it can only ever close a document it opened;
2. sets `displayDialogs = NO`, `rulerUnits = PIXELS` and `typeUnits = POINTS` for the run;
3. opens the file and records the document (`name_sha256`, size, resolution, mode, bits), its guides (`doc.guides`: direction and coordinate in px) and every layer, walking `doc.layers` recursively: kind, `name_sha256`, bounds (with and without effects), `textItem` `contents_sha256`, font, size (pt), kind and justification, locks, blend mode, opacity, `fillOpacity`, `grouped` (clipping), visibility, whether it's the Background, and effects read with Action Manager (`executeActionGet` → `layerEffects`, each effect's `enabled` and `present`);
4. exports `<name>.opened.png` (Save a Copy as PNG);
5. re-typesets every text layer by setting its own `textKey` descriptor back on it, which makes Photoshop lay the text out again from the stored engine data with every style run kept (a fully locked layer is unlocked for this and locked again), then exports `<name>.retypeset.png`;
6. closes the document with `SaveOptions.DONOTSAVECHANGES`, restores the preferences, `displayDialogs` and the previously active document, and writes `<name>.verify.json`.

The script prints `ok <json>` and exits 0, or prints `failed <json>: <first error>` and exits 1. The report starts with `file_sha256` (plus `file` with `--raw`) and `raw`. `exports` records whether `<name>.opened.png` and `<name>.retypeset.png` were written next to the report, `errors` lists every failure, and `retypeset` has `{index, ok, error}` for each text layer. Messages are scrubbed as described under "Client data". Photoshop's layer `index` and `depth` follow the same order as psd-verify's.

`displayDialogs = NO` doesn't hold back every alert: a file Photoshop can't fully read (a line whose Smart Shape data it rejects, for example) raises one while `app.open` waits, and Photoshop then waits too. So while the harness runs, the script looks every 2 seconds, through System Events, for Photoshop windows that are dialogs (the terminal running it needs Accessibility access). It presses a dialog's Cancel button, or the only button of a one-button alert, appends the dialog's text to `<out-dir>/alerts.txt` (names scrubbed as above), and exits 1. A dialog it can't dismiss is reported as still open and the run stops. A dialog already open before the run starts, such as one of the user's own, stops the run before Photoshop is asked anything (exit 3), as does System Events being out of reach.

### psd-diff.py

```sh
python3 scripts/psd-diff.py a.png b.png [--tolerance 8] [--max-fraction 0.002]
```

Compares the two images with premultiplied alpha, so colour under full transparency doesn't count and an opaque RGB image equals the same pixels as RGBA. A pixel differs when any channel differs by more than `--tolerance` (0–255, default 8). Prints the differing count, fraction and largest channel difference, then PASS when the fraction is at most `--max-fraction` (default 0.002 = 0.2%). Exit status: 0 pass, 1 fail, 2 when the images can't be compared (unreadable, or different sizes).

### Matching the two reports

| psd-verify | Photoshop | They match when |
| --- | --- | --- |
| `file_sha256` | `file_sha256`, `document.name_sha256` | equal when both tools were given the same file name (Photoshop's document name is the file's name) |
| `layers` `index`, `depth`, `name_sha256` | same fields | equal, layer for layer |
| `kind` | `typename` / `kind` | `group` ↔ `LayerSet`; `pixel` ↔ `NORMAL`; `type` ↔ `TEXT`; `smartobject` ↔ `SMARTOBJECT`; `shape` ↔ `SOLIDFILL`, `GRADIENTFILL` or `PATTERNFILL`; `solidcolorfill` ↔ `SOLIDFILL`; `invert` ↔ `INVERSION`; other fill and adjustment kinds ↔ the same name in capitals (checked so far: 3 solid-colour shape layers, all `shape` ↔ `SOLIDFILL`; no fill or adjustment layers) |
| `bbox` | `bounds_no_effects` | equal (not for groups: psd-tools unions only their visible, unclipped children) |
| `blend_mode` | `blend_mode` | equal without underscores, except `COLOR` ↔ `COLORBLEND` |
| `opacity`, `fill_opacity` (0–255) | `opacity`, `fill_opacity` (%) | `round(% × 255 / 100)` equals the stored value (Photoshop gives no fill for groups) |
| `clipping` | `grouped` | equal (Photoshop gives none for groups) |
| `visible` | `visible` | equal |
| `locks` bits `transparency`, `composite`, `position`, `complete` | `locks` `transparent_pixels`, `pixels`, `position`, `all` | equal; Photoshop reports every text layer as pixel- and transparency-locked, so compare text layers on `all` and `position` only |
| `text.text_sha256` | `text.contents_sha256` | equal |
| `text.fonts` | `text.font` | Photoshop's font is in the list |
| `text.font_sizes[0]` × √\|xx·yy − xy·yx\| × 72 / resolution | `text.size` (pt) | within 0.5 pt |
| `text.text_type` | `text.kind` | `POINT` ↔ `POINTTEXT`, `PARAGRAPH` ↔ `PARAGRAPHTEXT` |
| `effects.items` names | `effects.items` with `present` | `DropShadow` ↔ `dropShadow`, `InnerShadow` ↔ `innerShadow`, `OuterGlow` ↔ `outerGlow`, `InnerGlow` ↔ `innerGlow`, `ColorOverlay` ↔ `solidFill`, `GradientOverlay` ↔ `gradientFill`, `PatternOverlay` ↔ `patternFill`, `Stroke` ↔ `frameFX`, `BevelEmboss` ↔ `bevelEmboss`, `Satin` ↔ `chromeFX`, each Photoshop name with or without `Multi` |
| `guides` | `guides` | same order; direction 0 ↔ `VERTICAL`, 1 ↔ `HORIZONTAL`; `position` equals `coordinate` |

### Pass criteria

A PSD Compositor writes passes when:

1. `psd-verify.py` exits 0: psd-tools reads it without a warning.
2. Layer count, names and kinds match between `psd-verify.py` and Photoshop, and locks, guides and clipping match too (table above).
3. Text layers are still `LayerKind.TEXT` with the same font, contents and size (± 0.5 pt at the document resolution).
4. The harness exits 0: no error, and no exception while re-typesetting.
5. Visual: for the untouched corpus round trip, Photoshop's two PNGs agree (judged against the source's own figure, as below), and Photoshop's `.opened.png` agrees with Compositor's `ImageExporter.pngData` render, at `psd-diff.py --tolerance 8 --max-fraction 0.0005` (under 0.05% of pixels). Edited text and effects use the looser default, `--max-fraction 0.002`.

**Measured caveat, not a pass rule.** Photoshop draws a just-opened file from the layer pixels stored in it, and lays the text out again from its engine data only when the text is edited. On Photoshop's own files, `.opened.png` and `.retypeset.png` can therefore already disagree. Of the four corpus files checked (Photoshop 27.8, all fonts installed), two agree exactly. The other two differ in 2.8% and 3.0% of their pixels. In the first, Photoshop now sets several lines a few pixels differently; the second was measured but not examined. Text created and saved in the same session differs only in edge anti-aliasing (largest channel difference 39). Setting the `textKey` descriptor back, setting `textItem.contents = textItem.contents` and setting the anti-alias method to itself all give identical renders, so the difference comes from the file, not the harness. Such a source would fail the first comparison in criterion 5 before Compositor writes anything, hence the relative rule below. When reporting a result, give both figures.

**Relative rule for the first comparison (ratified, in force, for untouched text; edited text is under Known differences):** measure the source PSD's own `.opened.png`/`.retypeset.png` comparison the same way. A written file passes that comparison when its differing fraction is no more than the source's, where the source already exceeds 0.05%; otherwise the 0.05% threshold applies as stated above.

Two other references: `uv run --with psd-tools python3 -m psd_tools export file.psd merged.png` writes the merged image stored in the file (the composite its writer saved; psd-tools composites the layers itself only when there is none), and psd-tools' own `composite(force=True)` is only a rough check, 0.25–0.8% off Photoshop on the corpus and about 5% with a drop shadow.

### Guides

Photoshop 27.8 saves guides as resource 1032: `u32 version (1) · u32 grid cycle H · u32 grid cycle V · u32 count`, then per guide `u32 location` in 1/32 px and `u8 direction` (0 vertical, 1 horizontal). A new 72 ppi document with guides added by script at 64 px (vertical), 33 px (horizontal) and 150.5 px (vertical) saved as

```
00000001 00000240 00000240 00000003  00000800 00  00000420 01  000012d0 00
```

version 1, a grid cycle of 576 (18 px) on both axes, and locations 2048, 1056 and 4816: scripted guides keep half pixels.

### Testing the scripts

```sh
uv run --with psd-tools python3 -m unittest discover -s scripts/tests
```

The psd-diff and harness tests also run under the system `python3`; the harness tests parse `photoshop-verify.jsx` with `node` and never contact Photoshop.
