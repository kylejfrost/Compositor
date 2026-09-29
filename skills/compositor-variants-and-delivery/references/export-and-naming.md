# Export and naming

## Contents

- [export_image options](#export_image-options)
- [PNG or JPEG](#png-or-jpeg)
- [Pixel density and print](#pixel-density-and-print)
- [Naming](#naming)
- [Folders](#folders)
- [Layered deliverables](#layered-deliverables)

## export_image options

| Argument | Use |
|---|---|
| `path` | required; absolute, `~/…`, or relative to the Agent folder; the extension picks the format unless `format` says |
| `format` | `png` or `jpeg`; a `.jpg`/`.jpeg` extension is added for JPEG when missing. `format` wins over the extension without a warning (a `.jpg` path with `format: "png"` gets PNG bytes), so leave it out or keep the two the same |
| `quality` | JPEG only, 0–1, default 0.85 |
| `background` | what shows through transparency: PNG defaults to `transparent`, JPEG to `white`; also `black`, `checkerboard` |
| `scale` | output pixels per document pixel, 0.05–4 |
| `max_size` | cap on the longest side (16–30,000); scales down only |
| `region` | `{x, y, width, height}` of the canvas to export (rounded out, clamped) |
| `overwrite` | replace an existing file; default false |

The result reports `path`, `format`, `bytes`, `width`, `height`, `scale` and the document
size. Exports never mark the document saved, and they draw exactly what `render_document`
shows (so a Photoshop feature Compositor doesn't draw is missing from the export too).
Exports are limited to 30,000 px per side and 200 megapixels (`pixel_budget`).

## PNG or JPEG

| Content | Format | Why |
|---|---|---|
| text, logos, flat color, UI | PNG | lossless: sharp edges, exact brand colors |
| anything with transparency (cutouts, stickers, overlays) | PNG | JPEG can't hold transparency |
| photos, photo-heavy social posts | JPEG, `quality` 0.85–0.92 | a fraction of the PNG's size with no visible loss |
| platforms that recompress uploads | JPEG 0.9–0.95 or PNG | less double-compression damage |
| print | PNG (or the printer's requested format) at 300 ppi | lossless; resolution stored in the file |

Check `bytes` against any limit the user or platform has (email headers under ~1 MB,
many ad networks 150 KB–5 MB); lower `quality` in steps of 0.05 rather than shrinking the
pixel size.

## Pixel density and print

- Retina / high-density screens: export at `scale: 2` of the CSS size (a 600 × 200 email
  header at 1200 × 400) and let the consumer display it at half.
- Print: the document's `resolution` (set at `new_document`, or `set_resolution`) is
  stored in exports; pixel size = inches × 300. Don't raise `resolution` to "make it
  print-ready": it changes no pixels.

## Naming

Names should sort, describe and never collide:

```
<project>-<variant>-<width>x<height>[-<language or row>][-v<version>].<ext>
spring-sale-story-1080x1920.jpg
spring-sale-feed-1080x1350-de.jpg
card-jordan-rivera-1080x1350.png
```

- Lowercase, hyphens, no spaces or punctuation beyond `-` and `.`; slug names from data
  (`Jordan Rivera` → `jordan-rivera`, accents folded, apostrophes dropped).
- Include the pixel size: people choose files by it, and verification can check it
  against the name.
- Never reuse a name: when a file exists (`io_error`, `details.code: "file_exists"`),
  add or bump a version suffix rather than passing `overwrite: true`, unless the user
  asked to replace that exact file.

## Folders

- One folder per delivery: `out/<project>/` (relative paths land in the Agent folder), or
  the folder the user names. Keep masters (`.comp`, `.psd`) apart from exports:
  `out/<project>/masters/` and `out/<project>/exports/`.
- Don't write into the source template's folder unless asked ("next to the template" is a
  request to do exactly that, with new names).
- Writing to Documents, Desktop, Downloads or cloud folders may need macOS permission
  (`folder_access_pending` / `folder_access_denied`); the Agent folder never does. Offer
  to deliver there and `reveal_in_finder` it.

## Layered deliverables

- `.comp`: Compositor's own format keeps everything losslessly, including the Photoshop
  data of an opened PSD. Always keep one for each master.
- `.psd` (when `get_app_info.features` lists Photoshop saving): `save_document_as` with a
  `.psd` path (or `format: "psd"`), to a new file. The result lists `warnings` for
  anything Photoshop can't hold as Compositor has it; without `allow_lossy: true` the
  save refuses instead of approximating. Pass the warnings on, and verify the PSD (see
  [Verification and contact sheets](verification-and-contact-sheets.md)).
- `set_as_current: false` saves a copy and leaves the open document tied to its original
  file; the default makes the new file the document's own.
- A layered delivery goes with a flat PNG or JPEG preview of the same state, so the client
  can see it without the app.
