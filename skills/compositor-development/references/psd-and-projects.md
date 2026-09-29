# PSD features and the .comp format

Compositor's promise to its owner is that a layered Photoshop file can be opened, edited
and saved back without losing anything Photoshop put in it. Two pieces carry that promise:
the PSD reader, which keeps everything, and the `.comp` project format, which stores
everything. This reference covers the rules for both and the end-to-end path for a new
Photoshop feature. The formal specs are `docs/project-format.md` and `docs/psd-export.md`.

## Contents

- [Preserve by default](#preserve-by-default)
- [The .comp format and its versions](#the-comp-format-and-its-versions)
- [Adding a Photoshop feature end to end](#adding-a-photoshop-feature-end-to-end)
- [Verifying PSD files from the outside](#verifying-psd-files-from-the-outside)
- [Client files](#client-files)

## Preserve by default

Never drop or normalize Photoshop data because Compositor doesn't understand it. What the
reader keeps (`Compositor/Document/PSDExtras.swift`):

- **Per layer, `PSDLayerExtras`**: every additional-layer-info block in file order
  (`blocks`, `luni`, `lsct` and `lsdk` included, each byte for byte), and the layer
  record's fields as stored: the four-character `blendKey` (including modes Compositor
  lacks), `flags`, `clippingByte`, `fillerByte`, mask flags, default colour and parameters,
  `blendingRanges`, `trailingBytes`, the Photoshop `layerID`, `colorLabel`, `nameSource`.
  A folder also keeps its hidden section-divider record (`sectionDividerExtras`).
- **Per document, `PSDDocumentExtras`**: every image resource in order, the document-level
  tagged blocks, linked-layer entries no smart object refers to, global layer mask info,
  colour mode data, channel count and alpha channel names, ICC profile name, global light,
  the source file name and the layer-count sign.

How modeled features coexist with the raw data:

- A feature Compositor decodes (locks from `lspf`, fill from `iOpa`, text from `TySh`,
  shapes from vector blocks) sits **alongside** its block, which stays in `blocks` exactly
  as read. A writer re-emits an untouched layer's blocks byte for byte and regenerates a
  block only when the live layer no longer matches what was imported.
- To tell "untouched" from "edited", import records what it made of the layer:
  `importedName`, `importedText`, `importedTextAnchor`, `importedTextIsBox`,
  `importedShape`, `importedEffects`, `importedVisible`. They are never drawn. When you
  model a new editable feature, add its `imported…` snapshot the same way.
- A layer Compositor can't show (an adjustment kind it lacks, for example) becomes a hidden
  placeholder layer with no pixels (`placeholder`, such as `adjustment:brit`) instead of
  disappearing, so it can be written back in place.
- Every conversion the user should know about (rasterized, substituted, kept only for
  writing back) is a `PSDConversion` note from `PSDDocumentBuilder`; the UI shows them in
  the conversion sheet, and headless opens return them.
- Import fits Photoshop data to the project's size caps and says in a conversion note what
  it had to drop, so an imported PSD always saves as a project.
- Untrusted input never traps: lengths are bounds-checked, huge or non-finite values are
  rejected or ignored (see the `…WithoutTrapping` tests in `PSDRoundTripTests`), and a
  malformed file fails with a `PSDError`, leaving the open tabs as they were.

The writer lives in `Compositor/IO/PSD/Writer/`: `PSDWriter` (header, resources, layer and
mask info, merged image; `PSDWriteOptions` with `allowLossy` and `preserveExtras`, a
`PSDWriteReport` of warnings), `PSDLayerRecordWriter` (records bottom to top, writing back
each imported layer's blocks, blend key, clipping and flags while the layer still matches
them), `PSDLayerBaker` (each layer's pixels and mask in an axis-aligned rectangle),
`PSDCompositeWriter`, `PSDImageResourcesWriter`, and `PSDDescriptorWriter`, the byte-exact
inverse of the descriptor reader. Edited features have writers of their own, each keeping
the file's block while the layer still matches it: `PSDEffectsWriter` (`lfx2`),
`PSDVectorWriter` (shape layers' vector blocks), `PSDTextWriter` (`TySh`),
`PSDSmartObjectWriter` (`PlLd`/`SoLd` and the `lnk2` contents) and `PSDAdjustmentWriter`
(adjustment blocks; kinds Photoshop lacks, such as Grain, the blurs and Profile, become pixel
layers of their result, and only with `allowLossy`). A warning marked `lossy` changes what
the file holds. Save As writes a PSD in the app (the Format pop-up in `ProjectController`,
after `PSDWriteReportSheet` lists any lossy items) and over MCP (`save_document_as` with a
`.psd` path, refused with guard `lossy` unless `allow_lossy: true`); the `.psd` then becomes
the document's working file. `docs/psd-export.md` has the policies. Keep the original block
whenever you model something, or the writer loses its byte-exact path for untouched layers.

## The .comp format and its versions

A `.comp` file is a package: `manifest.json`, `images/<layer UUID>.png` (and
`.mask.png`), and for documents from Photoshop a `psd/` folder of sidecars in Photoshop's
own wire format (`<layer UUID>.blocks`, `<layer UUID>.divider.blocks`,
`document.resources`, `document.blocks`, `document.linked`). `ProjectStore` writes it
atomically and validates everything (versions, assets, sidecars, sizes, parent links)
before it replaces the open document. `ProjectManifest.current` is 11; versions
1–11 all read.

Rules for a schema change:

1. **Bump the version when an older build would get it wrong.** If a build that doesn't
   know the field would draw the document differently or silently lose meaning (folders,
   masks, clipping, adjustment layers, folder opacity, Photoshop data), increment
   `ProjectManifest.current`. Older builds then refuse the file with "This project
   uses format version N" instead of misrendering it.
2. **Additive metadata that an older reader can safely ignore needs no bump.** Editable
   text and live shape sources were added that way: the layer's PNG is still what an older
   build draws, so it shows the same pixels and merely can't re-edit them.
3. **Gate new fields by version.** In `ProjectStore`'s validation, a file declaring a
   version older than the field's must not carry it (the existing checks read
   `guard manifest.version >= 10 else { throw ProjectError.invalid }`). This keeps every
   version's meaning fixed.
4. **Missing means default, and defaults are omitted.** Decode a missing field as the
   neutral value and write `nil` for it (`locks.isEmpty ? nil : locks`,
   `fillOpacity == 1 ? nil : fillOpacity`), so old and new files of the same document
   compare equal.
5. **Carry it everywhere.** Add the field to `ProjectLayerRecord` and to both mappings in
   `Compositor/Document/ImageLayer+Record.swift`, and to `scaled(…)` / `translated(by:)`
   when it has geometry. Saving, Image Size, Canvas Size, Crop, copies between tabs, export
   and MCP previews all go through those.
6. **Validate like the rest**: finite numbers, ranges, and size limits (4 MiB manifest,
   512 MiB per image asset, 64 MiB per layer blocks sidecar, 2 GiB of sidecars in total;
   see `docs/project-format.md` for each).
7. **Document and test**: the field, its range and its version in
   `docs/project-format.md`; a save-and-reopen test; a rejection test for an older version
   carrying it; a test that Image Size, Canvas Size and Crop keep it.

## Adding a Photoshop feature end to end

1. **Know the bytes.** Work from Adobe's *Photoshop File Formats Specification* and
   cross-check against psd-tools' source
   (`uv run --with psd-tools python3 -c "import psd_tools, inspect; print(inspect.getsourcefile(psd_tools))"`).
   Confirm against a small file you make in Photoshop yourself; memory and blog posts are
   often wrong about padding, length fields and versions.
2. **Read it.** Decode in `Compositor/IO/PSD/` from the block the reader already keeps
   (`record.extras`), with bounds-checked reads and `PSDError` for malformed data. The
   block stays in `blocks` unchanged.
3. **Model it.** Add a property with a neutral default to `ImageLayer` (or
   `CanvasDocument`), plus an `imported…` snapshot in `PSDLayerExtras` if the feature is
   editable and a writer will need to know whether it changed.
4. **Build it.** Map it in `PSDDocumentBuilder.makeImport`, and add a `PSDConversion` note
   wherever the result differs from Photoshop's (a substitute font, a rasterized effect).
5. **Draw it.** If it changes pixels, draw it in the renderer shared by the canvas and
   export (`LayerRenderer`, the effects renderers), never in the canvas alone.
6. **Save it.** Follow the `.comp` rules above.
7. **Expose it.** If agents need to see or change it, add it to the layer JSON in
   `MCPValues` and to `get_document`'s output, and follow
   [Adding an MCP tool](mcp-tools.md) for any new tool.
8. **Test it.** Build the file with `PSDFixture` (see [Testing](testing.md)), import it,
   and assert the modeled value, the conversion notes, that the raw block is still
   byte-identical in `psdExtras`, and a `.comp` round trip. Add hostile-input tests (short
   blocks, huge counts, NaN) that must fail cleanly.
9. **Document it.** `README.md`'s import bullet and `docs/project-format.md`.

## Verifying PSD files from the outside

Four scripts in `scripts/` check a PSD without changing it; `docs/psd-export.md` has the
full field reference and pass criteria.

```bash
uv run --with psd-tools python3 scripts/psd-verify.py copy.psd --json /private/tmp/report.json
scripts/photoshop-verify.sh copy.psd /private/tmp/ps-out          # needs Photoshop 2026 running
python3 scripts/psd-diff.py a.png b.png --tolerance 8 --max-fraction 0.002
```

- `psd-verify.py` reports what psd-tools reads (header, resources, guides, every layer's
  kind, bounds, blend, opacity, locks, text, effects, smart objects) and exits 1 on any
  psd-tools warning.
- `photoshop-verify.sh` runs `photoshop-verify.jsx` in the running Photoshop: it opens the
  file (refusing one that's already open there), records what Photoshop sees, exports the
  opened and re-typeset renders, and closes without saving.
- `psd-diff.py` compares two renders with premultiplied alpha.
- Layer names, text and file names are client data: both reports store only their SHA-256
  unless you pass `--raw`, which is for debugging alone. Run the tools on **copies** and
  write outputs to `/private/tmp`, because the renders are the client's pixels.
- The script tests run with
  `uv run --with psd-tools python3 -m unittest discover -s scripts/tests`; the Photoshop
  harness tests parse the JSX with `node` and never contact Photoshop.

## Client files

The owner's real PSDs are client work. They never enter the repository, a test fixture, a
doc, a commit message or a skill, and neither do their names, layer names or text. Probe
them only through copies in `/private/tmp`, with a time limit per file (see the privacy
notes in [Testing](testing.md)), and report findings as counts or hashes.
