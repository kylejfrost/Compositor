#!/usr/bin/env python3
"""Render the probe through every usable installed Look profile with the Python reference.

    uv run --with numpy --with pillow python scripts/profiles/conformance.py --out DIR \
        [--library "/Library/Application Support/Adobe/CameraRaw/Settings"]

Writes DIR/<sha256 of the profile file>__<percent>.png for 100 %, and for 50 % when the profile supports Amount,
plus DIR/index.json = [{"digest", "path", "name", "percent"}]. ProfileConformanceTests compares Compositor's
renderer with these (TEST_RUNNER_COMPOSITOR_PROFILE_REFERENCE=DIR).

The outputs are rendered from Adobe's tables: they are Adobe-derived and must never be committed, so DIR has to be
outside the repository.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "reference"))

import lrapply as A  # noqa: E402
import lrprofile as L  # noqa: E402

REPO = HERE.parents[1]
PROBE = REPO / "CompositorTests" / "Fixtures" / "Profiles" / "probe.png"
LIBRARY = "/Library/Application Support/Adobe/CameraRaw/Settings"


def usable(props: dict) -> bool:
    """A Look profile Compositor can apply to rendered images (the same rules as AdobeProfile.usability)."""
    def get(key):
        return props.get("crs:" + key)

    if get("CameraModelRestriction"):
        return False
    if not A.is_true(get("SupportsOutputReferred")):
        return False
    for key in ("LookTable", "RGBTable"):
        fingerprint = get(key)
        if isinstance(fingerprint, str) and fingerprint and "crs:Table_" + fingerprint not in props:
            return False
    if A.is_true(get("RequiresRGBTables")):
        return False
    return all(get(key) in (None, "0") for key in ("RGBTables", "ProfileGainTableMap", "ProfileToneCurve"))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True, type=Path, help="output folder, outside the repository")
    parser.add_argument("--library", default=LIBRARY, help="the installed profile library")
    args = parser.parse_args()
    out = args.out.resolve()
    if out == REPO or REPO in out.parents:
        parser.error("--out must be outside the repository: the renders are Adobe-derived and never committed")
    out.mkdir(parents=True, exist_ok=True)

    with Image.open(PROBE) as image:
        probe = np.asarray(image.convert("RGB"))
    index = []
    skipped = failed = 0
    for path in sorted(Path(args.library).rglob("*")):
        if path.suffix.lower() != ".xmp" or not path.is_file():
            continue
        data = path.read_bytes()
        try:
            props = L.parse_xmp(str(path))
        except Exception:
            failed += 1
            continue
        if props.get("crs:PresetType") != "Look":
            continue
        if not usable(props):
            skipped += 1
            continue
        try:
            profile = L.load_profile(str(path))
        except Exception:
            failed += 1
            continue
        digest = hashlib.sha256(data).hexdigest()
        percents = [100, 50] if A.is_true(profile.get("SupportsAmount")) else [100]
        for percent in percents:
            _, u8, _ = A.render_srgb8(probe, profile, percent / 100)
            Image.fromarray(u8).save(out / f"{digest}__{percent}.png")
            index.append({"digest": digest, "path": str(path), "name": profile.name(), "percent": percent})
    (out / "index.json").write_text(json.dumps(index, indent=1) + "\n")
    profiles = len({entry["digest"] for entry in index})
    print(f"{profiles} usable profiles, {len(index)} renders; {skipped} not usable, {failed} unreadable")
    return 0


if __name__ == "__main__":
    sys.exit(main())
