#!/usr/bin/env python3
"""Writes the synthetic PNGs that skills' evals/fixtures.json recipes ask for. Standard library only.

    python3 scripts/skills-eval/fixture_images.py skills/<skill>/evals/fixtures.json --out <folder>

Each image spec is {"path", "width", "height", "kind", "from", "to", ...}; colors are "#rrggbb". Kinds:
  solid            every pixel "from"
  linear_gradient  "from" to "to" along "angle" degrees (default 0): 0 runs left to right, 90 top to bottom
                   (y points down, as in Compositor), corner to corner of the image
  radial_gradient  "from" at "center" ({"x", "y"}, default the middle) to "to" at "radius" (default the distance
                   to the farthest corner)
  checker          "cell"-pixel squares (default 16), "from" in the top-left one
  disc             a hard-edged "from" circle at "center" with "radius" (default a quarter of the shorter side)
                   over "to"; a pixel is inside when its center is
The PNGs are 8-bit RGB, deterministic byte for byte.
"""

import argparse
import json
import math
import re
import struct
import sys
import zlib
from pathlib import Path

KINDS = ("solid", "linear_gradient", "radial_gradient", "checker", "disc")


def parse_color(text):
    match = re.fullmatch(r"#([0-9a-fA-F]{6})", str(text))
    if not match:
        raise ValueError(f"colors are #rrggbb, not {text!r}")
    value = int(match.group(1), 16)
    return value >> 16, (value >> 8) & 0xFF, value & 0xFF


def mix(a, b, t):
    t = min(max(t, 0.0), 1.0)
    return bytes(round(x + (y - x) * t) for x, y in zip(a, b))


def rows(spec):
    """Yields each row of the image as RGB bytes."""
    width, height, kind = int(spec["width"]), int(spec["height"]), spec.get("kind")
    if kind not in KINDS:
        raise ValueError(f"unknown image kind {kind!r}; expected one of {', '.join(KINDS)}")
    if width < 1 or height < 1:
        raise ValueError("width and height must be at least 1")
    start = parse_color(spec["from"])
    end = parse_color(spec.get("to", spec["from"]))
    center = spec.get("center") or {}
    cx, cy = float(center.get("x", width / 2)), float(center.get("y", height / 2))

    if kind == "solid":
        line = bytes(start) * width
        for _ in range(height):
            yield line
    elif kind == "linear_gradient":
        angle = math.radians(float(spec.get("angle", 0)))
        dx, dy = math.cos(angle), math.sin(angle)
        # The projection of the image rectangle on the direction, so the corners get exactly "from" and "to".
        extent = abs(width * dx) + abs(height * dy)
        for y in range(height):
            offset = (y + 0.5 - height / 2) * dy
            yield b"".join(mix(start, end, ((x + 0.5 - width / 2) * dx + offset) / extent + 0.5) for x in range(width))
    elif kind == "radial_gradient":
        radius = float(spec.get("radius") or max(math.hypot(px - cx, py - cy)
                                                  for px in (0, width) for py in (0, height)))
        for y in range(height):
            yield b"".join(mix(start, end, math.hypot(x + 0.5 - cx, y + 0.5 - cy) / radius) for x in range(width))
    elif kind == "checker":
        cell = int(spec.get("cell", 16))
        first, second = bytes(start), bytes(end)
        for y in range(height):
            yield b"".join(first if (x // cell + y // cell) % 2 == 0 else second for x in range(width))
    else:  # disc
        radius = float(spec.get("radius", min(width, height) / 4))
        inside, outside = bytes(start), bytes(end)
        for y in range(height):
            yield b"".join(inside if (x + 0.5 - cx) ** 2 + (y + 0.5 - cy) ** 2 <= radius ** 2 else outside
                           for x in range(width))


def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)


def png_bytes(spec):
    width, height = int(spec["width"]), int(spec["height"])
    raw = b"".join(b"\x00" + line for line in rows(spec))
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 6))
            + chunk(b"IEND", b""))


def write_image(spec, root):
    """Writes the spec's PNG at root/spec["path"] and returns that path."""
    relative = Path(spec["path"])
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError(f"image paths are relative and stay inside the folder: {spec['path']}")
    data = png_bytes(spec)
    path = Path(root) / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


def main(argv=None):
    parser = argparse.ArgumentParser(description="Write the images an evals/fixtures.json recipe lists.")
    parser.add_argument("recipe", help="a skill's evals/fixtures.json")
    parser.add_argument("--out", required=True, help="the folder the image paths are relative to")
    args = parser.parse_args(argv)
    recipe = json.loads(Path(args.recipe).read_text(encoding="utf-8"))
    for spec in recipe.get("images", []):
        print(write_image(spec, args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
