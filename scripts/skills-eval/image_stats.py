#!/usr/bin/env python3
"""Prints pixel statistics of an image as JSON, for grade_scripted.py's pixel, image_compare and image_differs checks.

    uv run --with pillow python3 scripts/skills-eval/image_stats.py <image> [--points JSON] [--other <image>]

Reports width and height; mean_luminance (Rec. 709 weights on the 0-1 channel values) and mean_red_minus_blue over
all pixels; with --points (a JSON list of [x, y] pairs or "center"), each point's {r, g, b, a} in 0-1 under the key
"x,y" or "center"; with --other, diff_fraction: the share of pixels where any channel, with premultiplied alpha,
differs by more than 8 of 255 (null when the sizes differ). Needs Pillow.
"""

import argparse
import json
import sys

from PIL import Image, ImageChops, ImageStat

THRESHOLD = 8


def premultiplied(image):
    red, green, blue, alpha = image.split()
    return [ImageChops.multiply(channel, alpha) for channel in (red, green, blue)] + [alpha]


def diff_fraction(first, second):
    if first.size != second.size:
        return None
    channels = [ImageChops.difference(a, b) for a, b in zip(premultiplied(first), premultiplied(second))]
    largest = channels[0]
    for channel in channels[1:]:
        largest = ImageChops.lighter(largest, channel)
    histogram = largest.histogram()
    return round(sum(histogram[THRESHOLD + 1:]) / (first.size[0] * first.size[1]), 6)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("image")
    parser.add_argument("--points", default="[]", help='JSON list of [x, y] pairs or "center"')
    parser.add_argument("--other", help="an image to compare with")
    args = parser.parse_args(argv)
    image = Image.open(args.image).convert("RGBA")
    width, height = image.size
    red, green, blue = (value / 255 for value in ImageStat.Stat(image.convert("RGB")).mean)
    report = {"width": width, "height": height,
              "mean_luminance": round(0.2126 * red + 0.7152 * green + 0.0722 * blue, 6),
              "mean_red_minus_blue": round(red - blue, 6), "points": {}}
    for point in json.loads(args.points):
        x, y = (width // 2, height // 2) if point == "center" else (int(point[0]), int(point[1]))
        key = "center" if point == "center" else f"{x},{y}"
        if not (0 <= x < width and 0 <= y < height):
            report["points"][key] = None
            continue
        report["points"][key] = dict(zip("rgba", (round(value / 255, 4) for value in image.getpixel((x, y)))))
    if args.other:
        report["diff_fraction"] = diff_fraction(image, Image.open(args.other).convert("RGBA"))
    json.dump(report, sys.stdout)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
