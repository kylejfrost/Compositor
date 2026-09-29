# Adjustments and profiles

## Contents

- [Adjustment layers](#adjustment-layers)
- [Settings by kind](#settings-by-kind)
- [Patching full settings](#patching-full-settings)
- [Destructive equivalents](#destructive-equivalents)
- [Lightroom and Camera Raw profiles](#lightroom-and-camera-raw-profiles)
- [Recipes](#recipes)
- [Adjustments in PSD files](#adjustments-in-psd-files)

## Adjustment layers

`add_adjustment_layer` with `kind`, optional `settings`, `name` and `clip_to_below` adds
the layer above the active layer (inside it when it's a folder), configures it and names
it as one undo step; nothing is added when any part fails, and no panel opens. It returns
the new layer's id and its full settings.

- It affects every layer below it in the same folder, down to the folder's bottom (or the
  whole document at the top level). `clip_to_below: true` clips it to the layer directly
  below, so it adjusts only that layer. Put a photo and its adjustments in a folder to
  keep them from touching anything else.
- `set_adjustment` with `layer` and `settings` changes only what you pass (one undo step,
  none when nothing changes). An unknown key or a value out of range fails naming the
  field.
- Kinds: `hue_saturation`, `levels`, `curves`, `exposure`, `gradient_map`, `grain`,
  `gaussian_blur`, `motion_blur`, `add_noise`, `invert`, `black_white`, `color_balance`,
  and `profile`.
- Opacity (`set_layer_opacity`), blend mode (`set_layer_blend_mode`, e.g. `Luminosity` to
  change tone without shifting color) and a mask all apply to adjustment layers.
- Photoshop adjustment and fill layers Compositor can't apply arrive as `placeholder`
  layers and can't be changed.

## Settings by kind

The shorthand keys `settings` accepts (ranges enforced):

| Kind | Keys |
|---|---|
| `levels` | `channel` (`rgb`, `red`, `green`, `blue`; default `rgb`), `black` 0–254, `gamma` 0.1–9.99, `white` (above black, ≤ 255), `output_black`, `output_white` 0–255 |
| `curves` | `channel`, `points`: 2–32 `[x, y]` pairs in 0–255, from x 0 to x 255, x increasing |
| `hue_saturation` | `hue` −180…180 (0–360 with `colorize`), `saturation` and `lightness` −100…100 for the Master range, `colorize` |
| `exposure` | `exposure` −20…20 (stops), `offset` −0.5…0.5, `gamma` 0.01–9.99 |
| `color_balance` | `shadow_`, `mid_`, `highlight_` + `cyan_red`, `magenta_green`, `yellow_blue` (−100…100), `preserve_luminosity` |
| `black_white` | `reds`, `yellows`, `greens`, `cyans`, `blues`, `magentas` (−200…300), `tint`, `tint_hue` 0–360, `tint_saturation` 0–100 |
| `gradient_map` | `shadows`, `highlights` (colors), `reversed` |
| `grain` | `amount` 0–100, `size` 0.5–20, `roughness` 0–100 |
| `gaussian_blur` | `radius` 0.1–250 |
| `motion_blur` | `angle` −90…90, `distance` 1–2,000 |
| `add_noise` | `amount` 0.1–400, `gaussian`, `monochromatic` |
| `invert` | none |
| `profile` | `profile` (an id from `list_profiles`, an Adobe UUID, `"Group/Name"` or a name; `null` for none), `amount` 0–200 (whole numbers; always 100 for a profile without an Amount) |

## Patching full settings

The settings a tool returns (and `get_layer` reports under `adjustment`) can be sent back
with changes: objects merge field by field, arrays replace, `null` removes an optional
member. Examples:

- Shift only the reds: `{"hsv_settings": {"adjustments": {"reds": {"hue": 20}}}}`.
- Levels per channel: `levels.ranges` lists the `rgb`, `red`, `green` and `blue` channels
  in that order; `curves.channels` likewise.
- Give either a shorthand key or the full field it maps to, not both (that fails as a
  conflict).

## Destructive equivalents

When the pixels themselves must change (a flat deliverable, a layer that will be
painted), the same settings apply directly, inside the selection if there is one, as one
undo step each:

- `apply_levels` with `settings` (one channel's range, or `ranges` for all four) and
  optional `auto` (`contrast`, `color`, `neutral`) that sets levels from the histogram
  first, as the panel's Auto buttons do.
- `apply_hue_saturation` with `settings`: `hue`, `saturation`, `lightness` for a `range`
  (`master`, `reds`, `yellows`, `greens`, `cyans`, `blues`, `magentas`), `colorize`, or
  `adjustments` for several ranges at once.
- `apply_filter` with `kind` (`curves`, `exposure`, `gradient_map`, `black_white`,
  `color_balance`, `gaussian_blur`, `motion_blur`, `add_noise`, `grain`,
  `lens_correction`, `vignette`, `bloom_glow`, `tonal_contrast`, `camera_raw_filter`) and
  `settings` using the keys above (the last five take their panel's sliders, listed in
  [Retouching and filters](retouching-and-filters.md)). Unset keys are the filter's
  defaults, never the app's last-used values.

Settings that change nothing record nothing (`recorded: false`).

## Lightroom and Camera Raw profiles

A Profile adjustment layer applies a Lightroom / Camera Raw creative profile (Adobe's
Artistic, B&W, Modern, Vintage and Film-Inspired sets, or imported `.xmp` profiles)
without Lightroom installed.

1. `list_profiles` with a `query` (name, group or file name; case and accents ignored) or a
   `group`; page with `limit` (1–500, default 100) and `offset`. Each entry has `id`,
   `uuid`, `name`, `group`, `source`, `supports_amount`, `monochrome`, `fidelity`
   (`exact`, or `approximate` with the `ignored_settings` Compositor doesn't reproduce),
   `usable`, and a `reason` when it can't apply. `refresh: true` rescans the profile
   folders; `include_unusable: true` also lists camera-matching and RAW-only profiles, which
   only apply to raw files.
2. `import_profile` with a `.xmp` file or a folder (searched recursively, up to 1,000
   files per call) copies Look-type profiles into Compositor's library. Develop presets,
   camera-matching and RAW-only profiles are skipped with a reason (`skipped`,
   `skipped_count`); importing the same file again changes nothing.
3. `add_adjustment_layer` with `kind: "profile"` and `settings: {"profile": "<id or
   Group/Name>", "amount": 100}`, clipped to the photo when other layers sit below it.
4. Tune `amount` with `set_adjustment` (0–200, when `supports_amount`), check with
   `render_region` on skin and highlights, and report the profile's `fidelity`: an
   `approximate` profile carries develop settings Compositor doesn't reproduce.

## Recipes

- **Underexposed photo**: `sample_colors` on the brightest real highlight and the deepest
  shadow; a `levels` layer with `white` at the highlight's brightest channel × 255 (minus a
  little headroom), `black` at the shadow's, `gamma` 1.1–1.3; recheck the samples.
- **More contrast**: a `curves` layer with a gentle S: `points` `[[0,0],[64,54],[192,202],[255,255]]`.
- **Color cast**: sample something that should be neutral (white paper, gray pavement);
  where red, green and blue differ, correct with a `color_balance` layer (move midtones
  away from the excess) or `curves` per channel until the sample is neutral; or
  `apply_levels` with `auto: "neutral"` on a copy and compare.
- **Warmer, cooler**: `color_balance` with `mid_yellow_blue` −10 (warmer) or +10 (cooler)
  and a little `mid_cyan_red`.
- **Mute one color**: `hue_saturation` with `hsv_settings.adjustments.<range>.saturation`
  −40.
- **Black and white with a tint**: `black_white` with `tint: true`, `tint_hue` 35,
  `tint_saturation` 20 for a warm sepia.
- **Duotone**: `gradient_map` with `shadows` and `highlights` in the brand colors, blend
  mode `Normal` at 100% or `Color` at lower opacity.

## Adjustments in PSD files

A saved PSD writes back Photoshop's own adjustment layers unchanged when untouched. New or
edited Levels, Curves, Hue/Saturation, Exposure, Color Balance, Black & White, Invert and
Gradient Map layers are written as Photoshop adjustments (as the PSD writer supports
them); blur, noise, grain and Profile layers have no Photoshop equivalent and are either
refused (guard `lossy`) or, with `allow_lossy`, written as a pixel layer of their result on
the layers below, with a warning. For a PSD deliverable, flatten such looks into the photo
deliberately (`apply_filter`, or a merge) or deliver a `.comp` too, and say which.
