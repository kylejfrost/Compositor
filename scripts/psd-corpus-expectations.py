#!/usr/bin/env python3
"""Writes what psd-tools reads from a folder of Photoshop files, for CompositorTests/PSDCorpusTests to compare
Compositor's PSD import against.

    uv run --with psd-tools python3 scripts/psd-corpus-expectations.py <corpus-folder> [--output <file>]

Reads every `*.psd` directly in <corpus-folder> and writes `expectations.json` next to them (or to --output). For
each file: the header (size, version, depth, color mode, whether Compositor opens it as a document), the resolution
(resource 1005), and every layer in psd-tools's order (groups before their contents), with its layer ID (`lyid`),
kind and locks (`lspf`), plus where present:

- type (`TySh`): the transform, each style run's font (PostScript name), size and length, each paragraph run's
  justification and length, how many of a run's characters show (line breaks aside), and whether Compositor's import
  rules make the layer editable text (horizontal, unwarped, unrotated, unskewed, unmirrored, an RGB fill, a box for
  paragraph text);
- smart objects (`SoLd`/`SoLE`): the contents' ID (`Idnt`), the placement's ID (`placed`) and its quad (`Trnf`, document
  pixels);
- effects (`lfx2`): the master switch and, for each kind Compositor shows (stroke, drop shadow, color overlay, inner
  shadow, outer glow), its `present` entries in order with their enabled flag, whether their color is RGB, and a
  stroke's paint type;
- shapes (`vogk`, or a vector mask with a `SoCo`/`vscg` fill): each `vogk` item's `keyOriginType` and whether it is
  invalidated, and whether Compositor's import rules (`PSDVector.live`) make it a live shape, and which: a solid
  fill, a stroke Compositor can draw, a vector mask neither inverted nor disabled, one `vogk` item Photoshop hasn't
  invalidated (a rectangle, ellipse or arrowless line), upright (`Trnf` a move, or a scale along the axes for an
  ellipse or a square-cornered rectangle; box corners at its box), and a path that draws that shape (older files
  without `vogk`: four sharp corners of an upright box).

Layer names, text and file names are client data: the file keeps only their SHA-1 (`name_sha1`, `text_sha1`,
`file_sha1`; text as Compositor holds it, a final `\\r` dropped and `\\r` and U+0003 turned into `\\n`), so it can sit
next to the files without repeating them. It is never written into this repository, nor under the cloud folders
(~/Library/CloudStorage, ~/Library/Mobile Documents), whose placeholders can hang a read: point it at local copies.
"""

import argparse
import hashlib
import json
import math
import os
import sys

from psd_tools import PSDImage
from psd_tools.constants import Resource, Tag
from psd_tools.psd.base import DictElement, ListElement

REPOSITORY = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
CLOUD_FOLDERS = [os.path.expanduser("~/Library/CloudStorage"), os.path.expanduser("~/Library/Mobile Documents")]

# Compositor's `DocumentLimits`: the longest side of any surface, and the most pixels one surface (a canvas, an export,
# a filter target, a text box, a shape) may have. A document's layers together are held to a larger budget instead.
MAX_SIDE = 30_000
MAX_SURFACE_PIXELS = 200_000_000

# Compositor's effect kinds: the single key and the list key Photoshop may store them under instead.
EFFECT_KINDS = {
    "stroke": ("FrFX", "frameFXMulti"),
    "shadow": ("DrSh", "dropShadowMulti"),
    "colorOverlay": ("SoFi", "solidFillMulti"),
    "innerShadow": ("IrSh", "innerShadowMulti"),
    "outerGlow": ("OrGl", None),
}


def sha1(text):
    return hashlib.sha1(text.encode("utf-8", "surrogatepass")).hexdigest()


def inside(path, folder):
    path, folder = os.path.realpath(path), os.path.realpath(folder)
    return path == folder or path.startswith(folder + os.sep)


def code(value):
    """A four-character code (a descriptor key, an enumeration's value) as a string."""
    value = getattr(value, "value", value)
    return value.decode("latin-1") if isinstance(value, bytes) else str(value)


def plain(value):
    """An engine-data or descriptor value as plain Python: numbers, strings, bools, lists and dicts (keys and
    enumerations as their codes)."""
    if isinstance(value, dict) or isinstance(value, DictElement):
        return {code(key): plain(item) for key, item in value.items()}
    if isinstance(value, (list, tuple, ListElement)):
        return [plain(item) for item in value]
    if hasattr(value, "enum"):
        return code(value.enum)
    value = getattr(value, "value", value)
    if isinstance(value, bytes):
        return value.decode("latin-1")
    return value


def at(value, path):
    """`value` followed along a dotted path of keys and list indices; None where it runs out."""
    for step in path.split("."):
        if isinstance(value, list):
            index = int(step) if step.lstrip("-").isdigit() else None
            value = value[index] if index is not None and 0 <= index < len(value) else None
        elif isinstance(value, dict):
            value = value.get(step)
        else:
            return None
        if value is None:
            return None
    return value


def first(*values):
    return next((value for value in values if value is not None), None)


def number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def shown_counts(lengths, text):
    """How many UTF-16 units of each run aren't line breaks, each run clamped to the text that remains."""
    units = [int.from_bytes(text.encode("utf-16-le", "surrogatepass")[i:i + 2], "little")
             for i in range(0, len(text.encode("utf-16-le", "surrogatepass")), 2)]
    start, counts = 0, []
    for length in lengths:
        end = start + max(0, min(length, len(units) - start))
        counts.append(sum(1 for unit in units[start:end] if unit not in (0x0D, 0x0A, 0x03)))
        start = end
    return counts


def dominant(runs):
    """The run showing the most characters; the first on a tie."""
    return max(enumerate(runs), key=lambda item: (item[1]["shown"], -item[0]))[1] if runs else None


def text_box_fits(width, height, sx, sy):
    """Whether a paragraph text box of `width` x `height`, scaled by `sx` and `sy`, fits Compositor's text box
    (`TypeTool`): the scaled box with its padding (12 px) on each side is 16 to MAX_SIDE px a side and one surface,
    at most MAX_SURFACE_PIXELS."""
    boxed = (width * sx + 24, height * sy + 24)
    return (width > 0 and height > 0 and all(16 <= side <= MAX_SIDE for side in boxed)
            and boxed[0] * boxed[1] <= MAX_SURFACE_PIXELS)


def type_layer(layer):
    engine = plain(layer.engine_dict) or {}
    resources = plain(layer.resource_dict) or plain(layer.document_resources) or {}
    text = at(engine, "Editor.Text")
    if not isinstance(text, str):
        text = layer.text
    fonts = [at(font, "Name") or "" for font in resources.get("FontSet", [])]
    normal_style = at(resources, "StyleSheetSet.%d.StyleSheetData" % (resources.get("TheNormalStyleSheet") or 0)) or {}
    default_style = at(engine, "StyleRun.DefaultRunData.StyleSheet.StyleSheetData") or {}
    style_runs = at(engine, "StyleRun.RunArray") or []
    style_lengths = [int(length) for length in at(engine, "StyleRun.RunLengthArray") or []]
    runs = []
    for run, length in zip(style_runs, style_lengths):
        data = at(run, "StyleSheet.StyleSheetData") or {}

        def value(key):
            return first(data.get(key), default_style.get(key), normal_style.get(key))

        font = value("Font") if isinstance(value("Font"), int) else 0
        fill = value("FillColor") or {}
        runs.append({
            "length": length,
            "font": fonts[font] if 0 <= font < len(fonts) else "",
            "size": float(first(number(value("FontSize")), 12)),
            "fill_type": int(first(number(fill.get("Type")), 1)),
            "fill_values": len([v for v in fill.get("Values", [1, 0, 0, 0]) if number(v) is not None and math.isfinite(v)]),
        })
    for run, shown in zip(runs, shown_counts(style_lengths, text)):
        run["shown"] = shown
    normal_paragraph = at(resources, "ParagraphSheetSet.%d.Properties" % (resources.get("TheNormalParagraphSheet") or 0)) or {}
    default_paragraph = at(engine, "ParagraphRun.DefaultRunData.ParagraphSheet.Properties") or {}
    paragraph_lengths = [int(length) for length in at(engine, "ParagraphRun.RunLengthArray") or []]
    paragraphs = []
    for run, length in zip(at(engine, "ParagraphRun.RunArray") or [], paragraph_lengths):
        justification = first(at(run, "ParagraphSheet.Properties.Justification"),
                              default_paragraph.get("Justification"), normal_paragraph.get("Justification"), 0)
        paragraphs.append({"length": length, "justification": int(justification)})
    for paragraph, shown in zip(paragraphs, shown_counts(paragraph_lengths, text)):
        paragraph["shown"] = shown

    xx, xy, yx, yy, tx, ty = [float(v) for v in layer.transform]
    sx, sy = math.hypot(xx, xy), math.hypot(yx, yy)
    shape = at(engine, "Rendered.Shapes.Children.0") or {}
    cookie = at(shape, "Cookie.Photoshop") or {}
    paragraph_text = first(cookie.get("ShapeType"), shape.get("ShapeType"), 0) == 1
    box = cookie.get("BoxBounds")
    orientation = plain(layer._data.text_data.get(b"Ornt")) or "Hrzn"
    warp_style = (plain(layer.warp.get(b"warpStyle")) if layer.warp is not None else None) or "warpNone"
    run = dominant(runs)
    editable = (
        layer.width > 0 and layer.height > 0
        and orientation != "Vrtc" and warp_style == "warpNone"
        and all(math.isfinite(v) for v in (sx, sy)) and sx > 0 and sy > 0
        and abs(xx * yx + xy * yy) / (sx * sy) < 0.01
        and abs(math.atan2(xy, xx)) <= 0.0001
        and xx * yy - xy * yx >= 0
        and run is not None and run["fill_type"] == 1 and run["fill_values"] == 4
        and len(text.encode("utf-16-le", "surrogatepass")) // 2 <= 100_000
    )
    if editable and paragraph_text:
        bounds = [number(v) for v in box] if isinstance(box, list) and len(box) == 4 else None
        width = bounds[2] - bounds[0] if bounds and None not in bounds else 0
        height = bounds[3] - bounds[1] if bounds and None not in bounds else 0
        editable = text_box_fits(width, height, sx, sy)
    content = text[:-1] if text.endswith("\r") else text
    content = content.replace("\r", "\n").replace("\x03", "\n")
    return {
        "text_sha1": sha1(content),
        "transform": [xx, xy, yx, yy, tx, ty],
        "fonts": fonts,
        "runs": runs,
        "paragraphs": paragraphs,
        "paragraph_text": paragraph_text,
        "editable": bool(editable),
    }


def smart_object(layer):
    for tag in (Tag.SMART_OBJECT_LAYER_DATA1, Tag.SMART_OBJECT_LAYER_DATA2):
        if tag in layer.tagged_blocks:
            data = plain(getattr(layer.tagged_blocks.get_data(tag), "data", None)) or {}
            quad = data.get("Trnf")
            return {
                "unique_id": (data.get("Idnt") or "").strip("\x00"),
                "placed": (data.get("placed") or "").strip("\x00"),
                "quad": [float(v) for v in quad] if isinstance(quad, list) and len(quad) == 8 else None,
            }
    return None


def effects(layer):
    if Tag.OBJECT_BASED_EFFECTS_LAYER_INFO not in layer.tagged_blocks:
        return None
    root = plain(layer.tagged_blocks.get_data(Tag.OBJECT_BASED_EFFECTS_LAYER_INFO)) or {}
    kinds = {}
    for kind, (single, multi) in EFFECT_KINDS.items():
        listed = [entry for entry in (root.get(multi) or [] if multi else []) if isinstance(entry, dict)]
        entries = listed or ([root[single]] if isinstance(root.get(single), dict) else [])
        present = [entry for entry in entries if entry.get("present", True) is not False]
        if not present:
            continue
        found = []
        for entry in present:
            color = entry.get("Clr ") or {}
            found.append({
                "enabled": entry.get("enab", True) is not False,
                "rgb": all(number(color.get(key)) is not None for key in ("Rd  ", "Grn ", "Bl  "))
                or all(number(color.get(key)) is not None for key in ("redFloat", "greenFloat", "blueFloat")),
                "paint": entry.get("PntT", "SClr") if kind == "stroke" else None,
            })
        kinds[kind] = found
    return {"master": root.get("masterFXSwitch", True) is not False, "kinds": kinds}


# Descriptor values by their stored type, as PSDDescriptor's accessors read them (`bool`, `int`, `unit`, a number
# stored any of three ways, `object`, `list`), so the predicate below refuses what Compositor refuses.
def item(descriptor, key):
    if descriptor is None or not hasattr(descriptor, "items"):
        return None
    return next((value for name, value in descriptor.items() if code(name) == key), None)


def typed(value, *kinds):
    return value is not None and type(value).__name__ in kinds


def d_bool(descriptor, key):
    value = item(descriptor, key)
    return bool(value.value) if typed(value, "Bool") else None


def d_int(descriptor, key):
    value = item(descriptor, key)
    return int(value.value) if typed(value, "Integer", "LargeInteger") else None


def d_unit(descriptor, key):
    value = item(descriptor, key)
    return float(value.value) if typed(value, "UnitFloat") else None


def d_number(descriptor, key):
    value = item(descriptor, key)
    return float(value.value) if typed(value, "UnitFloat", "Double", "Integer") else None


def d_object(descriptor, key):
    value = item(descriptor, key)
    return value if hasattr(value, "items") else None


def d_list(descriptor, key):
    value = item(descriptor, key)
    return list(value) if typed(value, "List") else None


def rgb(descriptor, key):
    """`Clr ` as PSDDescriptor.rgb reads it: `Rd  `/`Grn `/`Bl  ` in 0…255, else the 0…1 float form."""
    color = d_object(descriptor, key)
    for keys, scale in ((("Rd  ", "Grn ", "Bl  "), 1), (("redFloat", "greenFloat", "blueFloat"), 255)):
        values = [d_number(color, name) for name in keys]
        if all(value is not None and math.isfinite(value) for value in values):
            return tuple(min(255, max(0, value * scale)) / 255 for value in values)
    return None


def path_subpaths(data, width, height):
    """The subpaths of a `vmsk`/`vsms` path with knots, each (closed, [(incoming, anchor, outgoing)]) in document
    pixels."""
    result = []
    for record in data.path:
        if type(record).__name__ not in ("ClosedPath", "OpenPath") or len(record) == 0:
            continue
        knots = [tuple((point[1] * width, point[0] * height) for point in (knot.preceding, knot.anchor, knot.leaving))
                 for knot in record]
        result.append((type(record).__name__ == "ClosedPath", knots))
    return result


def path_bounds(subpaths):
    """The tight box around the path's curves (CGPath.boundingBoxOfPath): the anchors and each cubic's extremes."""
    xs, ys = [], []

    def extremes(p0, c1, c2, p3, axis):
        a = p3[axis] - 3 * c2[axis] + 3 * c1[axis] - p0[axis]
        b = 2 * (c2[axis] - 2 * c1[axis] + p0[axis])
        c = c1[axis] - p0[axis]
        if abs(a) < 1e-12:
            roots = [-c / b] if abs(b) > 1e-12 else []
        else:
            discriminant = b * b - 4 * a * c
            roots = [] if discriminant < 0 else [(-b + sign * math.sqrt(discriminant)) / (2 * a) for sign in (1, -1)]
        values = []
        for t in roots:
            if 0 < t < 1:
                u = 1 - t
                values.append(u ** 3 * p0[axis] + 3 * u * u * t * c1[axis] + 3 * u * t * t * c2[axis] + t ** 3 * p3[axis])
        return values

    for closed, knots in subpaths:
        segments = list(zip(knots, knots[1:])) + ([(knots[-1], knots[0])] if closed else [])
        for _, anchor, _ in knots:
            xs.append(anchor[0])
            ys.append(anchor[1])
        for (_, p0, c1), (c2, p3, _) in segments:
            xs.extend(extremes(p0, c1, c2, p3, 0))
            ys.extend(extremes(p0, c1, c2, p3, 1))
    return (min(xs), min(ys), max(xs), max(ys)) if xs else None


PATH_TOLERANCE = 1


def are_corners(points, box):
    left, top, right, bottom = box
    corners = [(left, top), (right, top), (right, bottom), (left, bottom)]

    def near(a, b):
        return abs(a[0] - b[0]) <= PATH_TOLERANCE and abs(a[1] - b[1]) <= PATH_TOLERANCE

    return (len(points) == 4 and all(any(near(point, corner) for point in points) for corner in corners)
            and all(any(near(point, corner) for corner in corners) for point in points))


def pixel_point(descriptor):
    x, y = d_number(descriptor, "Hrzn"), d_number(descriptor, "Vrtc")
    return (x, y) if x is not None and y is not None and math.isfinite(x) and math.isfinite(y) else None


def upright(transform, square_corners):
    """`Trnf` absent, a move, or (square corners or an ellipse) a move and a scale along the axes."""
    if transform is None:
        return True
    xx, xy, yx, yy = (d_number(transform, key) for key in ("xx", "xy", "yx", "yy"))
    if None in (xx, xy, yx, yy):
        return False
    tolerance = 1e-4
    if abs(xx - 1) <= tolerance and abs(yy - 1) <= tolerance and abs(xy) <= tolerance and abs(yx) <= tolerance:
        return True
    return (square_corners and math.isfinite(xx) and math.isfinite(yy) and xx > tolerance and yy > tolerance
            and abs(xy) <= tolerance and abs(yx) <= tolerance)


def origination(root):
    """The one shape a `vogk` describes, as PSDVector.origination reads it: (kind, box, line) or None."""
    items = d_list(root, "keyDescriptorList")
    if d_bool(root, "keyShapeInvalidated") is True or items is None or len(items) != 1 or not hasattr(items[0], "items"):
        return None
    shape = items[0]
    kind = {1: "rectangle", 2: "rectangle", 4: "line", 5: "ellipse"}.get(d_int(shape, "keyOriginType"))
    if d_bool(shape, "keyShapeInvalidated") is True or kind is None:
        return None
    if kind == "line":
        start = pixel_point(d_object(shape, "keyOriginLineStart"))
        end = pixel_point(d_object(shape, "keyOriginLineEnd"))
        weight = d_number(shape, "keyOriginLineWeight")
        if (d_bool(shape, "keyOriginLineArrowSt") is True or d_bool(shape, "keyOriginLineArrowEnd") is True
                or start is None or end is None or weight is None or not math.isfinite(weight) or weight <= 0):
            return None
        box = (min(start[0], end[0]), min(start[1], end[1]), max(start[0], end[0]), max(start[1], end[1]))
        return kind, box, (start, end, weight)
    box_descriptor = d_object(shape, "keyOriginShapeBBox")
    box = tuple(d_unit(box_descriptor, key) for key in ("Left", "Top ", "Rght", "Btom"))
    if None in box or not all(math.isfinite(value) for value in box) or box[2] - box[0] < 1 or box[3] - box[1] < 1:
        return None
    corners = d_object(shape, "keyOriginBoxCorners")
    if corners is not None:
        points = [pixel_point(d_object(corners, key))
                  for key in ("rectangleCornerA", "rectangleCornerB", "rectangleCornerC", "rectangleCornerD")]
        if not are_corners([point for point in points if point is not None], box):
            return None
    radius = 0
    radii_descriptor = d_object(shape, "keyOriginRRectRadii") if kind == "rectangle" else None
    if radii_descriptor is not None:
        radii = [d_unit(radii_descriptor, key) for key in ("topLeft", "topRight", "bottomRight", "bottomLeft")]
        radii = [value for value in radii if value is not None]
        if len(radii) == 4:
            if max(radii) - min(radii) > 0.5:
                return None
            radius = max(radii)
    if not upright(d_object(shape, "Trnf"), radius == 0):
        return None
    return kind, box, None


def draws(kind, box, line, subpaths):
    """Whether the path is that one shape, as PSDVector.draws decides: one subpath filling the box, or for a line
    one along it that reaches both ends."""
    bounds = path_bounds(subpaths)
    if len(subpaths) != 1 or bounds is None:
        return False
    if line is None:
        return all(abs(bounds[i] - box[i]) <= PATH_TOLERANCE for i in range(4))
    start, end, weight = line
    reach = weight / 2 + PATH_TOLERANCE
    dx, dy = end[0] - start[0], end[1] - start[1]
    length_squared = dx * dx + dy * dy

    def off_line(point):
        along = (min(1, max(0, ((point[0] - start[0]) * dx + (point[1] - start[1]) * dy) / length_squared))
                 if length_squared > 0 else 0)
        return math.hypot(point[0] - (start[0] + along * dx), point[1] - (start[1] + along * dy))

    anchors = [anchor for _, anchor, _ in subpaths[0][1]]
    inside_box = (box[0] - reach <= bounds[0] and box[1] - reach <= bounds[1]
                  and bounds[2] <= box[2] + reach and bounds[3] <= box[3] + reach)
    return (inside_box and all(off_line(anchor) <= reach for anchor in anchors)
            and all(any(math.hypot(anchor[0] - e[0], anchor[1] - e[1]) <= reach for anchor in anchors) for e in (start, end)))


def sharp_rect(subpaths):
    """Older files without `vogk`: a path of four sharp anchors at the corners of their upright box."""
    if len(subpaths) != 1 or len(subpaths[0][1]) != 4:
        return None
    knots = subpaths[0][1]
    box = path_bounds(subpaths)
    sharp = all(math.hypot(c[0] - a[0], c[1] - a[1]) <= 0.5 for incoming, a, outgoing in knots for c in (incoming, outgoing))
    if not sharp or box is None or box[2] - box[0] < 1 or box[3] - box[1] < 1:
        return None
    return "rectangle" if are_corners([anchor for _, anchor, _ in knots], box) else None


ADJUSTMENT_KEYS = {"levl", "curv", "hue2", "hue ", "expA", "grdm", "brit", "blnc", "nvrt", "thrs", "post", "mixr", "selc",
                   "blwh", "phfl", "vibA", "clrL"}


def live_shape(blocks, width, height):
    """The kind of live shape Compositor's import makes of the layer (PSDVector.live), or None when it stays pixels."""
    stroke_style = blocks.get_data(Tag.VECTOR_STROKE_DATA) if Tag.VECTOR_STROKE_DATA in blocks else None
    if d_bool(stroke_style, "fillEnabled") is False:
        return None
    fill = rgb(blocks.get_data(Tag.SOLID_COLOR_SHEET_SETTING), "Clr ") if Tag.SOLID_COLOR_SHEET_SETTING in blocks else None
    if fill is None and Tag.VECTOR_STROKE_CONTENT_DATA in blocks:
        content = blocks.get_data(Tag.VECTOR_STROKE_CONTENT_DATA)
        fill = rgb(content, "Clr ") if code(getattr(content, "key", b"")) == "SoCo" else None
    if fill is None or any(code(key) in ADJUSTMENT_KEYS for key in blocks.keys()):
        return None
    stroke = None
    if stroke_style is not None:
        color = rgb(d_object(stroke_style, "strokeStyleContent"), "Clr ")
        stroke_width = d_unit(stroke_style, "strokeStyleLineWidth")
        if color is not None and stroke_width is not None and math.isfinite(stroke_width) and 0 <= stroke_width <= 500:
            stroke = (color, stroke_width)
        if d_bool(stroke_style, "strokeEnabled") is True:
            dashed = len(d_list(stroke_style, "strokeStyleLineDashSet") or []) > 0
            opacity = d_unit(stroke_style, "strokeStyleOpacity")
            if stroke is None or dashed or abs((100 if opacity is None else opacity) - 100) >= 0.5:
                return None
    mask = next((blocks.get_data(tag) for tag in (Tag.VECTOR_MASK_SETTING1, Tag.VECTOR_MASK_SETTING2) if tag in blocks), None)
    if mask is not None and (mask.invert or mask.disable):
        return None
    subpaths = path_subpaths(mask, width, height) if mask is not None else []
    if Tag.VECTOR_ORIGINATION_DATA in blocks:
        described = origination(blocks.get_data(Tag.VECTOR_ORIGINATION_DATA))
        if described is None or mask is None or not draws(*described, subpaths):
            return None
        kind, _, line = described
        # A line stroked in another color than its own is something a Compositor line can't draw.
        if line is not None and stroke is not None and d_bool(stroke_style, "strokeEnabled") is True and stroke[1] > 0 \
                and max(abs(a - b) for a, b in zip(stroke[0], fill)) > 0.5 / 255:
            return None
        return kind
    return sharp_rect(subpaths)


def shapes(layer, width, height):
    blocks = layer.tagged_blocks
    has_mask = Tag.VECTOR_MASK_SETTING1 in blocks or Tag.VECTOR_MASK_SETTING2 in blocks
    has_fill = Tag.SOLID_COLOR_SHEET_SETTING in blocks or Tag.VECTOR_STROKE_CONTENT_DATA in blocks
    if layer.is_group() or not (Tag.VECTOR_ORIGINATION_DATA in blocks or has_mask and has_fill):
        return None
    items = []
    if Tag.VECTOR_ORIGINATION_DATA in blocks:
        data = plain(blocks.get_data(Tag.VECTOR_ORIGINATION_DATA)) or {}
        items = [{"type": int(first(number(entry.get("keyOriginType")), 0)),
                  "invalidated": bool(entry.get("keyShapeInvalidated"))}
                 for entry in data.get("keyDescriptorList", []) if isinstance(entry, dict)]
    kind = live_shape(blocks, width, height)
    return {"items": items, "live": kind is not None, "kind": kind}


def describe(path):
    psd = PSDImage.open(path)
    color_mode = int(getattr(psd.color_mode, "value", psd.color_mode))
    entry = {
        "width": psd.width, "height": psd.height, "version": int(psd.version), "depth": int(psd.depth),
        "color_mode": color_mode,
        "supported": int(psd.version) == 1 and int(psd.depth) == 8 and color_mode == 3,
    }
    resolution = psd.image_resources.get_data(Resource.RESOLUTION_INFO)
    entry["resolution"] = resolution.horizontal / 65536 if resolution is not None else 72.0
    layers = []
    for layer in psd.descendants():
        locks = layer.tagged_blocks.get_data(Tag.PROTECTED_SETTING) if Tag.PROTECTED_SETTING in layer.tagged_blocks else None
        record = {
            "id": int(layer.layer_id),
            "name_sha1": sha1(layer.name),
            "kind": layer.kind,
            "locks": int(getattr(locks, "value", locks) or 0),
        }
        if Tag.TYPE_TOOL_OBJECT_SETTING in layer.tagged_blocks:
            record["text"] = type_layer(layer)
        for key, reader in (("smart_object", smart_object), ("effects", effects)):
            value = reader(layer)
            if value is not None:
                record[key] = value
        shape = shapes(layer, psd.width, psd.height)
        if shape is not None:
            record["shape"] = shape
        layers.append(record)
    entry["layer_count"] = len(layers)
    entry["layers"] = layers
    return entry


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("corpus", help="folder of local PSD copies")
    parser.add_argument("--output", help="where to write (default: <corpus>/expectations.json)")
    args = parser.parse_args()
    folder = os.path.realpath(args.corpus)
    output = os.path.realpath(args.output or os.path.join(folder, "expectations.json"))
    for path in (folder, output):
        if inside(path, REPOSITORY):
            sys.exit("Refusing %s: expectations describe client files and never go into the repository." % path)
        if any(inside(path, cloud) for cloud in CLOUD_FOLDERS):
            sys.exit("Refusing %s: cloud placeholders can hang a read. Copy the files to a local folder." % path)
    names = sorted(name for name in os.listdir(folder)
                   if name.lower().endswith(".psd") and os.path.isfile(os.path.join(folder, name)))
    files = []
    for name in names:
        try:
            entry = describe(os.path.join(folder, name))
        except Exception as error:  # A file psd-tools can't read is listed, without its message (it may quote names).
            entry = {"error": type(error).__name__}
        entry["file_sha1"] = sha1(name)
        files.append(entry)
        print("%s… %s" % (entry["file_sha1"][:12], entry.get("error") or "%d layers" % entry["layer_count"]))
    with open(output, "w") as stream:
        json.dump({"version": 2, "files": files}, stream, indent=1, sort_keys=True)
    print("Wrote %d files' expectations to %s" % (len(files), output))


if __name__ == "__main__":
    main()
