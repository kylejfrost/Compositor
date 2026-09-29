# Retouching and filters

## Contents

- [Brush strokes: stroke_path](#brush-strokes-stroke_path)
- [Removing blemishes and objects](#removing-blemishes-and-objects)
- [Other pixel tools](#other-pixel-tools)
- [Filters: apply_filter](#filters-apply_filter)
- [Checking retouching](#checking-retouching)

## Brush strokes: stroke_path

`stroke_path` paints one stroke through `points` (1–10,000 `{x, y}` in document pixels;
one point paints a single dab) on a layer's pixels, or its mask with `target: "mask"`.
It uses this call's `brush`, not the app's brush settings, with no smoothing: segments
between points are straight, so give curves enough points (every 5–10 px). Inside a
selection it paints only there. One undo step, named after the tool.

| `brush` field | Range | Default |
|---|---|---|
| `diameter` | 1–2,000 px | 40 |
| `hardness` | 0 (soft, fading from the center) – 1 (hard edge) | 1 |
| `opacity` | 0.01–1: the most the stroke covers, even where it overlaps itself | 1 |
| `color` | for `mode: "paint"`; default the foreground color (on a mask, black) | |

| `mode` | Does |
|---|---|
| `paint` | lays down `brush.color` |
| `erase` | clears pixels to transparency |
| `heal` | Spot Healing: rebuilds the painted area from nearby texture; `heal_mode` `content_aware` (default), `create_texture` or `proximity_match` |
| `clone` | copies from `clone.source` (where the first point copies from), keeping that offset for the whole stroke; `clone.sample_all_layers` copies what is visible rather than the layer alone; `clone.aligned` as Photoshop's Aligned |
| `blur` | softens what it passes over |
| `smudge` | drags colors along the stroke |
| `liquify` | pushes pixels along the stroke |

Masks take `paint` and `blur` only. A hidden layer (or one in a hidden folder) refuses
painting (guard `can_paint`); show it first.

## Removing blemishes and objects

- **Small spots** (dust, blemishes): `stroke_path` with `mode: "heal"`, a single point or a
  short stroke over the spot, `diameter` about 1.5× the spot, `hardness` 0.5. Work on a
  duplicate of the photo layer.
- **Lines and edges** (a wire, a seam): `mode: "clone"` along the line with
  `clone.source` a parallel clean strip; clone onto an empty layer above the photo with
  `clone.sample_all_layers: true` to keep it adjustable.
- **Larger objects**: select the object with a margin (`select_polygon` or
  `select_object`, then `modify_selection` expand 4–10 px), `content_aware_fill` on the
  photo layer (it needs a selection, and fails when too little of the layer is left to
  copy from), then `select_none`. Check for repeated patterns and fix them with a clone
  stroke.
- **Skin softening**: duplicate the photo, `apply_filter` `gaussian_blur` (radius 4–10)
  on the copy, add a `hide_all` mask to the copy and paint white (low `opacity`, soft
  brush) where to soften; keep eyes, lips and hair edges sharp.

## Other pixel tools

| Tool | Does |
|---|---|
| `fill_selection` | fills the selection (or the whole layer) with `with`: `color` (+ `color`), `foreground` or `background` |
| `clear_selection` | clears the selected pixels to transparency; needs a selection |
| `invert_pixels` | inverts colors (keeping transparency), inside the selection if any |
| `draw_gradient` | linear or radial gradient from `start` to `end`, `colors` `{from, to}` (each a color or `"transparent"`) or a palette `style` |
| `set_layer_pixels` | replaces a layer's pixels with an image file (`placement` `keep_bounds`, `keep_origin`, `natural`) |
| `paste_image_into_layer` | draws an image file into a layer at `x`, `y`, `mode` `over` or `replace` |
| `get_layer_pixels` | a layer's own pixels (or mask) as a PNG, `save_to` for the full-size file |
| `copy_pixels` / `paste_pixels` | Compositor's clipboard (and the system pasteboard) |
| `layer_via_copy` | the selected pixels as a new layer, in place |

## Filters: apply_filter

`apply_filter` runs a filter on a layer's pixels (inside the selection if any) as one
undo step, with `settings` using the same keys as the adjustment layer of that kind, or,
for a filter without one, its panel's sliders:

| `kind` | `settings` |
|---|---|
| `gaussian_blur` | `radius` 0.1–250 |
| `motion_blur` | `angle` −90…90, `distance` 1–2,000 |
| `add_noise` | `amount` 0.1–400, `gaussian`, `monochromatic` |
| `grain` | `amount` 0–100, `size` 0.5–20, `roughness` 0–100 |
| `lens_correction` | `distortion` −100…100 (positive straightens barrel distortion) |
| `vignette` | `amount`, `midpoint`, `feather`, `highlights` 0–100, `roundness` −100…100, `color`; on an empty layer it frames the whole canvas |
| `bloom_glow` | `amount` 0–100, `radius` 1–150 |
| `tonal_contrast` | `amount` 0–100, `radius` 1–100, `shadows`, `midtones`, `highlights` −100…100 |
| `camera_raw_filter` | `exposure` −5…5; `temperature`, `tint`, `contrast`, `highlights`, `shadows`, `whites`, `blacks`, `texture`, `clarity`, `dehaze`, `vibrance`, `saturation` −100…100 (curves, mixer, grading, detail, optics and geometry are only in the app) |
| `curves`, `exposure`, `gradient_map`, `black_white`, `color_balance` | as in [Adjustments and profiles](adjustments-and-profiles.md) |

Unset settings are the filter's defaults (a gradient map runs from the foreground to the
background color). A blur can spread the layer past its edges. Filters that change
nothing (Lens Correction without `distortion`, Exposure at defaults, Grain with amount 0)
record nothing. For effects the user may want to tune later, use the adjustment layer of
the same kind instead.

There is no sharpen, unsharp mask, noise reduction or high-pass filter; say so if one is
asked for.

## Checking retouching

- `render_region` at 100% (and 200% by rendering a smaller region with the same
  `max_size`) over every retouched spot: look for smears, repeated texture, soft patches.
- Compare with the original: hide the retouch layer (or the duplicate) and render the same
  region again, or render the untouched duplicate with `render_layer`.
- `sample_colors` across a healed area and its surroundings: values should blend, not
  jump.
