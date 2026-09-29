# PSD round trip: what survives, what is rewritten, what is flagged

Compositor opens a PSD, keeps the Photoshop data it doesn't model alongside the layers,
and writes it back. The rule is **preserve by default**: an untouched layer goes back out
byte for byte, an edited one is rewritten from Compositor's model, and anything
approximated is reported rather than hidden. Use this checklist to tell the user what to
expect, and to decide whether a deliverable should be a PSD, a `.comp`, or a flat export.

## Contents

- [Survives untouched](#survives-untouched)
- [Rewritten when you edit it](#rewritten-when-you-edit-it)
- [Flagged when the file is opened](#flagged-when-the-file-is-opened)
- [Flagged or refused when a PSD is saved](#flagged-or-refused-when-a-psd-is-saved)
- [Choosing the output format](#choosing-the-output-format)

## Survives untouched

For a layer you didn't change, the saved PSD carries what the source had:

- Every tagged block, in its order: type (`TySh`), effects (`lfx2`, `lrFX`), vector shape
  and stroke data, smart-object placement, adjustment settings, and blocks Compositor has
  no model for at all; the bytes after the last block too.
- The record's own fields: blend key (including blend modes Compositor draws as Normal),
  clipping and filler bytes, flags, blending ranges, Photoshop layer ID, color label, and
  the mask's flags, default color and density/feather parameters. A mask Compositor padded
  to cover its layer is cropped back to the rectangle Photoshop stored, as long as the
  padding is still the mask's default color.
- Placeholder layers (`kind: "placeholder"`: adjustments and fills Compositor can't
  apply) come back exactly, visible in Photoshop as before even though Compositor shows
  them hidden.
- Document data: image resources (resolution, guides with their grid, slices, print
  settings, ICC profile description and anything unknown), document-level tagged blocks,
  global layer mask info, color mode data, the global light angle, and the Background
  layer when it is still the opaque bottom layer. Not the file's alpha or spot channels
  (saved selections), which Compositor doesn't keep (a lossy item, below); after Crop,
  Canvas Size, Image Size or Flip Canvas the saved paths move with the canvas and the
  slices are left out.
- Folders keep their section dividers and open/closed state.

Renaming, hiding, locking or changing a layer's opacity rewrites only those fields (below),
not its pixels, type, vector or effect data; moving or resizing it rewrites its pixels too.

## Rewritten when you edit it

| You change | The PSD gets |
|---|---|
| name, visibility, opacity, fill opacity, blend mode (to one Compositor models), locks | the record field or its block (`luni`, `lspf`, `iOpa`) rewritten in place; everything else kept |
| position, scale, rotation, flip | new pixel data baked into an upright rectangle (a turned layer is resampled); a live text, shape or smart object keeps its type, vector or placement data updated to the new transform (a shape turned by other than quarter turns keeps its outline as a vector path, without its shape settings: a lossy item, below) |
| pixels (painting, filters, `set_layer_pixels`, masks applied) | new channel data from Compositor's render of the layer; a text or shape layer whose pixels were changed, or a smart object distorted or with its mask applied, is written as plain pixels (pixel tools refuse a smart object's own pixels) |
| a mask | the mask Compositor shows, written as the user mask (Photoshop recombines it with any vector mask) |
| text content or style | a new type block from Compositor's single style (font, size, color, tracking, leading, alignment); Photoshop lays the text out again when it's edited there |
| a live shape's geometry, fill or stroke | new vector data: a vector mask with Photoshop's live-shape settings, fill and stroke (a line's round ends become flat) |
| layer effects Compositor models (stroke, drop shadow, inner shadow, outer glow, inner glow, color overlay) | those effects rewritten from Compositor's settings inside the original effects block, so settings Compositor doesn't model (contour, noise, spread) survive; an effect added in Compositor gets Photoshop's defaults for the rest |
| a smart object's contents (`replace_smart_object_contents`) | the new contents embedded for Photoshop, with the placement from the layer's quad |
| adjustment layer settings | the adjustment block rewritten for Levels, Curves, Hue/Saturation, Exposure, Color Balance, Black & White, Invert and Gradient Map, keeping what Compositor doesn't show; kinds Photoshop lacks are rasterized (below) |
| new layers | the blocks Photoshop itself writes for a new layer |
| anything | a new merged composite image, rendered by Compositor |

## Flagged when the file is opened

`open_document` (and `revert_document`) return `conversions`, one `{layer, message}` per
thing Compositor converted or keeps only to write back. Common ones and what they mean for
a fill job:

| Note says | What it means |
|---|---|
| a font "isn't installed" | the layer shows Photoshop's pixels; editing it redraws in the named substitute |
| "Justified text isn't supported" | editable as left- (or center-) aligned text |
| the text's settings or type data couldn't be kept live | the layer stays Photoshop's pixels; recreate the text to change it |
| an effect "isn't supported, so it isn't shown" (bevel, satin, gradient or pattern overlay, inner glow, a second shadow) | not drawn in Compositor previews or exports, but written back to the PSD |
| "The stroke is centered … Compositor draws it outside" | previews differ slightly from Photoshop at the stroke |
| a value "was set to" something | an effect setting beyond Compositor's range was clamped for drawing |
| a smart object's "contents aren't stored in the file", or "settings couldn't be read" | it keeps Photoshop's pixels (and data) but can't be replaced |
| "Vector shape was rasterized" / "layer type isn't supported and was imported as pixels" | pixels only; the source data is still written back while untouched |
| an adjustment or fill "isn't supported" | a hidden placeholder, written back unchanged |
| a blend mode "will be applied as Normal", a folder "will be pass-through" | previews differ from Photoshop; the mode is written back |
| "Adjustment parameters may not match Photoshop exactly" | previews of that adjustment are approximate |
| clipping of a folder, or to an unsupported base, "was skipped" | previews show it unclipped; the clipping byte is written back |
| "Placed at pixel size; the file was N ppi" | a PSD placed into another document at its pixel size |

Flat exports (`export_image`) draw what Compositor draws. When a note says something
isn't shown, the PNG differs from Photoshop's rendering there: tell the user, and check
that slot in a render.

## Flagged or refused when a PSD is saved

Saving as `.psd` returns the writer's `warnings`, one `{layer, message, lossy}` for each
thing the file holds differently from the document. Pass every one on to the user.

Lossy items change what the file holds. Without `allow_lossy: true` the save refuses
(guard `lossy`, the items in `details.warnings`, nothing written):

- an adjustment layer Photoshop has no adjustment for (Grain, Gaussian Blur, Motion Blur,
  Add Noise, Profile), saved as "<name> (rasterized)", a pixel layer of its result on the
  layers below (or on its clipping stack);
- a clipping base that isn't the layer directly below, as Photoshop requires: the clipping
  is applied to the layer's pixels or, on an adjustment or an empty layer, left out
  (Photoshop shows the layer unclipped);
- a Curves channel with more points than Photoshop holds, resampled to 16;
- a shape Photoshop can't keep live: one turned by other than quarter turns is saved as a
  vector path without its shape settings (pixels when reopened in Compositor); one with
  no area (a line whose ends meet, a shape its stroke covers) is saved as pixels; an
  imported Photoshop shape Compositor keeps as pixels, once moved, resized, painted or put
  on another canvas, is saved as pixels without its shape;
- the file's alpha or spot channels (saved selections), which Compositor doesn't keep;
- an adjustment's Photoshop vector mask after Crop, Canvas Size, Image Size or Flip
  Canvas: saved without it, so Photoshop applies the adjustment unmasked.

Notes never stop a save:

- a layer larger than Photoshop allows: only its part on the canvas is saved;
- a line's round ends are flat in Photoshop;
- a Hue/Saturation color range is applied inside its band, as Photoshop can;
- a placeholder Photoshop shows, or an effect Compositor doesn't draw, is left out of the
  merged image apps without layers show;
- a smart object from a project saved before Compositor kept smart objects is saved as
  pixels.

When the save refuses, ask the user whether to accept the approximation, deliver a `.comp`
too, or remove the feature. Other refusals: a document past 30,000 px per side or 100
megapixels, more than 32,767 layer records or 4 GB of layer data (guard
`photoshop_limits`), or a text layer that can't be encoded.

## Choosing the output format

- **`.psd`**: for designers who continue in Photoshop. Faithful for untouched layers;
  edited layers as the table above; read the warnings.
- **`.comp`**: Compositor's own format keeps everything Compositor models, losslessly,
  plus all the Photoshop data for writing a PSD later. Save one beside a PSD delivery when
  anything was approximated.
- **PNG / JPEG**: what the client sees; matches Compositor's render, which can differ from
  Photoshop's where a conversion note says so.
