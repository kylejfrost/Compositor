# Profiles

Compositor can apply Lightroom and Camera Raw creative profiles as an adjustment layer. This document covers using them and how they work inside Compositor.

## What a profile is

A profile is an `.xmp` file with `crs:PresetType="Look"`. It carries a LookTable, an RGBTable or both, and sometimes point curves, a grayscale flag and other develop settings.

It is not:

- a develop preset (an `.xmp` with `PresetType="Normal"`), which records slider settings rather than a look;
- a camera profile (`.dcp`), which describes a camera's sensor;
- the Camera Raw Filter (Filter › Camera Raw Filter…, `apply_filter` `camera_raw_filter`), Compositor's own set of develop sliders that it applies to a layer's pixels once. A Profile adjustment layer stays live and applies an Adobe profile's tables. In the code the filter's settings are `CameraRawSettings` and a profile's develop values `ProfileDevelopSettings`.

## Where Compositor finds profiles

Compositor lists every profile in three folders, including their subfolders:

- `/Library/Application Support/Adobe/CameraRaw/Settings`, where Lightroom and Camera Raw install Adobe's profiles;
- `~/Library/Application Support/Adobe/CameraRaw/Settings`, where they keep the profiles you add to them;
- `~/Library/Application Support/Compositor/Profiles`, which holds copies of the profiles you import into Compositor.

**Import Profiles…** in the Profile panel accepts `.xmp` files and folders of them. Compositor checks each file and copies the ones it can apply into its own folder, named by their SHA-256. Importing the same file again does nothing. When one profile is in several folders, the Adobe copy is listed.

## Using a profile

1. Choose **Layer › New Adjustment Layer › Profile…**. The new layer starts as None, which changes nothing, and the Profile panel opens.
2. Click a card to preview that profile on the image. Each card shows the profile applied to the layers below.
3. Set **Amount**, from 0 to 200 %. 100 % is the profile as designed. A profile without an Amount always applies at 100 %, and the slider is disabled.
4. Click **OK** to keep the profile or **Cancel** to go back to what the layer had.

On OK, the layer takes the profile's name, unless you have renamed it yourself. The change is one undo step. Double-click the layer to reopen the panel.

Like any adjustment layer, a Profile layer changes everything below it. To limit it to one layer, put it just above that layer and choose **Layer › Create Clipping Mask**.

## Which profiles apply

Compositor applies profiles to rendered images, not to raw files. It lists a profile when:

- it is output-referred (`SupportsOutputReferred`);
- it has no camera restriction;
- every table it names is in the file.

Camera-matching profiles and RAW-only profiles need a camera's raw data. They are hidden, and the panel shows how many there are. **Show profiles Compositor can't apply** lists them as disabled cards, each with the reason in its tooltip.

## Fidelity

A profile is **exact** when Compositor ignores none of it: it applies every table, point curve and grayscale conversion the profile has. That isn't yet a verified match with Lightroom. Many creative profiles, among them every exact one in Adobe's current library, share a look table with a fixed amount (Adobe Color's base look). Compositor applies that table in full, and whether Lightroom and Camera Raw apply it in full to a rendered image, rather than scaling or skipping it as they may for non-raw files, hasn't been checked against them yet; it changes some profiles' results by up to 56 levels. Until it is, treat an exact profile's look as very close, not identical.

Some profiles also carry Adobe develop settings, such as Clarity, Contrast, HSL, split toning and vignettes. Compositor does not apply these, so the profile's look is only **approximate**. Those cards have an **Approximate** badge, and the panel's **Approximate** button lists what isn't applied.

## Projects

A project embeds each profile file it uses, byte for byte, as `profiles/<sha256>.xmp` inside the `.comp` package. It therefore opens and renders the same on a Mac without the profile. [project-format.md](project-format.md) describes the format.

This means a `.comp` you share contains copies of the Adobe or third-party profile files it uses.

## Saving as PSD

Photoshop has no equivalent of a Profile layer, so Profile layers are Compositor-only. Saving a document that has one as a Photoshop file stops and names the layer. The layer is rasterized into the PSD only when you allow lossy export.

## Developer notes

### Engine

- **Parsing.** `AdobeProfileParser` reads the XMP. `AdobeTableCodec` decodes the tables' text encoding, zlib block and payloads.
- **Rendering.** `ProfileRenderer` applies a profile to premultiplied 8-bit RGBA through the C kernel in `Compositor/Rendering/ProfilePixels.c`.
  - Images up to `1 << 20` pixels are evaluated exactly, pixel by pixel.
  - Larger images use a baked 256³ lookup table, 48 MiB, which gives byte-identical results. Exports and other renders off the main thread bake the table when it's missing.
  - The canvas never waits for a table. When one is missing it evaluates the drawn area pixel by pixel (the same bytes) and bakes the table on another thread for the draws after it, whoever added the layer (the panel or an agent).
  - `ProfileLUTCache` keeps the four most recent tables. A background bake never evicts a table drawn with in the last second, so more visible profile and Amount pairs than that don't rebake one another on every redraw; the ones that don't fit are evaluated directly.
  - The Profile panel bakes the table off the main thread before previewing whenever the canvas draws more than `1 << 20` points of the document, whatever the document's own size (a small document zoomed in counts).
- **Reference.** The table math follows the Adobe DNG SDK 1.7.1 reference implementation. The composition of the stages is Compositor's own "reference v1".
- **Library and registry.**
  - `ProfileLibrary` scans the folders, deduplicates, imports and loads profiles.
  - `ProfileRegistry` holds every profile a document uses, for the life of the process.
  - Browsing never registers a profile. Choosing one, loading a project and MCP do.

### Scripts

`scripts/profiles/` holds:

- the Python reference implementation (`reference/lrprofile.py` and `reference/lrapply.py`);
- `make_fixtures.py`, which generates the synthetic fixtures and golden images in `CompositorTests/Fixtures/Profiles/`;
- `conformance.py`, which renders the installed profiles with the reference for the conformance test.

Its [README](../scripts/profiles/README.md) has the commands.

### Adobe's files stay out of the repository

**Never commit Adobe's profile files, or images rendered with them, or anything derived from their tables.** Adobe owns them. The committed fixtures are synthetic: their tables come from formulas in `make_fixtures.py` or from `ProfileFixture` in the tests.

Tests use `ProfileTestSupport.locations`, a temporary library holding the synthetic fixtures, and never read the installed folders.

### Tests that run on request

These tests are off by default. The corpus and conformance tests read Adobe's library, so they only run where Lightroom or Camera Raw is installed, and anything they write stays outside the repository.

- **Corpus.** `ProfileCorpusTests` parses every installed profile. `ProfileLibraryTests.installedLibraryIndexes` indexes the real folders and records the counts:

  ```sh
  TEST_RUNNER_COMPOSITOR_ADOBE_LIBRARY=1 xcodebuild test -project Compositor.xcodeproj -scheme Compositor \
      -destination platform=macOS -only-testing:CompositorTests/ProfileCorpusTests \
      -only-testing:CompositorTests/ProfileLibraryTests
  ```

- **Conformance.** `ProfileConformanceTests` compares Compositor with the Python reference on every usable installed profile. The reference renders are Adobe-derived, so write them outside the repository:

  ```sh
  uv run --with numpy --with pillow python scripts/profiles/conformance.py --out /tmp/profile-conformance
  TEST_RUNNER_COMPOSITOR_PROFILE_REFERENCE=/tmp/profile-conformance xcodebuild test -project Compositor.xcodeproj \
      -scheme Compositor -destination platform=macOS -only-testing:CompositorTests/ProfileConformanceTests
  ```

- **Performance.** `ProfilePerformanceTests` times a bake and the two apply paths on synthetic fixtures when `TEST_RUNNER_PROFILE_BENCHMARK=1`.
