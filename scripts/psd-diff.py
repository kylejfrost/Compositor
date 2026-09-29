#!/usr/bin/env python3
"""Compares two renders of a document pixel by pixel.

    python3 scripts/psd-diff.py <a.png> <b.png> [--tolerance 8] [--max-fraction 0.002]

A pixel differs when any channel of the two images, compared with premultiplied alpha (so colour under full
transparency is ignored), is more than --tolerance apart (0-255). Passes (exit 0) when the fraction of
differing pixels is at most --max-fraction; exits 1 when it is larger and 2 when the images can't be compared.
Needs only Pillow (run with `uv run --with pillow` if the system python3 lacks it); thresholds per check are
in docs/psd-export.md.
"""

import argparse
import sys

from PIL import Image, ImageChops


def _premultiplied(path):
    with Image.open(path) as image:
        return image.convert("RGBA").convert("RGBa")


def compare(a, b, tolerance):
    """Returns (differing pixel count, total pixels, largest channel difference)."""
    difference = ImageChops.difference(a, b)
    over = [band.point(lambda value: 255 if value > tolerance else 0) for band in difference.split()]
    mask = over[0]
    for band in over[1:]:
        mask = ImageChops.lighter(mask, band)
    largest = max(high for _, high in difference.getextrema())
    return mask.histogram()[255], a.width * a.height, largest


def main(argv=None):
    parser = argparse.ArgumentParser(description="Compare two renders of a document pixel by pixel.")
    parser.add_argument("a", help="first image (e.g. Photoshop's PNG)")
    parser.add_argument("b", help="second image")
    parser.add_argument("--tolerance", type=int, default=8, help="largest channel difference ignored (default 8)")
    parser.add_argument(
        "--max-fraction", type=float, default=0.002, help="largest passing fraction of differing pixels (default 0.002)"
    )
    args = parser.parse_args(argv)

    try:
        a, b = _premultiplied(args.a), _premultiplied(args.b)
    except OSError as error:
        print(f"psd-diff: {error}", file=sys.stderr)
        return 2
    if a.size != b.size:
        print(
            f"psd-diff: sizes differ: {args.a} is {a.width} x {a.height}, {args.b} is {b.width} x {b.height}",
            file=sys.stderr,
        )
        return 2

    differing, total, largest = compare(a, b, args.tolerance)
    fraction = differing / total if total else 0.0
    passed = fraction <= args.max_fraction
    print(f"differing pixels: {differing} of {total} ({fraction:.4%}); max channel difference: {largest}")
    print(
        f"{'PASS' if passed else 'FAIL'} (tolerance {args.tolerance}, max fraction {args.max_fraction:g} "
        f"= {args.max_fraction:.4%})"
    )
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
