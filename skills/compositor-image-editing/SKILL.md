---
name: compositor-image-editing
description: Edit photos and pixels in Compositor through its MCP tools, non-destructively first. Select by shape, color, object or subject; mask and remove backgrounds; correct tone and color with Levels, Curves, Exposure, Hue/Saturation, Color Balance, Black & White and Gradient Map adjustment layers or Lightroom/Camera Raw profiles; retouch with heal, clone, blur and content-aware fill; apply filters; crop, trim, straighten and resize. Use whenever the user wants a photo or image fixed, cleaned up, cut out, recolored, brightened, graded, given a Lightroom look, retouched, blurred, straightened, cropped or resized in Compositor, or asks for a background removed or a product isolated, even if they don't name the tool.
---

# Compositor image editing

Photo work goes wrong in two ways: an edit that can't be taken back, and an edit that
looks fine at thumbnail size but not at full size. Prefer changes that stay adjustable
(adjustment layers, masks), keep the original pixels available, and check results at
100% with `render_region` as well as the whole image. Read the **compositor** skill first
for selectors, coordinates and the render-and-verify loop.

## Non-destructive first

| Goal | Adjustable way | Pixel-changing way (when it's right) |
|---|---|---|
| tone and color | `add_adjustment_layer` (Levels, Curves, Exposure, Hue/Saturation, Color Balance, Black & White, Gradient Map, Invert, Profile), `clip_to_below: true` to affect one layer | `apply_levels`, `apply_hue_saturation`, `apply_filter` with `curves`, `exposure`… |
| hide part of a layer | a layer mask (`add_layer_mask`, paint with `target: "mask"`) | `clear_selection`, `stroke_path` with `mode: "erase"` |
| remove a background | `remove_background` (it makes a mask; nothing is erased) | `apply_layer_mask` afterwards, when a flat cutout is required |
| blur, grain, noise | a blur, grain or noise adjustment layer | `apply_filter` |
| retouch spots and objects | clone onto a new empty layer above the photo (`stroke_path` `mode: "clone"` with `clone.sample_all_layers: true`) | `stroke_path` heal or clone on the photo itself, `content_aware_fill` (duplicate the layer first) |

Pixel-changing edits are right when the result must be flat (a deliverable that has to
open anywhere), or when there is no adjustable equivalent (retouching). Before one,
`duplicate_layer` the original and hide the copy (`set_layer_visibility`), or work on a
`layer_via_copy`, so the untouched pixels stay in the document.

## Workflow

1. **Look first**: `get_document`, then `render_document` and `render_region` at full
   size on the areas you'll change. Measure what "too dark" or "too blue" means with
   `sample_colors` on a few points (a white shirt, skin, sky, a gray card): numbers make a
   correction objective and let you check it afterwards.
2. **Choose the target**: address the photo layer by id. Pixel tools refuse folders and
   adjustment layers (`has_pixels`) and a smart object's own pixels (`not_smart_object`:
   change its contents instead); text and shape layers become plain pixels when painted
   or filtered, so edit the photo, not its frame.
3. **Limit the area** when needed with a selection (tools act inside it) or a mask.
4. **Apply** in the order a photographer would: crop and straighten, exposure and levels,
   white balance and color, local fixes and retouching, then the look (profile, grade),
   then output resizing. Compositor has no sharpening filter; if one is asked for, say so
   rather than faking it with contrast.
5. **Verify** each step: `render_region` at 100% where you worked, `sample_colors` on the
   same points as step 1, `render_document` for the whole. Undo (`undo`) and try smaller
   values rather than stacking corrections.
6. **Clean up**: `select_none`, name new layers by purpose ("Levels: brighten", "Retouch"),
   and report every change and which ones stay adjustable.
7. **Keep the adjustable version on disk.** Adjustment layers, masks and a kept original
   live only in the open document: an exported PNG or JPEG is flat, and the tab can be
   closed or reverted. Whenever the user wants to tweak, dial back or revisit the edit
   ("keep it adjustable", "so I can change it later", "keep the original"), also
   `save_document_as` a `.comp` (or a `.psd` for Photoshop users) next to the export, and
   give its absolute path along with the export's.

## Selections

A selection limits painting, fills, filters and pixel adjustments to its area. Build it
with `select_rect`, `select_ellipse`, `select_polygon` (points as `{x, y}`),
`select_by_color` (the Magic Wand: `tolerance`, `contiguous`, `sample_all_layers`),
`select_object` (Vision, from a point on the object), `select_subject` (Vision, the main
subject) or `load_layer_selection` (a layer's pixels or its mask), combined with `mode`
`replace`, `add` or `subtract`. Refine with `modify_selection` (`expand`, `contract`,
`feather`) and `transform_selection`; inspect with `get_selection`; end with
`select_none`, because a forgotten selection silently limits every later edit.
[Selections and masks](references/selections-and-masks.md) has the details and recipes.

## Masks and cutouts

- `add_layer_mask` with `kind` `reveal_all`, `hide_all`, `from_selection` or
  `hide_selection`; paint it with `stroke_path`, `fill_selection`, `draw_gradient` or
  `invert_pixels` using `target: "mask"` (black hides, white reveals, grays blend).
- `remove_background` masks out the background Vision finds: `quality: "basic"` is Vision's
  mask; `"advanced"` refines it (`refine_edges`, `matte_contrast`, `shift_edge`). Check the
  edge at 100% on hair and fine detail with `render_region`, and render over a contrasting
  background (`render_layer` with `background: "checkerboard"` or a temporary solid layer
  below) to see halos.
- Keep the mask until the end; `apply_layer_mask` bakes it into transparency only when a
  flat cutout is the deliverable.

## Tone, color and looks

Adjustment layers apply to everything below them in their folder, or only to the layer
below with `clip_to_below: true`. `add_adjustment_layer` takes `kind` and `settings`;
`set_adjustment` changes only what you pass. Shorthand keys per kind (Levels `black`,
`gamma`, `white`; Hue/Saturation `hue`, `saturation`, `lightness`; Curves `points`…) and
Lightroom-style profiles (`list_profiles`, then a `profile` adjustment layer with an
`amount`) are in [Adjustments and profiles](references/adjustments-and-profiles.md).

## Retouching and filters

`stroke_path` paints one stroke through `points` with a `brush` (`diameter`, `hardness`,
`opacity`, `color`) in a `mode`: `paint`, `erase`, `heal` (spot healing, `heal_mode`),
`clone` (from `clone.source`), `blur`, `smudge` or `liquify`. `content_aware_fill` fills
a selection from its surroundings. `apply_filter` runs blurs, noise, grain, lens
correction, vignette, bloom, tonal contrast, the Camera Raw Filter's basic sliders and the
color filters on a layer's pixels. Recipes and settings:
[Retouching and filters](references/retouching-and-filters.md).

## Crop, straighten and resize

`crop` to a rectangle (layers keep their pixels outside it), `trim_canvas` to the visible
content plus `padding`, `rotate_layer` to straighten a photo, `resize_image` to scale
everything (`width` and/or `height`, or `percent`; `sampling` `high` for photos, `nearest`
for pixel art), `resize_canvas` to add room (`anchor`, optional `fill`), `flip_canvas` to
mirror. Whole-document tools refuse while an edit is pending in the app. Details and
upscaling limits: [Crop, straighten and resize](references/crop-and-resize.md).

## References

- [Selections and masks](references/selections-and-masks.md)
- [Adjustments and profiles](references/adjustments-and-profiles.md)
- [Retouching and filters](references/retouching-and-filters.md)
- [Crop, straighten and resize](references/crop-and-resize.md)
