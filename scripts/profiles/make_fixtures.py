#!/usr/bin/env python3
"""Generate the synthetic profile fixtures and golden images the Swift profile tests use.

Everything here is synthetic: the tables are made from formulas, never from Adobe's profiles.

    uv run --with numpy --with pillow python scripts/profiles/make_fixtures.py          # write
    uv run --with numpy --with pillow python scripts/profiles/make_fixtures.py --check  # verify, exit 1 on drift

Output (flat, unique names): CompositorTests/Fixtures/Profiles/
  profile-*.xmp   11 Look profiles with embedded tables
  probe.png       289x22 sRGB probe (17^3 lattice, hue sweeps, gray ramp, ColorChecker)
  golden-*.png    the probe rendered by reference/lrapply.py, one per case in goldens.json
  goldens.json    [{"golden", "profile", "percent", "fixedLook"}]
  kernels.json    look and RGB table stage outputs for 200 linear ProPhoto inputs
"""
from __future__ import annotations

import argparse
import colorsys
import hashlib
import json
import math
import struct
import sys
import tempfile
import zlib
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "reference"))

import lrapply as A  # noqa: E402
import lrprofile as L  # noqa: E402

REPO = HERE.parents[1]
FIXTURES = REPO / "CompositorTests" / "Fixtures" / "Profiles"

# The 24 ColorChecker patches in sRGB, in chart order.
COLORCHECKER = [
    (115, 82, 68), (194, 150, 130), (98, 122, 157), (87, 108, 67), (133, 128, 177), (103, 189, 170),
    (214, 126, 44), (80, 91, 166), (193, 90, 99), (94, 60, 108), (157, 188, 64), (224, 163, 46),
    (56, 61, 150), (70, 148, 73), (175, 54, 60), (231, 199, 31), (187, 86, 149), (8, 133, 161),
    (243, 243, 242), (200, 200, 200), (160, 160, 160), (122, 122, 121), (85, 85, 85), (52, 52, 52),
]

# RGBTable enums (dng_rgb_table).
SRGB, ADOBE_RGB, PROPHOTO, DISPLAY_P3, REC2020 = 0, 1, 2, 3, 4
LINEAR, SRGB_GAMMA, GAMMA_18, GAMMA_22, REC709 = 0, 1, 2, 3, 4
CLIP, EXTEND = 0, 1


# ---------------------------------------------------------------------------
# Tables
# ---------------------------------------------------------------------------


def look_table(hue, sat, val, encoding, amount, entry):
    """A LookTable from entry(v, h, s) -> (hue shift in degrees, saturation scale, value scale)."""
    deltas = []
    for v in range(val):
        for h in range(hue):
            for s in range(sat):
                deltas.append(tuple(float(c) for c in entry(v, h, s)))
    lo, hi = amount
    return L.LookTable(version=1 if lo == hi == 1.0 else 2, hue_divisions=hue, sat_divisions=sat, val_divisions=val,
                       deltas=deltas, encoding=encoding, min_amount=lo, max_amount=hi, flags=None, monochrome=False)


def rgb_table(divisions, primaries, gamma, gamut, amount, f, dimensions=3, flags=None):
    """An RGBTable whose node (i, j, k) sits at the SDK identity values nop/65535 and holds f clamped and quantized."""
    nop = L.nop_values(divisions)

    def sample(r, g, b):
        return tuple(round(min(max(c, 0.0), 1.0) * 65535) for c in f(r, g, b))

    samples = []
    if dimensions == 3:
        for ri in range(divisions):
            for gi in range(divisions):
                for bi in range(divisions):
                    samples.append(sample(nop[ri] / 65535, nop[gi] / 65535, nop[bi] / 65535))
    else:
        for i in range(divisions):
            x = nop[i] / 65535
            samples.append(sample(x, x, x))
    lo, hi = amount
    return L.RGBTable(version=1, dimensions=dimensions, divisions=divisions, samples=samples, primaries=primaries,
                      gamma=gamma, gamut=gamut, min_amount=lo, max_amount=hi, flags=flags, monochrome=False)


def warm_adobe_table():
    return rgb_table(9, ADOBE_RGB, GAMMA_22, CLIP, (0.0, 2.0), lambda r, g, b: (
        r + 0.08 * r * (1 - r) + 0.03 * (1 - r),
        g + 0.05 * math.sin(math.pi * r) * (b - 0.5),
        0.9 * b + 0.02 * g))


@dataclass
class Fixture:
    stem: str
    name: str
    look: L.LookTable | None = None
    rgb: L.RGBTable | None = None
    supports_amount: bool = True
    grayscale: bool = False
    rgb_table_amount: str | None = None
    settings: list = field(default_factory=list)
    curves: list = field(default_factory=list)

    @property
    def file(self):
        return f"profile-{self.stem}.xmp"


def fixtures():
    tau = 2 * math.pi
    return [
        Fixture("identity-srgb", "Identity sRGB",
                rgb=rgb_table(9, SRGB, SRGB_GAMMA, CLIP, (0.0, 1.0), lambda r, g, b: (r, g, b))),
        Fixture("warm-adobe", "Warm AdobeRGB", rgb=warm_adobe_table(), rgb_table_amount="0.5"),
        Fixture("film-prophoto", "Film ProPhoto",
                rgb=rgb_table(7, PROPHOTO, GAMMA_18, CLIP, (0.0, 1.5), lambda r, g, b: (
                    r ** 1.1, 0.02 + 0.96 * g, b + 0.1 * (g - r) * b), flags=1)),
        Fixture("rec2020-extend", "Rec2020 Extend",
                rgb=rgb_table(6, REC2020, REC709, EXTEND, (0.0, 1.0), lambda r, g, b: (
                    r + 0.06 * math.sin(tau * r),
                    g + 0.06 * math.sin(tau * g) + 0.04 * (r - b),
                    b + 0.06 * math.sin(tau * b)))),
        Fixture("p3-linear-1d", "P3 Linear 1D",
                rgb=rgb_table(17, DISPLAY_P3, LINEAR, CLIP, (0.0, 2.0), lambda r, g, b: (r ** 0.8, g, b ** 1.25),
                              dimensions=1)),
        Fixture("hsm-linear", "Hue Linear",
                look=look_table(12, 4, 4, 0, (0.0, 2.0), lambda v, h, s: (
                    10 * math.sin(tau * h / 12) * s / 3,
                    1 + 0.2 * math.cos(tau * h / 12) * s / 3,
                    1 if s == 0 else 1 - 0.1 * (v / 3) * (s / 3)))),
        Fixture("hsm-srgb-fixed", "Hue sRGB Fixed",
                look=look_table(8, 3, 4, 1, (1.0, 1.0), lambda v, h, s: (
                    15 * (1 if h % 2 == 0 else -1) * s / 2,
                    0.85 + 0.1 * v / 3,
                    1 if s == 0 else 1 - 0.15 * s / 2))),
        Fixture("hsm-flat", "Hue Flat",
                look=look_table(6, 3, 1, 0, (0.0, 2.0), lambda v, h, s: (
                    20 * s / 2, 1.1, 1 if s == 0 else 1 - 0.05 * s / 2))),
        Fixture("bw-curve", "Mono Curve", grayscale=True,
                look=look_table(8, 3, 4, 0, (0.0, 2.0), lambda v, h, s: (
                    0, 1 if s == 0 else 0.9, 1 if s == 0 else 1 + 0.25 * math.cos(tau * h / 8) * s / 2)),
                curves=[("ToneCurvePV2012", [(0, 10), (64, 58), (128, 132), (192, 205), (255, 250)]),
                        ("ToneCurvePV2012Red", [(0, 0), (128, 140), (255, 255)])],
                rgb=rgb_table(5, SRGB, SRGB_GAMMA, CLIP, (0.0, 2.0), lambda r, g, b: (
                    min(1.0, 1.05 * r + 0.02), g, 0.88 * b))),
        Fixture("settings-approx", "Approximate", rgb=warm_adobe_table(),
                settings=[("Clarity2012", "+10"), ("Contrast2012", "+8"), ("GrayMixerRed", "0"),
                          ("SplitToningShadowHue", "40")]),
        Fixture("no-amount", "No Amount", rgb=warm_adobe_table(), rgb_table_amount="0.5", supports_amount=False),
    ]


# ---------------------------------------------------------------------------
# XMP
# ---------------------------------------------------------------------------


def encode_table(raw: bytes) -> tuple[str, str]:
    """(fingerprint, text): MD5 of the payload, and [u32 size][zlib] in the 85-digit text encoding."""
    block = struct.pack("<I", len(raw)) + zlib.compress(raw, 6)
    return hashlib.md5(raw).hexdigest().upper(), L.a85_encode(block)


def xmp(fixture: Fixture, uuid: str) -> str:
    def flag(value):
        return "True" if value else "False"

    attributes = [("PresetType", "Look"), ("UUID", uuid), ("SupportsAmount", flag(fixture.supports_amount)),
                  ("SupportsColor", "True"), ("SupportsNormalDynamicRange", "True"),
                  ("SupportsSceneReferred", "True"), ("SupportsOutputReferred", "True")]
    if fixture.grayscale:
        attributes.append(("ConvertToGrayscale", "True"))
    if fixture.rgb_table_amount is not None:
        attributes.append(("RGBTableAmount", fixture.rgb_table_amount))
    attributes += fixture.settings
    tables = []
    for key, table, serialize in (("LookTable", fixture.look, L.serialize_look_table),
                                  ("RGBTable", fixture.rgb, L.serialize_rgb_table)):
        if table is None:
            continue
        fingerprint, text = encode_table(serialize(table))
        attributes.append((key, fingerprint))
        tables.append((f"Table_{fingerprint}", text))
    attributes += tables

    lines = ['<x:xmpmeta xmlns:x="adobe:ns:meta/">',
             ' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">',
             '  <rdf:Description rdf:about=""',
             '    xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"']
    lines += [f'   crs:{key}="{value}"' for key, value in attributes]
    lines[-1] += ">"
    for key, value in (("Name", fixture.name), ("Group", "Synthetic")):
        lines += [f"   <crs:{key}>", "    <rdf:Alt>", f'     <rdf:li xml:lang="x-default">{value}</rdf:li>',
                  "    </rdf:Alt>", f"   </crs:{key}>"]
    for key, points in fixture.curves:
        lines += [f"   <crs:{key}>", "    <rdf:Seq>"]
        lines += [f"     <rdf:li>{x}, {y}</rdf:li>" for x, y in points]
        lines += ["    </rdf:Seq>", f"   </crs:{key}>"]
    lines += ["  </rdf:Description>", " </rdf:RDF>", "</x:xmpmeta>", ""]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Probe, goldens, kernels
# ---------------------------------------------------------------------------


def probe() -> np.ndarray:
    img = np.zeros((22, 289, 3), np.uint8)
    lv = [round(i * 255 / 16) for i in range(17)]
    for r in range(17):
        for g in range(17):
            for b in range(17):
                img[r, g * 17 + b] = (lv[r], lv[g], lv[b])
    for row, (s, v) in enumerate([(1.0, 1.0), (0.5, 1.0), (1.0, 0.5)]):
        for x in range(289):
            img[17 + row, x] = [round(c * 255) for c in colorsys.hsv_to_rgb(x / 289, s, v)]
    for x in range(289):
        img[20, x] = round(x * 255 / 288)
        img[21, x] = COLORCHECKER[min(x // 12, 23)]
    return img


# (stem, percent, fixed-look policy)
GOLDEN_CASES = [
    ("identity-srgb", 100, "full"),
    *[("warm-adobe", p, "full") for p in (0, 50, 100, 150, 200)],
    ("film-prophoto", 100, "full"), ("film-prophoto", 150, "full"),
    ("rec2020-extend", 100, "full"),
    ("p3-linear-1d", 50, "full"), ("p3-linear-1d", 100, "full"),
    *[("hsm-linear", p, "full") for p in (0, 50, 100, 200)],
    ("hsm-srgb-fixed", 0, "full"), ("hsm-srgb-fixed", 0, "scaled"), ("hsm-srgb-fixed", 0, "skipped"),
    ("hsm-srgb-fixed", 50, "scaled"), ("hsm-srgb-fixed", 100, "full"),
    ("hsm-flat", 100, "full"),
    ("bw-curve", 50, "full"), ("bw-curve", 100, "full"),
    ("settings-approx", 100, "full"),
    ("no-amount", 200, "full"),
]

# (stem, stage, amount)
KERNEL_CASES = [
    ("hsm-linear", "look", 1.0), ("hsm-linear", "look", 0.5), ("hsm-linear", "look", 2.0),
    ("hsm-srgb-fixed", "look", 1.0), ("hsm-flat", "look", 1.0),
    ("warm-adobe", "rgb", 1.0), ("warm-adobe", "rgb", 0.5), ("warm-adobe", "rgb", 1.5),
    ("film-prophoto", "rgb", 1.0), ("film-prophoto", "rgb", 1.5),
    ("rec2020-extend", "rgb", 1.0),
    ("p3-linear-1d", "rgb", 1.0), ("p3-linear-1d", "rgb", 0.5),
]


def kernel_inputs() -> np.ndarray:
    lattice = np.stack(np.meshgrid(*[np.linspace(0, 1, 5)] * 3, indexing="ij"), -1).reshape(-1, 3)
    edges = np.array([[1, 1e-7, 0], [1, 0, 1e-7], [0.9999999, 0, 1e-7], [0.5, 0.5, 0.5], [1, 1, 1], [0, 0, 0],
                      [1, 0, 0], [0, 1, 0], [0, 0, 1], [1, 1, 0], [0, 1, 1], [1, 0, 1]], dtype=np.float64)
    rng = np.random.default_rng(7).random((63, 3))
    return np.concatenate([lattice, edges, rng])


def golden_name(stem, percent, policy):
    return f"golden-{stem}-{percent}" + ("" if policy == "full" else f"-{policy}") + ".png"


def generate(out: Path):
    out.mkdir(parents=True, exist_ok=True)
    loaded = {}
    for index, fixture in enumerate(fixtures(), start=1):
        path = out / fixture.file
        path.write_text(xmp(fixture, f"{index:032X}"), encoding="utf-8")
        loaded[fixture.stem] = L.load_profile(str(path))

    image = probe()
    Image.fromarray(image).save(out / "probe.png")

    goldens = []
    for stem, percent, policy in GOLDEN_CASES:
        _, u8, _ = A.render_srgb8(image, loaded[stem], percent / 100, fixed_look=policy)
        name = golden_name(stem, percent, policy)
        Image.fromarray(u8).save(out / name)
        goldens.append({"golden": name, "profile": f"profile-{stem}.xmp", "percent": percent, "fixedLook": policy})
    (out / "goldens.json").write_text(json.dumps(goldens, indent=1) + "\n")

    inputs = kernel_inputs()
    cases = []
    for stem, stage, amount in KERNEL_CASES:
        p = loaded[stem]
        if stage == "look":
            outputs = A.apply_hue_sat_map(inputs, p.look_table.table, amount)
        else:
            outputs = A.apply_rgb_table(inputs, p.rgb_table.table, amount)
        cases.append({"profile": f"profile-{stem}.xmp", "stage": stage, "amount": amount,
                      "outputs": outputs.tolist()})
    (out / "kernels.json").write_text(json.dumps({"inputs": inputs.tolist(), "cases": cases}) + "\n")


# ---------------------------------------------------------------------------
# --check
# ---------------------------------------------------------------------------


def pixels(path: Path) -> np.ndarray:
    with Image.open(path) as image:
        return np.asarray(image.convert("RGB"))


def profile_summary(path: Path):
    """Properties without the table text (compressed bytes may differ across zlib versions), plus the tables."""
    p = L.load_profile(str(path))
    props = {k: v for k, v in p.props.items() if not k.startswith("crs:Table_")}
    return props, p.look_table and p.look_table.table, p.rgb_table and p.rgb_table.table


def check(fresh: Path, committed: Path) -> list[str]:
    problems = []
    expected = sorted(f.name for f in fresh.iterdir())
    present = sorted(f.name for f in committed.iterdir()) if committed.is_dir() else []
    if expected != present:
        problems.append(f"files differ: missing {sorted(set(expected) - set(present))}, "
                        f"unexpected {sorted(set(present) - set(expected))}")
    for name in expected:
        a, b = fresh / name, committed / name
        if not b.exists():
            continue
        if name.endswith(".png"):
            pa, pb = pixels(a), pixels(b)
            if pa.shape != pb.shape or not np.array_equal(pa, pb):
                problems.append(f"{name}: pixels differ")
        elif name.endswith(".xmp"):
            if profile_summary(a) != profile_summary(b):
                problems.append(f"{name}: properties or tables differ")
        elif name == "kernels.json":
            ja, jb = json.loads(a.read_text()), json.loads(b.read_text())
            meta = [[(c["profile"], c["stage"], c["amount"]) for c in j["cases"]] for j in (ja, jb)]
            if meta[0] != meta[1]:
                problems.append("kernels.json: cases differ")
                continue
            arrays = [(np.array(ja["inputs"]), np.array(jb["inputs"]))]
            arrays += [(np.array(ca["outputs"]), np.array(cb["outputs"])) for ca, cb in zip(ja["cases"], jb["cases"])]
            if any(x.shape != y.shape or not np.allclose(x, y, rtol=0, atol=1e-12) for x, y in arrays):
                problems.append("kernels.json: values differ by more than 1e-12")
        elif json.loads(a.read_text()) != json.loads(b.read_text()):
            problems.append(f"{name}: differs")
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="regenerate into a temporary folder and compare")
    args = parser.parse_args()
    if not args.check:
        generate(FIXTURES)
        print(f"wrote {len(list(FIXTURES.iterdir()))} files to {FIXTURES.relative_to(REPO)}")
        return 0
    with tempfile.TemporaryDirectory() as tmp:
        fresh = Path(tmp)
        generate(fresh)
        problems = check(fresh, FIXTURES)
    for problem in problems:
        print("DRIFT:", problem)
    if problems:
        return 1
    print("fixtures are up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
