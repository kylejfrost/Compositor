#!/usr/bin/env python3
"""Prints the structure psd-tools reads from a PSD, to check files Compositor (or anything else) writes.

    uv run --with psd-tools python3 scripts/psd-verify.py <file.psd> [--json out.json] [--raw]

Reports the header, the signed layer count, image resources and document-level tagged blocks in file order,
guides (resource 1032), and every layer in Photoshop's order (top to bottom, groups before their contents):
kind, name, bbox, blend mode, opacity, clipping, visibility and locks, plus text (TypeLayer.text, transform,
text_type), effects and smart-object ids and file types where present. Exits 1 when psd-tools logs or raises
a warning, or when the file or a layer can't be read; see docs/psd-export.md.

Layer names, text and the file's name are client data, so the report and the summary hold their SHA-256
(`name_sha256`, `text_sha256`, `file_sha256`) instead, hashed exactly as scripts/photoshop-verify.jsx does,
and error and warning messages have them replaced by `#` and the hash's first 12 hex digits. `--raw` also
stores the strings themselves.
"""

import argparse
import hashlib
import json
import logging
import os
import re
import sys
import warnings

import psd_tools
from psd_tools import PSDImage
from psd_tools.constants import Resource


class _WarningLog(logging.Handler):
    def __init__(self, messages):
        super().__init__(logging.WARNING)
        self.messages = messages

    def emit(self, record):
        self.messages.append(record.getMessage())


def digest(text):
    """SHA-256 hex of the UTF-8 bytes (lone surrogates as their 3-byte form, as photoshop-verify.jsx does)."""
    return hashlib.sha256(text.encode("utf-8", "surrogatepass")).hexdigest()


class Privacy:
    """Keeps client strings (layer names, text, the file's name and path) out of the report unless `raw`.

    `conceal` stores a string as `<key>_sha256`, plus `<key>` itself only when raw, and remembers it so that
    `scrub` can replace it in error and warning messages with `#` and the first 12 hex digits of its hash.
    """

    def __init__(self, raw):
        self.raw = raw
        self._secrets = set()

    def remember(self, value):
        if value:
            self._secrets.add(value)

    def conceal(self, entry, key, value):
        if value is not None:
            value = str(value)
            self.remember(value)
        entry[key + "_sha256"] = None if value is None else digest(value)
        if self.raw:
            entry[key] = value

    def scrub(self, message):
        if self.raw or not self._secrets:
            return message
        pattern = "|".join(re.escape(secret) for secret in sorted(self._secrets, key=len, reverse=True))
        return re.sub(pattern, lambda match: "#" + digest(match.group(0))[:12], message)


def _key_name(key):
    value = getattr(key, "value", key)
    return value.decode("latin-1") if isinstance(value, bytes) else str(value)


def _resource(key):
    number = int(getattr(key, "value", key))
    try:
        name = Resource(number).name
    except ValueError:
        name = None
    return {"id": number, "name": name}


def _guides(psd):
    info = psd.image_resources.get_data(Resource.GRID_AND_GUIDES_INFO)
    if info is None:
        return []
    return [
        {
            "location": location,
            "direction": direction,
            "axis": "vertical" if direction == 0 else "horizontal",
            "position": location / 32,
        }
        for location, direction in info.data
    ]


def _locks(layer):
    locks = layer.locks
    if locks is None:
        return None
    return {
        "value": int(locks.value),
        "transparency": locks.transparency,
        "composite": locks.composite,
        "position": locks.position,
        "nesting": locks.nesting,
        "complete": locks.complete,
    }


def _text(layer, privacy):
    text_type = layer.text_type
    runs = layer.typesetting.runs
    text = {}
    privacy.conceal(text, "text", layer.text)
    text.update(
        text_type=text_type.name if text_type is not None else None,
        transform=list(layer.transform),
        fonts=layer.font_names,
        font_sizes=list(dict.fromkeys(run.style.font_size for run in runs)),
    )
    return text


def _effects(layer, privacy):
    effects = layer.effects
    return {
        "enabled": effects.enabled,
        "items": [{"name": effect.name, "enabled": effect.enabled, "shown": effect.shown} for effect in effects],
    }


def _smart_object(layer, privacy):
    smart = layer.smart_object
    return {
        "unique_id": smart.unique_id,
        "kind": smart.kind,
        "filetype": smart.filetype,
        "filesize": smart.filesize,
    }


def _layer(layer, index, depth, errors, privacy):
    entry = {"index": index, "depth": depth, "kind": layer.kind}
    privacy.conceal(entry, "name", layer.name)
    entry.update(
        bbox=list(layer.bbox),
        blend_mode=layer.blend_mode.name,
        opacity=layer.opacity,
        fill_opacity=layer.fill_opacity,
        visible=layer.visible,
        clipping=layer.clipping,
        locks=_locks(layer),
    )
    details = []
    if layer.kind == "type":
        details.append(("text", _text))
    if layer.kind == "smartobject":
        details.append(("smart_object", _smart_object))
    if layer.has_effects(enabled=False):
        details.append(("effects", _effects))
    for key, read in details:
        try:
            entry[key] = read(layer, privacy)
        except Exception as error:  # a malformed block is a finding, not a crash
            entry[key] = None
            errors.append(f"layer {index} {key}: {type(error).__name__}: {error}")
    return entry


def _layers_top_to_bottom(group, depth, entries, errors, privacy):
    # psd-tools keeps layer-record order (bottom first); Photoshop lists top first.
    for layer in reversed(list(group)):
        entries.append(_layer(layer, len(entries), depth, errors, privacy))
        if layer.is_group():
            _layers_top_to_bottom(layer, depth + 1, entries, errors, privacy)


def inspect(path, raw=False):
    path = str(path)
    privacy = Privacy(raw)
    basename = os.path.basename(path)
    for value in (path, os.path.abspath(path), basename, os.path.splitext(basename)[0]):
        privacy.remember(value)
    report = {"file": path} if raw else {}
    report.update(
        file_sha256=digest(basename),
        raw=raw,
        psd_tools=psd_tools.__version__,
        warnings=[],
        errors=[],
    )
    handler = _WarningLog(report["warnings"])
    logger = logging.getLogger("psd_tools")
    propagate = logger.propagate
    logger.addHandler(handler)
    logger.propagate = False  # the summary lists them; don't also print them to stderr
    try:
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            try:
                psd = PSDImage.open(path)
                header = psd._record.header
                layer_info = psd._record.layer_and_mask_information.layer_info
                report["header"] = {
                    "version": header.version,
                    "channels": header.channels,
                    "width": header.width,
                    "height": header.height,
                    "depth": header.depth,
                    "color_mode": header.color_mode.name,
                }
                report["layer_count"] = layer_info.layer_count if layer_info is not None else 0
                report["resources"] = [_resource(key) for key in psd.image_resources.keys()]
                report["document_blocks"] = [_key_name(key) for key in (psd.tagged_blocks or {}).keys()]
                report["guides"] = _guides(psd)
                report["layers"] = []
                _layers_top_to_bottom(psd, 0, report["layers"], report["errors"], privacy)
            except Exception as error:
                report["errors"].append(f"{type(error).__name__}: {error}")
        report["warnings"].extend(str(warning.message) for warning in caught)
    finally:
        logger.removeHandler(handler)
        logger.propagate = propagate
    for label in ("warnings", "errors"):
        report[label] = [privacy.scrub(message) for message in report[label]]
    return report


def _number(value):
    return f"{value:g}"


def _label(entry, key):
    """The string itself (raw reports) or `#` and the first 12 hex digits of its hash."""
    if key in entry:
        return json.dumps(entry[key], ensure_ascii=False)
    hashed = entry[key + "_sha256"]
    return "#" + hashed[:12] if hashed else "null"


def summary(report):
    lines = [report["file"] if "file" in report else "file #" + report["file_sha256"][:12]]
    header = report.get("header")
    if header:
        lines.append(
            f"  header: PSD version {header['version']}, {header['width']} x {header['height']} px, "
            f"{header['channels']} channels, {header['depth']}-bit {header['color_mode']}"
        )
        count = report["layer_count"]
        note = " (negative: the first alpha channel is the merged transparency)" if count < 0 else ""
        lines.append(f"  layer count: {count}{note}")
        resources = ", ".join(f"{r['id']} {r['name'] or '?'}" for r in report["resources"])
        lines.append(f"  resources ({len(report['resources'])}): {resources or 'none'}")
        lines.append(f"  document blocks: {' '.join(report['document_blocks']) or 'none'}")
        guides = ", ".join(f"{g['axis']} {_number(g['position'])} px" for g in report["guides"])
        lines.append(f"  guides: {guides or 'none'}")
        lines.append(f"  layers ({len(report['layers'])}, top to bottom):")
        for layer in report["layers"]:
            lines.append("    " + "  " * layer["depth"] + _layer_line(layer))
    for label in ("warnings", "errors"):
        items = report[label]
        lines.append(f"  {label}: {'none' if not items else len(items)}")
        lines.extend(f"    {item}" for item in items)
    return "\n".join(lines)


def _layer_line(layer):
    left, top, right, bottom = layer["bbox"]
    parts = [
        f"{layer['index']} {layer['kind']} {_label(layer, 'name')}",
        f"({left}, {top}, {right}, {bottom})",
        layer["blend_mode"],
        f"opacity {layer['opacity']}",
        f"fill {layer['fill_opacity']}",
    ]
    if layer["clipping"]:
        parts.append("clipped")
    if not layer["visible"]:
        parts.append("hidden")
    if layer["locks"] and layer["locks"]["value"]:
        parts.append(f"locks {layer['locks']['value']:#x}")
    text = layer.get("text")
    if text:
        sizes = "/".join(_number(size) for size in text["font_sizes"])
        parts.append(f"text {text['text_type']} {' '.join(text['fonts'])} {sizes}")
    smart = layer.get("smart_object")
    if smart:
        parts.append(f"smart object {smart['kind']} {smart['filetype']} {smart['unique_id']}")
    effects = layer.get("effects")
    if effects:
        names = " ".join(effect["name"] + ("" if effect["enabled"] else "(off)") for effect in effects["items"])
        parts.append(f"effects{'' if effects['enabled'] else ' (all off)'}: {names or 'none'}")
    return " ".join(parts)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Print the structure psd-tools reads from a PSD.")
    parser.add_argument("psd", help="PSD file to inspect")
    parser.add_argument("--json", metavar="OUT", help="also write the report as JSON to OUT")
    parser.add_argument(
        "--raw",
        action="store_true",
        help="also store layer names, text and the file path themselves, not just their hashes "
        "(client data: keep the output out of the repository)",
    )
    args = parser.parse_args(argv)

    report = inspect(args.psd, raw=args.raw)
    print(summary(report))
    if args.json:
        with open(args.json, "w", encoding="utf-8") as out:
            json.dump(report, out, indent=2, ensure_ascii=False)
            out.write("\n")
    return 1 if report["warnings"] or report["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
