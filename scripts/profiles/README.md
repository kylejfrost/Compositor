# Profile reference scripts

Compositor applies Lightroom and Camera Raw profiles (`crs:PresetType="Look"` XMP files) with a C kernel in
`Compositor/Rendering/ProfilePixels.c`. These scripts hold the Python reference it is tested against.

**Never commit Adobe's profile files, or anything rendered from or derived from their tables.** Adobe owns them.
The committed fixtures are synthetic: their tables come from formulas in `make_fixtures.py`.

## What is here

- `reference/lrprofile.py` decodes profile XMP files: the 85-digit table text, the zlib block, and the LookTable
  and RGBTable payloads. It can also serialize tables.
- `reference/lrapply.py` applies a profile to 8-bit sRGB pixels in float64 with numpy: colour spaces, transfer
  functions, the LookTable and RGBTable stages, point curves, amounts, and the whole pipeline (`render_srgb8`).
  The table math follows the Adobe DNG SDK 1.7.1; the composition of the stages is Compositor's "reference v1".
- `make_fixtures.py` writes the synthetic fixtures into `CompositorTests/Fixtures/Profiles/`:
  11 `profile-*.xmp`, `probe.png`, the `golden-*.png` renders listed in `goldens.json`, and `kernels.json` (stage
  outputs for 200 linear ProPhoto inputs). Its output is deterministic. With `--check` it regenerates everything
  into a temporary folder and compares pixels, parsed tables and properties, and kernel values (to 1e-12), exiting
  1 on any drift. Compressed table text may legitimately differ between zlib versions, so it is not compared.
- `conformance.py` renders `probe.png` through every usable Look profile installed in the Camera Raw library, at
  100 % and also at 50 % when the profile supports Amount. It writes `<sha256>__<percent>.png` and `index.json`
  into a folder that must be outside the repository, because those renders are Adobe-derived.

## Commands

Run from the repository root. Use uv; never install into the system Python.

```sh
# Regenerate the committed fixtures after changing the reference or the fixture definitions
uv run --with numpy --with pillow python scripts/profiles/make_fixtures.py

# Check that the committed fixtures match the generator
uv run --with numpy --with pillow python scripts/profiles/make_fixtures.py --check
uv run --with numpy --with pillow python -m unittest discover -s scripts/tests -p 'test_profile_fixtures.py'

# Compare Compositor with the reference on the installed profiles (the output folder is outside the repo)
uv run --with numpy --with pillow python scripts/profiles/conformance.py --out /tmp/profile-conformance
TEST_RUNNER_COMPOSITOR_PROFILE_REFERENCE=/tmp/profile-conformance xcodebuild test -project Compositor.xcodeproj \
    -scheme Compositor -destination platform=macOS -only-testing:CompositorTests/ProfileConformanceTests
```

Changing the renderer's default behaviour (for example `ProfileRenderOptions.fixedLookTables`) means changing
`lrapply.py` to match, regenerating the fixtures and committing the new goldens together with the Swift change.
