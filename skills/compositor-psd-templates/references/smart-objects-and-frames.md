# Smart objects and photo frames

Templates hold photos in one of four ways. Identify which before filling, because each
needs a different tool, and the wrong one breaks the frame.

## Contents

- [Which kind of frame is it?](#which-kind-of-frame-is-it)
- [Smart-object frames](#smart-object-frames)
- [Fit, fill and stretch](#fit-fill-and-stretch)
- [Clipped photo frames](#clipped-photo-frames)
- [Masked frames](#masked-frames)
- [Plain rectangles](#plain-rectangles)
- [What a smart object can hold](#what-a-smart-object-can-hold)

## Which kind of frame is it?

In `get_document` with `detail: "full"`:

| What you see | Frame kind | Fill with |
|---|---|---|
| `kind: "smart_object"`, `smart_object.natural_size` like a photo | smart object | `replace_smart_object_contents` |
| a `raster` or `shape` layer (the frame), with a layer above it that has `clipping: true` | clipping group | replace the clipped layer's pixels, or add a new clipped layer |
| a `folder` (or layer) whose `mask` shapes the photo | masked frame | add the photo inside the folder, or `set_layer_pixels` on the masked layer |
| a gray or colored `raster` rectangle named "Photo" / "Image here" | placeholder shape | add the photo above it, sized to it, then hide or delete the placeholder only if the user wants |

Render the frame alone (`render_layer`) or its region (`render_region` with the frame's
`bounds`) to see which it is when names don't say.

## Smart-object frames

`replace_smart_object_contents` (`layer`, `path`, `fit`, default `"fit"`) puts the file
inside the smart object and draws it in the object's placement. The layer keeps its id,
name, effects, mask, clipping and locks, and its `contents_revision` goes up by one; one
undo step. Its **placement follows the new contents' proportions**:

- An image with the frame's proportions lands exactly on the frame: the transform doesn't
  change.
- Any other image resizes the layer. `fill` makes it as large as it must be to cover the
  frame, centered, so the photo **spills past two sides of the frame and is drawn there**,
  over whatever sits next to the frame (nothing crops it; a mask added to the layer
  beforehand didn't hide the spill in a live test). `fit` shrinks it inside the frame and
  leaves two sides of the frame uncovered.
- A position lock refuses any replacement that would move or resize the layer
  (`layer_locked`: "The new contents would move or resize it"), and a pixel lock refuses
  every replacement.

So give a frame an image of its own proportions. That fills it edge to edge and keeps it
exactly where the designer put it, with its locks in place:

1. `get_smart_object_info` on the frame: its `quad` (four corners in document pixels;
   width `W` and height `H`) and `natural_size`.
2. Compare the image's `w × h` with `W × H`. When `w / h` equals `W / H` (within a pixel),
   replace it as it is.
3. Otherwise crop the image to the frame's proportions first, into a new file:
   - centered: keep `w' = min(w, round(h × W / H))` by `h' = min(h, round(w × H / W))` and
     run `sips --cropToHeightWidth <h'> <w'> <image> --out <cropped>` (height first);
   - around an off-center subject (a face near the top): `open_document` the image as a
     scratch document, `crop` to a `W:H` rectangle around the subject, `export_image` it,
     then `close_document` with `discard_changes: true`.
4. `replace_smart_object_contents` with the cropped file and `fit: "fill"`. Its result's
   `transform` should equal the frame's; check with `render_region` over the frame.

Only replace with an uncropped image of other proportions when the user wants the frame
itself to change shape; unlock the position lock for that (and say so), and check that
the new size doesn't cover the text or shapes around it.

More about smart objects:

- `get_smart_object_info` (or `smart_object` in `get_layer`) tells you what is inside now:
  `file_name`, `file_type`, `bytes`, `natural_size` (the contents' own size), `quad` (the
  four corners of the placement in document pixels: top-left, top-right, bottom-right,
  bottom-left), `embedded` and `contents_revision`.
- `export_smart_object_contents` writes the current contents to a file (never over an
  existing one without `overwrite`), useful to keep what was there before replacing it.
- `place_smart_object` adds a new smart-object layer from a file (for a frame that
  doesn't exist yet): its own size centered on `center`, or into `fit_rect` as `fit`
  says.
- Replacing happens outside any edit in progress: a pending free transform is committed
  first, and a crop or brush stroke in progress refuses the call (settle it first).

## Fit, fill and stretch

With the frame's placement `W × H` and the image's natural size `w × h`:

| `fit` | Scale | The layer afterwards |
|---|---|---|
| `"fit"` (default) | `min(W/w, H/h)` | the whole image, centered inside the frame; smaller than the frame on two sides when the proportions differ |
| `"fill"` | `max(W/w, H/h)` | the frame covered, centered; larger than the frame on two sides when the proportions differ, and drawn there |
| `"stretch"` | `W/w` and `H/h` separately | exactly the frame; distorted unless the proportions already match |

With an image cropped to the frame's proportions all three give the frame exactly.

Check a face or product after every replace: `render_region` over the frame's bounds at
full detail. A frame far larger than the photo upscales it; compare `natural_size` with
the frame's size and warn when the photo is smaller than the frame (it will look soft).

## Clipped photo frames

A clipping group is a base layer (the frame shape) with layers above it clipped to it
(`clipping: true`): they show only where the base has pixels.

- To swap the photo: `set_layer_pixels` on the clipped photo layer with the new file.
  `placement: "keep_bounds"` stretches the new image over the old layer's box (only right
  when the proportions match); `"keep_origin"` puts it at its own pixel size from the
  box's top-left; `"natural"` centers it upright at its own size where the layer was. Then
  size it: `scale_layer_to_fit` with `mode: "cover"` and the base's bounds as `rect`.
- Or add a new layer: `add_image_layer` (it goes above the active layer), `place_layer`
  directly above the frame (`above` the frame layer), `set_clipping_mask` with
  `enabled: true`, then `scale_layer_to_fit` with `mode: "cover"` and the frame's bounds.
  Hide or delete the old photo only when asked.
- Clipping follows the stack: a layer moved out of the group stops clipping, one moved
  into it starts. Keep the new photo directly above the base or above other clipped layers.

## Masked frames

A mask on the frame layer or its folder hides everything outside the frame shape. Put
the new photo inside the masked folder (`place_layer` with `parent`) or replace the masked
layer's pixels (`set_layer_pixels`); the mask keeps working either way. A mask linked to
its layer moves with it; an unlinked mask stays put while the photo moves inside it,
which is how a designer lets a photo be repositioned inside a fixed window.

## Plain rectangles

A flat rectangle marked "photo here" is not a frame: nothing clips to it. Add the photo
above it with `add_image_layer`, then `scale_layer_to_fit` with `mode: "cover"` and the
rectangle's bounds; to crop to the rectangle, clip the photo to it (`set_clipping_mask`),
or add a mask from a selection of its bounds (`select_rect`, then `add_layer_mask` with
`kind: "from_selection"`).

## What a smart object can hold

- Contents Compositor draws: PNG, JPEG, TIFF, GIF, SVG, PDF (first page) and Photoshop
  `.psd`. EPS is recognized but can't be drawn on current macOS; Large Document `.psb`
  contents (Photoshop's own embedded documents) keep the pixels Photoshop saved and can't
  be redrawn. Each contents file is at most 512 MiB.
- Painting, fills, filters, Levels, Hue/Saturation, `set_layer_pixels` and
  `paste_image_into_layer` refuse a smart object (`not_smart_object`) rather than drop
  its file; its mask can still be painted. `distort_layer` and `apply_layer_mask` do turn
  it into plain pixels (the smart object is dropped). Move, scale and rotate it instead;
  those keep it live. To change the picture, replace its contents.
- Replacing very large contents (hundreds of MB) can make that step impossible to undo;
  keep the original file.
- A saved PSD embeds the replaced contents, so Photoshop can open and edit them; read the
  save's `warnings` all the same (see [PSD round trip](round-trip.md)).
