# Verification and contact sheets

## Contents

- [Check every file](#check-every-file)
- [Sources untouched](#sources-untouched)
- [PSD deliverables](#psd-deliverables)
- [Comparing two renders](#comparing-two-renders)
- [Contact sheets](#contact-sheets)

## Check every file

After exporting a set, check it as a set, from the shell, against the plan:

```bash
cd "$HOME/Library/Application Support/Compositor/Agent/out/spring-sale" || exit 1
for file in *.png *.jpg; do
  [ -e "$file" ] || continue
  size=$(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w "x" h}')
  case "$file" in *"$size"*) status=ok ;; *) status="SIZE MISMATCH" ;; esac
  printf '%-45s %-11s %8s bytes  %s\n' "$file" "$size" "$(stat -f %z "$file")" "$status"
done
```

(When the files carry their size in the name, as the naming convention suggests, the
name itself is the expected size.) Then look at them: a `render_document` of each
variant before export, or the contact sheet below, catches what sizes can't (a clipped
headline, a logo in the story's reply bar).

## Sources untouched

Record `shasum -a 256` of the master and every source file (templates, photos) before
starting, and compare at the end; the digests must match. A changed digest means an
output path pointed at a source: stop, tell the user, and restore from their backup or
version history, not by guessing.

## PSD deliverables

`psd-verify.py`, `psd-diff.py` and `photoshop-verify.sh` come with this skill: in its own
`scripts/` folder when it is a packaged copy (`<skill>/scripts/psd-verify.py`, where
`<skill>` is this skill's base directory), or, when it was installed as a link into a
Compositor checkout with `scripts/install-skills.sh`, in that checkout's `scripts/` two
folders up (`$(cd -P <skill>/../.. && pwd)/scripts`). Check once with `ls`, then call
them by absolute path. Where they can't reach the files (Claude Desktop runs a skill's
scripts in its own sandbox), reopen each saved PSD in Compositor (`open_document`, then
`get_document` with `detail: "full"`) and compare its layers with the master's, and say
that this was the check. For each `.psd` written:

```bash
uv run --with psd-tools python3 <skill>/scripts/psd-verify.py "out/spring-sale/masters/spring-sale-feed-1080x1350.psd" --raw
```

It prints the header and every layer (top to bottom, indented by depth) with its kind,
name, bbox, opacity, locks and, for text, font and size; `--json <file>` also writes the
full report. Pass rules (the full table is in a Compositor checkout's
`docs/psd-export.md`):

1. `psd-verify.py` exits 0: psd-tools reads the file without warnings.
2. Layer count, names and kinds match the document you saved (and the source PSD, except
   for intended changes); locks, guides and clipping too.
3. Text layers are still `type` with the right font, contents and size.
4. Optional, when Photoshop is installed and already running and the user agrees:
   `<skill>/scripts/photoshop-verify.sh copy.psd out-dir` on a **copy** exits 0, and its
   `.opened.png` matches Compositor's export within `psd-diff.py --tolerance 8
   --max-fraction 0.002` (0.0005 for an untouched round trip).

Pass on every `warnings` entry the save returned, and every conversion note that touched
an element of the delivery.

## Comparing two renders

`uv run --with pillow python3 <skill>/scripts/psd-diff.py a.png b.png` compares two
same-size images with premultiplied alpha: it prints the count and fraction of pixels
differing by more than `--tolerance` (default 8) and PASS when the fraction is at most
`--max-fraction` (default 0.002). Use it to confirm that a re-export is unchanged, or
that two variants share an untouched region (crop both to the region first with
`export_image` `region`).

## Contact sheets

A contact sheet shows the whole set on one image, which is how people review a kit.

1. Lay out a grid: for `n` files in `c` columns, cells `cell` px square with `gap` px
   between and around them, a label band of `label` px under each cell:
   `width = c·cell + (c + 1)·gap`, `rows = ceil(n / c)`,
   `height = rows·(cell + label) + (rows + 1)·gap`. For 4 files: `c = 4`, `cell = 480`,
   `gap = 40`, `label = 60` gives 2120 × 620.
2. `new_document` at that size, `fill: "#f2f2f2"`, `name: "contact sheet"`.
3. For file `i` (0-based) at column `i mod c`, row `i div c`, the cell's top-left is
   `x = gap + col·(cell + gap)`, `y = gap + row·(cell + label + gap)`:
   `add_image_layer` with the file's path and `name`, then `scale_layer_to_fit` with
   `rect` = the cell and `mode: "contain"`, so every variant shows whole, at its own
   proportions.
4. Label each cell with `add_text_layer`: the file name and pixel size, `anchor: "top"`
   at the cell's center x and `y + cell + 8`, 22–28 px, dark gray; `fit_text` long names
   to the cell width.
5. `export_image` to `out/<project>/contact-sheet.png`, then close the sheet
   (`close_document` with `discard_changes: true`, since it is a disposable view) unless
   the user wants it kept.
6. Look at the exported sheet (or `render_document` before closing) and fix any variant
   that looks wrong before delivering.
