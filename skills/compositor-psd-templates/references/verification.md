# Verifying a filled template

Prove three things before calling a template job done: the source is unchanged, the
output is a sound file with the structure the source had, and each slot shows what was
asked. Compositor's previews cover the last; these checks cover the first two.

## Contents

- [Where the verification scripts are](#where-the-verification-scripts-are)
- [1. The source is unchanged](#1-the-source-is-unchanged)
- [2. The PSD reads cleanly](#2-the-psd-reads-cleanly)
- [3. The structure matches the source](#3-the-structure-matches-the-source)
- [4. Photoshop agrees (optional)](#4-photoshop-agrees-optional)
- [5. Flat exports](#5-flat-exports)
- [Client files](#client-files)

## Where the verification scripts are

`psd-verify.py`, `psd-diff.py` and `photoshop-verify.sh` (with its `photoshop-verify.jsx`)
come with this skill, in one of two places:

- **In this skill's own `scripts/` folder** when the skill is a packaged copy (Claude
  Desktop, or any copy made with the checkout's `scripts/package-skills.sh`):
  `<skill>/scripts/psd-verify.py`, where `<skill>` is this skill's base directory (shown
  when the skill loads).
- **In a Compositor checkout's `scripts/` folder** when the skill was installed with the
  checkout's `scripts/install-skills.sh`: the skill is then a link into that checkout, two
  folders below its root, and has no `scripts/` of its own. `ls -L <skill>/scripts` fails;
  the checkout is `$(cd -P <skill>/../.. && pwd)`.

Look once (`ls <skill>/scripts`), then call the script by its absolute path, as below.
psd-verify needs `uv` (it runs psd-tools in a throwaway environment); psd-diff needs
Pillow (`uv run --with pillow python3 …`).

Where the scripts can't reach the files (Claude Desktop runs a skill's scripts in its own
sandbox, away from the Mac's files), check the saved PSD with Compositor itself: after
saving, `open_document` the new file (a new tab), `get_document` with `detail: "full"`,
and compare its layer tree with the template's (the same paths, kinds and locks; the
filled slots' new text and sizes), then `close_document` that tab. That shows what
Compositor reads back; it doesn't replace psd-tools or Photoshop as an outside check, so
say which check you ran.

## 1. The source is unchanged

```bash
shasum -a 256 "template.psd"
```

Run it before opening the template and again at the end; the two digests must match. A
Compositor tool never writes a file you didn't name as its output, so a changed digest
means an output path pointed at the source.

## 2. The PSD reads cleanly

```bash
uv run --with psd-tools python3 <skill>/scripts/psd-verify.py "out/Card - Endorser Name.psd" --raw
```

Exit status 0 means psd-tools read it without a warning; 1 lists warnings or errors;
2 is a usage error. It prints the header (size, depth, channels), the layer count, the
image resources and every layer in Photoshop's order (top to bottom, each group before its
contents, indented by depth): index, kind (`group`, `pixel`, `type`, `smartobject`,
`shape`, or an adjustment or fill class), name, bbox `(left, top, right, bottom)`, blend
mode, opacity, locks, and for type layers the text kind, font and size. `--raw` shows
names and text; without it they are hashed, so the output can be kept or shared without
client data. `--json <file>` also writes the full report (with each layer's text, effects
and smart-object data).

## 3. The structure matches the source

Run the same command on the template, then compare the two layer lists line by line:

- the same number of layers, in the same order, with the same depths, kinds and names;
- differences only on the slots you filled: a type layer's text (and its bbox when the
  words got longer or shorter), a photo's bbox only if the frame was meant to change;
- the locks as before (`locks 0x…` on the same layers).

A `type` layer that became `pixel` means a text slot was rasterized (it will no longer be
editable in Photoshop); a missing layer or a changed name is a bug to fix, not to report
as done. A smart-object frame whose bbox grew means the photo spills out of its frame (see
[Smart objects and photo frames](smart-objects-and-frames.md)).

## 4. Photoshop agrees (optional)

Only when the user asked for it and Photoshop is installed and already running: the
harness drives the user's Photoshop, opens a copy, records what Photoshop sees and renders
it twice. Run it on a copy, never on a file Photoshop has open:

```bash
mkdir -p ps-check && cp "out/Card - Endorser Name.psd" ps-check/card.psd
<skill>/scripts/photoshop-verify.sh ps-check/card.psd ps-check
```

It prints `ok <json>` or `failed <json>: <first error>`. Compare its layers with
psd-verify's (same order, `index` and `name_sha256`), and its `.opened.png` with
Compositor's export using `psd-diff.py` (tolerance 8; at most 0.2% of pixels may differ
with edited text and effects, 0.05% for an untouched round trip):

```bash
uv run --with pillow python3 <skill>/scripts/psd-diff.py ps-check/card.opened.png "out/card-endorser-name.png" --tolerance 8 --max-fraction 0.002
```

The full matching table and pass criteria are in a Compositor checkout's
`docs/psd-export.md`. The harness never saves the file it opens; delete `ps-check/` when
done.

## 5. Flat exports

`export_image` reports `width`, `height` and `bytes`; confirm on disk with
`sips -g pixelWidth -g pixelHeight "out/card-endorser-name.png"` (or `get_file_info`),
and open the image (or a `render_document` of the same state) to look at every slot.

## Client files

Templates are client work. Keep saved reports and renders out of any repository, and
don't store `--raw` output (it holds the names and text); run Photoshop checks only on
copies, and never paste layer names or text from a client file into a commit, issue or
skill.
